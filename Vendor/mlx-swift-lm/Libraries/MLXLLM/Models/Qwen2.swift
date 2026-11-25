//
//  Qwen2.swift
//  LLM
//
//  Created by John Mai on 2024/3/3.
//

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// port of https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/models/qwen2.py

class Qwen2Attention: Module {
    let args: Qwen2Configuration
    let scale: Float

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear

    let rope: RoPE

    public init(_ args: Qwen2Configuration) {
        self.args = args

        let dim = args.hiddenSize
        let heads = args.attentionHeads
        let kvHeads = args.kvHeads

        let headDim = args.hiddenSize / heads
        self.scale = pow(Float(headDim), -0.5)

        _wq.wrappedValue = Linear(dim, heads * headDim, bias: true)
        _wk.wrappedValue = Linear(dim, kvHeads * headDim, bias: true)
        _wv.wrappedValue = Linear(dim, kvHeads * headDim, bias: true)
        _wo.wrappedValue = Linear(heads * headDim, dim, bias: false)

        let ropeScale: Float
        if let ropeScaling = args.ropeScaling, ropeScaling["type"] == .string("linear"),
            let factor = ropeScaling["factor"]
        {
            if let v = factor.asFloat() {
                ropeScale = 1 / v
            } else {
                fatalError("ropeScaling.factor must be a float")
            }
        } else {
            ropeScale = 1
        }

        self.rope = RoPE(
            dimensions: headDim, traditional: args.ropeTraditional, base: args.ropeTheta,
            scale: ropeScale)
    }

    public func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))

        var queries = wq(x)
        var keys = wk(x)
        var values = wv(x)

        // prepare the queries, keys and values for the attention computation
        queries = queries.reshaped(B, L, args.attentionHeads, -1).transposed(0, 2, 1, 3)
        keys = keys.reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)

        let offset = cache?.ropeOffset
        queries = applyRotaryPosition(rope, to: queries, offset: offset)
        keys = applyRotaryPosition(rope, to: keys, offset: offset)

        let output = attentionWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            scale: scale,
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return wo(output)
    }
}

class Qwen2MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    public init(dimensions: Int, hiddenDimensions: Int) {
        _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

class Qwen2TransformerBlock: Module {
    @ModuleInfo(key: "self_attn") var attention: Qwen2Attention
    let mlp: Qwen2MLP

    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    public init(_ args: Qwen2Configuration) {
        _attention.wrappedValue = Qwen2Attention(args)
        self.mlp = Qwen2MLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        _inputLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    public func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        var r = attention(inputLayerNorm(x), mask: mask, cache: cache)
        let h = x + r
        r = mlp(postAttentionLayerNorm(h))
        let out = h + r
        return out
    }
}

public class Qwen2ModelInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding

    fileprivate let layers: [Qwen2TransformerBlock]
    let norm: RMSNorm

    public init(_ args: Qwen2Configuration, layered: Bool = false) {
        precondition(args.vocabularySize > 0)

        _embedTokens.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)

        self.layers = (0 ..< (layered ? 0 : args.hiddenLayers))
            .map { _ in
                Qwen2TransformerBlock(args)
            }
        self.norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]? = nil) -> MLXArray {
        var h = embedTokens(inputs)

        let mask = createAttentionMask(h: h, cache: cache?.first)

        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[i])
        }

        return norm(h)
    }
}

public class Qwen2Model: Module, LLMModel, KVCacheDimensionProvider, ThrowingLanguageModel {
    public let vocabularySize: Int
    public let kvHeads: [Int]

    public let model: Qwen2ModelInner
    let configuration: Qwen2Configuration

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    private var layeredWeights: Qwen2LayeredWeights?

    public convenience init(_ args: Qwen2Configuration) { self.init(args, layered: false) }

    public init(_ args: Qwen2Configuration, layered: Bool) {
        self.configuration = args
        self.vocabularySize = args.vocabularySize
        self.kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
        self.model = Qwen2ModelInner(args, layered: layered)

        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var out = model(inputs, cache: cache)
        if let lmHead {
            out = lmHead(out)
        } else {
            out = model.embedTokens.asLinear(out)
        }
        return out
    }

    public func loadLayeredWeights(from directory: URL, fileSelection: ModelFileSelection,
                                   quantization: BaseConfiguration.PerLayerQuantization?,
                                   validate: @escaping @Sendable () throws -> Void) throws {
        guard model.layers.isEmpty else { throw Qwen2LayeredWeights.invalid("resident model cannot be repurposed") }
        let weights = try Qwen2LayeredWeights(directory: directory, files: fileSelection,
            quantization: quantization, validate: validate)
        let shared = try weights.read { !$0.hasPrefix("model.layers.") }
        try weights.install(into: self, values: sanitize(weights: shared), prefix: "")
        layeredWeights = weights
    }

    public func prepareThrowing(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        guard layeredWeights != nil else { return try prepare(input, cache: cache, windowSize: windowSize) }
        let step = windowSize ?? 512
        guard step > 0 else { throw Qwen2LayeredWeights.invalid("invalid prefill window") }
        var remaining = input.text
        try withPreparedCache(cache, lengths: remaining.sequenceLengths) {
            while remaining.tokens.size > step {
                _ = try callThrowing(remaining[.newAxis, ..<step], cache: cache, state: nil)
                remaining = remaining[step...]
            }
        }
        return .tokens(remaining)
    }

    public func callThrowing(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) throws -> LMOutput {
        guard let weights = layeredWeights else { return self(input, cache: cache, state: state) }
        guard cache == nil || cache?.count == configuration.hiddenLayers else {
            throw Qwen2LayeredWeights.invalid("cache layer count differs from configuration")
        }
        try weights.validate()
        var hidden = model.embedTokens(input.tokens)
        let mask = createAttentionMask(h: hidden, cache: cache?.first)
        for index in 0..<configuration.hiddenLayers {
            try Task.checkCancellation()
            let layer = withRandomState(MLXRandom.RandomState(seed: 0)) { Qwen2TransformerBlock(configuration) }
            let prefix = "model.layers.\(index)."
            let values = try weights.read { $0.hasPrefix(prefix) }
            let local = Dictionary(uniqueKeysWithValues: values.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
            try weights.install(into: layer, values: local, prefix: prefix)
            hidden = layer(hidden, mask: mask, cache: cache?[index])
            try checkedEval([hidden] + (cache?[index].innerState() ?? []))
            try weights.validate()
        }
        hidden = model.norm(hidden)
        let logits = lmHead?(hidden) ?? model.embedTokens.asLinear(hidden)
        try checkedEval(logits)
        try weights.validate()
        return .init(logits: logits)
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var weights = weights

        if configuration.tieWordEmbeddings {
            weights["lm_head.weight"] = nil
        }

        // Remove unused precomputed rotary freqs
        return weights.filter {
            !$0.key.contains("self_attn.rotary_emb.inv_freq")
        }
    }
}

public struct Qwen2Configuration: Codable, Sendable {
    var hiddenSize: Int
    var hiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var rmsNormEps: Float
    var vocabularySize: Int
    var kvHeads: Int
    var ropeTheta: Float = 1_000_000
    var ropeTraditional: Bool = false
    var ropeScaling: [String: StringOrNumber]? = nil
    var tieWordEmbeddings = false

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case kvHeads = "num_key_value_heads"
        case ropeTheta = "rope_theta"
        case ropeTraditional = "rope_traditional"
        case ropeScaling = "rope_scaling"
        case tieWordEmbeddings = "tie_word_embeddings"
    }

    public init(from decoder: Decoder) throws {
        // custom implementation to handle optional keys with required values
        let container: KeyedDecodingContainer<Qwen2Configuration.CodingKeys> =
            try decoder.container(
                keyedBy: Qwen2Configuration.CodingKeys.self)

        self.hiddenSize = try container.decode(
            Int.self, forKey: Qwen2Configuration.CodingKeys.hiddenSize)
        self.hiddenLayers = try container.decode(
            Int.self, forKey: Qwen2Configuration.CodingKeys.hiddenLayers)
        self.intermediateSize = try container.decode(
            Int.self, forKey: Qwen2Configuration.CodingKeys.intermediateSize)
        self.attentionHeads = try container.decode(
            Int.self, forKey: Qwen2Configuration.CodingKeys.attentionHeads)
        self.rmsNormEps = try container.decode(
            Float.self, forKey: Qwen2Configuration.CodingKeys.rmsNormEps)
        self.vocabularySize = try container.decode(
            Int.self, forKey: Qwen2Configuration.CodingKeys.vocabularySize)
        self.kvHeads = try container.decode(Int.self, forKey: Qwen2Configuration.CodingKeys.kvHeads)
        self.ropeTheta =
            try container.decodeIfPresent(
                Float.self, forKey: Qwen2Configuration.CodingKeys.ropeTheta)
            ?? 1_000_000
        self.ropeTraditional =
            try container.decodeIfPresent(
                Bool.self, forKey: Qwen2Configuration.CodingKeys.ropeTraditional) ?? false
        self.ropeScaling = try container.decodeIfPresent(
            [String: StringOrNumber].self, forKey: Qwen2Configuration.CodingKeys.ropeScaling)
        self.tieWordEmbeddings =
            try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
    }
}

// MARK: - LoRA

extension Qwen2Model: LoRAModel {
    public var loraLayers: [Module] {
        model.layers
    }
}

/// The four admitted Qwen2.5 Q4 revisions use a fixed index and original packed
/// tensors. Only selected arrays survive each shard read; no re-quantization.
final class Qwen2LayeredWeights {
    let validate: @Sendable () throws -> Void
    private let directory: URL
    private let index: [String: String]
    private let quantization: BaseConfiguration.PerLayerQuantization?

    static func invalid(_ message: String) -> Error {
        NSError(domain: "Qwen2LayeredWeights", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    init(directory: URL, files: ModelFileSelection,
         quantization: BaseConfiguration.PerLayerQuantization?,
         validate: @escaping @Sendable () throws -> Void) throws {
        self.directory = directory; self.validate = validate; self.quantization = quantization
        try validate()
        guard files.contains("model.safetensors.index.json") else {
            throw Self.invalid("The admitted Qwen2 weight index is missing")
        }
        let url = directory.appendingPathComponent("model.safetensors.index.json")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4 * 1024 * 1024 else { throw Self.invalid("Invalid Qwen2 index size") }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let index = object["weight_map"] as? [String: String], !index.isEmpty,
              index.count <= 65536,
              Set(index.values) == Set(files.weightURLs(in: directory).map(\.lastPathComponent)),
              index.values.allSatisfy({ !$0.contains("/") && files.contains($0) }) else {
            throw Self.invalid("Qwen2 index differs from the admitted shards")
        }
        self.index = index
        try validate()
    }

    func read(_ include: (String) -> Bool) throws -> [String: MLXArray] {
        try validate()
        let selected = index.filter { include($0.key) && !$0.key.contains("self_attn.rotary_emb.inv_freq") }
        guard !selected.isEmpty else { throw Self.invalid("Qwen2 weight stage is missing") }
        var result: [String: MLXArray] = [:]
        for shard in Set(selected.values).sorted() {
            try Task.checkCancellation()
            try validate()
            let arrays = try loadArrays(url: directory.appendingPathComponent(shard))
            for (name, file) in selected where file == shard {
                guard let value = arrays[name], [.uint32, .bfloat16, .float16, .float32].contains(value.dtype),
                      result[name] == nil else { throw Self.invalid("Missing or invalid Qwen2 tensor: " + name) }
                result[name] = value
            }
        }
        try validate()
        return result
    }

    func install(into module: Module, values: [String: MLXArray], prefix: String) throws {
        var changes: [(String, Module)] = []
        for (name, child) in module.leafModules().flattened() {
            guard let scales = values[name + ".scales"] else { continue }
            guard let q = quantization?.quantization(layer: prefix + name), q.bits == 4,
                  q.groupSize == 64, q.mode == .affine,
                  let packed = values[name + ".weight"], let biases = values[name + ".biases"],
                  packed.dtype == .uint32, packed.ndim == 2,
                  [.bfloat16, .float16, .float32].contains(scales.dtype), biases.dtype == scales.dtype else {
                throw Self.invalid("Invalid original packed Q4 group: " + prefix + name)
            }
            let shape: [Int]
            if let linear = child as? Linear { shape = linear.weight.shape }
            else if let embedding = child as? Embedding { shape = embedding.weight.shape }
            else { throw Self.invalid("Unsupported quantized Qwen2 module: " + name) }
            guard shape.count == 2, packed.dim(0) == shape[0], packed.dim(1) * 8 == shape[1],
                  shape[1] % q.groupSize == 0, scales.shape == [shape[0], shape[1] / q.groupSize],
                  biases.shape == scales.shape else { throw Self.invalid("Packed Qwen2 dimensions differ: " + name) }
            if let linear = child as? Linear {
                let bias = values[name + ".bias"]
                guard (linear.bias == nil) == (bias == nil), bias == nil || bias?.shape == linear.bias?.shape else {
                    throw Self.invalid("Qwen2 projection bias differs: " + name)
                }
                changes.append((name, QuantizedLinear(weight: packed, bias: bias, scales: scales,
                    biases: biases, groupSize: q.groupSize, bits: q.bits, mode: q.mode)))
            } else {
                changes.append((name, QuantizedEmbedding(weight: packed, scales: scales, biases: biases,
                    groupSize: q.groupSize, bits: q.bits, mode: q.mode)))
            }
        }
        module.update(modules: ModuleChildren.unflattened(changes))
        try module.update(parameters: ModuleParameters.unflattened(values), verify: [.all])
        try checkedEval(module)
        try validate()
    }
}
