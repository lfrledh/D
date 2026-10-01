import Foundation
import Darwin
import MLX
import XCTest
@testable import Flux2

final class Flux2Mistral3TextEncoderTests: XCTestCase {
  func testLayeredTextRejectsReplacementFromOriginalAdmission() throws {
    enum AdmissionError: Error { case changed }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny_mistral3_text_encoder/text_encoder")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let component = root.appendingPathComponent("text_encoder")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.copyItem(at: fixture.appendingPathComponent("config.json"),
      to: component.appendingPathComponent("config.json"))
    let file = component.appendingPathComponent("model.safetensors")
    try FileManager.default.copyItem(at: fixture.appendingPathComponent("model.safetensors"), to: file)
    var original = stat()
    XCTAssertEqual(Darwin.lstat(file.path, &original), 0)
    var bytes = try Data(contentsOf: file)
    bytes[bytes.count - 1] ^= 1 // Preserve the header, dtype, and length.
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
    XCTAssertThrowsError(try Flux2Mistral3TextEncoder.loadLayered(from: root, dtype: .float32,
      admissionValidator: validate)) { error in
      guard case AdmissionError.changed = error else {
        return XCTFail("Expected original admission failure, got \(error)")
      }
    }
    XCTAssertGreaterThan(validations, 0)
  }

  func testPromptEmbedsSmoke() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny_mistral3_text_encoder")
    let fixtureFile = fixtureRoot.appendingPathComponent("prompt_embeds.safetensors")

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureFile.path))

    let reader = try SafeTensorsReader(fileURL: fixtureFile)
    let inputIds = try reader.tensor(named: "input_ids").asType(.int32)
    let attentionMask = try reader.tensor(named: "attention_mask").asType(.int32)
    let expectedEmbeds = try reader.tensor(named: "prompt_embeds").asType(.float32)
    let expectedTextIds = try reader.tensor(named: "text_ids").asType(.int32)

    let encoder = try Flux2Mistral3TextEncoder.load(from: fixtureRoot, dtype: .float32)
    let actualEmbeds = try encoder.promptEmbeds(
      inputIds: inputIds,
      attentionMask: attentionMask,
      hiddenStateLayers: [0, 1, 2]
    )

    TestHelpers.assertAllClose(actualEmbeds, expectedEmbeds, atol: 1e-4, rtol: 1e-3)

    let batch = inputIds.dim(0)
    XCTAssertEqual(actualEmbeds.dim(0), batch)
    XCTAssertEqual(actualEmbeds.ndim, 3)

    let actualTextIds = try Flux2PositionIds.prepareTextIds(actualEmbeds)
    XCTAssertEqual(actualTextIds.dim(0), batch)
    XCTAssertEqual(actualTextIds.ndim, 3)
    XCTAssertEqual(actualTextIds.asType(.int32).asArray(Int32.self), expectedTextIds.asArray(Int32.self))

    let embedValues = actualEmbeds.asType(.float32).asArray(Float32.self)
    XCTAssertFalse(embedValues.isEmpty)
    XCTAssertFalse(embedValues.contains { !$0.isFinite })
  }

  func testLoadsLanguageModelModelPrefixWeights() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny_mistral3_text_encoder")
    let fixtureFile = fixtureRoot.appendingPathComponent("prompt_embeds.safetensors")
    let sourceWeightsURL = fixtureRoot.appendingPathComponent("text_encoder/model.safetensors")
    let sourceConfigURL = fixtureRoot.appendingPathComponent("text_encoder/config.json")

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let tempTextEncoderDir = tempDir.appendingPathComponent("text_encoder")
    try FileManager.default.createDirectory(at: tempTextEncoderDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.copyItem(
      at: sourceConfigURL,
      to: tempTextEncoderDir.appendingPathComponent("config.json")
    )

    let weightsReader = try SafeTensorsReader(fileURL: sourceWeightsURL)
    let sourceWeights = try weightsReader.loadAllTensors(as: .float32)
    var renamedWeights: [String: MLXArray] = [:]
    for (name, tensor) in sourceWeights {
      guard name.hasPrefix("model.language_model.") else { continue }
      let suffix = name.dropFirst("model.language_model.".count)
      renamedWeights["language_model.model.\(suffix)"] = tensor
    }

    try MLX.save(
      arrays: renamedWeights,
      metadata: [:],
      url: tempTextEncoderDir.appendingPathComponent("model.safetensors")
    )

    let reader = try SafeTensorsReader(fileURL: fixtureFile)
    let inputIds = try reader.tensor(named: "input_ids").asType(.int32)
    let attentionMask = try reader.tensor(named: "attention_mask").asType(.int32)
    let expectedEmbeds = try reader.tensor(named: "prompt_embeds").asType(.float32)
    let expectedTextIds = try reader.tensor(named: "text_ids").asType(.int32)

    let encoder = try Flux2Mistral3TextEncoder.load(from: tempDir, dtype: .float32)
    let actualEmbeds = try encoder.promptEmbeds(
      inputIds: inputIds,
      attentionMask: attentionMask,
      hiddenStateLayers: [0, 1, 2]
    )

    TestHelpers.assertAllClose(actualEmbeds, expectedEmbeds, atol: 1e-4, rtol: 1e-3)

    let batch = inputIds.dim(0)
    XCTAssertEqual(actualEmbeds.dim(0), batch)
    XCTAssertEqual(actualEmbeds.ndim, 3)

    let actualTextIds = try Flux2PositionIds.prepareTextIds(actualEmbeds)
    XCTAssertEqual(actualTextIds.asType(.int32).asArray(Int32.self), expectedTextIds.asArray(Int32.self))

    let values = actualEmbeds.asType(.float32).asArray(Float32.self)
    XCTAssertFalse(values.isEmpty)
    XCTAssertFalse(values.contains { !$0.isFinite })
  }

  func testLayeredPromptMatchesIndependentOriginalFixtureAndRejectsGeneration() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny_mistral3_text_encoder")
    let reader = try SafeTensorsReader(fileURL: root.appendingPathComponent("prompt_embeds.safetensors"))
    let input = try reader.tensor(named: "input_ids").asType(.int32)
    let mask = try reader.tensor(named: "attention_mask").asType(.int32)
    let expected = try reader.tensor(named: "prompt_embeds").asType(.float32)
    let layered = try Flux2Mistral3TextEncoder.loadLayered(from: root, dtype: .float32)
    let actual = try layered.promptEmbeds(inputIds: input, attentionMask: mask,
                                          hiddenStateLayers: [0, 1, 2])
    TestHelpers.assertAllClose(actual, expected, atol: 1e-4, rtol: 1e-3)
    XCTAssertThrowsError(try layered.generateTokenIds(inputIds: input, maxNewTokens: 1)) { error in
      guard case Flux2Mistral3TextEncoderError.layeredGenerationUnavailable = error else {
        return XCTFail("Expected explicit layered generation rejection, got \(error)")
      }
    }
  }

  func testLayeredPromptRequiresCompleteBlockAndStopsOnCancellation() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_tiny_mistral3_text_encoder")
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let component = target.appendingPathComponent("text_encoder")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: target) }
    try FileManager.default.copyItem(at: root.appendingPathComponent("text_encoder/config.json"),
                                     to: component.appendingPathComponent("config.json"))
    let original = try SafeTensorsReader(fileURL: root.appendingPathComponent("text_encoder/model.safetensors"))
    var weights = try original.loadAllTensors(as: .float32)
    weights.removeValue(forKey: "model.language_model.layers.0.self_attn.q_proj.weight")
    try MLX.save(arrays: weights, metadata: [:], url: component.appendingPathComponent("model.safetensors"))
    let inputs = try SafeTensorsReader(fileURL: root.appendingPathComponent("prompt_embeds.safetensors"))
    let input = try inputs.tensor(named: "input_ids").asType(.int32)
    let mask = try inputs.tensor(named: "attention_mask").asType(.int32)
    let incomplete = try Flux2Mistral3TextEncoder.loadLayered(from: target, dtype: .float32)
    XCTAssertThrowsError(try incomplete.promptEmbeds(inputIds: input, attentionMask: mask,
                                                       hiddenStateLayers: [0, 1, 2]))

    let complete = try Flux2Mistral3TextEncoder.loadLayered(from: root, dtype: .float32)
    let cancelled = await Task { () -> Bool in
      withUnsafeCurrentTask { $0?.cancel() }
      do { _ = try complete.promptEmbeds(inputIds: input, attentionMask: mask); return false }
      catch is CancellationError { return true }
      catch { return false }
    }.value
    XCTAssertTrue(cancelled)
  }
}
