import AppKit
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite("Stored chat channel presentation")
@MainActor struct ChatChannelPresentationTests {
    private func attempt(status: ChatAttempt.Status, format: ChatOutputFormat? = nil) -> ChatAttempt {
        var value = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
            node: .init(operationID: WorkflowModelRoutes.qwen35, title: "fixture"),
            messagesJSON: "[]", inputs: [:], systemPrompt: "", status: status)
        value.outputFormat = format
        return value
    }

    @Test func runningBytesStayRawAndFinalChannelsUseStoredResponse() {
        var running = attempt(status: .running, format: .init(kind: .json))
        running.rawText = "<think>unparsed</think> {\"x\":1"
        let live = ChatChannelPresentation(running)
        #expect(live.isStreaming)
        #expect(live.isUnseparatedRaw)
        #expect(live.text == running.rawText)
        #expect(live.rawText == running.rawText)
        #expect(live.formatReport == nil)
        #expect(live.structuredResult == nil)

        var finished = running
        finished.status = .completed
        finished.response = .init(rawText: running.rawText, reasoningText: "stored reasoning",
                                  finalText: "body only", finishReason: .stop)
        let final = ChatChannelPresentation(finished)
        #expect(!final.isStreaming)
        #expect(!final.isUnseparatedRaw)
        #expect(final.text == "body only")
        #expect(final.rawText == running.rawText)
        #expect(final.formatReport?.status == .invalid)
        #expect(final.structuredResult == nil)

        let message = ChatMessage(parentID: nil, role: .assistant, text: "", attemptID: running.id)
        let host = NSHostingView(rootView: ChatMessageContent(message: message, attempt: running,
                                                              onPreview: { _ in }))
        host.frame = .init(x: 0, y: 0, width: 680, height: 360)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
    }

    @Test func terminalBytesWithoutParsedResponseRemainUnseparatedFromManualAnswer() {
        for status in [ChatAttempt.Status.partial, .interrupted] {
            var unfinished = attempt(status: status, format: .init(kind: .json))
            unfinished.rawText = "<think>unfinished"
            let presentation = ChatChannelPresentation(unfinished)
            #expect(!presentation.isStreaming)
            #expect(presentation.isUnseparatedRaw)
            #expect(presentation.text == "<think>unfinished")
            #expect(presentation.rawText == "<think>unfinished")
            #expect(presentation.formatReport == nil)
            #expect(presentation.structuredResult == nil)

            let message = ChatMessage(parentID: nil, role: .assistant, text: "", attemptID: unfinished.id)
            let host = NSHostingView(rootView: ChatMessageContent(message: message, attempt: unfinished,
                                                                  onPreview: { _ in }))
            host.frame = .init(x: 0, y: 0, width: 680, height: 360)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > 0)

            var session = ChatSession(title: "source")
            session.messages = [message]
            let manual = ChatTextRevision(messageID: message.id, text: "Reviewed answer")
            var choices = ChatContextChoices()
            choices.revisions = [manual]
            choices.adoptedRevisionIDs = [manual.id]
            session.contextChoices = choices
            #expect(ChatContextRowStatus.forMessage(message, in: session) == .adopted)
            #expect(session.contextChoices?.adopted[message.id] == "Reviewed answer")
            #expect(presentation.text != manual.text)
        }
    }

    @Test func contextRowsDistinguishReviewedSummaryAndOriginalHistory() throws {
        let first = ChatMessage(parentID: nil, role: .user, text: "原问题")
        let next = ChatMessage(parentID: first.id, role: .user, text: "新问题")
        var session = ChatSession(title: "summary")
        session.messages = [first, next]; session.selectedLeafID = next.id
        let source = try ChatContextSource.capture(session: session, coveredMessageIDs: [first.id])
        let summary = try ChatContextSummary(text: "已确认摘要", source: source, enabled: true)
        #expect(ChatContextRowStatus.forMessage(first, in: session, summaryUses: [summary]) == .summarized)
        #expect(ChatContextRowStatus.forMessage(next, in: session, summaryUses: [summary]) == .currentQuestion)
        #expect(ChatContextRowStatus.forMessage(first, in: session) == .included)
        var choices = ChatContextChoices(); choices.excludedMessageIDs = [first.id]; session.contextChoices = choices
        #expect(ChatContextRowStatus.forMessage(first, in: session, summaryUses: [summary]) == .excluded)
        #expect(session.messages == [first, next])
    }

    @Test func structuredFoldUsesOnlyStrictlyCheckedOriginal() {
        let json = #"{"name":"🎨","ok":true}"#
        var valid = attempt(status: .completed, format: .init(kind: .json))
        valid.rawText = json
        valid.response = .init(rawText: json, finalText: json, finishReason: .stop)
        let jsonView = ChatChannelPresentation(valid)
        #expect(jsonView.formatReport?.status == .valid)
        #expect(jsonView.formatReport?.datum == nil)
        #expect(jsonView.structuredResult == json)

        valid.response = .init(rawText: #"{"x":1,"x":2}"#, finalText: #"{"x":1,"x":2}"#,
                               finishReason: .stop)
        let rejected = ChatChannelPresentation(valid)
        #expect(rejected.formatReport?.status == .invalid)
        #expect(rejected.structuredResult == nil)
        #expect(rejected.text == #"{"x":1,"x":2}"#)

        let schema: WorkflowDataSchema = .record([.init("title", .text)])
        var typed = attempt(status: .completed, format: .init(kind: .schema, schema: schema))
        typed.rawText = #"{"title":"原文"}"#
        typed.response = .init(rawText: typed.rawText, finalText: typed.rawText, finishReason: .stop)
        let typedView = ChatChannelPresentation(typed)
        #expect(typedView.formatReport?.status == .valid)
        #expect(typedView.formatReport?.datum?.fields?["title"] == .text("原文"))
        #expect(typedView.structuredResult == typed.rawText)

        typed.response = .init(rawText: #"{"other":"原文"}"#, finalText: #"{"other":"原文"}"#,
                               finishReason: .stop)
        #expect(ChatChannelPresentation(typed).structuredResult == nil)
    }

    @Test func provenanceShowsFrozenRevisionScopeOriginAndExactCoveredIDs() throws {
        let first = ChatMessage(parentID: nil, role: .user, text: "one")
        let second = ChatMessage(parentID: first.id, role: .user, text: "two")
        var session = ChatSession(title: "source")
        session.messages = [first, second]
        session.selectedLeafID = second.id
        let source = try ChatContextSource.capture(session: session, coveredMessageIDs: [first.id, second.id])
        let manualSummary = try ChatContextSummary(text: "reviewed", source: source)
        let manualView = ChatProvenancePresentation(summary: manualSummary)
        #expect(manualView.revision == 1 && manualView.origin == .manual)
        #expect(manualView.source?.sessionID == session.id)
        #expect(manualView.source?.selectedLeafID == second.id)
        #expect(manualView.source?.coveredMessageIDs == [first.id, second.id])

        let auxiliaryID = UUID()
        let auxiliary = try ChatContextSummary(text: "suggested", source: source,
                                               auxiliaryAttemptID: auxiliaryID)
        #expect(ChatProvenancePresentation(summary: auxiliary).origin == .auxiliary(auxiliaryID))

        let projectID = UUID()
        let memory = try ChatMemoryEntry.suggestion(text: "fact", scope: .project(projectID), source: source)
        let revised = try memory.edited(text: "edited fact")
        let memoryView = ChatProvenancePresentation(memory: revised)
        #expect(memoryView.revision == 2)
        #expect(memoryView.scope == .project(projectID))
        #expect(memoryView.origin == .chat)
        #expect(memoryView.source?.coveredMessageIDs == [first.id, second.id])
        #expect(ChatProvenancePresentation(memory: try .manual(text: "personal", scope: .personal)).origin == .manual)
    }
}
