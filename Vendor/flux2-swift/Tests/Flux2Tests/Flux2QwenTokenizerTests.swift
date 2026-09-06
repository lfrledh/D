import Foundation
import MLX
import XCTest
@testable import Flux2

final class Flux2QwenTokenizerTests: XCTestCase {
  private func fixtureTokenizer(maxLength: Int = 512) throws -> Flux2QwenTokenizer {
    let directory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_klein4b/tokenizer")
    return try Flux2QwenTokenizer.load(from: directory, maxLengthOverride: maxLength)
  }

  func testStrictEncodingReportsCompleteTokenCountAndPromptIndex() throws {
    let tokenizer = try fixtureTokenizer()
    let longPrompt = String(repeating: "orange cat sitting on a windowsill ", count: 20)
    let fullBatch = try tokenizer.encode(prompts: [longPrompt], truncation: false)
    let fullCount = fullBatch.attentionMask.asArray(Int32.self).reduce(0, +)
    XCTAssertGreaterThan(fullCount, 32)

    XCTAssertThrowsError(try tokenizer.encode(
      prompts: ["cat", longPrompt], maxLength: 32, truncation: false
    )) { error in
      guard case Flux2TokenizerError.promptTooLong(let index, let count, let limit) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(index, 1)
      XCTAssertEqual(count, Int(fullCount))
      XCTAssertEqual(limit, 32)
    }
  }

  func testStrictEncodingAcceptsExactBoundaryAndPreservesDefaultTruncation() throws {
    let tokenizer = try fixtureTokenizer(maxLength: 128)
    let prompt = "A fluffy orange cat sitting on a windowsill"
    let fullBatch = try tokenizer.encode(prompts: [prompt], truncation: false)
    let count = Int(fullBatch.attentionMask.asArray(Int32.self).reduce(0, +))
    XCTAssertGreaterThan(count, 1)
    let exact = try tokenizer.encode(prompts: [prompt], maxLength: count, truncation: false)
    XCTAssertEqual(exact.inputIds.shape, [1, count])
    XCTAssertEqual(exact.attentionMask.asArray(Int32.self), Array(repeating: 1, count: count))
    XCTAssertThrowsError(try tokenizer.encode(prompts: [prompt], maxLength: count - 1, truncation: false))

    let legacy = try tokenizer.encode(prompts: [prompt], maxLength: count - 1)
    let explicit = try tokenizer.encode(prompts: [prompt], maxLength: count - 1, truncation: true)
    let expected = Array(fullBatch.inputIds.asArray(Int32.self).prefix(count - 1))
    XCTAssertEqual(legacy.inputIds.asArray(Int32.self), expected)
    XCTAssertEqual(explicit.inputIds.asArray(Int32.self), expected)
  }

  func testStrictEncodingIncludesChatTemplateTokensInTheLimit() throws {
    let tokenizer = try fixtureTokenizer()
    XCTAssertThrowsError(try tokenizer.encode(prompts: [""], maxLength: 1, truncation: false)) { error in
      guard case Flux2TokenizerError.promptTooLong(let index, let count, let limit) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(index, 0)
      XCTAssertGreaterThan(count, 1)
      XCTAssertEqual(limit, 1)
    }
  }

  func testTokenizerLoadsAndEncodes() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures/flux2_klein4b")
    let tokenizerDir = fixtureRoot.appendingPathComponent("tokenizer")

    XCTAssertTrue(FileManager.default.fileExists(atPath: tokenizerDir.path))

    let maxLength = 128
    let tokenizer = try Flux2QwenTokenizer.load(from: tokenizerDir, maxLengthOverride: maxLength)
    let prompt = "A fluffy orange cat sitting on a windowsill"
    let batch = try tokenizer.encode(
      prompts: [prompt],
      maxLength: maxLength,
      addGenerationPrompt: true,
      enableThinking: false
    )

    XCTAssertEqual(batch.inputIds.shape, [1, maxLength])
    XCTAssertEqual(batch.attentionMask.shape, [1, maxLength])
    XCTAssertEqual(batch.inputIds.dtype, .int32)
    XCTAssertEqual(batch.attentionMask.dtype, .int32)

    let maskValues = batch.attentionMask.asArray(Int32.self)
    XCTAssertEqual(maskValues.count, maxLength)
    XCTAssertGreaterThan(maskValues.reduce(0, +), 0)
  }
}
