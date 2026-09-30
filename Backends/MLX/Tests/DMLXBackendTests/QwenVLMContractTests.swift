import CryptoKit
import DInference
import Foundation
import Testing
@testable import DMLXBackend

@Suite("Qwen3.5 VLM metadata contract")
struct QwenVLMContractTests {
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

    @Test func modelIdentityUsesBothNestedDimensions() throws {
        for (hidden, layers, expected) in [(4096, 32, "9B"), (5120, 64, "27B")] {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
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
                            "layer_types": Array(repeating: "full_attention", count: layers),
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
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
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
        defer { snapshot.removePrivateFiles() }
        #expect(try Data(contentsOf: snapshot.video!.privateURL) == bytes)
        try snapshot.verifyOriginals()
        try Data("mutated-source".utf8).write(to: source)
        #expect(throws: (any Error).self) { try snapshot.verifyOriginals() }
        #expect(try Data(contentsOf: snapshot.video!.privateURL) == bytes)
    }

    @Test func upstreamFrameResamplingIsDetectedBeforeLoad() {
        #expect(MLXQwenVLMBackend.upstreamFrameCount([0]) == 1)
        #expect(MLXQwenVLMBackend.upstreamFrameCount([0, 0.5, 1.0]) == 2)
    }
}
