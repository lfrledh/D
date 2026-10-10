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
        switch section { case .summary: wording("Automatic summaries", "自动摘要"); case .memory: wording("Extract memories", "记忆提取"); case .organization: wording("Conversation organization", "会话整理") }
    }
    private func enabled(_ kind: ChatAssistanceKind) -> Bool {
        switch kind { case .summary: summary; case .title: title; case .tags: tags; case .followUps: followUps; case .memory: memoryMode != .off }
    }

    var body: some View {
        DisclosureGroup(sectionTitle, isExpanded: expanded ?? $localExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(wording("Off by default. Enabled tasks run after complete answers with lower queue priority. Original messages stay unchanged.",
                    "默认关闭。开启的任务在完整回答后低优先级排队，保留原始消息。"))
                    .font(.caption).foregroundStyle(.secondary)
                if section == .summary { Toggle(wording("Create summaries automatically", "自动生成摘要"), isOn: $summary) }
                if section == .organization {
                Toggle(wording("Automatic title", "自动命名"), isOn: $title)
                Toggle(wording("Suggested tags", "建议标签"), isOn: $tags)
                Toggle(wording("Follow-up suggestions", "建议追问"), isOn: $followUps)
                }
                if section == .memory {
                Picker(wording("Memory extraction", "记忆提取"), selection: $memoryMode) {
                    Text(wording("Off", "关闭")).tag(ChatAssistanceMemoryMode.off)
                    Text(wording("Review suggestions", "审核建议")).tag(ChatAssistanceMemoryMode.suggest)
                    Text(wording("Record automatically", "自动记录")).tag(ChatAssistanceMemoryMode.automatic)
                }
                if memoryMode != .off {
                    Toggle(wording("Personal memory (otherwise this project)", "个人记忆（关闭则为本项目）"), isOn: $personal)
                    Text(wording("Recording and reading are separate. New entries are not injected until enabled in Memory.",
                        "记录与读取分开：新条目不会自动发送，需在记忆中启用。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                ForEach(section.kinds.filter { enabled($0) }, id: \.self) { kind in
                    DisclosureGroup(label(kind) + wording(" advanced options", "高级选项")) {
                        if kind == .summary {
                            TextField(wording("Summary threshold (estimated tokens)", "摘要阈值（估计 token）"), text: $threshold)
                        }
                        TextField(wording("Output token budget", "输出 token 预算"), text: Binding(
                            get: { budgets[kind] ?? "" }, set: { budgets[kind] = $0 }))
                    }
                }
                Text(hasChanges ? wording("Changes are not applied", "修改尚未应用") : wording("Showing saved settings", "当前为已保存设置"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(wording("Discard this group's edits", "放弃本组修改")) { load() }.disabled(!hasChanges)
                Button(wording("Apply this group", "应用本组设置")) { apply() }
                    .accessibilityIdentifier("chat-assistance-apply").disabled(!hasChanges)
                Text(wording("The run command below runs all saved enabled tasks, including other groups.", "下方运行命令会执行本会话所有已保存并开启的任务，包含其他分组。")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(wording("Run all enabled tasks in this conversation", "运行本会话所有已开启任务")) {
                        do { try chat.runAssistance(sessionID: session.id); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(chat.isRunning || chat.isAssisting || chat.pendingAssistanceSaveID != nil
                        || !ChatAssistanceKind.allCases.contains { (session.assistanceOptions ?? .init()).isEnabled($0) })
                    if chat.isAssisting {
                        Button(wording("Stop assistance", "停止辅助")) { Task { await chat.cancelAssistance() } }
                    }
                }
                if chat.pendingAssistanceSaveID != nil {
                    Button(wording("Retry saving assistance", "重试保存辅助结果")) {
                        Task { do { try await chat.retryAssistanceSave() } catch { self.error = error.localizedDescription } }
                    }
                }
                if !chat.assistancePhase.isEmpty { Text(chat.assistancePhase).font(.caption).textSelection(.enabled) }
                if let error { Text(ChatErrorText.display(error, language: language)).foregroundStyle(.red).textSelection(.enabled) }
                ForEach((session.assistanceExecutions ?? []).filter { section.kinds.contains($0.record.kind) }.reversed()) { execution in
                    DisclosureGroup(label(execution.record.kind) + " · " + execution.record.status.rawValue) {
                        Text(wording("Output budget: ", "输出预算：") + String(execution.record.maximumOutputTokens))
                        if let issue = execution.record.issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red) }
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
                        DisclosureGroup(wording("Technical details", "技术详情")) {
                            Text("ID: " + execution.id.uuidString).font(.caption).textSelection(.enabled)
                            Text(wording("Source: ", "来源：") + execution.record.source.sha256).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }.padding(.vertical, 6)
        }.onAppear { if !loaded { load(); loaded = true } }.accessibilityIdentifier("chat-assistance-panel")
    }
    private func label(_ kind: ChatAssistanceKind) -> String {
        switch kind {
        case .summary: wording("Summary", "摘要")
        case .title: wording("Title", "标题")
        case .tags: wording("Tags", "标签")
        case .followUps: wording("Follow-ups", "追问")
        case .memory: wording("Memory", "记忆")
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
