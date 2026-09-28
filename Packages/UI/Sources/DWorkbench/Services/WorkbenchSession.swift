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
    public let pitchBackendID: String?
    public let pitchModel: ModelReference?
    /// Explicit owner of backend output files when several workspaces share one runtime.
    public var artifactStore: ProjectStore? = nil
    public let engine: any InferenceEngine
    public let backendID: String
    public let status: @Sendable () async -> WorkbenchRuntimeStatus
    public let shutdown: @Sendable () async -> Void
    public let cleanup: @Sendable () async throws -> Void
    public let validateModel: @Sendable (URL) async throws -> Void

    /// A workspace may drain its own requests, but must not shut down the App runtime.
    public func borrowed(artifactStore: ProjectStore) -> Self {
        var value = Self(engine: engine, backendID: backendID, status: status,
            shutdown: {}, cleanup: {}, validateModel: validateModel,
            textBackendID: textBackendID, validateTextModel: validateTextModel,
            audioBackendID: audioBackendID, validateAudioModel: validateAudioModel,
            musicBackendID: musicBackendID, validateMusicModel: validateMusicModel,
            imageCapability: imageCapability, textCapability: textCapability,
            audioCapability: audioCapability, musicCapability: musicCapability,
            videoBackendID: videoBackendID, validateVideoModel: validateVideoModel,
            videoCapability: videoCapability, defaultMemoryBudgetBytes: defaultMemoryBudgetBytes,
            pitchBackendID: pitchBackendID, pitchModel: pitchModel)
        value.artifactStore = artifactStore
        return value
    }

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
                defaultMemoryBudgetBytes: UInt64 = 12 * 1024 * 1024 * 1024,
                pitchBackendID: String? = nil, pitchModel: ModelReference? = nil) {
        self.pitchBackendID = pitchBackendID
        self.pitchModel = pitchModel
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
