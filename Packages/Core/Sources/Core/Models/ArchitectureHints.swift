// Path: Core/Sources/Core/Models/ArchitectureHints.swift

import Foundation

/// Numerical hints extracted from model config for memory planning.
public struct ArchitectureHints: Sendable, Codable, Equatable {
    public let numLayers: Int
    public let numAttentionHeads: Int
    public let numKVHeads: Int
    public let headDim: Int
    public let hiddenSize: Int
    public let vocabSize: Int
    public let maxSequenceLength: Int
    public let intermediateSize: Int

    public init(
        numLayers: Int,
        numAttentionHeads: Int,
        numKVHeads: Int,
        headDim: Int,
        hiddenSize: Int,
        vocabSize: Int,
        maxSequenceLength: Int,
        intermediateSize: Int = 0
    ) {
        self.numLayers = numLayers
        self.numAttentionHeads = numAttentionHeads
        self.numKVHeads = numKVHeads
        self.headDim = headDim
        self.hiddenSize = hiddenSize
        self.vocabSize = vocabSize
        self.maxSequenceLength = maxSequenceLength
        self.intermediateSize = intermediateSize
    }

    public static let none = ArchitectureHints(
        numLayers: 0,
        numAttentionHeads: 0,
        numKVHeads: 0,
        headDim: 0,
        hiddenSize: 0,
        vocabSize: 0,
        maxSequenceLength: 0
    )
}
