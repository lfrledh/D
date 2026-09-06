// Path: Core/Sources/Core/Models/InferenceTask.swift

import Foundation

/// Represents a task to be performed by the inference engine.
public enum InferenceTask: Sendable {
    case textGeneration(prompt: String, parameters: GenerateParameters)
    case imageGeneration(prompt: String, parameters: ImageGenerationParameters)
    case audioGeneration(prompt: String, parameters: AudioGenerationParameters)
    case videoGeneration(prompt: String, parameters: VideoGenerationParameters)
    case visionLanguage(imageData: Data, prompt: String)
}
