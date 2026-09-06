import Foundation
import Core

/// SD3 模型配置，对应 Python 的 __init__ 参数
public struct SD3Config: Codable, Sendable {
    public let sampleSize: Int
    public let patchSize: Int
    public let inChannels: Int
    public let numLayers: Int
    public let attentionHeadDim: Int
    public let numAttentionHeads: Int
    public let jointAttentionDim: Int
    public let captionProjectionDim: Int
    public let pooledProjectionDim: Int
    public let outChannels: Int
    public let posEmbedMaxSize: Int
    public let dualAttentionLayers: [Int]   // SD3.5 需要双流注意力的层索引
    public let qkNorm: String?               // 如 "rms_norm"

    public init(
        sampleSize: Int = 128,
        patchSize: Int = 2,
        inChannels: Int = 16,
        numLayers: Int = 18,
        attentionHeadDim: Int = 64,
        numAttentionHeads: Int = 18,
        jointAttentionDim: Int = 4096,
        captionProjectionDim: Int = 1152,
        pooledProjectionDim: Int = 2048,
        outChannels: Int = 16,
        posEmbedMaxSize: Int = 96,
        dualAttentionLayers: [Int] = [],
        qkNorm: String? = nil
    ) {
        self.sampleSize = sampleSize
        self.patchSize = patchSize
        self.inChannels = inChannels
        self.numLayers = numLayers
        self.attentionHeadDim = attentionHeadDim
        self.numAttentionHeads = numAttentionHeads
        self.jointAttentionDim = jointAttentionDim
        self.captionProjectionDim = captionProjectionDim
        self.pooledProjectionDim = pooledProjectionDim
        self.outChannels = outChannels
        self.posEmbedMaxSize = posEmbedMaxSize
        self.dualAttentionLayers = dualAttentionLayers
        self.qkNorm = qkNorm
    }

    /// 从 HuggingFace 的 config.json 解析
    public static func from(url: URL) throws -> SD3Config {
        let data = try Data(contentsOf: url)
        // 此处可扩展解析逻辑，目前先用默认值
        return SD3Config()
    }
}
