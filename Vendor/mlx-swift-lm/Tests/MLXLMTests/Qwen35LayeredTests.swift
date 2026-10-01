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
            ($0.0, $0.1.asType($0.0.hasSuffix(".linear_attn.A_log") || $0.0.hasSuffix(".linear_attn.norm.weight") ? .float32 : .bfloat16))
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

@Test("Original FP32 linear controls retain their dtype without admitting arbitrary FP32 weights")
func qwenOriginalPrecisionControls() throws {
    #expect(Qwen35LayeredFileValidation.byteWidth(name: "model.language_model.layers.0.linear_attn.A_log", dtype: "F32") == 4)
    #expect(Qwen35LayeredFileValidation.byteWidth(name: "language_model.model.layers.2.linear_attn.norm.weight", dtype: "F32") == 4)
    #expect(Qwen35LayeredFileValidation.byteWidth(name: "language_model.model.layers.0.linear_attn.in_proj_qkv.weight", dtype: "F32") == nil)
    #expect(Qwen35LayeredFileValidation.byteWidth(name: "language_model.model.layers.0.linear_attn.A_log", dtype: "I32") == nil)
    #expect(Qwen35LayeredFileValidation.byteWidth(name: "language_model.model.layers.0.linear_attn.A_log", dtype: "BF16") == 2)
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

@Test("Original Qwen linear and attention blocks match independent resident import",
      .enabled(if: ProcessInfo.processInfo.environment["D_TEST_QWEN_REAL_BLOCKS"] == "1"))
func originalQwenBlocksMatch() throws {
    defer { Stream(.gpu).synchronize(); Stream(.cpu).synchronize(); Memory.clearCache() }
    let env = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(env["D_TEST_QWEN_VLM_DIR"]))
    let revision = try #require(env["D_TEST_QWEN_REVISION"])
    let configURL = directory.appendingPathComponent("config.json")
    let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
    let metadataBefore = try [configURL, indexURL].map(Qwen35LayeredFileValidation.identity)
    let config = try Qwen35LayeredFileValidation.configuration(
        Qwen35LayeredWeights.readBounded(configURL, maximum: 4 * 1024 * 1024))
    try #require(config.textConfiguration.fullAttentionInterval == 4)
    let index = try #require(JSONSerialization.jsonObject(with:
        Qwen35LayeredWeights.readBounded(indexURL, maximum: 4 * 1024 * 1024)) as? [String: Any])
    let map = try #require(index["weight_map"] as? [String: String])
    // Sparse sanitizer carrier: never evaluate its embedding/head placeholders.
    let owner = withRandomState(MLXRandom.RandomState(seed: 101)) { Qwen35(config, layered: true) }
    let loader = try Qwen35LayeredWeights(directory: directory)
    func make(_ i: Int) -> Qwen35Language.DecoderLayer {
        withRandomState(MLXRandom.RandomState(seed: 102)) {
            Qwen35Language.DecoderLayer(config.textConfiguration, layerIdx: i)
        }
    }
    func same(_ a: MLXArray, _ b: MLXArray) throws {
        try #require(a.shape == b.shape && a.dtype == b.dtype)
        #expect(allClose(a, b, rtol: 0, atol: 0).item(Bool.self))
    }
    func resident(_ i: Int) throws -> Qwen35Language.DecoderLayer {
        let raw = "model.language_model.layers.\(i).", local = "language_model.model.layers.\(i)."
        let selected = map.filter { $0.key.hasPrefix(raw) }
        try #require(!selected.isEmpty)
        var weights: [String: MLXArray] = [:], identities: [URL: String] = [:]
        for file in Set(selected.values).sorted() {
            try #require(!file.contains("/") && !file.contains("\\") && file.hasSuffix(".safetensors"))
            let url = directory.appendingPathComponent(file)
            identities[url] = try Qwen35LayeredFileValidation.identity(url)
            let (arrays, metadata) = try loadArraysAndMetadata(url: url)
            let keys = Set(selected.filter { $0.value == file }.keys)
            let slice = arrays.filter { keys.contains($0.key) }
            try #require(Set(slice.keys) == keys)
            for (key, value) in owner.sanitize(weights: slice, metadata: metadata) {
                try #require(key.hasPrefix(local))
                let name = String(key.dropFirst(local.count))
                try #require(weights[name] == nil)
                weights[name] = value // Preserve stored dtype, with no asType.
            }
        }
        let block = make(i)
        try #require(Set(weights.keys) == Set(block.parameters().flattened().map { $0.0 }))
        try block.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        try checkedEval(block)
        for (url, identity) in identities { try #require(Qwen35LayeredFileValidation.identity(url) == identity) }
        return block
    }
    func forward(_ block: Qwen35Language.DecoderLayer, _ x: MLXArray,
                 _ cache: any KVCache, _ position: Int) throws -> MLXArray {
        let count = x.dim(1)
        let positions = broadcast(MLXArray((position..<(position + count)).map { Int32($0) })
            .reshaped(1, 1, count), to: [3, 1, count])
        var mask: MLXArray?
        if case .array(let value) = createAttentionMask(h: x, cache: cache, returnArray: true) { mask = value }
        let result = withPreparedCache([cache], lengths: nil) {
            block(x, attentionMask: mask,
                  ssmMask: block.isLinear ? createSSMMask(h: x, cache: cache as? MambaCache) : nil,
                  cache: cache, positionIds: positions)
        }
        try checkedEval([result] + cache.innerState())
        return result
    }
    func run(_ i: Int, _ dtype: DType) throws -> DType {
        let original = try resident(i)
        let a: any KVCache = i == 0 ? MambaCache() : KVCacheSimple()
        let b: any KVCache = i == 0 ? MambaCache() : KVCacheSimple()
        var position = 0, outputDType = dtype
        for (step, count) in [2, 3, 1, 1].enumerated() {
            let width = config.textConfiguration.hiddenSize
            let values = (0..<(count * width)).map { Float(($0 + position * width) % 97 - 48) / 64 }
            let input = MLXArray(values).reshaped(1, count, width).asType(dtype)
            let streamed = make(i)
            try loader.loadLayer(i, into: streamed, model: owner)
            if step == 0 {
                let pa = Dictionary(uniqueKeysWithValues: original.parameters().flattened())
                let pb = Dictionary(uniqueKeysWithValues: streamed.parameters().flattened())
                try #require(Set(pa.keys) == Set(pb.keys))
                for key in pa.keys.sorted() { try same(pa[key]!, pb[key]!) }
            }
            let expected = try forward(original, input, a, position)
            let actual = try forward(streamed, input, b, position)
            try same(expected, actual)
            try #require(a.offset == b.offset && a.metaState == b.metaState)
            let ca = a.innerState(), cb = b.innerState()
            try #require(ca.count == cb.count)
            for (left, right) in zip(ca, cb) { try same(left, right) }
            if i == 3 { #expect(b.offset == position + count) }
            outputDType = actual.dtype
            let record: [String: Any] = ["revision": revision, "layer": i, "step": step,
                "tokens": count, "inputDType": String(describing: input.dtype),
                "outputDType": String(describing: actual.dtype), "cacheOffset": b.offset,
                "cache": cb.map { ["dtype": String(describing: $0.dtype), "shape": $0.shape] as [String: Any] }]
            print("QWEN_REAL_BLOCK " + String(decoding: try JSONSerialization.data(withJSONObject: record, options: .sortedKeys), as: UTF8.self))
            position += count
        }
        return outputDType
    }
    let control = withRandomState(MLXRandom.RandomState(seed: 73)) { MLXRandom.uniform(0.0..<1.0, [4]).asArray(Float.self) }
    let after = try withRandomState(MLXRandom.RandomState(seed: 73)) {
        let promoted = try run(0, .bfloat16)
        Stream().synchronize(); Memory.clearCache()
        _ = try run(3, promoted)
        Stream().synchronize(); Memory.clearCache()
        return MLXRandom.uniform(0.0..<1.0, [4]).asArray(Float.self)
    }
    #expect(after == control)
    #expect(try [configURL, indexURL].map(Qwen35LayeredFileValidation.identity) == metadataBefore)
}
}

// Run alone in a fresh process: upstream global compilation caches outlive tests.
@Suite(.serialized) struct QwenActivationOwnershipTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_TEST_QWEN_ACTIVATION_PROBE"] == "1"))
    func activationOwnership() throws {
        func snapshot(_ name: String) {
            Stream(.gpu).synchronize(); Stream(.cpu).synchronize(); Memory.clearCache()
            print("QWEN_ACTIVATION \(name) active=\(Memory.activeMemory) cache=\(Memory.cacheMemory)")
        }
        func upstream(_ fast: Bool, _ dtype: DType) throws {
            let input = MLXArray([-2.0 as Float, -0.5, 0, 0.5, 2]).asType(dtype)
            let output = fast ? GELU(approximation: .fast)(input) : GELU()(input)
            try checkedEval(output)
        }
        func scoped(_ fast: Bool, _ dtype: DType, compareUpstream: Bool = false) throws {
            let activation = Qwen3VLVision.ScopedGELU(fast: fast)
            let input = MLXArray([-10.0 as Float, -2, -0.5, 0, 0.5, 2, 10]).asType(dtype)
            let actual = activation(input)
            try checkedEval(actual)
            if compareUpstream {
                let expected = fast ? GELU(approximation: .fast)(input) : GELU()(input)
                try checkedEval(expected)
                #expect(actual.dtype == expected.dtype)
                #expect(arrayEqual(actual, expected).item(Bool.self))
            }
        }
        snapshot("before")
        try #require(Memory.activeMemory == 0)
        for _ in 0..<3 {
            for dtype in [DType.bfloat16, .float32] {
                try scoped(true, dtype); try scoped(false, dtype)
            }
            snapshot("scoped-released")
            #expect(Memory.activeMemory == 0 && Memory.cacheMemory == 0)
        }
        try upstream(true, .bfloat16); snapshot("global-fast-bf16")
        try upstream(false, .bfloat16); snapshot("global-exact-bf16")
        try upstream(true, .float32); snapshot("global-fast-f32")
        try upstream(false, .float32); snapshot("global-exact-f32")
        let globalBaseline = Memory.activeMemory
        for dtype in [DType.bfloat16, .float32] {
            try scoped(true, dtype, compareUpstream: true)
            try scoped(false, dtype, compareUpstream: true)
        }
        snapshot("scoped-parity-released")
        #expect(Memory.activeMemory == globalBaseline && Memory.cacheMemory == 0)
    }
}
