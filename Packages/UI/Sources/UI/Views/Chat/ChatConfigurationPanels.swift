import DWorkbench
import Foundation
import SwiftUI

/// Commands shared by the hosted panels and their controller-backed presentation tests.
@MainActor enum ChatConfigurationActions {
    static func matchesFrozenInput(_ candidate: ChatAttempt, source: ChatAttempt) -> Bool {
        candidate.sessionID == source.sessionID && candidate.userMessageID == source.userMessageID &&
        candidate.messagesJSON == source.messagesJSON && candidate.inputs == source.inputs &&
        candidate.systemPrompt == source.systemPrompt
    }

    static func answers(in session: ChatSession, source: ChatAttempt) -> [ChatAttempt] {
        session.attempts.filter { matchesFrozenInput($0, source: source) }
    }

    static func canCompare(_ session: ChatSession, source: ChatAttempt, chat: ChatController) -> Bool {
        chat.isLoaded && source.sessionID == session.id &&
        session.attempts.contains(where: { $0.id == source.id }) &&
        source.status != .running && source.status != .saving &&
        ChatRunAdmission.allows(session, isRunning: chat.isRunning,
            hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil,
            invalidFields: chat.invalidParameterFields)
    }

    static func canChoose(_ session: ChatSession, attempt: ChatAttempt, chat: ChatController) -> Bool {
        chat.isLoaded && !session.archived && session.contextChoices?.deletedAt == nil &&
        !chat.isRunning && chat.pendingSaveAttemptID == nil && chat.saveIssue == nil &&
        attempt.sessionID == session.id && attempt.status != .running && attempt.status != .saving &&
        !(attempt.response?.finalText ?? attempt.rawText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        session.messages.contains(where: { $0.id == attempt.assistantMessageID && $0.attemptID == attempt.id })
    }

    static func choose(_ attempt: ChatAttempt, sessionID: UUID, chat: ChatController) throws {
        guard let session = chat.state.sessions.first(where: { $0.id == sessionID }),
              canChoose(session, attempt: attempt, chat: chat) else {
            throw WorkflowIssue("请等待回答和保存完成，并在原对话中选择。")
        }
        try chat.selectLeaf(attempt.assistantMessageID, sessionID: sessionID)
    }

    static func compareCurrent(_ source: ChatAttempt, sessionID: UUID,
                               chat: ChatController) async throws {
        guard let session = chat.state.sessions.first(where: { $0.id == sessionID }),
              canCompare(session, source: source, chat: chat),
              let configuration = session.configuration else {
            throw WorkflowIssue("当前对话或模型参数尚不能提交比较。")
        }
        try await chat.compare(source.id, configuration: configuration, sessionID: sessionID)
    }

    static func savePreset(_ draft: ChatPromptPreset, captureCurrentConfiguration: Bool,
                           sessionID: UUID, chat: ChatController) throws {
        var preset = draft
        if captureCurrentConfiguration {
            guard let session = chat.state.sessions.first(where: { $0.id == sessionID }),
                  !chat.hasInvalidParameterText(sessionID: sessionID),
                  let configuration = session.configuration else {
                throw WorkflowIssue("请先完成参数输入并选择模型，再保存当前配置。")
            }
            preset.configuration = configuration
        }
        try chat.setPreset(preset)
    }
}

/// Lead supplies the scoped import/export file UI. Editing stays local until Save;
/// applying is a separate, explicit conversation change.
struct ChatPresetsPanel: View {
    @Environment(\.dLanguageStore) private var language
    let chat: ChatController
    let sessionID: UUID
    let onImport: () -> Void
    let onExport: ([ChatPromptPreset]) -> Void

    @State private var editingID: UUID?
    @State private var editorOpen = false
    @State private var name = ""
    @State private var prompt = ""
    @State private var selectionInstruction = ""
    @State private var captureConfiguration = false
    @State private var issue: String?

    init(chat: ChatController, sessionID: UUID, onImport: @escaping () -> Void,
         onExport: @escaping ([ChatPromptPreset]) -> Void) {
        self.chat = chat
        self.sessionID = sessionID
        self.onImport = onImport
        self.onExport = onExport
    }

    private var session: ChatSession? { chat.state.sessions.first { $0.id == sessionID } }
    private var original: ChatPromptPreset? { chat.state.presets.first { $0.id == editingID } }
    private var invalidCapture: Bool {
        captureConfiguration && (session?.configuration == nil || chat.hasInvalidParameterText(sessionID: sessionID))
    }
    private var validName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 256
    }

    private func text(_ key: String, _ english: String, _ chinese: String) -> String {
        workflowText(language, "chat.config." + key,
            fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english)
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); issue = nil } catch { issue = error.localizedDescription }
    }
    private func load(_ preset: ChatPromptPreset?) {
        editingID = preset?.id
        name = preset?.name ?? ""
        prompt = preset?.prompt ?? ""
        selectionInstruction = preset?.selectionInstruction ?? ""
        captureConfiguration = false
        issue = nil
        editorOpen = true
    }
    private func save() {
        guard validName, !invalidCapture else { return }
        guard editingID == nil || original != nil else {
            issue = text("removed", "This preset was removed. Create a new preset to save these edits.",
                "此预设已被删除。请新建预设以保存编辑。")
            return
        }
        let instruction = selectionInstruction.isEmpty ? nil : selectionInstruction
        let preset = ChatPromptPreset(id: editingID ?? UUID(), name: name, prompt: prompt,
            configuration: original?.configuration,
            selectionInstruction: instruction)
        perform { try ChatConfigurationActions.savePreset(preset,
            captureCurrentConfiguration: captureConfiguration, sessionID: sessionID, chat: chat) }
        if issue == nil { editorOpen = false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text("presets", "Presets", "预设")).font(.headline)
            Text(text("future", "Applying a preset changes future answers only.", "应用预设只影响之后的回答。"))
                .font(.caption).foregroundStyle(.secondary)
            if chat.state.presets.isEmpty {
                Text(text("empty", "No saved presets", "尚无已保存预设"))
                    .foregroundStyle(.secondary)
            }
            ForEach(chat.state.presets) { preset in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).lineLimit(1)
                        Text(preset.configuration == nil
                            ? text("promptOnly", "Prompt only", "仅提示词")
                            : text("withSettings", "Prompt and model settings", "提示词和模型设置"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(text("apply", "Apply", "应用")) {
                        perform { try chat.applyPreset(preset.id, sessionID: sessionID) }
                    }
                    .disabled(session == nil || session?.archived == true || session?.contextChoices?.deletedAt != nil || !chat.isLoaded || chat.saveIssue != nil)
                    .accessibilityIdentifier("chat-preset-apply-\(preset.id.uuidString)")
                    Menu {
                        Button(text("edit", "Edit…", "编辑…")) { load(preset) }
                        Button(text("duplicate", "Duplicate", "复制")) {
                            perform { _ = try chat.copyPreset(preset.id,
                                name: preset.name + text("copySuffix", " Copy", " 副本")) }
                        }
                        Button(text("delete", "Delete", "删除"), role: .destructive) {
                            perform { try chat.removePreset(preset.id) }
                            if editingID == preset.id && issue == nil { editorOpen = false }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel(text("presetActions", "Preset actions", "预设操作") + ": " + preset.name)
                }
            }
            HStack {
                Button(text("new", "New preset…", "新建预设…")) { load(nil) }
                Spacer()
                Button(text("import", "Import…", "导入…"), action: onImport)
                Button(text("export", "Export…", "导出…")) { onExport(chat.state.presets) }
                    .disabled(chat.state.presets.isEmpty)
            }
            if editorOpen { editor }
            if let issue { Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: sessionID) { _, _ in
            editorOpen = false
            editingID = nil
            issue = nil
        }
    }

    private var editor: some View {
        DisclosureGroup(isExpanded: $editorOpen) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(text("name", "Name", "名称"), text: $name)
                    .accessibilityLabel(text("name", "Name", "名称"))
                    .accessibilityIdentifier("chat-preset-name")
                Text(text("system", "System prompt", "系统提示"))
                TextSourcesQuestionEditor(value: prompt, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-preset-prompt", onEdit: { prompt = $0 })
                    .id("prompt:" + (editingID?.uuidString ?? "new"))
                    .accessibilityLabel(text("system", "System prompt", "系统提示"))
                    .frame(height: 90)
                Text(text("selection", "Selection instruction (optional)", "选段指令（可选）"))
                TextSourcesQuestionEditor(value: selectionInstruction, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-preset-selection", onEdit: { selectionInstruction = $0 })
                    .id("selection:" + (editingID?.uuidString ?? "new"))
                    .accessibilityLabel(text("selection", "Selection instruction (optional)", "选段指令（可选）"))
                    .frame(height: 70)
                Toggle(text("capture", "Capture current model settings", "保存当前模型参数"),
                    isOn: $captureConfiguration)
                    .disabled(session?.configuration == nil)
                if invalidCapture {
                    Text(text("invalid", "Finish the current numeric input before capturing settings.",
                        "请先完成当前数值输入，再保存参数。"))
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button(text("restore", "Restore saved version", "恢复已保存版本")) { load(original) }
                        .disabled(original == nil)
                    Spacer()
                    Button(text("cancel", "Cancel", "取消")) { editorOpen = false; issue = nil }
                    Button(text("save", "Save preset", "保存预设"), action: save)
                        .disabled(!validName || invalidCapture || prompt.utf8.count > 65_536 ||
                                  selectionInstruction.utf8.count > 16_384 || !chat.isLoaded || chat.saveIssue != nil)
                        .accessibilityIdentifier("chat-preset-save")
                }
            }.padding(.top, 8)
        } label: {
            Text(original == nil ? text("create", "Create preset", "新建预设") :
                text("editTitle", "Edit preset", "编辑预设"))
        }
        .accessibilityIdentifier("chat-preset-editor")
    }
}

/// The source attempt and every displayed candidate share one exact frozen request.
/// Model choice remains in the main top bar; this panel never starts inference implicitly.
struct ChatComparisonPanel: View {
    @Environment(\.dLanguageStore) private var language
    let chat: ChatController
    let sessionID: UUID
    let sourceAttemptID: UUID
    let onClose: () -> Void
    @State private var issue: String?

    init(chat: ChatController, sessionID: UUID, sourceAttemptID: UUID,
         onClose: @escaping () -> Void) {
        self.chat = chat
        self.sessionID = sessionID
        self.sourceAttemptID = sourceAttemptID
        self.onClose = onClose
    }

    private var session: ChatSession? { chat.state.sessions.first { $0.id == sessionID } }
    private var source: ChatAttempt? { session?.attempts.first { $0.id == sourceAttemptID } }
    private func text(_ key: String, _ english: String, _ chinese: String) -> String {
        workflowText(language, "chat.config." + key,
            fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english)
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); issue = nil } catch { issue = error.localizedDescription }
    }
    private func launch(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action(); issue = nil } catch { issue = error.localizedDescription } }
    }
    private func status(_ attempt: ChatAttempt) -> String {
        let english: String = switch attempt.status {
        case .running: "Running"; case .completed: "Completed"; case .partial: "Partial"
        case .cancelled: "Cancelled"; case .failed: "Failed"; case .interrupted: "Interrupted"
        case .saving: "Saving"
        }
        let chinese: String = switch attempt.status {
        case .running: "生成中"; case .completed: "已完成"; case .partial: "部分完成"
        case .cancelled: "已取消"; case .failed: "失败"; case .interrupted: "已中断"
        case .saving: "保存中"
        }
        return text("status." + attempt.status.rawValue, english, chinese)
    }
    private func scalar(_ value: WorkflowScalar) -> String {
        switch value {
        case .text(let text): text
        case .integer(let number): String(number)
        case .decimal(let number): String(number)
        case .flag(let flag): String(describing: flag)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("comparison", "Compare answers", "比较回答")).font(.headline)
                Spacer()
                Button(text("close", "Close", "关闭"), action: onClose)
                    .accessibilityIdentifier("chat-comparison-close")
            }
            if let session, let source {
                Text(text("fixedInput", "All answers below use the same frozen question, context, media, and system prompt.",
                    "下列回答使用同一份冻结的问题、上下文、媒体和系统提示。"))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(text("input", "Frozen input", "冻结输入")) {
                    if let user = session.messages.first(where: { $0.id == source.userMessageID }) {
                        Text(text("question", "Question", "问题") + ": " + user.text)
                            .textSelection(.enabled)
                    }
                    Text(text("system", "System prompt", "系统提示") + ": " + source.systemPrompt)
                        .textSelection(.enabled)
                    Text(text("mediaPorts", "Media ports", "媒体端口") + ": " +
                         (source.inputs.keys.sorted().joined(separator: ", ").isEmpty ? "—" :
                          source.inputs.keys.sorted().joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(ChatConfigurationActions.answers(in: session, source: source)) { attempt in
                            answer(attempt, session: session, source: source)
                        }
                    }.padding(.vertical, 4)
                }
                HStack {
                    Button(text("compareCurrent", "Compare with current model and settings", "用当前模型与参数新增比较")) {
                        launch { try await ChatConfigurationActions.compareCurrent(source,
                            sessionID: sessionID, chat: chat) }
                    }
                    .disabled(!ChatConfigurationActions.canCompare(session, source: source, chat: chat))
                    .accessibilityIdentifier("chat-comparison-new")
                    Button(text("reproduce", "Reproduce source exactly", "精确重现原回答")) {
                        launch { try await chat.reproduce(sourceAttemptID, sessionID: sessionID) }
                    }
                    .disabled(!ChatRunAdmission.allowsReplay(session, attempt: source,
                        isRunning: chat.isRunning, hasPendingSave: chat.pendingSaveAttemptID != nil,
                        hasSaveIssue: chat.saveIssue != nil) || !chat.isLoaded)
                    .accessibilityIdentifier("chat-comparison-reproduce")
                }
                Text(text("draft", "Your unsent draft is preserved. Choosing an answer selects its branch without generating.",
                    "未发送草稿会保留。选择回答只切换分支，不会生成。"))
                    .font(.caption).foregroundStyle(.secondary)
                if let originalError = source.issue {
                    Text(text("sourceIssue", "Source issue", "原回答问题") + ": " + ChatErrorText.display(originalError, language: language))
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } else {
                Text(text("missing", "The source answer is no longer in this conversation.", "原回答已不在此对话中。"))
                    .foregroundStyle(.secondary)
            }
            if let issue { Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: sessionID) { _, _ in issue = nil }
        .onChange(of: sourceAttemptID) { _, _ in issue = nil }
    }

    private func answer(_ attempt: ChatAttempt, session: ChatSession, source: ChatAttempt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(attempt.id == source.id ? text("source", "Source", "原回答") :
                text("candidate", "Candidate", "候选回答"))
                .font(.subheadline.bold())
            Text(status(attempt)).font(.caption).foregroundStyle(.secondary)
            Text(text("model", "Model", "模型") + ": " +
                 (attempt.node.parameters["modelID"]?.string ?? "—"))
                .font(.caption).textSelection(.enabled)
            Text(text("seed", "Seed", "种子") + ": " +
                 (attempt.node.parameters["seed"]?.string ?? "—"))
                .font(.caption).textSelection(.enabled)
            DisclosureGroup(text("settings", "Frozen settings", "冻结参数")) {
                ForEach(attempt.node.parameters.keys.sorted().filter {
                    !["modelID", "seed", "messagesJSON", "task", "outputMode"].contains($0)
                }, id: \.self) { key in
                    if let value = attempt.node.parameters[key] {
                        Text(key + ": " + scalar(value)).font(.caption).textSelection(.enabled)
                    }
                }
            }
            ScrollView {
                Text(attempt.response?.finalText ?? attempt.rawText).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 120, maxHeight: 260)
            if let issue = attempt.issue {
                Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Button(text("choose", "Choose this answer", "选择此回答")) {
                perform { try ChatConfigurationActions.choose(attempt, sessionID: sessionID, chat: chat) }
            }
            .disabled(!ChatConfigurationActions.canChoose(session, attempt: attempt, chat: chat))
            .accessibilityIdentifier("chat-comparison-choose-\(attempt.id.uuidString)")
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
