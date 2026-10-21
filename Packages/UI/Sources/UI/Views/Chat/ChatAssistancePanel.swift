import DWorkbench
import SwiftUI

enum ChatAssistanceSection {
    case summary, memory, organization
    var kinds: [ChatAssistanceKind] {
        switch self { case .summary: [.summary]; case .memory: [.memory]; case .organization: [.title, .tags, .followUps] }
    }
    /// Apply only the edited group to the latest controller value, never another panel's stale snapshot.
    func merging(_ draft: ChatAssistanceOptions, into current: ChatAssistanceOptions) -> ChatAssistanceOptions {
        func budget(_ kind: ChatAssistanceKind) -> Int {
            (kinds.contains(kind) ? draft : current).outputTokenBudgets.value(for: kind)
        }
        return .init(summary: self == .summary ? draft.summary : current.summary,
            title: self == .organization ? draft.title : current.title,
            tags: self == .organization ? draft.tags : current.tags,
            followUps: self == .organization ? draft.followUps : current.followUps,
            memoryMode: self == .memory ? draft.memoryMode : current.memoryMode,
            memoryTarget: self == .memory ? draft.memoryTarget : current.memoryTarget,
            outputTokenBudgets: .init(summary: budget(.summary), title: budget(.title), tags: budget(.tags),
                followUps: budget(.followUps), memory: budget(.memory)),
            summaryThresholdEstimatedTokens: self == .summary ? draft.summaryThresholdEstimatedTokens : current.summaryThresholdEstimatedTokens)
    }
}

/// One optional settings group, not a second chat composer or model runner.
struct ChatAssistancePanel: View {
    @Environment(\.dLanguageStore) private var language
    @Bindable var chat: ChatController
    let session: ChatSession
    var section: ChatAssistanceSection = .organization
    var expanded: Binding<Bool>? = nil
    @State private var localExpanded = false
    @Environment(\.dLanguageStore) private var copyLanguage
    let wording: (String, String) -> String
    @State private var summary = false
    @State private var title = false
    @State private var tags = false
    @State private var followUps = false
    @State private var memoryMode = ChatAssistanceMemoryMode.off
    @State private var personal = false
    @State private var budgets: [ChatAssistanceKind: String] = [:]
    @State private var threshold = "4096"
    @State private var error: String?
    @State private var loaded = false
    private var sectionTitle: String {
        switch section { case .summary: workflowText(copyLanguage, "chat.assistancePanel.automaticSummaries"); case .memory: workflowText(copyLanguage, "chat.assistancePanel.extractMemories"); case .organization: workflowText(copyLanguage, "chat.assistancePanel.conversationOrganization") }
    }
    private func enabled(_ kind: ChatAssistanceKind) -> Bool {
        switch kind { case .summary: summary; case .title: title; case .tags: tags; case .followUps: followUps; case .memory: memoryMode != .off }
    }

    var body: some View {
        DisclosureGroup(sectionTitle, isExpanded: expanded ?? $localExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(workflowText(copyLanguage, "chat.assistancePanel.offByDefaultEnabledTasksRunAfterCompleteAnswersWith"))
                    .font(.caption).foregroundStyle(.secondary)
                if section == .summary { Toggle(workflowText(copyLanguage, "chat.assistancePanel.createSummariesAutomatically"), isOn: $summary) }
                if section == .organization {
                Toggle(workflowText(copyLanguage, "chat.assistancePanel.automaticTitle"), isOn: $title)
                Toggle(workflowText(copyLanguage, "chat.assistancePanel.suggestedTags"), isOn: $tags)
                Toggle(workflowText(copyLanguage, "chat.assistancePanel.followUpSuggestions"), isOn: $followUps)
                }
                if section == .memory {
                WorkbenchPicker(workflowText(copyLanguage, "chat.assistancePanel.memoryExtraction"), selection: $memoryMode) {
                    WorkbenchChoice(workflowText(copyLanguage, "chat.assistancePanel.off"), value:ChatAssistanceMemoryMode.off)
                    WorkbenchChoice(workflowText(copyLanguage, "chat.assistancePanel.reviewSuggestions"), value:ChatAssistanceMemoryMode.suggest)
                    WorkbenchChoice(workflowText(copyLanguage, "chat.assistancePanel.recordAutomatically"), value:ChatAssistanceMemoryMode.automatic)
                }
                if memoryMode != .off {
                    Toggle(workflowText(copyLanguage, "chat.assistancePanel.personalMemoryOtherwiseThisProject"), isOn: $personal)
                    Text(workflowText(copyLanguage, "chat.assistancePanel.recordingAndReadingAreSeparateNewEntriesAreNotInjected"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                ForEach(section.kinds.filter { enabled($0) }, id: \.self) { kind in
                    DisclosureGroup(label(kind) + workflowText(copyLanguage, "chat.assistancePanel.advancedOptions")) {
                        if kind == .summary {
                            TextField(workflowText(copyLanguage, "chat.assistancePanel.summaryThresholdEstimatedTokens"), text: $threshold)
                        }
                        TextField(workflowText(copyLanguage, "chat.knowledgePanel.outputTokenBudget"), text: Binding(
                            get: { budgets[kind] ?? "" }, set: { budgets[kind] = $0 }))
                    }
                }
                Text(hasChanges ? workflowText(copyLanguage, "chat.outputFormatPanel.changesAreNotApplied") : workflowText(copyLanguage, "chat.assistancePanel.showingSavedSettings"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(workflowText(copyLanguage, "chat.assistancePanel.discardThisGroupSEdits")) { load() }.disabled(!hasChanges)
                Button(workflowText(copyLanguage, "chat.assistancePanel.applyThisGroup")) { apply() }
                    .accessibilityIdentifier("chat-assistance-apply").disabled(!hasChanges)
                Text(workflowText(copyLanguage, "chat.assistancePanel.theRunCommandBelowRunsAllSavedEnabledTasksIncluding")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(workflowText(copyLanguage, "chat.assistancePanel.runAllEnabledTasksInThisConversation")) {
                        do { try chat.runAssistance(sessionID: session.id); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(chat.isRunning || chat.isAssisting || chat.pendingAssistanceSaveID != nil
                        || !ChatAssistanceKind.allCases.contains { (session.assistanceOptions ?? .init()).isEnabled($0) })
                    if chat.isAssisting {
                        Button(workflowText(copyLanguage, "chat.assistancePanel.stopAssistance")) { Task { await chat.cancelAssistance() } }
                    }
                }
                if chat.pendingAssistanceSaveID != nil {
                    Button(workflowText(copyLanguage, "chat.assistancePanel.retrySavingAssistance")) {
                        Task { do { try await chat.retryAssistanceSave() } catch { self.error = error.localizedDescription } }
                    }
                }
                if !chat.assistancePhase.isEmpty { Text(chat.assistancePhase).font(.caption).textSelection(.enabled) }
                if let error { WorkbenchIssueText(raw: error).foregroundStyle(.red).textSelection(.enabled) }
                ForEach((session.assistanceExecutions ?? []).filter { section.kinds.contains($0.record.kind) }.reversed()) { execution in
                    DisclosureGroup(label(execution.record.kind) + " · " + execution.record.status.rawValue) {
                        Text(workflowText(copyLanguage, "chat.assistancePanel.outputBudget") + String(execution.record.maximumOutputTokens))
                        if let issue = execution.record.issue { WorkbenchIssueText(raw: issue).foregroundStyle(.red) }
                        if let result = execution.record.result {
                            switch result {
                            case .summary(let text), .title(let text): Text(text).textSelection(.enabled)
                            case .tags(let texts), .memory(let texts): Text(texts.joined(separator: "\n")).textSelection(.enabled)
                            case .followUps(let texts):
                                ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                                    Button(text) {
                                        do { try chat.appendAssistanceFollowUp(text, executionID: execution.id, sessionID: session.id) }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }
                            }
                        }
                        DisclosureGroup(workflowText(copyLanguage, "chat.assistancePanel.technicalDetails")) {
                            Text("ID: " + execution.id.uuidString).font(.caption).textSelection(.enabled)
                            Text(workflowText(copyLanguage, "chat.assistancePanel.source") + execution.record.source.sha256).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }.padding(.vertical, 6)
        }.onAppear { if !loaded { load(); loaded = true } }.accessibilityIdentifier("chat-assistance-panel")
    }
    private func label(_ kind: ChatAssistanceKind) -> String {
        switch kind {
        case .summary: workflowText(copyLanguage, "chat.assistancePanel.summary")
        case .title: workflowText(copyLanguage, "chat.artifactEditor.title")
        case .tags: workflowText(copyLanguage, "consistency.LIB-TAGS")
        case .followUps: workflowText(copyLanguage, "chat.assistancePanel.followUps")
        case .memory: workflowText(copyLanguage, "chat.assistancePanel.memory")
        }
    }
    private var hasChanges: Bool {
        let o = chat.state.sessions.first { $0.id == session.id }?.assistanceOptions ?? .init()
        let switchChanged: Bool
        switch section {
        case .summary: switchChanged = summary != o.summary || (summary && threshold != String(o.summaryThresholdEstimatedTokens))
        case .memory: switchChanged = memoryMode != o.memoryMode || (memoryMode != .off && personal != (o.memoryTarget == .personal))
        case .organization: switchChanged = title != o.title || tags != o.tags || followUps != o.followUps
        }
        return switchChanged || section.kinds.filter { enabled($0) }.contains {
            budgets[$0] != String(o.outputTokenBudgets.value(for: $0))
        }
    }
    private func load() {
        let o = chat.state.sessions.first { $0.id == session.id }?.assistanceOptions ?? .init()
        summary = o.summary; title = o.title; tags = o.tags; followUps = o.followUps
        memoryMode = o.memoryMode; personal = o.memoryTarget == .personal
        threshold = String(o.summaryThresholdEstimatedTokens)
        for kind in ChatAssistanceKind.allCases { budgets[kind] = String(o.outputTokenBudgets.value(for: kind)) }
    }
    private func apply() {
        do {
            let current = chat.state.sessions.first { $0.id == session.id }?.assistanceOptions ?? .init()
            func budget(_ kind: ChatAssistanceKind) throws -> Int {
                guard section.kinds.contains(kind), enabled(kind) else { return current.outputTokenBudgets.value(for: kind) }
                guard let n = Int(budgets[kind] ?? ""), n > 0 else { throw WorkflowIssue("Output budgets must be positive integers / 输出预算须为正整数。") }
                return n
            }
            let limit = section == .summary && summary ? Int(threshold) : current.summaryThresholdEstimatedTokens
            guard let limit, limit > 0 else { throw WorkflowIssue("The summary threshold must be positive / 摘要阈值须为正整数。") }
            let scope: ChatMemoryScope? = personal ? .personal : chat.projectIdentity.map(ChatMemoryScope.project)
            let draft = ChatAssistanceOptions(summary: summary, title: title, tags: tags, followUps: followUps,
                memoryMode: memoryMode, memoryTarget: memoryMode == .off ? nil : scope,
                outputTokenBudgets: try .init(summary: budget(.summary), title: budget(.title), tags: budget(.tags),
                    followUps: budget(.followUps), memory: budget(.memory)), summaryThresholdEstimatedTokens: limit)
            try chat.setAssistanceOptions(section.merging(draft, into: current), sessionID: session.id)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
