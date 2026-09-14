import DInference
import Foundation
import Observation

/// Application operation: frozen source context, candidate decisions, and one authoritative persistence callback.
@MainActor @Observable
public final class ProjectTextSourcesController {
    public private(set) var notebook: TextSourcesNotebook
    public private(set) var document: TextDraftDocument
    public private(set) var partialAnswer = ""
    public private(set) var isRunning = false
    public private(set) var isCancelling = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public private(set) var unsavedCompletedRecord: TextSourceAnswerRecord?
    public var isDirty: Bool { notebook.revision != persistedRevision || unsavedCompletedRecord != nil }
    public var canAsk: Bool {
        !isRunning && !isSaving && unsavedCompletedRecord == nil && !notebook.excerpts.isEmpty &&
        !notebook.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        notebook.records.count < TextSourcesLimits.records
    }
    public var canUndo: Bool { undoRecord?.acceptedRevision == document.revision && !isRunning && !isSaving }

    private var engine: any InferenceEngine
    private var backendID: String
    private let persist: @MainActor (TextSourcesNotebook, UUID, TextDraftDocument?, UUID) async throws -> Void
    private var persistedRevision: UUID
    private var activeRun: InferenceRun?
    private var operationID: UUID?
    private var cancelled = false
    private var cancellationSent = false
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var undoRecord: (recordID: UUID, acceptedRevision: UUID, previous: TextDraftDocument)?

    public init(notebook: TextSourcesNotebook, document: TextDraftDocument, engine: any InferenceEngine,
                backendID: String,
                persist: @escaping @MainActor (TextSourcesNotebook, UUID, TextDraftDocument?, UUID) async throws -> Void) throws {
        try TextSourcesArchive.validate(notebook)
        self.notebook = notebook; self.document = document; self.engine = engine
        self.backendID = backendID; self.persist = persist; persistedRevision = notebook.revision
    }

    public func synchronizeTarget(_ value: TextDraftDocument) {
        guard value.id == document.id else { return }
        document = value
        if undoRecord?.acceptedRevision != value.revision { undoRecord = nil }
    }

    func rebind(engine: any InferenceEngine, backendID: String) {
        guard !isRunning, !isSaving else { return }
        self.engine = engine; self.backendID = backendID; undoRecord = nil
    }

    public func changeQuestion(_ value: String) {
        guard !isSaving else { errorMessage = "正在保存，请稍后修改问题。"; return }
        guard !value.utf8.elementsEqual(notebook.question.utf8) else { return }
        changeInput { $0.question = value }
    }

    public func addSource(_ source: TextSourceSnapshot) {
        changeInput { note in
            note.sources.append(source)
            note.excerpts.append(try TextSourceReader.excerpt(from: source))
        }
    }

    public func removeSource(id: UUID) {
        changeInput { note in
            note.sources.removeAll { $0.id == id }
            note.excerpts.removeAll { $0.sourceID == id }
        }
    }

    public func useExcerpt(sourceID: UUID, range: NSRange?) {
        changeInput { note in
            guard let source = note.sources.first(where: { $0.id == sourceID }) else { throw TextSourcesError.stale }
            let excerpt = try TextSourceReader.excerpt(from: source, range: range)
            note.excerpts.removeAll { $0.sourceID == sourceID }
            note.excerpts.append(excerpt)
        }
    }

    private func changeInput(_ change: (inout TextSourcesNotebook) throws -> Void) {
        guard !isSaving else { errorMessage = "正在保存，请稍后修改资料。"; return }
        do {
            var changed = notebook; try change(&changed)
            changed.revision = UUID(); changed.inputRevision = UUID()
            try TextSourcesArchive.validate(changed)
            notebook = changed; errorMessage = nil
        } catch { errorMessage = "资料未改变：\(error.localizedDescription)" }
    }

    public func canAccept(_ record: TextSourceAnswerRecord) -> Bool {
        guard !isRunning, !isSaving, record.disposition == .pending,
              notebook.records.contains(where: { $0.id == record.id }),
              record.submission.notebookRevision == notebook.inputRevision,
              record.submission.targetDocumentID == document.id,
              record.submission.targetDocumentRevision == document.revision else { return false }
        let check = TextSourcesContext.citations(in: record.answer, submission: record.submission)
        return !check.validLabels.isEmpty && check.invalidLabels.isEmpty
    }

    public func citationSummary(_ record: TextSourceAnswerRecord) -> String {
        TextSourcesContext.citations(in: record.answer, submission: record.submission).summary
    }

    public func ask(using model: ModelReference, modelID: String,
                    validate: @Sendable (ModelReference) async throws -> ModelReference = { $0 }) async {
        guard canAsk else { return }
        let operation = UUID(); operationID = operation
        isRunning = true; isCancelling = false; cancelled = false; cancellationSent = false
        partialAnswer = ""; errorMessage = nil
        defer { finishOperation(operation) }
        do {
            let capturedNotebook = notebook, capturedTarget = document
            let verified = try await validate(model)
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            guard capturedNotebook.inputRevision == notebook.inputRevision,
                  capturedTarget.revision == document.revision else { throw TextSourcesError.stale }
            let submission = try TextSourcesContext.makeSubmission(notebook: capturedNotebook, target: capturedTarget,
                modelID: modelID, modelRevision: verified.revision)
            let request = InferenceRequest(id: submission.id, model: verified, input: .text(submission.request))
            try request.validate()
            let run = try await engine.submit(request, backendID: backendID)
            activeRun = run
            if cancelled || Task.isCancelled { cancelled = true; await sendCancellation() }
            var answer = ""
            var streamError: (any Error)?
            if run.id != request.id { streamError = TextSourcesError.invalid("运行编号与提交记录不符。"); await sendCancellation() }
            do {
                for try await event in run.events {
                    if cancelled || Task.isCancelled { cancelled = true; await sendCancellation(); continue }
                    if streamError != nil { await sendCancellation(); continue }
                    guard case .textDelta(let delta) = event else {
                        streamError = TextDraftError.nonTextOutput; await sendCancellation(); continue
                    }
                    guard delta.utf8.count <= TextDraftDocument.maximumUTF8Bytes - answer.utf8.count else {
                        streamError = TextDraftError.replacementTooLarge; await sendCancellation(); continue
                    }
                    answer.append(delta); partialAnswer = answer
                }
            } catch { streamError = error; await sendCancellation() }
            let result = await withTaskCancellationHandler(operation: { await run.outcome() }, onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == operation else { return }
                    self.cancelled = true; await self.sendCancellation()
                }
            })
            activeRun = nil
            guard !cancelled, !Task.isCancelled else { throw CancellationError() }
            if let streamError { throw streamError }
            let metrics: [String: String]
            switch result {
            case .completed(let output): metrics = Self.safeMetrics(output.metadata)
            case .cancelled: throw CancellationError()
            case .failed(let failure): throw failure
            }
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextDraftError.emptyReplacement }
            unsavedCompletedRecord = .init(submission: submission, answer: answer, metrics: metrics)
            // The task remains busy until both runtime outcome and this save have resolved.
            do { try await flush() }
            catch { errorMessage = "回答已生成，但尚未保存；原文未改变，请重试保存：\(error.localizedDescription)" }
        } catch is CancellationError {
            errorMessage = "已取消，原文和已有记录保持不变。"
        } catch { errorMessage = "回答未完成，原文已保留：\(error.localizedDescription)" }
    }

    public func cancel() async {
        guard isRunning, let operation = operationID else { return }
        cancelled = true; isCancelling = true
        await sendCancellation()
        if operationID == operation { await withCheckedContinuation { waiters[operation, default: []].append($0) } }
    }

    private func sendCancellation() async {
        guard let activeRun, !cancellationSent else { return }
        cancellationSent = true; isCancelling = true
        await activeRun.cancel()
    }

    private func finishOperation(_ operation: UUID) {
        guard operationID == operation else { return }
        activeRun = nil; operationID = nil; isRunning = false; isCancelling = false
        cancelled = false; cancellationSent = false
        let completed = waiters.removeValue(forKey: operation) ?? []; completed.forEach { $0.resume() }
    }

    public func flush() async throws {
        guard !isSaving else { throw TextSourcesError.busy }
        guard isDirty else { return }
        isSaving = true; defer { isSaving = false }
        do {
            if let record = unsavedCompletedRecord {
                var updated = notebook
                updated.records.append(record); updated.revision = UUID()
                try TextSourcesArchive.validate(updated)
                notebook = updated; unsavedCompletedRecord = nil
            }
            let snapshot = notebook
            try await persist(snapshot, persistedRevision, nil, document.revision)
            persistedRevision = snapshot.revision; errorMessage = nil
        } catch { errorMessage = "资料/回答尚未保存，当前内容已保留：\(error.localizedDescription)"; throw error }
    }

    public func accept(id: UUID) async {
        guard let index = notebook.records.firstIndex(where: { $0.id == id }), canAccept(notebook.records[index]) else {
            errorMessage = "回答已过期或引用未验证；原文未改变。"; return
        }
        do {
            try await flush()
            let record = notebook.records[index]
            guard canAccept(record) else { throw TextSourcesError.stale }
            let previous = document
            let text = document.text + (document.text.isEmpty ? "" : "\n\n") + record.answer
            let accepted = try TextDraftDocument(id: document.id, text: text, generationSettings: document.generationSettings)
            var updated = notebook; updated.records[index].disposition = .accepted; updated.revision = UUID()
            try await commitDecision(updated, replacement: accepted)
            if document.revision == accepted.revision { undoRecord = (id, accepted.revision, previous) }
        } catch { errorMessage = "未采用回答，原文已保留：\(error.localizedDescription)" }
    }

    public func reject(id: UUID) async {
        guard !isRunning, !isSaving, let index = notebook.records.firstIndex(where: { $0.id == id }),
              notebook.records[index].disposition == .pending else { return }
        do {
            try await flush()
            var updated = notebook; updated.records[index].disposition = .rejected; updated.revision = UUID()
            try await commitDecision(updated, replacement: nil)
        } catch { errorMessage = "拒绝状态尚未保存，原文和记录已保留：\(error.localizedDescription)" }
    }

    public func undo() async {
        guard canUndo, let undoRecord,
              let index = notebook.records.firstIndex(where: { $0.id == undoRecord.recordID }) else { return }
        do {
            try await flush()
            guard document.revision == undoRecord.acceptedRevision else { throw TextSourcesError.stale }
            let restored = try TextDraftDocument(id: document.id, text: undoRecord.previous.text,
                                                generationSettings: undoRecord.previous.generationSettings)
            var updated = notebook; updated.records[index].disposition = .undone; updated.revision = UUID()
            try await commitDecision(updated, replacement: restored)
            self.undoRecord = nil
        } catch { errorMessage = "无法撤销，现有正文已保留：\(error.localizedDescription)" }
    }

    private func commitDecision(_ updated: TextSourcesNotebook, replacement: TextDraftDocument?) async throws {
        try TextSourcesArchive.validate(updated)
        isSaving = true; defer { isSaving = false }
        let targetRevision = document.revision
        try await persist(updated, persistedRevision, replacement, targetRevision)
        notebook = updated; persistedRevision = updated.revision
        if let replacement, document.revision == targetRevision { document = replacement }
        errorMessage = nil
    }

    private static func safeMetrics(_ values: [String: String]) -> [String: String] {
        let keys: Set<String> = ["promptTokens", "generationTokens", "promptSeconds", "generationSeconds",
            "stopReason", "upstreamStopReason", "modelRevision", "randomSeed", "weightBytes", "estimatedPeakBytes",
            "executionProfileIdentifier", "executionProfileRevision", "maximumPromptTokens", "maximumOutputTokens"]
        return values.filter { keys.contains($0.key) && $0.value.utf8.count <= 512 }
    }
}
