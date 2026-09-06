// File: Packages/ImageInference/Sources/ImageInference/Diffusion/SD3/SD3Service.swift

import Foundation
import Core
import MLX
import MLXNN
import Hub
import ModelLoading
import StableDiffusion


public actor SD3Service: ImageGenerationService {
    private let modelID: String
    private let loadConfig: LoadConfiguration
    private let hub: HubApi
    private var transformer: SD3Transformer2DModel?
    // 后续需要时再添加 VAE 和文本编码器

    public init(modelID: String, loadConfig: LoadConfiguration = LoadConfiguration(float16: true, quantize: false)) {
        self.modelID = modelID
        self.loadConfig = loadConfig
        self.hub = HubApi()
    }

    private func ensureLoaded() async throws {
        if transformer != nil { return }

        let repo = Hub.Repo(id: modelID)
        try await hub.snapshot(from: repo) { _ in }

        let localDir = hub.localRepoLocation(repo)

        let configURL = localDir.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let sd3Config = try JSONDecoder().decode(SD3Config.self, from: configData)

        let transformer = SD3Transformer2DModel(config: sd3Config)

        let weightsURL = localDir.appendingPathComponent("diffusion_pytorch_model.safetensors")
        let weights = try SafetensorsLoader.loadArrays(from: weightsURL)
        var mappedWeights: [(String, MLXArray)] = []
        for (key, value) in weights {
            mappedWeights.append(contentsOf: mapSD3Weight(key: key, value: value.asType(loadConfig.dType)))
        }
        try transformer.update(parameters: ModuleParameters.unflattened(mappedWeights), verify: .none)

        self.transformer = transformer
    }

    nonisolated public func generate(prompt: String, parameters: ImageGenerationParameters) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                await self.performGeneration(prompt: prompt, parameters: parameters, continuation: continuation)
            }
        }
    }

    private func performGeneration(prompt: String, parameters: ImageGenerationParameters, continuation: AsyncStream<Data>.Continuation) async {
        // 暂时只返回空数据，后续实现完整生成
        continuation.finish()
    }
}
