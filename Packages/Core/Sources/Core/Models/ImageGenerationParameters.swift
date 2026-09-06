// Path: Core/Sources/Core/Models/ImageGenerationParameters.swift

import Foundation

/// Parameters for image generation.
public struct ImageGenerationParameters: Sendable, Codable {
    public var steps: Int
    public var guidanceScale: Float
    public var seed: UInt64?
    public var width: Int
    public var height: Int

    public init(
        steps: Int = 20,
        guidanceScale: Float = 7.5,
        seed: UInt64? = nil,
        width: Int = 512,
        height: Int = 512
    ) {
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.width = width
        self.height = height
    }
}
