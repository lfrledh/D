import DInference
import Foundation

/// Editing text survives invalid intermediate input. Only submission makes an execution snapshot.
public struct VideoCreationDraft: Codable, Sendable, Equatable {
    public var revision: UUID
    public var prompt: String
    public var negativePrompt: String
    public var widthText: String
    public var heightText: String
    public var framesText: String
    public var fpsNumeratorText: String
    public var fpsDenominatorText: String
    public var stepsText: String
    public var guidanceText: String
    public var shiftText: String
    public var seedText: String
    /// Empty means the automatic host budget; otherwise an exact positive MiB integer.
    public var memoryBudgetMiBText: String
    public var rejectedAssetIDs: [UUID]

    public init(revision: UUID = UUID(), prompt: String = "", negativePrompt: String = "",
                widthText: String = "832", heightText: String = "480", framesText: String = "17",
                fpsNumeratorText: String = "16", fpsDenominatorText: String = "1",
                stepsText: String = "50", guidanceText: String = "6", shiftText: String = "8",
                seedText: String = "42", memoryBudgetMiBText: String = "",
                rejectedAssetIDs: [UUID] = []) {
        self.revision = revision; self.prompt = prompt; self.negativePrompt = negativePrompt
        self.widthText = widthText; self.heightText = heightText; self.framesText = framesText
        self.fpsNumeratorText = fpsNumeratorText; self.fpsDenominatorText = fpsDenominatorText
        self.stepsText = stepsText; self.guidanceText = guidanceText; self.shiftText = shiftText
        self.seedText = seedText; self.memoryBudgetMiBText = memoryBudgetMiBText
        self.rejectedAssetIDs = rejectedAssetIDs
    }

    public func makeRequest(capability: VideoExecutionCapability = .wan21) throws -> VideoRequest {
        guard let width = Int(widthText), let height = Int(heightText), let frames = Int(framesText),
              let numerator = Int32(fpsNumeratorText), let denominator = Int32(fpsDenominatorText),
              let steps = Int(stepsText), let guidance = Float(guidanceText),
              let shift = Float(shiftText), let seed = UInt64(seedText) else {
            throw InferenceFailure.invalidRequest("请输入有效的视频参数；未完成的输入已保留。")
        }
        let value = VideoRequest(prompt: prompt, negativePrompt: negativePrompt, width: width, height: height,
            frameCount: frames, frameRate: .init(numerator: numerator, denominator: denominator),
            steps: steps, guidanceScale: guidance, scheduleShift: shift, seed: seed, executionProfile: capability.profile)
        try capability.validate(value)
        _ = try selectedMemoryBudgetBytes()
        return value
    }

    public func selectedMemoryBudgetBytes() throws -> UInt64? {
        guard !memoryBudgetMiBText.isEmpty else { return nil }
        guard memoryBudgetMiBText.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(memoryBudgetMiBText), value > 0,
              value <= UInt64(Int64.max) / 1_048_576 else {
            throw InferenceFailure.invalidRequest("内存预算请输入正整数 MiB，或清空以使用自动预算。")
        }
        return value * 1_048_576
    }

    func hasSameEditableRepresentation(as other: Self) -> Bool {
        let lhs = [prompt, negativePrompt, widthText, heightText, framesText, fpsNumeratorText,
                   fpsDenominatorText, stepsText, guidanceText, shiftText, seedText, memoryBudgetMiBText]
        let rhs = [other.prompt, other.negativePrompt, other.widthText, other.heightText, other.framesText,
                   other.fpsNumeratorText, other.fpsDenominatorText, other.stepsText, other.guidanceText,
                   other.shiftText, other.seedText, other.memoryBudgetMiBText]
        return zip(lhs, rhs).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}
