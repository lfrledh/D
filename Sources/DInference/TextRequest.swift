import Foundation

public struct TextRequest: Sendable, Codable, Equatable {
    public let prompt: String
    public let maxTokens: Int
    public let temperature: Float
    public let topP: Float
    public let execution: TextExecutionSelection?

    public init(prompt: String, maxTokens: Int = 256, temperature: Float = 0.7, topP: Float = 0.95,
                execution: TextExecutionSelection? = nil) {
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.execution = execution
    }
}

