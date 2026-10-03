import DWorkbench
import SwiftUI

/// One optional settings group, not a second chat composer or model runner.
struct ChatAssistancePanel: View {
    @Bindable var chat: ChatController
    let session: ChatSession
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

    var body: some View {
        DisclosureGroup(wording("Optional model assistance", "可选模型辅助")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(wording("Off by default. Enabled tasks run after complete answers with lower queue priority. Original messages stay unchanged.",
                    "默认关闭。开启的任务在完整回答后低优先级排队，保留原始消息。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(wording("Context summary", "上下文摘要"), isOn: $summary)
                Toggle(wording("Automatic title", "自动命名"), isOn: $title)
                Toggle(wording("Suggested tags", "建议标签"), isOn: $tags)
                Toggle(wording("Follow-up suggestions", "建议追问"), isOn: $followUps)
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
                TextField(wording("Summary threshold (estimated tokens)", "摘要阈值（估计 token）"), text: $threshold)
                ForEach(ChatAssistanceKind.allCases, id: \.self) { kind in
                    TextField(label(kind) + wording(" output tokens", "输出 token"), text: Binding(
                        get: { budgets[kind] ?? "" }, set: { budgets[kind] = $0 }))
                }
                Button(wording("Apply assistance settings", "应用辅助设置")) { apply() }
                    .accessibilityIdentifier("chat-assistance-apply")
                HStack {
                    Button(wording("Run enabled tasks now", "运行已开启任务")) {
                        do { try chat.runAssistance(sessionID: session.id); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(chat.isRunning || chat.isAssisting || chat.pendingAssistanceSaveID != nil)
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
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                ForEach((session.assistanceExecutions ?? []).reversed()) { execution in
                    DisclosureGroup(label(execution.record.kind) + " · " + execution.record.status.rawValue) {
                        Text("ID: " + execution.id.uuidString).font(.caption).textSelection(.enabled)
                        Text(wording("Output budget: ", "输出预算：") + String(execution.record.maximumOutputTokens))
                        if let issue = execution.record.issue { Text(issue).foregroundStyle(.red) }
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
                        Text(wording("Source: ", "来源：") + execution.record.source.sha256).font(.caption).textSelection(.enabled)
                    }
                }
            }.padding(.vertical, 6)
        }.onAppear { load() }.accessibilityIdentifier("chat-assistance-panel")
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
    private func load() {
        let o = session.assistanceOptions ?? .init()
        summary = o.summary; title = o.title; tags = o.tags; followUps = o.followUps
        memoryMode = o.memoryMode; personal = o.memoryTarget == .personal
        threshold = String(o.summaryThresholdEstimatedTokens)
        for kind in ChatAssistanceKind.allCases { budgets[kind] = String(o.outputTokenBudgets.value(for: kind)) }
    }
    private func apply() {
        do {
            func budget(_ kind: ChatAssistanceKind) throws -> Int {
                guard let n = Int(budgets[kind] ?? ""), n > 0 else { throw WorkflowIssue("Output budgets must be positive integers / 输出预算须为正整数。") }
                return n
            }
            guard let limit = Int(threshold), limit > 0 else { throw WorkflowIssue("The summary threshold must be positive / 摘要阈值须为正整数。") }
            let scope: ChatMemoryScope? = personal ? .personal : chat.projectIdentity.map(ChatMemoryScope.project)
            try chat.setAssistanceOptions(.init(summary: summary, title: title, tags: tags, followUps: followUps,
                memoryMode: memoryMode, memoryTarget: memoryMode == .off ? nil : scope,
                outputTokenBudgets: try .init(summary: budget(.summary), title: budget(.title), tags: budget(.tags),
                    followUps: budget(.followUps), memory: budget(.memory)), summaryThresholdEstimatedTokens: limit), sessionID: session.id)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
