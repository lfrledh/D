import Foundation
import MLX
import MLXNN
import XCTest
@testable import Flux2

/// Opt-in numerical controls on original tensors. The one-block text fixture is
/// explicitly a comparison fixture, never a production model or generation result.
final class Flux2DevOriginalBlockTests: XCTestCase {
  func testOriginalTextBlockAndDiffusionBlocksKeepExactNumerics() throws {
    guard let path = ProcessInfo.processInfo.environment["D_TEST_DEV_BF16"],
          let output = ProcessInfo.processInfo.environment["D_TEST_DEV_CONTROL"] else {
      throw XCTSkip("Original Dev control is opt-in")
    }
    let source = URL(fileURLWithPath: path), target = URL(fileURLWithPath: output)
    let oldCache = Memory.cacheLimit; Memory.cacheLimit = 0
    defer { Flux2RuntimeResources.clearCaches(); Memory.clearCache(); Memory.cacheLimit = oldCache }
    let component = target.appendingPathComponent("text_encoder")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("text_encoder/config.json"))) as? [String: Any])
    var text = try XCTUnwrap(config["text_config"] as? [String: Any])
    XCTAssertEqual(text["num_hidden_layers"] as? Int, 40)
    text["num_hidden_layers"] = 1
    if let types = text["layer_types"] as? [String] { text["layer_types"] = Array(types.prefix(1)) }
    config["text_config"] = text
    try JSONSerialization.data(withJSONObject: config).write(to: component.appendingPathComponent("config.json"), options: .withoutOverwriting)
    try autoreleasepool {
      let tensors = try Flux2WeightsLoader(snapshot: source).load(component: .textEncoder, dtype: nil) {
        $0.hasSuffix("embed_tokens.weight") || $0.hasSuffix("model.norm.weight") ||
          $0 == "model.language_model.norm.weight" || $0.contains(".layers.0.")
      }
      XCTAssertTrue(tensors.values.allSatisfy { $0.dtype == .bfloat16 })
      try MLX.save(arrays: tensors, url: component.appendingPathComponent("model.safetensors"))
    }
    func textResult(layered: Bool) throws -> [Float32] {
      let model = try layered ? Flux2Mistral3TextEncoder.loadLayered(from: target) : Flux2Mistral3TextEncoder.load(from: target)
      let result = try model.promptEmbeds(inputIds: MLXArray([Int32(1), 2, 3, 4], [1, 4]),
        attentionMask: MLXArray.ones([1, 4], dtype: .int32), hiddenStateLayers: [0, 1])
      MLX.eval(result); XCTAssertEqual(result.dtype, .bfloat16)
      return result.asType(.float32).asArray(Float32.self)
    }
    let resident = try autoreleasepool { try textResult(layered: false) }; Memory.clearCache()
    let layered = try autoreleasepool { try textResult(layered: true) }; Memory.clearCache()
    XCTAssertEqual(layered, resident); XCTAssertFalse(layered.contains { !$0.isFinite })
    print("D_DEV_CONTROL text original block exact", layered.count)

    let cfg = try JSONDecoder().decode(Flux2TransformerConfiguration.self,
      from: Data(contentsOf: source.appendingPathComponent("transformer/config.json")))
    XCTAssertEqual(cfg.numLayers, 8); XCTAssertEqual(cfg.numSingleLayers, 48)
    for single in [false, true] {
      let prefix = single ? "single_transformer_blocks.0." : "transformer_blocks.0."
      func result(selected: Bool) throws -> [Float32] {
        let weights: [String: MLXArray]
        if selected {
          weights = try Flux2PinnedWeightSelection(snapshot: source, component: .transformer) { _, dtype in dtype == .bfloat16 }.load { $0.hasPrefix(prefix) }
        } else {
          weights = try Flux2WeightsLoader(snapshot: source).load(component: .transformer, dtype: nil) { $0.hasPrefix(prefix) }
        }
        let local = Dictionary(uniqueKeysWithValues: weights.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
        let hidden = (MLXArray(0..<(2 * cfg.innerDim)).asType(.float32) / Float(2 * cfg.innerDim)).reshaped(1, 2, cfg.innerDim).asType(.bfloat16)
        let context = hidden * MLXArray(Float32(0.5)).asType(.bfloat16)
        let zero = MLXArray.zeros([1, 1, cfg.innerDim], dtype: .bfloat16)
        let one = MLXArray.ones([1, 1, cfg.innerDim], dtype: .bfloat16)
        let modulation: Flux2ModulationParams = (zero, zero, one)
        let value: MLXArray
        if single {
          let block = Flux2SingleTransformerBlock(dim: cfg.innerDim, numAttentionHeads: cfg.numAttentionHeads,
            attentionHeadDim: cfg.attentionHeadDim, mlpRatio: cfg.mlpRatio, eps: cfg.eps)
          XCTAssertEqual(Set(local.keys), Set(block.parameters().flattened().map { $0.0 }))
          try block.update(parameters: ModuleParameters.unflattened(local), verify: .none)
          value = block(hiddenStates: hidden, encoderHiddenStates: context, tembModParams: modulation).hiddenStates
        } else {
          let block = Flux2TransformerBlock(dim: cfg.innerDim, numAttentionHeads: cfg.numAttentionHeads,
            attentionHeadDim: cfg.attentionHeadDim, mlpRatio: cfg.mlpRatio, eps: cfg.eps)
          XCTAssertEqual(Set(local.keys), Set(block.parameters().flattened().map { $0.0 }))
          try block.update(parameters: ModuleParameters.unflattened(local), verify: .none)
          let pair = block(hiddenStates: hidden, encoderHiddenStates: context,
            tembModParamsImg: [modulation, modulation], tembModParamsTxt: [modulation, modulation])
          value = concatenated([pair.encoderHiddenStates, pair.hiddenStates], axis: 1)
        }
        MLX.eval(value); XCTAssertEqual(value.dtype, .bfloat16)
        return value.asType(.float32).asArray(Float32.self)
      }
      let expected = try autoreleasepool { try result(selected: false) }; Memory.clearCache()
      let actual = try autoreleasepool { try result(selected: true) }; Memory.clearCache()
      XCTAssertEqual(actual, expected); XCTAssertFalse(actual.contains { !$0.isFinite })
      print("D_DEV_CONTROL", prefix, "original tensors exact", actual.count)
    }
  }
}
