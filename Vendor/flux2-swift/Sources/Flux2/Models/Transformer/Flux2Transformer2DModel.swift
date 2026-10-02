import Foundation
import MLX
import MLXNN

public enum Flux2Transformer2DModelError: Error {
  case configNotFound(URL)
  case incompleteLayer(String)
  case unsupportedLayeredQuantization
  case unsupportedLayeredPrecision
}

public final class Flux2Transformer2DModel: Module {
  public let configuration: Flux2TransformerConfiguration
  public let outChannels: Int
  public let innerDim: Int

  private let posEmbed: Flux2PosEmbed

  @ModuleInfo(key: "time_guidance_embed") private var timeGuidanceEmbed: Flux2TimestepGuidanceEmbeddings
  @ModuleInfo(key: "double_stream_modulation_img") private var doubleStreamModulationImg: Flux2Modulation
  @ModuleInfo(key: "double_stream_modulation_txt") private var doubleStreamModulationTxt: Flux2Modulation
  @ModuleInfo(key: "single_stream_modulation") private var singleStreamModulation: Flux2Modulation

  @ModuleInfo(key: "x_embedder") private var xEmbedder: Linear
  @ModuleInfo(key: "context_embedder") private var contextEmbedder: Linear

  @ModuleInfo(key: "transformer_blocks") private var transformerBlocks: [Flux2TransformerBlock]
  @ModuleInfo(key: "single_transformer_blocks") private var singleTransformerBlocks: [Flux2SingleTransformerBlock]

  @ModuleInfo(key: "norm_out") private var normOut: Flux2AdaLayerNormContinuous
  @ModuleInfo(key: "proj_out") private var projOut: Linear
  private var layeredSource: Flux2PinnedWeightSelection? = nil

  public var isLayered: Bool { layeredSource != nil }

  public init(configuration: Flux2TransformerConfiguration) {
    self.configuration = configuration
    outChannels = configuration.resolvedOutChannels
    innerDim = configuration.innerDim
    let numHeads = configuration.numAttentionHeads
    let headDim = configuration.attentionHeadDim
    let mlpRatio = configuration.mlpRatio
    let eps = configuration.eps
    let numLayers = configuration.numLayers
    let numSingleLayers = configuration.numSingleLayers

    posEmbed = Flux2PosEmbed(theta: configuration.ropeTheta, axesDims: configuration.axesDimsRope)

    _timeGuidanceEmbed.wrappedValue = Flux2TimestepGuidanceEmbeddings(
      inChannels: configuration.timestepGuidanceChannels,
      embeddingDim: innerDim,
      bias: false,
      guidanceEmbeds: configuration.guidanceEmbeds
    )

    _doubleStreamModulationImg.wrappedValue = Flux2Modulation(dim: innerDim, modParamSets: 2, bias: false)
    _doubleStreamModulationTxt.wrappedValue = Flux2Modulation(dim: innerDim, modParamSets: 2, bias: false)
    _singleStreamModulation.wrappedValue = Flux2Modulation(dim: innerDim, modParamSets: 1, bias: false)

    _xEmbedder.wrappedValue = Flux2ModulePlaceholders.linear(bias: false)
    _contextEmbedder.wrappedValue = Flux2ModulePlaceholders.linear(bias: false)

    var blocks: [Flux2TransformerBlock] = []
    blocks.reserveCapacity(numLayers)
    for _ in 0..<numLayers {
      blocks.append(Flux2TransformerBlock(
        dim: innerDim,
        numAttentionHeads: numHeads,
        attentionHeadDim: headDim,
        mlpRatio: mlpRatio,
        eps: eps,
        bias: false
      ))
    }
    _transformerBlocks.wrappedValue = blocks

    var singleBlocks: [Flux2SingleTransformerBlock] = []
    singleBlocks.reserveCapacity(numSingleLayers)
    for _ in 0..<numSingleLayers {
      singleBlocks.append(Flux2SingleTransformerBlock(
        dim: innerDim,
        numAttentionHeads: numHeads,
        attentionHeadDim: headDim,
        mlpRatio: mlpRatio,
        eps: eps,
        bias: false
      ))
    }
    _singleTransformerBlocks.wrappedValue = singleBlocks

    _normOut.wrappedValue = Flux2AdaLayerNormContinuous(
      embeddingDim: innerDim,
      conditioningEmbeddingDim: innerDim,
      elementwiseAffine: false,
      eps: eps,
      bias: false
    )

    let projOutDim = configuration.patchSize * configuration.patchSize * outChannels
    _projOut.wrappedValue = Flux2ModulePlaceholders.linear(bias: false)

    super.init()
  }

  public static func load(from snapshot: URL, dtype: DType = .bfloat16, fileSet: Flux2FileSet? = nil) throws -> Flux2Transformer2DModel {
    try fileSet?.require("transformer/config.json")
    let configURL = snapshot
      .appendingPathComponent("transformer")
      .appendingPathComponent("config.json")

    guard FileManager.default.fileExists(atPath: configURL.path) else {
      throw Flux2Transformer2DModelError.configNotFound(configURL)
    }

    let configData = try Data(contentsOf: configURL)
    let configuration = try JSONDecoder().decode(Flux2TransformerConfiguration.self, from: configData)
    let model = Flux2Transformer2DModel(configuration: configuration)

    let loader = Flux2WeightsLoader(snapshot: snapshot, fileSet: fileSet)
    let weights = try loader.load(component: .transformer, dtype: dtype)
    if let manifest = try Flux2Quantizer.loadManifest(from: snapshot, fileSet: fileSet) {
      Flux2Quantizer.applyQuantization(to: model, manifest: manifest, weights: weights)
    }
    try model.update(parameters: ModuleParameters.unflattened(weights), verify: .none)

    return model
  }

  public static func loadLayered(from snapshot: URL, dtype: DType = .bfloat16, fileSet: Flux2FileSet? = nil,
                                 admissionValidator: (() throws -> Void)? = nil) throws -> Flux2Transformer2DModel {
    try admissionValidator?()
    if let _ = try Flux2Quantizer.loadManifest(from: snapshot, fileSet: fileSet) {
      throw Flux2Transformer2DModelError.unsupportedLayeredQuantization
    }
    try admissionValidator?()
    try fileSet?.require("transformer/config.json")
    let configURL = snapshot.appendingPathComponent("transformer/config.json")
    try admissionValidator?()
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      throw Flux2Transformer2DModelError.configNotFound(configURL)
    }
    let configData = try Data(contentsOf: configURL)
    try admissionValidator?()
    let configuration = try JSONDecoder().decode(Flux2TransformerConfiguration.self, from: configData)
    try admissionValidator?()
    let model = Flux2Transformer2DModel(configuration: configuration)
    try admissionValidator?()
    let source = try Flux2PinnedWeightSelection(snapshot: snapshot, component: .transformer, fileSet: fileSet,
                                                 admissionValidator: admissionValidator) {
      _, actual in actual == dtype
    }
    let weights = try source.load {
      !$0.hasPrefix("transformer_blocks.") && !$0.hasPrefix("single_transformer_blocks.")
    }
    let expected = Set(model.parameters().flattened().map { $0.0 }.filter {
      !$0.hasPrefix("transformer_blocks.") && !$0.hasPrefix("single_transformer_blocks.")
    })
    guard !expected.isEmpty, Set(weights.keys) == expected else {
      throw Flux2Transformer2DModelError.incompleteLayer("shared")
    }
    try model.update(parameters: ModuleParameters.unflattened(weights), verify: .none)
    MLX.eval(Array(weights.values))
    try source.verifyFileIdentities()
    model.layeredSource = source
    return model
  }

  private func loadDoubleBlock(_ index: Int, source: Flux2PinnedWeightSelection) throws -> Flux2TransformerBlock {
    let prefix = "transformer_blocks.\(index)."
    let loaded = try source.load {
      $0.hasPrefix(prefix)
    }
    let stripped = Dictionary(uniqueKeysWithValues: loaded.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
    try source.verifyFileIdentities()
    let block = Flux2TransformerBlock(dim: innerDim, numAttentionHeads: configuration.numAttentionHeads,
      attentionHeadDim: configuration.attentionHeadDim, mlpRatio: configuration.mlpRatio,
      eps: configuration.eps, bias: false)
    let expected = Set(block.parameters().flattened().map { $0.0 })
    guard !expected.isEmpty, Set(stripped.keys) == expected else {
      throw Flux2Transformer2DModelError.incompleteLayer(prefix)
    }
    try block.update(parameters: ModuleParameters.unflattened(stripped), verify: .none)
    return block
  }

  private func loadSingleBlock(_ index: Int, source: Flux2PinnedWeightSelection) throws -> Flux2SingleTransformerBlock {
    let prefix = "single_transformer_blocks.\(index)."
    let loaded = try source.load {
      $0.hasPrefix(prefix)
    }
    let stripped = Dictionary(uniqueKeysWithValues: loaded.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
    try source.verifyFileIdentities()
    let block = Flux2SingleTransformerBlock(dim: innerDim, numAttentionHeads: configuration.numAttentionHeads,
      attentionHeadDim: configuration.attentionHeadDim, mlpRatio: configuration.mlpRatio,
      eps: configuration.eps, bias: false)
    let expected = Set(block.parameters().flattened().map { $0.0 })
    guard !expected.isEmpty, Set(stripped.keys) == expected else {
      throw Flux2Transformer2DModelError.incompleteLayer(prefix)
    }
    try block.update(parameters: ModuleParameters.unflattened(stripped), verify: .none)
    return block
  }

  public func callAsFunction(
    _ hiddenStates: MLXArray,
    encoderHiddenStates: MLXArray,
    timestep: MLXArray,
    imgIds: MLXArray,
    txtIds: MLXArray,
    guidance: MLXArray? = nil,
    attentionMask: MLXFast.ScaledDotProductAttentionMaskMode = .none,
    evaluationPolicy: Flux2EvaluationPolicy = .deferred
  ) -> MLXArray {
    // This entry point is retained for the resident model, where forward cannot throw.
    precondition(layeredSource == nil, "Use callLayered for a layered transformer.")
    return try! forward(hiddenStates, encoderHiddenStates: encoderHiddenStates, timestep: timestep,
      imgIds: imgIds, txtIds: txtIds, guidance: guidance, attentionMask: attentionMask,
      evaluationPolicy: evaluationPolicy, source: nil)
  }

  public func callLayered(
    _ hiddenStates: MLXArray, encoderHiddenStates: MLXArray, timestep: MLXArray,
    imgIds: MLXArray, txtIds: MLXArray, guidance: MLXArray? = nil,
    attentionMask: MLXFast.ScaledDotProductAttentionMaskMode = .none
  ) throws -> MLXArray {
    guard let layeredSource else { throw Flux2Transformer2DModelError.incompleteLayer("layered source") }
    return try forward(hiddenStates, encoderHiddenStates: encoderHiddenStates, timestep: timestep,
      imgIds: imgIds, txtIds: txtIds, guidance: guidance, attentionMask: attentionMask,
      evaluationPolicy: .aggressive, source: layeredSource)
  }

  private func forward(
    _ hiddenStates: MLXArray, encoderHiddenStates: MLXArray, timestep: MLXArray,
    imgIds: MLXArray, txtIds: MLXArray, guidance: MLXArray?,
    attentionMask: MLXFast.ScaledDotProductAttentionMaskMode,
    evaluationPolicy: Flux2EvaluationPolicy,
    source: Flux2PinnedWeightSelection?
  ) throws -> MLXArray {
    let numTxtTokens = encoderHiddenStates.dim(1)
    let targetDtype = hiddenStates.dtype
    let scale = MLXArray(1000.0).asType(targetDtype)

    let timestepScaled = timestep.asType(targetDtype) * scale
    var guidanceScaled: MLXArray? = nil
    if let guidance {
      guidanceScaled = guidance.asType(targetDtype) * scale
    }

    let temb = timeGuidanceEmbed(timestepScaled, guidance: guidanceScaled)

    let doubleStreamModImg = doubleStreamModulationImg(temb)
    let doubleStreamModTxt = doubleStreamModulationTxt(temb)
    let singleStreamMod = singleStreamModulation(temb)[0]

    var hidden = xEmbedder(hiddenStates)
    var encoder = contextEmbedder(encoderHiddenStates)

    let batch = hiddenStates.dim(0)
    let imgSeq = hiddenStates.dim(1)
    let txtSeq = encoderHiddenStates.dim(1)

    func validateIds(_ ids: MLXArray, name: String, expectedSeq: Int) {
      precondition(ids.ndim == 3, "\(name) must be [B, S, num_axes].")
      precondition(ids.dim(0) == batch, "\(name) must have B=\(batch); got \(ids.dim(0)).")
      precondition(ids.dim(1) == expectedSeq, "\(name) must have S=\(expectedSeq); got \(ids.dim(1)).")
    }

    validateIds(imgIds, name: "imgIds", expectedSeq: imgSeq)
    validateIds(txtIds, name: "txtIds", expectedSeq: txtSeq)

    let imageRotary = posEmbed(imgIds)
    let textRotary = posEmbed(txtIds)
    let concatRotary: Flux2RotaryEmbeddings = (
      cos: MLX.concatenated([textRotary.cos, imageRotary.cos], axis: 1),
      sin: MLX.concatenated([textRotary.sin, imageRotary.sin], axis: 1)
    )

    for index in transformerBlocks.indices {
      if source != nil { try Task.checkCancellation(); Memory.clearCache() }
      let block = try source.map { try loadDoubleBlock(index, source: $0) } ?? transformerBlocks[index]
      let outputs = block(
        hiddenStates: hidden,
        encoderHiddenStates: encoder,
        tembModParamsImg: doubleStreamModImg,
        tembModParamsTxt: doubleStreamModTxt,
        imageRotaryEmb: concatRotary,
        attentionMask: attentionMask
      )
      encoder = outputs.encoderHiddenStates
      hidden = outputs.hiddenStates
      if evaluationPolicy == .aggressive { MLX.eval(encoder, hidden) }
      if let source { try source.verifyFileIdentities() }
    }

    hidden = MLX.concatenated([encoder, hidden], axis: 1)

    for index in singleTransformerBlocks.indices {
      if source != nil { try Task.checkCancellation(); Memory.clearCache() }
      let block = try source.map { try loadSingleBlock(index, source: $0) } ?? singleTransformerBlocks[index]
      let outputs = block(
        hiddenStates: hidden,
        tembModParams: singleStreamMod,
        imageRotaryEmb: concatRotary,
        attentionMask: attentionMask
      )
      hidden = outputs.hiddenStates
      evaluationPolicy.evalIfNeeded(hidden)
      if let source { try source.verifyFileIdentities() }
    }

    let splitStates = split(hidden, indices: [numTxtTokens], axis: 1)
    hidden = splitStates[1]

    hidden = normOut(hidden, conditioningEmbedding: temb)
    let output = projOut(hidden)
    if let source {
      MLX.eval(output)
      try source.verifyFileIdentities()
    }
    return output
  }
}
