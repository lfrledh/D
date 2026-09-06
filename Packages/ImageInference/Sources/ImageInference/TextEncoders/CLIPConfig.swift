import Foundation

public struct CLIPConfig: Codable, Sendable {
    public let hiddenSize: Int
    public let numAttentionHeads: Int
    public let numHiddenLayers: Int
    public let intermediateSize: Int
    public let projectionDim: Int?
    public let vocabSize: Int
    public let maxPositionEmbeddings: Int
    public let layerNormEps: Float
    public let dropout: Float
    public let attentionDropout: Float
    public let hiddenAct: String
    public let eosTokenId: Int

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case numAttentionHeads = "num_attention_heads"
        case numHiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case projectionDim = "projection_dim"
        case vocabSize = "vocab_size"
        case maxPositionEmbeddings = "max_position_embeddings"
        case layerNormEps = "layer_norm_eps"
        case dropout = "dropout"
        case attentionDropout = "attention_dropout"
        case hiddenAct = "hidden_act"
        case eosTokenId = "eos_token_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        numAttentionHeads = try container.decode(Int.self, forKey: .numAttentionHeads)
        numHiddenLayers = try container.decode(Int.self, forKey: .numHiddenLayers)
        intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
        projectionDim = try container.decodeIfPresent(Int.self, forKey: .projectionDim)
        vocabSize = try container.decode(Int.self, forKey: .vocabSize)
        maxPositionEmbeddings = try container.decode(Int.self, forKey: .maxPositionEmbeddings)
        layerNormEps = try container.decode(Float.self, forKey: .layerNormEps)
        dropout = try container.decode(Float.self, forKey: .dropout)
        attentionDropout = try container.decode(Float.self, forKey: .attentionDropout)
        hiddenAct = try container.decode(String.self, forKey: .hiddenAct)
        eosTokenId = try container.decode(Int.self, forKey: .eosTokenId)
    }
}
