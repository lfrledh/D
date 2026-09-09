import Foundation

public enum InferenceCapability: String, Sendable, Codable, Hashable {
    case textGeneration
    case imageGeneration
    case audioGeneration
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
}

public struct TextRequest: Sendable, Codable, Equatable {
    public let prompt: String
    public let maxTokens: Int
    public let temperature: Float
    public let topP: Float

    public init(prompt: String, maxTokens: Int = 256, temperature: Float = 0.7, topP: Float = 0.95) {
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }
}

public struct ImageRequest: Sendable, Codable, Equatable {
    public let prompt: String
    public let width: Int
    public let height: Int
    public let steps: Int
    public let guidanceScale: Float
    public let seed: UInt64

    public init(prompt: String, width: Int, height: Int, steps: Int,
                guidanceScale: Float, seed: UInt64) {
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
    }
}

/// This deliberately describes implemented contract shapes, not every future modality.
/// Tokenization, latents, tensor layouts, and model-specific conditioning stay in backends.
public enum InferenceInput: Sendable, Codable, Equatable {
    case text(TextRequest)
    case image(ImageRequest)
    case audio(AudioRequest)

    public var capability: InferenceCapability {
        switch self {
        case .text: .textGeneration
        case .image: .imageGeneration
        case .audio: .audioGeneration
        }
    }
}

public struct InferenceRequest: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let model: ModelReference
    public let input: InferenceInput

    public init(id: UUID = UUID(), model: ModelReference, input: InferenceInput) {
        self.id = id
        self.model = model
        self.input = input
    }

    /// Common validation only. Backends must also validate architecture and capabilities.
    public func validate() throws {
        guard model.directory.isFileURL, model.directory.path.hasPrefix("/") else {
            throw InferenceFailure.invalidRequest("Model directory must be a local absolute file URL.")
        }
        switch input {
        case .text(let text):
            guard text.maxTokens > 0, text.temperature.isFinite,
                  text.temperature >= 0, text.topP.isFinite, text.topP > 0, text.topP <= 1 else {
                throw InferenceFailure.invalidRequest("Invalid text generation parameters.")
            }
        case .audio(let audio):
            try audio.validate()
        case .image(let image):
            guard image.width > 0, image.height > 0, image.steps > 0,
                  image.guidanceScale.isFinite, image.guidanceScale >= 0 else {
                throw InferenceFailure.invalidRequest("Invalid image generation parameters.")
            }
        }
    }
}
