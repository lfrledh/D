import MLX
import MLXNN
import Darwin

// MARK: - T5 Layer Norm
class T5LayerNorm: Module {
    let weight: MLXArray
    let eps: Float

    public init(dimensions: Int, eps: Float = 1e-6) {
        self.weight = MLXArray.ones([dimensions])
        self.eps = eps
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let variance = pow(x, 2).mean(axis: -1, keepDims: true)
        let h = x * rsqrt(variance + eps)
        return h * weight
    }
}

// MARK: - T5 Relative Position Bias
class T5RelativePositionBias: Module {
    let numBuckets: Int
    let maxDistance: Int
    let numHeads: Int
    let embedding: Embedding

    public init(numHeads: Int, numBuckets: Int, maxDistance: Int) {
        self.numHeads = numHeads
        self.numBuckets = numBuckets
        self.maxDistance = maxDistance
        self.embedding = Embedding(embeddingCount: numBuckets, dimensions: numHeads)
        super.init()
    }

    public func callAsFunction(queryLength: Int, keyLength: Int) -> MLXArray {
        let contextPos = MLXArray(0..<queryLength).expandedDimensions(axis: 1)
        let memoryPos = MLXArray(0..<keyLength).expandedDimensions(axis: 0)
        let relativePos = memoryPos - contextPos

        let bidirectional = true
        var relativeBuckets = MLXArray.zeros(like: relativePos)

        if bidirectional {
            let halfBuckets = numBuckets / 2
            let positiveMask = relativePos .> 0
            relativeBuckets = relativeBuckets + positiveMask * halfBuckets
            let absPos = abs(relativePos)
            let maxExact = halfBuckets / 2
            let isSmall = absPos .< maxExact
            let logFactor = Darwin.log(Float(maxDistance) / Float(maxExact)) / Float(halfBuckets - maxExact)
            let largePos = maxExact + (MLX.log(absPos.asType(.float32) / Float(maxExact)) * (Float(1.0) / logFactor)).asType(.int32)
            // 使用 minimum 替代 min
            let clippedLarge = minimum(largePos, MLXArray(halfBuckets - 1))
            let bucket = which(isSmall, absPos, clippedLarge)
            relativeBuckets = relativeBuckets + bucket
        }

        let bias = embedding(relativeBuckets)
        return bias.transposed(2, 0, 1).expandedDimensions(axis: 0)
    }
}

// MARK: - T5 Attention
class T5Attention: Module {
    let dModel: Int
    let dKv: Int
    let numHeads: Int
    let headDim: Int

    let q: Linear
    let k: Linear
    let v: Linear
    let o: Linear
    let dropout: Dropout
    let hasRelativeBias: Bool
    var relativeBias: T5RelativePositionBias?

    public init(config: T5Config, hasRelativeBias: Bool = false) {
        self.dModel = config.dModel
        self.dKv = config.dKv
        self.numHeads = config.numHeads
        self.headDim = dKv
        self.hasRelativeBias = hasRelativeBias

        self.q = Linear(dModel, numHeads * dKv, bias: false)
        self.k = Linear(dModel, numHeads * dKv, bias: false)
        self.v = Linear(dModel, numHeads * dKv, bias: false)
        self.o = Linear(numHeads * dKv, dModel, bias: false)
        self.dropout = Dropout(p: config.dropoutRate)

        if hasRelativeBias {
            self.relativeBias = T5RelativePositionBias(
                numHeads: numHeads,
                numBuckets: config.relativeAttentionNumBuckets,
                maxDistance: config.relativeAttentionMaxDistance
            )
        }
        super.init()
    }

    public func callAsFunction(
        _ hiddenStates: MLXArray,
        mask: MLXArray? = nil,
        positionBias: MLXArray? = nil
    ) -> (MLXArray, MLXArray?) {
        let batch = hiddenStates.shape[0]
        let seqLen = hiddenStates.shape[1]

        var q = self.q(hiddenStates)
        var k = self.k(hiddenStates)
        var v = self.v(hiddenStates)

        q = q.reshaped(batch, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        k = k.reshaped(batch, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        v = v.reshaped(batch, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)

        var scores = matmul(q, k.transposed(0, 1, 3, 2)) / Darwin.sqrt(Float(headDim))

        if let pb = positionBias {
            scores = scores + pb
        } else if let relBias = relativeBias {
            let pb = relBias(queryLength: seqLen, keyLength: seqLen)
            scores = scores + pb
        }

        if let m = mask {
            scores = scores + m
        }

        let probs = softmax(scores, axis: -1)
        let probsDropped = dropout(probs)

        var out = matmul(probsDropped, v)
        out = out.transposed(0, 2, 1, 3).reshaped(batch, seqLen, -1)
        out = o(out)

        return (out, scores)
    }
}

// MARK: - T5 Dense Gated
class T5DenseGatedAct: Module {
    let wi0: Linear
    let wi1: Linear
    let wo: Linear
    let activation: GELU

    public init(config: T5Config) {
        self.wi0 = Linear(config.dModel, config.dFf, bias: false)
        self.wi1 = Linear(config.dModel, config.dFf, bias: false)
        self.wo = Linear(config.dFf, config.dModel, bias: false)
        self.activation = GELU()
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let hiddenGelu = activation(wi0(x))
        let hiddenLinear = wi1(x)
        var h = hiddenGelu * hiddenLinear
        h = wo(h)
        return h
    }
}

class T5LayerFF: Module {
    let dense: T5DenseGatedAct
    let layerNorm: T5LayerNorm
    let dropout: Dropout

    public init(config: T5Config) {
        self.dense = T5DenseGatedAct(config: config)
        self.layerNorm = T5LayerNorm(dimensions: config.dModel, eps: config.layerNormEps)
        self.dropout = Dropout(p: config.dropoutRate)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = layerNorm(x)
        h = dense(h)
        h = dropout(h)
        return x + h
    }
}

// MARK: - T5 Block
class T5Block: Module {
    let layerNorm: T5LayerNorm
    let attention: T5Attention
    let ff: T5LayerFF

    public init(config: T5Config, hasRelativeBias: Bool) {
        self.layerNorm = T5LayerNorm(dimensions: config.dModel, eps: config.layerNormEps)
        self.attention = T5Attention(config: config, hasRelativeBias: hasRelativeBias)
        self.ff = T5LayerFF(config: config)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil, positionBias: MLXArray? = nil) -> (MLXArray, MLXArray?) {
        var h = layerNorm(x)
        let (attnOut, pb) = attention(h, mask: mask, positionBias: positionBias)
        h = x + attnOut
        h = ff(h)
        return (h, pb)
    }
}

// MARK: - T5 Encoder
public class T5Encoder: Module {
    let config: T5Config
    let embedTokens: Embedding
    let blocks: [T5Block]
    let finalLayerNorm: T5LayerNorm

    public init(config: T5Config) {
        self.config = config
        self.embedTokens = Embedding(embeddingCount: config.vocabSize, dimensions: config.dModel)
        self.blocks = (0..<config.numLayers).map { i in
            T5Block(config: config, hasRelativeBias: i == 0)
        }
        self.finalLayerNorm = T5LayerNorm(dimensions: config.dModel, eps: config.layerNormEps)
        super.init()
    }

    public func callAsFunction(_ inputIds: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        let batch = inputIds.shape[0]
        let seqLen = inputIds.shape[1]

        var hiddenStates = embedTokens(inputIds)

        var extendedMask: MLXArray? = nil
        if let padMask = attentionMask {
            extendedMask = padMask.reshaped(batch, 1, 1, seqLen)
            // 使用 which 替代 where，并传入 MLXArray
            extendedMask = which(extendedMask! .== 1, MLXArray(0.0), MLXArray(-Float.infinity))
        }

        var positionBias: MLXArray? = nil
        for block in blocks {
            let (out, pb) = block(hiddenStates, mask: extendedMask, positionBias: positionBias)
            hiddenStates = out
            if positionBias == nil {
                positionBias = pb
            }
        }

        hiddenStates = finalLayerNorm(hiddenStates)
        return hiddenStates
    }
}
