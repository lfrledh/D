// File: Packages/ImageInference/Sources/ImageInference/StableDiffusionService.swift

import Foundation
import Core
import MLX
import StableDiffusion
import Hub
import AppKit  // 新增：用于 NSBitmapImageRep

/// 错误类型
enum ImageGenerationError: LocalizedError {
    case unsupportedModel
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            return "The model is not supported by the built-in Stable Diffusion library. Supported models: stabilityai/sdxl-turbo, stabilityai/stable-diffusion-2-1-base"
        case .generationFailed(let reason):
            return "Image generation failed: \(reason)"
        }
    }
}

/// 使用 mlx-swift-examples 的 StableDiffusion 实现图像生成
public actor StableDiffusionService: ImageGenerationService {
    private let modelID: String
    private let float16: Bool
    private let quantize: Bool
    private var container: ModelContainer<TextToImageGenerator>?

    /// 初始化
    /// - Parameters:
    ///   - modelID: Hugging Face 模型 ID，例如 "stabilityai/sdxl-turbo"
    ///   - float16: 是否使用 float16 精度（默认 true）
    ///   - quantize: 是否量化模型（默认 false）
    public init(modelID: String, float16: Bool = true, quantize: Bool = false) {
        self.modelID = modelID
        self.float16 = float16
        self.quantize = quantize
    }

    /// 创建 LoadConfiguration（内部使用）
    private var loadConfig: LoadConfiguration {
        LoadConfiguration(float16: float16, quantize: quantize)
    }

    /// 确保模型已加载（懒加载）
    private func ensureLoaded() async throws {
        if container != nil { return }

        // 将模型 ID 映射到预设（目前仅支持两个官方模型）
        let preset: StableDiffusionConfiguration.Preset
        switch modelID {
        case "stabilityai/sdxl-turbo":
            preset = .sdxlTurbo
        case "stabilityai/stable-diffusion-2-1-base":
            preset = .base
        default:
            throw ImageGenerationError.unsupportedModel
        }

        let configuration = preset.configuration
        let hub = HubApi()

        // 下载或确认本地缓存（如果已存在则跳过下载）
        try await configuration.download(hub: hub)

        // 创建生成器容器
        let container = try ModelContainer<TextToImageGenerator>.createTextToImageGenerator(
            configuration: configuration,
            loadConfiguration: loadConfig
        )

        self.container = container
    }

    nonisolated public func generate(prompt: String, parameters: ImageGenerationParameters) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                await self.performGeneration(prompt: prompt, parameters: parameters, continuation: continuation)
            }
        }
    }

    private func performGeneration(prompt: String, parameters: ImageGenerationParameters, continuation: AsyncStream<Data>.Continuation) async {
        do {
            try await ensureLoaded()

            guard let container else {
                continuation.finish()
                return
            }

            // 转换参数：注意 latentSize 是 [height/8, width/8]
            let latentSize = [parameters.height / 8, parameters.width / 8]
            let evalParams = EvaluateParameters(
                cfgWeight: parameters.guidanceScale,
                steps: parameters.steps,
                imageCount: 1,
                decodingBatchSize: 1,
                latentSize: latentSize,
                seed: parameters.seed,
                prompt: prompt,
                negativePrompt: ""  // 可扩展，暂不支持
            )

            // 使用 performTwoStage 分阶段执行，以支持 conserveMemory 模式
            // 显式标注闭包返回类型和参数类型，帮助编译器推断
            try await container.performTwoStage(
                first: { (generator: TextToImageGenerator) -> (DenoiseIterator, ImageDecoder) in
                    let latents = generator.generateLatents(parameters: evalParams)
                    let decoder = generator.detachedDecoder()
                    return (latents, decoder)
                },
                second: { (tuple: (DenoiseIterator, ImageDecoder)) in
                    let (latents, decoder) = tuple
                    var lastXt: MLXArray?
                    for xt in latents {
                        eval(xt)
                        lastXt = xt
                    }

                    guard let finalXt = lastXt else {
                        throw ImageGenerationError.generationFailed("No latents generated")
                    }

                    // 解码第一个图像
                    var imageArray = decoder(finalXt[0])
                    // 后处理：从 [-1,1] 到 [0,1] 并裁剪
                    imageArray = MLX.clip(imageArray / 2 + 0.5, min: 0, max: 1)
                    // 转换为 uint8
                    imageArray = (imageArray * 255).asType(.uint8)

                    // 使用 StableDiffusion 的 Image 类型转换为 CGImage
                    let sdImage = Image(imageArray)
                    let cgImageOptional: CGImage? = sdImage.asCGImage()
                    guard let cgImage = cgImageOptional else {
                        throw ImageGenerationError.generationFailed("Failed to create CGImage")
                    }

                    // 转换为 PNG Data
                    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                        throw ImageGenerationError.generationFailed("Failed to encode PNG")
                    }

                    continuation.yield(pngData)
                    continuation.finish()
                }
            )
        } catch {
            continuation.finish()
        }
    }
}
