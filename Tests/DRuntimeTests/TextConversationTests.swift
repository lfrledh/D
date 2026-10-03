import DInference
import Foundation
import Testing

@Suite("Typed text conversation")
struct TextConversationTests {
    private let vlm = TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 256,
                                              profile: TextExecutionCapability.qwen35VLMProfile)

    @Test func oldRequestAndResultDecodeWithoutNewKeys() throws {
        let old = Data(#"{"prompt":"old","maxTokens":8,"temperature":0.7,"topP":0.95,"execution":null,"images":null,"video":null,"visualProcessing":null}"#.utf8)
        let request = try JSONDecoder().decode(TextRequest.self, from: old)
        #expect(request.messages == nil && request.tools == nil && request.thinking == nil && request.seed == nil)
        #expect(request.chatTemplateOverride == nil)
        #expect(!(String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            .contains("chatTemplateOverride")))
        #expect(try JSONDecoder().decode(TextRequest.self, from: JSONEncoder().encode(request)) == request)
        let result = try JSONDecoder().decode(InferenceResult.self,
            from: Data(#"{"artifacts":[],"metadata":{"stopReason":"stop"}}"#.utf8))
        #expect(result.textResponse == nil)
    }

    @Test func requestTemplateValidationAndRoundtrip() throws {
        let source = "{% for message in messages %}{{ message.role }}{% endfor %}"
        let request = TextRequest(prompt: "hello", chatTemplateOverride: source)
        try vlm.validate(request)
        #expect(try JSONDecoder().decode(TextRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(throws: (any Error).self) {
            try TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 256)
                .validate(request)
        }
        #expect(throws: (any Error).self) {
            try vlm.validate(TextRequest(prompt: "hello", chatTemplateOverride: " \n "))
        }
        #expect(throws: (any Error).self) {
            try vlm.validate(TextRequest(prompt: "hello",
                chatTemplateOverride: String(repeating: "é", count: 32_769)))
        }
    }

    @Test func mediaOrderAndTwoVideosStayVisible() throws {
        let image = TextImageReference(url: URL(fileURLWithPath: "/tmp/a.png"), width: 1, height: 1,
                                       byteCount: 1, contentSHA256: String(repeating: "a", count: 64))
        let video = TextVideoReference(url: URL(fileURLWithPath: "/tmp/a.mp4"), byteCount: 1,
                                       contentSHA256: String(repeating: "b", count: 64), durationSeconds: 1)
        let request = TextRequest(prompt: "", messages: [.init(role: .user, parts: [
            .text("first"), .video(video), .image(image), .text("last"), .video(video)])])
        try vlm.validate(request)
        #expect(request.allImages.count == 1 && request.allVideos.count == 2)
        #expect(request.resolvedMessages[0].parts == [.text("first"), .video(video), .image(image),
                                                      .text("last"), .video(video)])
        #expect(try JSONDecoder().decode(TextRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func toolRoundtripAndMixedLegacyRejection() throws {
        let tool = TextToolDefinition(name: "lookup", description: "Lookup", parameters: [
            "type": .string("object"), "properties": .object(["id": .object(["type": .string("integer")])]),
            "required": .array([.string("id")])])
        let calls = [TextToolCall(id: "a", name: "lookup", arguments: ["id": .int(1)]),
                     TextToolCall(id: "b", name: "lookup", arguments: ["id": .int(2)])]
        let messages: [TextMessage] = [
            .init(role: .user, parts: [.text("find two")]),
            .init(role: .assistant, parts: [], toolCalls: calls),
            .init(role: .tool, parts: [.text("one")], toolCallID: "a"),
            .init(role: .tool, parts: [.text("two")], toolCallID: "b")]
        let request = TextRequest(prompt: "", messages: messages, tools: [tool])
        try vlm.validate(request)
        #expect(try JSONDecoder().decode(TextRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(throws: (any Error).self) {
            try vlm.validate(TextRequest(prompt: "ambiguous", messages: messages, tools: [tool]))
        }
        #expect(throws: (any Error).self) {
            try vlm.validate(TextRequest(prompt: "", messages: Array(messages.dropLast()), tools: [tool]))
        }
        #expect(throws: (any Error).self) {
            try TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 256)
                .validate(request)
        }
    }

    @Test func boundedJSONAndFinalResponseRoundtrip() throws {
        let value: TextJSONValue = .object(["list": .array([.null, .bool(true), .int(9), .double(1e100)])])
        #expect(try JSONDecoder().decode(TextJSONValue.self, from: JSONEncoder().encode(value)) == value)
        let response = TextResponse(rawText: "<think>why</think>done", reasoningText: "why",
            finalText: "done", finishReason: .stop)
        let result = InferenceResult(textResponse: response)
        #expect(try JSONDecoder().decode(InferenceResult.self, from: JSONEncoder().encode(result)) == result)
        var count = 0
        #expect(throws: (any Error).self) {
            try TextJSONValue.double(.infinity).validate(count: &count)
        }
    }
}
