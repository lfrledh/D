// Path: Core/Sources/Core/Models/LoadedTensor.swift

import Foundation
import MLX

/// Represents a tensor loaded from a safetensors file (raw data, not yet converted to MLXArray).
public struct LoadedTensor: Sendable {
    public let name: String
    public let data: Data
    public let dtype: DType
    public let shape: [Int]

    public init(name: String, data: Data, dtype: DType, shape: [Int]) {
        self.name = name
        self.data = data
        self.dtype = dtype
        self.shape = shape
    }
}
