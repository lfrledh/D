import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

private actor ContextPresentationNoInference: InferenceEngine {
    private(set) var submissions = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1
        throw WorkflowIssue("Context presentation must not run inference")
    }
}

private final class ContextPresentationSettings: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

@Suite("Chat context presentation commands")
@MainActor struct ChatContextPresentationTests {
    private func node() throws -> WorkflowNode {
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture")
        node.parameters["outputMode"] = .text("response")
        node.parameters["task"] = .text("")
        node.parameters["messagesJSON"] = .text("[]")
        return node
    }

    private func fixture(_ state: ChatState) async throws
        -> (ChatController, WorkbenchModel, ContextPresentationNoInference, ProjectStore, URL) {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory(),
                       isDirectory: true).appendingPathComponent("chat-context-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: base.appendingPathComponent("Fixture.dproject"), name: "Context fixture")
        if !state.sessions.isEmpty { _ = try await store.saveChatState(state, expectedRevision: 0) }
        let engine = ContextPresentationNoInference()
        let runtime = WorkbenchSession(engine: engine, backendID: "context.fixture",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let chat = ChatController(store: store) {
            WorkflowServices(store: store, session: runtime) { _, identity in
                .init(identity: identity, reference: .init(directory: base, revision: identity),
                      backendID: "fixture.text", operationID: WorkflowModelRoutes.qwen35,
                      textCapability: .init(maximumPromptTokens: 8192, maximumOutputTokens: 1024,
                                            profile: TextExecutionCapability.qwen35VLMProfile))
            }
        }
        await chat.load()
        let project = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "context.fixture",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: ContextPresentationSettings())
        return (chat, WorkbenchModel(projectSession: project), engine, store, base)
    }

    private func render(_ chat: ChatController, model: WorkbenchModel,
                        inspector: Bool = false, preview: Bool = false,
                        attemptID: UUID? = nil, height: CGFloat = 700) -> [String: CGRect] {
        var positions: [String: CGRect] = [:]
        let host = NSHostingView(rootView: ChatWorkbenchView(chat: chat, model: model,
            onChooseModel: {}, onSavedAsset: { _ in }, onAssetsChanged: {},
            initialInspectorVisible: inspector, initialSettingsVisible: preview, initialContextPreviewVisible: preview,
            initialInspectedAttemptID: attemptID)
            .observingLayout { positions[$0] = $1 })
        host.frame = .init(x: 0, y: 0, width: 1_300, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return positions
    }

    private func close(_ store: ProjectStore, root: URL) async throws {
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }

    @Test func lexicalHitSelectsStoredSiblingPathWithoutSubmittingAndDeletedHitIsRejected() async throws {
        let original = ChatMessage(parentID: nil, role: .user, text: "original branch")
        let target = ChatMessage(parentID: nil, role: .user, text: "needle 👩🏽‍🎨 sibling")
        var first = ChatSession(title: "First")
        first.messages = [original, target]; first.selectedLeafID = original.id
        let otherMessage = ChatMessage(parentID: nil, role: .user, text: "other")
        var other = ChatSession(title: "Other")
        other.messages = [otherMessage]; other.selectedLeafID = otherMessage.id
        var state = ChatState(); state.sessions = [first, other]; state.selectedSessionID = other.id
        let (chat, model, engine, store, root) = try await fixture(state)
        #expect(render(chat, model: model)["message-\(otherMessage.id.uuidString)"] != nil)
        let hit = try #require(ChatHistorySearch.matches(in: chat.state.sessions, query: "needle").first)
        let opened = try ChatContextCommands.open(hit, in: chat)
        let jump = try #require(opened)
        #expect(jump.sessionID == first.id && jump.messageID == target.id)
        #expect(chat.selectedSession?.selectedLeafID == target.id)
        #expect(render(chat, model: model)["message-\(target.id.uuidString)"] != nil)
        #expect(await engine.submissions == 0)
        try ChatContextCommands.choices(try #require(chat.selectedSession), mutate: {
            $0.pinned = true; $0.tags = ["research", "👩🏽‍🎨"]
            $0.favoriteMessageIDs = [target.id]
            $0.excludedMessageIDs = [original.id]
        }, in: chat)
        #expect(chat.selectedSession?.contextChoices?.pinned == true)
        #expect(chat.selectedSession?.contextChoices?.favoriteMessageIDs == [target.id])
        #expect(chat.selectedSession?.contextChoices?.excludedMessageIDs == [original.id])
        #expect(ChatContextSessionList.visible(chat.state.sessions, archived: false, deleted: false,
            favoritesOnly: true, tag: "research").map(\.id) == [first.id])
        #expect(throws: (any Error).self) {
            try ChatContextCommands.choices(try #require(chat.selectedSession), mutate: {
                $0.tags = [String(repeating: "x", count: 33)]
            }, in: chat)
        }
        #expect(chat.selectedSession?.contextChoices?.tags == ["research", "👩🏽‍🎨"])
        try chat.setDeleted(true, sessionID: first.id)
        let ordinary = ChatContextSessionList.visible(chat.state.sessions, archived: false,
            deleted: false, favoritesOnly: false, tag: "")
        #expect(!ordinary.contains { $0.id == first.id })
        #expect(ChatHistorySearch.matches(in: ordinary, query: "needle").isEmpty)
        #expect(ChatContextSessionList.visible(chat.state.sessions, archived: false,
            deleted: true, favoritesOnly: false, tag: "").contains { $0.id == first.id })
        #expect(!ChatRunAdmission.allows(try #require(chat.selectedSession), isRunning: false,
            hasPendingSave: false, hasSaveIssue: false, invalidFields: []))
        #expect(throws: (any Error).self) { try ChatContextCommands.open(hit, in: chat) }
        try chat.setDeleted(false, sessionID: first.id)
        #expect(try ChatContextCommands.open(hit, in: chat)?.messageID == target.id)
        try await close(store, root: root)
    }

    @Test func searchHitOnSelectedUserOrAssistantAncestorPreservesLeafDraftAndPreview() async throws {
        let user1 = ChatMessage(parentID: nil, role: .user, text: "needle first question")
        let attempt1ID = UUID()
        let answer1 = ChatMessage(parentID: user1.id, role: .assistant, text: "needle first answer", attemptID: attempt1ID)
        let user2 = ChatMessage(parentID: answer1.id, role: .user, text: "second question")
        let attempt2ID = UUID()
        let answer2 = ChatMessage(parentID: user2.id, role: .assistant, text: "second answer", attemptID: attempt2ID)
        let frozen = try node()
        var session = ChatSession(title: "Selected path")
        var attempt1 = ChatAttempt(id: attempt1ID, sessionID: session.id, userMessageID: user1.id,
                                   assistantMessageID: answer1.id, node: frozen, messagesJSON: "[]",
                                   inputs: [:], systemPrompt: "", status: .completed)
        attempt1.response = .init(rawText: answer1.text, finalText: answer1.text, finishReason: .stop)
        var attempt2 = ChatAttempt(id: attempt2ID, sessionID: session.id, userMessageID: user2.id,
                                   assistantMessageID: answer2.id, node: frozen, messagesJSON: "[]",
                                   inputs: [:], systemPrompt: "", status: .completed)
        attempt2.response = .init(rawText: answer2.text, finalText: answer2.text, finishReason: .stop)
        session.messages = [user1, answer1, user2, answer2]
        session.attempts = [attempt1, attempt2]
        session.selectedLeafID = answer2.id; session.draft = "unsent continuation"
        session.configuration = frozen
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, engine, store, root) = try await fixture(state)
        let preview = try chat.contextPreview(sessionID: session.id)
        let hits = ChatHistorySearch.matches(in: chat.state.sessions, query: "needle")
        for ancestor in [user1.id, answer1.id] {
            let hit = try #require(hits.first(where: { $0.messageID == ancestor }))
            #expect(try ChatContextCommands.open(hit, in: chat)?.messageID == ancestor)
            #expect(chat.selectedSession?.selectedLeafID == answer2.id)
            #expect(chat.selectedSession?.draft == "unsent continuation")
            #expect(try chat.contextPreview(sessionID: session.id) == preview)
            #expect(chat.selectedPath.map(\.id) == [user1.id, answer1.id, user2.id, answer2.id])
            // This checks retained transcript layout, not a scroll gesture. Lazy rows
            // outside a 700pt viewport need not emit geometry; lay out this small path.
            #expect(render(chat, model: model, height: 2_000)["message-\(answer2.id.uuidString)"] != nil)
        }
        #expect(await engine.submissions == 0)
        try await close(store, root: root)
    }

    @Test func pendingUserStaysCurrentQuestionEvenWhenStoredAsExcluded() async throws {
        let user = ChatMessage(parentID: nil, role: .user, text: "pending question still sent")
        var session = ChatSession(title: "Pending")
        session.messages = [user]; session.selectedLeafID = user.id
        session.configuration = try node()
        var choices = ChatContextChoices(); choices.excludedMessageIDs = [user.id]
        session.contextChoices = choices
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, engine, store, root) = try await fixture(state)
        let preview = try chat.contextPreview(sessionID: session.id)
        #expect(preview.messagesJSON.contains(user.text))
        let status = ChatContextRowStatus.forMessage(user, in: try #require(chat.selectedSession))
        #expect(status == .currentQuestion && !status.canExclude)
        #expect(status.english == "Current question · still sent")
        #expect(status.chinese == "本次问题，仍会发送")
        #expect(render(chat, model: model, inspector: true, preview: true)["context-row-\(user.id.uuidString)"] != nil)
        #expect(await engine.submissions == 0)
        try await close(store, root: root)
    }

    @Test func hostedPartialAnswerAdoptsSeparateVersionAndKeepsOriginalRequest() async throws {
        let user = ChatMessage(parentID: nil, role: .user, text: "First question")
        let attemptID = UUID()
        let assistant = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: attemptID)
        var frozen = try node()
        let frozenMessages = "[{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"old materials\"}]}]"
        frozen.parameters["messagesJSON"] = .text(frozenMessages)
        var session = ChatSession(title: "Partial answer")
        var attempt = ChatAttempt(id: attemptID, sessionID: session.id, userMessageID: user.id,
                              assistantMessageID: assistant.id, node: frozen,
                              messagesJSON: frozenMessages, inputs: [:], systemPrompt: "old system", status: .partial)
        attempt.rawText = "partial model output"
        session.messages = [user, assistant]; session.attempts = [attempt]
        session.selectedLeafID = assistant.id; session.configuration = frozen
        session.draft = "continue"
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, engine, store, root) = try await fixture(state)
        var current = frozen
        current.parameters["modelID"] = .text("text:current")
        current.parameters["temperature"] = .decimal(0.1)
        try chat.updateConfiguration(current, sessionID: session.id)
        try chat.setSystemPrompt("current system", sessionID: session.id)
        #expect(render(chat, model: model)["message-\(assistant.id.uuidString)"] != nil)
        #expect(ChatContextCommands.canAdopt(chat.selectedSession?.attempts.first, in: chat))
        let before = try #require(chat.selectedSession?.attempts.first)
        let draft = try #require(chat.selectedSession?.draft)
        let edited = "adopted continuation 👩🏽‍🎨"
        try ChatContextCommands.adopt(edited, messageID: assistant.id, sessionID: session.id, in: chat)
        #expect(chat.selectedSession?.attempts.first == before)
        #expect(chat.selectedSession?.draft == draft)
        #expect(chat.selectedSession?.contextChoices?.adopted[assistant.id] == edited)
        #expect(try chat.contextPreview(sessionID: session.id).messagesJSON.contains(edited))
        #expect(render(chat, model: model)["adopted-version-\(assistant.id.uuidString)"] != nil)
        #expect(render(chat, model: model, preview: true)["context-preview-\(session.id.uuidString)"] != nil)
        var inspected: [String: CGRect] = [:]
        let detail = ChatWorkbenchView(chat: chat, model: model, onChooseModel: {},
            onSavedAsset: { _ in }, onAssetsChanged: {}).observingLayout { inspected[$0] = $1 }
        let detailHost = NSHostingView(rootView: detail.requestInspectionPanel(before))
        detailHost.frame = .init(x: 0, y: 0, width: 760, height: 1000)
        detailHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        detailHost.layoutSubtreeIfNeeded()
        #expect(inspected["request-inspection-\(attemptID.uuidString)"] != nil)
        for field in ["input-system", "input-format"] {
            #expect(inspected["request-field-\(field)-\(attemptID.uuidString)"] != nil)
        }
        for section in ["source", "parameters", "memory", "media"] {
            #expect(inspected["request-section-\(section)-\(attemptID.uuidString)"] != nil)
        }
        #expect(chat.selectedSession?.draft == draft)
        let revision = try #require(chat.selectedSession?.contextChoices?.revisions.first)
        try ChatContextCommands.selectVersion(nil, messageID: assistant.id, sessionID: session.id, in: chat)
        #expect(chat.selectedSession?.contextChoices?.adopted[assistant.id] == nil)
        try ChatContextCommands.selectVersion(revision.id, messageID: assistant.id, sessionID: session.id, in: chat)
        #expect(chat.selectedSession?.contextChoices?.adopted[assistant.id] == edited)
        let inspection = ChatRequestInspection(attempt: before)
        #expect(inspection.sections.first(where: { $0.id == "input" })?.fields.contains {
            $0.id == "system" && $0.value == "old system"
        } == true)
        // The current local inspector shows decoded ordered parts; it does not
        // repeat raw JSON in the input summary. The frozen source stays exact.
        #expect(before.messagesJSON == frozenMessages)
        #expect(inspection.sections.first(where: { $0.id == "messages" })?.fields.contains {
            $0.id == "message.0" && $0.value == "Part 1 · text: old materials"
        } == true)
        #expect(inspection.sections.first(where: { $0.id == "parameters" })?.fields.contains {
            $0.id == "modelID" && $0.value == "text:fixture"
        } == true)
        #expect(chat.selectedSession?.configuration?.parameters["modelID"]?.string == "text:current")
        #expect(!inspection.redactedJSON.contains("old system"))
        #expect(!inspection.redactedJSON.contains("old materials"))
        try chat.setDefaultSystemPrompt("future only")
        #expect(chat.selectedSession?.systemPrompt == "current system")
        let second = try chat.newSession()
        #expect(chat.selectedSession?.id == second && chat.selectedSession?.systemPrompt == "future only")
        #expect(throws: (any Error).self) {
            try ChatContextCommands.adopt("wrong session", messageID: assistant.id, sessionID: session.id, in: chat)
        }
        #expect(await engine.submissions == 0)
        try await close(store, root: root)
    }
}
