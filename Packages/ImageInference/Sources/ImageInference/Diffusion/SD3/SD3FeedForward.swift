import MLX
import MLXNN

class SD3FeedForward: Module {
    let linear1: Linear
    let linear2: Linear
    let activation: GELU

    public init(dim: Int, dimOut: Int, activation: GELU = GELU(approximation: .tanh)) {
        self.linear1 = Linear(dim, dim * 4)
        self.linear2 = Linear(dim * 4, dimOut)
        self.activation = activation
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = linear1(x)
        h = activation(h)
        h = linear2(h)
        return h
    }
}
