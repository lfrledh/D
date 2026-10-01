import DInference
import Foundation
import Testing
@testable import DMLXBackend

@Suite("Qwen incremental final-body stream")
struct QwenResponseStreamTests {
    private let open = 10_001
    private let close = 10_002

    private var tool: TextToolDefinition {
        TextToolDefinition(name: "sum", description: "Sum", parameters: [
            "type": .string("object"),
            "properties": .object([
                "value": .object(["type": .string("integer")]),
                "payload": .object(["type": .string("object"), "properties": .object([
                    "items": .object(["type": .string("array"), "items": .object(["type": .string("integer")])])
                ])])
            ]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false)
        ])
    }

    private struct Feed {
        var stream: QwenResponseStream
        var pieces = [Int: String]()
        var tokens = [Int]()
        var output = ""
        var deltas = [String]()
        var next = 1

        init(thinking: Bool, tools: [TextToolDefinition]? = nil) {
            stream = QwenResponseStream(openID: 10_001, closeID: 10_002,
                                        thinking: thinking, tools: tools)
            pieces[10_001] = "<think>"
            pieces[10_002] = "</think>"
        }

        mutating func text(_ value: String) throws {
            let id = next
            next += 1
            pieces[id] = value
            try token(id)
        }

        mutating func scalarTokens(_ value: String) throws {
            for scalar in value.unicodeScalars { try text(String(scalar)) }
        }

        mutating func token(_ id: Int) throws {
            tokens.append(id)
            let table = pieces
            if let delta = try stream.accept(id, decode: { ids in ids.map { table[$0]! }.joined() }) {
                output += delta
                deltas.append(delta)
            }
        }

        mutating func finish(tools: [TextToolDefinition]? = nil) throws -> TextResponse {
            let raw = tokens.map { pieces[$0]! }.joined()
            let table = pieces
            let result = try stream.finish(raw: raw, stopped: "stop", tools: tools, runID: nil,
                                           decode: { ids in ids.map { table[$0]! }.joined() })
            if let delta = result.delta {
                output += delta
                deltas.append(delta)
            }
            return result.response
        }
    }

    @Test func earlyDeltaAndThinkingModes() throws {
        var enabled = Feed(thinking: true)
        try enabled.text("private thought")
        #expect(enabled.output.isEmpty)
        try enabled.token(close)
        try enabled.text("early 中文")
        #expect(enabled.output == "early 中文") // Before completion exists.
        try enabled.text(" done")
        let response = try enabled.finish()
        #expect(response.reasoningText == "private thought")
        #expect(response.finalText == enabled.output)
        #expect(response.rawText == "private thought</think>early 中文 done")

        var disabled = Feed(thinking: false)
        try disabled.text("immediate")
        #expect(disabled.output == "immediate")
        #expect(try disabled.finish().finalText == "immediate")
    }

    @Test func channelMisuseStaysIncomplete() throws {
        var late = Feed(thinking: false)
        try late.text("preview")
        try late.token(open)
        try late.text("secret")
        try late.token(close)
        #expect(try late.finish().finishReason == .incomplete)
        #expect(late.output == "preview")

        var duplicate = Feed(thinking: true)
        try duplicate.token(close)
        try duplicate.token(close)
        try duplicate.text("body")
        #expect(try duplicate.finish().finishReason == .incomplete)

        var unclosed = Feed(thinking: true)
        try unclosed.text("thought")
        #expect(try unclosed.finish().finishReason == .incomplete)
        #expect(unclosed.output.isEmpty)
    }

    @Test func invalidCloseStopsLaterTransientBodyAndRetainsRaw() throws {
        var feed = Feed(thinking: false)
        try feed.text("before")
        try feed.token(close)
        try feed.text("after")
        #expect(feed.output == "before")
        let response = try feed.finish()
        #expect(feed.output == "before")
        #expect(response.finalText == nil)
        #expect(response.finishReason == .incomplete)
        #expect(response.rawText == "before</think>after")

        var initialClose = Feed(thinking: false)
        try initialClose.token(close)
        try initialClose.text("private after invalid channel")
        let initialResponse = try initialClose.finish()
        #expect(initialClose.output.isEmpty)
        #expect(initialResponse.rawText == "</think>private after invalid channel")
        #expect(initialResponse.finishReason == .incomplete)
    }

    @Test func everyDelimiterSplitHoldsMarkup() throws {
        let markers = ["<tool_call>", "</tool_call>", "<function=sum>", "</function>",
                       "<parameter=value>", "</parameter>", "<think>", "</think>"]
        for marker in markers {
            for split in 1..<marker.count {
                var feed = Feed(thinking: false)
                try feed.text("before ")
                try feed.text(String(marker.prefix(split)))
                #expect(feed.output == "before ")
                try feed.text(String(marker.dropFirst(split)))
                try feed.text("private arguments")
                #expect(feed.output == "before ")
                let response = try feed.finish()
                #expect(response.finishReason == .incomplete)
                #expect(feed.output == "before ")
            }
        }
    }

    @Test func validCallsKeepArgumentsPrivateAndFinalTextExact() throws {
        let call = "<tool_call><function=sum><parameter=value>2</parameter>" +
            "<parameter=payload>{\"items\":[1,2,{\"deep\":[3]}]}</parameter></function></tool_call>"
        // The nested object does not match the declared array item schema.
        var malformed = Feed(thinking: false, tools: [tool])
        try malformed.text("first ")
        try malformed.scalarTokens(call)
        try malformed.text(" later")
        #expect(malformed.output == "first ")
        #expect(try malformed.finish(tools: [tool]).finishReason == .incomplete)

        let valid = "<tool_call><function=sum><parameter=value>2</parameter>" +
            "<parameter=payload>{\"items\":[1,2,3]}</parameter></function></tool_call>"
        var feed = Feed(thinking: false, tools: [tool])
        try feed.text("first ")
        #expect(feed.output == "first ")
        try feed.scalarTokens(valid)
        #expect(feed.output == "first ")
        try feed.text(" between ")
        #expect(feed.output == "first  between ") // The producer is still active.
        try feed.scalarTokens(valid)
        try feed.text(" tail")
        #expect(feed.output == "first  between  tail") // Before producer completion.
        let response = try feed.finish(tools: [tool])
        #expect(response.finishReason == .toolCalls)
        #expect(response.toolCalls.count == 2)
        #expect(response.finalText == "first  between  tail")
        #expect(feed.output == response.finalText)
        #expect(feed.deltas.joined() == response.finalText)
        #expect(feed.deltas.filter { $0.contains("<") }.isEmpty)
    }

    @Test func trailingMalformedToolCannotBecomeFinalText() throws {
        var feed = Feed(thinking: false)
        try feed.text("transient body ")
        try feed.scalarTokens("<tool_call><function=sum><parameter=value>2")
        #expect(feed.output == "transient body ")
        let response = try feed.finish(tools: [tool])
        #expect(response.finalText == nil)
        #expect(response.finishReason == .incomplete)
        #expect(response.rawText.hasSuffix("<parameter=value>2"))
    }

    @Test func successfulFinishReleasesOrdinaryDelimiterStemsExactlyOnce() throws {
        for body in ["2 <", "2 <t", "<thinking>"] {
            var feed = Feed(thinking: false)
            try feed.scalarTokens(body)
            let response = try feed.finish()
            #expect(response.finalText == body)
            #expect(feed.output == body)
            #expect(feed.deltas.joined() == body)
            #expect(try feed.finish().finalText == body)
            #expect(feed.output == body)
        }
    }

    @Test func completeToolThenUnicodeAndOrdinaryStemHasNoDuplicate() throws {
        let call = "<tool_call><function=sum><parameter=value>2</parameter></function></tool_call>"
        let suffix = " 中文 👩\u{200D}💻 <thinking>"
        var feed = Feed(thinking: false, tools: [tool])
        try feed.scalarTokens(call)
        try feed.scalarTokens(suffix)
        let response = try feed.finish(tools: [tool])
        #expect(response.finishReason == .toolCalls)
        #expect(response.toolCalls.count == 1)
        #expect(response.finalText == suffix)
        #expect(feed.output == suffix)
        #expect(feed.deltas.joined() == suffix)
        #expect(!feed.output.contains("<tool_call>"))
    }

    @Test func unicodeAndReplacementRemainByteExact() throws {
        let text = "中文 e\u{0301} 👩\u{200D}💻 \u{fffd}"
        var feed = Feed(thinking: false)
        try feed.scalarTokens(text)
        let response = try feed.finish()
        #expect(Array(feed.output.utf8) == Array(text.utf8))
        #expect(response.finalText == text)
    }
}
