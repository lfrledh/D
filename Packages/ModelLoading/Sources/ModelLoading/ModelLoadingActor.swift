import Foundation
import Core
import MLXLLM
import Hub
import MLXLMCommon

@preconcurrency public actor ModelLoadingActor: ModelLoading {
    private let hardwareProfile: HardwareProfile
    private let imageServiceFactory: ((String, HardwareProfile) async throws -> ImageGenerationService)?  // 改为存储属性，不可变
    private var loadedContainers: [String: ModelContainerWrapper] = [:]
    private var loadedImageServices: [String: ImageGenerationService] = [:]
    private var downloadTasks: [String: DownloadTaskHandleImpl] = [:]
    private var taskForHandle: [UUID: Task<Void, Error>] = [:]

    public init(hardwareProfile: HardwareProfile,
                imageServiceFactory: ((String, HardwareProfile) async throws -> ImageGenerationService)? = nil) {
        self.hardwareProfile = hardwareProfile
        self.imageServiceFactory = imageServiceFactory
    }

    // MARK: - Model Loading

    public func loadChatModel(from url: URL) async throws -> ModelContainerProtocol {
        let cacheKey = url.absoluteString
        if let cached = loadedContainers[cacheKey] {
            return cached
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelLoadingError.directoryNotFound(url)
        }

        let config = ModelConfiguration(directory: url)
        let container = try await LLMModelFactory.shared.loadContainer(configuration: config)
        let wrapper = ModelContainerWrapper(container: container)

        loadedContainers[cacheKey] = wrapper
        return wrapper
    }

    public func loadImageModel(from url: URL) async throws -> ImageGenerationService {
        let cacheKey = url.absoluteString
        if let cached = loadedImageServices[cacheKey] {
            return cached
        }

        guard let factory = imageServiceFactory else {
            throw ModelLoadingError.imageServiceFactoryNotSet
        }

        guard let modelID = modelIDFromCacheFolder(url) else {
            throw ModelLoadingError.invalidModelFolder("Cannot extract model ID from folder name: \(url.lastPathComponent)")
        }

        let service = try await factory(modelID, hardwareProfile)
        loadedImageServices[cacheKey] = service
        return service
    }

    // MARK: - Download Management

    private var hasActiveDownload: Bool {
        downloadTasks.values.contains { task in
            switch task.status {
            case .downloading: return true
            default: return false
            }
        }
    }

    public func startDownload(modelId: String) async throws -> DownloadTaskHandle {
        // 检查是否有活跃下载
        if hasActiveDownload {
            throw ModelLoadingError.activeDownloadExists
        }

        if let existing = downloadTasks[modelId] {
            return existing
        }

        let id = UUID()

        let task = Task<Void, Error> { [weak self] in
            guard let self = self else { return }
            do {
                let config = ModelConfiguration(id: modelId)
                let repo = Hub.Repo(id: modelId)

                var hub = HubApi()
                if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"] {
                    hub = HubApi(downloadBase: URL(fileURLWithPath: hfHome))
                }

                // 开始下载，提供进度回调
                _ = try await hub.snapshot(from: repo) { progress, speed in
                    Task { @MainActor in
                        let status = DownloadStatus.downloading(
                            progress: progress.fractionCompleted,
                            speed: speed
                        )
                        await self.updateDownloadStatus(for: modelId, status: status)
                    }
                }

                // 下载完成后，存储目录
                let modelDir = hub.localRepoLocation(repo)
                let finalStatus = DownloadStatus.completed(modelDir: modelDir)
                await self.updateDownloadStatus(for: modelId, status: finalStatus)
            } catch {
                let finalStatus = DownloadStatus.failed(error.localizedDescription)
                await self.updateDownloadStatus(for: modelId, status: finalStatus)
            }
        }

        let handle = DownloadTaskHandleImpl(
            id: id,
            modelId: modelId,
            actor: self,
            task: task,
            onStatusUpdate: { status in
                Task { @MainActor in
                    NotificationCenter.default.post(name: .downloadTaskUpdated, object: nil, userInfo: ["id": id, "status": status])
                }
            }
        )

        downloadTasks[modelId] = handle
        taskForHandle[id] = task

        return handle
    }

    public func getDownloadTask(for modelId: String) -> DownloadTaskHandle? {
        return downloadTasks[modelId]
    }

    public func getAllDownloadTasks() async -> [DownloadTaskHandle] {
        return Array(downloadTasks.values)
    }

    func updateDownloadStatus(for modelId: String, status: DownloadStatus) async {
        if let handle = downloadTasks[modelId] as? DownloadTaskHandleImpl {
            handle.status = status
        }
    }

    func resumeDownload(handle: DownloadTaskHandleImpl) async {
        _ = try? await startDownload(modelId: handle.modelId)
    }

    func deleteDownloadedFiles(for modelId: String) async {
        guard let hfHome = ProcessInfo.processInfo.environment["HF_HOME"] else { return }
        let repo = Hub.Repo(id: modelId)
        let repoDir = URL(fileURLWithPath: hfHome)
            .appendingPathComponent(repo.type.rawValue)
            .appendingPathComponent(repo.id)
        try? FileManager.default.removeItem(at: repoDir)
    }

    public func deleteTask(for modelId: String, deleteFiles: Bool) async {
        if let handle = downloadTasks[modelId] {
            taskForHandle.removeValue(forKey: handle.id)
        }
        if deleteFiles {
            await deleteDownloadedFiles(for: modelId)
        }
        downloadTasks.removeValue(forKey: modelId)
    }

    // MARK: - Unload / Check

    public func unloadModel(at url: URL) async {
        let cacheKey = url.absoluteString
        loadedContainers.removeValue(forKey: cacheKey)
        loadedImageServices.removeValue(forKey: cacheKey)
    }

    public func isModelLoaded(at url: URL) async -> Bool {
        loadedContainers.keys.contains(url.absoluteString)
    }

    // MARK: - Private Helpers

    private func modelIDFromCacheFolder(_ url: URL) -> String? {
        let folderName = url.lastPathComponent
        // 标准 Hugging Face 缓存文件夹格式：models--org--model
        if folderName.hasPrefix("models--") {
            let withoutPrefix = String(folderName.dropFirst(8)) // 去掉 "models--"
            return withoutPrefix.replacingOccurrences(of: "--", with: "/")
        }
        return nil
    }
}

public extension Notification.Name {
    static let downloadTaskUpdated = Notification.Name("downloadTaskUpdated")
}
