import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow media publication through the existing Store")
struct WorkflowMediaStoreTests {
    private func location(_ name: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent(name + "-" + UUID().uuidString + ".dproject")
    }
    private func tone() throws -> Data {
        try WorkflowMusicPrograms.render(sequence: .init(clock: .seconds,
            notes: [.init(id: "原声🎵", pitch: 60, start: 0, end: 0.1, velocity: 0.3)], duration: 0.12), sampleRate: 16_000)
    }

    @Test func audioIsDecodedPublishedAndRestoredWithoutASecondStore() async throws {
        let url = location("audio"), bytes = try tone()
        let store = try await ProjectStore.create(at: url, name: "媒体")
        let result = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav", name: "合成参考音",
            operationID: "d.music.render")
        #expect(result.record.reference.kind == .audio)
        #expect(try await store.workflowState().archive?.version == 2)
        #expect(result.asset.metadata.audio?.origin == .programGenerated)
        #expect(result.asset.metadata.audio?.format.frameCount == 1_920)
        #expect(try await store.workflowData(result.record.reference) == bytes)
        try await store.close()
        let reopened = try await ProjectStore.open(at: url)
        #expect(try await reopened.workflowData(result.record.reference) == bytes)
        #expect(try await reopened.pinWorkflowAsset(result.asset.id) == result.record.reference)
        try await reopened.close()
    }

    @Test func invalidAudioNeverBecomesPublishedAndImportDoesNotChangeInput() async throws {
        let url = location("bad-audio"), store = try await ProjectStore.create(at: url, name: "bad")
        do {
            _ = try await store.publishWorkflowAsset(data: Data("not wave".utf8), mediaType: "audio/wav",
                name: "bad", operationID: "d.asset.import")
            Issue.record("Broken audio was published")
        } catch {}
        #expect(await store.snapshot().assets.isEmpty)
        let input = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + " 中文.wav")
        let bytes = try tone(); try bytes.write(to: input, options: .withoutOverwriting)
        let imported = try await store.importWorkflowFile(at: input)
        #expect(imported.asset.role == .original)
        #expect(imported.asset.metadata.audio?.origin == .importedFile)
        #expect(try Data(contentsOf: input) == bytes)
        try await store.close()
    }

    @Test func structuredNotesPreserveAndValidateSources() async throws {
        let store = try await ProjectStore.create(at: location("notes"), name: "notes")
        let original = try await store.publishWorkflowAsset(data: tone(), mediaType: "audio/wav", name: "原声", operationID: "d.asset.import")
        let notes = WorkflowNoteSequence(clock: .seconds, notes: [], duration: 0.12, sources: [original.record.reference])
        let bytes = try JSONEncoder().encode(notes.datum())
        do {
            _ = try await store.publishWorkflowAsset(data: bytes, mediaType: WorkflowMediaFormat.noteType,
                name: "missing source", operationID: "d.music.notes")
            Issue.record("Lost source was accepted")
        } catch {}
        let published = try await store.publishWorkflowAsset(data: bytes, mediaType: WorkflowMediaFormat.noteType,
            name: "音符", parents: [original.record.reference], operationID: "d.music.notes")
        #expect(published.record.reference.kind == .notes)
        let roundTrip = try WorkflowNoteSequence(datum: JSONDecoder().decode(WorkflowDatum.self,
            from: await store.workflowData(published.record.reference)))
        #expect(roundTrip == notes)
        #expect(published.record.parents == [original.record.reference])
        try await store.close()
    }

    @Test func rawVideoCannotSkipDecoder() async throws {
        let store = try await ProjectStore.create(at: location("admission"), name: "admission")
        do {
            _ = try await store.publishWorkflowAsset(data: Data([0, 1, 2]), mediaType: "video/mp4", name: "video", operationID: "d.video.generate")
            Issue.record("Unverified video published")
        } catch {}
        #expect(await store.snapshot().assets.isEmpty)
        try await store.close()
    }

    @Test func pitchCannotPublishWithMissingOriginalAndRequest() async throws {
        let store = try await ProjectStore.create(at: location("pitch-source"), name: "pitch")
        let source = PitchSourceIdentity(assetID: UUID(), documentID: UUID(), documentRevision: 0,
            contentSHA256: String(repeating: "a", count: 64), sampleRate: 16_000,
            frameCount: 2000, startFrame: 100, endFrame: 1379)
        let result = PitchAnalysisResult(runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
            sampleCount: 1280, frames: Array(repeating: .init(pitchHz: 440, confidence: 0.99, voiced: true), count: 5))
        let bytes = try JSONEncoder().encode(result)
        do {
            _ = try await store.publishWorkflowAsset(data: bytes, mediaType: PitchAnalysisResult.mediaType,
                name: "pitch", parents: [], operationID: "d.music.pitch")
            Issue.record("Unbound pitch original was admitted")
        } catch {}
        #expect(await store.snapshot().assets.isEmpty)
        try await store.close()
    }

    @Test func durableAssetFailureRetryKeepsSameVersionAndRejectsDifferentBytes() async throws {
        let store = try await ProjectStore.create(at: location("retry"), name: "retry")
        let bytes = try tone(), id = UUID()
        do {
            _ = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav", metadata: .init(), name: "tone",
                parents: [], operationID: "d.music.render", stepID: nil, request: nil, details: [:], assetID: id,
                checkpoint: { stage in if stage == .assetDurable { throw WorkflowIssue("fixture: disk unavailable") } })
            Issue.record("Expected injected save failure")
        } catch {}
        #expect(await store.snapshot().assets.isEmpty)
        let a = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav", name: "tone", operationID: "d.music.render", assetID: id)
        let b = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav", name: "tone", operationID: "d.music.render", assetID: id)
        #expect(a.record.reference == b.record.reference)
        do {
            _ = try await store.publishWorkflowAsset(data: Data([1, 2, 3]), mediaType: "audio/wav", name: "tone", operationID: "d.music.render", assetID: id)
            Issue.record("Different bytes reused immutable ID")
        } catch {}
        #expect(try await store.workflowData(a.record.reference) == bytes)
        try await store.close()
    }

    @Test func exportedAudioAndNotesUseActualBytesAndMutationIsDetected() async throws {
        let url = location("export"), store = try await ProjectStore.create(at: url, name: "export")
        let bytes = try tone()
        let item = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav", name: "tone", operationID: "d.music.render")
        let receipt = try await store.exportWorkflowAssets([item.record.reference], name: "音乐", exportID: UUID(), directory: url.deletingLastPathComponent())
        #expect(receipt.names == ["1.wav", "recipe.json"])
        let file = url.appendingPathComponent(item.asset.relativePath)
        try Data([0, 1, 2]).write(to: file)
        do { _ = try await store.workflowData(item.record.reference); Issue.record("Changed source was accepted") } catch {}
        try await store.close()
    }
}
