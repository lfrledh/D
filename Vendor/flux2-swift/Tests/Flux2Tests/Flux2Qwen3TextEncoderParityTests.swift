import Foundation
import MLX
import XCTest
@testable import Flux2

final class Flux2Qwen3TextEncoderParityTests: XCTestCase {
  func testTinyQwen3PromptEmbedsMatchesFixtures() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny_text_encoder")
    let fixtureFile = fixtureRoot.appendingPathComponent("prompt_embeds.safetensors")

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureFile.path))

    let reader = try SafeTensorsReader(fileURL: fixtureFile)
    let inputIds = try reader.tensor(named: "input_ids").asType(.int32)
    let attentionMask = try reader.tensor(named: "attention_mask").asType(.int32)
    let expectedEmbeds = try reader.tensor(named: "prompt_embeds").asType(.float32)
    let expectedTextIds = try reader.tensor(named: "text_ids").asType(.int32)

    let encoder = try Flux2Qwen3TextEncoder.load(from: fixtureRoot, dtype: .float32)
    let actualEmbeds = try encoder.promptEmbeds(
      inputIds: inputIds,
      attentionMask: attentionMask,
      hiddenStateLayers: [0, 1, 2]
    )

    TestHelpers.assertAllClose(actualEmbeds, expectedEmbeds, atol: 1e-4, rtol: 1e-3)

    let actualTextIds = try Flux2PositionIds.prepareTextIds(actualEmbeds)
    XCTAssertEqual(actualTextIds.asType(.int32).asArray(Int32.self), expectedTextIds.asArray(Int32.self))
  }

  func testLayeredKeepsEveryTinyHiddenStateAndRejectsMissingBlock() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny_text_encoder")
    let reader = try SafeTensorsReader(fileURL: root.appendingPathComponent("prompt_embeds.safetensors"))
    let ids = try reader.tensor(named: "input_ids").asType(.int32)
    let mask = try reader.tensor(named: "attention_mask").asType(.int32)
    let resident = try Flux2Qwen3TextEncoder.load(from: root, dtype: .float32)
    let layered = try Flux2Qwen3TextEncoder.loadLayered(from: root, dtype: .float32)
    XCTAssertThrowsError(try Flux2Qwen3TextEncoder.loadLayered(from: root, dtype: .bfloat16))
    let expected = try resident.promptEmbeds(inputIds: ids, attentionMask: mask, hiddenStateLayers: [0, 1, 2])
    let actual = try layered.promptEmbeds(inputIds: ids, attentionMask: mask, hiddenStateLayers: [0, 1, 2])
    TestHelpers.assertAllClose(actual, expected, atol: 1e-4, rtol: 1e-3)

    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let encoderDirectory = temporary.appendingPathComponent("text_encoder")
    try FileManager.default.createDirectory(at: encoderDirectory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("text_encoder/config.json"),
      to: encoderDirectory.appendingPathComponent("config.json"))
    var weights = try Flux2WeightsLoader(snapshot: root).load(component: .textEncoder, dtype: .float32)
    weights.removeValue(forKey: "model.layers.1.self_attn.q_proj.weight")
    try MLX.save(arrays: weights, metadata: [:], url: encoderDirectory.appendingPathComponent("model.safetensors"))
    let incomplete = try Flux2Qwen3TextEncoder.loadLayered(from: temporary, dtype: .float32)
    XCTAssertThrowsError(try incomplete.promptEmbeds(inputIds: ids, attentionMask: mask, hiddenStateLayers: [0, 1, 2]))
  }

  func testBF16LayeredKeepsAllHiddenStatesExactlyAtSameEvaluationPoints() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny_text_encoder")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let component = temporary.appendingPathComponent("text_encoder")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("text_encoder/config.json"),
      to: component.appendingPathComponent("config.json"))
    let sourceWeights = try Flux2WeightsLoader(snapshot: root).load(component: .textEncoder, dtype: .float32)
    let bf16 = sourceWeights.mapValues { $0.asType(.bfloat16) }
    MLX.eval(Array(bf16.values))
    try MLX.save(arrays: bf16, metadata: [:], url: component.appendingPathComponent("model.safetensors"))

    let reader = try SafeTensorsReader(fileURL: root.appendingPathComponent("prompt_embeds.safetensors"))
    let ids = try reader.tensor(named: "input_ids").asType(.int32)
    let mask = try reader.tensor(named: "attention_mask").asType(.int32)
    let resident = try Flux2Qwen3TextEncoder.load(from: temporary, dtype: .bfloat16)
    let layered = try Flux2Qwen3TextEncoder.loadLayered(from: temporary, dtype: .bfloat16)
    let selected = [0, 1, 2]
    let expected = try resident.promptEmbeds(inputIds: ids, attentionMask: mask,
      hiddenStateLayers: selected, evaluationPolicy: .aggressive)
    let actual = try layered.promptEmbeds(inputIds: ids, attentionMask: mask,
      hiddenStateLayers: selected, evaluationPolicy: .aggressive)
    MLX.eval(expected, actual)
    XCTAssertEqual(actual.dtype, .bfloat16)
    XCTAssertEqual(actual.shape, expected.shape)
    XCTAssertEqual(actual.asType(.float32).asArray(Float32.self),
                   expected.asType(.float32).asArray(Float32.self))
  }
}
