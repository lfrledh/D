import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Chat summary and memory values")
struct ChatMemoryContextTests {
    private func session() -> ChatSession {
        var session = ChatSession(title: "source")
        let reference = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .image,
                                               sha256: String(repeating: "a", count: 64))
        let user = ChatMessage(parentID: nil, role: .user, text: "literal e\u{301} 👩🏽‍🎨",
                               attachments: [.init(name: "image", reference: reference)])
        let assistant = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: UUID())
        var attempt = ChatAttempt(id: assistant.attemptID!, sessionID: session.id,
                                  userMessageID: user.id, assistantMessageID: assistant.id,
                                  node: .init(operationID: WorkflowModelRoutes.qwen35, title: "source"),
                                  messagesJSON: "[]", inputs: [:], systemPrompt: "rules", status: .completed)
        attempt.rawText = "raw response"
        attempt.response = .init(rawText: "raw response", finalText: "answer", finishReason: .stop)
        session.messages = [user, assistant]
        session.attempts = [attempt]
        session.selectedLeafID = assistant.id
        session.systemPrompt = "rules"
        return session
    }

    @Test func summaryRoundTripAndExactSourceChanges() throws {
        let original = session()
        let covered = original.messages.map(\.id)
        let source = try ChatContextSource.capture(session: original, coveredMessageIDs: covered)
        let shorterCoverage = try ChatContextSource.capture(session: original, coveredMessageIDs: [covered[0]])
        #expect(shorterCoverage.sha256 != source.sha256)
        let summary = try ChatContextSummary(text: "保留原文 👩🏽‍🎨 e\u{301}", source: source,
                                             auxiliaryAttemptID: UUID())
        let bytes = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ChatContextSummary.self, from: bytes)
        #expect(decoded == summary)
        try decoded.validate(current: original)
        #expect(decoded.source.sessionID == original.id)
        #expect(decoded.source.coveredMessageIDs == covered)
        var sourceObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        sourceObject["sha256"] = String(repeating: "0", count: 64)
        let mismatched = try JSONDecoder().decode(ChatContextSource.self,
            from: JSONSerialization.data(withJSONObject: sourceObject))
        #expect(throws: (any Error).self) { try mismatched.validate(current: original) }

        let revised = try summary.edited(text: "edited without replacing source")
        #expect(revised.id == summary.id && revised.revision == summary.revision + 1)
        #expect(revised.source == summary.source)
        #expect(original.messages[0].text == "literal e\u{301} 👩🏽‍🎨")

        var edited = original
        edited.messages[0] = .init(id: covered[0], parentID: nil, role: .user, text: "changed",
                                   attachments: original.messages[0].attachments)
        #expect(throws: (any Error).self) { try summary.validate(current: edited) }

        var media = original
        let old = original.messages[0].attachments[0]
        let changedReference = WorkflowAssetReference(projectID: old.reference.projectID,
            assetID: old.reference.assetID, version: UUID(), kind: .image, sha256: old.reference.sha256)
        media.messages[0] = .init(id: covered[0], parentID: nil, role: .user,
                                  text: original.messages[0].text,
                                  attachments: [.init(id: old.id, name: old.name, reference: changedReference)])
        #expect(throws: (any Error).self) { try summary.validate(current: media) }

        var branch = original
        let sibling = ChatMessage(parentID: nil, role: .user, text: "other branch")
        branch.messages.append(sibling); branch.selectedLeafID = sibling.id
        #expect(throws: (any Error).self) { try summary.validate(current: branch) }

        var missing = original
        missing.messages.removeFirst()
        #expect(throws: (any Error).self) { try summary.validate(current: missing) }

        var otherSession = original
        otherSession = ChatSession(title: "other")
        #expect(throws: (any Error).self) { try summary.validate(current: otherSession) }
    }

    @Test func adoptionExclusionAndUnicodeBytesChangeFingerprint() throws {
        let original = session()
        let source = try ChatContextSource.capture(session: original,
                                                   coveredMessageIDs: original.messages.map(\.id))
        var adopted = original
        var choices = ChatContextChoices()
        let revision = ChatTextRevision(messageID: original.messages[1].id, text: "chosen answer")
        choices.revisions = [revision]; choices.adoptedRevisionIDs = [revision.id]
        adopted.contextChoices = choices
        #expect(throws: (any Error).self) { try source.validate(current: adopted) }
        let adoptedSource = try ChatContextSource.capture(session: adopted,
            coveredMessageIDs: adopted.messages.map(\.id))
        let alternate = ChatTextRevision(messageID: original.messages[1].id, text: "chosen answer")
        choices.revisions.append(alternate); choices.adoptedRevisionIDs = [alternate.id]
        adopted.contextChoices = choices
        #expect(throws: (any Error).self) { try adoptedSource.validate(current: adopted) }

        var excluded = original
        choices = .init(); choices.excludedMessageIDs = [original.messages[1].id]
        excluded.contextChoices = choices
        #expect(throws: (any Error).self) { try source.validate(current: excluded) }
        #expect(throws: (any Error).self) {
            try ChatContextSource.capture(session: excluded,
                coveredMessageIDs: original.messages.map(\.id))
        }
        let partial = try ChatContextSource.capture(session: excluded,
            coveredMessageIDs: [original.messages[0].id])
        #expect(partial.coveredMessageIDs == [original.messages[0].id])

        var normalized = original
        normalized.messages[0] = .init(id: original.messages[0].id, parentID: nil, role: .user,
                                      text: "literal é 👩🏽‍🎨", attachments: original.messages[0].attachments)
        #expect(throws: (any Error).self) { try source.validate(current: normalized) }
    }

    @Test func memoryApprovalScopeForgetAndLimits() throws {
        let session = session()
        let source = try ChatContextSource.capture(session: session,
            coveredMessageIDs: session.messages.map(\.id))
        let project = UUID(), anotherProject = UUID()
        let manual = try ChatMemoryEntry.manual(text: "User wrote this exactly", scope: .personal)
        let suggestion = try ChatMemoryEntry.suggestion(text: "possible fact", scope: .project(project), source: source)
        #expect(manual.acceptance == .accepted && !manual.enabled)
        #expect(suggestion.acceptance == .suggested && !suggestion.enabled)
        #expect(throws: (any Error).self) { try suggestion.settingEnabled(true) }
        let approved = try suggestion.approved()
        #expect(approved.source == suggestion.source && approved.id == suggestion.id)
        #expect(approved.revision == suggestion.revision + 1 && !approved.enabled)
        let activeManual = try manual.settingEnabled(true)
        let activeProject = try approved.settingEnabled(true)
        let entries = [activeManual, activeProject, suggestion]
        #expect(ChatMemoryEntry.activeProjection(entries).isEmpty)
        #expect(ChatMemoryEntry.activeProjection(entries,
            enabledScopes: [.personal, .project(project)], isTemporarySession: true).isEmpty)
        #expect(ChatMemoryEntry.activeProjection(entries, enabledScopes: [.personal, .project(project)])
            == [activeManual, activeProject])
        #expect(ChatMemoryEntry.activeProjection(entries, enabledScopes: [.personal, .project(anotherProject)])
            == [activeManual])
        #expect(ChatMemoryEntry.activeProjection(entries, enabledScopes: [.personal])
            == [activeManual])
        #expect(ChatMemoryEntry.activeProjection(entries, enabledScopes: [.project(project)])
            == [activeProject])
        let forgotten = try activeProject.forgotten(at: activeProject.createdAt)
        #expect(forgotten.source == activeProject.source && !forgotten.enabled)
        #expect(throws: (any Error).self) { try forgotten.settingEnabled(true) }
        #expect(ChatMemoryEntry.activeProjection([forgotten], enabledScopes: [.project(project)]).isEmpty)
        #expect(ChatMemoryEntry.activeProjection([activeProject, forgotten],
            enabledScopes: [.project(project)]).isEmpty)
        let forgedRevival = try ChatMemoryEntry(id: activeProject.id, revision: forgotten.revision + 1,
            text: activeProject.text, scope: .project(project), source: activeProject.source,
            acceptance: .accepted, enabled: true, createdAt: activeProject.createdAt)
        #expect(ChatMemoryEntry.activeProjection([activeProject, forgotten, forgedRevival],
            enabledScopes: [.project(project)]).isEmpty)
        let disabled = try activeManual.settingEnabled(false)
        #expect(ChatMemoryEntry.activeProjection([activeManual, disabled],
            enabledScopes: [.personal]).isEmpty)
        let edited = try activeManual.edited(text: "exact edited e\u{301}")
        #expect(edited.id == activeManual.id && edited.source == activeManual.source)
        #expect(edited.revision == activeManual.revision + 1)
        #expect(try JSONDecoder().decode(ChatMemoryEntry.self, from: JSONEncoder().encode(edited)) == edited)
        #expect(throws: (any Error).self) {
            try ChatMemoryEntry.manual(text: "more than four bytes", scope: .personal,
                                       limits: .init(maxTextBytes: 4))
        }
        #expect(throws: (any Error).self) {
            try ChatContextSource.capture(session: session,
                coveredMessageIDs: session.messages.map(\.id), limits: .init(maxSourceBytes: 8))
        }
    }
}
