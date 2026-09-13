import DInference
import Foundation

public struct VideoBackendConfiguration: Sendable {
    public static let revision = "37ec512624d61f7aa208f7ea8140a131f93afc9a"
    public static let profile = ExecutionProfileReference(identifier: "wan21-t2v-1.3b-bf16-v1")
    public let pythonExecutable: URL
    public let providerScript: URL
    public let tokenizerDirectory: URL
    public let artifactDirectory: URL
    public let memoryLimitBytes: UInt64
    public let timeoutSeconds: Double
    public let cancellationGraceSeconds: Double

    public init(pythonExecutable: URL, providerScript: URL, tokenizerDirectory: URL,
                artifactDirectory: URL, memoryLimitBytes: UInt64, timeoutSeconds: Double = 3600,
                cancellationGraceSeconds: Double = 30) {
        self.pythonExecutable = pythonExecutable; self.providerScript = providerScript
        self.tokenizerDirectory = tokenizerDirectory; self.artifactDirectory = artifactDirectory
        self.memoryLimitBytes = memoryLimitBytes; self.timeoutSeconds = timeoutSeconds
        self.cancellationGraceSeconds = cancellationGraceSeconds
    }

    static func validate(_ value: VideoRequest) throws {
        try value.validate()
        guard value.executionProfile == profile, value.width % 16 == 0, value.height % 16 == 0,
              (value.frameCount - 1) % 4 == 0, value.seed <= UInt32.max,
              value.guidanceScale > 0, value.steps <= 1000,
              max(value.width / 16, value.height / 16, (value.frameCount - 1) / 4 + 1) <= 1024 else {
            throw InferenceFailure.invalidRequest(
                "Wan V0 requires its explicit profile, 16-aligned geometry, 4n+1 frames, UInt32 seed, positive guidance, 1...1000 steps and latent axes <= 1024. No parameters are adjusted.")
        }
    }

    static func estimate(_ value: VideoRequest) throws -> UInt64 {
        try validate(value)
        // T5 BF16 plus workspace; decoder working sets scale with image area.
        // Conservative estimates, not a statement that the development Mac is a ceiling.
        let pixels = UInt64(value.width) * UInt64(value.height)
        let (workspace, overflow) = pixels.multipliedReportingOverflow(by: 4 * 384 * 4 * 4)
        let (decoder, extraOverflow) = workspace.addingReportingOverflow(1024 * 1024 * 1024)
        guard !overflow, !extraOverflow else { throw InferenceFailure.invalidResourceEstimate }
        return max(13 * 1024 * 1024 * 1024, decoder)
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
