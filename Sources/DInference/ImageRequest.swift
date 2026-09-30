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

    public init(prompt: String, width: Int, height: Int, steps: Int,
                guidanceScale: Float, seed: UInt64, executionProfile: ExecutionProfileReference? = nil,
                referenceImage: ImageReference? = nil) {
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.executionProfile = executionProfile
        self.referenceImage = referenceImage
    }
}

