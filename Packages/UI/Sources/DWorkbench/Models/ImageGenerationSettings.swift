import DInference

/// Persistable image-generation selection. It describes only the controls implemented
/// by the frozen image capability; model installation remains a separate concern.
public struct ImageGenerationSettings: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let executionProfile: ExecutionProfileReference

    public static let legacy = ImageGenerationSettings()

    public init(width: Int = 512, height: Int = 512,
                executionProfile: ExecutionProfileReference = ImageExecutionCapability.verified512.profile) {
        self.width = width
        self.height = height
        self.executionProfile = executionProfile
    }

    public func request(prompt: String, seed: UInt64,
                        capability: ImageExecutionCapability, referenceImage: ImageReference? = nil) throws -> ImageRequest {
        let request = ImageRequest(
            prompt: prompt, width: width, height: height,
            steps: capability.steps, guidanceScale: capability.guidanceScale,
            seed: seed, executionProfile: referenceImage == nil ? executionProfile : ImageExecutionCapability.referenceKlein4B.profile,
            referenceImage: referenceImage)
        try capability.validate(request)
        return request
    }
}
