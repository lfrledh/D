import Foundation
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite("Chat presentation boundaries")
@MainActor struct ChatPresentationTests {
    @Test func replayRequiresRecordedSeedAndSafeSessionButNotCurrentDraftSettings() {
        var session = ChatSession()
        var node = WorkflowNode(operationID: "d.model.qwen35-9b", title: "Qwen")
        node.parameters["seed"] = .text("18446744073709551614")
        var attempt = ChatAttempt(sessionID: session.id, userMessageID: UUID(), assistantMessageID: UUID(),
            node: node, messagesJSON: "[]", inputs: [:], systemPrompt: "old", status: .completed)
        // An absent current configuration must not replace or invalidate a recorded request.
        session.configuration = nil
        #expect(ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: false,
            hasPendingSave: false, hasSaveIssue: false))
        #expect(!ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: true,
            hasPendingSave: false, hasSaveIssue: false))
        #expect(!ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: false,
            hasPendingSave: true, hasSaveIssue: false))
        #expect(!ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: false,
            hasPendingSave: false, hasSaveIssue: true))
        #expect(!ChatRunAdmission.allowsReplay(ChatSession(), attempt: attempt, isRunning: false,
            hasPendingSave: false, hasSaveIssue: false))
        attempt.node.parameters.removeValue(forKey: "seed")
        #expect(!ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: false,
            hasPendingSave: false, hasSaveIssue: false))
    }

    @Test func literalSourceRemainsAvailableDuringStreamingAndParseDelay() async {
        let final = "# Answer\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        let original = "<think>reasoning</think>\n" + final
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: true,
            showingRaw: false, parsed: nil, document: nil) == final)
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: false,
            showingRaw: false, parsed: nil, document: nil) == final)
        let document = await ChatMarkdownPresentation.parse(final)
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: false,
            showingRaw: true, parsed: final, document: document) == original)
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: false,
            showingRaw: false, parsed: final, document: document) == nil)
    }

    @Test func emptyHTMLRenderFallsBackToLiteralWhileMarkdownRenders() async {
        let html = "<div>保留这段回答</div>"
        let empty = await ChatMarkdownPresentation.parse(html)
        #expect(empty == .empty)
        #expect(ChatMarkdownPresentation.literalText(rendered: html, raw: html, streaming: false,
            showingRaw: false, parsed: html, document: empty) == html)

        let markdown = "# 回答\n\n正常 Markdown"
        let rendered = await ChatMarkdownPresentation.parse(markdown)
        #expect(rendered != .empty)
        #expect(ChatMarkdownPresentation.literalText(rendered: markdown, raw: markdown, streaming: false,
            showingRaw: false, parsed: markdown, document: rendered) == nil)
    }

    @Test func everyModelRunControlSharesNumericAndSaveAdmission() {
        var session = ChatSession()
        session.configuration = WorkflowNode(operationID: "d.model.qwen35-9b", title: "Qwen")
        let invalid = Set([session.id.uuidString + ":temperature"])
        #expect(!ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: invalid))
        session.draft = "发送"
        #expect(!ChatRunAdmission.allowsSend(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: invalid))
        #expect(ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
        #expect(ChatRunAdmission.allowsSend(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
        session.draft = " "
        #expect(ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
        #expect(!ChatRunAdmission.allowsSend(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
        #expect(!ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: true,
            hasSaveIssue: false, invalidFields: []))
        #expect(!ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: true, invalidFields: []))
        session.archived = true
        #expect(!ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
    }

    @Test func markdownCannotLoadImagesOrOpenModelLinks() async {
        #expect(!ChatMarkdownPresentation.config.imageConfig.enabled)
        let action = OpenURLAction { ChatMarkdownPresentation.discardURL($0) }
        let accepted = await withCheckedContinuation { continuation in
            action(URL(string: "https://example.invalid/model")!) { continuation.resume(returning: $0) }
        }
        #expect(!accepted)
    }

    @Test func sharedAssetDropRequiresExactStoreInstance() {
        let project = UUID(), original = UUID(), copy = UUID()
        #expect(ChatAssetDropScope.accepts(projectID: project, instanceID: original,
            manifestProjectID: project, manifestInstanceID: original))
        #expect(!ChatAssetDropScope.accepts(projectID: project, instanceID: original,
            manifestProjectID: project, manifestInstanceID: copy))
        #expect(!ChatAssetDropScope.accepts(projectID: UUID(), instanceID: original,
            manifestProjectID: project, manifestInstanceID: original))
        #expect(!ChatAssetDropScope.accepts(projectID: project, instanceID: nil,
            manifestProjectID: project, manifestInstanceID: copy))
        #expect(ChatAssetDropScope.accepts(projectID: project, instanceID: nil,
            manifestProjectID: project, manifestInstanceID: project))
    }
}
