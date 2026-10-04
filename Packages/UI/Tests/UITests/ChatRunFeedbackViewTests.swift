import DWorkbench
import Foundation
import Testing
@testable import UI

@Suite("Feedback inspection ownership") @MainActor
struct ChatRunFeedbackViewTests {
    @Test func clearsPreviousAnswerAndRejectsLateRead() async {
        let reading = ChatRunFeedbackReading()
        await reading.load { .init(metadata: ["generationTokens": "12"]) }
        #expect(reading.feedback?.generationTokens == 12)
        var delayed: CheckedContinuation<ChatRunFeedback, Never>?
        let old = Task { await reading.load { await withCheckedContinuation { delayed = $0 } } }
        while delayed == nil { await Task.yield() }
        #expect(reading.feedback == nil && reading.issue == nil)
        await reading.load { .init(metadata: ["generationTokens": "34"]) }
        delayed?.resume(returning: .init(metadata: ["generationTokens": "99"]))
        await old.value
        #expect(reading.feedback?.generationTokens == 34)
    }
    @Test func cancelledInspectionDoesNotPublishSuccessOrError() async {
        let reading = ChatRunFeedbackReading()
        var delayed: CheckedContinuation<ChatRunFeedback, Error>?
        let task = Task { await reading.load { try await withCheckedThrowingContinuation { delayed = $0 } } }
        while delayed == nil { await Task.yield() }
        task.cancel()
        delayed?.resume(throwing: CancellationError())
        await task.value
        #expect(reading.feedback == nil && reading.issue == nil)
    }
}
