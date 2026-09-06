import MLX
import MLXNN

public class VAEDecoder: Module, UnaryLayer {
    let convIn: Conv2d
    let midBlock: any UnaryLayer
    let upBlocks: [any UnaryLayer]
    let normOut: GroupNorm
    let convOut: Conv2d

    public init(config: VAEConfig) {
        let latentChannels = config.latentChannels
        let blockOuts = config.blockOutChannels
        let layersPerBlock = config.layersPerBlock
        let normNumGroups = config.normNumGroups
        let actFn = config.actFn
        let midAddAttention = config.midBlockAddAttention

        self.convIn = Conv2d(
            inputChannels: latentChannels,
            outputChannels: blockOuts.last!,
            kernelSize: 3,
            stride: 1,
            padding: IntOrPair(1)
        )

        let midResBlock = ResnetBlock2D(
            inChannels: blockOuts.last!,
            outChannels: blockOuts.last!,
            groups: normNumGroups,
            nonLinearity: actFn
        )
        if midAddAttention {
            let attnBlock = AttentionBlock(dim: blockOuts.last!, groups: normNumGroups)
            // 内部类 MidBlock 继承 Module 并遵循 UnaryLayer
            class MidBlock: Module, UnaryLayer {
                let res1: ResnetBlock2D
                let attn: AttentionBlock
                let res2: ResnetBlock2D
                init(res1: ResnetBlock2D, attn: AttentionBlock, res2: ResnetBlock2D) {
                    self.res1 = res1
                    self.attn = attn
                    self.res2 = res2
                    super.init()
                }
                func callAsFunction(_ x: MLXArray) -> MLXArray {
                    var h = res1(x)
                    h = attn(h)
                    h = res2(h)
                    return h
                }
            }
            self.midBlock = MidBlock(res1: midResBlock, attn: attnBlock, res2: midResBlock)
        } else {
            self.midBlock = midResBlock
        }

        var blocks: [any UnaryLayer] = []
        var inputChannels = blockOuts.last!
        for i in 0..<blockOuts.count {
            let outputChannels = blockOuts[blockOuts.count - 1 - i]
            for _ in 0..<layersPerBlock {
                let resBlock = ResnetBlock2D(
                    inChannels: inputChannels,
                    outChannels: outputChannels,
                    groups: normNumGroups,
                    nonLinearity: actFn
                )
                blocks.append(resBlock)
                inputChannels = outputChannels
            }
            if i != blockOuts.count - 1 {
                blocks.append(Upsample2D(channels: outputChannels))
            }
        }
        self.upBlocks = blocks

        self.normOut = GroupNorm(
            groupCount: normNumGroups,
            dimensions: inputChannels,
            eps: 1e-6,
            affine: true
        )
        self.convOut = Conv2d(
            inputChannels: inputChannels,
            outputChannels: config.outChannels,
            kernelSize: 3,
            stride: 1,
            padding: IntOrPair(1)
        )

        super.init()
    }

    public func callAsFunction(_ z: MLXArray) -> MLXArray {
        var h = convIn(z)
        h = midBlock(h)
        for block in upBlocks {
            h = block(h)
        }
        h = swish(normOut(h))
        h = convOut(h)
        return h
    }
}
