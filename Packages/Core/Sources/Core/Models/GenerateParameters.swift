// Path: Core/Sources/Core/Models/GenerateParameters.swift

import Foundation

/// Parameters for text generation.
public struct GenerateParameters: Sendable, Codable {
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    public var repetitionPenalty: Float
    public var penaltyWindowSize: Int
    public var maxTokens: Int
    public var stopSequences: [String]

    public init(
        temperature: Float = 0.8,
        topP: Float = 0.95,
        topK: Int = 40,
        repetitionPenalty: Float = 1.3,
        penaltyWindowSize: Int = 64,
        maxTokens: Int = 100,
        stopSequences: [String] = []
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.penaltyWindowSize = penaltyWindowSize
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }
}
