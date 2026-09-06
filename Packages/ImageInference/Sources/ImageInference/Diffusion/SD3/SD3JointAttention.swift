import MLX
import MLXNN
import Darwin

class JointAttention: Module {
    let toQ: Linear
    let toK: Linear
    let toV: Linear
    let addQProj: Linear?   // 用于 encoder_hidden_states 的 query
    let addKProj: Linear
    let addVProj: Linear
    let toOut: Linear
    let numHeads: Int
    let headDim: Int
    let scale: Float
    let contextPreOnly: Bool
    let normQ: RMSNorm?
    let normK: RMSNorm?
    let normAddQ: RMSNorm?
    let normAddK: RMSNorm?

    public init(
        dim: Int,
        numHeads: Int,
        headDim: Int,
        contextPreOnly: Bool = false,
        qkNorm: String? = nil,
        eps: Float = 1e-6
    ) {
        self.numHeads = numHeads
        self.headDim = headDim
        let innerDim = numHeads * headDim
        self.toQ = Linear(dim, innerDim)
        self.toK = Linear(dim, innerDim)
        self.toV = Linear(dim, innerDim)
        self.addKProj = Linear(dim, innerDim)
        self.addVProj = Linear(dim, innerDim)
        if !contextPreOnly {
            self.addQProj = Linear(dim, innerDim)
        } else {
            self.addQProj = nil
        }
        self.toOut = Linear(innerDim, dim)
        self.scale = 1.0 / Darwin.sqrt(Float(headDim))
        self.contextPreOnly = contextPreOnly

        // QK Norm
        if let norm = qkNorm, norm == "rms_norm" {
            self.normQ = RMSNorm(dimensions: headDim, eps: eps)
            self.normK = RMSNorm(dimensions: headDim, eps: eps)
            self.normAddQ = RMSNorm(dimensions: headDim, eps: eps)
            self.normAddK = RMSNorm(dimensions: headDim, eps: eps)
        } else {
            self.normQ = nil
            self.normK = nil
            self.normAddQ = nil
            self.normAddK = nil
        }

        super.init()
    }

    public func callAsFunction(
        _ hiddenStates: MLXArray,
        _ encoderHiddenStates: MLXArray?,
        attentionMask: MLXArray? = nil
    ) -> (MLXArray, MLXArray?) {
        let batch = hiddenStates.shape[0]
        let seqLen = hiddenStates.shape[1]
        let contextSeqLen = encoderHiddenStates?.shape[1] ?? 0

        // 投影 hidden_states
        var q = toQ(hiddenStates)
        var k = toK(hiddenStates)
        var v = toV(hiddenStates)

        // 投影 encoder_hidden_states
        var addQ: MLXArray? = nil
        var addK: MLXArray? = nil
        var addV: MLXArray? = nil
        if let enc = encoderHiddenStates {
            if let addQProj = addQProj {
                addQ = addQProj(enc)
            }
            addK = addKProj(enc)
            addV = addVProj(enc)
        }

        // 重塑为多头
        func reshapeForHeads(_ x: MLXArray) -> MLXArray {
            x.reshaped(batch, -1, numHeads, headDim).transposed(0, 2, 1, 3)
        }
        q = reshapeForHeads(q)
        k = reshapeForHeads(k)
        v = reshapeForHeads(v)

        if let addQOrig = addQ {
            addQ = reshapeForHeads(addQOrig)
        }
        if let addKOrig = addK {
            addK = reshapeForHeads(addKOrig)
        }
        if let addVOrig = addV {
            addV = reshapeForHeads(addVOrig)
        }

        // QK Norm
        if let normQ = normQ {
            q = normQ(q)
        }
        if let normK = normK {
            k = normK(k)
        }
        if let normAddQ = normAddQ, let addQVal = addQ {
            addQ = normAddQ(addQVal)
        }
        if let normAddK = normAddK, let addKVal = addK {
            addK = normAddK(addKVal)
        }

        // 拼接
        if let addQVal = addQ, let addKVal = addK, let addVVal = addV {
            q = concatenated([q, addQVal], axis: 2)
            k = concatenated([k, addKVal], axis: 2)
            v = concatenated([v, addVVal], axis: 2)
        }

        // 计算注意力
        let attn = scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: attentionMask)
        var out = attn.transposed(0, 2, 1, 3).reshaped(batch, -1, numHeads * headDim)

        // 分离输出
        var contextOut: MLXArray? = nil
        if let _ = encoderHiddenStates {
            if contextPreOnly {
                out = toOut(out)
                return (out, nil)
            } else {
                let hiddenPart = out[0..<batch, 0..<seqLen, 0..<innerDim]
                let contextPart = out[0..<batch, seqLen..<seqLen+contextSeqLen, 0..<innerDim]
                hiddenPart.eval()
                contextPart.eval()
                out = toOut(hiddenPart)
                contextOut = toOut(contextPart)
            }
        } else {
            out = toOut(out)
        }

        return (out, contextOut)
    }

    private var innerDim: Int {
        numHeads * headDim
    }
}
