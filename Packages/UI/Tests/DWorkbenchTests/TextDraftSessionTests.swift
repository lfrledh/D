import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor TextDraftGate {
    private var reached = false
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arrive() async {
        reached = true
        guard !open else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func hasReached() -> Bool { reached }

    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ImmediateTextDraftEngine: InferenceEngine {
    let outputs: [InferenceOutput]
    let outcome: RunOutcome
    private(set) var requests: [InferenceRequest] = []
    private(set) var cancellationCount = 0

    init(outputs: [InferenceOutput], outcome: RunOutcome = .completed(.init(metadata: ["fixture": "yes"]))) {
        self.outputs = outputs
        self.outcome = outcome
    }

    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        let outputs = self.outputs
        let outcome = self.outcome
        let stream = AsyncThrowingStream<InferenceOutput, Error> { continuation in
            outputs.forEach { continuation.yield($0) }
            continuation.finish()
        }
        return InferenceRun(id: request.id, events: stream,
                            cancel: { await self.recordCancellation() }, outcome: { outcome })
    }

    private func recordCancellation() { cancellationCount += 1 }
}

private actor AdmissionBlockingTextDraftEngine: InferenceEngine {
    let gate: TextDraftGate
    private(set) var cancellationCount = 0

    init(gate: TextDraftGate) { self.gate = gate }

    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        await gate.arrive()
        return InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() },
                            cancel: { await self.recordCancellation() }, outcome: { .cancelled })
    }

    private func recordCancellation() { cancellationCount += 1 }
}

@Suite("Text draft session", .serialized) @MainActor
struct TextDraftSessionTests {
    private let model = ModelReference(directory: URL(fileURLWithPath: "/tmp/text-draft-model", isDirectory: true))

    @Test func selectionRejectsUnicodeInteriorAndOverflowRanges() throws {
        let engine = ImmediateTextDraftEngine(outputs: [])
        let subject = TextDraftSession(document: try TextDraftDocument(text: "中e\u{301}👩‍💻🇯🇵Z"), engine: engine, backendID: "fixture")
        let emojiInterior = NSRange(location: 3, length: 1)
        #expect(throws: TextDraftError.invalidSelection) { try subject.selection(inUTF16: emojiInterior) }
        #expect(throws: TextDraftError.invalidSelection) { try subject.selection(inUTF16: NSRange(location: 9, length: 1)) }
        #expect(throws: TextDraftError.invalidSelection) { try subject.selection(inUTF16: NSRange(location: Int.max, length: 1)) }
        #expect(throws: TextDraftError.invalidSelection) { try subject.selection(inUTF16: NSRange(location: 1, length: 1)) }

        let selected = try subject.selection(inUTF16: NSRange(location: 0, length: 1))
        #expect(selected.selectedText == "中")
    }

    @Test func acceptedCandidateOnlyReplacesSelectionAndCanBeUndoneOnce() async throws {
        let engine = ImmediateTextDraftEngine(outputs: [.textDelta("better")])
        let subject = TextDraftSession(document: try TextDraftDocument(text: "before old after"), engine: engine, backendID: "fixture")
        let selection = try subject.selection(inUTF16: NSRange(location: 7, length: 3))
        let before = subject.document.revision
        try await subject.requestRewrite(selection: selection, instruction: "Improve it", model: model)

        let submitted = try #require(await engine.requests.first)
        if case .text(let request) = submitted.input {
            #expect(request.prompt.contains("Instruction:\nImprove it"))
            #expect(request.prompt.contains("Selected passage:\nold"))
        } else { Issue.record("Expected text request") }
        #expect(subject.canAcceptCandidate)
        try subject.acceptCandidate()
        #expect(subject.document.text == "before better after")
        #expect(subject.document.revision != before)
        #expect(subject.candidate == nil)
        #expect(throws: TextDraftError.noAcceptableCandidate) { try subject.acceptCandidate() }

        let acceptedRevision = subject.document.revision
        try subject.undoAcceptedRewrite()
        #expect(subject.document.text == "before old after")
        #expect(subject.document.revision != acceptedRevision)
        #expect(throws: TextDraftError.noUndoAvailable) { try subject.undoAcceptedRewrite() }
    }

    @Test func manualEditAfterAcceptanceCannotBeUndoneOverAuthorWork() async throws {
        let engine = ImmediateTextDraftEngine(outputs: [.textDelta("new")])
        let subject = TextDraftSession(document: try TextDraftDocument(text: "old"), engine: engine, backendID: "fixture")
        let selection = try subject.selection(inUTF16: NSRange(location: 0, length: 3))
        try await subject.requestRewrite(selection: selection, instruction: "Change", model: model)
        try subject.acceptCandidate()
        try subject.editText("author text")
        #expect(throws: TextDraftError.noUndoAvailable) { try subject.undoAcceptedRewrite() }
        #expect(subject.document.text == "author text")
    }

    @Test func lateCandidateCannotOverwriteAnEditedDraftAndRejectDoesNotEdit() async throws {
        let engine = ImmediateTextDraftEngine(outputs: [.textDelta("replacement")])
        let subject = TextDraftSession(document: try TextDraftDocument(text: "one two three"), engine: engine, backendID: "fixture")
        let selection = try subject.selection(inUTF16: NSRange(location: 4, length: 3))
        try await subject.requestRewrite(selection: selection, instruction: "Change", model: model)
        try subject.editText("manually edited")
        #expect(!subject.canAcceptCandidate)
        #expect(throws: TextDraftError.noAcceptableCandidate) { try subject.acceptCandidate() }
        subject.rejectCandidate()
        #expect(subject.document.text == "manually edited")
    }

    @Test func nonTextAndEmptyOutputNeverBecomeCandidates() async throws {
        let nonTextEngine = ImmediateTextDraftEngine(outputs: [.progress(completed: 1, total: 2)])
        let subject = TextDraftSession(document: try TextDraftDocument(text: "draft"), engine: nonTextEngine, backendID: "fixture")
        let selection = try subject.selection(inUTF16: NSRange(location: 0, length: 5))
        await #expect(throws: TextDraftError.nonTextOutput) {
            try await subject.requestRewrite(selection: selection, instruction: "Change", model: model)
        }
        #expect(subject.candidate == nil)
        #expect(await nonTextEngine.cancellationCount == 1)

        let emptyEngine = ImmediateTextDraftEngine(outputs: [])
        let empty = TextDraftSession(document: try TextDraftDocument(text: "draft"), engine: emptyEngine, backendID: "fixture")
        await #expect(throws: TextDraftError.emptyReplacement) {
            try await empty.requestRewrite(selection: try empty.selection(inUTF16: NSRange(location: 0, length: 5)), instruction: "Change", model: model)
        }
        #expect(empty.candidate == nil)

        let failedEngine = ImmediateTextDraftEngine(outputs: [.textDelta("partial")], outcome: .failed(.backendFailed("fixture failure")))
        let failed = TextDraftSession(document: try TextDraftDocument(text: "draft"), engine: failedEngine, backendID: "fixture")
        await #expect(throws: TextDraftError.inferenceFailed("fixture failure")) {
            try await failed.requestRewrite(selection: try failed.selection(inUTF16: NSRange(location: 0, length: 5)), instruction: "Change", model: model)
        }
        #expect(failed.candidate == nil)
    }

    @Test func cancellationBeforeSubmitReturnsKeepsSessionBusyUntilOutcome() async throws {
        let gate = TextDraftGate()
        let engine = AdmissionBlockingTextDraftEngine(gate: gate)
        let subject = TextDraftSession(document: try TextDraftDocument(text: "draft"), engine: engine, backendID: "fixture")
        let selection = try subject.selection(inUTF16: NSRange(location: 0, length: 5))
        let rewrite = Task { try await subject.requestRewrite(selection: selection, instruction: "Change", model: model) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !await gate.hasReached() {
            if ContinuousClock.now >= deadline { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(subject.isRunning)
        let cancellation = Task { await subject.cancel() }
        #expect(subject.isCancelling)
        await #expect(throws: TextDraftError.alreadyRunning) {
            try await subject.requestRewrite(selection: selection, instruction: "Again", model: model)
        }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await rewrite.value }
        await cancellation.value
        #expect(!subject.isRunning)
        #expect(await engine.cancellationCount == 1)
    }
}
