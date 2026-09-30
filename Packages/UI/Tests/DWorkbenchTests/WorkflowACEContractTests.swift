import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("ACE shared recipe and Store boundary")
struct WorkflowACEContractTests {
    @Test func lyricsReferencesAndEditClocksRemainDistinct() throws {
        var node = WorkflowACEOperation.operation.definition.makeNode()
        let style = AudioSourceReference(url: URL(fileURLWithPath: "/fixture/style.wav"),
            sha256: String(repeating: "a", count: 64), frameCount: 96_000, sampleRate: 48_000, channels: 2)
        let source = AudioSourceReference(url: URL(fileURLWithPath: "/fixture/source.wav"),
            sha256: String(repeating: "b", count: 64), frameCount: 480_001, sampleRate: 48_000, channels: 2)
        #expect(throws: WorkflowIssue.self) {
            try WorkflowACEOperation.request(node: node, prompt: "piano", lyrics: "不能丢弃", reference: style, source: nil)
        }
        node.parameters["vocal"] = .text("lyrics")
        node.parameters["language"] = .text("zh")
        node.parameters["mode"] = .text("repaint")
        node.parameters["startFrame"] = .integer(48_001)
        node.parameters["endFrame"] = .integer(96_001)
        node.parameters["bpm"] = .integer(93)
        node.parameters["keyScale"] = .text("C minor")
        node.parameters["meter"] = .text("3")
        let request = try WorkflowACEOperation.request(node: node, prompt: "完整描述 🎵", lyrics: "保留歌词",
                                                       reference: style, source: source)
        #expect(request.prompt == "完整描述 🎵")
        #expect(request.ace?.vocal == .lyrics(text: "保留歌词", language: "zh"))
        #expect(request.ace?.referenceAudio == style && request.source == source)
        #expect(request.durationSeconds == Double(source.frameCount) / 48_000)
        #expect(request.editRegion == .init(startFrame: 48_001, endFrame: 96_001))
        #expect(request.ace?.bpm == 93 && request.ace?.timeSignature == .three)
        #expect(throws: WorkflowIssue.self) {
            try WorkflowACEOperation.request(node: node, prompt: "piano", lyrics: "歌词", reference: style, source: nil)
        }
    }

    @Test(arguments: [false, true]) func actualOutputLengthIsSavedAndCheckedOnReopen(long: Bool) async throws {
        let parent = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
        let url = parent.appendingPathComponent("ace-store-" + UUID().uuidString + ".dproject")
        let store = try await ProjectStore.create(at: url, name: "ACE CPU fixture")
        let duration = long ? 380.0 : 0.1
        let requested = Int64(duration * 48_000), delivered = long ? 381 * 48_000 : 4_864
        let bytes = wave(frames: delivered)
        let request = InferenceRequest(model: .init(directory: parent, revision: "fixture"),
            input: .audio(.init(operation: .generate, prompt: "piano", durationSeconds: duration, seed: 42, ace: .init())))
        let details = receipt(requested: requested, delivered: Int64(delivered))
        var falseClaim = details; falseClaim["deliveredFrames"] = "4800"
        do {
            _ = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav",
                name: "bad", operationID: WorkflowModelRoutes.ace, request: request, details: falseClaim)
            Issue.record("False delivered length published")
        } catch {}
        #expect(await store.snapshot().assets.isEmpty)
        let result = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav",
            name: "tail retained", operationID: WorkflowModelRoutes.ace, request: request, details: details)
        #expect(result.asset.metadata.audio?.format.frameCount == Int64(delivered))
        let playbackPolicy = try await store.workflowAudioPlaybackPolicy(result.record.reference)
        let (playbackURL, _) = try await store.workflowMedia(result.record.reference)
        #expect(try AudioMediaInspector.inspect(at: playbackURL, policy: playbackPolicy).format.frameCount == Int64(delivered))
        if long {
            let (media, _) = try await store.workflowMedia(result.record.reference)
            #expect(throws: (any Error).self) { try AudioMediaInspector.inspect(at: media, policy: .generated) }
        }
        try await store.close()
        let reopened = try await ProjectStore.open(at: url)
        #expect(try await reopened.workflowData(result.record.reference) == bytes)
        #expect(try await reopened.workflowState().archive?.assets.first?.metadata == details)
        try await reopened.close()
    }

    @Test func longFloatAudioUsesRealImportEntryAndReopens() async throws {
        let parent = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
        let root = parent.appendingPathComponent("ace-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("200-seconds.wav")
        let bytes = wave(frames: 200 * 48_000)
        #expect(bytes.count > 64 * 1_024 * 1_024)
        try bytes.write(to: source, options: .withoutOverwriting)
        let project = root.appendingPathComponent("import.dproject")
        let store = try await ProjectStore.create(at: project, name: "ACE import fixture")
        let imported = try await store.importWorkflowMediaFile(at: source)
        #expect(imported.asset.metadata.audio?.format.frameCount == Int64(200 * 48_000))
        let policy = try await store.workflowAudioPlaybackPolicy(imported.record.reference)
        let (playbackURL, _) = try await store.workflowMedia(imported.record.reference)
        #expect(try AudioMediaInspector.inspect(at: playbackURL, policy: policy).format.frameCount == 200 * 48_000)
        try await store.close()
        let reopened = try await ProjectStore.open(at: project)
        #expect(try await reopened.workflowData(imported.record.reference) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        try await reopened.close()
    }

    private func receipt(requested: Int64, delivered: Int64) -> [String: String] {
        ["profile": ACERequest.fixedProfile, "requestedFrames": String(requested),
         "effectiveFrames": String(requested), "deliveredFrames": String(delivered),
         "tailPaddingFrames": String(max(0, delivered - requested)), "shortfallFrames": String(max(0, requested - delivered))]
    }
    private func wave(frames: Int) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); number(UInt32(36 + frames * 8)); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(3)); number(UInt16(2)); number(UInt32(48_000)); number(UInt32(384_000))
        number(UInt16(8)); number(UInt16(32)); text("data"); number(UInt32(frames * 8))
        data.append(Data(repeating: 0, count: frames * 8)); return data
    }
}
