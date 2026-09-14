import DInference
@testable import DMLXBackend
import Foundation
import MLXLMCommon
import Tokenizers
import Testing

@Suite("Text stream exact Unicode delivery")
struct IncrementalTextDecoderTests {
    @Test("Scalar extensions never disappear", arguments: [
        ["e", "e\u{0301}", "e\u{0301}!"],
        ["👩", "👩\u{200D}", "👩\u{200D}💻", "👩\u{200D}💻。"],
        ["👍", "👍🏽", "👍🏽好"],
        ["🇯", "🇯🇵", "🇯🇵!"],
        ["A", "A\r", "A\r\n", "A\r\n中", "A\r\n中文"]
    ])
    func scalarExtensions(prefixes: [String]) throws {
        var decoder = IncrementalTextDecoder()
        var joined = ""
        for prefix in prefixes { joined += try decoder.consume(prefix) ?? "" }
        joined += try decoder.consume(prefixes.last!, final: true) ?? ""
        #expect(Array(joined.utf8) == Array(prefixes.last!.utf8))
    }

    @Test("Incomplete UTF-8 is held until a complete decoding exists")
    func incompleteBytes() throws {
        var decoder = IncrementalTextDecoder()
        #expect(try decoder.consume("A") == "A")
        #expect(try decoder.consume("A\u{fffd}") == nil)
        #expect(try decoder.consume("A\u{fffd}\u{fffd}") == nil)
        #expect(try decoder.consume("A中") == "中")
        #expect(try decoder.consume("A中", final: true) == nil)
    }

    @Test("Final tokenizer replacement is delivered, not silently omitted")
    func finalReplacement() throws {
        var decoder = IncrementalTextDecoder()
        #expect(try decoder.consume("中") == "中")
        #expect(try decoder.consume("中\u{fffd}") == nil)
        #expect(try decoder.consume("中\u{fffd}", final: true) == "\u{fffd}")
        #expect(try decoder.consume("中\u{fffd}", final: true) == nil)
    }

    @Test("Decoded prefix rewrite fails, including canonical-equivalent normalization", arguments: [
        ["AB", "A"], ["AB", "AC"], ["é", "e\u{0301}"], ["e\u{0301}", "é"]
    ])
    func prefixRewrite(prefixes: [String]) throws {
        var decoder = IncrementalTextDecoder()
        _ = try decoder.consume(prefixes[0])
        #expect(throws: InferenceFailure.self) { try decoder.consume(prefixes[1], final: true) }
        // A rejected prefix never changes the previously delivered history.
        #expect(try decoder.consume(prefixes[0] + "!", final: true) == "!")
    }

    @Test("Empty and repeated output does not duplicate text")
    func emptyAndRepeated() throws {
        var decoder = IncrementalTextDecoder()
        #expect(try decoder.consume("") == nil)
        #expect(try decoder.consume("原文") == "原文")
        #expect(try decoder.consume("原文") == nil)
        #expect(try decoder.consume("原文", final: true) == nil)
    }
    @Test("Fixed local tokenizer delivers the whole Unicode text without loading weights")
    func actualTokenizerRoundtrip() async throws {
        let tokenizer = try await AutoTokenizer.from(modelFolder: realModelDirectory())
        for text in ["Cafe\u{0301} 👩‍💻 👍🏽 🇯🇵", "第一行\r\n第二行\n第三行", "甲 < 乙，原文保持", "replacement: \u{fffd}"] {
            let tokens = tokenizer.encode(text: text, addSpecialTokens: false)
            let full = tokenizer.decode(tokens: tokens)
            #expect(Array(full.utf8) == Array(text.utf8))
            var decoder = IncrementalTextDecoder()
            var joined = ""
            for end in 1...tokens.count {
                joined += try decoder.consume(tokenizer.decode(tokens: Array(tokens.prefix(end)))) ?? ""
            }
            joined += try decoder.consume(full, final: true) ?? ""
            #expect(Array(joined.utf8) == Array(full.utf8))
        }
    }

    @Test("Decoder retains ordinary text through the same SDK tool processor")
    func ordinaryToolPipeline() throws {
        let parts = ["甲 ", "<", " 乙 e", "\u{0301}", " 👩", "\u{200d}", "💻", "。"]
        var decoder = IncrementalTextDecoder()
        let processor = ToolCallProcessor(format: .json)
        var prefix = "", output = ""
        for part in parts {
            prefix += part
            if let delta = try decoder.consume(prefix) { output += processor.processChunk(delta) ?? "" }
        }
        if let delta = try decoder.consume(prefix, final: true) { output += processor.processChunk(delta) ?? "" }
        #expect(Array(output.utf8) == Array(prefix.utf8))
        #expect(processor.toolCalls.isEmpty)
    }

    @Test("A split complete tool call remains detectable; no tool is invoked")
    func splitToolCall() throws {
        let parts = ["<tool", "_call>", #"{"name":"fixture","arguments":{}}"#, "</tool", "_call>"]
        var decoder = IncrementalTextDecoder()
        let processor = ToolCallProcessor(format: .json)
        var prefix = "", output = ""
        for part in parts {
            prefix += part
            if let delta = try decoder.consume(prefix) { output += processor.processChunk(delta) ?? "" }
        }
        #expect(processor.toolCalls.count == 1)
        #expect(processor.toolCalls.first?.function.name == "fixture")
        #expect(output.isEmpty)
    }

    @Test("Unclosed tool prefix remains an upstream buffering limitation")
    func incompleteToolTailLimitation() throws {
        var decoder = IncrementalTextDecoder()
        let processor = ToolCallProcessor(format: .json)
        let pending = try decoder.consume("<tool")
        let delta = try #require(pending)
        #expect(processor.processChunk(delta) == nil)
        #expect(try decoder.consume("<tool", final: true) == nil)
        #expect(processor.toolCalls.isEmpty)
        // The SDK exposes no tail flush. This preserves its prior behavior, not a
        // promise that literal incomplete tool markup is faithfully delivered.
    }

}
