import MLX
import MLXNN

/// AdaLayerNormZero: 产生 6 个调制参数
class AdaLayerNormZero: Module {
    let norm: LayerNorm
    let linear: Linear
    let silu: SiLU

    public init(embeddingDim: Int, normDim: Int? = nil) {
        let dim = normDim ?? embeddingDim
        self.norm = LayerNorm(dimensions: dim, eps: 1e-6, affine: false)
        self.linear = Linear(embeddingDim, 6 * dim)
        self.silu = SiLU()
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, emb: MLXArray) -> (MLXArray, MLXArray, MLXArray, MLXArray, MLXArray) {
        // emb: [batch, embeddingDim]
        let emb = linear(silu(emb))  // [batch, 6*dim]
        // 拆分为 6 份
        let chunks = emb.split(parts: 6, axis: -1)
        let shiftMSA = chunks[0].expandedDimensions(axis: 1)
        let scaleMSA = chunks[1].expandedDimensions(axis: 1)
        let gateMSA = chunks[2].expandedDimensions(axis: 1)
        let shiftMLP = chunks[3].expandedDimensions(axis: 1)
        let scaleMLP = chunks[4].expandedDimensions(axis: 1)
        let gateMLP = chunks[5].expandedDimensions(axis: 1)

        let xNorm = norm(x)
        let out = xNorm * (1 + scaleMSA) + shiftMSA
        return (out, gateMSA, shiftMLP, scaleMLP, gateMLP)
    }
}

/// AdaLayerNormContinuous: 用于 context 的连续自适应归一化（无 gate）
class AdaLayerNormContinuous: Module {
    let norm: LayerNorm
    let linear: Linear
    let silu: SiLU

    public init(embeddingDim: Int, conditioningDim: Int, normDim: Int? = nil) {
        let dim = normDim ?? embeddingDim
        self.norm = LayerNorm(dimensions: dim, eps: 1e-6, affine: false)
        self.linear = Linear(conditioningDim, 2 * dim)
        self.silu = SiLU()
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, _ conditioning: MLXArray) -> MLXArray {
        let emb = linear(silu(conditioning))  // [batch, 2*dim]
        let chunks = emb.split(parts: 2, axis: -1)
        let scale = chunks[0]
        let shift = chunks[1]
        let xNorm = norm(x)
        return xNorm * (1 + scale.expandedDimensions(axis: 1)) + shift.expandedDimensions(axis: 1)
    }
}
