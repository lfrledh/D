import CryptoKit
import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor ReadinessEngine: InferenceEngine {
    private(set) var submissions = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1
        throw WorkflowIssue("Readiness checks must not generate")
    }
}

private actor ReadinessValidator {
    var calls = 0
    var suspendNext = false
    var pending: CheckedContinuation<Void, Never>?
    func arm() { suspendNext = true }
    func finish() { pending?.resume(); pending = nil }
    func validate() async throws {
        calls += 1
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { pending = $0 }
            throw WorkflowIssue("old inspection failed after a new installation was selected")
        }
    }
    var waiting: Bool { pending != nil }
}

@Suite(.serialized) @MainActor
struct WorkflowModelReadinessTests {
    @Test func selectionRefreshesReadinessAndPeerChoicesWithoutChangingDraftOrGraph() async throws {
        try await exercise(staleInspection: false)
    }
    @Test func olderReadinessFailureCannotOverwriteNewValidatedSelection() async throws {
        try await exercise(staleInspection: true)
    }

    private func exercise(staleInspection: Bool) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("readiness-" + UUID().uuidString)
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let bytes = Data("controlled CPU weights".utf8)
        try bytes.write(to: model.appendingPathComponent("weights.bin"), options: .withoutOverwriting)
        let realEntry = try ModelCatalog.flux2()
        let entry = ModelCatalogEntry(id: realEntry.id, title: "Controlled Klein registration", repository: "fixture/klein",
            revision: realEntry.revision,
            files: [.init(path: "weights.bin", size: UInt64(bytes.count),
                          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
            imageProfile: .flux2Klein, workflowProfileID: "d.image.generate")
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("library"), catalog: [entry])
        let id = try await library.registerExisting(at: model, catalogID: entry.id)
        let suite = "D.Readiness." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = ReadinessEngine(), validator = ReadinessValidator()
        func owner() -> ProjectSession {
            ProjectSession(sessionFactory: { _ in
                WorkbenchSession(engine: engine, backendID: "fixture.image",
                    status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                    shutdown: {}, cleanup: {}, validateModel: { _ in try await validator.validate() })
            }, settings: settings, modelLibrary: library)
        }
        let quickOwner = owner(), canvasOwner = owner()
        await quickOwner.createProject(at: root.appendingPathComponent("quick.dproject"))
        await canvasOwner.createProject(at: root.appendingPathComponent("canvas.dproject"))
        await canvasOwner.openWorkflow()
        let controller = try #require(canvasOwner.workflow)
        controller.addNode(operationID: "d.image.generate")
        let selected = controller.selectedNodeID
        let graph = controller.graph
        let quick = QuickGenerationController(store: try #require(quickOwner.currentStore),
            makeServices: { try quickOwner.makeExplicitOperationServices() })
        await quick.load()
        quick.select(operationID: "d.image.generate", modelID: "")
        let draft = try #require(quick.draft)
        quick.setParameter("promptText", value: .text("未完成的草稿 e\u{301} 👩🏽‍🎨"), draftID: draft.id)
        let expectedDraft = quick.draft
        let choice = try await quickOwner.selectWorkflowInstallation(id: id)
        #expect(quickOwner.explicitModelReadiness[choice.id] == .available)
        #expect(await validator.calls == 1, "A successful registration must not require a second content verification")
        if staleInspection {
            await validator.arm()
            let old = Task { await quickOwner.checkExplicitModelReadiness() }
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await validator.waiting) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(await validator.waiting)
            _ = try await quickOwner.selectWorkflowInstallation(id: id)
            await validator.finish()
            await old.value
            #expect(quickOwner.explicitModelReadiness[choice.id] == .available)
            #expect(quickOwner.explicitModelIssues[choice.id] == nil)
        }
        canvasOwner.refreshWorkflowModels()
        #expect(controller.modelChoices.contains { $0.id == choice.id })
        #expect(canvasOwner.workflow === controller && controller.graph == graph && controller.selectedNodeID == selected)
        #expect(quick.draft == expectedDraft)
        #expect(await engine.submissions == 0)
        #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
        try await library.remove(id)
        quickOwner.observeModelAvailability(await library.snapshot())
        #expect(quickOwner.explicitModelReadiness[choice.id] == .unavailable)
        #expect(quick.draft == expectedDraft && controller.graph == graph)
        #expect(try Data(contentsOf: model.appendingPathComponent("weights.bin")) == bytes)
        try await quick.flush()
        #expect(await quickOwner.requestClose())
        #expect(await canvasOwner.requestClose())
        try await library.shutdown()
    }
}
