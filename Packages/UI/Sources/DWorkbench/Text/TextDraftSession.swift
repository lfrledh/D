import DInference
import Foundation
import Observation

@MainActor @Observable
public final class TextDraftSession {
    public private(set) var document: TextDraftDocument
    public private(set) var candidate: TextRewriteCandidate?
    public private(set) var partialText = ""
    public private(set) var isRunning = false
    public private(set) var isCancelling = false
    public private(set) var errorMessage: String?

    private let engine: any InferenceEngine
    private let backendID: String
    private var activeRun: InferenceRun?
    private var cancellationRequested = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    private var undoRecord: UndoRecord?

    private struct UndoRecord {
        let acceptedDocument: TextDraftDocument
        let previousText: String
    }

    public init(document: TextDraftDocument, engine: any InferenceEngine, backendID: String) {
        self.document = document
        self.engine = engine
        self.backendID = backendID
    }

    public var canAcceptCandidate: Bool {
        guard let candidate,
              candidate.selection.documentID == document.id,
              candidate.selection.documentRevision == document.revision,
              let range = candidate.selection.range(in: document.text) else { return false }
        return String(document.text[range]) == candidate.selection.selectedText
    }

    public func selection(inUTF16 range: NSRange) throws -> TextRewriteSelection {
        try TextRewriteSelection(document: document, range: range)
    }

    public func editText(_ text: String) throws {
        try TextDraftDocument.validate(text)
        guard text != document.text else { return }
        document = try TextDraftDocument(id: document.id, text: text)
        undoRecord = nil
    }

    public func requestRewrite(selection: TextRewriteSelection, instruction: String,
                               model: ModelReference, maxTokens: Int = 256,
                               temperature: Float = 0.7, topP: Float = 0.95) async throws {
        guard !isRunning else { throw TextDraftError.alreadyRunning }
        guard selection.documentID == document.id,
              selection.documentRevision == document.revision,
              let range = selection.range(in: document.text),
              String(document.text[range]) == selection.selectedText else {
            throw TextDraftError.invalidSelection
        }
        let textRequest = TextRequest(
            prompt: "Rewrite the selected passage according to the instruction. Return only the replacement text.\n\nInstruction:\n\(instruction)\n\nSelected passage:\n\(selection.selectedText)",
            maxTokens: maxTokens, temperature: temperature, topP: topP)
        let request = InferenceRequest(model: model, input: .text(textRequest))
        try request.validate()

        candidate = nil
        partialText = ""
        errorMessage = nil
        isRunning = true
        isCancelling = false
        cancellationRequested = false

        do {
            let run = try await engine.submit(request, backendID: backendID)
            activeRun = run
            if cancellationRequested || Task.isCancelled { await run.cancel() }

            var replacement = ""
            var localError: TextDraftError?
            do {
                stream: for try await output in run.events {
                    if cancellationRequested || Task.isCancelled {
                        await run.cancel()
                        break stream
                    }
                    guard case .textDelta(let delta) = output else {
                        localError = .nonTextOutput
                        await run.cancel()
                        break stream
                    }
                    replacement.append(delta)
                    guard replacement.utf8.count <= TextDraftDocument.maximumUTF8Bytes else {
                        localError = .replacementTooLarge
                        await run.cancel()
                        break stream
                    }
                    partialText = replacement
                }
            } catch {
                if !cancellationRequested && !Task.isCancelled {
                    localError = .inferenceFailed(error.localizedDescription)
                }
            }

            if cancellationRequested || Task.isCancelled { await run.cancel() }
            let outcome = await run.outcome()
            let wasCancelled = cancellationRequested || Task.isCancelled
            activeRun = nil
            finishRun()

            if wasCancelled { throw CancellationError() }
            if let localError { throw localError }
            switch outcome {
            case .completed(let result):
                guard !replacement.isEmpty else { throw TextDraftError.emptyReplacement }
                candidate = TextRewriteCandidate(runID: run.id, selection: selection,
                                                 replacement: replacement, request: request, result: result)
            case .cancelled:
                throw CancellationError()
            case .failed(let failure):
                throw TextDraftError.inferenceFailed(failure.localizedDescription)
            }
        } catch {
            if activeRun == nil { finishRun() }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            throw error
        }
    }

    public func cancel() async {
        guard isRunning else { return }
        cancellationRequested = true
        isCancelling = true
        if let activeRun { await activeRun.cancel() }
        await waitForRunCompletion()
    }

    public func acceptCandidate() throws {
        guard let candidate, canAcceptCandidate,
              let range = candidate.selection.range(in: document.text) else {
            throw TextDraftError.noAcceptableCandidate
        }
        let previousText = document.text
        var updated = document.text
        updated.replaceSubrange(range, with: candidate.replacement)
        try TextDraftDocument.validate(updated)
        let accepted = try TextDraftDocument(id: document.id, text: updated)
        document = accepted
        undoRecord = UndoRecord(acceptedDocument: accepted, previousText: previousText)
        self.candidate = nil
    }

    public func rejectCandidate() {
        candidate = nil
        partialText = ""
    }

    public func undoAcceptedRewrite() throws {
        guard let undoRecord, undoRecord.acceptedDocument.revision == document.revision else {
            throw TextDraftError.noUndoAvailable
        }
        document = try TextDraftDocument(id: document.id, text: undoRecord.previousText)
        self.undoRecord = nil
    }

    private func waitForRunCompletion() async {
        guard isRunning else { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }

    private func finishRun() {
        guard isRunning else { return }
        isRunning = false
        isCancelling = false
        cancellationRequested = false
        completionWaiters.forEach { $0.resume() }
        completionWaiters.removeAll()
    }
}
