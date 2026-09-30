import Foundation

public enum InferenceCapability: String, Sendable, Codable, Hashable {
    case textGeneration
    case imageGeneration
    case audioGeneration
    case videoGeneration
    case audioPitchAnalysis
    case audioSingingGeneration
}

/// A resolved local model. Downloading and obtaining sandbox access belong to the host.
/// A revision/digest is useful provenance, but does not itself validate file contents.
public struct ModelReference: Sendable, Codable, Equatable {
    public let directory: URL
    public let revision: String?

    public init(directory: URL, revision: String? = nil) {
        self.directory = directory
        self.revision = revision
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Codable writes absolute URLs. Bundle URLs may retain a base before saving;
        // compare their locations while preserving the original URL for host access.
        lhs.directory.absoluteURL == rhs.directory.absoluteURL && lhs.revision == rhs.revision
    }
}

/// This deliberately describes implemented contract shapes, not every future modality.
/// Tokenization, latents, tensor layouts, and model-specific conditioning stay in backends.
public enum InferenceInput: Sendable, Codable, Equatable {
    case text(TextRequest)
    case image(ImageRequest)
    case audio(AudioRequest)
    case video(VideoRequest)
    case pitch(PitchAnalysisRequest)
    case singing(SingingRequest)

    public var capability: InferenceCapability {
        switch self {
        case .text: .textGeneration
        case .image: .imageGeneration
        case .audio: .audioGeneration
        case .video: .videoGeneration
        case .pitch: .audioPitchAnalysis
        case .singing: .audioSingingGeneration
        }
    }
}

public struct InferenceRequest: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let model: ModelReference
    public let input: InferenceInput
    /// Explicit caller selection, frozen with the job. Nil uses the host's default.
    /// This is a runtime admission budget, never a measured physical-memory cap.
    /// Backends may explicitly map it to a soft guidance value; video currently does.
    public let memoryBudgetBytes: UInt64?

    public init(id: UUID = UUID(), model: ModelReference, input: InferenceInput,
                memoryBudgetBytes: UInt64? = nil) {
        self.id = id
        self.model = model
        self.input = input
        self.memoryBudgetBytes = memoryBudgetBytes
    }

    /// Common validation only. Backends must also validate architecture and capabilities.
    public func validate() throws {
        if let memoryBudgetBytes {
            guard memoryBudgetBytes > 0, memoryBudgetBytes <= Int64.max else {
                throw InferenceFailure.invalidRequest("The explicit memory budget must be positive and representable.")
            }
        }
        guard model.directory.isFileURL, model.directory.path.hasPrefix("/") else {
            throw InferenceFailure.invalidRequest("Model directory must be a local absolute file URL.")
        }
        switch input {
        case .singing(let singing):
            try singing.validate()
        case .pitch(let pitch):
            try pitch.validate()
        case .video(let video):
            try video.validate()
        case .text(let text):
            guard text.maxTokens > 0, text.temperature.isFinite,
                  text.temperature >= 0, text.topP.isFinite, text.topP > 0, text.topP <= 1 else {
                throw InferenceFailure.invalidRequest("Invalid text generation parameters.")
            }
        case .audio(let audio):
            try audio.validate()
        case .image(let image):
            try image.referenceImage?.validate()
            guard image.width > 0, image.height > 0, image.steps > 0,
                  image.guidanceScale.isFinite, image.guidanceScale >= 0 else {
                throw InferenceFailure.invalidRequest("Invalid image generation parameters.")
            }
        }
    }
}
