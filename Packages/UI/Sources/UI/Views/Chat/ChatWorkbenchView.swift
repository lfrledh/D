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
    static func allowsReplay(_ session: ChatSession, attempt: ChatAttempt, isRunning: Bool,
                             hasPendingSave: Bool, hasSaveIssue: Bool) -> Bool {
        guard let seed = attempt.node.parameters["seed"]?.string, UInt64(seed) != nil else { return false }
        return !session.archived && !isRunning && !hasPendingSave && !hasSaveIssue &&
            attempt.sessionID == session.id && attempt.status != .running && attempt.status != .saving
    }

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
    @State private var showAdvanced = false
    @State private var issues: [UUID: String] = [:]
    @State private var globalIssue: String?
    @State private var editing: ChatEdit?
    @State private var preview: WorkflowAssetReference?
    @State private var newPresetName = ""

    init(chat: ChatController, model: WorkbenchModel,
         onChooseModel: @escaping () -> Void,
         onSavedAsset: @escaping (WorkflowAssetReference) -> Void,
         onAssetsChanged: @escaping () -> Void) {
        self.chat = chat; self.model = model; self.onChooseModel = onChooseModel
        self.onSavedAsset = onSavedAsset; self.onAssetsChanged = onAssetsChanged
    }

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
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
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 230, maxWidth: 340)
            if !chat.isLoaded {
                ContentUnavailableView(label("loadFailed", "聊天记录不可用"), systemImage: "exclamationmark.triangle",
                    description: Text(chat.error ?? label("loading", "正在读取聊天记录…")))
                    .frame(minWidth: 500)
            } else if let session {
                conversation(session).frame(minWidth: 500)
            } else {
                ContentUnavailableView(label("empty", "开始新对话"), systemImage: "bubble.left.and.bubble.right",
                    description: Text(label("emptyHelp", "新建对话后选择模型。不会自动发送。")))
                    .frame(minWidth: 500)
            }
        }
        .task { if !chat.isLoaded { await chat.load() } }
        .sheet(item: $editing) { edit in editSheet(edit) }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                VStack(alignment: .leading) {
                    Button(label("close", "关闭")) { self.preview = nil }.keyboardShortcut(.cancelAction)
                    QuickAssetPreview(store: chat.store, reference: preview, compact: false)
                }.padding(20).frame(minWidth: 560, minHeight: 360)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label("history", "对话")) .font(.headline)
                Spacer()
                Button(label("new", "新建"), systemImage: "plus") { perform { _ = try chat.newSession() } }
                    .disabled(!chat.isLoaded || chat.saveIssue != nil)
            }
            TextField(label("search", "搜索标题与内容"), text: $search)
                .textFieldStyle(.roundedBorder)
            Toggle(label("archived", "已归档"), isOn: $showArchived).controlSize(.small)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleSessions) { item in
                        HStack(spacing: 6) {
                            Button {
                                perform(sessionID: item.id, clearOnSuccess: false) { try chat.selectSession(item.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).lineLimit(2)
                                    Text("\(item.messages.count) " + label("messages", "条消息"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Menu {
                                Button(label("rename", "重命名")) {
                                    editing = ChatEdit(kind: .rename, sessionID: item.id, messageID: nil, text: item.title)
                                }
                                if !item.archived {
                                    Button(label("archive", "归档")) { perform(sessionID: item.id) { try chat.archive(item.id) } }
                                        .disabled(chat.activeSessionID == item.id)
                                }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
                        }
                        .padding(9)
                        .background(chat.state.selectedSessionID == item.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }.padding(14)
    }

    private func conversation(_ session: ChatSession) -> some View {
        let parentIDs = Set(session.messages.compactMap(\.parentID))
        let leaves = session.messages.filter { !parentIDs.contains($0.id) }
        let siblings = Dictionary(grouping: session.messages, by: {
            ($0.parentID?.uuidString ?? "root") + ":" + $0.role.rawValue
        })
        let attempts = Dictionary(uniqueKeysWithValues: session.attempts.map { ($0.id, $0) })
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.title3.bold()).lineLimit(2)
                    if let node = session.configuration {
                        let id = node.parameters["modelID"]?.string ?? ""
                        Text(model.projectSession.explicitModelChoices.first(where: { $0.id == id })?.displayName ??
                             (id.isEmpty ? label("chooseModel", "选择模型") : id))
                            .font(.subheadline)
                        Text(readiness(id)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(label("noModel", "尚未选择模型")) .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(label("changeModel", "更换模型"), action: onChooseModel)
                if !session.messages.isEmpty {
                    Menu(label("paths", "路径")) {
                        ForEach(leaves) { leaf in
                            Button((leaf.id == session.selectedLeafID ? "✓ " : "") +
                                   String(leaf.text.isEmpty ? leaf.id.uuidString.prefix(8) : leaf.text.prefix(40))) {
                                perform(sessionID: session.id) { try chat.selectLeaf(leaf.id, sessionID: session.id) }
                            }
                        }
                    }
                }
                Menu(label("export", "导出所选路径")) {
                    Button(label("copyPath", "复制所选路径")) {
                        perform(sessionID: session.id) { copy(try chat.exportSelectedPath(sessionID: session.id, markdown: false)) }
                    }
                    Button(label("exportMarkdown", "Markdown 内容")) { Task { await export(sessionID: session.id, markdown: true) } }
                    Button(label("exportPlain", "纯文字")) { Task { await export(sessionID: session.id, markdown: false) } }
                }.disabled(session.selectedLeafID == nil)
            }.padding(16)
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
                        }
                        if session.selectedLeafID == nil {
                            Text(label("noMessages", "暂无消息")) .foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(20)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button(label("bottom", "到底部"), systemImage: "arrow.down") {
                        withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    }.padding(12)
                }
            }
            Divider()
            settings(session)
            composer(session)
        }
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
                                   (sibling.text.isEmpty ? String(sibling.id.uuidString.prefix(8)) : String(sibling.text.prefix(36)))) {
                                perform(sessionID: session.id) { try chat.selectLeaf(sibling.id, sessionID: session.id) }
                            }
                        }
                    }
                }
                Spacer()
                Button(label("copy", "复制")) {
                    copy(attempt?.response?.finalText ?? attempt?.rawText ?? message.text)
                }
                if message.role == .user {
                    Button(label("edit", "编辑")) {
                        editing = ChatEdit(kind: .message, sessionID: session.id, messageID: message.id, text: message.text)
                    }
                    Button(label("generateReply", "生成回复")) { Task { await run(sessionID: session.id) { try await chat.regenerate(message.id, sessionID: session.id) } } }
                        .disabled(!canRun(session))
                } else if let parent = message.parentID {
                    Menu(label("candidates", "候选")) {
                        Button(label("newCandidate", "生成新候选（新随机种子）")) {
                            Task { await run(sessionID: session.id) { try await chat.regenerate(parent, sessionID: session.id) } }
                        }.disabled(!canRun(session))
                        if let attempt {
                            Button(label("replayRequest", "按原请求与种子重现")) {
                                Task { await run(sessionID: session.id) { try await chat.reproduce(attempt.id, sessionID: session.id) } }
                            }.disabled(!ChatRunAdmission.allowsReplay(session, attempt: attempt,
                                isRunning: chat.isRunning, hasPendingSave: chat.pendingSaveAttemptID != nil,
                                hasSaveIssue: chat.saveIssue != nil))
                        }
                    }.accessibilityIdentifier("chat-candidate-actions")
                }
                Button(label("forkHere", "从这里分叉")) {
                    perform(sessionID: session.id) { _ = try chat.forkSession(session.id, leafID: message.id) }
                }
            }.font(.caption)
            if let attempt {
                let final = attempt.response?.finalText
                let raw = attempt.response?.rawText ?? attempt.rawText
                let shown = attempt.status == .running ? attempt.rawText : (final ?? raw)
                if !shown.isEmpty {
                    ChatMarkdownView(messageID: message.id, text: shown, rawText: raw,
                                     isStreaming: attempt.status == .running)
                        .id(message.id)
                }
                if let reasoning = attempt.response?.reasoningText, !reasoning.isEmpty {
                    DisclosureGroup(label("reasoning", "思考内容")) {
                        Text(reasoning).textSelection(.enabled)
                        Button(label("copyReasoning", "复制思考内容")) { copy(reasoning) }
                    }
                }
                if let calls = attempt.response?.toolCalls, !calls.isEmpty {
                    DisclosureGroup(label("toolCalls", "工具调用声明 · 未执行")) {
                        ForEach(calls, id: \.id) { call in
                            VStack(alignment: .leading) {
                                Text(call.name).font(.subheadline.bold())
                                Text(String(data: (try? JSONEncoder().encode(call)) ?? Data(), encoding: .utf8) ?? "")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                HStack {
                    Text(status(attempt)).font(.caption).foregroundStyle(.secondary)
                    if let response = attempt.response {
                        Text(label("finish", "结束原因") + ": " + finish(response.finishReason))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if attempt.status == .completed, final?.isEmpty == false {
                        Button(label("saveAsset", "保存回答为素材")) { Task { await saveFinal(message.id, sessionID: session.id, useInWorkflow: false) } }
                        Button(label("useWorkflow", "用于工作流")) { Task { await saveFinal(message.id, sessionID: session.id, useInWorkflow: true) } }
                    }
                }
                if let issue = attempt.issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            } else {
                Text(message.text).textSelection(.enabled)
                ForEach(message.attachments) { attachment in attachmentRow(attachment, removable: false, sessionID: session.id) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func settings(_ session: ChatSession) -> some View {
        DisclosureGroup(label("nextAnswer", "下一次回答设置"), isExpanded: $showAdvanced) {
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(label("futureOnly", "更改只影响之后的生成。")) .font(.caption).foregroundStyle(.secondary)
                Text(label("systemPrompt", "系统提示（默认空）")) .font(.subheadline)
                TextSourcesQuestionEditor(value: session.systemPrompt, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-system-\(session.id.uuidString)",
                    onEdit: { value in perform(sessionID: session.id) { try chat.setSystemPrompt(value, sessionID: session.id) } })
                    .id(session.id.uuidString + ":system")
                    .frame(height: 90)
                HStack {
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
                    TextField(label("presetName", "预设名称"), text: $newPresetName).frame(maxWidth: 160)
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
            }.padding(.top, 10)
            }.frame(maxHeight: 220)
        }.padding(.horizontal, 16).padding(.vertical, 8)
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
            HStack {
                Button(label("attach", "添加附件…"), systemImage: "paperclip") {
                    Task { await chooseAttachments(for: session.id) }
                }.disabled(session.archived)
                Text(label("dropFiles", "可拖入 TXT、MD、图像或视频；Enter 换行。"))
                    .font(.caption).foregroundStyle(.secondary)
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
            Button(label("preview", "预览")) { preview = item.reference }
            if removable {
                Button(label("remove", "移除")) { perform(sessionID: sessionID) { try chat.removeAttachment(item.id, sessionID: sessionID) } }
            }
        }.font(.caption).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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

    private func editSheet(_ edit: ChatEdit) -> some View {
        ChatEditForm(edit: edit, onCancel: { editing = nil }, onCommit: { text in
            perform(sessionID: edit.sessionID) {
                switch edit.kind {
                case .rename: try chat.rename(edit.sessionID, title: text)
                case .message:
                    guard let id = edit.messageID else { return }
                    _ = try chat.editUserMessage(id, text: text, sessionID: edit.sessionID)
                }
            }
            if issues[edit.sessionID] == nil { editing = nil }
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
