import Foundation

public struct T5Config: Codable, Sendable {
    public let dModel: Int
    public let numHeads: Int
    public let numLayers: Int
    public let dFf: Int
    public let dKv: Int
    public let vocabSize: Int
    public let layerNormEps: Float
    public let dropoutRate: Float
    public let denseActFn: String
    public let isGatedAct: Bool
    public let relativeAttentionNumBuckets: Int
    public let relativeAttentionMaxDistance: Int

    enum CodingKeys: String, CodingKey {
        case dModel = "d_model"
        case numHeads = "num_heads"
        case numLayers = "num_layers"
        case dFf = "d_ff"
        case dKv = "d_kv"
        case vocabSize = "vocab_size"
        case layerNormEps = "layer_norm_epsilon"
        case dropoutRate = "dropout_rate"
        case denseActFn = "dense_act_fn"
        case isGatedAct = "is_gated_act"
        case relativeAttentionNumBuckets = "relative_attention_num_buckets"
        case relativeAttentionMaxDistance = "relative_attention_max_distance"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dModel = try container.decode(Int.self, forKey: .dModel)
        numHeads = try container.decode(Int.self, forKey: .numHeads)
        numLayers = try container.decode(Int.self, forKey: .numLayers)
        dFf = try container.decode(Int.self, forKey: .dFf)
        dKv = try container.decodeIfPresent(Int.self, forKey: .dKv) ?? 64
        vocabSize = try container.decode(Int.self, forKey: .vocabSize)
        layerNormEps = try container.decode(Float.self, forKey: .layerNormEps)
        dropoutRate = try container.decode(Float.self, forKey: .dropoutRate)
        denseActFn = try container.decode(String.self, forKey: .denseActFn)
        isGatedAct = try container.decodeIfPresent(Bool.self, forKey: .isGatedAct) ?? false
        relativeAttentionNumBuckets = try container.decode(Int.self, forKey: .relativeAttentionNumBuckets)
        relativeAttentionMaxDistance = try container.decode(Int.self, forKey: .relativeAttentionMaxDistance)
    }
}
