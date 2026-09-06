import MLX
import MLXNN

/// Swish / SiLU activation function: x * sigmoid(x)
public func swish(_ x: MLXArray) -> MLXArray {
    return x * sigmoid(x)
}
