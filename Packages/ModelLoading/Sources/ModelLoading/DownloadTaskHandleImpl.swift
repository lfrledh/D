import Foundation
import Core

public final class DownloadTaskHandleImpl: DownloadTaskHandle, @unchecked Sendable {
    public let id: UUID
    public let modelId: String
    private let actor: ModelLoadingActor
    private let task: Task<Void, Error>
    private let onStatusUpdate: @Sendable (DownloadStatus) -> Void

    public internal(set) var status: DownloadStatus {
        didSet { onStatusUpdate(status) }
    }

    init(id: UUID, modelId: String, actor: ModelLoadingActor, task: Task<Void, Error>, onStatusUpdate: @escaping @Sendable (DownloadStatus) -> Void) {
        self.id = id
        self.modelId = modelId
        self.actor = actor
        self.task = task
        self.onStatusUpdate = onStatusUpdate
        self.status = .waiting
    }

    public func pause() {
        task.cancel()
        status = .paused
        print("DownloadTaskHandleImpl: status set to paused")
    }

    public func resume() {
        Task {
            await actor.resumeDownload(handle: self)
        }
    }

    public func cancel(deleteFiles: Bool) {
        task.cancel()
        if deleteFiles {
            Task {
                await actor.deleteTask(for: modelId, deleteFiles: true)
            }
        } else {
            status = .failed("Download cancelled by user")
        }
    }
}
