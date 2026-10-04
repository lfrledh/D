import AppKit
import DInference
import DWorkbench
import SwiftUI

enum ChatAssetDropScope {
    static func accepts(projectID: UUID, instanceID: UUID?,
                        manifestProjectID: UUID, manifestInstanceID: UUID) -> Bool {
        // A legacy payload needs the shared library's uniqueness resolution, even
        // when this Store is the original: a restored instance may also be open.
        projectID == manifestProjectID && instanceID == manifestInstanceID
    }
}

/// Shared presentation gate for every control that can start model work.
/// ChatController still performs the final admission check.
enum ChatRunAdmission {
    static func allowsReplay(_ session: ChatSession, attempt: ChatAttempt, isRunning: Bool,
                             hasPendingSave: Bool, hasSaveIssue: Bool) -> Bool {
        guard let seed = attempt.node.parameters["seed"]?.string, UInt64(seed) != nil else { return false }
        return !session.archived && session.contextChoices?.deletedAt == nil && !isRunning && !hasPendingSave && !hasSaveIssue &&
            attempt.sessionID == session.id && attempt.status != .running && attempt.status != .saving
    }

    static func allows(_ session: ChatSession, isRunning: Bool, hasPendingSave: Bool,
                       hasSaveIssue: Bool, invalidFields: Set<String>) -> Bool {
        !session.archived && session.contextChoices?.deletedAt == nil && session.configuration != nil && !isRunning &&
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
    case comparison(UUID, UUID), presetImport([ChatPromptPreset], Data)
    case conversationImport(Data, String)
    case quote(UUID, ChatQuoteSource), artifact(ChatArtifactContent), fields([ChatAnswerField])
    case knowledgeDirectory(UUID, URL, ChatKnowledgeDirectoryInventory, Bool)
    var id: String {
        switch self {
        case .edit(let edit): "edit-\(edit.id)"
        case .preview(let reference): "preview-\(reference.assetID)"
        case .comparison(let session, let attempt): "compare-\(session)-\(attempt)"
        case .presetImport: "preset-import"
        case .conversationImport: "conversation-import"
        case .knowledgeDirectory(let owner, let url, _, _): "knowledge-directory-\(owner)-\(url.path)"
        case .artifact(let value): "artifact-\(value.id)-\(value.revision)"
        case .fields(let values): "fields-\(values.first?.answer.assetID.uuidString ?? "empty")"
        case .quote(let session, let source): "quote-\(session)-\(source.id)"
        }
    }
}

struct ChatSearchJump: Equatable {
    let sessionID: UUID
    let messageID: UUID
    let ticket = UUID()
}

enum ChatContextSessionList {
    static func visible(_ sessions: [ChatSession], archived: Bool, deleted: Bool,
                        favoritesOnly: Bool, tag: String) -> [ChatSession] {
        sessions.enumerated().filter { pair in
            let item = pair.element
            return item.archived == archived && (item.contextChoices?.deletedAt != nil) == deleted &&
                (tag.isEmpty || item.contextChoices?.tags.contains(tag) == true) &&
                (!favoritesOnly || item.contextChoices?.favoriteMessageIDs.isEmpty == false)
        }.sorted { lhs, rhs in
            let left = lhs.element.contextChoices?.pinned == true
            let right = rhs.element.contextChoices?.pinned == true
            return left == right ? lhs.offset > rhs.offset : left
        }.map { $0.element }
    }
}

/// These commands are used by the hosted controls and by the presentation fixture.
@MainActor enum ChatContextCommands {
    static func open(_ hit: ChatSearchHit, in chat: ChatController) throws -> ChatSearchJump? {
        guard let session = chat.state.sessions.first(where: { $0.id == hit.sessionID }),
              session.contextChoices?.deletedAt == nil else { throw WorkflowIssue("对话已删除或不存在。") }
        try chat.selectSession(session.id)
        guard let messageID = hit.messageID else { return nil }
        // An ancestor is already visible; changing the leaf would discard the rest of this path.
        if !chat.selectedPath.contains(where: { $0.id == messageID }) {
            try chat.selectLeaf(messageID, sessionID: session.id)
        }
        return .init(sessionID: session.id, messageID: messageID)
    }

    static func adopt(_ text: String, messageID: UUID, sessionID: UUID,
                      in chat: ChatController) throws {
        guard chat.state.selectedSessionID == sessionID else {
            throw WorkflowIssue("请返回原对话后再采用此回答。")
        }
        guard let session = chat.selectedSession,
              let attemptID = session.messages.first(where: { $0.id == messageID && $0.role == .assistant })?.attemptID,
              canAdopt(session.attempts.first(where: { $0.id == attemptID }), in: chat) else {
            throw WorkflowIssue("回答仍在运行、待保存或等待工具完成，不能采用。")
        }
        _ = try chat.adoptAnswer(messageID, text: text, sessionID: sessionID)
    }

    static func choices(_ session: ChatSession, mutate: (inout ChatContextChoices) -> Void,
                        in chat: ChatController) throws {
        guard let current = chat.state.sessions.first(where: { $0.id == session.id }) else {
            throw WorkflowIssue("对话不存在。")
        }
        var value = current.contextChoices ?? .init()
        mutate(&value)
        try chat.updateContextChoices(value, sessionID: session.id)
    }

    static func canAdopt(_ attempt: ChatAttempt?, in chat: ChatController) -> Bool {
        guard let attempt, attempt.status != .running, attempt.status != .saving,
              !chat.isRunning, chat.pendingSaveAttemptID == nil, chat.saveIssue == nil,
              attempt.response?.toolCalls.isEmpty != false,
              attempt.response?.finishReason != .toolCalls,
              attempt.response?.finishReason != .incomplete else { return false }
        return !(attempt.response?.finalText ?? attempt.rawText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func selectVersion(_ revisionID: UUID?, messageID: UUID, sessionID: UUID,
                              in chat: ChatController) throws {
        guard chat.state.selectedSessionID == sessionID,
              let session = chat.selectedSession,
              let attemptID = session.messages.first(where: { $0.id == messageID && $0.role == .assistant })?.attemptID,
              canAdopt(session.attempts.first(where: { $0.id == attemptID }), in: chat) else {
            throw WorkflowIssue("请等待回答完成并返回原对话后再选择版本。")
        }
        try chat.selectAnswerRevision(revisionID, messageID: messageID, sessionID: sessionID)
    }
}

enum ChatContextRowStatus: Equatable {
    case currentQuestion, excluded, summarized, adopted, included

    static func forMessage(_ message: ChatMessage, in session: ChatSession, summaryUses: [ChatContextSummary] = []) -> Self {
        if message.role == .user && session.selectedLeafID == message.id &&
            session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .currentQuestion
        }
        if session.contextChoices?.excludedMessageIDs.contains(message.id) == true { return .excluded }
        if summaryUses.contains(where: { $0.source.coveredMessageIDs.contains(message.id) }) { return .summarized }
        if session.contextChoices?.adopted[message.id] != nil { return .adopted }
        return .included
    }

    var canExclude: Bool { self != .currentQuestion }
    var english: String {
        switch self {
        case .currentQuestion: "Current question · still sent"
        case .excluded: "Excluded"
        case .summarized: "Replaced by reviewed summary"
        case .adopted: "Adopted"
        case .included: "Included"
        }
    }
    var chinese: String {
        switch self {
        case .currentQuestion: "本次问题，仍会发送"
        case .excluded: "已排除"
        case .summarized: "由已审核摘要代替"
        case .adopted: "已采用人工版本"
        case .included: "纳入"
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
    @ViewBuilder
    func chatMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        if let probe {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatLayoutSpace.name)) }
                action: { probe(id, $0) }
        } else { self }
    }
}

/// AppKit hiding retains the pane's editor identity while removing hidden views
/// from input and key-view navigation. Resizing an open pane never hides it.
struct ChatPaneHost<Content: View>: NSViewRepresentable {
    let content: Content
    let visible: Bool
    let identifier: String

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.setAccessibilityIdentifier(identifier)
        host.isHidden = !visible
        return host
    }
    func updateNSView(_ host: NSHostingView<Content>, context: Context) {
        host.rootView = content
        // Only an actual close/open changes native visibility. Hiding can release
        // the first responder; a layout change must not transiently hide an editor.
        if host.isHidden != !visible { host.isHidden = !visible }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<Content>, context: Context) -> CGSize? {
        .init(width: proposal.width ?? 240, height: proposal.height ?? 640)
    }
}

struct ChatScrollRestoration: Equatable {
    let ticket = UUID()
    let sessionID: UUID
    let followsBottom: Bool
    let anchor: UUID?

    func isCurrent(sessionID: UUID?, pending: Self?) -> Bool {
        sessionID == self.sessionID && pending?.ticket == ticket
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
    let onRetainTemporary: ((WorkflowAssetReference, Bool, UUID) async throws -> Void)?
    let onAssetsChanged: () -> Void
    let onSavedValue: ((WorkflowDatum, UUID) async throws -> Void)?
    let onResolveSharedAsset: ((UUID, UUID?, UUID) async throws -> (ProjectStore, WorkflowAssetReference, String))?

    @Environment(\.dLanguageStore) private var language
    @State private var search = ""
    @State private var showArchived = false
    @State private var showDeleted = false
    @State private var favoritesOnly = false
    @State private var selectedTag = ""
    @State private var searchJump: ChatSearchJump?
    @State private var inspectedAttemptID: UUID?
    @State private var showContextPreview = false
    @State private var lastBodyWidth: CGFloat = 0
    @State private var showSidebar = true
    @State private var showInspector = false
    @State private var sidebarWasPresented = false
    @State private var inspectorTab: ChatInspectorTab = .data
    @State private var sheets = ChatSheetQueue<ChatDetail>()
    @State private var followsBottom = true
    @State private var hasNewContent = false
    @State private var scrollStates: [UUID: ChatSessionScrollState] = [:]
    @State private var visibleMessageID: UUID?
    @State private var scrollRestoration: ChatScrollRestoration?
    @State private var issues: [UUID: String] = [:]
    @State private var globalIssue: String?
    @State private var newPresetName = ""
    @State private var filePanelBusy = false
    @State private var ocrImport = false
    private var layoutProbe: ((String, CGRect) -> Void)?

    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    init(chat: ChatController, model: WorkbenchModel,
         onChooseModel: @escaping () -> Void,
         onSavedAsset: @escaping (WorkflowAssetReference) -> Void,
         onRetainTemporary: ((WorkflowAssetReference, Bool, UUID) async throws -> Void)? = nil,
         onAssetsChanged: @escaping () -> Void,
         onSavedValue: ((WorkflowDatum, UUID) async throws -> Void)? = nil,
         onResolveSharedAsset: ((UUID, UUID?, UUID) async throws -> (ProjectStore, WorkflowAssetReference, String))? = nil,
         initialInspectorVisible: Bool = false,
         initialSettingsVisible: Bool = false,
         initialContextPreviewVisible: Bool = false,
         initialInspectedAttemptID: UUID? = nil,
         initiallyFollowsBottom: Bool = true,
         initiallyHasNewContent: Bool = false) {
        self.chat = chat; self.model = model; self.onChooseModel = onChooseModel
        self.onSavedAsset = onSavedAsset; self.onRetainTemporary = onRetainTemporary; self.onAssetsChanged = onAssetsChanged; self.onSavedValue = onSavedValue
        self.onResolveSharedAsset = onResolveSharedAsset
        _showInspector = State(initialValue: initialInspectorVisible)
        _inspectorTab = State(initialValue: initialSettingsVisible ? .settings : .data)
        _showContextPreview = State(initialValue: initialContextPreviewVisible)
        _inspectedAttemptID = State(initialValue: initialInspectedAttemptID)
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
        ChatContextSessionList.visible(chat.state.sessions, archived: showArchived, deleted: showDeleted,
                                       favoritesOnly: favoritesOnly, tag: selectedTag)
    }
    private var searchHits: [ChatSearchHit] {
        guard !showDeleted else { return [] }
        return ChatHistorySearch.matches(in: visibleSessions, query: search)
    }
    private var allTags: [String] {
        Array(Set(chat.state.sessions.filter { ($0.contextChoices?.deletedAt != nil) == showDeleted }
            .flatMap { $0.contextChoices?.tags ?? [] })).sorted()
    }

    var body: some View {
        GeometryReader { geometry in
            let sidebarShown = ChatPresentationLayout.showsSidebar(width: geometry.size.width, requested: showSidebar)
            let inspectorShown = ChatPresentationLayout.showsInspector(width: geometry.size.width,
                requested: showInspector, sidebar: sidebarShown)
            let inspectorInline = inspectorShown && sheets.narrowPanel != .inspector
            let sidebarInline = sidebarShown && sheets.narrowPanel != .sessions
            // An already open pane remains visible as an overlay while the width
            // changes. Do not briefly hide its native editor before onChange runs.
            let sidebarVisible = showSidebar && (sidebarInline || sidebarWasPresented || sheets.narrowPanel == .sessions)
            let inspectorVisible = showInspector
            let sidebarPaneWidth = min(ChatPresentationLayout.sidebarWidth, geometry.size.width)
            let inspectorPaneWidth = min(ChatPresentationLayout.inspectorWidth, geometry.size.width)
            ZStack(alignment: .topLeading) {
                Group {
                    if !chat.isLoaded {
                        ContentUnavailableView(label("loadFailed", "聊天记录不可用"), systemImage: "exclamationmark.triangle",
                            description: Text(chat.error.map { ChatErrorText.display($0, language: language) } ?? label("loading", "正在读取聊天记录…")))
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
                ChatPaneHost(content: sidebar.background(.background).disabled(!sidebarVisible)
                    .environment(\.dLanguageStore, language), visible: sidebarVisible,
                    identifier: "chat-sessions-host")
                    .frame(width: sidebarPaneWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) { if sidebarInline { Divider() } }
                    .allowsHitTesting(sidebarVisible)
                    .accessibilityHidden(!sidebarVisible)
                    .chatMeasured("sessions-pane", probe: layoutProbe)
                if let session {
                    ChatPaneHost(content: inspector(session).background(.background).disabled(!inspectorVisible)
                        .environment(\.dLanguageStore, language), visible: inspectorVisible,
                        identifier: "chat-inspector-host")
                        .frame(width: inspectorPaneWidth)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .leading) { if inspectorInline { Divider() } }
                        .chatMeasured("inspector-pane", probe: layoutProbe)
                        .allowsHitTesting(inspectorVisible)
                        .accessibilityHidden(!inspectorVisible)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .clipped()
            .coordinateSpace(name: ChatLayoutSpace.name)
            .onAppear {
                sidebarWasPresented = sidebarVisible
                lastBodyWidth = geometry.size.width
            }
            .onChange(of: geometry.size.width) { oldWidth, width in
                lastBodyWidth = width
                if sidebarShown { sidebarWasPresented = true }
                if let narrowPanel = sheets.narrowPanel, ChatPresentationLayout.dismissesNarrowPanel(narrowPanel,
                    width: width, sidebarRequested: showSidebar, inspectorRequested: showInspector) {
                    closeNarrowPanel(keepPreference: true)
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
        .environment(\.chatDisplayPreferences, model.chatDisplaySettings.preferences)
        .preferredColorScheme(model.chatDisplaySettings.preferences.preferredColorScheme)
        .task {
            let preferences = model.chatDisplaySettings
            chat.onPersistedTerminal = { _ in
                if preferences.preferences.endSound == true { NSSound(named: "Glass")?.play() }
            }
            if !chat.isLoaded { await chat.load() }
        }
        .sheet(item: Binding(get: { sheets.detail }, set: { sheets.detail = $0 })) { item in
            switch item {
            case .edit(let edit): editSheet(edit)
            case .knowledgeDirectory(let owner, let url, let inventory, let scoped):
                ChatKnowledgeDirectorySheet(inventory: inventory, wording: { en, zh in newLabel(en, english: en, chinese: zh) },
                    importEntries: { entries in
                        guard chat.state.sessions.contains(where: { $0.id == owner }) else { throw WorkflowIssue("原会话已离开。") }
                        await importURLs(entries.map(\.url), sessionID: owner, knowledge: true, directoryEntries: entries)
                        if let issue = issues[owner] { throw WorkflowIssue(issue) }
                    }, close: { sheets.detail = nil })
                    .onDisappear { if scoped { url.stopAccessingSecurityScopedResource() } }
            case .artifact(let content):
                ChatArtifactEditor(content: content, mermaidDocument: ChatMermaidDocument.document,
                    onSave: { value in
                        let saved = try await chat.saveArtifact(value)
                        onAssetsChanged(); return saved
                    }, onClose: { sheets.detail = nil })

            case .fields(let choices):
                ChatAnswerFieldSheet(choices: choices, wording: { en, zh in newLabel(en, english: en, chinese: zh) },
                    onSave: { field, publication, useInWorkflow in
                        let activity = try chat.beginExternalActivity(); defer { chat.endExternalActivity(activity) }
                        let envelope = try await chat.saveAnswerField(field, assetID: publication)
                        try Task.checkCancellation()
                        if chat.isTemporary {
                            guard let source = envelope.fields?["source"]?.assetReferences.first, let onRetainTemporary else { throw WorkflowIssue("长期保存入口不可用。") }
                            if useInWorkflow, let onSavedValue { try await onSavedValue(envelope, activity) }
                            else { try await onRetainTemporary(source, false, activity) }
                        } else {
                            onAssetsChanged()
                            if useInWorkflow, let onSavedValue { try await onSavedValue(envelope, activity) }
                        }
                    }, onClose: { sheets.detail = nil })
            case .quote(let sessionID, let source):
                ChatQuoteSheet(chat: chat, sessionID: sessionID, source: source,
                    onSaved: { onAssetsChanged() }, onKeep: { reference, workflow, activity in
                        if chat.isTemporary {
                            guard let onRetainTemporary else { throw WorkflowIssue("长期保存入口不可用。") }
                            try await onRetainTemporary(reference, workflow, activity)
                        } else {
                            onAssetsChanged()
                            if workflow, let onSavedValue { try await onSavedValue(.asset(reference), activity) }
                        }
                    }, onClose: { sheets.detail = nil })
            case .comparison(let sessionID, let attemptID):
                ScrollView {
                    ChatComparisonPanel(chat: chat, sessionID: sessionID, sourceAttemptID: attemptID,
                        onClose: { sheets.detail = nil })
                }.frame(minWidth: 700, idealWidth: 900, minHeight: 420)
            case .presetImport(let presets, let data):
                VStack(alignment: .leading, spacing: 12) {
                    Text(newLabel("importPresetsTitle", english: "Import preset copies", chinese: "导入预设副本")).font(.headline)
                    Text(newLabel("importPresetsNote", english: "This creates new presets. It does not change any conversation or run a model.",
                        chinese: "将创建新预设，不改变现有会话，也不会运行模型。"))
                    ScrollView {
                        ForEach(presets) { item in
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text(item.prompt).textSelection(.enabled)
                                if let configuration = item.configuration { Text(configuration.operationID).font(.caption) }
                            }.padding(.vertical, 6)
                        }
                    }
                    HStack {
                        Button(label("cancel", "取消")) { sheets.detail = nil }
                        Button(newLabel("importCopies", english: "Import copies", chinese: "导入副本")) {
                            perform(sessionID: chat.state.selectedSessionID) { try chat.importPresets(data); sheets.detail = nil }
                        }
                    }
                }.padding(20).frame(minWidth: 560, minHeight: 360)
            case .conversationImport(let data, let title):
                ChatConversationImportSheet(data: data, title: title,
                    onCancel: { sheets.detail = nil }, onAccept: { index, chosenTitle, allowingLosses, importID in
                        _ = try await chat.importConversation(data, title: chosenTitle, allowingLosses: allowingLosses,
                                                              importID: importID, selectedConversationIndex: index)
                        sheets.detail = nil
                    })
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
                    sidebarWasPresented = true
                    sheets.openNarrow(.sessions)
                } else {
                    showSidebar.toggle()
                    if showSidebar { sidebarWasPresented = true }
                }
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
                Button(label("close", "关闭"), systemImage: "xmark") {
                    showSidebar = false
                    if sheets.narrowPanel == .sessions { closeNarrowPanel() }
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("chat-sessions-close")
            }
            Button(newLabel("importConversation", english: "Import conversation…", chinese: "导入会话…")) { Task { await importConversation() } }
                .disabled(filePanelBusy || !chat.isLoaded || chat.saveIssue != nil)
            TextField(newLabel("lexicalSearch", english: "Lexical search", chinese: "词法搜索"), text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chat-history-search")
                .disabled(showDeleted)
            HStack {
                Toggle(label("archived", "已归档"), isOn: $showArchived)
                Toggle(newLabel("deleted", english: "Deleted", chinese: "已删除"), isOn: $showDeleted)
                    .onChange(of: showDeleted) { _, _ in selectedTag = "" }
            }.controlSize(.small)
            HStack {
                Toggle(newLabel("favoritesOnly", english: "Favorites", chinese: "收藏"), isOn: $favoritesOnly)
                Picker(newLabel("tagFilter", english: "Tag", chinese: "标签"), selection: $selectedTag) {
                    Text(newLabel("allTags", english: "All tags", chinese: "全部标签")).tag("")
                    ForEach(allTags, id: \.self) { tag in Text(tag).tag(tag) }
                }.labelsHidden().accessibilityLabel(newLabel("tagFilter", english: "Filter by tag", chinese: "按标签筛选"))
            }.controlSize(.small)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !search.isEmpty && !showDeleted {
                        Text(newLabel("lexicalResults", english: "Lexical matches in stored messages", chinese: "已保存消息的词法命中"))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(searchHits.indices, id: \.self) { index in
                            let hit = searchHits[index]
                            Button {
                                do {
                                    if let currentID = chat.state.selectedSessionID { saveScrollState(for: currentID) }
                                    searchJump = try ChatContextCommands.open(hit, in: chat)
                                    closeNarrowPanel()
                                } catch { report(error.localizedDescription, for: hit.sessionID) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chat.state.sessions.first(where: { $0.id == hit.sessionID })?.title ?? "")
                                        .font(.caption).bold().lineLimit(1)
                                    Text(searchExcerpt(hit)).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(newLabel("searchResult", english: "Open search result: ", chinese: "打开搜索结果：") + searchExcerpt(hit))
                                .accessibilityIdentifier("chat-search-hit-\(hit.sessionID.uuidString)-\(hit.messageID?.uuidString ?? "title")-\(index)")
                        }
                    } else { ForEach(visibleSessions) { item in
                        HStack(spacing: 6) {
                            Button {
                                do {
                                    if let currentID = chat.state.selectedSessionID { saveScrollState(for: currentID) }
                                    try chat.selectSession(item.id)
                                    closeNarrowPanel()
                                } catch { report(error.localizedDescription, for: item.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        if item.contextChoices?.pinned == true { Image(systemName: "pin.fill") }
                                        Text(item.title).lineLimit(2)
                                    }
                                    Text("\(item.messages.count) " + label("messages", "条消息"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let tags = item.contextChoices?.tags, !tags.isEmpty {
                                        Text(tags.joined(separator: " · ")).font(.caption2)
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            ChatActionMenu(title: newLabel("sessionActionsShort", english: "Actions", chinese: "操作"),
                                accessibilityIdentifier: "chat-session-actions-" + item.id.uuidString,
                                items: sessionMenuItems(item)).fixedSize()
                        }
                        .padding(9)
                        .background(chat.state.selectedSessionID == item.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    } }
                }
            }
        }.padding(14)
    }

    private func searchExcerpt(_ hit: ChatSearchHit) -> String {
        guard let range = Range(hit.range, in: hit.sourceText) else { return String(hit.sourceText.prefix(80)) }
        let start = hit.sourceText.index(range.lowerBound, offsetBy: -35, limitedBy: hit.sourceText.startIndex) ?? hit.sourceText.startIndex
        let end = hit.sourceText.index(range.upperBound, offsetBy: 45, limitedBy: hit.sourceText.endIndex) ?? hit.sourceText.endIndex
        return String(hit.sourceText[start..<end]).replacingOccurrences(of: "\n", with: " ")
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
                    if session.contextChoices?.deletedAt != nil {
                        Text(newLabel("deletedReadOnly", english: "Deleted · restore from the conversation list",
                            chinese: "已删除 · 请在对话列表恢复"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                    .lineLimit(1).disabled(session.contextChoices?.deletedAt != nil)
                if !session.messages.isEmpty {
                    ChatActionMenu(title: label("paths", "路径"), accessibilityIdentifier: "chat-paths",
                        items: leaves.map { leaf in
                            .init(id: leaf.id.uuidString, title: branchSummary(leaf), selected: leaf.id == session.selectedLeafID) {
                                perform(sessionID: session.id) { try chat.selectLeaf(leaf.id, sessionID: session.id) }
                            }
                        }).fixedSize()
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
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
              ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let notes = session.importLossNotes, !notes.isEmpty {
                            DisclosureGroup(newLabel("importLosses", english: "Import mapping notes", chinese: "导入映射记录")) {
                                ForEach(notes.indices, id: \.self) { Text(notes[$0]).font(.caption).textSelection(.enabled) }
                            }
                        }
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
                        .frame(maxWidth: CGFloat(model.chatDisplaySettings.preferences.transcriptWidth))
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
                          scrollRestoration?.sessionID != session.id else { return }
                    followsBottom = ChatScrollPosition.followsBottom(previous: previous, current: current,
                        wasFollowing: followsBottom)
                    if followsBottom { hasNewContent = false }
                    saveScrollState(for: session.id)
                }
                .onChange(of: visibleMessageID) { _, _ in
                    if chat.state.selectedSessionID == session.id, scrollRestoration?.sessionID != session.id {
                        saveScrollState(for: session.id)
                    }
                }
                .onChange(of: transcriptRevision(session)) { previous, _ in
                    guard previous.hasPrefix(session.id.uuidString + ":"),
                          scrollRestoration?.sessionID != session.id else { return }
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
                    let restore = ChatScrollRestoration(sessionID: newID,
                        followsBottom: followsBottom, anchor: restored?.anchor)
                    scrollRestoration = restore
                    Task { @MainActor in
                        await Task.yield()
                        guard restore.isCurrent(sessionID: chat.state.selectedSessionID,
                                                pending: scrollRestoration),
                              searchJump?.sessionID != newID else { return }
                        if restore.followsBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        else if let anchor = restore.anchor { proxy.scrollTo(anchor, anchor: .top) }
                        scrollRestoration = nil
                    }
                }
                .onAppear {
                    if let jump = searchJump, jump.sessionID == session.id {
                        Task { @MainActor in
                            await Task.yield()
                            guard searchJump == jump, chat.state.selectedSessionID == jump.sessionID else { return }
                            followsBottom = false; hasNewContent = false
                            visibleMessageID = jump.messageID
                            proxy.scrollTo(jump.messageID, anchor: .center)
                            saveScrollState(for: session.id)
                            scrollRestoration = nil
                            searchJump = nil
                        }
                        return
                    }
                    if let saved = scrollStates[session.id] {
                        followsBottom = saved.followsBottom
                        hasNewContent = saved.hasNewContent
                        visibleMessageID = saved.anchor
                        if saved.followsBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        else if let anchor = saved.anchor { proxy.scrollTo(anchor, anchor: .top) }
                    } else if followsBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onChange(of: searchJump) { _, jump in
                    guard let jump, jump.sessionID == session.id,
                          chat.state.selectedSessionID == jump.sessionID else { return }
                    Task { @MainActor in
                        await Task.yield()
                        guard searchJump == jump, chat.state.selectedSessionID == jump.sessionID else { return }
                        followsBottom = false; hasNewContent = false
                        visibleMessageID = jump.messageID
                        proxy.scrollTo(jump.messageID, anchor: .center)
                        saveScrollState(for: session.id)
                        scrollRestoration = nil
                        searchJump = nil
                    }
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

    private func openDataInspector(attemptID: UUID? = nil, preview: Bool = false) {
        inspectedAttemptID = attemptID
        showContextPreview = preview
        inspectorTab = .data
        showInspector = true
        let sidebar = ChatPresentationLayout.showsSidebar(width: lastBodyWidth, requested: showSidebar)
        if !ChatPresentationLayout.showsInspector(width: lastBodyWidth, requested: true, sidebar: sidebar) {
            sheets.openNarrow(.inspector)
        }
    }

    private func changeMessageChoice(session: ChatSession,
                                     mutate: (inout ChatContextChoices) -> Void) {
        perform(sessionID: session.id) {
            guard chat.state.selectedSessionID == session.id else { throw WorkflowIssue("请返回原对话后再修改消息。") }
            guard chat.selectedSession?.contextChoices?.deletedAt == nil else { throw WorkflowIssue("请先恢复已删除的对话。") }
            try ChatContextCommands.choices(session, mutate: mutate, in: chat)
        }
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
                            if let notes = session.importLossNotes, !notes.isEmpty {
                            DisclosureGroup(newLabel("importLosses", english: "Import mapping notes", chinese: "导入映射记录")) {
                                ForEach(notes.indices, id: \.self) { Text(notes[$0]).font(.caption).textSelection(.enabled) }
                            }
                        }
                        if session.originSessionID != nil {
                                Text(label("forkOrigin", "此对话从另一条路径分叉；原对话仍保留。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button(newLabel("contextPreview", english: "Preview next context", chinese: "预览下次上下文")) {
                                showContextPreview.toggle(); inspectedAttemptID = nil
                            }.accessibilityIdentifier("chat-context-preview-toggle")
                            if showContextPreview { contextPreviewPanel(session) }
                            if let attemptID = inspectedAttemptID,
                               let attempt = session.attempts.first(where: { $0.id == attemptID }) {
                                requestInspectionPanel(attempt)
                            }
                            ChatKnowledgePanel(chat: chat, session: session, quote: { id in
                            perform(sessionID: session.id) { present(.quote(session.id, try chat.quoteSource(kind: .document, id: id, sessionID: session.id))) }
                        },
                                importDocuments: { Task { await chooseAttachments(for: session.id, knowledge: true) } },
                                importDirectory: { Task { await chooseKnowledgeDirectory(for: session.id) } },
                                preview: { present(.preview($0)) },
                                wording: { english, chinese in
                                    language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english
                                }).id(session.id.uuidString + ":knowledge")
                            ChatToolsPanel(chat: chat, session: session, chooseSearchCredential: { provider in
                                Task { await chooseSearchCredential(provider, sessionID: session.id) }
                            }, openArtifact: { present(.artifact($0)) }, wording: { english, chinese in
                                language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english
                            }).id(session.id.uuidString + ":tools")
                            ChatMCPPanel(chat: chat, session: session, wording: { english, chinese in
                                language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english
                            }).id(session.id.uuidString + ":mcp")
                            Toggle(newLabel("importOCR", english: "Use on-device OCR for scanned PDF pages on import",
                                chinese: "导入扫描PDF时使用本地OCR"), isOn: $ocrImport)
                                .font(.caption)
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
                            Button(newLabel("newArtifact", english: "New editable artifact", chinese: "新建可编辑成果")) {
                                present(.artifact(.init(sessionID: session.id, title: newLabel("untitledArtifact", english: "Untitled", chinese: "未命名"), kind: .markdown, text: "")))
                            }
                            ForEach(session.artifacts ?? [], id: \.output) { value in
                                HStack {
                                    Button("\(value.title) · v\(value.revision)") { present(.artifact(value)) }
                                    if let output = value.output {
                                        Button(newLabel("useWorkflow", english: "Use in workflow", chinese: "用于工作流")) { onSavedAsset(output) }
                                    }
                                }
                            }
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

    @ViewBuilder private func contextPreviewPanel(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(newLabel("contextPreviewTitle", english: "Next request preview", chinese: "下次请求预览"))
                .font(.subheadline.bold())
            Text(newLabel("contextPreviewNote", english: "Current path and draft only. This preview does not send or change them.",
                chinese: "仅显示当前路径与草稿；预览不会发送或修改它们。"))
                .font(.caption).foregroundStyle(.secondary)
            let result = Result { try chat.contextPreview(sessionID: session.id) }
            let summaries = (try? result.get().summaryUses) ?? []
            ForEach(chat.selectedPath) { message in
                let status = ChatContextRowStatus.forMessage(message, in: session, summaryUses: summaries)
                Text(newLabel("contextRow.\(status)", english: status.english, chinese: status.chinese) +
                     " · " + branchSummary(message))
                    .font(.caption).lineLimit(2)
                    .chatMeasured("context-row-\(message.id.uuidString)", probe: layoutProbe)
                    .accessibilityIdentifier("chat-context-row-\(message.id.uuidString)")
            }
            switch result {
            case .success(let plan):
                Text(newLabel("conservativeBudget", english: "Conservative input estimate (not exact tokenization): ",
                    chinese: "保守输入估计（非精确分词）：") + String(plan.estimatedTokens))
                    .font(.caption)
                if let limit = session.configuration?.parameters["maximumPromptTokens"]?.integer {
                    Text(newLabel("configuredLimit", english: "Configured input limit: ", chinese: "所选输入上限：") + String(limit))
                        .font(.caption)
                    if plan.estimatedTokens > limit {
                        Text(newLabel("overEstimate", english: "Estimate exceeds the configured limit.",
                            chinese: "估计值超过所选上限。"))
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Text(newLabel("contextMedia", english: "Images: ", chinese: "图像：") + String(plan.images.count) +
                     newLabel("contextVideos", english: " · Videos: ", chinese: " · 视频：") + String(plan.videos.count))
                    .font(.caption)
            case .failure(let error):
                Text(ChatErrorText.display(error.localizedDescription, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("chat-context-preview-error")
            }
        }.accessibilityIdentifier("chat-context-preview")
            .chatMeasured("context-preview-\(session.id.uuidString)", probe: layoutProbe)
    }

    private func requestInspectionPanel(_ attempt: ChatAttempt) -> some View {
        let snapshot = ChatRequestInspection(attempt: attempt)
        return VStack(alignment: .leading, spacing: 8) {
            Text(newLabel("frozenRequest", english: "Frozen request", chinese: "冻结请求"))
                .font(.subheadline.bold())
            Text(newLabel("frozenRequestNote", english: "Saved attempt only. The JSON omits free text and credentials.",
                chinese: "仅来自已保存的尝试；JSON 省略自由文本与凭据。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(snapshot.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(.caption.bold())
                    ForEach(section.fields) { field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label).font(.caption).foregroundStyle(.secondary)
                            Text(field.value).font(.caption.monospaced()).textSelection(.enabled)
                        }.chatMeasured("request-field-\(section.id)-\(field.id)-\(attempt.id.uuidString)", probe: layoutProbe)
                    }
                }
            }
            Button(newLabel("copyRedactedJSON", english: "Copy redacted JSON", chinese: "复制脱敏 JSON")) {
                copy(snapshot.redactedJSON)
            }.accessibilityIdentifier("chat-copy-request-json")
            ChatRunFeedbackView(chat: chat, attempt: attempt).id(attempt.id)
            Text(snapshot.redactedJSON).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("chat-request-json")
        }.accessibilityIdentifier("chat-request-inspection")
            .chatMeasured("request-inspection-\(attempt.id.uuidString)", probe: layoutProbe)
    }

    private func sessionMenuItems(_ item: ChatSession) -> [ChatActionMenuItem] {
        var result: [ChatActionMenuItem] = [
            .init(id: "rename", title: label("rename", "重命名")) {
                present(.edit(ChatEdit(kind: .rename, sessionID: item.id, messageID: nil, text: item.title)))
            },
            .init(id: "pin", title: item.contextChoices?.pinned == true
                ? newLabel("unpin", english: "Unpin", chinese: "取消置顶") : newLabel("pin", english: "Pin", chinese: "置顶")) {
                perform(sessionID: item.id) { try ChatContextCommands.choices(item, mutate: { $0.pinned.toggle() }, in: chat) }
            },
            .init(id: "tags", title: newLabel("editTags", english: "Edit tags…", chinese: "编辑标签…")) {
                present(.edit(ChatEdit(kind: .tags, sessionID: item.id, messageID: nil, text: (item.contextChoices?.tags ?? []).joined(separator: "\n"))))
            },
            .init(id: "archive", title: item.archived ? newLabel("restoreArchive", english: "Restore from archive", chinese: "从归档恢复") : label("archive", "归档"), enabled: chat.activeSessionID != item.id) {
                perform(sessionID: item.id) { try chat.setArchived(!item.archived, sessionID: item.id) }
            },
            .init(id: "delete", title: item.contextChoices?.deletedAt == nil ? newLabel("softDelete", english: "Move to Deleted", chinese: "移到已删除") : newLabel("restoreDeleted", english: "Restore conversation", chinese: "恢复对话"), enabled: chat.activeSessionID != item.id) {
                perform(sessionID: item.id) { try chat.setDeleted(item.contextChoices?.deletedAt == nil, sessionID: item.id) }
            }
        ]
        if item.selectedLeafID != nil {
            result += [
                .init(id: "copy", title: label("copyPath", "复制所选路径")) { perform(sessionID: item.id) { copy(try chat.exportSelectedPath(sessionID: item.id, markdown: false)) } },
                .init(id: "markdown", title: label("exportMarkdown", "导出 Markdown")) { Task { await export(sessionID: item.id, markdown: true) } },
                .init(id: "text", title: label("exportPlain", "导出纯文字")) { Task { await export(sessionID: item.id, markdown: false) } },
                .init(id: "html", title: newLabel("exportHTML", english: "Export local HTML", chinese: "导出本地 HTML")) { Task { await export(sessionID: item.id, markdown: false, html: true) } }
            ]
        }
        if !chat.isTemporary {
            result.append(.init(id: "sessionPackage", title: newLabel("exportSessionPackage", english: "Export recoverable session…", chinese: "导出可恢复会话包…"), enabled: !chat.isBusy) {
                Task { await exportSessionPackage(sessionID: item.id) }
            })
        }
        return result
    }

    private func messageMenuItems(_ message: ChatMessage, session: ChatSession, attempt: ChatAttempt?) -> [ChatActionMenuItem] {
        let choices = session.contextChoices
        let favorite = choices?.favoriteMessageIDs.contains(message.id) == true
        let excluded = choices?.excludedMessageIDs.contains(message.id) == true
        let revisions = choices?.revisions.filter { $0.messageID == message.id } ?? []
        let adoptedID = revisions.first { choices?.adoptedRevisionIDs.contains($0.id) == true }?.id
        let answerText = attempt?.response?.finalText ?? attempt?.rawText ?? message.text
        let canAdopt = session.contextChoices?.deletedAt == nil && ChatContextCommands.canAdopt(attempt, in: chat)
        var result: [ChatActionMenuItem] = [
            .init(id: "favorite", title: favorite ? newLabel("unfavorite", english: "Remove favorite", chinese: "取消收藏") : newLabel("favorite", english: "Favorite", chinese: "收藏")) {
                changeMessageChoice(session: session) { value in
                    if value.favoriteMessageIDs.contains(message.id) { value.favoriteMessageIDs.removeAll { $0 == message.id } }
                    else { value.favoriteMessageIDs.append(message.id) }
                }
            }
        ]
        result.append(.init(id: "quote", title: newLabel("quoteSelection", english: "Quote a selection…", chinese: "选择片段引用…"), enabled: attempt?.status != .running && attempt?.status != .saving) {
            perform(sessionID: session.id) { present(.quote(session.id, try chat.quoteSource(kind: .message, id: message.id, sessionID: session.id))) }
        })
        if ChatContextRowStatus.forMessage(message, in: session).canExclude {
            result.append(.init(id: "context", title: excluded ? newLabel("includeContext", english: "Include in context", chinese: "回纳上下文") : newLabel("excludeContext", english: "Exclude from context", chinese: "排除上下文")) {
                changeMessageChoice(session: session) { value in
                    if value.excludedMessageIDs.contains(message.id) { value.excludedMessageIDs.removeAll { $0 == message.id } }
                    else { value.excludedMessageIDs.append(message.id) }
                }
            })
        }
        if message.role == .user {
            result.append(.init(id: "generate", title: label("generateReply", "生成回复"), enabled: canRun(session)) {
                Task { await run(sessionID: session.id) { try await chat.regenerate(message.id, sessionID: session.id) } }
            })
        } else if let parent = message.parentID {
            result.append(.init(id: "new-candidate", title: label("newCandidate", "生成新候选（新随机种子）"), enabled: canRun(session)) {
                Task { await run(sessionID: session.id) { try await chat.regenerate(parent, sessionID: session.id) } }
            })
            if let attempt {
                result += [
                    .init(id: "inspect", title: newLabel("inspectRequest", english: "Inspect frozen request", chinese: "检查冻结请求")) { openDataInspector(attemptID: attempt.id) },
                    .init(id: "compare", title: newLabel("compareAnswers", english: "Compare answers…", chinese: "比较回答…")) { present(.comparison(session.id, attempt.id)) },
                    .init(id: "reproduce", title: label("replayRequest", "按原请求与种子重现"), enabled: ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: chat.isRunning, hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil)) {
                        Task { await run(sessionID: session.id) { try await chat.reproduce(attempt.id, sessionID: session.id) } }
                    }
                ]
            }
        }
        if message.role == .assistant {
            result += [
                .init(id: "speak", title: newLabel("readAnswer", english: "Read aloud with system voice", chinese: "使用系统声音朗读"), enabled: chat.speechPlaybackState == .idle) {
                    perform(sessionID: session.id) { try chat.speech.speak(answerText) }
                },
                .init(id: "adopt", title: newLabel("editAdopt", english: "Edit and adopt…", chinese: "编辑并采用…"), enabled: canAdopt) {
                    present(.edit(ChatEdit(kind: .answer, sessionID: session.id, messageID: message.id, text: answerText)))
                }
            ]
            if let attempt, attempt.status != .completed {
                result.append(.init(id: "adopt-partial", title: newLabel("adoptPartial", english: "Adopt current partial answer", chinese: "采用当前部分回答"), enabled: canAdopt) {
                    perform(sessionID: session.id) { try ChatContextCommands.adopt(answerText, messageID: message.id, sessionID: session.id, in: chat) }
                })
            }
            if !revisions.isEmpty {
                var versions: [ChatActionMenuItem] = [.init(id: "original", title: newLabel("originalOutput", english: "Original model output", chinese: "原始模型输出"), selected: adoptedID == nil) {
                    perform(sessionID: session.id) { try ChatContextCommands.selectVersion(nil, messageID: message.id, sessionID: session.id, in: chat) }
                }]
                versions += revisions.enumerated().map { index, revision in
                    .init(id: revision.id.uuidString, title: newLabel("manualVersion", english: "Manual version ", chinese: "人工版本 ") + String(index + 1) + " · " + String(revision.text.prefix(28)), selected: adoptedID == revision.id) {
                        perform(sessionID: session.id) { try ChatContextCommands.selectVersion(revision.id, messageID: message.id, sessionID: session.id, in: chat) }
                    }
                }
                result.append(.init(id: "versions", title: newLabel("answerVersions", english: "Answer versions", chinese: "回答版本"), enabled: canAdopt, children: versions))
            }
        }
        result.append(.init(id: "fork", title: label("forkHere", "从这里分叉")) {
            perform(sessionID: session.id) { _ = try chat.forkSession(session.id, leafID: message.id) }
        })
        if session.selectedAnswer(messageID: message.id) != nil {
            result += [
                .init(id: "artifact", title: newLabel("editArtifact", english: "Create editable artifact…", chinese: "建立可编辑成果…")) {
                    Task { @MainActor in
                        do {
                            let content = try await chat.artifactFromAnswer(message.id, sessionID: session.id)
                            onAssetsChanged()
                            guard chat.state.selectedSessionID == session.id else { return }
                            present(.artifact(content))
                        } catch { issues[session.id] = error.localizedDescription }
                    }
                },
                .init(id: "save", title: label("saveAsset", "保存回答为素材")) { Task { await saveFinal(message.id, sessionID: session.id, useInWorkflow: false) } },
                .init(id: "workflow", title: label("useWorkflow", "用于工作流")) { Task { await saveFinal(message.id, sessionID: session.id, useInWorkflow: true) } }
            ]
        }
        if session.selectedAnswer(messageID: message.id)?.attempt?.outputFormat?.kind == .schema {
            result.append(.init(id: "fields", title: newLabel("answerFields", english: "Save / hand off structured fields…", chinese: "保存／交接结构化字段…")) {
                perform(sessionID: session.id) { present(.fields(try ChatAnswerField.choices(session: session, messageID: message.id))) }
            })
        }
        return result
    }

    private func messageCard(_ message: ChatMessage, session: ChatSession,
                             siblings: [ChatMessage], attempt: ChatAttempt?) -> some View {
        let choices = session.contextChoices
        let favorite = choices?.favoriteMessageIDs.contains(message.id) == true
        let excluded = choices?.excludedMessageIDs.contains(message.id) == true
        let revisions = choices?.revisions.filter { $0.messageID == message.id } ?? []
        let adoptedID = revisions.first { choices?.adoptedRevisionIDs.contains($0.id) == true }?.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.role == .user ? label("you", "你") : label("assistant", "助手")) .font(.headline)
                if siblings.count > 1 {
                    ChatActionMenu(title: label("branch", "分支") + " \((siblings.firstIndex(where: { $0.id == message.id }) ?? 0) + 1)/\(siblings.count)",
                        accessibilityIdentifier: "chat-branch-" + message.id.uuidString,
                        items: siblings.enumerated().map { index, sibling in
                            .init(id: sibling.id.uuidString, title: "\(index + 1) · " + branchSummary(sibling), selected: sibling.id == message.id) {
                                perform(sessionID: session.id) { try chat.selectLeaf(sibling.id, sessionID: session.id) }
                            }
                        }).fixedSize().chatMeasured("branch-menu-\(message.id.uuidString)", probe: layoutProbe)
                }
                Spacer()
                Button(label("copy", "复制")) {
                    copy(attempt?.response?.finalText ?? attempt?.rawText ?? message.text)
                }
                if message.role == .user {
                    Button(label("edit", "编辑")) {
                        present(.edit(ChatEdit(kind: .message, sessionID: session.id, messageID: message.id, text: message.text)))
                    }.disabled(session.contextChoices?.deletedAt != nil)
                }
                ChatActionMenu(title: newLabel("messageActionsShort", english: "Actions", chinese: "操作"),
                    accessibilityIdentifier: "chat-message-actions-" + message.id.uuidString,
                    items: messageMenuItems(message, session: session, attempt: attempt)).fixedSize()
            }.font(.caption)
            ChatMessageContent(message: message, attempt: attempt, onPreview: { present(.preview($0)) })
            if let excerpts = message.knowledgeExcerpts, !excerpts.isEmpty {
                DisclosureGroup(newLabel("usedSources", english: "Source excerpts sent with this question", chinese: "本次问题使用的资料片段")) {
                    ForEach(excerpts) { excerpt in
                        VStack(alignment: .leading) {
                            Text(excerpt.name + " · " + excerpt.source.assetID.uuidString.prefix(8)).font(.caption.bold())
                            Text(excerpt.text).font(.caption).textSelection(.enabled)
                            Button(newLabel("sourceOriginal", english: "View original", chinese: "查看原件")) { present(.preview(excerpt.source)) }
                        }
                    }
                }
            }
            if let adopted = revisions.first(where: { $0.id == adoptedID }) {
                DisclosureGroup(newLabel("adoptedVersion", english: "Adopted manual version · original above preserved",
                    chinese: "已采用人工版本 · 上方原输出保留")) {
                    Text(adopted.text).textSelection(.enabled)
                }.font(.caption).accessibilityIdentifier("chat-adopted-version-\(message.id.uuidString)")
                    .chatMeasured("adopted-version-\(message.id.uuidString)", probe: layoutProbe)
            }
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
                    Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
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
                DisclosureGroup(newLabel("displaySettings", english: "Display and keyboard", chinese: "显示与键盘")) {
                    ChatDisplayPreferencesPanel(state: model.chatDisplaySettings)
                }
                Text(label("nextAnswer", "下一次回答设置")).font(.headline)
                Text(label("futureOnly", "更改只影响之后的生成。")) .font(.caption).foregroundStyle(.secondary)
                ChatOutputFormatPanel(chat: chat, sessionID: session.id).id(session.id.uuidString + ":output-format")
                Text(label("systemPrompt", "系统提示（默认空）")) .font(.subheadline)
                TextSourcesQuestionEditor(value: session.systemPrompt, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-system-\(session.id.uuidString)",
                    accessibilityLabel: label("systemPrompt", "系统提示（默认空）"),
                    onEdit: { value in perform(sessionID: session.id) { try chat.setSystemPrompt(value, sessionID: session.id) } })
                    .id(session.id.uuidString + ":system")
                    .frame(height: 90)
                VStack(alignment: .leading, spacing: 8) {
                    Button(label("clearSystem", "清空系统提示")) { perform(sessionID: session.id) { try chat.setSystemPrompt("", sessionID: session.id) } }
                    Divider()
                    Text(newLabel("newSessionDefault", english: "Default system prompt for new conversations",
                        chinese: "新会话默认系统提示")).font(.subheadline)
                    Text(newLabel("newSessionDefaultNote", english: "Saving this default does not change existing conversations.",
                        chinese: "保存默认值不会回写现有会话。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(newLabel("editDefaultSystem", english: "Edit default…", chinese: "编辑默认提示…")) {
                        present(.edit(ChatEdit(kind: .defaultSystem, sessionID: session.id,
                                               messageID: nil, text: chat.defaultSystemPrompt)))
                    }.accessibilityIdentifier("chat-edit-default-system")
                    Button(newLabel("clearDefaultSystem", english: "Clear default", chinese: "清空默认提示")) {
                        perform(sessionID: session.id) { try chat.setDefaultSystemPrompt("") }
                    }
                    Divider()
                    DisclosureGroup(newLabel("managePresets", english: "Presets", chinese: "预设")) {
                        ChatPresetsPanel(chat: chat, sessionID: session.id,
                            onImport: { Task { await importPresets() } },
                            onExport: { presets in Task { await exportPresets(presets, sessionID: session.id) } })
                            .id(session.id.uuidString + ":presets")
                    }

                }
                ChatAssistancePanel(chat: chat, session: session, wording: { english, chinese in
                    language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english
                }).id(session.id.uuidString + ":assistance")
                ChatMemoryPanel(chat: chat, session: session, wording: { english, chinese in
                    language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english
                }).id(session.id.uuidString + ":memory")
                if let node = session.configuration,
                   let definition = WorkflowRegistry.standard.definition(for: node) {
                    ForEach(definition.fields.filter { !["modelID", "task", "messagesJSON", "outputMode"].contains($0.id) }) { field in
                        QuickParameterField(ownerID: session.id.uuidString, operationID: node.operationID,
                            field: field, value: node.parameters[field.id] ?? field.defaultValue,
                            onChange: { value in changeParameter(field.id, value: value, node: node, sessionID: session.id) },
                            raw: chat.parameterText[session.id.uuidString + ":" + field.id],
                            onRaw: { raw in changeNumeric(field: field, raw: raw, node: node, sessionID: session.id) })
                    }
                    DisclosureGroup(newLabel("templatePreview", english: "Chat template preview", chinese: "聊天模板预览")) {
                        ChatTemplatePanel(chat: chat, sessionID: session.id).id(session.id.uuidString + ":template")
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
            TextSourcesQuestionEditor(value: session.draft, editEpoch: 0,
                isEditable: !session.archived && session.contextChoices?.deletedAt == nil,
                accessibilityIdentifier: "chat-draft-\(session.id.uuidString)",
                accessibilityLabel: newLabel("messageDraft", english: "Message draft", chinese: "待发送消息"),
                onEdit: { value in perform(sessionID: session.id) { try chat.updateDraft(value, sessionID: session.id) } },
                pointSize: CGFloat(model.chatDisplaySettings.preferences.textPointSize),
                sendsOnReturn: model.chatDisplaySettings.preferences.sendShortcut == .return,
                onSubmit: { submitFromComposer(session.id) })
                .id(session.id.uuidString + ":draft")
                .frame(minHeight: 80, idealHeight: 110)
            ChatSpeechPanel(chat: chat, project: model.projectSession, sessionID: session.id,
                onImportAudio: { locale in Task { await chooseTranscriptionFile(sessionID: session.id, locale: locale) } })
                .id(session.id.uuidString + ":speech")
            Text(model.chatDisplaySettings.preferences.sendShortcut == .return
                ? newLabel("enterSend", english: "Return sends; Shift–Return adds a line. Input method conversion takes priority.", chinese: "回车发送，Shift–回车换行；输入法选字优先。")
                : newLabel("commandSend", english: "Command–Return sends; Return adds a line. Drop files or paste attachments below.", chinese: "Command–回车发送，回车换行；可拖入文件或粘贴附件。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(label("attach", "添加附件…"), systemImage: "paperclip") {
                    Task { await chooseAttachments(for: session.id) }
                }.disabled(session.archived || session.contextChoices?.deletedAt != nil)
                Button(newLabel("pasteAttachments", english: "Paste attachments", chinese: "粘贴附件")) {
                    Task { await pasteAttachments(sessionID: session.id) }
                }.disabled(session.archived || session.contextChoices?.deletedAt != nil)
                Spacer()
                if chat.pendingSaveAttemptID != nil || chat.saveIssue != nil {
                    Button(label("retrySave", "重试保存（不重新生成）")) { Task { await chat.retrySave() } }
                        .disabled(chat.isRunning)
                }
                if chat.canStopGeneration {
                    Button(chat.isCancelling
                        ? newLabel("stopping", english: "Stopping…", chinese: "正在停止…")
                        : label("stop", "停止当前生成"), systemImage: "stop.fill") {
                        Task { await chat.cancel() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chat.isCancelling)
                    .accessibilityIdentifier("chat-stop")
                    .help(newLabel("stopHelp", english: "Stop generation and keep received text. Resources are released before the next request.",
                        chinese: "停止生成并保留已接收文字；资源释放后才能开始下一次。"))
                    .chatMeasured("composer-stop", probe: layoutProbe)
                } else {
                    Button(label("send", "发送")) { submitFromComposer(session.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ChatRunAdmission.allowsSend(session, isRunning: chat.isRunning,
                            hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil,
                            invalidFields: chat.invalidParameterFields))
                        .accessibilityIdentifier("chat-send")
                }
            }
            .dropDestination(for: WorkflowCanvasTransfer.self) { items, _ in
                let owner = session.id
                Task { await importSharedAssets(items, sessionID: owner) }
                return !items.isEmpty
            }
            if let issue = issues[session.id] {
                Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
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
        .frame(maxWidth: CGFloat(model.chatDisplaySettings.preferences.transcriptWidth))
        .frame(maxWidth: .infinity)
        .padding(16)
        .dropDestination(for: URL.self) { urls, _ in
            let owner = session.id
            Task { await importURLs(urls, sessionID: owner) }
            return !urls.isEmpty
        }
    }

    private func submitFromComposer(_ sessionID: UUID) {
        guard let session = chat.state.sessions.first(where: { $0.id == sessionID }),
              ChatRunAdmission.allowsSend(session, isRunning: chat.isRunning,
                hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil,
                invalidFields: chat.invalidParameterFields) else { return }
        Task { await run(sessionID: sessionID) { try await chat.send(sessionID: sessionID) } }
    }

    private func attachmentRow(_ item: ChatAttachment, removable: Bool, sessionID: UUID) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.reference.kind == .image ? "photo" : item.reference.kind == .video ? "film" : "doc.text")
            Text(item.name).lineLimit(1)
            Text(attachmentKind(item.reference.kind)).font(.caption).foregroundStyle(.secondary)
            Button(label("preview", "预览")) { present(.preview(item.reference)) }
            if removable {
                let items = chat.state.sessions.first(where: { $0.id == sessionID })?.attachments ?? []
                Button(newLabel("attachmentEarlier", english: "Earlier", chinese: "前移")) {
                    perform(sessionID: sessionID) { try chat.moveAttachment(item.id, by: -1, sessionID: sessionID) }
                }.disabled(items.first?.id == item.id)
                Button(newLabel("attachmentLater", english: "Later", chinese: "后移")) {
                    perform(sessionID: sessionID) { try chat.moveAttachment(item.id, by: 1, sessionID: sessionID) }
                }.disabled(items.last?.id == item.id)
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
        case .document: newLabel("kind.document", english: "Document", chinese: "文档")
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

    private func chooseSearchCredential(_ provider: ChatSearchProvider, sessionID: UUID) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = newLabel("searchKeyFile", english: "Choose your local API key file for \(provider.rawValue). The key is not copied into the project.",
                                 chinese: "选择 \(provider.rawValue) 的本地 API 密钥文件；密钥不会复制到项目中。")
        guard await panel.begin() == .OK, let url = panel.url, owner === chat, store === chat.store,
              chat.state.sessions.contains(where: { $0.id == sessionID }) else { return }
        do { try chat.configureSearchCredential(url, provider: provider); report(nil, for: sessionID) }
        catch { report(error.localizedDescription, for: sessionID) }
    }

    private func chooseKnowledgeDirectory(for sessionID: UUID) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, owner === chat, store === chat.store else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let inspection = Task.detached(priority: .userInitiated) { try ChatKnowledgeDirectoryInventory.inspect(url) }
            let inventory = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
            guard owner === chat, store === chat.store, chat.state.sessions.contains(where: { $0.id == sessionID }) else {
                if scoped { url.stopAccessingSecurityScopedResource() }; return
            }
            sheets.present(.knowledgeDirectory(sessionID, url, inventory, scoped))
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            report(error.localizedDescription, for: sessionID)
        }
    }

    private func chooseAttachments(for sessionID: UUID, knowledge: Bool = false) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard await panel.begin() == .OK, owner === chat, store === chat.store else { return }
        await importURLs(panel.urls, sessionID: sessionID, knowledge: knowledge)
    }
    private func chooseTranscriptionFile(sessionID: UUID, locale: String) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = newLabel("audioImport", english: "Choose a local PCM WAV or CAF. D keeps a copy, transcribes on device, and waits for your review before adding text to the draft.", chinese: "选择本地PCM WAV或CAF；D保留副本并在本机转写，审核后才加入草稿，不自动发送。")
        guard await panel.begin() == .OK, let url = panel.url, owner === chat, store === chat.store else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard ["wav", "caf"].contains(url.pathExtension.lowercased()) else { throw WorkflowIssue(panel.message) }
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            let asset = try await store.importWorkflowMediaFile(at: url)
            onAssetsChanged(); try Task.checkCancellation()
            try await owner.transcribeSpeech(asset.record.reference, sessionID: sessionID, locale: locale)
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID) }
    }
    private func pasteAttachments(sessionID: UUID) async {
        // Explicit user action only; never poll the clipboard or follow web URLs.
        let pasteboard = NSPasteboard.general
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { await importURLs(files, sessionID: sessionID); return }
        guard let png = pasteboard.data(forType: .png), png.count <= 64 * 1_024 * 1_024 else {
            report(newLabel("pasteAttachmentMissing", english: "Copy local files or a PNG image first. Paste ordinary text directly in the draft. Other image formats can be added as files.", chinese: "请先复制本地文件或PNG图像；普通文字直接粘贴到草稿，其他图片格式可通过文件添加。"), for: sessionID); return
        }
        let owner = chat
        do {
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            _ = try await owner.addPastedPNG(png, sessionID: sessionID)
            onAssetsChanged()
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID) }
    }
    private func importURLs(_ urls: [URL], sessionID: UUID, knowledge: Bool = false,
                            directoryEntries: [ChatKnowledgeDirectoryInventory.Entry] = []) async {
        let ocr = ocrImport
        let owner = chat, store = chat.store
        guard let activity = try? owner.beginExternalActivity() else { return }
        defer { owner.endExternalActivity(activity) }
        var failures: [String] = []
        for url in urls {
            guard owner === chat, store === chat.store, chat.isLoaded,
                  chat.state.sessions.contains(where: { $0.id == sessionID }) else { break }
            guard url.isFileURL else { failures.append(url.absoluteString + ": " + label("fileOnly", "仅接受本地文件")); continue }
            guard DocumentTextExtractor.supportsPlainText(fileExtension: url.pathExtension) ||
                  ["pdf", "docx", "png", "jpg", "jpeg", "mp4"].contains(url.pathExtension.lowercased()) else {
                failures.append(url.lastPathComponent + ": " + newLabel("supportedDocuments", english: "Supported: UTF-8 text/code/CSV, PDF, DOCX, PNG/JPEG and MP4", chinese: "支持UTF-8文字/代码/CSV、PDF、DOCX、PNG/JPEG和MP4"))
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                if let entry = directoryEntries.first(where: { $0.url == url }) { try entry.validateUnchanged() }
                try Task.checkCancellation()
                let published = try await store.importWorkflowMediaFile(at: url)
                onAssetsChanged()
                if knowledge {
                    try await chat.addKnowledgeDocument(published.record.reference, name: url.lastPathComponent, ocr: ocr)
                } else {
                    _ = try await chat.addAttachment(published.record.reference, name: url.lastPathComponent, sessionID: sessionID, ocr: ocr)
                }
            } catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        report(failures.isEmpty ? nil : failures.joined(separator: "\n"), for: sessionID)
    }
    private func importSharedAssets(_ items: [WorkflowCanvasTransfer], sessionID: UUID) async {
        let owner = chat, store = chat.store
        guard let activity = try? owner.beginExternalActivity() else { return }
        defer { owner.endExternalActivity(activity) }
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
                    if !ChatAssetDropScope.accepts(projectID: projectID, instanceID: instanceID,
                        manifestProjectID: manifest.id, manifestInstanceID: manifest.effectiveInstanceID) {
                        guard let onResolveSharedAsset else { throw WorkflowIssue("请从资料库重新拖入具有明确项目实例的素材。") }
                        let (source, reference, name) = try await onResolveSharedAsset(projectID, instanceID, assetID)
                        try Task.checkCancellation()
                        guard owner === chat, store === chat.store else { throw CancellationError() }
                        _ = try await owner.addSharedAttachment(reference, from: source, name: name, sessionID: sessionID)
                        onAssetsChanged(); continue
                    }
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
    private func importConversation() async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, owner === chat else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= ChatInterchange.maximumImportBytes else { throw WorkflowIssue("Conversation import must be a regular file up to 2 MiB. / 会话导入限2MiB普通文件。") }
            let data = try Data(contentsOf: url)
            if let choices = try? ChatOpenWebUIImport.conversations(in: data), choices.count > 1 {
                // Selection and the selected tree's validation happen in the preview sheet.
            } else { _ = try ChatInterchange.previewImport(data) }
            present(.conversationImport(data, String(url.deletingPathExtension().lastPathComponent.prefix(100))))
        } catch { report(error.localizedDescription, for: chat.state.selectedSessionID) }
    }

    private func importPresets() async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, owner === chat else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 2_097_152 else { throw WorkflowIssue("Preset file must be at most 2 MiB. / 预设文件不能超过2MiB。") }
            let data = try Data(contentsOf: url)
            let presets = try ChatPresetFile.decode(data)
            present(.presetImport(presets, data))
        } catch { report(error.localizedDescription, for: chat.state.selectedSessionID) }
    }
    private func exportPresets(_ presets: [ChatPromptPreset], sessionID: UUID) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        do {
            _ = try ChatPresetFile.encode(presets)
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            guard await panel.begin() == .OK, let directory = panel.url, owner === chat, store === chat.store else { return }
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
            _ = try await store.exportChatPresets(presets, exportID: UUID(), directory: directory)
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID) }
    }

    private func exportSessionPackage(sessionID: UUID) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "D-chat.dbackup"
        panel.message = newLabel("sessionPackagePrivacy", english: "Includes all branches, unsent draft, attachments and frozen inputs (which may contain private facts). Personal-memory identities without local content remain provenance only. Future memory reads start disabled. Restore as an independent project through the existing Restore Backup entry.", chinese: "包含所有分支、未发送草稿、附件及冻结输入（可能含私人信息）。未保存本地内容的个人记忆仅保留来源标识，恢复后默认不读取记忆。使用现有“恢复备份”入口恢复为独立项目。")
        guard await panel.begin() == .OK, let destination = panel.url, owner === chat else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            let plan = try await owner.sessionBackupPlan(sessionID: sessionID)
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            _ = try await ProjectBackup.create(plan, at: destination)
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID) }
    }

    private func export(sessionID: UUID, markdown: Bool, html: Bool = false) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let snapshot = chat.state.sessions.first(where: { $0.id == sessionID })
        let value: String
        do {
            if html {
                guard let session = snapshot, let leaf = session.selectedLeafID else { throw WorkflowIssue("No selected conversation path. / 尚无所选会话路径。") }
                value = try ChatInterchange.exportHTML(session: session, leafID: leaf)
            } else { value = try chat.exportSelectedPath(sessionID: sessionID, markdown: markdown) }
        }
        catch { report(error.localizedDescription, for: sessionID); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard await panel.begin() == .OK, let directory = panel.url,
              owner === chat, store === chat.store else { return }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        do {
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            if html, let snapshot, let leaf = snapshot.selectedLeafID {
                _ = try await store.exportChatHTML(snapshot, leafID: leaf, exportID: UUID(), directory: directory)
                report(nil, for: sessionID); return
            }
            let reference = try await store.publishWorkflowAsset(data: Data(value.utf8), mediaType: html ? "text/html" : markdown ? "text/markdown" : "text/plain",
                name: html ? "聊天路径 HTML" : markdown ? "聊天路径 Markdown" : "聊天路径纯文字", operationID: "d.chat.export-path",
                details: ["chatSessionID": sessionID.uuidString, "format": html ? "html" : markdown ? "markdown" : "plain"]).record.reference
            onAssetsChanged()
            _ = try await store.exportWorkflowAssets([reference], name: html ? "D-chat-html" : markdown ? "D-chat-markdown" : "D-chat-text",
                                                      exportID: UUID(), directory: directory)
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID) }
    }
    private func saveFinal(_ messageID: UUID, sessionID: UUID, useInWorkflow: Bool) async {
        let owner = chat
        do {
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            let asset = try await owner.saveAssistantFinal(messageID, sessionID: sessionID)
            guard owner === chat else { return }
            if owner.isTemporary {
                guard let onRetainTemporary else { throw WorkflowIssue("长期保存入口不可用；成果仍在临时会话。") }
                try await onRetainTemporary(asset, useInWorkflow, activity)
            } else {
                onAssetsChanged()
                if useInWorkflow { onSavedAsset(asset) }
            }
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID) }
    }

    private func present(_ item: ChatDetail) {
        // Close the actual narrow pane as well as its presentation state before
        // replacing it with a detail sheet. Inline panes remain in place.
        if sheets.narrowPanel != nil { closeNarrowPanel() }
        sheets.present(item)
    }

    private func closeNarrowPanel(keepPreference: Bool = false) {
        if !keepPreference {
            switch sheets.narrowPanel {
            case .sessions: showSidebar = false
            case .inspector: showInspector = false
            case nil: break
            }
        }
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
        ChatEditForm(edit: edit, issue: issues[edit.sessionID], onCancel: { sheets.detail = nil }, onCommit: { text in
            perform(sessionID: edit.sessionID) {
                switch edit.kind {
                case .rename: try chat.rename(edit.sessionID, title: text)
                case .message:
                    guard let id = edit.messageID else { throw WorkflowIssue("消息不存在。") }
                    guard chat.state.selectedSessionID == edit.sessionID else { throw WorkflowIssue("请返回原对话后再编辑消息。") }
                    _ = try chat.editUserMessage(id, text: text, sessionID: edit.sessionID)
                case .answer:
                    guard let id = edit.messageID else { throw WorkflowIssue("回答不存在。") }
                    try ChatContextCommands.adopt(text, messageID: id, sessionID: edit.sessionID, in: chat)
                case .tags:
                    guard let session = chat.state.sessions.first(where: { $0.id == edit.sessionID }) else {
                        throw WorkflowIssue("对话不存在。")
                    }
                    let tags = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    try ChatContextCommands.choices(session, mutate: { $0.tags = tags }, in: chat)
                case .defaultSystem: try chat.setDefaultSystemPrompt(text)
                }
            }
            if issues[edit.sessionID] == nil { sheets.detail = nil }
        })
    }
}

private struct ChatEdit: Identifiable {
    enum Kind: Equatable { case rename, message, answer, tags, defaultSystem }
    let id = UUID()
    let kind: Kind
    let sessionID: UUID
    let messageID: UUID?
    let text: String
}

@MainActor
private struct ChatEditForm: View {
    let edit: ChatEdit
    let issue: String?
    let onCancel: () -> Void
    let onCommit: (String) -> Void
    @State private var text: String
    @Environment(\.dLanguageStore) private var language

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }
    private func newLabel(_ key: String, english: String, chinese: String) -> String {
        workflowText(language, "chat." + key,
            fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english)
    }

    init(edit: ChatEdit, issue: String?, onCancel: @escaping () -> Void, onCommit: @escaping (String) -> Void) {
        self.edit = edit; self.issue = issue; self.onCancel = onCancel; self.onCommit = onCommit
        _text = State(initialValue: edit.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let title = switch edit.kind {
                case .rename: label("rename", "重命名对话")
                case .message: label("editBranch", "编辑消息 · 创建新分支")
                case .answer: newLabel("editAdopt", english: "Edit and adopt answer", chinese: "编辑并采用回答")
                case .tags: newLabel("editTags", english: "Edit tags", chinese: "编辑标签")
                case .defaultSystem: newLabel("editDefaultSystem", english: "Default system prompt for new conversations", chinese: "新会话默认系统提示")
            }
            Text(title).font(.headline)
            if edit.kind == .answer {
                Text(newLabel("originalPreserved", english: "The original model output stays unchanged. Save explicitly to adopt this version.",
                    chinese: "原始模型输出保持不变；明确保存后才采用此版本。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if edit.kind == .tags {
                Text(newLabel("tagLines", english: "One tag per line; up to 24 tags of 32 characters each.",
                    chinese: "每行一个标签；最多24个，每个不超过32字。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextSourcesQuestionEditor(value: text, editEpoch: 0, isEditable: true,
                accessibilityIdentifier: "chat-edit-\(edit.sessionID.uuidString)", accessibilityLabel: title, onEdit: { text = $0 })
                .id(edit.id).frame(height: edit.kind == .rename ? 70 : 220)
            if let issue { Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(label("cancel", "取消"), action: onCancel)
                Button(edit.kind == .message ? label("createBranch", "创建分支") : label("save", "保存")) { onCommit(text) }
                    .disabled((edit.kind == .rename || edit.kind == .message || edit.kind == .answer) &&
                              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("chat-edit-save")
            }
        }.padding(20).frame(minWidth: 440)
    }
}
