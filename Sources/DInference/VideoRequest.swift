import Foundation

/// Exact frames per second, independent of the model's latent time compression.
public struct VideoFrameRate: Sendable, Codable, Equatable {
    public let numerator: Int32
    public let denominator: Int32

    public init(numerator: Int32, denominator: Int32 = 1) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public func validate() throws {
        guard numerator > 0, denominator > 0 else {
            throw InferenceFailure.invalidRequest("Video frame rate must have a positive numerator and denominator.")
        }
    }
}

/// A text-to-video execution snapshot. Image conditioning and audio are deliberately
/// absent until an adapter implements them; no untyped condition dictionary is used.
/// The profile determines the sampler/precision, while these values are never silently
/// rounded, truncated, or replaced by a host's latest preferences.
public struct VideoRequest: Sendable, Codable, Equatable {
    public let prompt: String
    public let negativePrompt: String
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let frameRate: VideoFrameRate
    public let steps: Int
    public let guidanceScale: Float
    public let scheduleShift: Float
    public let seed: UInt64
    public let executionProfile: ExecutionProfileReference

    public init(prompt: String, negativePrompt: String, width: Int, height: Int,
                frameCount: Int, frameRate: VideoFrameRate, steps: Int,
                guidanceScale: Float, scheduleShift: Float, seed: UInt64,
                executionProfile: ExecutionProfileReference) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.scheduleShift = scheduleShift
        self.seed = seed
        self.executionProfile = executionProfile
    }

    /// Common representational rules only. Dimensions, frame stride, token counts,
    /// sampler, and seed support must additionally be checked by the selected adapter.
    public func validate() throws {
        try frameRate.validate()
        guard width > 0, height > 0, frameCount > 0, steps > 0,
              guidanceScale.isFinite, guidanceScale >= 0,
              scheduleShift.isFinite, scheduleShift > 0,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !executionProfile.identifier.isEmpty, executionProfile.revision > 0 else {
            throw InferenceFailure.invalidRequest("Invalid video generation parameters or profile identity.")
        }
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (frameBytes, frameOverflow) = area.multipliedReportingOverflow(by: 3)
        let (_, spoolOverflow) = frameBytes.multipliedReportingOverflow(by: frameCount)
        let (_, timeOverflow) = Int64(frameCount).multipliedReportingOverflow(by: Int64(frameRate.denominator))
        guard !areaOverflow, !frameOverflow, !spoolOverflow, !timeOverflow else {
            throw InferenceFailure.invalidRequest("Video geometry or duration exceeds the integer representation.")
        }
    }
}
