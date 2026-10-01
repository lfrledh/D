import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow media publication through the existing Store")
struct WorkflowMediaStoreTests {
    /// Reuse a completed real run; this checks Store/recipe behavior, not inference or GUI.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_TEST_REAL_IMAGE_RESULT"] != nil))
    func realImagePublishesReopensAndExports() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("real-image-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let request = try JSONDecoder().decode(InferenceRequest.self,
            from: Data(contentsOf: URL(fileURLWithPath: try #require(env["D_TEST_REAL_IMAGE_REQUEST"]))))
        let result = try JSONDecoder().decode(InferenceResult.self,
            from: Data(contentsOf: URL(fileURLWithPath: try #require(env["D_TEST_REAL_IMAGE_RESULT"]))))
        guard case .image(let image) = request.input else { throw WorkflowIssue("Expected the original image request") }
        try #require(result.artifacts.count == 1)
        let source = try #require(result.artifacts.first)
        try #require(source.mediaType == "image/png")
        // Bind the original backend-owned output before assigning a new Store location.
        try #require(UUID(uuidString: String(source.url.deletingLastPathComponent().lastPathComponent.prefix(36))) == request.id)
        try #require(image.executionProfile == ImageExecutionCapability.flux2Dev.profile)
        try #require(result.metadata["imageExecutionProfile"] == image.executionProfile?.identifier)
        try #require(result.metadata["modelRevision"] == request.model.revision)
        let references = try image.resolvedReferences()
        try #require(result.metadata["referenceImageCount"] == String(references.count))
        try #require(result.metadata["referenceImageSHA256Ordered"] == references.map(\.sha256).joined(separator: ","))
        let original = try Data(contentsOf: source.url)
        let project = root.appendingPathComponent("Real image.dproject")
        let store = try await ProjectStore.create(at: project, name: "Real model output")
        let task = project.appendingPathComponent("Tasks/\(request.id)-\(UUID())")
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: false)
        let copy = task.appendingPathComponent("image.png")
        try original.write(to: copy, options: .withoutOverwriting)
        let bytes = try await store.readWorkflowBackendImage(.init(url: copy, mediaType: "image/png"), runID: request.id)
        let published = try await store.publishWorkflowAsset(data: bytes, mediaType: "image/png",
            metadata: .init(width: image.width, height: image.height, bitDepth: 8, colorSpace: "sRGB"),
            name: "Original precision result", operationID: "d.image.flux2-dev", request: request, details: result.metadata)
        try await store.close()
        let reopened = try await ProjectStore.open(at: project)
        #expect(try await reopened.workflowData(published.record.reference) == original)
        let record = try #require(try await reopened.workflowState().archive?.assets.first { $0.reference == published.record.reference })
        #expect(record.request == request && record.metadata == result.metadata)
        let exported = try await reopened.exportWorkflowAssets([published.record.reference], name: "export",
            exportID: UUID(), directory: root)
        #expect(exported.names == ["1.png", "recipe.json"])
        let package = root.appendingPathComponent("export-\(exported.id).dexport")
        #expect(try Data(contentsOf: package.appendingPathComponent("1.png")) == original)
        let recipe = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("recipe.json"))) as? [String: Any])
        let item = try #require((recipe["items"] as? [[String: Any]])?.first)
        #expect(item["modelRevision"] as? String == request.model.revision)
        #expect(item["seedDecimal"] as? String == String(image.seed))
        let exportedInput = try JSONDecoder().decode(InferenceInput.self, from: JSONSerialization.data(withJSONObject: try #require(item["input"])))
        guard case .image(let exportedImage) = exportedInput else { throw WorkflowIssue("Expected a public image recipe") }
        #expect(exportedImage.prompt == "[withheld]" && exportedImage.executionProfile == image.executionProfile)
        #expect(try exportedImage.resolvedReferences().isEmpty)
        try await reopened.close()
        #expect(try Data(contentsOf: source.url) == original)
        print("D_REAL_IMAGE_STORE", project.path, request.id, original.count)
    }

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

    @Test func workflowPitchPreparationPinsImmutableAudioWithoutCreatingADraft() async throws {
        let store = try await ProjectStore.create(at: location("pitch-input"), name: "pitch input")
        let bytes = try tone(), graphID = UUID(), runID = UUID()
        let original = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav", name: "原声",
            operationID: "d.asset.import")
        let before = await store.snapshot()
        let request = try await store.prepareWorkflowPitchInput(original.record.reference, graphID: graphID,
            runID: runID, range: .init(startFrame: 0, endFrame: 1_600))
        #expect(request.source.documentID == graphID)
        #expect(request.source.assetID == original.asset.id)
        #expect(request.source.contentSHA256 == original.record.reference.sha256)
        #expect(request.sampleCount == 1_600)
        #expect(try Data(contentsOf: request.inputURL).count == 6_400)
        #expect(try await store.workflowData(original.record.reference) == bytes)
        #expect(await store.snapshot() == before)
        do {
            _ = try await store.prepareWorkflowPitchInput(original.record.reference, graphID: graphID, runID: UUID(),
                range: .init(startFrame: 0, endFrame: 2_000))
            Issue.record("Out-of-range pitch input accepted")
        } catch {}
        #expect(await store.snapshot() == before)
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
