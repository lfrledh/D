import DWorkbench
import SwiftUI
import Observation

struct ChatRunFeedbackView: View {
    let chat: ChatController
    let attempt: ChatAttempt
    @State private var expanded = false
    @State private var reading = ChatRunFeedbackReading()
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        DisclosureGroup(workflowText(language, "chat.runFeedbackView.measuredUsageAndLoading"), isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    if let feedback = reading.feedback {
                        row("chat.runFeedbackView.promptTokens", feedback.promptTokens.map(String.init))
                        row("chat.runFeedbackView.generationTokens", feedback.generationTokens.map(String.init))
                        row("chat.runFeedbackView.applicationElapsed", feedback.applicationSeconds.map { String(format: "%.3f s", $0) })
                        row("chat.runFeedbackView.backendElapsed", feedback.generationSeconds.map { String(format: "%.3f s", $0) })
                        row("chat.runFeedbackView.actualLoading", feedback.loadingStrategy)
                    } else { Text(reading.issue ?? workflowText(language, "chat.runFeedbackView.reading")) }
                }.font(.caption).textSelection(.enabled)
                    .task(id: attempt.output) {
                        await reading.load { try await chat.runFeedback(for: attempt) }
                    }
            }
        }
    }
    private func row(_ key: String, _ value: String?) -> some View {
        Text(workflowText(language, key) + ": " + (value ?? workflowText(language, "chat.runFeedbackView.unknownNotRecorded")))
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
