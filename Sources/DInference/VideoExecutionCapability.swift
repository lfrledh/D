import Foundation

/// Typed description of the implemented adapter, separate from tested hardware profiles.
public struct VideoExecutionCapability: Sendable, Equatable {
    public static let wan21 = VideoExecutionCapability()
    public let profile = ExecutionProfileReference(identifier: "wan21-t2v-1.3b-bf16-v1")
    public let modelRevision = "37ec512624d61f7aa208f7ea8140a131f93afc9a"
    public let dimensionMultiple = 16
    public let frameStride = 4
    public let maximumLatentAxis = 1024
    public let maximumSteps = 1000
    public let maximumSeed = UInt64(UInt32.max)
    public let maximumTextTokens = 512
    public let precisionDescription = "T5/DiT BF16（保留原 FP32 张量），VAE FP32"
    private init() {}

    public func validate(_ value: VideoRequest) throws {
        try value.validate()
        guard value.executionProfile == profile,
              value.width % dimensionMultiple == 0, value.height % dimensionMultiple == 0,
              (value.frameCount - 1) % frameStride == 0, value.seed <= maximumSeed,
              value.guidanceScale > 0, value.steps <= maximumSteps,
              max(value.width / dimensionMultiple, value.height / dimensionMultiple,
                  (value.frameCount - 1) / frameStride + 1) <= maximumLatentAxis else {
            throw InferenceFailure.invalidRequest("当前视频模型要求宽高为16的倍数、帧数为4n+1、步数1…1000、Seed为0…4294967295；引导值大于0，潜在轴不超过1024。输入不会自动调整。")
        }
    }

    /// Same single-point estimate used by the backend. Long sequences remain uncalibrated.
    public func estimatedPeakBytes(for value: VideoRequest) throws -> UInt64 {
        try validate(value)
        let pixels = UInt64(value.width) * UInt64(value.height)
        let (workspace, overflow) = pixels.multipliedReportingOverflow(by: 4 * 384 * 4 * 8)
        let (decoder, extraOverflow) = workspace.addingReportingOverflow(1024 * 1024 * 1024)
        guard !overflow, !extraOverflow else { throw InferenceFailure.invalidResourceEstimate }
        return max(13 * 1024 * 1024 * 1024, decoder)
    }
}
