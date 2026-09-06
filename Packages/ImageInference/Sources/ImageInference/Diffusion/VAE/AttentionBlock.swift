import MLX
import MLXNN
import Darwin

/// 简化的自注意力模块，用于 VAE 的中间块
public class AttentionBlock: Module, UnaryLayer {
    let norm: GroupNorm
    let toQ: Conv2d
    let toK: Conv2d
    let toV: Conv2d
    let toOut: Conv2d
    let numHeads: Int
    let headDim: Int

    public init(dim: Int, numHeads: Int = 8, groups: Int = 32, eps: Float = 1e-6) {
        self.numHeads = numHeads
        self.headDim = dim / numHeads
        precondition(headDim * numHeads == dim, "dim must be divisible by numHeads")

        // 修正 GroupNorm 初始化
        self.norm = GroupNorm(groupCount: groups, dimensions: dim, eps: eps, affine: true)

        // 修正 Conv2d 初始化，添加参数标签
        self.toQ = Conv2d(inputChannels: dim, outputChannels: dim, kernelSize: 1)
        self.toK = Conv2d(inputChannels: dim, outputChannels: dim, kernelSize: 1)
        self.toV = Conv2d(inputChannels: dim, outputChannels: dim, kernelSize: 1)
        self.toOut = Conv2d(inputChannels: dim, outputChannels: dim, kernelSize: 1)

        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (batch, channels, height, width) = (x.shape[0], x.shape[1], x.shape[2], x.shape[3])

        var h = norm(x)

        let q = toQ(h)
        let k = toK(h)
        let v = toV(h)

        // 重塑为多头形式
        func reshape(_ tensor: MLXArray) -> MLXArray {
            // 输入形状 [batch, channels, height, width]
            // 输出形状 [batch, numHeads, height * width, headDim]
            return tensor.reshaped(batch, numHeads, headDim, height * width)
                .transposed(0, 1, 3, 2) // 变为 [batch, numHeads, seqLen, headDim]
        }

        let qFlat = reshape(q)
        let kFlat = reshape(k)
        let vFlat = reshape(v)

        // 缩放因子转为 MLXArray
        let scale = MLXArray(1.0 / Darwin.sqrt(Float(headDim)), dtype: .float32)

        // 注意力分数
        var scores = matmul(qFlat, kFlat.transposed(0, 1, 3, 2)) * scale
        let attn = softmax(scores, axis: -1)

        // 加权求和
        let out = matmul(attn, vFlat) // [batch, numHeads, seqLen, headDim]

        // 恢复形状
        let outReshaped = out.transposed(0, 1, 3, 2) // [batch, numHeads, headDim, seqLen]
            .reshaped(batch, channels, height, width)

        // 残差连接 + 输出投影
        return x + toOut(outReshaped)
    }
}
