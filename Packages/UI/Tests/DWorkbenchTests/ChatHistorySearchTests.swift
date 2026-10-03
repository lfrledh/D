import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Chat lexical history search")
struct ChatHistorySearchTests {
    @Test func titleMessageAttemptAndAttachmentHaveJumpTargets() throws {
        var session = ChatSession(title: "Needle title")
        let user = ChatMessage(parentID: nil, role: .user, text: "Needle question",
                               attachments: [.init(name: "Needle source", reference: .init(projectID: UUID(), assetID: UUID(),
                                   kind: .text, sha256: String(repeating: "a", count: 64)), textSnapshot: "Needle excerpt")])
        let attemptID = UUID()
        let answer = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: attemptID)
        var attempt = ChatAttempt(id: attemptID, sessionID: session.id, userMessageID: user.id,
                                  assistantMessageID: answer.id,
                                  node: .init(operationID: WorkflowModelRoutes.qwen35, title: "chat"),
                                  messagesJSON: "[]", inputs: [:], systemPrompt: "", status: .completed)
        attempt.rawText = "Needle raw"
        attempt.response = .init(rawText: "Needle raw", finalText: "Needle final", finishReason: .stop)
        session.messages = [user, answer]; session.attempts = [attempt]
        let hits = ChatHistorySearch.matches(in: [session], query: "needle")
        #expect(hits.map(\.kind) == [.title, .message, .attachment, .attachment, .message])
        #expect(hits.first?.messageID == nil)
        #expect(hits.dropFirst().allSatisfy { $0.messageID != nil })
        #expect(hits.last?.sourceText == "Needle final")
        #expect(ChatHistorySearch.matches(in: [session], query: "Needle", maximumHits: -1).isEmpty)
        #expect(ChatHistorySearch.matches(in: [session], query: "Needle", maximumHits: 2).count == 2)
    }

    @Test func unicodeRangesNeverSplitGraphemesAndOccurrencesDoNotOverlap() {
        let title = "👩🏽‍🎨 e\u{301} e\u{301}"
        let session = ChatSession(title: title)
        let hits = ChatHistorySearch.matches(in: [session], query: "e\u{301}")
        #expect(hits.count == 2)
        for hit in hits {
            #expect((title as NSString).substring(with: hit.range) == "e\u{301}")
            #expect(Range(hit.range, in: title) != nil)
        }
        #expect(ChatHistorySearch.matches(in: [session], query: "👩🏽‍🎨").count == 1)
    }
}
