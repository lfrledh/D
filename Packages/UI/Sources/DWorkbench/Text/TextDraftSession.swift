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
    private var activeOperationID: UUID?
    private var cancellationRequested = false
    private var cancellationSent = false
    private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
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
        guard !text.utf8.elementsEqual(document.text.utf8) else { return }
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
        cancellationSent = false
        activeOperationID = request.id

        do {
            let run = try await engine.submit(request, backendID: backendID)
            activeRun = run
            if Task.isCancelled { cancellationRequested = true }
            if cancellationRequested { await cancelRunIfNeeded(run, operationID: request.id) }

            var replacement = ""
            var localError: TextDraftError?
            do {
                for try await output in run.events {
                    if cancellationRequested || Task.isCancelled {
                        cancellationRequested = true
                        await cancelRunIfNeeded(run, operationID: request.id)
                        continue
                    }
                    if localError != nil {
                        await cancelRunIfNeeded(run, operationID: request.id)
                        continue
                    }
                    guard case .textDelta(let delta) = output else {
                        localError = .nonTextOutput
                        await cancelRunIfNeeded(run, operationID: request.id)
                        continue
                    }
                    replacement.append(delta)
                    guard replacement.utf8.count <= TextDraftDocument.maximumUTF8Bytes else {
                        localError = .replacementTooLarge
                        await cancelRunIfNeeded(run, operationID: request.id)
                        continue
                    }
                    partialText = replacement
                }
            } catch {
                if !cancellationRequested && !Task.isCancelled {
                    localError = .inferenceFailed(error.localizedDescription)
                    await cancelRunIfNeeded(run, operationID: request.id)
                }
            }

            if Task.isCancelled { cancellationRequested = true }
            if cancellationRequested { await cancelRunIfNeeded(run, operationID: request.id) }
            let outcome = await withTaskCancellationHandler(operation: {
                await run.outcome()
            }, onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.requestCancellation(operationID: request.id)
                }
            })
            let wasCancelled = cancellationRequested || Task.isCancelled
            activeRun = nil
            finishRun(operationID: request.id)

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
            if activeRun == nil { finishRun(operationID: request.id) }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            throw error
        }
    }

    public func cancel() async {
        guard isRunning, let operationID = activeOperationID else { return }
        await requestCancellation(operationID: operationID)
        await waitForRunCompletion(operationID: operationID)
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

    private func cancelRunIfNeeded(_ run: InferenceRun, operationID: UUID) async {
        guard activeOperationID == operationID, run.id == operationID, !cancellationSent else { return }
        cancellationSent = true
        isCancelling = true
        await run.cancel()
    }

    private func requestCancellation(operationID: UUID) async {
        guard activeOperationID == operationID else { return }
        cancellationRequested = true
        isCancelling = true
        if let activeRun { await cancelRunIfNeeded(activeRun, operationID: operationID) }
    }

    private func waitForRunCompletion(operationID: UUID) async {
        guard activeOperationID == operationID else { return }
        await withCheckedContinuation { completionWaiters[operationID, default: []].append($0) }
    }

    private func finishRun(operationID: UUID) {
        guard activeOperationID == operationID else { return }
        isRunning = false
        isCancelling = false
        cancellationRequested = false
        cancellationSent = false
        activeOperationID = nil
        completionWaiters.removeValue(forKey: operationID)?.forEach { $0.resume() }
    }
}
