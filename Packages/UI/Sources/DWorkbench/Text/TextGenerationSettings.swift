import DInference
import Foundation

/// Persisted text generation choices. Unknown profiles remain representable so an
/// existing document can be inspected even when its request cannot be executed.
public struct TextGenerationSettings: Codable, Equatable, Sendable {
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let profile: ExecutionProfileReference

    public init(maximumPromptTokens: Int = 2048,
                maximumOutputTokens: Int = 256,
                profile: ExecutionProfileReference = TextExecutionCapability.qwen2Profile) {
        self.maximumPromptTokens = maximumPromptTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.profile = profile
    }

    public static let legacy = TextGenerationSettings()
}
