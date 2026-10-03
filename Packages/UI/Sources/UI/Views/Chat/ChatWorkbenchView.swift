import AppKit
import DInference
import DWorkbench
import SwiftUI

enum ChatAssetDropScope {
    static func accepts(projectID: UUID, instanceID: UUID?,
                        manifestProjectID: UUID, manifestInstanceID: UUID) -> Bool {
        projectID == manifestProjectID &&
        (instanceID == nil ? manifestInstanceID == manifestProjectID : instanceID == manifestInstanceID)
    }
}

/// Shared presentation gate for every control that can start model work.
/// ChatController still performs the final admission check.
enum ChatRunAdmission {
    static func allows(_ session: ChatSession, isRunning: Bool, hasPendingSave: Bool,
                       hasSaveIssue: Bool, invalidFields: Set<String>) -> Bool {
        !session.archived && session.configuration != nil && !isRunning &&
        !hasPendingSave && !hasSaveIssue &&
        !invalidFields.contains(where: { $0.hasPrefix(session.id.uuidString + ":") })
    }

    static func allowsSend(_ session: ChatSession, isRunning: Bool, hasPendingSave: Bool,
                           hasSaveIssue: Bool, invalidFields: Set<String>) -> Bool {
        allows(session, isRunning: isRunning, hasPendingSave: hasPendingSave,
               hasSaveIssue: hasSaveIssue, invalidFields: invalidFields) &&
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ChatPresentationLayout {
    static let sidebarWidth: CGFloat = 240
    static let inspectorWidth: CGFloat = 320
    static let messageWidth: CGFloat = 760
    // The transcript and composer each reserve 16 points on both sides.
    static let minimumBodyWidth: CGFloat = 680 + 32
    static func showsSidebar(width: CGFloat, requested: Bool) -> Bool {
        requested && width >= minimumBodyWidth + sidebarWidth + 1
    }
    static func showsInspector(width: CGFloat, requested: Bool, sidebar: Bool) -> Bool {
        requested && width >= minimumBodyWidth + inspectorWidth + 1 + (sidebar ? sidebarWidth + 1 : 0)
    }
}

private enum ChatInspectorTab: String, CaseIterable, Identifiable {
    case data, settings, artifacts
    var id: Self { self }
}

enum ChatNarrowPanel: String, Identifiable {
    case sessions, inspector
    var id: Self { self }
}

extension ChatPresentationLayout {
    static func dismissesNarrowPanel(_ panel: ChatNarrowPanel, width: CGFloat,
                                     sidebarRequested: Bool, inspectorRequested: Bool) -> Bool {
        let sidebar = showsSidebar(width: width, requested: sidebarRequested)
        switch panel {
        case .sessions: return sidebar
        case .inspector: return showsInspector(width: width, requested: inspectorRequested, sidebar: sidebar)
        }
    }
}

private enum ChatDetail: Identifiable {
    case edit(ChatEdit), preview(WorkflowAssetReference)
    var id: String {
        switch self {
        case .edit(let edit): "edit-\(edit.id)"
        case .preview(let reference): "preview-\(reference.assetID)"
        }
    }
}

struct ChatSheetQueue<Detail: Identifiable> {
    var narrowPanel: ChatNarrowPanel?
    var detail: Detail?
    private(set) var pendingDetail: Detail?
    private(set) var narrowSheetVisible = false

    init() {}

    mutating func openNarrow(_ panel: ChatNarrowPanel) {
        narrowPanel = panel
        narrowSheetVisible = true
    }

    mutating func present(_ item: Detail) {
        if narrowSheetVisible {
            pendingDetail = item
            narrowPanel = nil
        } else {
            detail = item
        }
    }

    mutating func didDismissNarrowPanel() {
        guard narrowPanel == nil else { return }
        narrowSheetVisible = false
        if let pendingDetail {
            detail = pendingDetail
            self.pendingDetail = nil
        }
    }
}

struct ChatScrollPosition: Equatable {
    let offset: CGFloat
    let distanceToBottom: CGFloat

    static func followsBottom(previous: Self, current: Self, wasFollowing: Bool) -> Bool {
        guard abs(previous.offset - current.offset) > 1 else { return wasFollowing }
        return current.distanceToBottom <= 28
    }
}

private struct ChatSessionScrollState {
    var followsBottom: Bool
    var hasNewContent: Bool
    var anchor: UUID?
}

private enum ChatLayoutSpace { static let name = "chat-presentation-layout" }

private extension View {
    func chatMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatLayoutSpace.name)) }
            action: { probe?(id, $0) }
    }
}

enum ChatPresentationText {
    static func branchSummary(_ message: ChatMessage, you: String, assistant: String) -> String {
        let summary = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return String((summary.isEmpty ? (message.role == .user ? you : assistant) : summary).prefix(44))
    }
}

/// Presentation for a Store-owned chat. Lead owns construction, loading, and
/// model selection; this view never constructs a second controller or backend.
@MainActor
struct ChatWorkbenchView: View {
    @Bindable var chat: ChatController
    let model: WorkbenchModel
    let onChooseModel: () -> Void
    let onSavedAsset: (WorkflowAssetReference) -> Void
    let onAssetsChanged: () -> Void

    @Environment(\.dLanguageStore) private var language
    @State private var search = ""
    @State private var showArchived = false
    @State private var showSidebar = true
    @State private var showInspector = false
    @State private var inspectorTab: ChatInspectorTab = .data
    @State private var sheets = ChatSheetQueue<ChatDetail>()
    @State private var followsBottom = true
    @State private var hasNewContent = false
    @State private var scrollStates: [UUID: ChatSessionScrollState] = [:]
    @State private var visibleMessageID: UUID?
    @State private var restoringScrollFor: UUID?
    @State private var issues: [UUID: String] = [:]
    @State private var globalIssue: String?
    @State private var newPresetName = ""
    private var layoutProbe: ((String, CGRect) -> Void)?

    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    init(chat: ChatController, model: WorkbenchModel,
         onChooseModel: @escaping () -> Void,
         onSavedAsset: @escaping (WorkflowAssetReference) -> Void,
         onAssetsChanged: @escaping () -> Void,
         initialInspectorVisible: Bool = false,
         initiallyFollowsBottom: Bool = true,
         initiallyHasNewContent: Bool = false) {
        self.chat = chat; self.model = model; self.onChooseModel = onChooseModel
        self.onSavedAsset = onSavedAsset; self.onAssetsChanged = onAssetsChanged
        _showInspector = State(initialValue: initialInspectorVisible)
        _followsBottom = State(initialValue: initiallyFollowsBottom)
        _hasNewContent = State(initialValue: initiallyHasNewContent)
    }

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }
    private func newLabel(_ key: String, english: String, chinese: String) -> String {
        workflowText(language, "chat." + key,
            fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english)
    }
    private var session: ChatSession? { chat.selectedSession }
    private func canRun(_ session: ChatSession) -> Bool {
        ChatRunAdmission.allows(session, isRunning: chat.isRunning,
            hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil,
            invalidFields: chat.invalidParameterFields)
    }
    private func report(_ message: String?, for sessionID: UUID?) {
        if let sessionID { issues[sessionID] = message }
        else { globalIssue = message }
    }
    private var visibleSessions: [ChatSession] {
        Array(chat.state.sessions.filter { item in
            item.archived == showArchived &&
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) ||
             item.messages.contains { $0.text.localizedCaseInsensitiveContains(search) } ||
             item.messages.contains { $0.attachments.contains(where: {
                 $0.name.localizedCaseInsensitiveContains(search) ||
                 ($0.textSnapshot?.localizedCaseInsensitiveContains(search) ?? false)
             }) } ||
             item.attempts.contains { ($0.response?.finalText ?? $0.rawText).localizedCaseInsensitiveContains(search) })
        }.reversed())
    }

    var body: some View {
        GeometryReader { geometry in
            let sidebarShown = ChatPresentationLayout.showsSidebar(width: geometry.size.width, requested: showSidebar)
            let inspectorShown = ChatPresentationLayout.showsInspector(width: geometry.size.width,
                requested: showInspector, sidebar: sidebarShown)
            let inspectorInline = inspectorShown && sheets.narrowPanel != .inspector
            let sidebarInline = sidebarShown && sheets.narrowPanel != .sessions
            let sidebarPaneWidth = min(ChatPresentationLayout.sidebarWidth, geometry.size.width)
            let inspectorPaneWidth = min(ChatPresentationLayout.inspectorWidth, geometry.size.width)
            ZStack(alignment: .topLeading) {
                Group {
                    if !chat.isLoaded {
                        ContentUnavailableView(label("loadFailed", "聊天记录不可用"), systemImage: "exclamationmark.triangle",
                            description: Text(chat.error ?? label("loading", "正在读取聊天记录…")))
                    } else if let session {
                        conversation(session, width: geometry.size.width, sidebarShown: sidebarShown)
                    } else {
                        emptyConversation(width: geometry.size.width, sidebarShown: sidebarShown)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, sidebarInline ? ChatPresentationLayout.sidebarWidth + 1 : 0)
                .padding(.trailing, inspectorInline && session != nil ? ChatPresentationLayout.inspectorWidth + 1 : 0)
                .chatMeasured("conversation", probe: layoutProbe)

                if sheets.narrowPanel != nil {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { closeNarrowPanel() }
                        .accessibilityHidden(true)
                }
                sidebar
                    .frame(width: sidebarPaneWidth)
                    .frame(maxHeight: .infinity)
                    .background(.background)
                    .overlay(alignment: .trailing) { if sidebarInline { Divider() } }
                    .offset(x: sidebarInline || sheets.narrowPanel == .sessions ? 0 : -sidebarPaneWidth - 2)
                    .allowsHitTesting(sidebarInline || sheets.narrowPanel == .sessions)
                    .accessibilityHidden(!(sidebarInline || sheets.narrowPanel == .sessions))
                    .chatMeasured("sessions-pane", probe: layoutProbe)
                if let session {
                    inspector(session)
                        .frame(width: inspectorPaneWidth)
                        .frame(maxHeight: .infinity)
                        .background(.background)
                        .overlay(alignment: .leading) { if inspectorInline { Divider() } }
                        .chatMeasured("inspector-pane", probe: layoutProbe)
                        .allowsHitTesting(inspectorInline || sheets.narrowPanel == .inspector)
                        .accessibilityHidden(!(inspectorInline || sheets.narrowPanel == .inspector))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(x: inspectorInline || sheets.narrowPanel == .inspector ? 0 : inspectorPaneWidth + 2)
                }
            }
            .clipped()
            .coordinateSpace(name: ChatLayoutSpace.name)
            .onChange(of: geometry.size.width) { oldWidth, width in
                if let narrowPanel = sheets.narrowPanel, ChatPresentationLayout.dismissesNarrowPanel(narrowPanel,
                    width: width, sidebarRequested: showSidebar, inspectorRequested: showInspector) {
                    closeNarrowPanel()
                } else if sheets.narrowPanel == nil {
                    let oldSidebar = ChatPresentationLayout.showsSidebar(width: oldWidth, requested: showSidebar)
                    let newSidebar = ChatPresentationLayout.showsSidebar(width: width, requested: showSidebar)
                    if ChatPresentationLayout.showsInspector(width: oldWidth, requested: showInspector, sidebar: oldSidebar) &&
                       !ChatPresentationLayout.showsInspector(width: width, requested: showInspector, sidebar: newSidebar) {
                        sheets.openNarrow(.inspector)
                    } else if oldSidebar && !newSidebar {
                        sheets.openNarrow(.sessions)
                    }
                }
            }
        }
        .task { if !chat.isLoaded { await chat.load() } }
        .sheet(item: Binding(get: { sheets.detail }, set: { sheets.detail = $0 })) { item in
            switch item {
            case .edit(let edit): editSheet(edit)
            case .preview(let preview):
                VStack(alignment: .leading) {
                    Button(label("close", "关闭")) { sheets.detail = nil }.keyboardShortcut(.cancelAction)
                    QuickAssetPreview(store: chat.store, reference: preview, compact: false)
                }.padding(20).frame(minWidth: 560, minHeight: 360)
            }
        }
    }

    private func emptyConversation(width: CGFloat, sidebarShown: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                paneButtons(width: width, sidebarShown: sidebarShown)
                Spacer()
            }.padding(12)
            Divider()
            ChatEmptyConversationView { createSession() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .chatMeasured("empty-conversation", probe: layoutProbe)
        }
    }

    private func paneButtons(width: CGFloat, sidebarShown: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                if !ChatPresentationLayout.showsSidebar(width: width, requested: true) {
                    showSidebar = true
                    sheets.openNarrow(.sessions)
                } else { showSidebar.toggle() }
            } label: { Label(label("history", "对话"), systemImage: "sidebar.left") }
                .accessibilityIdentifier("chat-sessions-toggle")
            Button {
                if !ChatPresentationLayout.showsInspector(width: width, requested: true, sidebar: sidebarShown) {
                    showInspector = true
                    sheets.openNarrow(.inspector)
                }
                else { showInspector.toggle() }
            } label: { Label(newLabel("inspector", english: "Inspector", chinese: "检查器"), systemImage: "sidebar.right") }
                .accessibilityIdentifier("chat-inspector-toggle")
        }.labelStyle(.iconOnly)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label("history", "对话")) .font(.headline)
                Spacer()
                Button(label("new", "新建"), systemImage: "plus") { createSession() }
                    .disabled(!chat.isLoaded || chat.saveIssue != nil)
                if sheets.narrowPanel == .sessions {
                    Button(label("close", "关闭"), systemImage: "xmark") { closeNarrowPanel() }
                        .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("chat-sessions-close")
                }
            }
            TextField(label("search", "搜索标题与内容"), text: $search)
                .textFieldStyle(.roundedBorder)
            Toggle(label("archived", "已归档"), isOn: $showArchived).controlSize(.small)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleSessions) { item in
                        HStack(spacing: 6) {
                            Button {
                                do {
                                    if let currentID = chat.state.selectedSessionID { saveScrollState(for: currentID) }
                                    try chat.selectSession(item.id)
                                    closeNarrowPanel()
                                } catch { report(error.localizedDescription, for: item.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).lineLimit(2)
                                    Text("\(item.messages.count) " + label("messages", "条消息"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Menu {
                                Button(label("rename", "重命名")) {
                                    present(.edit(ChatEdit(kind: .rename, sessionID: item.id, messageID: nil, text: item.title)))
                                }
                                if !item.archived {
                                    Button(label("archive", "归档")) { perform(sessionID: item.id) { try chat.archive(item.id) } }
                                        .disabled(chat.activeSessionID == item.id)
                                }
                                if item.selectedLeafID != nil {
                                    Divider()
                                    Button(label("copyPath", "复制所选路径")) {
                                        perform(sessionID: item.id) { copy(try chat.exportSelectedPath(sessionID: item.id, markdown: false)) }
                                    }
                                    Button(label("exportMarkdown", "导出 Markdown")) { Task { await export(sessionID: item.id, markdown: true) } }
                                    Button(label("exportPlain", "导出纯文字")) { Task { await export(sessionID: item.id, markdown: false) } }
                                }
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel(newLabel("sessionActions", english: "Conversation actions: ", chinese: "对话操作：") + item.title)
                        }
                        .padding(9)
                        .background(chat.state.selectedSessionID == item.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }.padding(14)
    }

    private func conversation(_ session: ChatSession, width: CGFloat, sidebarShown: Bool) -> some View {
        let parentIDs = Set(session.messages.compactMap(\.parentID))
        let leaves = session.messages.filter { !parentIDs.contains($0.id) }
        let siblings = Dictionary(grouping: session.messages, by: {
            ($0.parentID?.uuidString ?? "root") + ":" + $0.role.rawValue
        })
        let attempts = Dictionary(uniqueKeysWithValues: session.attempts.map { ($0.id, $0) })
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                paneButtons(width: width, sidebarShown: sidebarShown)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.headline).lineLimit(1)
                    if let node = session.configuration {
                        let id = node.parameters["modelID"]?.string ?? ""
                        Text((model.projectSession.explicitModelChoices.first(where: { $0.id == id })?.displayName ??
                             (id.isEmpty ? label("chooseModel", "选择模型") : id)) + " · " + readiness(id))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(label("noModel", "尚未选择模型")) .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(label("changeModel", "更换模型"), action: onChooseModel)
                    .lineLimit(1)
                if !session.messages.isEmpty {
                    Menu(label("paths", "路径")) {
                        ForEach(leaves) { leaf in
                            Button((leaf.id == session.selectedLeafID ? "✓ " : "") + branchSummary(leaf)) {
                                perform(sessionID: session.id) { try chat.selectLeaf(leaf.id, sessionID: session.id) }
                            }
                        }
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
                .chatMeasured("topbar", probe: layoutProbe)
            Divider()
            if chat.isRunning, let active = chat.activeSessionID,
               let owner = chat.state.sessions.first(where: { $0.id == active }) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(label("runningIn", "正在生成：") + owner.title + " · " + chat.phase)
                        .font(.caption).lineLimit(2)
                    Spacer()
                    Button(label("stop", "停止当前生成")) { Task { await chat.cancel() } }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
              ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if session.originSessionID != nil {
                            Text(label("forkOrigin", "此对话从另一条路径分叉；原对话仍保留。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(chat.selectedPath) { message in
                            messageCard(message, session: session,
                                siblings: siblings[(message.parentID?.uuidString ?? "root") + ":" + message.role.rawValue] ?? [],
                                attempt: message.attemptID.flatMap { attempts[$0] })
                                .id(message.id)
                                .chatMeasured("message-\(message.id.uuidString)", probe: layoutProbe)
                        }
                        if session.selectedLeafID == nil {
                            Text(label("noMessages", "暂无消息")) .foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.scrollTargetLayout()
                        .frame(maxWidth: ChatPresentationLayout.messageWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16).padding(.vertical, 20)
                }
                .scrollPosition(id: $visibleMessageID)
                .chatMeasured("transcript", probe: layoutProbe)
                .onScrollGeometryChange(for: ChatScrollPosition.self) { geometry in
                    ChatScrollPosition(offset: geometry.contentOffset.y,
                        distanceToBottom: geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height)
                } action: { previous, current in
                    guard chat.state.selectedSessionID == session.id,
                          restoringScrollFor != session.id else { return }
                    followsBottom = ChatScrollPosition.followsBottom(previous: previous, current: current,
                        wasFollowing: followsBottom)
                    if followsBottom { hasNewContent = false }
                    saveScrollState(for: session.id)
                }
                .onChange(of: visibleMessageID) { _, _ in
                    if chat.state.selectedSessionID == session.id, restoringScrollFor != session.id {
                        saveScrollState(for: session.id)
                    }
                }
                .onChange(of: transcriptRevision(session)) { previous, _ in
                    guard previous.hasPrefix(session.id.uuidString + ":"),
                          restoringScrollFor != session.id else { return }
                    if followsBottom {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    } else {
                        hasNewContent = true
                    }
                    saveScrollState(for: session.id)
                }
                .onChange(of: session.id) { oldID, newID in
                    if scrollStates[oldID] == nil { saveScrollState(for: oldID) }
                    let restored = scrollStates[newID]
                    followsBottom = restored?.followsBottom ?? true
                    hasNewContent = restored?.hasNewContent ?? false
                    visibleMessageID = restored?.anchor
                    restoringScrollFor = newID
                    Task { @MainActor in
                        await Task.yield()
                        if followsBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        else if let anchor = restored?.anchor { proxy.scrollTo(anchor, anchor: .top) }
                        restoringScrollFor = nil
                    }
                }
                .onAppear {
                    if let saved = scrollStates[session.id] {
                        followsBottom = saved.followsBottom
                        hasNewContent = saved.hasNewContent
                        visibleMessageID = saved.anchor
                        if saved.followsBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        else if let anchor = saved.anchor { proxy.scrollTo(anchor, anchor: .top) }
                    } else if followsBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsBottom {
                        Button(hasNewContent ? newLabel("newContent", english: "New content · Bottom", chinese: "有新内容 · 到底部") : label("bottom", "到底部"),
                               systemImage: "arrow.down") {
                            followsBottom = true; hasNewContent = false
                            saveScrollState(for: session.id)
                            withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        }.padding(12).accessibilityIdentifier("chat-bottom-button")
                            .chatMeasured("bottom-button", probe: layoutProbe)
                    }
                }
              }
            Divider()
            composer(session)
                .chatMeasured("composer", probe: layoutProbe)
        }
    }

    private func transcriptRevision(_ session: ChatSession) -> String {
        let latest = session.attempts.last
        return "\(session.id):\(session.selectedLeafID?.uuidString ?? ""):\(session.messages.count):\(latest?.rawText.utf8.count ?? 0):\(latest?.status.rawValue ?? "")"
    }

    private func saveScrollState(for sessionID: UUID) {
        scrollStates[sessionID] = .init(followsBottom: followsBottom,
            hasNewContent: hasNewContent, anchor: visibleMessageID)
    }

    private func branchSummary(_ message: ChatMessage) -> String {
        ChatPresentationText.branchSummary(message, you: label("you", "你"), assistant: label("assistant", "助手"))
    }

    private func inspector(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(newLabel("inspector", english: "Inspector", chinese: "检查器")).font(.headline)
                Spacer()
                Button(label("close", "关闭"), systemImage: "xmark") {
                    showInspector = false; closeNarrowPanel()
                }.labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("chat-inspector-close")
            }.padding(14)
            Picker(newLabel("inspector", english: "Inspector", chinese: "检查器"), selection: $inspectorTab) {
                Text(newLabel("inspectorData", english: "Data", chinese: "资料")).tag(ChatInspectorTab.data)
                Text(newLabel("inspectorSettings", english: "Settings", chinese: "设置")).tag(ChatInspectorTab.settings)
                Text(newLabel("inspectorArtifacts", english: "Artifacts", chinese: "成果")).tag(ChatInspectorTab.artifacts)
            }.pickerStyle(.segmented).padding(.horizontal, 12)
            Divider().padding(.top, 12)
            ScrollView {
                Group {
                    switch inspectorTab {
                    case .data:
                        VStack(alignment: .leading, spacing: 12) {
                            Text(newLabel("selectedPath", english: "Selected path", chinese: "当前路径")).font(.headline)
                            Text("\(chat.selectedPath.count) " + label("messages", "条消息"))
                                .foregroundStyle(.secondary)
                            if session.originSessionID != nil {
                                Text(label("forkOrigin", "此对话从另一条路径分叉；原对话仍保留。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(newLabel("attachments", english: "Pending attachments", chinese: "待发送附件")).font(.headline)
                            if session.attachments.isEmpty {
                                Text(newLabel("noAttachments", english: "No attachments", chinese: "暂无附件")) .foregroundStyle(.secondary)
                            } else {
                                ForEach(session.attachments) { item in
                                    attachmentRow(item, removable: true, sessionID: session.id)
                                }
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    case .settings:
                        settings(session)
                    case .artifacts:
                        VStack(alignment: .leading, spacing: 12) {
                            Text(newLabel("savedAnswers", english: "Saved answers", chinese: "回答成果")).font(.headline)
                            ForEach(session.attempts.filter { $0.output != nil }) { attempt in
                                if let output = attempt.output {
                                    Button(label("preview", "预览") + " · " +
                                           String((attempt.response?.finalText ?? attempt.rawText).prefix(36))) {
                                        present(.preview(output))
                                    }
                                }
                            }
                            if !session.attempts.contains(where: { $0.output != nil }) {
                                Text(newLabel("noArtifacts", english: "No saved answers", chinese: "尚无已保存回答")) .foregroundStyle(.secondary)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityIdentifier("chat-inspector")
    }

    private func messageCard(_ message: ChatMessage, session: ChatSession,
                             siblings: [ChatMessage], attempt: ChatAttempt?) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.role == .user ? label("you", "你") : label("assistant", "助手")) .font(.headline)
                if siblings.count > 1 {
                    Menu(label("branch", "分支") + " \((siblings.firstIndex(where: { $0.id == message.id }) ?? 0) + 1)/\(siblings.count)") {
                        ForEach(siblings) { sibling in
                            Button("\((siblings.firstIndex(where: { $0.id == sibling.id }) ?? 0) + 1) · " +
                                   branchSummary(sibling)) {
                                perform(sessionID: session.id) { try chat.selectLeaf(sibling.id, sessionID: session.id) }
                            }
                        }
                    }.chatMeasured("branch-menu-\(message.id.uuidString)", probe: layoutProbe)
                }
                Spacer()
                Button(label("copy", "复制")) {
                    copy(attempt?.response?.finalText ?? attempt?.rawText ?? message.text)
                }
                if message.role == .user {
                    Button(label("edit", "编辑")) {
                        present(.edit(ChatEdit(kind: .message, sessionID: session.id, messageID: message.id, text: message.text)))
                    }
                }
                Menu {
                    if message.role == .user {
                        Button(label("generateReply", "生成回复")) { Task { await run(sessionID: session.id) { try await chat.regenerate(message.id, sessionID: session.id) } } }
                            .disabled(!canRun(session))
                    } else if let parent = message.parentID {
                        Button(label("regenerate", "重新生成")) { Task { await run(sessionID: session.id) { try await chat.regenerate(parent, sessionID: session.id) } } }
                            .disabled(!canRun(session))
                    }
                    Button(label("forkHere", "从这里分叉")) {
                        perform(sessionID: session.id) { _ = try chat.forkSession(session.id, leafID: message.id) }
                    }
                    if attempt?.status == .completed, attempt?.response?.finalText?.isEmpty == false {
                        Button(label("saveAsset", "保存回答为素材")) { Task { await saveFinal(message.id, sessionID: session.id, useInWorkflow: false) } }
                        Button(label("useWorkflow", "用于工作流")) { Task { await saveFinal(message.id, sessionID: session.id, useInWorkflow: true) } }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(newLabel("messageActions", english: "Message actions: ", chinese: "消息操作：") + branchSummary(message))
            }.font(.caption)
            ChatMessageContent(message: message, attempt: attempt, onPreview: { present(.preview($0)) })
            if let attempt {
                HStack {
                    Text(status(attempt)).font(.caption).foregroundStyle(.secondary)
                        .chatMeasured("attempt-status-\(attempt.id.uuidString)", probe: layoutProbe)
                    if let response = attempt.response {
                        Text(label("finish", "结束原因") + ": " + finish(response.finishReason))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let issue = attempt.issue {
                    Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .chatMeasured("attempt-issue-\(attempt.id.uuidString)", probe: layoutProbe)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func settings(_ session: ChatSession) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(label("nextAnswer", "下一次回答设置")).font(.headline)
                Text(label("futureOnly", "更改只影响之后的生成。")) .font(.caption).foregroundStyle(.secondary)
                Text(label("systemPrompt", "系统提示（默认空）")) .font(.subheadline)
                TextSourcesQuestionEditor(value: session.systemPrompt, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-system-\(session.id.uuidString)",
                    onEdit: { value in perform(sessionID: session.id) { try chat.setSystemPrompt(value, sessionID: session.id) } })
                    .id(session.id.uuidString + ":system")
                    .frame(height: 90)
                VStack(alignment: .leading, spacing: 8) {
                    Button(label("clearSystem", "清空系统提示")) { perform(sessionID: session.id) { try chat.setSystemPrompt("", sessionID: session.id) } }
                    Menu(label("applyPreset", "应用本地预设")) {
                        ForEach(chat.state.presets) { preset in
                            Menu(preset.name) {
                                Button(label("apply", "应用")) { perform(sessionID: session.id) { try chat.setSystemPrompt(preset.prompt, sessionID: session.id) } }
                                Button(label("replacePreset", "用当前提示更新")) {
                                    perform(sessionID: session.id) { try chat.setPreset(ChatPromptPreset(id: preset.id, name: preset.name, prompt: session.systemPrompt)) }
                                }
                                Button(label("duplicatePreset", "复制预设")) {
                                    perform(sessionID: session.id) { try chat.setPreset(ChatPromptPreset(name: preset.name +
                                        label("presetCopySuffix", " 副本"), prompt: preset.prompt)) }
                                }
                                Button(label("deletePreset", "删除预设")) { perform(sessionID: session.id) { try chat.removePreset(preset.id) } }
                            }
                        }
                    }
                    TextField(label("presetName", "预设名称"), text: $newPresetName)
                    Button(label("savePreset", "保存预设")) { savePreset(session) }
                        .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let node = session.configuration,
                   let definition = WorkflowRegistry.standard.definition(for: node) {
                    ForEach(definition.fields.filter { !["modelID", "task", "messagesJSON", "outputMode"].contains($0.id) }) { field in
                        QuickParameterField(ownerID: session.id.uuidString, operationID: node.operationID,
                            field: field, value: node.parameters[field.id] ?? field.defaultValue,
                            onChange: { value in changeParameter(field.id, value: value, node: node, sessionID: session.id) },
                            raw: chat.parameterText[session.id.uuidString + ":" + field.id],
                            onRaw: { raw in changeNumeric(field: field, raw: raw, node: node, sessionID: session.id) })
                    }
                    if definition.fields.contains(where: { $0.id == "toolsJSON" }) {
                        Text(label("toolsUnexecuted", "工具 JSON 仅向模型声明；D 不执行工具调用。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composer(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(session.attachments) { item in attachmentRow(item, removable: true, sessionID: session.id) }
                    }
                }
            }
            TextSourcesQuestionEditor(value: session.draft, editEpoch: 0, isEditable: !session.archived,
                accessibilityIdentifier: "chat-draft-\(session.id.uuidString)",
                onEdit: { value in perform(sessionID: session.id) { try chat.updateDraft(value, sessionID: session.id) } })
                .id(session.id.uuidString + ":draft")
                .frame(minHeight: 80, idealHeight: 110)
            Text(label("dropFiles", "可拖入 TXT、MD、图像或视频；Enter 换行。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(label("attach", "添加附件…"), systemImage: "paperclip") {
                    Task { await chooseAttachments(for: session.id) }
                }.disabled(session.archived)
                Spacer()
                if chat.pendingSaveAttemptID != nil || chat.saveIssue != nil {
                    Button(label("retrySave", "重试保存（不重新生成）")) { Task { await chat.retrySave() } }
                        .disabled(chat.isRunning)
                }
                Button(label("send", "发送")) { Task { await run(sessionID: session.id) { try await chat.send(sessionID: session.id) } } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ChatRunAdmission.allowsSend(session, isRunning: chat.isRunning,
                        hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil,
                        invalidFields: chat.invalidParameterFields))
                    .accessibilityIdentifier("chat-send")
            }
            .dropDestination(for: WorkflowCanvasTransfer.self) { items, _ in
                let owner = session.id
                Task { await importSharedAssets(items, sessionID: owner) }
                return !items.isEmpty
            }
            if let issue = issues[session.id] {
                Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let saveIssue = chat.saveIssue, saveIssue != issues[session.id] {
                Text(label("projectSaveIssue", "项目聊天保存失败：") + saveIssue)
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let globalIssue {
                Text(globalIssue).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if chat.selectedPath.last?.role == .user {
                Text(label("awaitingReply", "所选路径止于用户消息；请点“生成回复”，或选已完成路径。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: ChatPresentationLayout.messageWidth)
        .frame(maxWidth: .infinity)
        .padding(16)
        .dropDestination(for: URL.self) { urls, _ in
            let owner = session.id
            Task { await importURLs(urls, sessionID: owner) }
            return !urls.isEmpty
        }
    }

    private func attachmentRow(_ item: ChatAttachment, removable: Bool, sessionID: UUID) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.reference.kind == .image ? "photo" : item.reference.kind == .video ? "film" : "doc.text")
            Text(item.name).lineLimit(1)
            Text(attachmentKind(item.reference.kind)).font(.caption).foregroundStyle(.secondary)
            Button(label("preview", "预览")) { present(.preview(item.reference)) }
            if removable {
                Button(label("remove", "移除")) { perform(sessionID: sessionID) { try chat.removeAttachment(item.id, sessionID: sessionID) } }
            }
        }.font(.caption).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .chatMeasured("attachment-\(item.id.uuidString)", probe: layoutProbe)
    }

    private func readiness(_ id: String) -> String {
        switch model.projectSession.explicitModelReadiness[id] ?? .unknown {
        case .available: label("ready", "文件已核验 · 运行时仍需检查")
        case .unprepared: label("unprepared", "需要准备模型文件")
        case .unavailable: label("unavailable", "文件或授权暂不可用")
        case .unsupported: label("unsupported", "当前入口未适配")
        case .unknown: label("unknown", "准备状态待核验")
        }
    }
    private func status(_ attempt: ChatAttempt) -> String {
        let fallback: String = switch attempt.status {
        case .running: "生成中"; case .completed: "已完成"; case .partial: "部分完成"
        case .cancelled: "已取消"; case .failed: "失败"; case .interrupted: "已中断"
        case .saving: "保存中"
        }
        return label("status." + attempt.status.rawValue, fallback)
    }
    private func finish(_ reason: TextFinishReason) -> String {
        let fallback: String = switch reason {
        case .stop: "正常结束"; case .length: "达到长度上限"
        case .toolCalls: "工具调用待处理"; case .incomplete: "未完整结束"
        }
        return label("finish." + reason.rawValue, fallback)
    }
    private func attachmentKind(_ kind: WorkflowDataKind) -> String {
        switch kind {
        case .text: label("kind.text", "文字")
        case .image: label("kind.image", "图像")
        case .video: label("kind.video", "视频")
        default: kind.rawValue
        }
    }
    private func copy(_ string: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string)
    }
    private func perform(sessionID: UUID? = nil, clearOnSuccess: Bool = true, _ action: () throws -> Void) {
        let owner = sessionID ?? chat.state.selectedSessionID
        do { try action(); if clearOnSuccess { report(nil, for: owner) } }
        catch { report(error.localizedDescription, for: owner) }
    }
    private func run(sessionID: UUID, _ action: () async throws -> Void) async {
        do { try await action(); report(nil, for: sessionID) }
        catch { report(error.localizedDescription, for: sessionID) }
    }
    private func savePreset(_ session: ChatSession) {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(sessionID: session.id) { try chat.setPreset(ChatPromptPreset(name: name, prompt: session.systemPrompt)) }
        if issues[session.id] == nil { newPresetName = "" }
    }
    private func changeParameter(_ key: String, value: WorkflowScalar, node: WorkflowNode, sessionID: UUID) {
        var copy = node; copy.parameters[key] = value
        perform(sessionID: sessionID) { try chat.updateConfiguration(copy, sessionID: sessionID) }
        let fieldKey = sessionID.uuidString + ":" + key
        if issues[sessionID] == nil { chat.invalidParameterFields.remove(fieldKey) }
        else { chat.invalidParameterFields.insert(fieldKey) }
    }
    private func changeNumeric(field: WorkflowFieldDefinition, raw: String, node: WorkflowNode, sessionID: UUID) {
        let key = sessionID.uuidString + ":" + field.id
        chat.parameterText[key] = raw
        switch field.kind {
        case .integer:
            if let value = Int(raw) { changeParameter(field.id, value: .integer(value), node: node, sessionID: sessionID) }
            else { chat.invalidParameterFields.insert(key); report(label("invalidNumber", "数值未完成或无效；修正后才能生成。"), for: sessionID) }
        case .decimal:
            if let value = Double(raw), value.isFinite { changeParameter(field.id, value: .decimal(value), node: node, sessionID: sessionID) }
            else { chat.invalidParameterFields.insert(key); report(label("invalidNumber", "数值未完成或无效；修正后才能生成。"), for: sessionID) }
        default: break
        }
    }

    private func chooseAttachments(for sessionID: UUID) async {
        let owner = chat, store = chat.store
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard await panel.begin() == .OK, owner === chat, store === chat.store else { return }
        await importURLs(panel.urls, sessionID: sessionID)
    }
    private func importURLs(_ urls: [URL], sessionID: UUID) async {
        let owner = chat, store = chat.store
        var failures: [String] = []
        for url in urls {
            guard owner === chat, store === chat.store, chat.isLoaded,
                  chat.state.sessions.contains(where: { $0.id == sessionID }) else { break }
            guard url.isFileURL else { failures.append(url.absoluteString + ": " + label("fileOnly", "仅接受本地文件")); continue }
            guard ["txt", "md", "png", "jpg", "jpeg", "mp4"].contains(url.pathExtension.lowercased()) else {
                failures.append(url.lastPathComponent + ": " + label("unsupportedAttachment", "只接受 TXT、MD、PNG、JPEG、MP4"))
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let published = try await store.importWorkflowMediaFile(at: url)
                onAssetsChanged()
                try await chat.addAttachment(published.record.reference, name: url.lastPathComponent, sessionID: sessionID)
            } catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        report(failures.isEmpty ? nil : failures.joined(separator: "\n"), for: sessionID)
    }
    private func importSharedAssets(_ items: [WorkflowCanvasTransfer], sessionID: UUID) async {
        let owner = chat, store = chat.store
        do {
            let manifest = await store.snapshot()
            let state = try await store.workflowState()
            guard owner === chat, store === chat.store else { return }
            guard let archive = state.archive else { throw WorkflowIssue(state.readOnlyReason ?? "素材记录不可读。") }
            var failures: [String] = []
            for item in items {
                guard owner === chat, store === chat.store, chat.isLoaded,
                      chat.state.sessions.contains(where: { $0.id == sessionID }) else { break }
                let projectID: UUID, instanceID: UUID?, assetID: UUID
                switch item {
                case .asset(let project, let asset): (projectID, instanceID, assetID) = (project, nil, asset)
                case .assetInstance(let project, let instance, let asset): (projectID, instanceID, assetID) = (project, instance, asset)
                default:
                    failures.append(label("unsupportedDrop", "只能拖入项目素材。"))
                    continue
                }
                do {
                    guard ChatAssetDropScope.accepts(projectID: projectID, instanceID: instanceID,
                        manifestProjectID: manifest.id, manifestInstanceID: manifest.effectiveInstanceID),
                          let asset = manifest.assets.first(where: { $0.id == assetID }),
                          let reference = archive.assets.first(where: { $0.reference.assetID == assetID })?.reference else {
                        throw WorkflowIssue(label("dropScope", "拖入素材不属于此聊天项目，或缺少受管理的版本。"))
                    }
                    try await chat.addAttachment(reference, name: asset.name, sessionID: sessionID)
                } catch {
                    failures.append(String(assetID.uuidString.prefix(8)) + ": " + error.localizedDescription)
                }
            }
            report(failures.isEmpty ? nil : failures.joined(separator: "\n"), for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID) }
    }
    private func export(sessionID: UUID, markdown: Bool) async {
        let owner = chat, store = chat.store
        let value: String
        do { value = try chat.exportSelectedPath(sessionID: sessionID, markdown: markdown) }
        catch { report(error.localizedDescription, for: sessionID); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard await panel.begin() == .OK, let directory = panel.url,
              owner === chat, store === chat.store else { return }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        do {
            let reference = try await store.publishWorkflowAsset(data: Data(value.utf8), mediaType: markdown ? "text/markdown" : "text/plain",
                name: markdown ? "聊天路径 Markdown" : "聊天路径纯文字", operationID: "d.chat.export-path",
                details: ["chatSessionID": sessionID.uuidString, "format": markdown ? "markdown" : "plain"]).record.reference
            onAssetsChanged()
            _ = try await store.exportWorkflowAssets([reference], name: markdown ? "D-chat-markdown" : "D-chat-text",
                                                      exportID: UUID(), directory: directory)
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID) }
    }
    private func saveFinal(_ messageID: UUID, sessionID: UUID, useInWorkflow: Bool) async {
        let owner = chat
        do {
            let asset = try await owner.saveAssistantFinal(messageID, sessionID: sessionID)
            guard owner === chat else { return }
            onAssetsChanged()
            if useInWorkflow { onSavedAsset(asset) }
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID) }
    }

    private func present(_ item: ChatDetail) {
        sheets.present(item)
        // Narrow panes are overlays, so there is no AppKit sheet dismissal to await.
        if sheets.narrowPanel == nil { sheets.didDismissNarrowPanel() }
    }

    private func closeNarrowPanel() {
        sheets.narrowPanel = nil
        sheets.didDismissNarrowPanel()
    }

    private func createSession() {
        do {
            if let currentID = chat.state.selectedSessionID { saveScrollState(for: currentID) }
            _ = try chat.newSession()
            closeNarrowPanel()
        } catch { report(error.localizedDescription, for: chat.state.selectedSessionID) }
    }

    private func editSheet(_ edit: ChatEdit) -> some View {
        ChatEditForm(edit: edit, onCancel: { sheets.detail = nil }, onCommit: { text in
            perform(sessionID: edit.sessionID) {
                switch edit.kind {
                case .rename: try chat.rename(edit.sessionID, title: text)
                case .message:
                    guard let id = edit.messageID else { return }
                    _ = try chat.editUserMessage(id, text: text, sessionID: edit.sessionID)
                }
            }
            if issues[edit.sessionID] == nil { sheets.detail = nil }
        })
    }
}

private struct ChatEdit: Identifiable {
    enum Kind: Equatable { case rename, message }
    let id = UUID()
    let kind: Kind
    let sessionID: UUID
    let messageID: UUID?
    let text: String
}

@MainActor
private struct ChatEditForm: View {
    let edit: ChatEdit
    let onCancel: () -> Void
    let onCommit: (String) -> Void
    @State private var text: String
    @Environment(\.dLanguageStore) private var language

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }

    init(edit: ChatEdit, onCancel: @escaping () -> Void, onCommit: @escaping (String) -> Void) {
        self.edit = edit; self.onCancel = onCancel; self.onCommit = onCommit
        _text = State(initialValue: edit.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(edit.kind == .rename ? label("rename", "重命名对话") : label("editBranch", "编辑消息 · 创建新分支"))
                .font(.headline)
            TextSourcesQuestionEditor(value: text, editEpoch: 0, isEditable: true,
                accessibilityIdentifier: "chat-edit-\(edit.sessionID.uuidString)", onEdit: { text = $0 })
                .id(edit.id).frame(height: edit.kind == .rename ? 70 : 220)
            HStack {
                Spacer()
                Button(label("cancel", "取消"), action: onCancel)
                Button(edit.kind == .rename ? label("save", "保存") : label("createBranch", "创建分支")) { onCommit(text) }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(minWidth: 440)
    }
}
