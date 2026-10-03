import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Pure chat context plan")
struct ChatContextPlanTests {
    private func attempt(for message: ChatMessage, user: ChatMessage, status: ChatAttempt.Status,
                         response: TextResponse?) -> ChatAttempt {
        var item = ChatAttempt(id: message.attemptID!, sessionID: UUID(), userMessageID: user.id,
                               assistantMessageID: message.id,
                               node: .init(operationID: WorkflowModelRoutes.qwen35, title: "chat"),
                               messagesJSON: "[]", inputs: [:], systemPrompt: "old", status: status)
        item.rawText = "raw original"
        item.response = response
        return item
    }

    @Test func explicitAdoptionAndExclusionPreserveOriginalAttempt() throws {
        let user = ChatMessage(parentID: nil, role: .user, text: "first")
        let assistant = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: UUID())
        let source = attempt(for: assistant, user: user, status: .partial, response: nil)
        let path = [user, assistant]
        #expect(throws: (any Error).self) {
            try ChatContextPlan.build(path: path, attempts: [source], prompt: "next", attachments: [], system: "")
        }
        let plan = try ChatContextPlan.build(path: path, attempts: [source], prompt: "next", attachments: [],
                                             system: "", adopted: [assistant.id: "chosen excerpt"])
        #expect(plan.messagesJSON.contains("chosen excerpt"))
        #expect(!plan.messagesJSON.contains("raw original"))
        #expect(source.rawText == "raw original")
        #expect(source.status == .partial)
        let omitted = try ChatContextPlan.build(path: path, attempts: [source], prompt: "next", attachments: [],
                                                system: "", excluded: [user.id, assistant.id])
        #expect(!omitted.messagesJSON.contains("first"))
        #expect(source.rawText == "raw original")
        #expect(throws: (any Error).self) {
            try ChatContextPlan.build(path: path, attempts: [source], prompt: "next", attachments: [],
                                      system: "", excluded: [UUID()])
        }
        #expect(throws: (any Error).self) {
            try ChatContextPlan.build(path: path, attempts: [source], prompt: "next", attachments: [],
                                      system: "", adopted: [user.id: "illegal"])
        }
        #expect(throws: (any Error).self) {
            try ChatContextPlan.build(path: path, attempts: [source], prompt: "next", attachments: [],
                                      system: "", adopted: [assistant.id: "  "])
        }
    }

    @Test func excludingOnlyAssistantKeepsEarlierUserMessage() throws {
        let user = ChatMessage(parentID: nil, role: .user, text: "U1")
        let assistant = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: UUID())
        let source = attempt(for: assistant, user: user, status: .completed,
                             response: .init(rawText: "A1", finalText: "A1", finishReason: .stop))
        let plan = try ChatContextPlan.build(path: [user, assistant], attempts: [source],
                                             prompt: "U2", attachments: [], system: "",
                                             excluded: [assistant.id])
        let messages = try #require(JSONSerialization.jsonObject(with: Data(plan.messagesJSON.utf8)) as? [[String: Any]])
        #expect(messages.compactMap { $0["role"] as? String } == ["user", "user"])
        #expect(plan.messagesJSON.contains("U1"))
        #expect(!plan.messagesJSON.contains("A1"))
        #expect(plan.messagesJSON.contains("U2"))
    }

    @Test func excludingOnlyUserKeepsEarlierAssistantMessage() throws {
        let user = ChatMessage(parentID: nil, role: .user, text: "U1")
        let assistant = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: UUID())
        let source = attempt(for: assistant, user: user, status: .completed,
                             response: .init(rawText: "A1", finalText: "A1", finishReason: .stop))
        let plan = try ChatContextPlan.build(path: [user, assistant], attempts: [source],
                                             prompt: "U2", attachments: [], system: "",
                                             excluded: [user.id])
        let messages = try #require(JSONSerialization.jsonObject(with: Data(plan.messagesJSON.utf8)) as? [[String: Any]])
        #expect(messages.compactMap { $0["role"] as? String } == ["assistant", "user"])
        #expect(!plan.messagesJSON.contains("U1"))
        #expect(plan.messagesJSON.contains("A1"))
        #expect(plan.messagesJSON.contains("U2"))
        #expect(source.response?.finalText == "A1")
    }

    @Test func toolStateCannotBeAdoptedAndCompletedReasoningIsReal() throws {
        let user = ChatMessage(parentID: nil, role: .user, text: "first")
        let assistant = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: UUID())
        let tool = TextToolCall(id: "call", name: "lookup", arguments: [:])
        let unsafe = attempt(for: assistant, user: user, status: .partial,
                             response: .init(rawText: "partial", finalText: "partial", toolCalls: [tool], finishReason: .toolCalls))
        #expect(throws: (any Error).self) {
            try ChatContextPlan.build(path: [user, assistant], attempts: [unsafe], prompt: "next", attachments: [],
                                      system: "", adopted: [assistant.id: "approved"])
        }
        let finished = attempt(for: assistant, user: user, status: .completed,
                               response: .init(rawText: "raw", reasoningText: "real reasoning", finalText: "final", finishReason: .stop))
        let original = try ChatContextPlan.build(path: [user, assistant], attempts: [finished],
                                                 prompt: "next", attachments: [], system: "")
        #expect(original.messagesJSON.contains("real reasoning"))
        #expect(original.messagesJSON.contains("final"))
        let revised = try ChatContextPlan.build(path: [user, assistant], attempts: [finished],
                                                prompt: "next", attachments: [], system: "",
                                                adopted: [assistant.id: "editor text"])
        #expect(revised.messagesJSON.contains("editor text"))
        #expect(!revised.messagesJSON.contains("real reasoning"))
        #expect(finished.response?.finalText == "final")
    }

    @Test func mixedAttachmentsKeepOrderAndEmptySystemAddsNothing() throws {
        let project = UUID()
        func attachment(_ kind: WorkflowDataKind, _ name: String, _ text: String? = nil) -> ChatAttachment {
            .init(name: name, reference: .init(projectID: project, assetID: UUID(), kind: kind,
                                               sha256: String(repeating: "a", count: 64)), textSnapshot: text)
        }
        let media = [attachment(.image, "one"), attachment(.text, "notes", "source"),
                     attachment(.video, "clip"), attachment(.image, "two")]
        let plan = try ChatContextPlan.build(path: [], attempts: [], prompt: "question", attachments: media, system: "")
        #expect(plan.images == [media[0].reference, media[3].reference])
        #expect(plan.videos == [media[2].reference])
        let objects = try #require(JSONSerialization.jsonObject(with: Data(plan.messagesJSON.utf8)) as? [[String: Any]])
        #expect(objects.count == 1)
        let parts = try #require(objects[0]["parts"] as? [[String: Any]])
        #expect(parts.compactMap { $0["type"] as? String } == ["image", "text", "video", "image", "text"])
        #expect(plan.estimatedTokens == (plan.messagesJSON.utf8.count + 2) / 3 + 2 * 1024 + 4096)
    }
}
