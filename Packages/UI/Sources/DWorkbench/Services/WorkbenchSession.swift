import DInference
import Foundation

/// Application-facing runtime bridge. The composition root owns backend-specific types.
public struct WorkbenchSession: Sendable {
    public let videoCapability: VideoExecutionCapability?
    public let videoBackendID: String?
    public let validateVideoModel: (@Sendable (URL) async throws -> ModelReference)?
    public let defaultMemoryBudgetBytes: UInt64
    public let imageCapability: ImageExecutionCapability
    public let textCapability: TextExecutionCapability?
    public let audioCapability: AudioExecutionCapability?
    public let musicCapability: AudioExecutionCapability?
    public let musicBackendID: String?
    public let validateMusicModel: (@Sendable (URL) async throws -> ModelReference)?
    public let audioBackendID: String?
    public let validateAudioModel: (@Sendable (URL) async throws -> ModelReference)?
    public let textBackendID: String?
    public let validateTextModel: (@Sendable (URL) async throws -> ModelReference)?
    public let engine: any InferenceEngine
    public let backendID: String
    public let status: @Sendable () async -> WorkbenchRuntimeStatus
    public let shutdown: @Sendable () async -> Void
    public let cleanup: @Sendable () async throws -> Void
    public let validateModel: @Sendable (URL) async throws -> Void

    public init(engine: any InferenceEngine, backendID: String,
                status: @escaping @Sendable () async -> WorkbenchRuntimeStatus,
                shutdown: @escaping @Sendable () async -> Void,
                cleanup: @escaping @Sendable () async throws -> Void,
                validateModel: @escaping @Sendable (URL) async throws -> Void,
                textBackendID: String? = nil,
                validateTextModel: (@Sendable (URL) async throws -> ModelReference)? = nil,
                audioBackendID: String? = nil,
                validateAudioModel: (@Sendable (URL) async throws -> ModelReference)? = nil,
                musicBackendID: String? = nil,
                validateMusicModel: (@Sendable (URL) async throws -> ModelReference)? = nil,
                imageCapability: ImageExecutionCapability = .verified512,
                textCapability: TextExecutionCapability? = nil,
                audioCapability: AudioExecutionCapability? = nil,
                musicCapability: AudioExecutionCapability? = nil,
                videoBackendID: String? = nil,
                validateVideoModel: (@Sendable (URL) async throws -> ModelReference)? = nil,
                videoCapability: VideoExecutionCapability? = nil,
                defaultMemoryBudgetBytes: UInt64 = 12 * 1024 * 1024 * 1024) {
        self.videoBackendID = videoBackendID
        self.validateVideoModel = validateVideoModel
        self.videoCapability = videoCapability
        self.defaultMemoryBudgetBytes = defaultMemoryBudgetBytes
        self.imageCapability = imageCapability
        self.textCapability = textCapability
        self.audioCapability = audioCapability
        self.musicCapability = musicCapability
        self.musicBackendID = musicBackendID
        self.validateMusicModel = validateMusicModel
        self.audioBackendID = audioBackendID
        self.validateAudioModel = validateAudioModel
        self.textBackendID = textBackendID
        self.validateTextModel = validateTextModel
        self.engine = engine
        self.backendID = backendID
        self.status = status
        self.shutdown = shutdown
        self.cleanup = cleanup
        self.validateModel = validateModel
    }
}

public struct WorkbenchRuntimeStatus: Sendable {
    public let activeRunID: UUID?
    public let phase: String?
    public let state: JobState?
    public let queuedRunIDs: [UUID]

    public init(activeRunID: UUID?, phase: String?, queuedRunIDs: [UUID], state: JobState? = nil) {
        self.activeRunID = activeRunID
        self.phase = phase
        self.state = state
        self.queuedRunIDs = queuedRunIDs
    }
}
