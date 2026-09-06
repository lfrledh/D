// File: Packages/ImageInference/Sources/ImageInference/Diffusion/VAE/AutoencoderKL.swift

import MLX
import MLXNN
import Core

public class AutoencoderKL: Module {
    public let config: VAEConfig

    public let encoder: VAEEncoder
    public let decoder: VAEDecoder
    public let quantConv: Conv2d?
    public let postQuantConv: Conv2d?

    public init(config: VAEConfig) {
        self.config = config
        self.encoder = VAEEncoder(config: config)
        self.decoder = VAEDecoder(config: config)

        if config.useQuantConv {
            self.quantConv = Conv2d(
                inputChannels: config.latentChannels * 2,
                outputChannels: config.latentChannels * 2,
                kernelSize: 1
            )
        } else {
            self.quantConv = nil
        }

        if config.usePostQuantConv {
            self.postQuantConv = Conv2d(
                inputChannels: config.latentChannels,
                outputChannels: config.latentChannels,
                kernelSize: 1
            )
        } else {
            self.postQuantConv = nil
        }

        super.init()
    }

    /// 编码图像为潜在分布
    public func encode(_ x: MLXArray) -> DiagonalGaussianDistribution {
        var h = encoder(x)
        if let quantConv = quantConv {
            h = quantConv(h)
        }
        return DiagonalGaussianDistribution(parameters: h)
    }

    /// 从潜在 z 解码为图像
    public func decode(_ z: MLXArray) -> MLXArray {
        var h = z
        if let postQuantConv = postQuantConv {
            h = postQuantConv(h)
        }
        return decoder(h)
    }

    /// 前向：编码 → 采样/取模 → 解码
    public func callAsFunction(_ x: MLXArray, samplePosterior: Bool = false) -> MLXArray {
        let posterior = encode(x)
        let z = samplePosterior ? posterior.sample() : posterior.mode()
        return decode(z)
    }
}
