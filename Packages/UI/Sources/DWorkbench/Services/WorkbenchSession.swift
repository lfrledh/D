import DInference
import Foundation

/// Application-facing runtime bridge. The composition root owns backend-specific types.
public struct WorkbenchSession: Sendable {
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
                validateAudioModel: (@Sendable (URL) async throws -> ModelReference)? = nil) {
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
