// File: Packages/ImageInference/Sources/ImageInference/Diffusion/VAE/DiagonalGaussianDistribution.swift

import MLX
import MLXNN
import Core

public struct DiagonalGaussianDistribution {
    public let parameters: MLXArray  // shape [batch, channels*2, height, width]

    public var mean: MLXArray {
        let half = parameters.shape[1] / 2
        return parameters[0..., 0..<half, 0..., 0...]
    }

    public var logvar: MLXArray {
        let half = parameters.shape[1] / 2
        return parameters[0..., half..<parameters.shape[1], 0..., 0...]
    }

    public init(parameters: MLXArray) {
        self.parameters = parameters
    }

    /// 从分布中采样（用于训练）
    public func sample() -> MLXArray {
        let mean = self.mean
        let logvar = self.logvar
        let std = exp(0.5 * logvar)
        let noise = MLXRandom.normal(mean.shape)
        return mean + std * noise
    }

    /// 返回均值（用于确定性解码）
    public func mode() -> MLXArray {
        return mean
    }
}
