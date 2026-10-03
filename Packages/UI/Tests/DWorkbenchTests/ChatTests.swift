import DInference
import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DWorkbench

private actor ChatFixtureEngine: InferenceEngine {
    private(set) var requests: [InferenceRequest] = []
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        let index = requests.count
        let final = "reply \(index) 👩🏽‍🎨 e\u{301}"
        return .init(id: request.id, events: AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(final)); continuation.finish()
        }, cancel: {}, outcome: {
            .completed(.init(textResponse: .init(rawText: final, finalText: final, finishReason: .stop)))
        })
    }
}

private actor ChatOutcomeGate {
    private var submitted = false
    private var open = false
    private var submissionWaiter: CheckedContinuation<Void, Never>?
    private var outcomeWaiter: CheckedContinuation<Void, Never>?
    func markSubmitted() {
        submitted = true; submissionWaiter?.resume(); submissionWaiter = nil
    }
    func waitSubmitted() async {
        if submitted { return }
        await withCheckedContinuation { submissionWaiter = $0 }
    }
    func waitOutcome() async {
        if open { return }
        await withCheckedContinuation { outcomeWaiter = $0 }
    }
    func release() { open = true; outcomeWaiter?.resume(); outcomeWaiter = nil }
}

private actor ChatGatedEngine: InferenceEngine {
    let gate = ChatOutcomeGate()
    private(set) var cancellations = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        await gate.markSubmitted()
        return .init(id: request.id, events: AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("partial 👩🏽‍🎨 e\u{301}")); continuation.finish()
        }, cancel: { await self.recordCancel() }, outcome: {
            await self.gate.waitOutcome(); return .cancelled
        })
    }
    private func recordCancel() { cancellations += 1 }
}

@Suite("Chat sidecar and service", .serialized) @MainActor
struct ChatTests {
    private func fixture() async throws -> (ProjectStore, ChatFixtureEngine, ChatController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("Chat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Conversation.dproject"), name: "Chat CPU")
        let engine = ChatFixtureEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "fixture", status: {
            .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
        }, shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let controller = ChatController(store: store) {
            WorkflowServices(store: store, session: runtime) { _, identity in
                .init(identity: identity, reference: .init(directory: root, revision: identity),
                      backendID: "fixture.text", operationID: WorkflowModelRoutes.qwen35,
                      textCapability: .init(maximumPromptTokens: 8192, maximumOutputTokens: 1024,
                                            profile: TextExecutionCapability.qwen35VLMProfile))
            }
        }
        await controller.load()
        return (store, engine, controller)
    }
    private func configure(_ controller: ChatController, session: UUID) throws {
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture")
        node.parameters["maximumPromptTokens"] = .integer(8192)
        try controller.updateConfiguration(node, sessionID: session)
    }
    private func imageData() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(.init(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage()), data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @Test func twoTurnsFreezeHistoryAndBranchWithoutLosingOriginal() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        try chat.setSystemPrompt("Local instructions", sessionID: id)
        try chat.updateDraft("first 👩🏽‍🎨 e\u{301}", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        let firstAssistant = try #require(chat.selectedSession?.selectedLeafID)
        let firstUser = try #require(chat.selectedPath.first?.id)
        try chat.updateDraft("second", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        let sent = await engine.requests
        #expect(sent.count == 2)
        if case .text(let second) = sent[1].input {
            #expect(second.messages?.count == 4)
            #expect(second.messages?.first?.role == .system)
            #expect(second.messages?.last?.role == .user)
        } else { Issue.record("Expected text request") }
        let sibling = try chat.editUserMessage(firstUser, text: "revised", sessionID: id)
        #expect(chat.selectedPath.last?.id == sibling)
        try chat.selectLeaf(firstAssistant, sessionID: id)
        #expect(chat.selectedPath.map(\.id).contains(firstUser))
        let fork = try chat.forkSession(id)
        #expect(chat.selectedSession?.originSessionID == id)
        #expect(chat.selectedSession?.id == fork)
        try await chat.flush()
        #expect((try await store.chatState()).sessions.count == 2)
        try await store.close()
    }
    @Test func interruptedAttemptReopensReadOnlyUntilExplicitAction() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        try chat.updateDraft("resume", sessionID: id)
        // Build a real validated initial record without invoking the fake engine.
        let user = ChatMessage(parentID: nil, role: .user, text: "resume")
        let assistant = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: UUID())
        var node = try #require(chat.selectedSession?.configuration)
        node.parameters["messagesJSON"] = .text("[]")
        var attempt = ChatAttempt(id: try #require(assistant.attemptID), sessionID: id, userMessageID: user.id,
                                  assistantMessageID: assistant.id, node: node, messagesJSON: "[]", inputs: [:], systemPrompt: "")
        attempt.rawText = "partial"
        var saved = chat.state
        let i = try #require(saved.sessions.firstIndex(where: { $0.id == id }))
        saved.sessions[i].messages = [user, assistant]; saved.sessions[i].attempts = [attempt]
        saved.sessions[i].selectedLeafID = assistant.id
        _ = try await store.saveChatState(saved, expectedRevision: (try await store.chatState()).revision)
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let restored = ChatController(store: reopened) { throw WorkflowIssue("unexpected inference") }
        await restored.load()
        #expect(restored.state.sessions.first?.attempts.first?.status == .interrupted)
        #expect(restored.state.sessions.first?.attempts.first?.rawText == "partial")
        #expect(await engine.requests.isEmpty)
        try await reopened.close()
    }
    @Test func sidecarRejectsUnknownFieldsAndStaleWrites() async throws {
        let (store, _, chat) = try await fixture()
        _ = try chat.newSession(); try await chat.flush()
        let state = try await store.chatState()
        await #expect(throws: (any Error).self) {
            _ = try await store.saveChatState(state, expectedRevision: state.revision - 1)
        }
        let sidecar = store.rootURL.appendingPathComponent("quick-chat.json")
        let original = try Data(contentsOf: sidecar)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["futureField"] = "must survive"
        let unknown = try JSONSerialization.data(withJSONObject: object)
        try unknown.write(to: sidecar)
        let rejected = ChatController(store: store) { throw WorkflowIssue("unexpected inference") }
        await rejected.load()
        #expect(!rejected.isLoaded)
        try chat.rename(try #require(chat.selectedSession?.id), title: "changed locally")
        await #expect(throws: (any Error).self) { try await chat.flush() }
        #expect(try Data(contentsOf: sidecar) == unknown)
        try await store.close()
    }

    @Test func frozenTextAndImageAttachmentsSurviveIndependentBackupRestore() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        let text = try await store.publishWorkflowAsset(data: Data("source 👩🏽‍🎨 e\u{301}".utf8), mediaType: "text/plain",
                                                        name: "notes.md", operationID: "d.asset.import").record.reference
        let image = try await store.publishWorkflowAsset(data: imageData(), mediaType: "image/png",
                                                         metadata: .init(width: 2, height: 2), name: "reference.png",
                                                         operationID: "d.asset.import").record.reference
        _ = try await chat.addAttachment(text, name: "notes.md", sessionID: id)
        _ = try await chat.addAttachment(image, name: "reference.png", sessionID: id)
        try chat.updateDraft("Describe", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        let request = try #require(await engine.requests.first)
        if case .text(let body) = request.input {
            #expect(body.allImages.count == 1)
            #expect(body.resolvedMessages.first?.parts.count == 3)
        } else { Issue.record("Expected text request") }
        try await chat.flush()
        let backup = store.rootURL.deletingLastPathComponent().appendingPathComponent("chat.dbackup")
        _ = try await store.createBackup(at: backup)
        try await store.close()
        let restoredURL = backup.deletingLastPathComponent().appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restoredURL)
        let restored = try await ProjectStore.open(at: restoredURL)
        let saved = try await restored.chatState()
        #expect(saved.sessions.first?.messages.first?.attachments.map(\.reference) == [text, image])
        #expect(try await restored.workflowData(text) == Data("source 👩🏽‍🎨 e\u{301}".utf8))
        #expect(try await restored.workflowData(image) == imageData())
        try await restored.close()
    }

    @Test func switchingSessionsDoesNotCancelAndCancellationWaitsForDrain() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("ChatGate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Gate.dproject"), name: "Chat gate")
        let engine = ChatGatedEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "fixture", status: {
            .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
        }, shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let chat = ChatController(store: store) {
            WorkflowServices(store: store, session: runtime) { _, identity in
                .init(identity: identity, reference: .init(directory: root, revision: identity),
                      backendID: "fixture.text", operationID: WorkflowModelRoutes.qwen35,
                      textCapability: .init(maximumPromptTokens: 8192, maximumOutputTokens: 1024,
                                            profile: TextExecutionCapability.qwen35VLMProfile))
            }
        }
        await chat.load()
        let first = try chat.newSession(); try configure(chat, session: first)
        try chat.updateDraft("start", sessionID: first)
        try await chat.send(sessionID: first)
        await engine.gate.waitSubmitted()
        let second = try chat.newSession()
        #expect(chat.selectedSession?.id == second)
        #expect(chat.activeSessionID == first)
        let cancellation = Task { await chat.cancel() }
        await Task.yield()
        #expect(chat.isRunning)
        await engine.gate.release()
        await cancellation.value
        #expect(!chat.isRunning)
        #expect(chat.selectedSession?.id == second)
        #expect(chat.state.sessions.first?.attempts.first?.rawText == "partial 👩🏽‍🎨 e\u{301}")
        #expect(chat.state.sessions.first?.attempts.first?.status == .partial)
        #expect(await engine.cancellations > 0)
        try await chat.flush(); try await store.close()
    }

    @Test func failedAssetPublicationRetriesWithoutNewInference() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        let obstruction = store.rootURL.appendingPathComponent("WorkflowAssets")
        try Data("fixture obstruction".utf8).write(to: obstruction)
        try chat.updateDraft("save once", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        #expect(chat.pendingSaveAttemptID != nil)
        #expect(await engine.requests.count == 1)
        try FileManager.default.removeItem(at: obstruction)
        await chat.retrySave()
        #expect(chat.pendingSaveAttemptID == nil)
        #expect(chat.state.sessions.first?.attempts.first?.status == .completed)
        #expect(await engine.requests.count == 1)
        try await chat.flush(); try await store.close()
    }

    @Test func sidecarPublicationFailureRetriesOnlyItsOwnBytes() async throws {
        let (store, engine, chat) = try await fixture()
        _ = try chat.newSession(); try await chat.flush()
        let before = try await store.chatState()
        var candidate = before
        candidate.sessions[0].title = "durable candidate"
        await #expect(throws: (any Error).self) {
            _ = try await store.saveChatState(candidate, expectedRevision: before.revision,
                                              afterPublication: { throw WorkflowIssue("controlled post-publication failure") })
        }
        let revision = try await store.saveChatState(candidate, expectedRevision: before.revision)
        #expect(revision == before.revision + 2)
        #expect((try await store.chatState()).sessions[0].title == "durable candidate")
        #expect(await engine.requests.isEmpty)
        try await store.close()
    }
}
