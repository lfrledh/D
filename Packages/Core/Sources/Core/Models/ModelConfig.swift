// Path: Core/Sources/Core/Models/ModelConfig.swift

import Foundation
import MLX

/// Generic model configuration parsed from config.json.
public struct ModelConfig: Sendable, Codable, Equatable {
    public let modelType: String
    public let architectures: [String]?
    public let hiddenSize: Int?
    public let numAttentionHeads: Int?
    public let numKeyValueHeads: Int?
    public let numHiddenLayers: Int?
    public let intermediateSize: Int?
    public let vocabSize: Int?
    public let maxPositionEmbeddings: Int?
    public let rmsNormEps: Float?
    public let ropeTheta: Float?
    public let torchDtype: String?
    public let numTrainTimesteps: Int?
    public let sampleSize: Int?
    public let tieWordEmbeddings: Bool?
    public let attentionBias: Bool?
    public let quantizationGroupSize: Int?
    public let quantizationBits: Int?

    public init(
        modelType: String,
        architectures: [String]? = nil,
        hiddenSize: Int? = nil,
        numAttentionHeads: Int? = nil,
        numKeyValueHeads: Int? = nil,
        numHiddenLayers: Int? = nil,
        intermediateSize: Int? = nil,
        vocabSize: Int? = nil,
        maxPositionEmbeddings: Int? = nil,
        rmsNormEps: Float? = nil,
        ropeTheta: Float? = nil,
        torchDtype: String? = nil,
        numTrainTimesteps: Int? = nil,
        sampleSize: Int? = nil,
        tieWordEmbeddings: Bool? = nil,
        attentionBias: Bool? = nil,
        quantizationGroupSize: Int? = nil,
        quantizationBits: Int? = nil
    ) {
        self.modelType = modelType
        self.architectures = architectures
        self.hiddenSize = hiddenSize
        self.numAttentionHeads = numAttentionHeads
        self.numKeyValueHeads = numKeyValueHeads
        self.numHiddenLayers = numHiddenLayers
        self.intermediateSize = intermediateSize
        self.vocabSize = vocabSize
        self.maxPositionEmbeddings = maxPositionEmbeddings
        self.rmsNormEps = rmsNormEps
        self.ropeTheta = ropeTheta
        self.torchDtype = torchDtype
        self.numTrainTimesteps = numTrainTimesteps
        self.sampleSize = sampleSize
        self.tieWordEmbeddings = tieWordEmbeddings
        self.attentionBias = attentionBias
        self.quantizationGroupSize = quantizationGroupSize
        self.quantizationBits = quantizationBits
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey, CaseIterable {
        case modelType = "model_type"
        case architectures
        case hiddenSize = "hidden_size"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case numHiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case vocabSize = "vocab_size"
        case maxPositionEmbeddings = "max_position_embeddings"
        case rmsNormEps = "rms_norm_eps"
        case ropeTheta = "rope_theta"
        case torchDtype = "torch_dtype"
        case numTrainTimesteps = "num_train_timesteps"
        case sampleSize = "sample_size"
        case tieWordEmbeddings = "tie_word_embeddings"
        case attentionBias = "attention_bias"
        case quantization = "quantization" // 嵌套对象
    }

    public init(from decoder: any Decoder) throws {
        print("[ModelConfig] All CodingKeys cases: \(CodingKeys.allCases.map { $0.rawValue })")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        print("[ModelConfig] All keys in container: \(container.allKeys)")
        
        // 解码所有属性
        modelType = try container.decode(String.self, forKey: .modelType)
        architectures = try container.decodeIfPresent([String].self, forKey: .architectures)
        hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize)
        numAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .numAttentionHeads)
        numKeyValueHeads = try container.decodeIfPresent(Int.self, forKey: .numKeyValueHeads)
        numHiddenLayers = try container.decodeIfPresent(Int.self, forKey: .numHiddenLayers)
        intermediateSize = try container.decodeIfPresent(Int.self, forKey: .intermediateSize)
        vocabSize = try container.decodeIfPresent(Int.self, forKey: .vocabSize)
        maxPositionEmbeddings = try container.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings)
        rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps)
        ropeTheta = try container.decodeIfPresent(Float.self, forKey: .ropeTheta)
        torchDtype = try container.decodeIfPresent(String.self, forKey: .torchDtype)
        numTrainTimesteps = try container.decodeIfPresent(Int.self, forKey: .numTrainTimesteps)
        sampleSize = try container.decodeIfPresent(Int.self, forKey: .sampleSize)
        tieWordEmbeddings = try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings)
        attentionBias = try container.decodeIfPresent(Bool.self, forKey: .attentionBias)
        // 解析 quantization 嵌套对象
        if let quantizationContainer = try? container.nestedContainer(keyedBy: QuantizationCodingKeys.self, forKey: .quantization) {
            quantizationGroupSize = try quantizationContainer.decodeIfPresent(Int.self, forKey: .groupSize)
            quantizationBits = try quantizationContainer.decodeIfPresent(Int.self, forKey: .bits)
        } else {
            quantizationGroupSize = nil
            quantizationBits = nil
        }
        print("[ModelConfig] Successfully decoded all properties")
    }
    
    // 内部嵌套键
    enum QuantizationCodingKeys: String, CodingKey {
        case groupSize = "group_size"
        case bits
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelType, forKey: .modelType)
        try container.encodeIfPresent(architectures, forKey: .architectures)
        try container.encodeIfPresent(hiddenSize, forKey: .hiddenSize)
        try container.encodeIfPresent(numAttentionHeads, forKey: .numAttentionHeads)
        try container.encodeIfPresent(numKeyValueHeads, forKey: .numKeyValueHeads)
        try container.encodeIfPresent(numHiddenLayers, forKey: .numHiddenLayers)
        try container.encodeIfPresent(intermediateSize, forKey: .intermediateSize)
        try container.encodeIfPresent(vocabSize, forKey: .vocabSize)
        try container.encodeIfPresent(maxPositionEmbeddings, forKey: .maxPositionEmbeddings)
        try container.encodeIfPresent(rmsNormEps, forKey: .rmsNormEps)
        try container.encodeIfPresent(ropeTheta, forKey: .ropeTheta)
        try container.encodeIfPresent(torchDtype, forKey: .torchDtype)
        try container.encodeIfPresent(numTrainTimesteps, forKey: .numTrainTimesteps)
        try container.encodeIfPresent(sampleSize, forKey: .sampleSize)
        try container.encodeIfPresent(tieWordEmbeddings, forKey: .tieWordEmbeddings)
        try container.encodeIfPresent(attentionBias, forKey: .attentionBias)

        // 处理 quantization 嵌套
        if quantizationGroupSize != nil || quantizationBits != nil {
            var quantContainer = container.nestedContainer(keyedBy: QuantizationCodingKeys.self, forKey: .quantization)
            try quantContainer.encodeIfPresent(quantizationGroupSize, forKey: .groupSize)
            try quantContainer.encodeIfPresent(quantizationBits, forKey: .bits)
        }
    }
    
    public static func parse(from jsonData: Data) throws -> ModelConfig {
        // 打印 JSON 字符串以便检查
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print("[ModelConfig] JSON string: \(jsonString)")
        } else {
            print("[ModelConfig] Failed to convert data to string")
        }
        
        // 打印 JSON 的顶层键
        if let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            print("[ModelConfig] JSON top-level keys: \(jsonObject.keys)")
        }
        
        let decoder = JSONDecoder()
        // 注释掉策略，因为我们在 CodingKeys 中已手动映射
        // decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ModelConfig.self, from: jsonData)
        } catch {
            print("[ModelConfig] Decode error: \(error)")
            throw error
        }
    }
    
    // MARK: - Derived Properties

    public var inferredDType: DType {
        switch torchDtype?.lowercased() {
        case "float32", "fp32":  return .float32
        case "bfloat16", "bf16": return .bfloat16
        case "float16", "fp16":  return .float16
        default:                  return .float16
        }
    }

    public var headDim: Int? {
        guard let h = hiddenSize, let n = numAttentionHeads, n > 0 else { return nil }
        return h / n
    }

    public var effectiveNumKVHeads: Int? { numKeyValueHeads ?? numAttentionHeads }
}
