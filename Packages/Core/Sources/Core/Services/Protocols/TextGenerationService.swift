// Path: Core/Sources/Core/Services/Protocols/TextGenerationService.swift

import Foundation

/// Service for text generation.
public protocol TextGenerationService: Sendable {
    nonisolated func generate(prompt: String, parameters: GenerateParameters) -> AsyncStream<String>
}
