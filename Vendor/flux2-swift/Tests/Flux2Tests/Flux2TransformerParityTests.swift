import Foundation
import Darwin
import MLX
import XCTest
@testable import Flux2

final class Flux2TransformerParityTests: XCTestCase {
  func testLayeredTransformerRejectsReplacementFromOriginalAdmission() throws {
    enum AdmissionError: Error { case changed }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny/transformer")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let component = root.appendingPathComponent("transformer")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.copyItem(at: fixture.appendingPathComponent("config.json"),
      to: component.appendingPathComponent("config.json"))
    let file = component.appendingPathComponent("model.safetensors")
    try FileManager.default.copyItem(at: fixture.appendingPathComponent("model.safetensors"), to: file)
    var original = stat()
    XCTAssertEqual(Darwin.lstat(file.path, &original), 0)
    var bytes = try Data(contentsOf: file)
    bytes[bytes.count - 1] ^= 1 // Payload changes; the header, dtype, and file length do not.
    let replacement = component.appendingPathComponent("replacement.tmp")
    try bytes.write(to: replacement)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: replacement, to: file)
    var validations = 0
    let validate: () throws -> Void = {
      validations += 1
      var current = stat()
      guard Darwin.lstat(file.path, &current) == 0,
            current.st_dev == original.st_dev, current.st_ino == original.st_ino else {
        throw AdmissionError.changed
      }
    }
    XCTAssertThrowsError(try Flux2Transformer2DModel.loadLayered(from: root, dtype: .float32,
      admissionValidator: validate)) { error in
      guard case AdmissionError.changed = error else {
        return XCTFail("Expected original admission failure, got \(error)")
      }
    }
    XCTAssertGreaterThan(validations, 0)
  }

  func testTinyTransformerMatchesFixtures() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny")

    let inputsURL = fixtureRoot.appendingPathComponent("transformer_inputs.safetensors")
    let expectedURL = fixtureRoot.appendingPathComponent("transformer_expected.safetensors")
    XCTAssertTrue(FileManager.default.fileExists(atPath: inputsURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))

    let inputsReader = try SafeTensorsReader(fileURL: inputsURL)
    let hiddenStates = try inputsReader.tensor(named: "hidden_states").asType(.float32)
    let encoderHiddenStates = try inputsReader.tensor(named: "encoder_hidden_states").asType(.float32)
    let timestep = try inputsReader.tensor(named: "timestep").asType(.float32)
    let imgIds = try inputsReader.tensor(named: "img_ids").asType(.int32)
    let txtIds = try inputsReader.tensor(named: "txt_ids").asType(.int32)

    let transformer = try Flux2Transformer2DModel.load(from: fixtureRoot, dtype: .float32)
    let actual = transformer(
      hiddenStates,
      encoderHiddenStates: encoderHiddenStates,
      timestep: timestep,
      imgIds: imgIds,
      txtIds: txtIds
    ).asType(.float32)

    let expectedReader = try SafeTensorsReader(fileURL: expectedURL)
    let expected = try expectedReader.tensor(named: "output").asType(.float32)
    TestHelpers.assertAllClose(actual, expected, atol: 1e-4, rtol: 1e-3)
    // The fixture is an independent original-operation reference, including
    // its one double block and one single block. Exercise selected reads too.
    let layered = try Flux2Transformer2DModel.loadLayered(from: fixtureRoot, dtype: .float32)
    let selected = try layered.callLayered(hiddenStates, encoderHiddenStates: encoderHiddenStates,
      timestep: timestep, imgIds: imgIds, txtIds: txtIds)
    TestHelpers.assertAllClose(selected, expected, atol: 1e-4, rtol: 1e-3)
  }

  func testLayeredTinyTransformerMatchesResidentAndRequiresEveryBlock() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny")
    let reader = try SafeTensorsReader(fileURL: root.appendingPathComponent("transformer_inputs.safetensors"))
    let hidden = try reader.tensor(named: "hidden_states").asType(.float32)
    let encoder = try reader.tensor(named: "encoder_hidden_states").asType(.float32)
    let time = try reader.tensor(named: "timestep").asType(.float32)
    let imageIDs = try reader.tensor(named: "img_ids").asType(.int32)
    let textIDs = try reader.tensor(named: "txt_ids").asType(.int32)
    let resident = try Flux2Transformer2DModel.load(from: root, dtype: .float32)
    let layered = try Flux2Transformer2DModel.loadLayered(from: root, dtype: .float32)
    XCTAssertThrowsError(try Flux2Transformer2DModel.loadLayered(from: root, dtype: .bfloat16))
    XCTAssertEqual(layered.configuration.numLayers, 1)
    XCTAssertEqual(layered.configuration.numSingleLayers, 1)
    let expected = resident(hidden, encoderHiddenStates: encoder, timestep: time, imgIds: imageIDs, txtIds: textIDs)
    let actual = try layered.callLayered(hidden, encoderHiddenStates: encoder, timestep: time,
      imgIds: imageIDs, txtIds: textIDs)
    TestHelpers.assertAllClose(actual, expected, atol: 1e-4, rtol: 1e-3)
    let control = withRandomState(MLXRandom.RandomState(seed: 73)) {
      MLXRandom.uniform(0.0..<1.0, [4]).asArray(Float.self)
    }
    let randomState = MLXRandom.RandomState(seed: 73)
    let afterLayered = try withRandomState(randomState) {
      _ = try layered.callLayered(hidden, encoderHiddenStates: encoder, timestep: time,
        imgIds: imageIDs, txtIds: textIDs)
      return MLXRandom.uniform(0.0..<1.0, [4]).asArray(Float.self)
    }
    XCTAssertEqual(afterLayered, control)

    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let transformerDirectory = temporary.appendingPathComponent("transformer")
    try FileManager.default.createDirectory(at: transformerDirectory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("transformer/config.json"),
      to: transformerDirectory.appendingPathComponent("config.json"))
    var weights = try Flux2WeightsLoader(snapshot: root).load(component: .transformer, dtype: .float32)
    weights.removeValue(forKey: "single_transformer_blocks.0.attn.norm_q.weight")
    try MLX.save(arrays: weights, metadata: ["format": "pt"], url: transformerDirectory.appendingPathComponent("model.safetensors"))
    let incomplete = try Flux2Transformer2DModel.loadLayered(from: temporary, dtype: .float32)
    XCTAssertThrowsError(try incomplete.callLayered(hidden, encoderHiddenStates: encoder,
      timestep: time, imgIds: imageIDs, txtIds: textIDs))
  }

  func testLayeredTransformerStopsAtCancelledBlockBoundary() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny")
    let task = Task { () -> Bool in
      do {
        let reader = try SafeTensorsReader(fileURL: root.appendingPathComponent("transformer_inputs.safetensors"))
        let model = try Flux2Transformer2DModel.loadLayered(from: root, dtype: .float32)
        let hidden = try reader.tensor(named: "hidden_states").asType(.float32)
        let encoder = try reader.tensor(named: "encoder_hidden_states").asType(.float32)
        let time = try reader.tensor(named: "timestep").asType(.float32)
        let imageIDs = try reader.tensor(named: "img_ids").asType(.int32)
        let textIDs = try reader.tensor(named: "txt_ids").asType(.int32)
        withUnsafeCurrentTask { $0?.cancel() }
        _ = try model.callLayered(hidden, encoderHiddenStates: encoder, timestep: time,
          imgIds: imageIDs, txtIds: textIDs)
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    let cancelled = await task.value
    XCTAssertTrue(cancelled)
  }

  func testBF16LayeredTransformerMatchesResidentWithFullBlocksAndGuidance() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let component = temporary.appendingPathComponent("transformer")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("transformer/config.json"),
      to: component.appendingPathComponent("config.json"))
    let sourceWeights = try Flux2WeightsLoader(snapshot: root).load(component: .transformer, dtype: .float32)
    let bf16 = sourceWeights.mapValues { $0.asType(.bfloat16) }
    MLX.eval(Array(bf16.values))
    try MLX.save(arrays: bf16, metadata: ["format": "pt"], url: component.appendingPathComponent("model.safetensors"))

    let reader = try SafeTensorsReader(fileURL: root.appendingPathComponent("transformer_inputs.safetensors"))
    let hidden = try reader.tensor(named: "hidden_states").asType(.bfloat16)
    let encoder = try reader.tensor(named: "encoder_hidden_states").asType(.bfloat16)
    let time = try reader.tensor(named: "timestep").asType(.bfloat16)
    let imageIDs = try reader.tensor(named: "img_ids").asType(.int32)
    let textIDs = try reader.tensor(named: "txt_ids").asType(.int32)
    let guidance = MLXArray([Float32(1)]).asType(.bfloat16)
    let resident = try Flux2Transformer2DModel.load(from: temporary, dtype: .bfloat16)
    let layered = try Flux2Transformer2DModel.loadLayered(from: temporary, dtype: .bfloat16)
    XCTAssertEqual(layered.configuration.numLayers, 1)
    XCTAssertEqual(layered.configuration.numSingleLayers, 1)
    let expected = resident(hidden, encoderHiddenStates: encoder, timestep: time,
      imgIds: imageIDs, txtIds: textIDs, guidance: guidance, evaluationPolicy: .aggressive)
    let actual = try layered.callLayered(hidden, encoderHiddenStates: encoder, timestep: time,
      imgIds: imageIDs, txtIds: textIDs, guidance: guidance)
    MLX.eval(expected, actual)
    XCTAssertEqual(actual.dtype, .bfloat16)
    XCTAssertEqual(actual.shape, expected.shape)
    XCTAssertEqual(actual.asType(.float32).asArray(Float32.self),
                   expected.asType(.float32).asArray(Float32.self))

    let control = withRandomState(MLXRandom.RandomState(seed: 73)) {
      MLXRandom.uniform(0.0..<1.0, [4]).asArray(Float.self)
    }
    let afterLayered = try withRandomState(MLXRandom.RandomState(seed: 73)) {
      _ = try layered.callLayered(hidden, encoderHiddenStates: encoder, timestep: time,
        imgIds: imageIDs, txtIds: textIDs, guidance: guidance)
      return MLXRandom.uniform(0.0..<1.0, [4]).asArray(Float.self)
    }
    XCTAssertEqual(afterLayered, control)
  }
}

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
    let source = URL(fileURLWithPath: path).standardizedFileURL
    let parent = URL(fileURLWithPath: output).standardizedFileURL
    guard parent.resolvingSymlinksInPath() == parent,
          !(parent.path + "/").hasPrefix(source.resolvingSymlinksInPath().path + "/"),
          !(source.resolvingSymlinksInPath().path + "/").hasPrefix(parent.path + "/") else {
      throw NSError(domain: "DevControl", code: 1)
    }
    let target = parent.appendingPathComponent("dev-blocks-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    print("D_DEV_CONTROL_DIRECTORY", target.path)
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
      try MLX.save(arrays: tensors, metadata: ["format": "pt"], url: component.appendingPathComponent("model.safetensors"))
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
