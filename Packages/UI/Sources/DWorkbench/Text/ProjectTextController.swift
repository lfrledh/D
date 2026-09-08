import DInference
import Foundation
import Observation

/// One project's active text document. Persistence and runtime ownership remain with the host.
@MainActor @Observable
public final class ProjectTextController {
    public private(set) var editor: TextDraftSession
    public var instruction = ""
    public private(set) var selection = NSRange(location: 0, length: 0)
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public private(set) var canUndo = false
    private var selectionVersion = UUID()
    private var candidateSelectionVersion: UUID?
    private var persistedRevision: UUID
    private let persist: @MainActor (TextDraftDocument, UUID) async throws -> Void
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var writeTail: Task<Void, Error>?

    public init(document: TextDraftDocument, engine: any InferenceEngine, backendID: String,
                persist: @escaping @MainActor (TextDraftDocument, UUID) async throws -> Void) {
        editor = TextDraftSession(document: document, engine: engine, backendID: backendID)
        persistedRevision = document.revision
        self.persist = persist
    }

    public var isDirty: Bool { persistedRevision != editor.document.revision }
    public var hasPendingCandidate: Bool { editor.candidate != nil }
    public var canAccept: Bool {
        editor.canAcceptCandidate && candidateSelectionVersion == selectionVersion && !editor.isRunning
    }
    public var canRewrite: Bool {
        !editor.isRunning && !hasPendingCandidate && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (try? editor.selection(inUTF16: selection)) != nil
    }
    public var saveStatus: String {
        if let errorMessage { return errorMessage }
        if isSaving { return "正在保存正文…" }
        return isDirty ? "正文尚未保存" : "正文已保存在项目中"
    }

    public func edit(_ text: String, documentID: UUID) {
        guard documentID == editor.document.id else { return }
        do {
            let revision = editor.document.revision
            try editor.editText(text)
            guard revision != editor.document.revision else { return }
            selectionVersion = UUID()
            canUndo = false
            errorMessage = nil
            scheduleSave()
        } catch { errorMessage = "正文未改变：\(error.localizedDescription)" }
    }

    public func select(_ range: NSRange, documentID: UUID) {
        guard documentID == editor.document.id, selection != range else { return }
        selection = range
        selectionVersion = UUID()
    }

    public func rewrite(using model: ModelReference,
                        validate: @Sendable (ModelReference) async throws -> ModelReference = { $0 }) async {
        guard canRewrite else { return }
        errorMessage = nil
        candidateSelectionVersion = selectionVersion
        do {
            let captured = try editor.selection(inUTF16: selection)
            let capturedInstruction = instruction
            let generation = selectionVersion
            let verified = try await validate(model)
            try Task.checkCancellation()
            guard generation == selectionVersion, captured.documentRevision == editor.document.revision else {
                throw ProjectStoreError.invalidProject("校验模型期间原稿或选区已改变，请重新改写。")
            }
            try await editor.requestRewrite(selection: captured, instruction: capturedInstruction, model: verified)
        } catch is CancellationError {
            candidateSelectionVersion = nil
        } catch {
            candidateSelectionVersion = nil
            errorMessage = "改写未完成，原文已保留：\(error.localizedDescription)"
        }
    }

    /// Navigation may replace the project runtime after the old task has drained.
    /// Keep unsaved bytes and the persistence revision; transient undo belongs to the old session.
    func rebind(engine: any InferenceEngine, backendID: String) {
        guard !editor.isRunning, !hasPendingCandidate else { return }
        editor = TextDraftSession(document: editor.document, engine: engine, backendID: backendID)
        canUndo = false
    }

    public func cancel() async { await editor.cancel() }

    public func accept() {
        guard canAccept else { errorMessage = "原稿或选区已改变，请拒绝旧候选后重新生成。"; return }
        do {
            try editor.acceptCandidate()
            selection = NSRange(location: 0, length: 0)
            selectionVersion = UUID()
            candidateSelectionVersion = nil
            canUndo = true
            errorMessage = nil
            scheduleSave()
        } catch { errorMessage = "未采用候选：\(error.localizedDescription)" }
    }

    public func reject() {
        editor.rejectCandidate()
        candidateSelectionVersion = nil
    }

    public func undo() {
        do {
            try editor.undoAcceptedRewrite()
            canUndo = false
            selection = NSRange(location: 0, length: 0)
            selectionVersion = UUID()
            errorMessage = nil
            scheduleSave()
        } catch { errorMessage = "无法撤销：\(error.localizedDescription)" }
    }

    private func scheduleSave() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            _ = await self.enqueue(self.editor.document).result
        }
    }

    /// Cancelling a debounce never cancels an admitted write. Every write uses the
    /// revision returned by its completed predecessor, not the revision at scheduling time.
    private func enqueue(_ snapshot: TextDraftDocument) -> Task<Void, Error> {
        let previous = writeTail
        let write = Task { [self] in
            if let previous { _ = await previous.result }
            guard snapshot.revision != persistedRevision else { return }
            isSaving = true
            defer { isSaving = false }
            do {
                try await persist(snapshot, persistedRevision)
                persistedRevision = snapshot.revision
                errorMessage = nil
            } catch {
                errorMessage = "正文尚未保存，已保留在当前窗口。请恢复磁盘访问后重试：\(error.localizedDescription)"
                throw error
            }
        }
        writeTail = write
        return write
    }

    /// The host blocks navigation on failure; edits admitted while saving are also flushed.
    public func flush() async throws {
        debounce?.cancel()
        await debounce?.value
        debounce = nil
        if let writeTail { _ = await writeTail.result }
        while isDirty { try await enqueue(editor.document).value }
    }
}
