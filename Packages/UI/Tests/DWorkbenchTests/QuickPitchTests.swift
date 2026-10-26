import DInference
import Foundation
import Testing
@testable import DWorkbench

/// Controlled backend evidence, never claimed as real model inference.
private actor QuickPitchEngine: InferenceEngine {
    let root: URL
    private(set) var requests: [InferenceRequest] = []
    init(root: URL) { self.root = root }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        guard case .pitch(let input) = request.input else { throw ProjectStoreError.invalidTransition }
        requests.append(request)
        let result = PitchAnalysisResult(runID: request.id, source: input.source, inputSHA256: input.inputSHA256,
            sampleCount: input.sampleCount, frames: Array(repeating: .init(pitchHz: 440, confidence: 0.99, voiced: true), count: input.sampleCount / 256))
        let output = root.appendingPathComponent("Tasks/\(request.id.uuidString)/pitch.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: output)
        let completed = InferenceResult(artifacts: [.init(url: output, mediaType: PitchAnalysisResult.mediaType)])
        return .init(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { .completed(completed) })
    }
}

@Suite("Quick Pitch frozen attempt admission", .serialized) @MainActor
struct QuickPitchTests {
    private func fixture() async throws -> (ProjectStore, Data, WorkflowAssetReference) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("QuickPitch-\(UUID()).dproject")
        let store = try await ProjectStore.create(at: root, name: "controlled pitch fixture")
        let bytes = try WorkflowMusicPrograms.render(sequence: .init(clock: .seconds,
            notes: [.init(id: "tone", pitch: 69, start: 0, end: 1, velocity: 0.3)], duration: 1), sampleRate: 16_000)
        let asset = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav", name: "fixture source", operationID: "d.asset.import")
        return (store, bytes, asset.record.reference)
    }
    @Test(arguments: [false, true]) func realQuickCommandPinsAttemptAndSaveRetryDoesNotInferAgain(failPublication: Bool) async throws {
        let (store, original, ref) = try await fixture()
        let engine = QuickPitchEngine(root: store.rootURL)
        let session = WorkbenchSession(engine: engine, backendID: "fixture.pitch", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let quick = QuickGenerationController(store: store) {
            WorkflowServices(store: store, session: session) { _, identity in
                .init(identity: identity, reference: .init(directory: store.rootURL, revision: PitchAnalysisRequest.modelSHA256), backendID: "fixture.pitch")
            }
        }
        await quick.load(); quick.select(operationID: "d.music.pitch", modelID: "fixture:exact-pitch")
        quick.setInput("input", value: .asset(ref), draftID: try #require(quick.draft?.id))
        try await quick.flush()
        let frozen = try #require(quick.draft)
        let workflows = store.rootURL.appendingPathComponent("Workflows")
        if failPublication { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: workflows.path) }
        defer { if failPublication { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workflows.path) } }
        #expect(quick.canStart)
        quick.start(); await quick.waitForCompletion()
        let run = try #require(quick.state.runs.last)
        let requests = await engine.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        guard case .pitch(let input) = request.input else { Issue.record("Expected Pitch request"); return }
        #expect(request.id == run.id && input.source.documentID == run.id)
        #expect(input.source.assetID == ref.assetID && input.source.contentSHA256 == ref.sha256)
        #expect(run.draft == frozen)
        if failPublication {
            #expect(quick.pendingSaveRunID == run.id)
            #expect(run.status == .failed)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workflows.path)
            await quick.retrySave()
            #expect(quick.pendingSaveRunID == nil)
            #expect(await engine.requests.count == 1)
        }
        let saved = try #require(quick.state.runs.last)
        #expect(saved.status == .completed)
        let output = try #require(saved.outputs["pitch"]?.asset)
        let record = try #require(try await store.workflowState().archive?.assets.first { $0.reference == output })
        #expect(record.parents == [ref] && record.stepID == run.id)
        #expect(try await store.workflowData(ref) == original)
        try await quick.prepareForTermination(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.quickCreationState().runs.last == saved)
        #expect(try await reopened.workflowData(ref) == original)
        try await reopened.close()
    }
    @Test func unpersistedOrMismatchedAttemptCannotCreateInputSnapshot() async throws {
        let (store, _, ref) = try await fixture()
        let id = UUID(), node = WorkflowNode(operationID: "d.music.pitch", title: "fixture", parameters: ["modelID": .text("fixture:exact")])
        let inputs: [String: WorkflowValue] = ["input": .asset(ref)]
        await #expect(throws: (any Error).self) { _ = try await store.prepareQuickPitchInput(ref, runID: id, expectedNode: node, expectedInputs: inputs) }
        var state = try await store.quickCreationState()
        let draft = QuickDraft(id: "fixture", node: node, inputs: inputs)
        state.runs = [.init(id: id, draft: draft, createdAt: Date(), status: .running, outputs: [:], candidates: [], issue: nil)]
        _ = try await store.saveQuickCreationState(state, expectedRevision: state.revision)
        var different = node; different.title = "different frozen node"
        for (candidateID, candidateNode, candidateInputs) in [(UUID(), node, inputs), (id, different, inputs), (id, node, [:])] {
            await #expect(throws: (any Error).self) { _ = try await store.prepareQuickPitchInput(ref, runID: candidateID, expectedNode: candidateNode, expectedInputs: candidateInputs) }
        }
        #expect(!FileManager.default.fileExists(atPath: store.rootURL.appendingPathComponent("PitchInputs").path))
        let exact = try await store.prepareQuickPitchInput(ref, runID: id, expectedNode: node, expectedInputs: inputs)
        #expect(exact.source.documentID == id)
        try await store.close()
    }
}
