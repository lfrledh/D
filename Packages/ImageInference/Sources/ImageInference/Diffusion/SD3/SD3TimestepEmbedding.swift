import MLX
import MLXNN
import Darwin

class Timesteps: Module {
    let numChannels: Int
    let flipSinToCos: Bool
    let downscaleFreqShift: Float
    let scale: Float

    public init(numChannels: Int, flipSinToCos: Bool = true, downscaleFreqShift: Float = 0, scale: Float = 1) {
        self.numChannels = numChannels
        self.flipSinToCos = flipSinToCos
        self.downscaleFreqShift = downscaleFreqShift
        self.scale = scale
        super.init()
    }

    public func callAsFunction(_ timesteps: MLXArray) -> MLXArray {
        let halfDim = numChannels / 2
        let indices = MLXArray(Array(0..<halfDim)).asType(.float32)
        let exponent = -Float(log(10000.0)) * indices / Float(halfDim - 1)
        let emb = exp(exponent)

        let t = timesteps.asType(.float32).expandedDimensions(axis: 1)
        var embOut = t * emb
        embOut = embOut * scale

        let embSin = sin(embOut)
        let embCos = cos(embOut)
        if flipSinToCos {
            embOut = concatenated([embCos, embSin], axis: 1)
        } else {
            embOut = concatenated([embSin, embCos], axis: 1)
        }

        if numChannels % 2 == 1 {
            embOut = padded(embOut, widths: [0, 0, 0, 1], value: MLXArray(0))
        }
        return embOut
    }
}

class TimestepEmbedding: Module {
    let linear1: Linear
    let linear2: Linear
    let act: SiLU

    public init(inChannels: Int, timeEmbedDim: Int, outDim: Int? = nil, act: SiLU? = nil) {
        self.linear1 = Linear(inChannels, timeEmbedDim)
        self.linear2 = Linear(timeEmbedDim, outDim ?? timeEmbedDim)
        self.act = act ?? SiLU()
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = linear1(x)
        h = act(h)
        h = linear2(h)
        return h
    }
}

class CombinedTimestepTextProjEmbeddings: Module {
    let timeProj: Timesteps
    let timestepEmbedder: TimestepEmbedding
    let textEmbedder: Linear

    public init(embeddingDim: Int, pooledProjectionDim: Int) {
        self.timeProj = Timesteps(numChannels: 256, flipSinToCos: true, downscaleFreqShift: 0)
        self.timestepEmbedder = TimestepEmbedding(inChannels: 256, timeEmbedDim: embeddingDim)
        self.textEmbedder = Linear(pooledProjectionDim, embeddingDim)
        super.init()
    }

    public func callAsFunction(_ timestep: MLXArray, _ pooledProjection: MLXArray) -> MLXArray {
        let timeProjEmb = timeProj(timestep)
        let timeEmb = timestepEmbedder(timeProjEmb)
        let textEmb = textEmbedder(pooledProjection)
        return timeEmb + textEmb
    }
}
