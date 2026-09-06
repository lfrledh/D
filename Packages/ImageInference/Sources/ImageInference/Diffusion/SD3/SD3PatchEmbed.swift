import MLX
import MLXNN

class SD3PatchEmbed: Module {
    let proj: Conv2d
    let norm: LayerNorm?
    let patchSize: Int
    let embedDim: Int
    let posEmbed: MLXArray?
    let posEmbedMaxSize: Int?

    public init(
        height: Int,
        width: Int,
        patchSize: Int,
        inChannels: Int,
        embedDim: Int,
        posEmbedMaxSize: Int? = nil,
        interpolationScale: Float = 1.0,
        layerNorm: Bool = false
    ) {
        self.patchSize = patchSize
        self.embedDim = embedDim
        self.posEmbedMaxSize = posEmbedMaxSize

        self.proj = Conv2d(
            inputChannels: inChannels,
            outputChannels: embedDim,
            kernelSize: IntOrPair(patchSize),
            stride: IntOrPair(patchSize),
            bias: true
        )

        if layerNorm {
            self.norm = LayerNorm(dimensions: embedDim, eps: 1e-6, affine: false)
        } else {
            self.norm = nil
        }

        if let maxSize = posEmbedMaxSize {
            let pos = SD3PatchEmbed.create2DSincosPosEmbed(
                embedDim: embedDim,
                gridSize: maxSize,
                baseSize: maxSize,
                interpolationScale: interpolationScale
            )
            self.posEmbed = pos
        } else {
            self.posEmbed = nil
        }

        super.init()
    }

    static func create2DSincosPosEmbed(embedDim: Int, gridSize: Int, baseSize: Int, interpolationScale: Float) -> MLXArray {
        let gridH = MLXArray(0..<gridSize).asType(.float32) / Float(gridSize) * Float(baseSize) / interpolationScale
        let gridW = MLXArray(0..<gridSize).asType(.float32) / Float(gridSize) * Float(baseSize) / interpolationScale

        let meshes = meshGrid([gridW, gridH], indexing: .xy)
        guard meshes.count >= 2 else {
            fatalError("meshGrid returned less than 2 arrays")
        }
        let meshW = meshes[0]
        let meshH = meshes[1]
        let grid = stacked([meshW, meshH], axis: 0)

        let halfDim = embedDim / 2
        let omega = MLXArray(0..<halfDim).asType(.float32) * (2.0 * .pi / Float(halfDim))

        let embH = sin(grid[0].reshaped(-1) * omega)
        let embW = cos(grid[1].reshaped(-1) * omega)
        let pos = concatenated([embH, embW], axis: 1)
        return pos.reshaped(gridSize, gridSize, embedDim)
    }

    private func croppedPosEmbed(height: Int, width: Int) -> MLXArray? {
        guard let fullPos = posEmbed, let maxSize = posEmbedMaxSize else { return nil }
        let top = (maxSize - height) / 2
        let left = (maxSize - width) / 2
        let cropped = fullPos[top..<top+height, left..<left+width, 0..<embedDim]
        return cropped.reshaped(-1, embedDim)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (batch, height, width, _) = (x.shape[0], x.shape[1], x.shape[2], x.shape[3])

        var h = proj(x)
        let newHeight = h.shape[1]
        let newWidth = h.shape[2]
        h = h.reshaped(batch, newHeight * newWidth, embedDim)

        if let norm = norm {
            h = norm(h)
        }

        if let fullPos = posEmbed {
            let pos: MLXArray
            if let maxSize = posEmbedMaxSize {
                pos = croppedPosEmbed(height: newHeight, width: newWidth) ?? fullPos.reshaped(-1, embedDim)
            } else {
                pos = fullPos.reshaped(-1, embedDim)
            }
            h = h + pos
        }

        return h
    }
}
