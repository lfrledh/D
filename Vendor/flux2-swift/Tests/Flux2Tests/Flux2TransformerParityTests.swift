import Foundation
import MLX
import XCTest
@testable import Flux2

final class Flux2TransformerParityTests: XCTestCase {
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
    try MLX.save(arrays: weights, metadata: [:], url: transformerDirectory.appendingPathComponent("model.safetensors"))
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
}
