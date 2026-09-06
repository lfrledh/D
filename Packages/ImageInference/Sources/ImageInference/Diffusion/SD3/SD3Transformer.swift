import MLX
import MLXNN

public class SD3Transformer2DModel: Module {
    let config: SD3Config
    let posEmbed: SD3PatchEmbed
    let timeTextEmbed: CombinedTimestepTextProjEmbeddings
    let contextEmbedder: Linear
    let transformerBlocks: [JointTransformerBlock]
    let normOut: AdaLayerNormContinuous
    let projOut: Linear

    public init(config: SD3Config) {
        self.config = config
        self.posEmbed = SD3PatchEmbed(
            height: config.sampleSize,
            width: config.sampleSize,
            patchSize: config.patchSize,
            inChannels: config.inChannels,
            embedDim: config.numAttentionHeads * config.attentionHeadDim,
            posEmbedMaxSize: config.posEmbedMaxSize
        )
        self.timeTextEmbed = CombinedTimestepTextProjEmbeddings(
            embeddingDim: config.numAttentionHeads * config.attentionHeadDim,
            pooledProjectionDim: config.pooledProjectionDim
        )
        self.contextEmbedder = Linear(config.jointAttentionDim, config.captionProjectionDim)

        var blocks: [JointTransformerBlock] = []
        for i in 0..<config.numLayers {
            let useDual = config.dualAttentionLayers.contains(i)
            // 对于 SD3.5，需要根据 dualAttentionLayers 决定是否使用双流注意力（目前 JointTransformerBlock 已支持）
            let block = JointTransformerBlock(
                dim: config.numAttentionHeads * config.attentionHeadDim,
                numHeads: config.numAttentionHeads,
                headDim: config.attentionHeadDim,
                contextPreOnly: (i == config.numLayers - 1), // 最后一层 context_pre_only
                qkNorm: config.qkNorm
            )
            blocks.append(block)
        }
        self.transformerBlocks = blocks

        self.normOut = AdaLayerNormContinuous(
            embeddingDim: config.numAttentionHeads * config.attentionHeadDim,
            conditioningDim: config.numAttentionHeads * config.attentionHeadDim
        )
        self.projOut = Linear(
            config.numAttentionHeads * config.attentionHeadDim,
            config.patchSize * config.patchSize * config.outChannels
        )
        super.init()
    }

    public func callAsFunction(
        hiddenStates: MLXArray,
        encoderHiddenStates: MLXArray,
        pooledProjections: MLXArray,
        timestep: MLXArray
    ) -> MLXArray {
        var hs = hiddenStates  // 预期形状 [batch, height, width, channels]
        let (batch, height, width, _) = (hs.shape[0], hs.shape[1], hs.shape[2], hs.shape[3])

        // Patch embedding + positional
        hs = posEmbed(hs)  // [batch, numPatches, dim]

        // 时间步 + 文本嵌入
        let temb = timeTextEmbed(timestep, pooledProjections)  // [batch, dim]

        // 处理 encoder hidden states
        var enc = contextEmbedder(encoderHiddenStates)  // [batch, seqLen, captionProjectionDim]

        // 通过 transformer 块
        for block in transformerBlocks {
            let (hsOut, encOut) = block(hs, enc, temb: temb)
            hs = hsOut
            if let encOut = encOut {
                enc = encOut
            } else {
                // 如果 encoder 被丢弃（最后一层），则 enc 不再使用
            }
        }

        // 输出归一化和投影
        hs = normOut(hs, temb)  // AdaLayerNormContinuous
        hs = projOut(hs)

        // 解 patchify
        let patchSize = config.patchSize
        let numPatchesH = height / patchSize
        let numPatchesW = width / patchSize
        // hs 形状 [batch, numPatchesH * numPatchesW, outChannels * patchSize * patchSize]
        hs = hs.reshaped(batch, numPatchesH, numPatchesW, config.outChannels, patchSize, patchSize)
        // 转置以重组为图像
        // 需要 [batch, outChannels, height, width]
        hs = hs.transposed(0, 3, 1, 4, 2, 5)  // [batch, outChannels, numPatchesH, patchSize, numPatchesW, patchSize]
        hs = hs.reshaped(batch, config.outChannels, height, width)
        return hs
    }
}
