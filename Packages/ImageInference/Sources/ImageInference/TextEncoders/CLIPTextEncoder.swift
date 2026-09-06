import MLX
import MLXNN
import Darwin

// MARK: - CLIP Embeddings
class CLIPEmbeddings: Module {
    let tokenEmbedding: Embedding
    let positionEmbedding: Embedding
    let positionIds: MLXArray

    public init(config: CLIPConfig) {
        self.tokenEmbedding = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        self.positionEmbedding = Embedding(embeddingCount: config.maxPositionEmbeddings, dimensions: config.hiddenSize)
        self.positionIds = MLXArray(0..<config.maxPositionEmbeddings).reshaped(1, -1)
        super.init()
    }

    public func callAsFunction(_ inputIds: MLXArray) -> MLXArray {
        let tokenEmbeds = tokenEmbedding(inputIds)
        let seqLen = inputIds.shape[1]
        let posIds = positionIds[0..<1, 0..<seqLen]  // [1, seqLen]
        let posEmbeds = positionEmbedding(posIds)
        return tokenEmbeds + posEmbeds
    }
}

// MARK: - CLIP Attention
class CLIPAttention: Module {
    let embedDim: Int
    let numHeads: Int
    let headDim: Int
    let scale: Float

    let qProj: Linear
    let kProj: Linear
    let vProj: Linear
    let outProj: Linear
    let dropout: Dropout

    public init(config: CLIPConfig) {
        self.embedDim = config.hiddenSize
        self.numHeads = config.numAttentionHeads
        self.headDim = embedDim / numHeads
        self.scale = 1.0 / Darwin.sqrt(Float(headDim))

        self.qProj = Linear(embedDim, embedDim, bias: true)
        self.kProj = Linear(embedDim, embedDim, bias: true)
        self.vProj = Linear(embedDim, embedDim, bias: true)
        self.outProj = Linear(embedDim, embedDim, bias: true)
        self.dropout = Dropout(p: config.attentionDropout)
        super.init()
    }

    public func callAsFunction(_ hiddenStates: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        let batch = hiddenStates.shape[0]
        let seqLen = hiddenStates.shape[1]

        var q = qProj(hiddenStates)
        var k = kProj(hiddenStates)
        var v = vProj(hiddenStates)

        q = q.reshaped(batch, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        k = k.reshaped(batch, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        v = v.reshaped(batch, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)

        var scores = matmul(q, k.transposed(0, 1, 3, 2)) * scale

        if let mask = attentionMask {
            scores = scores + mask
        }

        let attnProbs = softmax(scores, axis: -1)
        let attnProbsDropped = dropout(attnProbs)

        var out = matmul(attnProbsDropped, v)
        out = out.transposed(0, 2, 1, 3).reshaped(batch, seqLen, -1)
        out = outProj(out)
        return out
    }
}

// MARK: - CLIP MLP
class CLIPMLP: Module {
    let fc1: Linear
    let fc2: Linear
    let activation: GELU

    public init(config: CLIPConfig) {
        self.fc1 = Linear(config.hiddenSize, config.intermediateSize, bias: true)
        self.fc2 = Linear(config.intermediateSize, config.hiddenSize, bias: true)
        self.activation = GELU()
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = fc1(x)
        h = activation(h)
        h = fc2(h)
        return h
    }
}

// MARK: - CLIP Encoder Layer
class CLIPEncoderLayer: Module {
    let selfAttn: CLIPAttention
    let layerNorm1: LayerNorm
    let mlp: CLIPMLP
    let layerNorm2: LayerNorm

    public init(config: CLIPConfig) {
        self.selfAttn = CLIPAttention(config: config)
        self.layerNorm1 = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps)
        self.mlp = CLIPMLP(config: config)
        self.layerNorm2 = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        var residual = x
        var h = layerNorm1(x)
        h = selfAttn(h, attentionMask: attentionMask)
        h = residual + h

        residual = h
        h = layerNorm2(h)
        h = mlp(h)
        h = residual + h
        return h
    }
}

// MARK: - CLIP Encoder
class CLIPEncoder: Module {
    let layers: [CLIPEncoderLayer]

    public init(config: CLIPConfig) {
        self.layers = (0..<config.numHiddenLayers).map { _ in CLIPEncoderLayer(config: config) }
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        var h = x
        for layer in layers {
            h = layer(h, attentionMask: attentionMask)
        }
        return h
    }
}

// MARK: - CLIP Text Encoder (with projection)
public class CLIPTextEncoder: Module {
    let config: CLIPConfig
    let embeddings: CLIPEmbeddings
    let encoder: CLIPEncoder
    let finalLayerNorm: LayerNorm
    let textProjection: Linear?

    public init(config: CLIPConfig) {
        self.config = config
        self.embeddings = CLIPEmbeddings(config: config)
        self.encoder = CLIPEncoder(config: config)
        self.finalLayerNorm = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps, affine: true)
        if let projDim = config.projectionDim {
            self.textProjection = Linear(config.hiddenSize, projDim, bias: false)
        } else {
            self.textProjection = nil
        }
        super.init()
    }

    public func callAsFunction(_ inputIds: MLXArray, attentionMask: MLXArray? = nil) -> (lastHiddenState: MLXArray, textEmbeds: MLXArray?) {
        var hiddenStates = embeddings(inputIds)

        let seqLen = inputIds.shape[1]
        // 修正 full 调用
        var causalMask = MLXArray.full([seqLen, seqLen], values: MLXArray(-Float.infinity), dtype: .float32)
        for i in 0..<seqLen {
            for j in 0...i {
                causalMask[i, j] = MLXArray(0.0)
            }
        }
        let extendedMask = causalMask.reshaped(1, 1, seqLen, seqLen)

        var finalMask = extendedMask
        if let padMask = attentionMask {
            let padMaskExpanded = padMask.reshaped(-1, 1, 1, seqLen)
            // 使用 which 替代 where，并传入 MLXArray
            let padMaskFloat = which(padMaskExpanded .== 0, MLXArray(-Float.infinity), MLXArray(0.0))
            finalMask = finalMask + padMaskFloat
        }

        hiddenStates = encoder(hiddenStates, attentionMask: finalMask)
        hiddenStates = finalLayerNorm(hiddenStates)

        let eosPositions = (inputIds .== config.eosTokenId).argMax(axis: -1)
        let pooled = hiddenStates[0..<hiddenStates.shape[0], eosPositions.asType(.int32)]

        if let proj = textProjection {
            let textEmbeds = proj(pooled)
            return (hiddenStates, textEmbeds)
        } else {
            return (hiddenStates, pooled)
        }
    }
}
