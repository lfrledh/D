import Foundation

public protocol ImageGenerationService: Sendable {
    nonisolated func generate(prompt: String, parameters: ImageGenerationParameters) -> AsyncStream<Data>
}
