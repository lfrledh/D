import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing
@testable import MLXVLM

private struct TinyQwenFixture {
    let resident: Qwen35
    let layered: Qwen35
    let directory: URL

    static func configuration() throws -> Qwen35Configuration {
        let json = """
        {"model_type":"qwen3_5","image_token_id":60,"video_token_id":61,
         "image_token_index":60,"video_token_index":61,"vision_start_token_id":59,
         "text_config":{"model_type":"qwen3_5_text","hidden_size":64,
           "num_hidden_layers":4,"intermediate_size":128,"num_attention_heads":1,
           "num_key_value_heads":1,"head_dim":64,"linear_num_value_heads":1,
           "linear_num_key_heads":1,"linear_key_head_dim":64,
           "linear_value_head_dim":64,"linear_conv_kernel_dim":4,
           "vocab_size":64,"full_attention_interval":4,
           "rope_parameters":{"type":"default","mrope_section":[11,11,10],
             "partial_rotary_factor":1.0,"rope_theta":100000.0}},
         "vision_config":{"model_type":"qwen3_5","depth":1,"hidden_size":64,
           "intermediate_size":128,"out_hidden_size":64,"num_heads":1,
           "patch_size":2,"spatial_merge_size":1,"temporal_patch_size":1,
           "num_position_embeddings":16,"in_channels":3}}
        """
        return try Qwen35LayeredFileValidation.configuration(Data(json.utf8))
    }

    static func make(originalLayout: Bool = false) throws -> Self {
        let config = try configuration()
        let resident = withRandomState(MLXRandom.RandomState(seed: 17)) { Qwen35(config) }
        let weights = Dictionary(uniqueKeysWithValues: resident.parameters().flattened().map {
            ($0.0, $0.1.asType(.bfloat16))
        })
        try resident.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        try checkedEval(resident)
        resident.evaluateResidentLayersForComparison = true
        guard let root = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] else {
            throw Qwen35LayeredWeights.Failure.invalid("D_TEST_TEMP_DIR is required for this test")
        }
        let directory = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var shards = [[String: MLXArray](), [String: MLXArray]()]
        var map: [String: String] = [:]
        for (index, key) in weights.keys.sorted().enumerated() {
            let shard = index % 2
            var storedKey = key
            var storedValue = weights[key]!
            if originalLayout {
                if key.hasPrefix("language_model.model.") {
                    storedKey = "model.language_model." + key.dropFirst("language_model.model.".count)
                } else if key.hasPrefix("vision_tower.") {
                    storedKey = "model.visual." + key.dropFirst("vision_tower.".count)
                } else if key.hasPrefix("language_model.lm_head.") {
                    storedKey = String(key.dropFirst("language_model.".count))
                }
                if [".input_layernorm.weight", ".post_attention_layernorm.weight",
                    "model.norm.weight", ".q_norm.weight", ".k_norm.weight"]
                    .contains(where: { storedKey.hasSuffix($0) }) && storedValue.ndim == 1 {
                    storedValue = storedValue - MLXArray(1, dtype: storedValue.dtype)
                }
                if storedKey.contains("conv1d.weight") && storedValue.dim(-1) == 1 {
                    storedValue = storedValue.movedAxis(source: 1, destination: 2)
                }
                if storedKey.contains("patch_embed.proj.weight") && storedValue.ndim == 5 {
                    storedValue = storedValue.transposed(0, 4, 1, 2, 3)
                }
            }
            shards[shard][storedKey] = storedValue
            map[storedKey] = "model-0000\(shard + 1)-of-00002.safetensors"
        }
        for shard in 0..<2 {
            try save(arrays: shards[shard], metadata: ["format": originalLayout ? "pt" : "mlx"],
                     url: directory.appendingPathComponent("model-0000\(shard + 1)-of-00002.safetensors"))
        }
        let index: [String: Any] = ["weight_map": map]
        try JSONSerialization.data(withJSONObject: index).write(to:
            directory.appendingPathComponent("model.safetensors.index.json"))
        let layered = Qwen35(config, layered: true)
        try layered.loadLayeredWeights(from: directory)
        return Self(resident: resident, layered: layered, directory: directory)
    }
}

private func output(_ result: PrepareResult) throws -> LMOutput {
    guard case .logits(let output) = result else {
        throw Qwen35LayeredWeights.Failure.invalid("expected prefill logits")
    }
    return output
}

private func expectSameState(_ resident: [KVCache], _ layered: [KVCache]) {
    #expect(resident.count == layered.count)
    for (original, streamed) in zip(resident, layered) {
        #expect(original.offset == streamed.offset)
        let a = original.innerState()
        let b = streamed.innerState()
        #expect(a.count == b.count)
        for (left, right) in zip(a, b) {
            #expect(left.shape == right.shape)
            #expect(left.dtype == right.dtype)
            #expect(allClose(left, right, rtol: 0, atol: 0).item(Bool.self))
        }
    }
}

private struct PrefillStep {
    let logits: MLXArray
    let offsets: [Int]
    let state: [[MLXArray]]

    init(_ output: LMOutput, _ caches: [any KVCache]) {
        logits = output.logits[0..., -1, 0...]
        offsets = caches.map(\.offset)
        state = caches.map { $0.innerState() }
    }
}

private func expectSameSteps(_ original: [PrefillStep], _ streamed: [PrefillStep]) {
    #expect(original.count == streamed.count)
    for (a, b) in zip(original, streamed) {
        #expect(a.offsets == b.offsets)
        #expect(allClose(a.logits, b.logits, rtol: 0, atol: 0).item(Bool.self))
        for (left, right) in zip(a.state, b.state) {
            #expect(left.count == right.count)
            for (lhs, rhs) in zip(left, right) {
                #expect(lhs.shape == rhs.shape)
                #expect(lhs.dtype == rhs.dtype)
                #expect(allClose(lhs, rhs, rtol: 0, atol: 0).item(Bool.self))
            }
        }
    }
}

@Suite(.serialized) struct QwenLayeredTests {
@Test("Three linear and one attention block match BF16 resident prefill and decode")
func qwenLayeredMatchesResident() throws {
    let fixture = try TinyQwenFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    #expect(fixture.layered.loraLayers.isEmpty)
    #expect(!fixture.layered.layeredVisionIsResident)
    // Same two-token chunks and per-layer materialization on both paths.
    let input = LMInput(tokens: MLXArray([3, 4, 5, 6, 7]).reshaped(1, -1))
    let residentCache = fixture.resident.newCache(parameters: nil)
    let layeredCache = fixture.layered.newCache(parameters: nil)
    var residentSteps: [PrefillStep] = []
    var layeredSteps: [PrefillStep] = []
    fixture.resident.onComparisonPrefillStep = { residentSteps.append(PrefillStep($0, $1)) }
    fixture.layered.onComparisonPrefillStep = { layeredSteps.append(PrefillStep($0, $1)) }
    var r = try output(fixture.resident.prepare(input, cache: residentCache, windowSize: 2))
    var l = try output(fixture.layered.prepareThrowing(input, cache: layeredCache, windowSize: 2))
    #expect(residentSteps.count == 3)
    expectSameSteps(residentSteps, layeredSteps)
    #expect(allClose(r.logits[0..., -1, 0...], l.logits[0..., -1, 0...],
                     rtol: 0, atol: 0).item(Bool.self))
    expectSameState(residentCache, layeredCache)
    for token in [10, 11] {
        r = fixture.resident.callAsFunction(.init(tokens: MLXArray([token])),
            cache: residentCache, state: r.state)
        l = try fixture.layered.callThrowing(.init(tokens: MLXArray([token])),
            cache: layeredCache, state: l.state)
        #expect(allClose(r.logits, l.logits, rtol: 0, atol: 0).item(Bool.self))
        expectSameState(residentCache, layeredCache)
    }
    #expect(residentCache.map(\.offset) == layeredCache.map(\.offset))
    #expect(layeredCache[3].offset == 7) // full-attention KV cache
    #expect(layeredCache[0].offset == 0) // MambaCache offset is not its sequence count
    #expect((layeredCache[0] as? MambaCache)?[1]?.dtype == .float32)
    #expect((layeredCache[0] as? MambaCache)?[0] != nil)
    #expect((layeredCache[0] as? MambaCache)?[1] != nil)
    #expect(!fixture.layered.layeredVisionIsResident)
}

@Test("Missing or changed layer shard throws before a decode completes")
func qwenLayeredReportsLayerIO() throws {
    let fixture = try TinyQwenFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let shard = fixture.directory.appendingPathComponent("model-00001-of-00002.safetensors")
    try FileManager.default.removeItem(at: shard)
    let cache = fixture.layered.newCache(parameters: nil)
    #expect(throws: (any Error).self) {
        _ = try fixture.layered.prepareThrowing(
            LMInput(tokens: MLXArray([3, 4, 5]).reshaped(1, -1)), cache: cache, windowSize: 2)
    }
}

@Test("Image and video features remain ordered across layered prefill and decode")
func qwenLayeredKeepsMergedVisualState() throws {
    let fixture = try TinyQwenFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let imageFrame = THW(1, 2, 2), videoFrame = THW(2, 2, 2)
    let imageTokens: [Int32] = [2, 59] + Array(repeating: 60, count: 4)
    let videoTokens: [Int32] = [3, 59] + Array(repeating: 61, count: 8) + [4]
    let input = LMInput(
        text: .init(tokens: MLXArray(imageTokens + videoTokens).reshaped(1, -1)),
        image: .init(pixels: MLXArray.zeros([4, 12]), frames: [imageFrame]),
        video: .init(pixels: MLXArray.ones([8, 12]), frames: [videoFrame]))
    let residentCache = fixture.resident.newCache(parameters: nil)
    let layeredCache = fixture.layered.newCache(parameters: nil)
    var residentSteps: [PrefillStep] = []
    var layeredSteps: [PrefillStep] = []
    fixture.resident.onComparisonPrefillStep = { residentSteps.append(PrefillStep($0, $1)) }
    fixture.layered.onComparisonPrefillStep = { layeredSteps.append(PrefillStep($0, $1)) }
    let resident = try output(fixture.resident.prepare(input, cache: residentCache, windowSize: 2))
    let layered = try output(fixture.layered.prepareThrowing(input,
        cache: layeredCache, windowSize: 2))
    #expect(residentSteps.count == 9)
    expectSameSteps(residentSteps, layeredSteps)
    #expect(allClose(resident.logits[0..., -1, 0...],
                     layered.logits[0..., -1, 0...],
                     rtol: 0, atol: 0).item(Bool.self))
    expectSameState(residentCache, layeredCache)
    let r = fixture.resident.callAsFunction(.init(tokens: MLXArray([5])),
        cache: residentCache, state: resident.state)
    let l = try fixture.layered.callThrowing(.init(tokens: MLXArray([5])),
        cache: layeredCache, state: layered.state)
    #expect(allClose(r.logits, l.logits, rtol: 0, atol: 0).item(Bool.self))
    expectSameState(residentCache, layeredCache)
    #expect(!fixture.layered.layeredVisionIsResident)
}

@Test("Original-key safetensors load through sanitizer before layered inference")
func qwenLayeredSanitizesOriginalLayout() throws {
    let fixture = try TinyQwenFixture.make(originalLayout: true)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let input = LMInput(tokens: MLXArray([3]).reshaped(1, -1))
    let resident = try output(fixture.resident.prepare(input,
        cache: fixture.resident.newCache(parameters: nil), windowSize: 1))
    let layered = try output(fixture.layered.prepareThrowing(input,
        cache: fixture.layered.newCache(parameters: nil), windowSize: 1))
    #expect(allClose(resident.logits, layered.logits, rtol: 0, atol: 0).item(Bool.self))
}

@Test("A selected shard changed after lazy selection fails after evaluation")
func qwenLayeredRejectsPostSelectionMutation() throws {
    let fixture = try TinyQwenFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let weights = try Qwen35LayeredWeights(directory: fixture.directory)
    let layer = Qwen35Language.DecoderLayer(fixture.layered.config.textConfiguration, layerIdx: 0)
    weights.beforeSelectedEvaluation = {
        let shard = fixture.directory.appendingPathComponent("model-00001-of-00002.safetensors")
        let handle = try FileHandle(forUpdating: shard)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: length - 1)
        let old = try #require(handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: length - 1)
        try handle.write(contentsOf: Data([old ^ 0xff]))
    }
    do {
        try weights.loadLayer(0, into: layer, model: fixture.layered)
        Issue.record("Changed selected shard was accepted")
    } catch {
        #expect(error.localizedDescription.contains("shard changed during evaluation"))
    }
}

@Test("Cancelled layer loading propagates cancellation")
func qwenLayeredCancelledLayer() async throws {
    let observed = try await Task {
        let fixture = try TinyQwenFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let weights = try Qwen35LayeredWeights(directory: fixture.directory)
        let layer = Qwen35Language.DecoderLayer(fixture.layered.config.textConfiguration, layerIdx: 0)
        withUnsafeCurrentTask { $0?.cancel() }
        do { try weights.loadLayer(0, into: layer, model: fixture.layered); return false }
        catch is CancellationError { return true }
    }.value
    #expect(observed)
    #expect(!Task.isCancelled)
}

private func headerFixture(_ json: String, payload: Data = Data()) throws -> (URL, URL) {
    guard let root = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] else {
        throw Qwen35LayeredWeights.Failure.invalid("D_TEST_TEMP_DIR is required for this test")
    }
    let directory = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("model.safetensors")
    let bytes = Data(json.utf8)
    var data = Data((0..<8).map { UInt8((UInt64(bytes.count) >> ($0 * 8)) & 0xff) })
    data.append(bytes)
    data.append(payload)
    try data.write(to: file)
    return (directory, file)
}

@Test("Layered headers reject noninteger and unrepresentable dimensions")
func qwenLayeredStrictHeaderIntegers() throws {
    let bool = try JSONSerialization.jsonObject(with: Data("{\"shape\":[true]}".utf8)) as! [String: Any]
    let fraction = try JSONSerialization.jsonObject(with: Data("{\"shape\":[1.0]}".utf8)) as! [String: Any]
    let zero = try JSONSerialization.jsonObject(with: Data("{\"shape\":[0]}".utf8)) as! [String: Any]
    let huge = try JSONSerialization.jsonObject(with: Data("{\"shape\":[2147483648]}".utf8)) as! [String: Any]
    #expect(Qwen35LayeredWeights.strictDimensions(bool["shape"]) == nil)
    #expect(Qwen35LayeredWeights.strictDimensions(fraction["shape"]) == nil)
    #expect(Qwen35LayeredWeights.strictDimensions(zero["shape"]) == nil)
    #expect(Qwen35LayeredWeights.strictDimensions(huge["shape"]) == nil)
    #expect(Qwen35LayeredWeights.strictOffsets([false, 4]) == nil)
    #expect(Qwen35LayeredWeights.strictOffsets([0.5, 4]) == nil)
}

@Test("Layered headers reject truncation, duplicate keys and overlapping offsets")
func qwenLayeredRejectsMalformedHeaders() throws {
    let (shortDirectory, shortFile) = try headerFixture("{}")
    defer { try? FileManager.default.removeItem(at: shortDirectory) }
    try Data([255, 255, 255, 255, 255, 255, 255, 127]).write(to: shortFile)
    #expect(throws: (any Error).self) { _ = try Qwen35LayeredFileValidation.header(shortFile) }

    let (duplicateDirectory, duplicateFile) = try headerFixture(
        "{\"a\":{\"dtype\":\"BF16\",\"shape\":[1],\"data_offsets\":[0,2]}," +
        "\"a\":{\"dtype\":\"BF16\",\"shape\":[1],\"data_offsets\":[2,4]}}",
        payload: Data(repeating: 0, count: 4))
    defer { try? FileManager.default.removeItem(at: duplicateDirectory) }
    #expect(throws: (any Error).self) { _ = try Qwen35LayeredFileValidation.header(duplicateFile) }

    let (overlapDirectory, _) = try headerFixture(
        "{\"a\":{\"dtype\":\"BF16\",\"shape\":[2],\"data_offsets\":[0,4]}," +
        "\"b\":{\"dtype\":\"BF16\",\"shape\":[1],\"data_offsets\":[2,4]}}",
        payload: Data(repeating: 0, count: 4))
    defer { try? FileManager.default.removeItem(at: overlapDirectory) }
    #expect(throws: (any Error).self) { _ = try Qwen35LayeredWeights(directory: overlapDirectory) }
}

@Test("Malformed dimensions reject before construction rather than trap")
func configurationRejectsTrappingControls() throws {
    let data = try JSONEncoder().encode(TinyQwenFixture.configuration())
    let base = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var oversized = base, oversizedText = try #require(base["text_config"] as? [String: Any])
    oversizedText["linear_key_head_dim"] = 1_000_000_000
    oversizedText["linear_value_head_dim"] = 1_000_000_000
    oversized["text_config"] = oversizedText
    #expect(throws: (any Error).self) { _ = try Qwen35LayeredFileValidation.configuration(JSONSerialization.data(withJSONObject: oversized)) }
    for (hidden, heads) in [(64, 0), (Int.min, -1), (64, 3)] {
        var object = base, text = try #require(base["text_config"] as? [String: Any])
        text.removeValue(forKey: "head_dim")
        text["hidden_size"] = hidden; text["num_attention_heads"] = heads
        object["text_config"] = text
        #expect(throws: (any Error).self) { _ = try Qwen35LayeredFileValidation.configuration(JSONSerialization.data(withJSONObject: object)) }
    }
    for (key, value) in [("linear_num_key_heads", 3 as Any),
                         ("vocab_size", 0 as Any), ("full_attention_interval", 0 as Any)] {
        var object = base, text = try #require(base["text_config"] as? [String: Any])
        text[key] = value; object["text_config"] = text
        #expect(throws: (any Error).self) { _ = try Qwen35LayeredFileValidation.configuration(JSONSerialization.data(withJSONObject: object)) }
    }
    for (key, value) in [("partial_rotary_factor", 1e30 as Any),
                         ("mrope_section", [Int.max, 11, 10] as Any)] {
        var object = base, text = try #require(base["text_config"] as? [String: Any])
        var rope = try #require(text["rope_parameters"] as? [String: Any])
        rope[key] = value; text["rope_parameters"] = rope; object["text_config"] = text
        #expect(throws: (any Error).self) { _ = try Qwen35LayeredFileValidation.configuration(JSONSerialization.data(withJSONObject: object)) }
    }
}
}
