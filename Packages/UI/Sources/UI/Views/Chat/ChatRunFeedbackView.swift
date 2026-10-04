import DWorkbench
import SwiftUI
import Observation

struct ChatRunFeedbackView: View {
    let chat: ChatController
    let attempt: ChatAttempt
    @State private var expanded = false
    @State private var reading = ChatRunFeedbackReading()
    @Environment(\.dLanguageStore) private var language
    private func wording(_ en: String, _ zh: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en
    }
    var body: some View {
        DisclosureGroup(wording("Measured usage and loading", "实际用量与加载方式"), isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    if let feedback = reading.feedback {
                        row("Prompt tokens", "输入token", feedback.promptTokens.map(String.init))
                        row("Generated tokens", "生成token", feedback.generationTokens.map(String.init))
                        row("Application elapsed, including queue/load/release", "应用耗时（含排队/加载/释放）", feedback.applicationSeconds.map { String(format: "%.3f s", $0) })
                        row("Backend generation elapsed", "后端生成耗时", feedback.generationSeconds.map { String(format: "%.3f s", $0) })
                        row("Actual loading", "实际加载", feedback.loadingStrategy)
                    } else { Text(reading.issue ?? wording("Reading…", "正在读取…")) }
                }.font(.caption).textSelection(.enabled)
                    .task(id: attempt.output) {
                        await reading.load { try await chat.runFeedback(for: attempt) }
                    }
            }
        }
    }
    private func row(_ en: String, _ zh: String, _ value: String?) -> some View {
        Text(wording(en, zh) + ": " + (value ?? wording("Unknown / not recorded", "未知／未记录")))
    }
}

/// One inspection owns its values; an uncancellable Store read may finish after
/// SwiftUI has dismissed or replaced that inspection, so publication is guarded.
@MainActor @Observable final class ChatRunFeedbackReading {
    private(set) var feedback: ChatRunFeedback?
    private(set) var issue: String?
    private var ticket: UUID?
    func load(_ read: @MainActor () async throws -> ChatRunFeedback) async {
        let current = UUID(); ticket = current
        feedback = nil; issue = nil
        do {
            let value = try await read()
            guard !Task.isCancelled, ticket == current else { return }
            feedback = value
        } catch {
            guard !Task.isCancelled, ticket == current else { return }
            issue = error.localizedDescription
        }
    }
}
