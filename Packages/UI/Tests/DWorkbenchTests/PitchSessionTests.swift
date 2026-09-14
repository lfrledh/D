import DInference
import DRuntime
import Foundation
import Testing
@testable import DWorkbench

private actor PitchHostProbe {
    var started = 0
    var releases = 0
    var wait = false
    func begin() -> Bool { started += 1; return wait }
    func setWait(_ value: Bool) { wait = value }
    func released() { releases += 1 }
}
private actor PitchHostBackend: InferenceBackend {
    nonisolated let descriptor = BackendDescriptor(id: "fixture.pitch", version: "1", capabilities: [.audioPitchAnalysis])
    let root: URL
    let probe: PitchHostProbe
    init(root: URL, probe: PitchHostProbe) { self.root = root; self.probe = probe }
    func estimate(_ request: InferenceRequest) -> ResourceEstimate { .init(peakBytes: 1) }
    func execute(_ request: InferenceRequest, emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard case .pitch(let input) = request.input else { throw ProjectStoreError.invalidTransition }
        if await probe.begin() { while true { try await Task.sleep(for: .milliseconds(10)) } }
        let value = PitchAnalysisResult(runID: request.id, source: input.source, inputSHA256: input.inputSHA256,
            sampleCount: input.sampleCount, frames: Array(repeating: .init(pitchHz: 440, confidence: 0.99, voiced: true), count: input.sampleCount / 256))
        let output = root.appendingPathComponent("\(request.id.uuidString)/pitch.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: output)
        let artifact = ArtifactReference(url: output, mediaType: PitchAnalysisResult.mediaType)
        try await emit(.artifact(artifact))
        return .init(artifacts: [artifact], metadata: ["evidence": "synthetic host-flow fixture"])
    }
    func release() async { await probe.released() }
}

@Suite("Pitch production host flow", .serialized) @MainActor
struct PitchSessionTests {
    @Test func cancellationNavigationDirtyInputAndReopenRespectCandidateIdentity() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]!)
            .appendingPathComponent("pitch-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "D.PitchHost.\(UUID().uuidString)", settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let probe = PitchHostProbe()
        let subject = ProjectSession(sessionFactory: { artifacts in
            let backend = PitchHostBackend(root: artifacts, probe: probe)
            let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 100))
            return WorkbenchSession(engine: runtime, backendID: "fixture.image", status: {
                let state = await runtime.snapshot()
                return .init(activeRunID: state.activeRunID, phase: state.phase?.rawValue, queuedRunIDs: state.queuedRunIDs)
            }, shutdown: { await runtime.shutdown() }, cleanup: {}, validateModel: { _ in },
            pitchBackendID: backend.descriptor.id,
            pitchModel: .init(directory: root.appendingPathComponent("fixture-model"), revision: PitchAnalysisRequest.modelSHA256))
        }, settings: settings, audioEnabled: true)
        let project = root.appendingPathComponent("Host.dproject"), source = root.appendingPathComponent("voice.wav")
        try AudioTestMedia.writePCM(to: source, samples: [[Float](repeating: 0.1, count: 16000)], sampleRate: 16000, bitDepth: 32, floatingPoint: true)
        let original = try Data(contentsOf: source)
        await subject.createProject(at: project)
        let other = try #require(subject.activeDocumentID)
        #expect(await subject.importAudio(at: source, name: "中文 e\u{301} 🎵"))
        let document = try #require(subject.activeDocumentID)
        await probe.setWait(true)
        await subject.analyzePitch()
        try await until { await probe.started == 1 }
        #expect(await subject.selectDocument(id: other))
        try await until { !subject.isBusy }
        #expect(await probe.releases == 1)
        #expect(subject.manifest?.jobs.last?.state == .cancelled)
        #expect(await subject.selectDocument(id: document))
        await probe.setWait(false)
        await subject.analyzePitch()
        try await until { !subject.isBusy }
        await subject.refreshPitchAnalysis()
        #expect(subject.pitchResult != nil && !subject.pitchHasSaved)
        let audio = try #require(subject.audio)
        #expect(audio.setNoteInput("new unsaved 中文", contextID: audio.contextID, documentID: document))
        #expect(subject.pitchIsStale)
        await subject.decidePitchAnalysis(accept: true)
        #expect(!subject.pitchHasSaved)
        #expect(audio.discardUnsubmittedInput(contextID: audio.contextID, documentID: document))
        await subject.decidePitchAnalysis(accept: true)
        #expect(subject.pitchHasSaved)
        let accepted = subject.pitchResultAssetID
        await subject.analyzePitch()
        try await until { !subject.isBusy }
        await subject.refreshPitchAnalysis()
        #expect(subject.pitchResultAssetID != accepted)
        #expect(await subject.selectDocument(id: other))
        #expect(await subject.selectDocument(id: document))
        await subject.refreshPitchAnalysis()
        #expect(subject.pitchIsStale)
        await subject.decidePitchAnalysis(accept: false)
        #expect(subject.pitchResultAssetID == accepted && subject.pitchHasSaved)
        await subject.exportPitchAnalysis(to: root.appendingPathComponent("analysis.json"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("analysis.json").path))
        #expect(await subject.cancelAndCloseProject())
        let reopened = try await ProjectStore.open(at: project)
        #expect(await reopened.snapshot().documents.last?.pitchAnalysis?.selectedAssetID == accepted)
        #expect(try Data(contentsOf: source) == original)
        try await reopened.close()
    }
    private func until(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await predicate()) {
            try #require(ContinuousClock.now < deadline, "Pitch host did not reach required state")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
