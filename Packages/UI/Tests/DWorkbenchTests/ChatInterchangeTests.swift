import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Pure chat interchange")
struct ChatInterchangeTests {
    private func data(_ messages: [[String: Any]], version: Any = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": "openai-messages", "version": version,
                                                "messages": messages], options: [.sortedKeys])
    }

    @Test func htmlEscapesEveryUntrustedFieldAndKeepsUnicodeText() throws {
        var session = ChatSession(title: "<Talk & \"friends\"> 👩🏽‍🎨")
        session.systemPrompt = "System 'rule' <img src=x>"
        let user = ChatMessage(parentID: nil, role: .user,
                               text: "Hello <script>alert(1)</script> & e\u{301}\nhttps://example.test/a?x=1&y=2")
        let attemptID = UUID()
        let assistant = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: attemptID)
        var attempt = ChatAttempt(id: attemptID, sessionID: session.id, userMessageID: user.id,
                                  assistantMessageID: assistant.id,
                                  node: .init(operationID: WorkflowModelRoutes.qwen35, title: "chat"),
                                  messagesJSON: "[]", inputs: [:], systemPrompt: session.systemPrompt,
                                  status: .completed)
        attempt.rawText = "raw output"
        attempt.response = .init(rawText: "raw output", finalText: "Answer > \"quoted\" 👩🏽‍🎨", finishReason: .stop)
        session.messages = [user, assistant]; session.attempts = [attempt]
        let original = session

        let html = try ChatInterchange.exportHTML(session: session, leafID: assistant.id)
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("&lt;Talk &amp; &quot;friends&quot;&gt; 👩🏽‍🎨"))
        #expect(html.contains("System &#39;rule&#39; &lt;img src=x&gt;"))
        #expect(html.contains("Hello &lt;script&gt;alert(1)&lt;/script&gt; &amp; e\u{301}\nhttps://example.test/a?x=1&amp;y=2"))
        #expect(html.contains("Answer &gt; &quot;quoted&quot; 👩🏽‍🎨"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img"))
        #expect(!html.contains("<a "))
        #expect(session == original)
        #expect(throws: (any Error).self) { try ChatInterchange.exportHTML(session: session, leafID: UUID()) }
    }

    @Test func orderedTextAndSystemPromptRequireExplicitAcceptance() throws {
        let original = try data([
            ["role": "system", "content": "Original system 👩🏽‍🎨"],
            ["role": "user", "content": "First e\u{301}"],
            ["role": "assistant", "content": [["type": "text", "text": "A"], ["type": "text", "text": "nswer"]]],
            ["role": "user", "content": "Next"]
        ])
        let copy = original
        let preview = try ChatInterchange.previewOpenAIMessagesV1(original)
        #expect(preview.format == "openai-messages" && preview.version == 1)
        #expect(preview.systemPrompt == "Original system 👩🏽‍🎨")
        #expect(preview.messages.map(\.role) == [.user, .assistant, .user])
        #expect(preview.messages.map(\.text) == ["First e\u{301}", "Answer", "Next"])
        #expect(preview.messages.map(\.sourceIndex) == [1, 2, 3])
        #expect(preview.losses.isEmpty)
        let accepted = try preview.accept()
        #expect(accepted.systemPrompt == preview.systemPrompt && accepted.messages == preview.messages)
        #expect(accepted.format == "openai-messages" && accepted.version == 1)
        #expect(original == copy)
    }

    @Test func unsupportedMediaAndToolFieldsAreVisibleBeforeAcceptance() throws {
        let original = try data([
            ["role": "user", "content": [["type": "text", "text": "Read this"],
                                            ["type": "image_url", "image_url": ["url": "https://example.test/x.png"]]]],
            ["role": "assistant", "content": "Cannot inspect image", "tool_calls": [["id": "call-1"]],
             "channel": "final"],
            ["role": "tool", "content": "untrusted result", "tool_call_id": "call-1"]
        ])
        let preview = try ChatInterchange.previewOpenAIMessagesV1(original)
        #expect(preview.messages.map(\.text) == ["Read this", "Cannot inspect image"])
        #expect(preview.losses.map(\.location) == ["messages[0].content[1]", "messages[1].channel",
                                                  "messages[1].tool_calls", "messages[2]"])
        #expect(throws: (any Error).self) { try preview.accept() }
        let accepted = try preview.accept(allowingLosses: true)
        #expect(accepted.acknowledgedLosses == preview.losses)
        #expect(accepted.messages == preview.messages)
    }

    @Test func malformedShapeRolesPartsAndOrderAreRejected() throws {
        let cases: [[[String: Any]]] = [
            [["role": "assistant", "content": "Orphan"]],
            [["role": "developer", "content": "Do something"]],
            [["role": "user", "content": 42]],
            [["role": "user", "content": [["type": "text", "text": 42]]]],
            [["role": "user", "content": "One"], ["role": "user", "content": "Two"]],
            [["role": "user", "content": "One"], ["role": "system", "content": "Late"]],
            [["role": "user", "content": [["type": "image_url", "image_url": [:]]]]]
        ]
        for messages in cases {
            let bytes = try data(messages)
            #expect(throws: (any Error).self) { try ChatInterchange.previewOpenAIMessagesV1(bytes) }
        }
        #expect(throws: (any Error).self) {
            try ChatInterchange.previewOpenAIMessagesV1(Data("[]".utf8))
        }
    }

    @Test func versionBooleanNumericAndUnknownWrapperAreRejected() throws {
        let messages: [[String: Any]] = [["role": "user", "content": "hello"]]
        let invalidVersions: [Any] = [true, 2, 1.5, "1"]
        for version in invalidVersions {
            #expect(throws: (any Error).self) {
                try ChatInterchange.previewOpenAIMessagesV1(data(messages, version: version))
            }
        }
        let wrong = try JSONSerialization.data(withJSONObject: ["format": "other", "version": 1,
                                                            "messages": messages])
        #expect(throws: (any Error).self) { try ChatInterchange.previewOpenAIMessagesV1(wrong) }
        let unknown = try JSONSerialization.data(withJSONObject: ["format": "openai-messages", "version": 1,
                                                              "messages": messages, "extra": "ignored?"])
        #expect(throws: (any Error).self) { try ChatInterchange.previewOpenAIMessagesV1(unknown) }
    }

    @Test func byteDepthMessageAndTextBoundsAreEnforced() throws {
        #expect(throws: (any Error).self) {
            try ChatInterchange.previewOpenAIMessagesV1(Data(repeating: 0x20,
                count: ChatInterchange.maximumImportBytes + 1))
        }
        let deep = "{\"format\":\"openai-messages\",\"version\":1,\"messages\":" +
            String(repeating: "[", count: ChatInterchange.maximumJSONDepth) + "0" +
            String(repeating: "]", count: ChatInterchange.maximumJSONDepth) + "}"
        #expect(throws: (any Error).self) {
            try ChatInterchange.previewOpenAIMessagesV1(Data(deep.utf8))
        }
        let many: [[String: Any]] = Array(repeating: ["role": "user", "content": "x"],
                                          count: ChatInterchange.maximumMessages + 1)
        #expect(throws: (any Error).self) { try ChatInterchange.previewOpenAIMessagesV1(data(many)) }
        let oversizedText = String(repeating: "x", count: ChatInterchange.maximumTextBytes + 1)
        #expect(throws: (any Error).self) {
            try ChatInterchange.previewOpenAIMessagesV1(data([["role": "user", "content": oversizedText]]))
        }
        let atLimit = String(repeating: "x", count: ChatInterchange.maximumTextBytes)
        #expect(try ChatInterchange.previewOpenAIMessagesV1(data([["role": "user", "content": atLimit]])).messages.count == 1)
    }

    @Test func utf16LEEscapedQuoteCannotHideDeepUnknownField() throws {
        let nested = String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)
        let source = "{\"format\":\"openai-messages\",\"version\":1,\"messages\":[{\"role\":\"user\",\"content\":\"escaped \\\" quote\",\"unknown\":" +
            nested + "}]}"
        #expect(throws: (any Error).self) {
            try ChatInterchange.previewOpenAIMessagesV1(Data(source.utf8))
        }
        let utf16LE = try #require(source.data(using: .utf16LittleEndian))
        #expect(utf16LE.prefix(2) == Data([0x7B, 0x00]))
        #expect(throws: (any Error).self) {
            try ChatInterchange.previewOpenAIMessagesV1(utf16LE)
        }
    }

    @Test func finalToolLossCannotExceedLossBudget() throws {
        var user: [String: Any] = ["role": "user", "content": "hello"]
        for index in 0..<4_096 {
            user["unknown\(index)"] = "x"
        }
        let atLimit = try ChatInterchange.previewOpenAIMessagesV1(data([user]))
        #expect(atLimit.losses.count == 4_096)

        let withTool = try data([user, ["role": "tool", "content": "ignored"]])
        do {
            _ = try ChatInterchange.previewOpenAIMessagesV1(withTool)
            Issue.record("A tool loss exceeded the 4,096-loss budget.")
        } catch let error as ChatInterchangeError {
            #expect(error == .invalid("Import has too many unsupported fields or parts."))
        }
    }
}
