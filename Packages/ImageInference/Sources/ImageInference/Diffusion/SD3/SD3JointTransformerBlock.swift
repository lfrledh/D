import MLX
import MLXNN

class JointTransformerBlock: Module {
    let norm1: AdaLayerNormZero
    let norm1Context: AdaLayerNormZero   // 对于 context，使用相同的 AdaLayerNormZero，但输出参数不同
    let attn: JointAttention
    let norm2: LayerNorm
    let ff: SD3FeedForward
    let norm2Context: LayerNorm?
    let ffContext: SD3FeedForward?
    let contextPreOnly: Bool

    public init(
        dim: Int,
        numHeads: Int,
        headDim: Int,
        contextPreOnly: Bool = false,
        qkNorm: String? = nil
    ) {
        self.norm1 = AdaLayerNormZero(embeddingDim: dim)
        self.norm1Context = AdaLayerNormZero(embeddingDim: dim)  // 独立参数
        self.attn = JointAttention(
            dim: dim,
            numHeads: numHeads,
            headDim: headDim,
            contextPreOnly: contextPreOnly,
            qkNorm: qkNorm
        )
        self.norm2 = LayerNorm(dimensions: dim, eps: 1e-6, affine: false)
        self.ff = SD3FeedForward(dim: dim, dimOut: dim)

        if !contextPreOnly {
            self.norm2Context = LayerNorm(dimensions: dim, eps: 1e-6, affine: false)
            self.ffContext = SD3FeedForward(dim: dim, dimOut: dim)
        } else {
            self.norm2Context = nil
            self.ffContext = nil
        }
        self.contextPreOnly = contextPreOnly
        super.init()
    }

    public func callAsFunction(
        _ hiddenStates: MLXArray,
        _ encoderHiddenStates: MLXArray,
        temb: MLXArray
    ) -> (MLXArray, MLXArray?) {
        // 1. 归一化 + 调制参数
        let (normHS, gateMSA, shiftMLP, scaleMLP, gateMLP) = norm1(hiddenStates, emb: temb)
        let (normEnc, cGateMSA, cShiftMLP, cScaleMLP, cGateMLP) = norm1Context(encoderHiddenStates, emb: temb)

        // 2. 注意力
        let (attnOut, contextAttnOut) = attn(normHS, normEnc)

        // 3. 应用 gate 并残差连接
        let gatedAttnOut = gateMSA * attnOut
        var hs = hiddenStates + gatedAttnOut

        // 4. 前馈
        var normHS2 = norm2(hs)
        normHS2 = normHS2 * (1 + scaleMLP) + shiftMLP
        let ffOut = ff(normHS2)
        hs = hs + gateMLP * ffOut

        var encOut: MLXArray? = nil
        if !contextPreOnly, let contextAttnOut = contextAttnOut {
            // 处理 encoder 分支
            var enc = encoderHiddenStates + cGateMSA * contextAttnOut
            if let norm2Context = norm2Context, let ffContext = ffContext {
                var normEnc2 = norm2Context(enc)
                normEnc2 = normEnc2 * (1 + cScaleMLP) + cShiftMLP
                let ffEncOut = ffContext(normEnc2)
                enc = enc + cGateMLP * ffEncOut
            }
            encOut = enc
        }

        return (hs, encOut)
    }
}
