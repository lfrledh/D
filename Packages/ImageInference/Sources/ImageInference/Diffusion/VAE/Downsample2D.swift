import MLX
import MLXNN

public class Downsample2D: Module, UnaryLayer {
    let conv: Conv2d

    public init(channels: Int, outChannels: Int? = nil, padding: Int = 1) {
        let outCh = outChannels ?? channels
        self.conv = Conv2d(
            inputChannels: channels,
            outputChannels: outCh,
            kernelSize: 3,
            stride: 2,
            padding: IntOrPair(padding)
        )
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        return conv(x)
    }
}
