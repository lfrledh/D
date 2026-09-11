import DInference
import Foundation

/// AW1 editable creation options. Invalid/incomplete numeric input is saved verbatim;
/// submission validation creates a separate immutable AudioRequest.
public struct AudioCreationDraft: Codable, Sendable, Equatable {
    public var revision: UUID
    public var prompt: String
    public var operation: AudioOperation
    public var durationText: String
    public var seedText: String
    public var stepsText: String
    public var guidanceText: String
    public var strengthText: String
    public var editRegion: AudioFrameRange?
    public var rejectedAssetIDs: [UUID]

    public init(revision: UUID = UUID(), prompt: String = "", operation: AudioOperation = .generate,
                durationText: String = "6", seedText: String = "42", stepsText: String = "8",
                guidanceText: String = "1", strengthText: String = "0.5",
                editRegion: AudioFrameRange? = nil, rejectedAssetIDs: [UUID] = []) {
        self.revision = revision; self.prompt = prompt; self.operation = operation
        self.durationText = durationText; self.seedText = seedText; self.stepsText = stepsText
        self.guidanceText = guidanceText; self.strengthText = strengthText
        self.editRegion = editRegion; self.rejectedAssetIDs = rejectedAssetIDs
    }

    public func makeRequest(source: AudioSourceReference?) throws -> AudioRequest {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceFailure.invalidRequest("Audio prompt must not be blank.")
        }
        guard let seed = UInt64(seedText), seed <= UInt64(UInt32.max) - 1,
              let steps = Int(stepsText), (1...100).contains(steps),
              let guidance = Float(guidanceText), guidance.isFinite, (1...15).contains(guidance) else {
            throw InferenceFailure.invalidRequest("Invalid current audio profile parameters.")
        }

        let duration: Double
        let strength: Float
        let region: AudioEditRegion?
        switch operation {
        case .generate:
            guard source == nil, editRegion == nil else {
                throw InferenceFailure.invalidRequest("Generation does not accept a source or edit region.")
            }
            guard let requestedDuration = Double(durationText), requestedDuration.isFinite,
                  requestedDuration > 0 else {
                throw InferenceFailure.invalidRequest("Invalid generation duration.")
            }
            duration = requestedDuration
            strength = 1
            region = nil
        case .variation:
            guard let source, editRegion == nil else {
                throw InferenceFailure.invalidRequest("Variation requires a source and no edit region.")
            }
            guard let requestedStrength = Float(strengthText), requestedStrength.isFinite,
                  requestedStrength > 0, requestedStrength <= 1 else {
                throw InferenceFailure.invalidRequest("Invalid variation strength.")
            }
            duration = Double(source.frameCount) / Double(source.sampleRate)
            strength = requestedStrength
            region = nil
        case .inpaint:
            guard let source, let editRegion,
                  editRegion.startFrame >= 0, editRegion.startFrame < editRegion.endFrame,
                  editRegion.endFrame <= source.frameCount else {
                throw InferenceFailure.invalidRequest("Inpainting requires a valid half-open source region.")
            }
            guard let requestedStrength = Float(strengthText), requestedStrength.isFinite,
                  requestedStrength > 0, requestedStrength <= 1 else {
                throw InferenceFailure.invalidRequest("Invalid inpaint strength.")
            }
            duration = Double(source.frameCount) / Double(source.sampleRate)
            strength = requestedStrength
            region = AudioEditRegion(startFrame: editRegion.startFrame, endFrame: editRegion.endFrame)
        }
        guard duration.isFinite, duration > 0 else {
            throw InferenceFailure.invalidRequest("Invalid audio duration.")
        }
        let request = AudioRequest(operation: operation, prompt: prompt, durationSeconds: duration,
                                   seed: seed, steps: steps, guidanceScale: guidance,
                                   strength: strength, source: source, editRegion: region)
        try request.validate()
        return request
    }
}
