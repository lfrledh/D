import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor FlowGate {
    private(set) var reached = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { reached = true; if !opened { await withCheckedContinuation { waiter = $0 } } }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}
private actor FlowEngine: InferenceEngine {
    let gate: FlowGate?
    let failure: Bool
    private(set) var submissions = 0
    private(set) var cancellations = 0
    init(gate: FlowGate? = nil, failure: Bool = false) { self.gate = gate; self.failure = failure }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1
        let gate = self.gate, failure = self.failure
        return InferenceRun(id: request.id, events: AsyncThrowingStream { c in
            c.yield(.textDelta("新句")); c.finish()
        }, cancel: { await self.cancelled() }, outcome: {
            if let gate { await gate.wait(); return .cancelled }
            return failure ? .failed(.backendFailed("controlled CPU failure")) : .completed(.init())
        })
    }
    private func cancelled() { cancellations += 1 }
}
// No preference domain on the user's machine is written by these new fixtures.
private final class FlowDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

@Suite("T0 production storage and host flow", .serialized) @MainActor
struct ProjectTextFlowTests {
    private func folder() throws -> URL {
        let root = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let dir = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func host(engine: FlowEngine) -> ProjectSession {
        ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text",
                validateTextModel: { ModelReference(directory: $0, revision: "CPU fixture only") })
        }, settings: FlowDefaults())
    }
    private func prepare(_ host: ProjectSession, at root: URL) async throws -> ProjectTextController {
        await host.createProject(at: root.appendingPathComponent("创作.dproject"))
        await host.createTextDocument()
        let text = try #require(host.text)
        host.editText("中e\u{301}👩‍💻尾", documentID: text.editor.document.id)
        host.selectText(NSRange(location: 3, length: 5), documentID: text.editor.document.id)
        text.instruction = "改写选段"
        await host.registerTextModel(at: root)
        try #require(host.canRewriteText)
        return text
    }

    @Test func acceptUndoRejectAndReopenPreserveOriginalUntilExplicitAcceptance() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let subject = host(engine: FlowEngine())
        let text = try await prepare(subject, at: root)
        let original = text.editor.document
        await subject.saveText()
        await subject.rewriteText()
        #expect(text.editor.document == original)
        #expect(subject.manifest?.activeDocument?.textDraft == original)
        #expect(text.editor.candidate?.selection.selectedText == "👩‍💻")
        #expect(text.canAccept)
        #expect(!(await subject.requestClose()))
        text.accept()
        #expect(text.editor.document.text == "中e\u{301}新句尾")
        await subject.saveText()
        #expect(!text.isDirty)
        text.undo()
        await subject.saveText()
        #expect(text.editor.document.text == original.text)
        #expect(!text.isDirty)
        text.select(NSRange(location: 0, length: 1), documentID: original.id)
        await subject.rewriteText()
        let beforeReject = text.editor.document
        text.reject()
        #expect(text.editor.document == beforeReject)
        #expect(await subject.requestClose())
        await subject.openProject(at: root.appendingPathComponent("创作.dproject"))
        #expect(subject.documents.count == 2)
        #expect(subject.documents.first?.kind == .image)
        #expect(subject.text?.editor.document == beforeReject)
        #expect(subject.text?.editor.candidate == nil)
        #expect(subject.text?.canUndo == false)
        #expect(await subject.requestClose())
    }

    @Test func selectionChangesBackStillInvalidatesCandidateAndForeignEditsAreIgnored() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let subject = host(engine: FlowEngine()); let text = try await prepare(subject, at: root)
        await subject.rewriteText()
        let original = text.editor.document
        subject.selectText(NSRange(location: 0, length: 1), documentID: original.id)
        subject.selectText(NSRange(location: 3, length: 5), documentID: original.id)
        #expect(!text.canAccept)
        text.accept(); #expect(text.editor.document == original)
        subject.editText("错误文档的延迟回调", documentID: UUID())
        #expect(text.editor.document == original)
        await subject.createTextDocument(); #expect(subject.activeDocumentID == original.id)
        text.reject()
        await subject.createTextDocument()
        #expect(subject.activeDocumentID != original.id)
        subject.editText("旧编辑器回调", documentID: original.id)
        #expect(subject.text?.editor.document.text == "")
        #expect(await subject.requestClose())
    }

    @Test func saveFailurePreservesBodyAndExternalFileAndBlocksNavigation() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let subject = host(engine: FlowEngine()); let text = try await prepare(subject, at: root)
        await subject.saveText()
        let file = root.appendingPathComponent("创作.dproject/project.json")
        let original = try Data(contentsOf: file)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var documents = try #require(object["documents"] as? [[String: Any]])
        let index = try #require(documents.firstIndex { $0["id"] as? String == text.editor.document.id.uuidString })
        var payload = try #require(documents[index]["textDraft"] as? [String: Any])
        payload["text"] = "另一位作者的正文"
        documents[index]["textDraft"] = payload; object["documents"] = documents
        let external = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try external.write(to: file, options: .atomic)
        let id = text.editor.document.id
        subject.editText("保留未保存正文", documentID: id)
        await subject.saveText()
        #expect(text.isDirty)
        #expect(text.editor.document.text == "保留未保存正文")
        #expect(try Data(contentsOf: file) == external)
        await subject.createTextDocument(); #expect(subject.activeDocumentID == id)
        #expect(!(await subject.requestClose()))
        // Own fixture only: restore the exact admitted bytes to simulate recovery, then retry.
        try original.write(to: file, options: .atomic)
        await subject.saveText()
        #expect(!text.isDirty)
        #expect(await subject.requestClose())
    }

    @Test func cancellationRemainsBusyUntilAuthoritativeOutcomeAndFailureDoesNotEdit() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = FlowGate()
        let cancellingEngine = FlowEngine(gate: gate)
        let subject = host(engine: cancellingEngine), text = try await prepare(subject, at: root)
        let original = text.editor.document
        let run = Task { await subject.rewriteText() }
        try await wait { await gate.reached }
        let cancel = Task { await subject.cancelTextRewrite() }
        try await wait { await cancellingEngine.cancellations > 0 }
        #expect(subject.isBusy)
        #expect(text.editor.document == original)
        await gate.open(); await run.value; await cancel.value
        #expect(!subject.isBusy); #expect(text.editor.candidate == nil)
        #expect(await subject.requestClose())
        let failed = host(engine: FlowEngine(failure: true))
        await failed.openProject(at: root.appendingPathComponent("创作.dproject"))
        let body = try #require(failed.text)
        body.select(NSRange(location: 0, length: 1), documentID: body.editor.document.id)
        body.instruction = "改写"; await failed.registerTextModel(at: root)
        await failed.rewriteText()
        #expect(body.editor.document == original)
        #expect(body.editor.candidate == nil)
        #expect(body.errorMessage != nil)
        #expect(await failed.requestClose())
    }

    @Test func editsDuringModelValidationDoNotSilentlyRetargetRewrite() async throws {
        let gate = FlowGate(), engine = FlowEngine()
        let document = try TextDraftDocument(text: "原文")
        let controller = ProjectTextController(document: document, engine: engine, backendID: "fixture", persist: { _, _ in })
        controller.instruction = "改写"; controller.select(NSRange(location: 0, length: 1), documentID: document.id)
        let run = Task { await controller.rewrite(using: ModelReference(directory: URL(fileURLWithPath: "/not-read"))) { reference in
            await gate.wait(); return reference
        } }
        try await wait { await gate.reached }
        controller.edit("人工新稿", documentID: document.id)
        await gate.open(); await run.value
        #expect(await engine.submissions == 0)
        #expect(controller.editor.candidate == nil)
        #expect(controller.editor.document.text == "人工新稿")
        try await controller.flush()
    }

    @Test func flushWaitsAdmittedWriteAndPersistsNewestRevisionInOrder() async throws {
        let gate = FlowGate(), doc = try TextDraftDocument(text: "初始")
        var saved = doc, expected: [UUID] = [], snapshots: [TextDraftDocument] = []
        let controller = ProjectTextController(document: doc, engine: FlowEngine(), backendID: "fixture") { value, revision in
            expected.append(revision); snapshots.append(value)
            if snapshots.count == 1 { await gate.wait() }
            #expect(revision == saved.revision)
            saved = value
        }
        controller.edit("第一个", documentID: doc.id)
        try await wait { await gate.reached } // debounce has admitted a real write
        controller.edit("最新中文👩‍💻", documentID: doc.id)
        let flush = Task { try await controller.flush() }
        await gate.open(); try await flush.value
        #expect(saved == controller.editor.document)
        #expect(snapshots.map(\.text) == ["第一个", "最新中文👩‍💻"])
        #expect(expected == [doc.revision, snapshots[0].revision])
        #expect(!controller.isDirty)
    }

    @Test func legalUnicodeSelectionAndManualEditInvalidationAreEnforcedByHostController() async throws {
        let doc = try TextDraftDocument(text: "中e\u{301}👩‍💻🇯🇵")
        let controller = ProjectTextController(document: doc, engine: FlowEngine(), backendID: "fixture", persist: { _, _ in })
        controller.instruction = "改写"
        for bad in [NSRange(location: 1, length: 1), NSRange(location: 3, length: 1), NSRange(location: 0, length: 0)] {
            controller.select(bad, documentID: doc.id); #expect(!controller.canRewrite)
        }
        controller.select(NSRange(location: 1, length: 2), documentID: doc.id); #expect(controller.canRewrite)
        await controller.rewrite(using: ModelReference(directory: URL(fileURLWithPath: "/not-read")))
        controller.edit("人工正文", documentID: doc.id)
        #expect(!controller.canAccept); controller.accept(); #expect(controller.editor.document.text == "人工正文")
        controller.reject(); try await controller.flush()
    }
}
