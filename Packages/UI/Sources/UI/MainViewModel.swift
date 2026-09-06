import Foundation
import Core
import SwiftUI

@MainActor
@Observable
public final class MainViewModel {
    private let modelLoading: any ModelLoading
    private var capabilityViewModels: [ModelCapability: any CapabilityViewModel] = [:]

    // 公共状态 - 下载管理
    public var downloadModelID: String = ""
    public var isDownloading = false
    public var downloadTasks: [DownloadTaskHandle] = []
    private var downloadTaskObserver: NSObjectProtocol?

    // 当前选中的模态
    public var selectedCapability: ModelCapability = .text {
        didSet {
            if capabilityViewModels[selectedCapability] == nil {
                createViewModel(for: selectedCapability)
            }
        }
    }

    // 供内部使用的当前子ViewModel
    var currentCapabilityViewModel: (any CapabilityViewModel)? {
        capabilityViewModels[selectedCapability]
    }

    public init(modelLoading: any ModelLoading) {
        self.modelLoading = modelLoading

        createViewModel(for: .text)
        createViewModel(for: .image)

        self.downloadTaskObserver = NotificationCenter.default.addObserver(
            forName: .downloadTaskUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                await self?.refreshDownloadTasks()
            }
        }
        Task {
            await refreshDownloadTasks()
        }
    }

    private func createViewModel(for capability: ModelCapability) {
        switch capability {
        case .text:
            capabilityViewModels[capability] = TextCapabilityViewModel(modelLoading: modelLoading)
        case .image:
            capabilityViewModels[capability] = ImageCapabilityViewModel(modelLoading: modelLoading)
        case .audio, .video, .visionLanguage:
            break
        }
    }

    // MARK: - 下载管理
    @MainActor
    public func refreshDownloadTasks() async {
        let tasks = await modelLoading.getAllDownloadTasks()
        self.downloadTasks = tasks
    }

    public func openDownloadsFolder() {
        guard let downloadsURL = getDownloadsDirectory() else { return }
        NSWorkspace.shared.open(downloadsURL)
    }

    private func getDownloadsDirectory() -> URL? {
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"] {
            return URL(fileURLWithPath: hfHome)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documents?.appendingPathComponent("huggingface_cache")
    }

    public func downloadModel() async {
        let id = downloadModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        if downloadTasks.contains(where: { task in
            switch task.status {
            case .downloading: return true
            default: return false
            }
        }) {
            return
        }

        isDownloading = true

        do {
            _ = try await modelLoading.startDownload(modelId: id)
            await refreshDownloadTasks()
        } catch {
            // 错误处理（可以发送通知或设置错误消息，但这里没有errorMessage属性）
        }

        isDownloading = false
    }
}
