// File: D/D/DApp.swift

import SwiftUI
import Core
import ModelLoading
import UI
import MLX
import ImageInference
import StableDiffusion

@main
struct DApp: App {
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            MainView(viewModel: dependencies.mainViewModel)
        }
    }
}

@MainActor
final class AppDependencies {
    let modelLoading: any ModelLoading
    let mainViewModel: MainViewModel

    init() {
        // 设置 MLX 错误处理
        MLX.setErrorHandler { message, _ in
            if let msgPtr = message {
                let msg = String(cString: msgPtr)
                print("MLX Error: \(msg)")
            }
        }

        // 从 UserDefaults 读取下载路径，如果不存在则使用默认值
        let savedPath = UserDefaults.standard.string(forKey: "downloadPath")
        let downloadPath: String
        if let savedPath = savedPath, !savedPath.isEmpty {
            downloadPath = savedPath
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            downloadPath = documents.appendingPathComponent("huggingface_cache").path
            UserDefaults.standard.set(downloadPath, forKey: "downloadPath")
        }
        setenv("HF_HOME", downloadPath, 1)
        print("HF_HOME set to: \(downloadPath)")

        let hardware = HardwareProfile()

        // 定义图像服务工厂闭包
        let imageFactory: (String, HardwareProfile) async throws -> ImageGenerationService = { modelID, hardwareProfile in
            // 判断是否为 SD3 系列模型
            if modelID.contains("stable-diffusion-3.5") || modelID.contains("sd3") {
                // 使用 SD3Service，暂时不量化，float16 开启
                return SD3Service(modelID: modelID, loadConfig: LoadConfiguration(float16: true, quantize: false))
            } else {
                // 默认使用 StableDiffusionService
                return StableDiffusionService(modelID: modelID, float16: true, quantize: false)
            }
        }

        // 创建 ModelLoadingActor，传入工厂闭包
        let loadingActor = ModelLoadingActor(
            hardwareProfile: hardware,
            imageServiceFactory: imageFactory
        )

        self.modelLoading = loadingActor
        self.mainViewModel = MainViewModel(modelLoading: loadingActor)
    }
}
