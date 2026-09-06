// File: Packages/ImageInference/Sources/ImageInference/Diffusion/VAE/Upsample2D.swift

import MLX
import MLXNN
import Core

// 临时辅助函数：最近邻上采样
func upscaleNearest(_ x: MLXArray, scale: Int) -> MLXArray {
    let shape = x.shape
    let batch = shape[0]
    let channels = shape[1]
    let h = shape[2]
    let w = shape[3]

    // 在高度和宽度维度后各插入一个维度，然后平铺实现上采样
    let expanded = x.expandedDimensions(axes: [2, 4]) // [B, C, H, 1, W, 1]
    let repeated = tiled(expanded, repetitions: [1, 1, 1, scale, 1, scale])
    return repeated.reshaped([batch, channels, h * scale, w * scale])
}

public class Upsample2D: Module {
    let conv: Conv2d

    public init(channels: Int, outChannels: Int? = nil, padding: Int = 1) {
        let outCh = outChannels ?? channels
        // 修正 Conv2d 初始化：添加参数标签
        self.conv = Conv2d(
            inputChannels: channels,
            outputChannels: outCh,
            kernelSize: 3,
            stride: 1,
            padding: IntOrPair(padding) // 将 Int 转为 IntOrPair
        )
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let scale = 2
        let upsampled = upscaleNearest(x, scale: scale)
        return conv(upsampled)
    }
}

// 遵循 UnaryLayer 协议，使它可以被放入 [any UnaryLayer] 数组并调用
extension Upsample2D: UnaryLayer {}
