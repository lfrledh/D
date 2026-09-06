// Path: Core/Sources/Core/Models/LoRAConfig.swift

import Foundation

/// Configuration for LoRA adapters.
public struct LoRAConfig: Sendable, Codable {
    public let rank: Int
    public let alpha: Float
    public let targetModules: [String]

    public init(rank: Int, alpha: Float, targetModules: [String]) {
        self.rank = rank
        self.alpha = alpha
        self.targetModules = targetModules
    }
}
