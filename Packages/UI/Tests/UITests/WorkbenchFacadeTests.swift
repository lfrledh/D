import DInference
import DWorkbench
import Foundation
import Observation
import Synchronization
import Testing
import UI

private actor PresentationOutcomeGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

private actor PresentationEngine: InferenceEngine {
    let gate: PresentationOutcomeGate
    init(gate: PresentationOutcomeGate) { self.gate = gate }
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { [gate] in
            await gate.wait()
            return .cancelled
        })
    }
}

@Suite @MainActor
struct WorkbenchFacadeTests {
    private func session(gate: PresentationOutcomeGate) -> ProjectSession {
        let engine = PresentationEngine(gate: gate)
        return ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "presentation.fixture", status: {
                .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
            }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: UserDefaults(suiteName: "D.Presentation.\(UUID())")!)
    }

    @Test func facadeBindingsObserveServiceChangesWithoutDuplicatingState() {
        let service = session(gate: PresentationOutcomeGate())
        let facade = WorkbenchModel(projectSession: service)
        let changed = Mutex(false)
        withObservationTracking { _ = facade.prompt } onChange: { changed.withLock { $0 = true } }
        service.prompt = "Changed by a headless caller"
        #expect(changed.withLock { $0 })
        #expect(facade.prompt == service.prompt)
        facade.seedText = "-"
        #expect(service.seedText == "-")
    }

    @Test func removingPresentationDoesNotCancelOrAbandonAnOwnedTask() async throws {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("presentation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = PresentationOutcomeGate()
        let service = session(gate: gate)
        await service.createProject(at: folder.resolvingSymlinksInPath().appendingPathComponent("Headless.dproject"))
        try #require(service.manifest != nil, Comment(rawValue: service.errorMessage ?? "Project unavailable"))
        await service.registerModel(at: folder)
        var facade: WorkbenchModel? = WorkbenchModel(projectSession: service)
        facade?.prompt = "This job belongs to the application service"
        await facade?.generate()
        #expect(service.isBusy)
        weak let previousFacade = facade
        facade = nil
        #expect(previousFacade == nil)
        #expect(service.isBusy)
        await gate.open()
        let deadline = ContinuousClock.now + .seconds(5)
        while service.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!service.isBusy)
        let replacement = WorkbenchModel(projectSession: service)
        #expect(replacement.manifest?.jobs.first?.state == .cancelled)
        #expect(await service.requestClose())
    }
}
