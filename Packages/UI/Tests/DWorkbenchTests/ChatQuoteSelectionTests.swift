import CryptoKit
import Foundation
import Testing
@testable import DWorkbench

struct ChatQuoteSelectionTests {
    private let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!

    private func source(_ text: String, kind: ChatQuoteSource.Kind = .message,
                        version: String = "v1") throws -> ChatQuoteSource {
        try ChatQuoteSource(kind: kind, id: id, version: version, text: text)
    }

    @Test func exactUTF8DigestAndCharacterAlignedUTF16Ranges() throws {
        let raw = "中文👩‍👩‍👧‍👦 Cafe e\u{301}\r\n"
        let value = try source(raw)
        #expect(value.sha256 == SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }.joined())
        #expect(value.text == raw)

        for piece in ["中文", "👩‍👩‍👧‍👦", "e\u{301}", "\r\n"] {
            let nativeRange = (raw as NSString).range(of: piece)
            let selection = try ChatQuoteSelection(source: value, range: nativeRange)
            #expect(selection.range == nativeRange)
            #expect(selection.text == piece)
            try selection.validate(against: value)
            let decoded = try JSONDecoder().decode(ChatQuoteSelection.self,
                                                    from: JSONEncoder().encode(selection))
            #expect(decoded == selection)
        }

        let composed = try source("é")
        let decomposed = try source("e\u{301}")
        #expect(composed.sha256 != decomposed.sha256)
    }

    @Test func rejectsCollapsedClippedNegativeOverflowAndCharacterSplits() throws {
        let value = try source("A👩‍💻e\u{301}Z")
        let total = value.text.utf16.count
        let invalid = [
            NSRange(location: 0, length: 0),
            NSRange(location: -1, length: 1),
            NSRange(location: NSNotFound, length: 1),
            NSRange(location: total, length: 1),
            NSRange(location: total - 1, length: 2),
            NSRange(location: Int.max - 1, length: Int.max),
            NSRange(location: 2, length: 1), // Inside the emoji's surrogate pair.
            NSRange(location: 1, length: 2), // Clips the emoji grapheme.
            NSRange(location: 6, length: 1)  // Clips the combining grapheme.
        ]
        for range in invalid {
            #expect(throws: ChatQuoteSelectionError.invalidRange) {
                try ChatQuoteSelection(source: value, range: range)
            }
        }
    }

    @Test func budgetsUseExactUTF8Bytes() throws {
        let maximum = try source(String(repeating: "a", count: ChatQuoteSource.maximumUTF8Bytes))
        #expect(maximum.text.utf8.count == ChatQuoteSource.maximumUTF8Bytes)
        #expect(throws: ChatQuoteSelectionError.sourceTooLarge) {
            try source(String(repeating: "a", count: ChatQuoteSource.maximumUTF8Bytes + 1))
        }
        let selected = try ChatQuoteSelection(
            source: maximum,
            range: NSRange(location: 0, length: ChatQuoteSelection.maximumUTF8Bytes))
        #expect(selected.text.utf8.count == ChatQuoteSelection.maximumUTF8Bytes)
        #expect(throws: ChatQuoteSelectionError.selectionTooLarge) {
            try ChatQuoteSelection(source: maximum,
                                   range: NSRange(location: 0,
                                                  length: ChatQuoteSelection.maximumUTF8Bytes + 1))
        }
        let multibyte = try source(String(repeating: "界", count: 22_000))
        #expect(throws: ChatQuoteSelectionError.selectionTooLarge) {
            try ChatQuoteSelection(source: multibyte,
                                   range: NSRange(location: 0, length: multibyte.text.utf16.count))
        }
    }

    @Test func rejectsIdentityDigestRangeAndTextDrift() throws {
        let original = try source("hello world")
        let quote = try ChatQuoteSelection(source: original, range: NSRange(location: 6, length: 5))
        let changedID = try ChatQuoteSource(kind: .message, id: UUID(), version: "v1", text: original.text)
        let changedKind = try source(original.text, kind: .document)
        let changedVersion = try source(original.text, version: "v2")
        let changedText = try source("hello earth")
        for replacement in [changedID, changedKind, changedVersion, changedText] {
            #expect(throws: ChatQuoteSelectionError.sourceChanged) {
                try quote.validate(against: replacement)
            }
        }

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(quote))
                                  as? [String: Any])
        object["text"] = "earth"
        let alteredText = try JSONDecoder().decode(ChatQuoteSelection.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: ChatQuoteSelectionError.sourceChanged) {
            try alteredText.validate(against: original)
        }
        object["text"] = "world"
        object["utf16Location"] = 99
        let alteredRange = try JSONDecoder().decode(ChatQuoteSelection.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: ChatQuoteSelectionError.sourceChanged) {
            try alteredRange.validate(against: original)
        }
    }

    @Test func decodedSourceRejectsForgedDigestAndOversize() throws {
        let original = try source("hello")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
                                  as? [String: Any])
        object["text"] = "changed"
        #expect(throws: ChatQuoteSelectionError.sourceChanged) {
            try JSONDecoder().decode(ChatQuoteSource.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        object["text"] = String(repeating: "a", count: ChatQuoteSource.maximumUTF8Bytes + 1)
        #expect(throws: ChatQuoteSelectionError.sourceTooLarge) {
            try JSONDecoder().decode(ChatQuoteSource.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
    }
}
