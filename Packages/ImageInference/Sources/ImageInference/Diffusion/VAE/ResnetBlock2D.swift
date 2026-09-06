// File: Packages/ImageInference/Sources/ImageInference/Diffusion/VAE/ResnetBlock2D.swift

import MLX
import MLXNN

/// 2D ResNet block used in VAE encoder/decoder.
/// Based on diffusers' `ResnetBlock2D`.
public class ResnetBlock2D: Module, UnaryLayer {
    let norm1: GroupNorm
    let conv1: Conv2d
    let norm2: GroupNorm
    let conv2: Conv2d
    let dropout: Dropout
    let nonlinearity: (MLXArray) -> MLXArray
    let convShortcut: Conv2d?

    public init(
        inChannels: Int,
        outChannels: Int? = nil,
        dropout: Float = 0.0,
        groups: Int = 32,
        eps: Float = 1e-6,
        nonLinearity: String = "swish"
    ) {
        let outCh = outChannels ?? inChannels

        // 修正 GroupNorm 调用：使用 groupCount 参数
        self.norm1 = GroupNorm(
            groupCount: groups,
            dimensions: inChannels,
            eps: eps,
            affine: true
        )
        self.conv1 = Conv2d(
            inputChannels: inChannels,
            outputChannels: outCh,
            kernelSize: 3,
            stride: 1,
            padding: 1
        )

        self.norm2 = GroupNorm(
            groupCount: groups,
            dimensions: outCh,
            eps: eps,
            affine: true
        )
        self.dropout = Dropout(p: dropout)  // 添加 p: 标签
        self.conv2 = Conv2d(
            inputChannels: outCh,
            outputChannels: outCh,
            kernelSize: 3,
            stride: 1,
            padding: 1
        )

        // 简化激活函数处理，目前仅支持 swish
        if nonLinearity == "swish" {
            self.nonlinearity = swish
        } else {
            // 默认使用 swish
            self.nonlinearity = swish
        }

        if inChannels != outCh {
            self.convShortcut = Conv2d(
                inputChannels: inChannels,
                outputChannels: outCh,
                kernelSize: 1
            )
        } else {
            self.convShortcut = nil
        }

        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x

        h = norm1(h)
        h = nonlinearity(h)
        h = conv1(h)

        h = norm2(h)
        h = nonlinearity(h)
        h = dropout(h)
        h = conv2(h)

        var shortcut = x
        if let convShortcut = convShortcut {
            shortcut = convShortcut(shortcut)
        }

        return shortcut + h
    }
}
