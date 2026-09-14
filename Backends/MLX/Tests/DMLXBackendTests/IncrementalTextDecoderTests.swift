import DInference
@testable import DMLXBackend
import Foundation
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
}
