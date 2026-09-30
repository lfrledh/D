import DInference
import Foundation
import Testing
@testable import DMLXBackend

@Suite("Qwen3.5 conversation mapping and output")
struct QwenConversationTests {
    @Test func successiveToolOutputsHaveDistinctStableConversationIDs() throws {
        let xml = "<tool_call><function=sum><parameter=value>2</parameter><parameter=ok>true</parameter></function></tool_call>"
        let firstID = UUID(), secondID = UUID()
        func response(_ id: UUID) -> TextResponse {
            QwenTextResponse.assemble(raw: xml, reasoning: nil, final: xml, stopped: "stop", tools: [tool], runID: id)
        }
        let first = try #require(response(firstID).toolCalls.first)
        let second = try #require(response(secondID).toolCalls.first)
        #expect(first.id != second.id && response(firstID).toolCalls.first?.id == first.id)
        let request = TextRequest(prompt: "", messages: [
            .init(role: .user, parts: [.text("Add")]),
            .init(role: .assistant, parts: [], toolCalls: [first]),
            .init(role: .tool, parts: [.text("3")], toolCallID: first.id),
            .init(role: .user, parts: [.text("Again")]),
            .init(role: .assistant, parts: [], toolCalls: [second]),
            .init(role: .tool, parts: [.text("3")], toolCallID: second.id)
        ], tools: [tool])
        try request.validateConversation()
    }
    @Test func longReasoningDoesNotInvalidateCompletedShortAnswer() {
        let reasoning = String(repeating: "x", count: 2 * 1_048_576)
        let response = QwenTextResponse.assemble(raw: reasoning + "ok", reasoning: reasoning,
            final: "ok", stopped: "stop", tools: nil)
        #expect(response.rawText == reasoning + "ok" && response.reasoningText == reasoning)
        #expect(response.finalText == "ok" && response.finishReason == .stop)
    }
    private let tool = TextToolDefinition(name: "sum", description: "Add values", parameters: [
        "type": .string("object"),
        "properties": .object([
            "value": .object(["type": .string("number")]),
            "ok": .object(["type": .string("boolean")]),
            "items": .object(["type": .string("array"), "items": .object(["type": .string("integer")])])
        ]), "required": .array([.string("value"), .string("ok")]),
        "additionalProperties": .bool(false)])

    @Test func modelSpecificThinkingControls() throws {
        #expect(try QwenMessageMapping.context(for: nil, modelSize: "9B").isEmpty)
        let disabled = try QwenMessageMapping.context(for: .init(enableThinking: false), modelSize: "9B")
        #expect(disabled["enable_thinking"] as? Bool == false)
        #expect(throws: (any Error).self) {
            try QwenMessageMapping.context(for: .init(reasoningEffort: .medium), modelSize: "9B")
        }
        #expect(throws: (any Error).self) {
            try QwenMessageMapping.context(for: .init(enableThinking: false, reasoningEffort: .low), modelSize: "27B")
        }
        let context = try QwenMessageMapping.context(for: .init(enableThinking: true,
            reasoningEffort: .xhigh, preserveThinking: true), modelSize: "27B")
        #expect(context["reasoning_effort"] as? String == "xhigh")
        #expect(context["preserve_thinking"] as? Bool == true)
    }

    @Test func orderedPartsAndToolIDsMapIntoNativeMessages() {
        let image = TextImageReference(url: URL(fileURLWithPath: "/tmp/a.png"), width: 1, height: 1,
            byteCount: 1, contentSHA256: String(repeating: "a", count: 64))
        let video = TextVideoReference(url: URL(fileURLWithPath: "/tmp/a.mp4"), byteCount: 1,
            contentSHA256: String(repeating: "b", count: 64), durationSeconds: 1)
        let call = TextToolCall(id: "call_0", name: "sum", arguments: ["value": .int(2), "ok": .bool(true)])
        let request = TextRequest(prompt: "", messages: [
            .init(role: .user, parts: [.text("a"), .video(video), .image(image), .video(video)]),
            .init(role: .assistant, parts: [.text("calling")], reasoningContent: "thought", toolCalls: [call]),
            .init(role: .tool, parts: [.text("2")], toolCallID: "call_0")], tools: [tool])
        let mapped = QwenMessageMapping.messages(request)
        let parts = mapped[0]["content"] as? [[String: any Sendable]]
        #expect(parts?.compactMap { $0["type"] as? String } == ["text", "video", "image", "video"])
        #expect(mapped[1]["reasoning_content"] as? String == "thought")
        let calls = mapped[1]["tool_calls"] as? [[String: any Sendable]]
        #expect(calls?.first?["id"] as? String == "call_0")
        #expect(mapped[2]["tool_call_id"] as? String == "call_0")
    }

    @Test func nativeToolResultsRequireCallOrder() throws {
        let calls = [
            TextToolCall(id: "call_a", name: "sum", arguments: ["value": .int(1), "ok": .bool(true)]),
            TextToolCall(id: "call_b", name: "sum", arguments: ["value": .int(2), "ok": .bool(false)])
        ]
        let prefix: [TextMessage] = [
            .init(role: .user, parts: [.text("add both")]),
            .init(role: .assistant, parts: [], toolCalls: calls)
        ]
        let first = TextMessage(role: .tool, parts: [.text("result A")], toolCallID: "call_a")
        let second = TextMessage(role: .tool, parts: [.text("result B")], toolCallID: "call_b")
        let ordered = TextRequest(prompt: "", messages: prefix + [first, second], tools: [tool])
        try ordered.validateConversation()
        let mapped = QwenMessageMapping.messages(ordered)
        let nativeCalls = mapped[1]["tool_calls"] as? [[String: any Sendable]]
        #expect(nativeCalls?.compactMap { $0["id"] as? String } == ["call_a", "call_b"])
        #expect(mapped[2]["tool_call_id"] as? String == "call_a")
        #expect(mapped[3]["tool_call_id"] as? String == "call_b")
        let reversed = TextRequest(prompt: "", messages: prefix + [second, first], tools: [tool])
        #expect(throws: InferenceFailure.invalidRequest("Tool results must answer pending calls in order by ID.")) {
            try reversed.validateConversation()
        }
        #expect(throws: (any Error).self) {
            try TextRequest(prompt: "", messages: prefix + [first, first], tools: [tool]).validateConversation()
        }
        #expect(throws: (any Error).self) {
            try TextRequest(prompt: "", messages: prefix + [first], tools: [tool]).validateConversation()
        }
    }

    @Test func completeTwoCallsAndFinalOnlyText() {
        let xml = """
        Before <tool_call>\n<function=sum>\n<parameter=value>1e100</parameter>\n<parameter=ok>true</parameter>\n</function>\n</tool_call>
        <tool_call><function=sum><parameter=value>2</parameter><parameter=ok>false</parameter></function></tool_call>
        """
        let response = QwenTextResponse.assemble(raw: "thought" + xml, reasoning: "thought",
            final: xml, stopped: "stop", tools: [tool])
        #expect(response.finishReason == .toolCalls)
        #expect(response.finalText?.contains("Before") == true)
        #expect(response.toolCalls.map(\.id) == ["call_0", "call_1"])
        #expect(response.toolCalls[0].arguments["value"] == .double(1e100))
        #expect(response.toolCalls[1].arguments["ok"] == .bool(false))
    }

    @Test func malformedAndTruncatedCallsNeverBecomeFinal() {
        let cases = [
            "<tool_call><function=sum><parameter=value>nan</parameter><parameter=ok>true</parameter></function></tool_call>",
            "<tool_call><function=sum><parameter=value>inf</parameter><parameter=ok>true</parameter></function></tool_call>",
            "<tool_call><function=sum><parameter=value>1e999</parameter><parameter=ok>true</parameter></function></tool_call>",
            "<tool_call><function=sum><parameter=value>2</parameter><parameter=value>3</parameter></function></tool_call>",
            "<tool_call><function=sum><parameter=ok>maybe</parameter></function></tool_call>",
            "<tool_call><function=sum><parameter=value>2</parameter><parameter=ok>true</parameter><parameter=items>[1,2,3</parameter></function></tool_call>",
            "<tool_call><function=sum><parameter=value>2</parameter>",
            "<tool_call><function=sum><parameter=value>2</parameter></function>"
        ]
        for text in cases {
            let response = QwenTextResponse.assemble(raw: text, reasoning: nil, final: text, stopped: "stop", tools: [tool])
            #expect(response.finishReason == .incomplete)
            #expect(response.finalText == nil)
            #expect(response.rawText == text)
        }
        let thought = QwenTextResponse.assemble(raw: "<tool_call>inside thought", reasoning: "<tool_call>inside thought",
            final: "safe", stopped: "stop", tools: [tool])
        #expect(thought.finishReason == .stop && thought.toolCalls.isEmpty && thought.finalText == "safe")
        #expect(QwenTextResponse.assemble(raw: "unfinished", reasoning: "unfinished", final: nil,
            stopped: "length", tools: [tool]).finishReason == .incomplete)
        #expect(QwenTextResponse.assemble(raw: "partial", reasoning: nil, final: "partial", stopped: "length",
            tools: [tool]).finishReason == .length)
        let objectTool = TextToolDefinition(name: "nested", description: "Nested", parameters: [
            "type": .string("object"), "properties": .object([
                "payload": .object(["type": .string("object"), "properties": .object([
                    "n": .object(["type": .string("integer")])])])])])
        let duplicate = "<tool_call><function=nested><parameter=payload>{\"n\":1,\"n\":2}</parameter></function></tool_call>"
        #expect(QwenTextResponse.assemble(raw: duplicate, reasoning: nil, final: duplicate, stopped: "stop",
            tools: [objectTool]).finishReason == .incomplete)
    }
}
