import Foundation
import Core
import SwiftUI
import ImageInference

@MainActor
@Observable
final class ImageCapabilityViewModel: CapabilityViewModel {
    private let modelLoading: any ModelLoading
    private var imageService: ImageGenerationService?

    // 输出
    var generatedImages: [NSImage] = []

    // 参数
    var steps: Int = 20
    var guidanceScale: Float = 7.5
    var seed: UInt64?
    var width: Int = 512
    var height: Int = 512

    // 状态
    var isGenerating = false
    private var generationTask: Task<Void, Never>?
    var prompt = ""

    // 加载状态
    var isModelLoaded: Bool { imageService != nil }
    var isModelLoading = false
    var errorMessage: String?
    var selectedModelURL: URL?

    init(modelLoading: any ModelLoading) {
        self.modelLoading = modelLoading
    }

    // MARK: - 模型加载
    func selectModelFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Image Model Folder"
        panel.message = "Choose a folder containing the image model"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedModelURL = url
    }

    func loadSelectedModel() async {
        guard let url = selectedModelURL else {
            errorMessage = "No folder selected"
            return
        }

        isModelLoading = true
        errorMessage = nil

        do {
            let service = try await modelLoading.loadImageModel(from: url)
            self.imageService = service
        } catch {
            errorMessage = error.localizedDescription
        }

        isModelLoading = false
    }

    func unloadModel() async {
        guard let url = selectedModelURL else { return }
        await modelLoading.unloadModel(at: url)
        imageService = nil
    }

    // MARK: - 生成
    func generate() {
        guard let service = imageService else {
            errorMessage = "No image model loaded"
            return
        }

        isGenerating = true
        errorMessage = nil

        let params = ImageGenerationParameters(
            steps: steps,
            guidanceScale: guidanceScale,
            seed: seed,
            width: width,
            height: height
        )

        generationTask = Task { @MainActor in
            let stream = service.generate(prompt: prompt, parameters: params)
            for await data in stream {
                if Task.isCancelled { break }
                if data.isEmpty {
                    errorMessage = "Image generation failed"
                    break
                }
                if let image = NSImage(data: data) {
                    self.generatedImages.append(image)
                }
            }
            isGenerating = false
            generationTask = nil
        }
    }

    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }
}
