import DWorkbench
import SwiftUI

struct ChatRunFeedbackView: View {
    let chat: ChatController
    let attempt: ChatAttempt
    @State private var expanded = false
    @State private var feedback: ChatRunFeedback?
    @State private var issue: String?
    @Environment(\.dLanguageStore) private var language
    private func wording(_ en: String, _ zh: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en
    }
    var body: some View {
        DisclosureGroup(wording("Measured usage and loading", "实际用量与加载方式"), isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    if let feedback {
                        row("Prompt tokens", "输入token", feedback.promptTokens.map(String.init))
                        row("Generated tokens", "生成token", feedback.generationTokens.map(String.init))
                        row("Application elapsed, including queue/load/release", "应用耗时（含排队/加载/释放）", feedback.applicationSeconds.map { String(format: "%.3f s", $0) })
                        row("Backend generation elapsed", "后端生成耗时", feedback.generationSeconds.map { String(format: "%.3f s", $0) })
                        row("Actual loading", "实际加载", feedback.loadingStrategy)
                    } else { Text(issue ?? wording("Reading…", "正在读取…")) }
                }.font(.caption).textSelection(.enabled)
                    .task(id: attempt.output) {
                        do { feedback = try await chat.runFeedback(for: attempt); issue = nil }
                        catch { feedback = nil; issue = error.localizedDescription }
                    }
            }
        }
    }
    private func row(_ en: String, _ zh: String, _ value: String?) -> some View {
        Text(wording(en, zh) + ": " + (value ?? wording("Unknown / not recorded", "未知／未记录")))
    }
}
