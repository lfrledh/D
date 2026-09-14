import DInference
import DRuntime
import Foundation
import Testing
@testable import DWorkbench

private actor VideoSessionProbe {
    var inputs: [InferenceRequest] = []
    var mayFinish = false
    var releaseCount = 0
    func begin(_ request: InferenceRequest) { inputs.append(request) }
    func finish() { mayFinish = true }
    func released() { releaseCount += 1 }
}
private actor VideoSessionBackend: InferenceBackend {
    nonisolated let descriptor = BackendDescriptor(id: "fixture.video", version: "1", capabilities: [.videoGeneration])
    let root: URL, probe: VideoSessionProbe
    init(root: URL, probe: VideoSessionProbe) { self.root = root; self.probe = probe }
    func estimate(_ request: InferenceRequest) throws -> ResourceEstimate { .init(peakBytes: 1) }
    func execute(_ request: InferenceRequest, emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard case .video(let input) = request.input else { throw ProjectStoreError.invalidTransition }
        await probe.begin(request)
        if input.prompt == "controlled failure" { throw InferenceFailure.backendFailed("CPU controlled failure") }
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await probe.mayFinish) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw InferenceFailure.backendFailed("CPU fixture deadline") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let project = root.deletingLastPathComponent()
        let output = try VideoProjectFixture.output(project: project, runID: request.id)
        try await VideoProjectFixture.write(output, input: input)
        return .init(artifacts: [.init(url: output, mediaType: "video/mp4")], metadata: ["evidence": "software CPU fixture, no model"])
    }
    func release() async { await probe.released() }
}

@Suite("Video session assembly", .serialized) @MainActor
struct VideoProjectSessionTests {
    private func subject(_ settings: UserDefaults, probe: VideoSessionProbe) -> ProjectSession {
        ProjectSession(sessionFactory: { artifacts in
            let backend = VideoSessionBackend(root: artifacts, probe: probe)
            let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 64,
                allowsRequestBudgetIncrease: true))
            return WorkbenchSession(engine: runtime, backendID: "fixture.image", status: {
                let value = await runtime.snapshot()
                return .init(activeRunID: value.activeRunID, phase: value.phase?.rawValue, queuedRunIDs: value.queuedRunIDs)
            }, shutdown: { await runtime.shutdown() }, cleanup: {}, validateModel: { _ in },
                videoBackendID: backend.descriptor.id, validateVideoModel: { .init(directory: $0, revision: "CPU fixture") },
                videoCapability: .wan21, defaultMemoryBudgetBytes: 64)
        }, settings: settings)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline, "owned CPU task did not finish")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func fixture(_ body: (ProjectSession, VideoSessionProbe, URL) async throws -> Void) async throws {
        let root = try VideoProjectFixture.root(), suite = "D.VideoSessionCPU.\(UUID())"
        let settings = try #require(UserDefaults(suiteName: suite)), probe = VideoSessionProbe()
        defer { settings.removePersistentDomain(forName: suite) }
        let session = subject(settings, probe: probe)
        await session.createProject(at: root.appendingPathComponent("项目.dproject"))
        await session.createVideoCreation()
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
        await session.registerVideoModel(at: model)
        do { try await body(session, probe, root) }
        catch { _ = await session.cancelAndCloseProject(); throw error }
        #expect(await session.cancelAndCloseProject())
    }

    @Test func immutableGenerationSurvivesEditingAndDocumentChange() async throws {
        try await fixture { session, probe, _ in
            let id = try #require(session.activeDocumentID), context = session.videoCreationContextID
            let draft = VideoProjectFixture.draft("原始中文 e\u{301} 👩‍💻")
            session.updateVideoCreationDraft(draft, contextID: context, documentID: id)
            await session.generateVideoCreation(contextID: context, documentID: id)
            try await wait { !(await probe.inputs.isEmpty) }
            var edited = draft; edited.prompt = "改变后的草稿"; edited.seedText = "100"
            session.updateVideoCreationDraft(edited, contextID: context, documentID: id)
            await session.createVideoCreation()
            let other = try #require(session.activeDocumentID)
            #expect(other != id)
            let otherContext = session.videoCreationContextID
            session.updateVideoCreationDraft(draft, contextID: context, documentID: id)
            #expect(session.videoCreationDraft?.prompt == "")
            await probe.finish()
            try await wait { !session.isBusy }
            let original = try #require(session.documents.first(where: { $0.id == id }))
            #expect(original.videoCreation?.prompt == edited.prompt)
            let run = try #require(session.manifest?.jobs.last)
            #expect(run.documentID == id && run.state == .completed)
            #expect(run.request.input == .video(try draft.makeRequest()))
            #expect(session.activeDocumentID == other && session.videoCreationContextID == otherContext)
            #expect(original.adoptedAssetID == nil && session.activeDocument?.adoptedAssetID == nil)
            #expect(await probe.releaseCount == 1)
            _ = await session.selectDocument(id: id)
            let current = session.videoCreationContextID
            let asset = try #require(session.videoCreationCandidates.first)
            await session.mutateVideoCreationCandidate(.adopt(asset.id), contextID: current, documentID: id)
            #expect(session.activeDocument?.adoptedAssetID == asset.id)
            await session.mutateVideoCreationCandidate(.reject(asset.id, true), contextID: current, documentID: id)
            #expect(session.activeDocument?.adoptedAssetID == nil)
            #expect(session.videoCreationDraft?.rejectedAssetIDs == [asset.id])
            await session.mutateVideoCreationCandidate(.reject(asset.id, false), contextID: current, documentID: id)
            await session.previewVideoAsset(id: asset.id, contextID: current, documentID: id)
            #expect(session.videoPreviewURL != nil)
            _ = await session.selectCreatorMode(.image)
            #expect(session.videoPreviewURL == nil)
        }
    }

    @Test func invalidBudgetCancellationAndFailurePreserveDraft() async throws {
        try await fixture { session, probe, _ in
            let id = try #require(session.activeDocumentID), context = session.videoCreationContextID
            var draft = VideoProjectFixture.draft()
            draft.memoryBudgetMiBText = "-"
            session.updateVideoCreationDraft(draft, contextID: context, documentID: id)
            #expect(!session.canGenerateVideoCreation)
            await session.generateVideoCreation(contextID: context, documentID: id)
            #expect(session.documentJobs.isEmpty)
            draft.memoryBudgetMiBText = "1"
            session.updateVideoCreationDraft(draft, contextID: context, documentID: id)
            await session.generateVideoCreation(contextID: context, documentID: id)
            try await wait { !(await probe.inputs.isEmpty) }
            await session.cancelVideoCreation(contextID: context, documentID: id)
            try await wait { !session.isBusy }
            #expect(session.documentJobs.last?.state == .cancelled)
            #expect(session.videoCreationCandidates.isEmpty)
            #expect(session.videoCreationDraft?.prompt == draft.prompt)
            #expect(await probe.releaseCount == 1)
            draft.prompt = "controlled failure"
            session.updateVideoCreationDraft(draft, contextID: context, documentID: id)
            await session.generateVideoCreation(contextID: context, documentID: id)
            try await wait { !session.isBusy }
            #expect(session.documentJobs.last?.state == .failed)
            #expect(session.errorMessage?.contains("CPU controlled failure") == true)
            #expect(session.videoCreationCandidates.isEmpty)
            #expect(await probe.releaseCount == 2)
        }
    }

    @Test func saveFailureDoesNotSubmitOrReplaceExternallyChangedManifest() async throws {
        try await fixture { session, probe, _ in
            let id = try #require(session.activeDocumentID), context = session.videoCreationContextID
            let project = try #require(session.projectURL)
            let file = project.appendingPathComponent(ProjectStore.manifestFilename)
            let durable = try Data(contentsOf: file), external = Data("controlled external change".utf8)
            try external.write(to: file)
            session.updateVideoCreationDraft(VideoProjectFixture.draft(), contextID: context, documentID: id)
            #expect(await session.saveVideoCreation(contextID: context, documentID: id) == false)
            await session.generateVideoCreation(contextID: context, documentID: id)
            #expect(await probe.inputs.isEmpty)
            #expect(try Data(contentsOf: file) == external)
            #expect(session.videoCreationDraft?.prompt == VideoProjectFixture.draft().prompt)
            try durable.write(to: file) // Only restores this explicitly corrupted owned fixture.
            #expect(await session.saveVideoCreation(contextID: context, documentID: id))
        }
    }
}
