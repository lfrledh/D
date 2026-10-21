import AppKit
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
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var colorScheme
    let chat: ChatController
    let session: ChatSession
    @Environment(\.dLanguageStore) private var copyLanguage
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
        DisclosureGroup(workflowText(copyLanguage, "chat.memoryPanel.summariesAndMemory")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(workflowText(copyLanguage, "chat.memoryPanel.summariesReplaceOnlyReviewedContextOriginalsRemainMemoryIsOff"))
                    .font(.caption).foregroundStyle(.secondary)
                ChatAssistancePanel(chat: chat, session: session, section: .summary, wording: wording)
                ForEach(summaries) { summary in
                    let provenance = ChatProvenancePresentation(summary: summary)
                    Toggle(workflowText(copyLanguage, "chat.memoryPanel.summaryRevision") + String(provenance.revision), isOn: Binding(get: { summary.enabled }, set: { value in
                        change { try chat.setSummaryEnabled(summary.id, enabled: value, sessionID: session.id) }
                    }))
                    provenanceDetails(provenance)
                    Text(summary.text).lineLimit(4).font(.caption).textSelection(.enabled)
                    Button(workflowText(copyLanguage, "chat.memoryPanel.editANewRevision")) { summaryText = summary.text; editingSummary = summary.id }
                }
                TextSourcesQuestionEditor(value: summaryText, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-summary-editor", onEdit: { summaryText = $0 },
                    transparentBackground: true, foregroundColor: NSColor(preferences.resolvedAppearance.palette(for: colorScheme).foregroundColor))
                    .frame(minHeight: 65).padding(8).workbenchPanel(cornerRadius: 10)
                Button(editingSummary == nil ? workflowText(copyLanguage, "chat.memoryPanel.saveReviewedSummary") : workflowText(copyLanguage, "chat.memoryPanel.saveSummaryRevision")) {
                    change { try chat.writeSummary(text: summaryText, sessionID: session.id, replacingID: editingSummary); summaryText = ""; editingSummary = nil }
                }.disabled(summaryText.isEmpty || chat.isRunning)
                Divider()
                if !chat.isTemporary {
                ChatAssistancePanel(chat: chat, session: session, section: .memory, wording: wording)
                Toggle(workflowText(copyLanguage, "chat.memoryPanel.usePersonalMemories"), isOn: scopeBinding(.personal))
                if let id = chat.projectIdentity { Toggle(workflowText(copyLanguage, "chat.memoryPanel.useThisProjectSMemories"), isOn: scopeBinding(.project(id))) }
                ForEach(memories) { entry in
                    let provenance = ChatProvenancePresentation(memory: entry)
                    VStack(alignment: .leading) {
                        Text(entry.text)
                            .font(.caption).textSelection(.enabled)
                        provenanceDetails(provenance)
                        if entry.forgottenAt == nil {
                            HStack {
                                Toggle(workflowText(copyLanguage, "chat.memoryPanel.enabled"), isOn: Binding(get: { entry.enabled }, set: { value in
                                    write { try entry.settingEnabled(value) }
                                })).disabled(entry.acceptance != .accepted)
                                if entry.acceptance == .suggested {
                                    Button(workflowText(copyLanguage, "consistency.legacy.TextSourcesView.145")) { write { try entry.approved() } }
                                }
                                Button(workflowText(copyLanguage, "chat.edit")) { editingMemory = entry; memoryText = entry.text; personal = entry.scope == .personal }
                                Button(workflowText(copyLanguage, "chat.memoryPanel.forget"), role: .destructive) { write { try entry.forgotten() } }
                            }
                        } else { Text(workflowText(copyLanguage, "chat.MemoryPanel.Forgottenretainedonlyashistory")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Toggle(workflowText(copyLanguage, "chat.memoryPanel.newMemoryIsPersonal"), isOn: $personal).disabled(editingMemory != nil)
                TextSourcesQuestionEditor(value: memoryText, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-memory-editor", onEdit: { memoryText = $0 },
                    transparentBackground: true, foregroundColor: NSColor(preferences.resolvedAppearance.palette(for: colorScheme).foregroundColor))
                    .frame(minHeight: 65).padding(8).workbenchPanel(cornerRadius: 10)
                Button(workflowText(copyLanguage, "chat.memoryPanel.saveMemory")) {
                    write(clearEditor: true) {
                        if let editingMemory { return try editingMemory.edited(text: memoryText) }
                        guard let projectID = chat.projectIdentity else { throw WorkflowIssue("项目尚未准备。") }
                        return try .manual(text: memoryText, scope: personal ? .personal : .project(projectID))
                    }
                }.disabled(memoryText.isEmpty)
                } else { Text(workflowText(copyLanguage, "chat.memoryPanel.temporaryChatDoesNotReadOrWriteLongTermMemory")).font(.caption) }
                if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            }.padding(.top, 6)
        }
    }
    @ViewBuilder private func provenanceDetails(_ value: ChatProvenancePresentation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(workflowText(copyLanguage, "chat.memoryPanel.revision") + " \(value.revision)")
            if let scope = value.scope {
                switch scope {
                case .personal: Text(workflowText(copyLanguage, "chat.memoryPanel.scopePersonal"))
                case .project(let id): Text(workflowText(copyLanguage, "chat.memoryPanel.scopeProject") + id.uuidString)
                }
            }
            switch value.origin {
            case .manual: Text(workflowText(copyLanguage, "chat.memoryPanel.originManual"))
            case .auxiliary(let id): Text(workflowText(copyLanguage, "chat.memoryPanel.originAuxiliaryAttempt") + id.uuidString)
            case .chat: Text(workflowText(copyLanguage, "chat.memoryPanel.originSourceChat"))
            }
            if let source = value.source {
                Text(workflowText(copyLanguage, "chat.memoryPanel.sourceChat") + source.sessionID.uuidString)
                Text(workflowText(copyLanguage, "chat.memoryPanel.sourceLeaf") + source.selectedLeafID.uuidString)
                if let first = source.coveredMessageIDs.first,
                   let last = source.coveredMessageIDs.last {
                    Text(workflowText(copyLanguage, "chat.memoryPanel.coveredRange") + first.uuidString + " … " + last.uuidString)
                }
                DisclosureGroup(workflowText(copyLanguage, "chat.memoryPanel.coveredMessageIDs", arguments: ["count": String(source.coveredMessageIDs.count)])) {
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
