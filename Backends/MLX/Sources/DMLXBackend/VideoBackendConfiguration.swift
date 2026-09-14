import DInference
import Foundation

public struct VideoBackendConfiguration: Sendable {
    public static let revision = VideoExecutionCapability.wan21.modelRevision
    public static let profile = VideoExecutionCapability.wan21.profile
    public let pythonExecutable: URL
    public let providerScript: URL
    public let tokenizerDirectory: URL
    public let artifactDirectory: URL
    /// MLX graph-evaluation guideline; not an RSS/physical-memory hard cap.
    public let memoryLimitBytes: UInt64
    public let timeoutSeconds: Double
    public let cancellationGraceSeconds: Double
    public let accessBootstrapRoot: URL?
    public let confirmDeployment: (@Sendable () throws -> Void)?

    public init(pythonExecutable: URL, providerScript: URL, tokenizerDirectory: URL,
                artifactDirectory: URL, memoryLimitBytes: UInt64, timeoutSeconds: Double = 3600,
                cancellationGraceSeconds: Double = 30, accessBootstrapRoot: URL? = nil,
                confirmDeployment: (@Sendable () throws -> Void)? = nil) {
        self.pythonExecutable = pythonExecutable; self.providerScript = providerScript
        self.tokenizerDirectory = tokenizerDirectory; self.artifactDirectory = artifactDirectory
        self.memoryLimitBytes = memoryLimitBytes; self.timeoutSeconds = timeoutSeconds
        self.cancellationGraceSeconds = cancellationGraceSeconds
        self.accessBootstrapRoot = accessBootstrapRoot
        self.confirmDeployment = confirmDeployment
    }

    static func validate(_ value: VideoRequest) throws {
        try VideoExecutionCapability.wan21.validate(value)
    }

    static func estimate(_ value: VideoRequest) throws -> UInt64 {
        try VideoExecutionCapability.wan21.estimatedPeakBytes(for: value)
    }
}

struct VideoWireRequest: Encodable {
    let schemaVersion = 1
    let runID: String
    let profile = VideoBackendConfiguration.profile.identifier
    let revision = VideoBackendConfiguration.revision
    let prompt: String
    let negativePrompt: String
    let width: Int
    let height: Int
    let frameCount: Int
    let fpsNumerator: Int32
    let fpsDenominator: Int32
    let steps: Int
    let guidanceScale: Float
    let shift: Float
    let seed: UInt64
    let memoryLimitBytes: UInt64

    init(id: UUID, video: VideoRequest, memoryLimitBytes: UInt64) {
        runID = id.uuidString.lowercased(); prompt = video.prompt; negativePrompt = video.negativePrompt
        width = video.width; height = video.height; frameCount = video.frameCount
        fpsNumerator = video.frameRate.numerator; fpsDenominator = video.frameRate.denominator
        steps = video.steps; guidanceScale = video.guidanceScale; shift = video.scheduleShift
        seed = video.seed; self.memoryLimitBytes = memoryLimitBytes
    }
}
