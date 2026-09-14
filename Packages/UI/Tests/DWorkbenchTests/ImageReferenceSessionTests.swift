import DInference
import DRuntime
import Foundation
import Testing
@testable import DWorkbench

private actor ReferenceSessionBackend: InferenceBackend {
    nonisolated let descriptor = BackendDescriptor(id: "reference-cpu", version: "1", capabilities: [.imageGeneration])
    let fixture: ProjectFixture
    var opened = false
    private(set) var requests: [InferenceRequest] = []
    private(set) var releases = 0
    init(_ fixture: ProjectFixture) { self.fixture = fixture }
    func open() { opened = true }
    func estimate(_ request: InferenceRequest) -> ResourceEstimate { .init(peakBytes: 1) }
    func execute(_ request: InferenceRequest, emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        requests.append(request)
        let deadline = ContinuousClock.now + .seconds(10)
        while !opened {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw InferenceFailure.backendFailed("CPU gate timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        let png = try fixture.publishPNG(jobID: request.id, size: 512)
        return .init(artifacts: [.init(url: png, mediaType: "image/png")])
    }
    func release() { releases += 1 }
}

@MainActor @Suite("Reference image session snapshots", .serialized)
struct ImageReferenceSessionTests {
    private func subject(_ backend: ReferenceSessionBackend) -> ProjectSession {
        ProjectSession(sessionFactory: { _ in
            let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 100))
            return WorkbenchSession(engine: runtime, backendID: backend.descriptor.id,
                status: { let s = await runtime.snapshot(); return .init(activeRunID: s.activeRunID,
                    phase: s.phase?.rawValue, queuedRunIDs: s.queuedRunIDs) },
                shutdown: { await runtime.shutdown() }, cleanup: {}, validateModel: { _ in },
                imageCapability: .scalableKlein4B)
        }, settings: UserDefaults(suiteName: "D.ImageReferenceTests.\(UUID())")!)
    }
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    @Test func editingWhileRunningNeverReplacesCapturedReferenceOrLatestDraft() async throws {
        try await withFixture { fixture in
            try await runEditing(fixture)
        }
    }
    private func runEditing(_ fixture: ProjectFixture) async throws {
        let backend = ReferenceSessionBackend(fixture), session = subject(backend)
        await session.createProject(at: fixture.project)
        await session.registerModel(at: fixture.directory)
        let source = try fixture.publishPNG(jobID: UUID(), size: 512)
        await session.importImageReference(at: source, name: "原图", documentID: try #require(session.activeDocumentID), navigationEpoch: session.navigationEpoch)
        let reference = try #require(session.referenceImageAssetID)
        let doc = try #require(session.activeDocumentID)
        session.prompt = "蓝色 中文 e\u{301} 🎨"; session.randomSeed = false; session.seedText = "42"
        await session.generate()
        try await wait { await backend.requests.count == 1 }
        session.prompt = "新的草稿不能被完成回调覆盖"
        await session.setImageReference(nil, documentID: doc, navigationEpoch: session.navigationEpoch)
        await backend.open()
        try await wait { !session.isBusy }
        #expect(session.prompt == "新的草稿不能被完成回调覆盖")
        #expect(session.referenceImageAssetID == nil)
        let job = try #require(session.manifest?.jobs.first)
        #expect(job.documentID == doc && job.imageReferenceAssetID == reference && job.state == .completed)
        guard case .image(let image) = job.request.input else { Issue.record("image input missing"); return }
        #expect(image.referenceImage != nil && image.prompt == "蓝色 中文 e\u{301} 🎨")
        #expect(session.activeDocument?.adoptedAssetID == nil)
        #expect(await backend.releases == 1)
        #expect(await session.cancelAndCloseProject())
        await session.openProject(at: fixture.project)
        #expect(session.prompt == "新的草稿不能被完成回调覆盖")
        #expect(session.referenceImageAssetID == nil)
        #expect(await session.cancelAndCloseProject())
    }
    @Test func staleNavigationAndEmptyModalityCannotChangeReference() async throws {
        try await withFixture { fixture in try await runStaleNavigation(fixture) }
    }
    private func runStaleNavigation(_ fixture: ProjectFixture) async throws {
        let backend = ReferenceSessionBackend(fixture), session = subject(backend)
        await session.createProject(at: fixture.project)
        let source = try fixture.publishPNG(jobID: UUID(), size: 512)
        let doc = try #require(session.activeDocumentID), epoch = session.navigationEpoch
        await session.importImageReference(at: source, name: "原图", documentID: doc, navigationEpoch: epoch)
        let reference = try #require(session.referenceImageAssetID)
        try #require(await session.selectCreatorMode(.video))
        await session.setImageReference(nil, documentID: doc, navigationEpoch: session.navigationEpoch)
        #expect(session.manifest?.documents.first?.draft.referenceImageAssetID == reference)
        #expect(await session.selectDocument(id: doc))
        #expect(session.navigationEpoch != epoch)
        await session.setImageReference(nil, documentID: doc, navigationEpoch: epoch)
        await session.importImageReference(at: source, name: "过期导入", documentID: doc, navigationEpoch: epoch)
        #expect(session.referenceImageAssetID == reference)
        #expect(session.manifest?.assets.count == 1)
        await session.setImageReference(nil, documentID: doc, navigationEpoch: session.navigationEpoch)
        #expect(session.referenceImageAssetID == nil)
        #expect(await session.cancelAndCloseProject())
    }
    @Test func cancellationPreservesOriginalAndNextRequestRuns() async throws {
        try await withFixture { fixture in try await runCancellation(fixture) }
    }
    private func runCancellation(_ fixture: ProjectFixture) async throws {
        let backend = ReferenceSessionBackend(fixture), session = subject(backend)
        await session.createProject(at: fixture.project); await session.registerModel(at: fixture.directory)
        let source = try fixture.publishPNG(jobID: UUID(), size: 512)
        let bytes = try Data(contentsOf: source)
        await session.importImageReference(at: source, name: "保留原图", documentID: try #require(session.activeDocumentID), navigationEpoch: session.navigationEpoch)
        session.prompt = "edit"
        await session.generate()
        try await wait { await backend.requests.count == 1 }
        let id = try #require(session.manifest?.jobs.first?.id)
        await session.cancel(id)
        try await wait { !session.isBusy }
        #expect(session.manifest?.jobs.first?.state == .cancelled)
        #expect(session.manifest?.assets.filter { $0.role == .result }.isEmpty == true)
        #expect(try Data(contentsOf: source) == bytes)
        await backend.open(); await session.generate()
        try await wait { !session.isBusy }
        #expect(session.manifest?.jobs.last?.state == .completed)
        #expect(await backend.releases == 2)
        #expect(await session.cancelAndCloseProject())
    }
}
