import Foundation

public struct ImageRequest: Sendable, Codable, Equatable {
    public let prompt: String
    public let width: Int
    public let height: Int
    public let steps: Int
    public let guidanceScale: Float
    public let seed: UInt64
    public let executionProfile: ExecutionProfileReference?
    public let referenceImage: ImageReference?
    /// Ordered frozen inputs. Nil retains the legacy single-reference encoding.
    public let referenceImages: [ImageReference]?

    public init(prompt: String, width: Int, height: Int, steps: Int,
                guidanceScale: Float, seed: UInt64, executionProfile: ExecutionProfileReference? = nil,
                referenceImage: ImageReference? = nil,
                referenceImages: [ImageReference]? = nil) {
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.executionProfile = executionProfile
        self.referenceImage = referenceImage
        self.referenceImages = referenceImages
    }

    /// Resolve the two public forms without dropping or reordering any input.
    public func resolvedReferences() throws -> [ImageReference] {
        guard referenceImage == nil || referenceImages == nil else {
            throw InferenceFailure.invalidRequest("Specify either referenceImage or referenceImages, not both.")
        }
        if let referenceImages {
            guard !referenceImages.isEmpty else {
                throw InferenceFailure.invalidRequest("The referenceImages list cannot be empty.")
            }
            for reference in referenceImages { try reference.validate() }
            return referenceImages
        }
        if let referenceImage {
            try referenceImage.validate()
            return [referenceImage]
        }
        return []
    }
}
