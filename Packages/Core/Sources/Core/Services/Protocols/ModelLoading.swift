import Foundation

/// Represents the status of a download task.
public enum DownloadStatus: Sendable {
    case waiting
    case downloading(progress: Double, speed: Double?) // speed in bytes/sec
    case paused
    case completed(modelDir: URL)  // 存储下载完成的目录
    case failed(String)
}

/// A handle to control a download task.
public protocol DownloadTaskHandle: Sendable {
    var id: UUID { get }
    var modelId: String { get }
    var status: DownloadStatus { get }
    func pause()
    func resume()
    func cancel(deleteFiles: Bool)
}

public protocol ModelLoading: Sendable {
    func loadChatModel(from url: URL) async throws -> ModelContainerProtocol
    func startDownload(modelId: String) async throws -> DownloadTaskHandle
    func getDownloadTask(for modelId: String) async -> DownloadTaskHandle?
    func getAllDownloadTasks() async -> [DownloadTaskHandle]
    func unloadModel(at url: URL) async
    func isModelLoaded(at url: URL) async -> Bool
    
    /// 从本地模型文件夹加载图像生成模型
    /// - Parameter url: 模型文件夹 URL（如下载管理器返回的 completed(modelDir:) 中的目录）
    /// - Returns: 遵循 ImageGenerationService 协议的服务实例
    func loadImageModel(from url: URL) async throws -> ImageGenerationService
}
