import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor SourcesGate {
    private(set) var reached = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { reached = true; if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
private actor SourcesEngine: InferenceEngine {
    private(set) var requests: [InferenceRequest] = []
    private(set) var cancellations = 0
    let gate: SourcesGate?
    let outcome: RunOutcome
    let answer: String
    init(gate: SourcesGate? = nil, outcome: RunOutcome = .completed(.init()), answer: String = "代号是蓝桉。[S1]") {
        self.gate = gate; self.outcome = outcome; self.answer = answer
    }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        let gate = gate, outcome = outcome, answer = answer
        return .init(id: request.id, events: AsyncThrowingStream { $0.yield(.textDelta(answer)); $0.finish() },
            cancel: { await self.cancelled() }, outcome: { if let gate { await gate.wait() }; return outcome })
    }
    private func cancelled() { cancellations += 1 }
}
private actor SourcesCancelRaceEngine: InferenceEngine {
    let firstOutcome = SourcesGate(), delayedCancel = SourcesGate(), secondOutcome = SourcesGate()
    private var count = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        count += 1
        let first = count == 1, end = first ? firstOutcome : secondOutcome, cancel = delayedCancel
        return .init(id: request.id, events: AsyncThrowingStream { $0.yield(.textDelta("蓝桉[S1]")); $0.finish() },
            cancel: { if first { await cancel.wait() } }, outcome: { await end.wait(); return .completed(.init()) })
    }
}
private final class SourcesDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

@Suite("Text sources lifecycle and production host", .serialized) @MainActor
struct TextSourcesFlowTests {
    @Test func lateCancellationReturnCannotWaitForNextOperation() async throws {
        let engine = SourcesCancelRaceEngine()
        let controller = try ProjectTextSourcesController(notebook: notebook(), document: TextDraftDocument(text: "原稿"),
            engine: engine, backendID: "fixture", persist: { _, _, _, _ in })
        let first = Task { await controller.ask(using: model, modelID: "fixture") }
        try await wait { await engine.firstOutcome.reached }
        var returned = false
        let cancel = Task { await controller.cancel(); returned = true }
        try await wait { await engine.delayedCancel.reached }
        await engine.firstOutcome.open(); await first.value
        let second = Task { await controller.ask(using: model, modelID: "fixture") }
        try await wait { await engine.secondOutcome.reached }
        await engine.delayedCancel.open()
        do { try await wait { returned } }
        catch { await engine.secondOutcome.open(); await second.value; await cancel.value; throw error }
        #expect(controller.isRunning && !controller.isCancelling && returned)
        await engine.secondOutcome.open(); await second.value; await cancel.value
        #expect(controller.notebook.records.count == 1)
    }

    @Test func fullCompletedRecordSurvivesArchiveOverflowAndCanBeSavedAfterRemovingCurrentSource() async throws {
        let source = try TextSourceSnapshot(displayName: "large.txt", bytes: Data(repeating: 120, count: 500_000))
        let excerpt = try TextSourceReader.excerpt(from: source, range: NSRange(location: 0, length: 1))
        var note = TextSourcesNotebook(question: "x?", sources: [source], excerpts: [excerpt])
        let target = try TextDraftDocument(text: "原稿")
        // Eleven compact answered histories plus the current source fit; a twelfth with a
        // larger answer does not. All source and per-answer values remain individually valid.
        for _ in 0..<11 {
            let submission = try TextSourcesContext.makeSubmission(notebook: TextSourcesNotebook(question: "x?", sources: [source], excerpts: [excerpt]),
                target: target, modelID: "fixture", modelRevision: nil)
            note.records.append(.init(submission: submission, answer: "x [S1]"))
        }
        try TextSourcesArchive.validate(note)
        let controller = try ProjectTextSourcesController(notebook: note, document: target,
            engine: SourcesEngine(answer: String(repeating: "x", count: 100_000) + " [S1]"), backendID: "fixture", persist: { _, _, _, _ in })
        await controller.ask(using: model, modelID: "fixture")
        let pending = try #require(controller.unsavedCompletedRecord)
        #expect(pending.submission.sources[0].bytes == source.bytes && !controller.canAsk && controller.document == target)
        controller.removeSource(id: source.id)
        try await controller.flush()
        #expect(controller.unsavedCompletedRecord == nil && !controller.isDirty && controller.notebook.records.count == 12)
        #expect(controller.notebook.records.last?.answer == pending.answer)
    }

    private let model = ModelReference(directory: URL(fileURLWithPath: "/fixture-only"), revision: "fixture")
    private func notebook() throws -> TextSourcesNotebook {
        let source = try TextSourceSnapshot(displayName: "代号👩‍💻.md", bytes: Data("代号是蓝桉\r\ne\u{301}👩‍💻".utf8))
        return .init(question: "代号是什么？", sources: [source], excerpts: [try TextSourceReader.excerpt(from: source)])
    }
    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(4)
        while !(await predicate()) { guard ContinuousClock.now < limit else { throw CancellationError() }; try await Task.sleep(for: .milliseconds(3)) }
    }
    private func directory() throws -> URL {
        let temp = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: temp).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
    private func host(_ engine: SourcesEngine, enabled: Bool = true) -> ProjectSession {
        ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "fixture.image",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {},
                validateModel: { _ in }, textBackendID: "fixture.text",
                validateTextModel: { ModelReference(directory: $0, revision: "fixture") })
        }, settings: SourcesDefaults(), textSourcesEnabled: enabled)
    }

    @Test func productionImportAskAcceptUndoRejectAndColdReopen() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("输入 é 👩‍💻.md")
        let originalBytes = Data("代号是蓝桉\r\ne\u{301}👩‍💻".utf8); try originalBytes.write(to: source)
        let engine = SourcesEngine(), project = host(engine), url = root.appendingPathComponent("资料.dproject")
        await project.createProject(at: url); await project.createTextDocument()
        let id = try #require(project.activeDocumentID), text = try #require(project.text)
        project.editText("原稿 e\u{301}👩‍💻", documentID: id)
        await project.importTextSource(at: source, documentID: id, epoch: project.navigationEpoch)
        let controller = try #require(project.textSources)
        controller.changeQuestion("代号是什么？")
        await project.registerTextModel(at: root)
        #expect(project.canAskTextSources)
        let original = text.editor.document
        await project.askTextSources()
        let record = try #require(controller.notebook.records.first)
        #expect(text.editor.document == original)
        #expect(controller.canAccept(record) && !controller.isDirty)
        #expect(await engine.requests.count == 1)
        await project.acceptTextSources(id: record.id)
        #expect(text.editor.document.text == original.text + "\n\n" + record.answer)
        #expect(project.manifest?.activeDocument?.textDraft == text.editor.document)
        #expect(project.manifest?.activeDocument?.textSources?.records.first?.disposition == .accepted)
        await project.undoTextSources()
        #expect(text.editor.document.text.utf8.elementsEqual(original.text.utf8))
        #expect(controller.notebook.records.first?.disposition == .undone)
        await project.askTextSources()
        let second = try #require(controller.notebook.records.last)
        await controller.reject(id: second.id)
        #expect(await project.requestClose())
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("已移动.txt"))
        await project.openProject(at: url)
        #expect(project.text?.editor.document.text.utf8.elementsEqual(original.text.utf8) == true)
        #expect(project.textSources?.notebook.sources.first?.bytes == originalBytes)
        #expect(project.textSources?.notebook.records.map(\.disposition) == [.undone, .rejected])
        #expect(project.textSources?.canUndo == false)
        #expect(await project.requestClose())
    }

    @Test func inputChangedDuringGenerationKeepsNewQuestionAndMakesOldAnswerStale() async throws {
        let gate = SourcesGate(), engine = SourcesEngine(gate: gate), document = try TextDraftDocument(text: "原文")
        let controller = try ProjectTextSourcesController(notebook: notebook(), document: document, engine: engine,
            backendID: "fixture", persist: { _, _, _, _ in })
        let run = Task { await controller.ask(using: model, modelID: "fixture") }
        try await wait { await gate.reached }
        controller.changeQuestion("新的问题")
        await gate.open(); await run.value
        let record = try #require(controller.notebook.records.first)
        #expect(record.submission.question == "代号是什么？")
        #expect(controller.notebook.question == "新的问题" && !controller.canAccept(record))
        await controller.accept(id: record.id)
        #expect(controller.document == document)
    }

    @Test func cancellationWaitsForOutcomeAndFailedModelCannotPublish() async throws {
        let gate = SourcesGate(), engine = SourcesEngine(gate: gate), document = try TextDraftDocument(text: "原文")
        var writes = 0
        let controller = try ProjectTextSourcesController(notebook: notebook(), document: document, engine: engine,
            backendID: "fixture", persist: { _, _, _, _ in writes += 1 })
        let run = Task { await controller.ask(using: model, modelID: "fixture") }
        try await wait { await gate.reached }
        var cancelled = false
        let cancel = Task { await controller.cancel(); cancelled = true }
        try await wait { await engine.cancellations == 1 }
        #expect(!cancelled && controller.isRunning && controller.isCancelling && !controller.canAsk)
        await gate.open(); await cancel.value; await run.value
        #expect(cancelled && writes == 0 && controller.notebook.records.isEmpty && controller.document == document)
        let failing = try ProjectTextSourcesController(notebook: notebook(), document: document,
            engine: SourcesEngine(outcome: .failed(.backendFailed("controlled failure"))), backendID: "fixture", persist: { _, _, _, _ in writes += 1 })
        await failing.ask(using: model, modelID: "fixture")
        #expect(writes == 0 && failing.notebook.records.isEmpty && failing.document == document)
    }

    @Test func saveFailurePreservesAnswerAndAtomicAcceptFailurePreservesBody() async throws {
        let document = try TextDraftDocument(text: "不可丢失"), engine = SourcesEngine()
        var fail = true, saved: TextSourcesNotebook?
        let controller = try ProjectTextSourcesController(notebook: notebook(), document: document, engine: engine,
            backendID: "fixture", persist: { note, _, _, _ in
                if fail { throw ProjectStoreError.externalModification }; saved = note
            })
        await controller.ask(using: model, modelID: "fixture")
        let record = try #require(controller.notebook.records.first)
        #expect(controller.isDirty && saved == nil && controller.document == document)
        fail = false; try await controller.flush()
        #expect(!controller.isDirty && saved?.records.first == record)
        fail = true; await controller.accept(id: record.id)
        #expect(controller.document == document && controller.notebook.records.first?.disposition == .pending)
        fail = false; await controller.accept(id: record.id)
        #expect(controller.document.text == document.text + "\n\n" + record.answer)
    }

    @Test func targetChangedWhileDecisionIsSavingCannotBeOverwrittenOnReturn() async throws {
        let gate = SourcesGate(), document = try TextDraftDocument(text: "原稿")
        let controller = try ProjectTextSourcesController(notebook: notebook(), document: document,
            engine: SourcesEngine(), backendID: "fixture", persist: { _, _, replacement, _ in
                if replacement != nil { await gate.wait() }
            })
        await controller.ask(using: model, modelID: "fixture")
        let id = try #require(controller.notebook.records.first?.id)
        let accept = Task { await controller.accept(id: id) }
        try await wait { await gate.reached }
        let newer = try TextDraftDocument(id: document.id, text: "更新的原稿")
        controller.synchronizeTarget(newer)
        await gate.open(); await accept.value
        #expect(controller.document == newer && !controller.canUndo)
    }

    @Test func disabledFeatureLeavesExistingTextHostUntouched() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let project = host(SourcesEngine(), enabled: false)
        await project.createProject(at: root.appendingPathComponent("旧入口.dproject")); await project.createTextDocument()
        #expect(project.text != nil && project.textSources == nil && !project.canAskTextSources)
        #expect(await project.requestClose())
    }
}
