import Foundation
import Testing
@testable import DWorkbench

@Suite("B5 selected text and immutable search identity")
struct ChatB5Tests {
    private func fixture() -> (ChatSession, ChatMessage, ChatTextRevision) {
        var session = ChatSession(title: "Review")
        let message = ChatMessage(parentID: nil, role: .assistant, text: "original needle")
        let revision = ChatTextRevision(messageID: message.id, text: "selected needle 👩🏽‍🎨", origin: .edited)
        session.messages = [message]
        var choices = ChatContextChoices(); choices.revisions = [revision]; choices.adoptedRevisionIDs = [revision.id]
        session.contextChoices = choices
        return (session, message, revision)
    }

    @Test func adoptedAndOriginalHitsKeepExactVersionWithoutMutatingChoice() throws {
        let (session, _, revision) = fixture()
        let hits = ChatHistorySearch.matches(in: [session], query: "needle")
        #expect(hits.count == 2)
        #expect(hits.map(\.textVersion) == [.selected, .original])
        #expect(hits[0].revisionID == revision.id)
        #expect(hits.allSatisfy { ChatHistorySearch.isCurrent($0, in: session) })
        #expect(session.contextChoices?.adoptedRevisionIDs == [revision.id])
        #expect(ChatHistorySearch.matches(in: [session], query: "👩🏽‍🎨").count == 1)
        #expect(ChatHistorySearch.matches(in: [session], query: "needle", maximumHits: 1).count == 1)
    }

    @Test func equalVersionsDeduplicateOnlyWithinOneMessage() {
        var (session, message, revision) = fixture()
        let same = ChatTextRevision(messageID: message.id, text: message.text)
        session.contextChoices?.revisions = [same, revision]; session.contextChoices?.adoptedRevisionIDs = [same.id]
        session.messages.append(ChatMessage(parentID: nil, role: .user, text: message.text))
        let hits = ChatHistorySearch.matches(in: [session], query: "needle")
        #expect(hits.count == 2)
        #expect(hits.first?.revisionID == same.id)
    }

    @Test func removedRevisionCannotResolveToNewSelectedVersion() throws {
        var (session, _, revision) = fixture()
        let hit = try #require(ChatHistorySearch.matches(in: [session], query: "selected").first)
        session.contextChoices?.revisions = []
        session.contextChoices?.adoptedRevisionIDs = []
        #expect(!ChatHistorySearch.isCurrent(hit, in: session))
        #expect(hit.revisionID == revision.id)
    }

    @Test func legacyRevisionDecodesWithoutInventingOrigin() throws {
        let (_, _, revision) = fixture()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(revision)) as? [String: Any])
        object.removeValue(forKey: "origin")
        let decoded = try JSONDecoder().decode(ChatTextRevision.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.origin == nil)
        #expect(decoded.text == revision.text && decoded.id == revision.id)
        #expect(try JSONDecoder().decode(ChatTextRevision.self, from: JSONEncoder().encode(revision)) == revision)
    }
    @Test func retainedButUnselectedRevisionIsNotCurrent() throws {
        var (session, _, _) = fixture()
        let hit = try #require(ChatHistorySearch.matches(in: [session], query: "selected").first)
        session.contextChoices?.adoptedRevisionIDs = []
        #expect(!ChatHistorySearch.isCurrent(hit, in: session))
    }
    @Test func actualPhaseCodesAndCancellationPriority() {
        #expect(ChatGenerationPhase.updated(by: "phase.generatingRaw", previous: .preparing, cancelling: false) == .generating)
        #expect(ChatGenerationPhase.updated(by: "phase.releasing", previous: .generating, cancelling: false) == .generating)
        #expect(ChatGenerationPhase.updated(by: "phase.generatingRaw", previous: .lowMemoryExecution, cancelling: false) == .lowMemoryExecution)
        #expect(ChatGenerationPhase.updated(by: "phase.generatingRaw", previous: .generating, cancelling: true) == .stopping)
    }

}
