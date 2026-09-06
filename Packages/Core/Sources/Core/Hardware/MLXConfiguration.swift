// Path: Core/Sources/Core/Hardware/MLXConfiguration.swift

import Foundation
import MLX

/// Configure MLX memory limits based on hardware profile.
public enum MLXConfiguration {
    public nonisolated static func configure(with profile: HardwareProfile) {
        // Set MLX memory limit to inference budget
        Memory.memoryLimit = Int(profile.inferenceBudgetBytes)
        print("[MLXConfiguration] Memory limit set to \(profile.formattedInferenceBudget)")
    }
}
