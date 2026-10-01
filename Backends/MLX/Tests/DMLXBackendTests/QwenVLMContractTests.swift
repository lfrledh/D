import CoreImage
import CoreMedia
import CryptoKit
import DInference
import Foundation
import MLXLMCommon
import MLXVLM
import Testing
@testable import DMLXBackend

@Suite("Qwen3.5 VLM metadata contract")
struct QwenVLMContractTests {
    @Test func loadingStrategyIsExplicitAndLegacyJSONRemainsResident() throws {
        let legacy = TextRequest(prompt: "hello")
        let data = try JSONEncoder().encode(legacy)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["loadingStrategy"] == nil)
        #expect(try JSONDecoder().decode(TextRequest.self, from: data).loadingStrategy == nil)
        let selected = TextRequest(prompt: "hello", loadingStrategy: .ssdLayered)
        #expect(try JSONDecoder().decode(TextRequest.self,
            from: JSONEncoder().encode(selected)).loadingStrategy == .ssdLayered)
    }

    private let officialProcessor = Data("""
        {"processor_class":"Qwen3VLProcessor","image_processor_type":"Qwen2VLImageProcessorFast",
         "patch_size":16,"merge_size":2,"temporal_patch_size":2,
         "image_mean":[0.5,0.5,0.5],"image_std":[0.5,0.5,0.5],
         "size":{"shortest_edge":65536,"longest_edge":16777216}}
        """.utf8)

    @Test func nestedBudgetAndExplicitOverride() throws {
        let source = try QwenVLMProcessorConfiguration.normalized(officialProcessor, overrides: nil)
        #expect(source.minimum == 65_536 && source.maximum == 16_777_216)
        let object = try QwenVLMModelInventory.object(source.data)
        #expect(try QwenVLMModelInventory.integer(object, "min_pixels") == 65_536)
        #expect(try QwenVLMModelInventory.integer(object, "max_pixels") == 16_777_216)
        let override = try QwenVLMProcessorConfiguration.normalized(
            officialProcessor, overrides: TextVisualProcessing(minimumPixels: 100_000, maximumPixels: 1_000_000))
        #expect(override.minimum == 100_000 && override.maximum == 1_000_000)
    }

    @Test func conflictingTopLevelBudgetFails() throws {
        var object = try QwenVLMModelInventory.object(officialProcessor)
        object["min_pixels"] = 3136
        #expect(throws: (any Error).self) {
            try QwenVLMProcessorConfiguration.normalized(JSONSerialization.data(withJSONObject: object), overrides: nil)
        }
    }

    @Test func configurationIntegersRejectBooleanFractionAndOversize() throws {
        for source in ["{\"n\":true}", "{\"n\":1.0}",
                       "{\"n\":1.5}", "{\"n\":9223372036854775808}"] {
            let object = try QwenVLMModelInventory.object(Data(source.utf8))
            #expect(throws: (any Error).self) {
                _ = try QwenVLMModelInventory.integer(object, "n")
            }
        }
        let zero = try QwenVLMModelInventory.object(Data("{\"n\":0}".utf8))
        #expect(try QwenVLMModelInventory.integer(zero, "n") == 0)
        #expect(throws: (any Error).self) {
            _ = try QwenVLMModelInventory.object(Data("{\"n\":1,\"n\":2}".utf8))
        }
    }

    @Test func modelIdentityUsesBothNestedDimensions() throws {
        for (hidden, layers, expected) in [(4096, 32, "9B"), (5120, 64, "27B")] {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let config: [String: Any] = [
            "architectures": ["Qwen3_5ForConditionalGeneration"], "model_type": "qwen3_5",
            "text_config": ["model_type": "qwen3_5_text", "hidden_size": hidden,
                            "output_gate_type": expected == "9B" ? "sigmoid" : "swish",
                            "num_hidden_layers": layers, "max_position_embeddings": 262144,
                            "vocab_size": 248320, "head_dim": 256, "num_key_value_heads": 4,
                            "num_attention_heads": expected == "9B" ? 16 : 24,
                            "intermediate_size": expected == "9B" ? 12288 : 17408,
                            "linear_num_value_heads": expected == "9B" ? 32 : 48,
                            "full_attention_interval": 4,
                            "layer_types": (0..<layers).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" },
                            "dtype": "bfloat16"],
            "vision_config": ["model_type": "qwen3_5", "out_hidden_size": hidden,
                              "patch_size": 16, "spatial_merge_size": 2,
                              "temporal_patch_size": 2, "depth": 27,
                              "hidden_size": 1152, "intermediate_size": 4304,
                              "num_heads": 16, "num_position_embeddings": 2304,
                              "in_channels": 3]
            ]
            try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
            try officialProcessor.write(to: root.appendingPathComponent("preprocessor_config.json"))
            try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
            try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer_config.json"))
            try Data(repeating: 1, count: 16).write(to: root.appendingPathComponent("a.safetensors"))
            #expect(try QwenVLMModelInventory.validateModel(at: root).size == expected)
        }
    }

    @Test func outputGateTypeMustMatchKnownModelSize() throws {
        try QwenVLMModelInventory.validateOutputGateType([:], size: "9B")
        try QwenVLMModelInventory.validateOutputGateType(["output_gate_type": "sigmoid"], size: "9B")
        try QwenVLMModelInventory.validateOutputGateType(["output_gate_type": "swish"], size: "27B")
        for (size, gate) in [("9B", "unknown"), ("9B", "swish"),
                             ("27B", "sigmoid"), ("27B", "unknown")] {
            #expect(throws: (any Error).self) {
                try QwenVLMModelInventory.validateOutputGateType(["output_gate_type": gate], size: size)
            }
        }
        #expect(throws: (any Error).self) {
            try QwenVLMModelInventory.validateOutputGateType([:], size: "27B")
        }
    }

    @Test func privateCopyProtectsOriginalAndDetectsMutation() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let model = root.appendingPathComponent("model")
        let artifacts = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("clip.mp4")
        let bytes = Data("0123456789abc".utf8)
        try bytes.write(to: source)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let request = TextRequest(prompt: "clip", video: TextVideoReference(
            url: source, byteCount: UInt64(bytes.count), contentSHA256: digest, durationSeconds: 1))
        let snapshot = try QwenVLMInputSnapshot.freeze(request, in: artifacts, modelDirectory: model)
        defer { try? snapshot.removePrivateFiles() }
        #expect(try Data(contentsOf: snapshot.video!.privateURL) == bytes)
        try snapshot.verifyOriginals()
        try Data("mutated-source".utf8).write(to: source)
        do { try snapshot.verifyOriginals(); Issue.record("Changed input was accepted") }
        catch InferenceFailure.inputIntegrityChanged { }
        catch { Issue.record("Mutation must not be hidden by cancellation: \(error)") }
        #expect(try Data(contentsOf: snapshot.video!.privateURL) == bytes)
    }

    @Test func failedFreezeKeepsOriginalAndCleansOwnedPartialCopy() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let model = root.appendingPathComponent("model")
        let artifacts = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("clip.mp4")
        let bytes = Data("original-video".utf8)
        try bytes.write(to: source)
        let wrongDigest = String(repeating: "0", count: 64)
        let request = TextRequest(prompt: "clip", video: TextVideoReference(
            url: source, byteCount: UInt64(bytes.count), contentSHA256: wrongDigest, durationSeconds: 1))
        #expect(throws: (any Error).self) {
            try QwenVLMInputSnapshot.freeze(request, in: artifacts, modelDirectory: model)
        }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: artifacts.path).isEmpty)
    }

    @Test func attentionLayoutRejectsCrashAndWrongArchitecture() throws {
        let expected = (0..<32).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" }
        #expect(try QwenVLMModelInventory.validAttentionLayout(["layer_types": expected], layers: 32))
        #expect(try QwenVLMModelInventory.validAttentionLayout(
            ["layer_types": expected, "full_attention_interval": 4], layers: 32))
        for interval in [0, 3, 5] {
            #expect(try !QwenVLMModelInventory.validAttentionLayout(
                ["layer_types": expected, "full_attention_interval": interval], layers: 32))
        }
        var wrong = expected
        wrong[0] = "full_attention"
        #expect(try !QwenVLMModelInventory.validAttentionLayout(["layer_types": wrong], layers: 32))
        #expect(try !QwenVLMModelInventory.validAttentionLayout(
            ["layer_types": Array(repeating: "full_attention", count: 32)], layers: 32))
    }

    @Test func invalidImageNormalizationFailsBeforeProcessorLoad() throws {
        for (key, value) in [
            ("image_mean", [0.5, 0.5]),
            ("image_std", [0.5, 0.5]),
            ("image_std", [0.5, 0.0, 0.5]),
        ] {
            var object = try QwenVLMModelInventory.object(officialProcessor)
            object[key] = value
            #expect(throws: (any Error).self) {
                try QwenVLMProcessorConfiguration.normalized(
                    JSONSerialization.data(withJSONObject: object), overrides: nil)
            }
        }
    }

    @Test func privateCleanupPreservesUnknownAndReplacementEntries() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let model = root.appendingPathComponent("model")
        let artifacts = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("clip.mp4")
        let bytes = Data("original-video".utf8)
        try bytes.write(to: source)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let request = TextRequest(prompt: "clip", video: TextVideoReference(
            url: source, byteCount: UInt64(bytes.count), contentSHA256: digest, durationSeconds: 1))
        let snapshot = try QwenVLMInputSnapshot.freeze(request, in: artifacts, modelDirectory: model)
        let unknown = snapshot.directory.appendingPathComponent("unowned")
        try Data("keep".utf8).write(to: unknown)
        #expect(throws: (any Error).self) { try snapshot.removePrivateFiles() }
        #expect(try Data(contentsOf: unknown) == Data("keep".utf8))
        #expect(try Data(contentsOf: snapshot.video!.privateURL) == bytes)
        try FileManager.default.removeItem(at: unknown)
        let held = artifacts.appendingPathComponent("held")
        try FileManager.default.moveItem(at: snapshot.directory, to: held)
        try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: false)
        let replacement = snapshot.directory.appendingPathComponent("replacement")
        try Data("keep replacement".utf8).write(to: replacement)
        #expect(throws: (any Error).self) { try snapshot.removePrivateFiles() }
        #expect(try Data(contentsOf: replacement) == Data("keep replacement".utf8))
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func suppliedVideoFramesKeepCountOrderAndTimestamps() async throws {
        let timestamps = [0, 0.5, 1, 1.5].map { CMTime(seconds: $0, preferredTimescale: 600) }
        let frames = timestamps.enumerated().map { index, time in
            UserInput.VideoFrame(
                frame: CIImage(color: CIColor(red: CGFloat(index) / 4, green: 0, blue: 0))
                    .cropped(to: CGRect(x: CGFloat(index), y: 0, width: 2, height: 2)),
                timeStamp: time)
        }
        var observedOrigins = [Int]()
        let processed = try await MediaProcessing.asProcessedSequence(
            .frames(frames), targetFPS: { _ in 2 }, maxFrames: 4,
            preserveSuppliedFrames: true) { frame in
                observedOrigins.append(Int(frame.frame.extent.origin.x))
                return frame
            }
        #expect(processed.frames.count == 4)
        #expect(processed.timestamps == timestamps)
        #expect(observedOrigins == [0, 1, 2, 3])
        await #expect(throws: (any Error).self) {
            _ = try await MediaProcessing.asProcessedSequence(
                .frames(frames), targetFPS: { _ in 2 }, maxFrames: 3,
                preserveSuppliedFrames: true)
        }
        let reversed = [frames[1], frames[0]]
        await #expect(throws: (any Error).self) {
            _ = try await MediaProcessing.asProcessedSequence(
                .frames(reversed), targetFPS: { _ in 2 }, maxFrames: 4,
                preserveSuppliedFrames: true)
        }
        let cancelled = Task<Void, Error> {
            let cancelledFrames = (0..<4).map { index in
                UserInput.VideoFrame(
                    frame: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
                    timeStamp: CMTime(value: Int64(index), timescale: 2))
            }
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await MediaProcessing.asProcessedSequence(
                .frames(cancelledFrames), targetFPS: { _ in 2 }, maxFrames: 4,
                preserveSuppliedFrames: true)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}
