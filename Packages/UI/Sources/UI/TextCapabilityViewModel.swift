import Foundation
import Core
import SwiftUI
import TextInference

@MainActor
@Observable
final class TextCapabilityViewModel: CapabilityViewModel {
    private let modelLoading: any ModelLoading
    private var chatService: LLMChatService?

    // 输出
    var generatedText = ""

    // 参数
    var temperature: Float = 0.8
    var topK: Int = 40
    var topP: Float = 0.95
    var repetitionPenalty: Float = 1.3
    var penaltyWindowSize: Int = 64
    var maxTokens: Int = 100

    // 状态
    var isGenerating = false
    private var generationTask: Task<Void, Never>?
    var prompt = ""

    // 加载状态
    var isModelLoaded: Bool { chatService != nil }
    var isModelLoading = false
    var errorMessage: String?
    var selectedModelURL: URL?

    init(modelLoading: any ModelLoading) {
        self.modelLoading = modelLoading
    }

    // MARK: - 模型加载
    func selectModelFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Text Model Folder"
        panel.message = "Choose a folder containing config.json and .safetensors files"
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
            let container = try await modelLoading.loadChatModel(from: url)
            self.chatService = LLMChatService(modelContainer: container)
        } catch {
            errorMessage = error.localizedDescription
        }

        isModelLoading = false
    }

    func unloadModel() async {
        guard let url = selectedModelURL else { return }
        await modelLoading.unloadModel(at: url)
        chatService = nil
    }

    // MARK: - 生成
    func generate() {
        guard let service = chatService else {
            errorMessage = "No text model loaded"
            return
        }

        isGenerating = true
        generatedText = ""
        errorMessage = nil

        let params = GenerateParameters(
            temperature: temperature,
            topP: topP,
            topK: topK,
            repetitionPenalty: repetitionPenalty,
            penaltyWindowSize: penaltyWindowSize,
            maxTokens: maxTokens
        )

        generationTask = Task { @MainActor in
            let stream = service.generate(prompt: prompt, parameters: params)
            for await fragment in stream {
                if Task.isCancelled { break }
                if fragment.hasPrefix("[Error] ") {
                    errorMessage = String(fragment.dropFirst(7))
                    break
                }
                generatedText += fragment
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
