import DWorkbench
import SwiftUI

/// Uses frozen provenance from the displayed revision; it does not recapture
/// a possibly changed chat path when the panel redraws.
struct ChatProvenancePresentation {
    enum Origin: Equatable {
        case manual
        case auxiliary(UUID)
        case chat
    }

    let revision: UInt64
    let scope: ChatMemoryScope?
    let origin: Origin
    let source: ChatContextSource?

    init(summary: ChatContextSummary) {
        revision = summary.revision
        scope = nil
        origin = summary.auxiliaryAttemptID.map { .auxiliary($0) } ?? .manual
        source = summary.source
    }

    init(memory: ChatMemoryEntry) {
        revision = memory.revision
        scope = memory.scope
        switch memory.source {
        case .manual: origin = .manual; source = nil
        case .chat(let captured): origin = .chat; source = captured
        }
    }
}

/// Explicit, versioned context changes. Ordinary browsing never starts model work.
struct ChatMemoryPanel: View {
    @Environment(\.dLanguageStore) private var language
    let chat: ChatController
    let session: ChatSession
    let wording: (String, String) -> String
    @State private var summaryText = ""
    @State private var memoryText = ""
    @State private var personal = false
    @State private var editingSummary: UUID?
    @State private var editingMemory: ChatMemoryEntry?
    @State private var issue: String?
    private var summaries: [ChatContextSummary] {
        Dictionary(grouping: session.contextSummaries ?? [], by: \.id).values.compactMap { $0.max { $0.revision < $1.revision } }.sorted { $0.createdAt < $1.createdAt }
    }
    private var memories: [ChatMemoryEntry] {
        Dictionary(grouping: (chat.state.memoryEntries ?? []).filter { $0.scope != .personal } + chat.personalMemories, by: \.id).values
            .compactMap { $0.max { $0.revision < $1.revision } }.sorted { $0.createdAt < $1.createdAt }
    }
    var body: some View {
        DisclosureGroup(wording("Summaries and memory", "摘要与记忆")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(wording("Summaries replace only reviewed context. Originals remain. Memory is off until explicitly enabled.", "摘要仅替代经过确认的上下文，原文保留。记忆须显式启用。"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(summaries) { summary in
                    let provenance = ChatProvenancePresentation(summary: summary)
                    Toggle(wording("Summary revision ", "摘要版本 ") + String(provenance.revision), isOn: Binding(get: { summary.enabled }, set: { value in
                        change { try chat.setSummaryEnabled(summary.id, enabled: value, sessionID: session.id) }
                    }))
                    provenanceDetails(provenance)
                    Text(summary.text).lineLimit(4).font(.caption).textSelection(.enabled)
                    Button(wording("Edit a new revision", "编辑为新版本")) { summaryText = summary.text; editingSummary = summary.id }
                }
                TextSourcesQuestionEditor(value: summaryText, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-summary-editor", onEdit: { summaryText = $0 }).frame(minHeight: 65)
                Button(editingSummary == nil ? wording("Save reviewed summary", "保存人工整理的摘要") : wording("Save summary revision", "保存摘要新版本")) {
                    change { try chat.writeSummary(text: summaryText, sessionID: session.id, replacingID: editingSummary); summaryText = ""; editingSummary = nil }
                }.disabled(summaryText.isEmpty || chat.isRunning)
                Divider()
                if !chat.isTemporary {
                Toggle(wording("Use personal memories", "使用个人记忆"), isOn: scopeBinding(.personal))
                if let id = chat.projectIdentity { Toggle(wording("Use this project's memories", "使用本项目记忆"), isOn: scopeBinding(.project(id))) }
                ForEach(memories) { entry in
                    let provenance = ChatProvenancePresentation(memory: entry)
                    VStack(alignment: .leading) {
                        Text(entry.text)
                            .font(.caption).textSelection(.enabled)
                        provenanceDetails(provenance)
                        if entry.forgottenAt == nil {
                            HStack {
                                Toggle(wording("Enabled", "启用"), isOn: Binding(get: { entry.enabled }, set: { value in
                                    write { try entry.settingEnabled(value) }
                                })).disabled(entry.acceptance != .accepted)
                                if entry.acceptance == .suggested {
                                    Button(wording("Accept", "采用")) { write { try entry.approved() } }
                                }
                                Button(wording("Edit", "编辑")) { editingMemory = entry; memoryText = entry.text; personal = entry.scope == .personal }
                                Button(wording("Forget", "忘记"), role: .destructive) { write { try entry.forgotten() } }
                            }
                        } else { Text(wording("Forgotten · retained only as history", "已忘记 · 仅保留历史" )).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Toggle(wording("New memory is personal", "新增为个人记忆"), isOn: $personal).disabled(editingMemory != nil)
                TextSourcesQuestionEditor(value: memoryText, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-memory-editor", onEdit: { memoryText = $0 }).frame(minHeight: 65)
                Button(wording("Save memory", "保存记忆")) {
                    write(clearEditor: true) {
                        if let editingMemory { return try editingMemory.edited(text: memoryText) }
                        guard let projectID = chat.projectIdentity else { throw WorkflowIssue("项目尚未准备。") }
                        return try .manual(text: memoryText, scope: personal ? .personal : .project(projectID))
                    }
                }.disabled(memoryText.isEmpty)
                } else { Text(wording("Temporary chat does not read or write long-term memory.", "临时会话不读写长期记忆。")).font(.caption) }
                if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            }.padding(.top, 6)
        }
    }
    @ViewBuilder private func provenanceDetails(_ value: ChatProvenancePresentation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(wording("Revision", "版本") + " \(value.revision)")
            if let scope = value.scope {
                switch scope {
                case .personal: Text(wording("Scope: personal", "范围：个人"))
                case .project(let id): Text(wording("Scope: project ", "范围：项目 ") + id.uuidString)
                }
            }
            switch value.origin {
            case .manual: Text(wording("Origin: manual", "来源：人工"))
            case .auxiliary(let id): Text(wording("Origin: auxiliary attempt ", "来源：辅助尝试 ") + id.uuidString)
            case .chat: Text(wording("Origin: source chat", "来源：源聊天"))
            }
            if let source = value.source {
                Text(wording("Source chat: ", "源聊天：") + source.sessionID.uuidString)
                Text(wording("Source leaf: ", "来源末消息：") + source.selectedLeafID.uuidString)
                if let first = source.coveredMessageIDs.first,
                   let last = source.coveredMessageIDs.last {
                    Text(wording("Covered range: ", "覆盖范围：") + first.uuidString + " … " + last.uuidString)
                }
                DisclosureGroup(wording("Covered message IDs (\(source.coveredMessageIDs.count))",
                                        "覆盖消息 ID（\(source.coveredMessageIDs.count)）")) {
                    ForEach(source.coveredMessageIDs, id: \.self) { id in
                        Text(id.uuidString).textSelection(.enabled)
                    }
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
    private func scopeBinding(_ scope: ChatMemoryScope) -> Binding<Bool> {
        Binding(get: { session.memoryScopes?.contains(scope) == true }, set: { value in
            change { var values = session.memoryScopes ?? []; values.removeAll { $0 == scope }; if value { values.append(scope) }; try chat.setMemoryScopes(values, sessionID: session.id) }
        })
    }
    private func change(_ action: () throws -> Void) { do { try action(); issue = nil } catch { issue = error.localizedDescription } }
    private func write(clearEditor: Bool = false, _ value: () throws -> ChatMemoryEntry) {
        do {
            let entry = try value(), capturedText = memoryText
            Task { @MainActor in
                do { try await chat.writeMemory(entry); if clearEditor && memoryText == capturedText { memoryText = ""; editingMemory = nil }; issue = nil }
                catch { issue = error.localizedDescription }
            }
        } catch { issue = error.localizedDescription }
    }
}
