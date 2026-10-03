import DInference
import Foundation
import Darwin
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DWorkbench

private actor ChatFixtureEngine: InferenceEngine {
    private(set) var requests: [InferenceRequest] = []
    private var finishReason: TextFinishReason = .stop
    func setFinishReason(_ reason: TextFinishReason) { finishReason = reason }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        let index = requests.count
        let reason = finishReason
        let final = "reply \(index) 👩🏽‍🎨 e\u{301}"
        return .init(id: request.id, events: AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(final)); continuation.finish()
        }, cancel: {}, outcome: {
            .completed(.init(textResponse: .init(rawText: final, finalText: final, finishReason: reason)))
        })
    }
}

private actor ChatOutcomeGate {
    private var submitted = false
    private var open = false
    private var submissionWaiter: CheckedContinuation<Void, Never>?
    private var outcomeWaiters: [CheckedContinuation<Void, Never>] = []
    func markSubmitted() {
        submitted = true; submissionWaiter?.resume(); submissionWaiter = nil
    }
    func waitSubmitted() async {
        if submitted { return }
        await withCheckedContinuation { submissionWaiter = $0 }
    }
    func waitOutcome() async {
        if open { return }
        await withCheckedContinuation { outcomeWaiters.append($0) }
    }
    func release() {
        open = true
        let pending = outcomeWaiters; outcomeWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
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
    @Test func newCandidateChangesActualSeedButReplayKeepsFrozenRequest() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        var node = try #require(chat.selectedSession?.configuration)
        node.parameters["seed"] = .text("18446744073709551614")
        try chat.updateConfiguration(node, sessionID: id)
        try chat.setSystemPrompt("original system", sessionID: id)
        try chat.updateDraft("fixed question", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        let first = try #require(chat.selectedSession?.attempts.first)
        try await chat.regenerate(first.userMessageID, sessionID: id); await chat.waitForCompletion()
        try chat.setSystemPrompt("changed later", sessionID: id)
        node.parameters["temperature"] = .decimal(0.1)
        try chat.updateConfiguration(node, sessionID: id)
        let unfinishedField = id.uuidString + ":temperature"
        chat.parameterText[unfinishedField] = "-"
        chat.invalidParameterFields.insert(unfinishedField)
        await #expect(throws: (any Error).self) {
            try await chat.regenerate(first.userMessageID, sessionID: id)
        }
        try await chat.reproduce(first.id, sessionID: id); await chat.waitForCompletion()
        #expect(chat.parameterText[unfinishedField] == "-")
        #expect(chat.invalidParameterFields.contains(unfinishedField))
        let requests = await engine.requests
        #expect(requests.count == 3)
        if case .text(let original) = requests[0].input, case .text(let newer) = requests[1].input,
           case .text(let replay) = requests[2].input {
            #expect(original.seed == 18_446_744_073_709_551_614)
            #expect(newer.seed != original.seed)
            #expect(replay == original)
        } else { Issue.record("Expected text requests") }
        #expect(chat.selectedSession?.attempts.last?.replayedAttemptID == first.id)
        #expect(chat.selectedSession?.attempts.first == first)
        try await chat.flush()
        let saved = try await store.chatState()
        #expect(saved.sessions.first?.attempts.last?.replayedAttemptID == first.id)
        try await chat.prepareForTermination(); try await store.close()
    }

    @Test func legacyWhitespacePresetRemainsReadableWhileNewWritesRejectIt() async throws {
        let (store, _, chat) = try await fixture()
        var legacy = try await store.chatState()
        legacy.presets = [.init(name: " ", prompt: "old preserved instructions")]
        _ = try await store.saveChatState(legacy, expectedRevision: legacy.revision)
        let reader = ChatController(store: store) { throw WorkflowIssue("No inference in migration test") }
        await reader.load()
        #expect(reader.isLoaded && reader.error == nil)
        _ = try reader.newSession()
        try await reader.flush()
        #expect(try await store.chatState().presets == legacy.presets)
        #expect(throws: (any Error).self) { try reader.setPreset(.init(name: " ", prompt: "new")) }
        #expect(chat.state.presets.isEmpty)
        try await store.close()
    }

    @Test func comparisonKeepsFrozenInputAndPresetExchangeDoesNotRewriteHistory() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        try chat.setSystemPrompt("original rules", sessionID: id)
        try await chat.sendAfterDraft("fixed question", sessionID: id)
        let original = try #require(chat.selectedSession?.attempts.first)
        let unbound = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        let beforeInvalidComparison = chat.state
        await #expect(throws: (any Error).self) {
            try await chat.compare(original.id, configuration: unbound, sessionID: id)
        }
        #expect(chat.state == beforeInvalidComparison && chat.saveIssue == nil)
        try chat.setSystemPrompt("different future rules", sessionID: id)
        try chat.updateDraft("unsubmitted future question", sessionID: id)
        var alternative = try #require(chat.selectedSession?.configuration)
        alternative.parameters["temperature"] = .decimal(0.2)
        alternative.parameters["modelID"] = .text("text:another-fixture")
        try await chat.compare(original.id, configuration: alternative, sessionID: id)
        await chat.waitForCompletion()
        let compared = try #require(chat.selectedSession?.attempts.last)
        #expect(compared.messagesJSON == original.messagesJSON && compared.inputs == original.inputs)
        #expect(compared.systemPrompt == original.systemPrompt && compared.comparisonSourceAttemptID == original.id)
        #expect(compared.node.parameters["modelID"] == alternative.parameters["modelID"])
        #expect(chat.selectedSession?.draft == "unsubmitted future question")
        #expect(chat.selectedSession?.attempts.first == original)
        #expect(await engine.requests.count == 2)
        #expect(ChatRequestInspection(attempt: compared).redactedJSON.contains(original.id.uuidString))

        let preset = ChatPromptPreset(name: "Translate", prompt: "new system", configuration: alternative,
                                      selectionInstruction: "Explain the quoted selection")
        try chat.setPreset(preset); try chat.applyPreset(preset.id, sessionID: id)
        let applied = try #require(chat.selectedSession)
        var updated = preset; updated.prompt = "changed preset only"
        try chat.setPreset(updated)
        #expect(chat.selectedSession == applied)
        let copiedID = try chat.copyPreset(preset.id, name: "Copy")
        #expect(copiedID != preset.id)
        let bytes = try ChatPresetFile.encode([preset])
        #expect(try ChatPresetFile.decode(bytes) == [preset])
        try chat.importPresets(bytes)
        #expect(chat.state.presets.count == 3)
        #expect(chat.state.presets.first?.prompt == "changed preset only")
        #expect(chat.state.presets.last?.id != preset.id)
        var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["unexpected"] = true
        #expect(throws: (any Error).self) { try chat.importPresets(JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "unexpected"); object["version"] = true
        #expect(throws: (any Error).self) { try ChatPresetFile.decode(JSONSerialization.data(withJSONObject: object)) }
        #expect(chat.state.presets.count == 3)
        try await chat.flush()
        #expect(try await store.chatState() == chat.state)
        try await store.close()
    }

    @Test func partialAnswerAdoptionPreservesOutputAndReopensAsExplicitVersion() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        await engine.setFinishReason(.length)
        try chat.updateDraft("first", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        let original = try #require(chat.selectedSession?.attempts.first)
        #expect(original.status == .partial)
        try chat.updateDraft("continue", sessionID: id)
        await #expect(throws: (any Error).self) { try await chat.send(sessionID: id) }
        #expect(await engine.requests.count == 1)
        let revised = "人工采用 👩🏽‍🎨 e\u{301}，保留这个部分继续。"
        let revision = try chat.adoptAnswer(original.assistantMessageID, text: revised, sessionID: id)
        let preview = try chat.contextPreview(sessionID: id)
        #expect(preview.messagesJSON.contains(revised))
        await engine.setFinishReason(.stop)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        #expect(chat.selectedSession?.attempts.first == original)
        #expect(chat.selectedSession?.attempts.last?.messagesJSON == preview.messagesJSON)
        #expect(chat.selectedSession?.contextChoices?.revisions.first?.id == revision)
        try await chat.flush()
        let durable = try await store.chatState()
        #expect(durable.sessions.first?.contextChoices?.adopted[original.assistantMessageID] == revised)
        let backup = store.rootURL.deletingLastPathComponent().appendingPathComponent("adopted.dbackup")
        _ = try await store.createBackup(at: backup)
        let restoredURL = backup.deletingLastPathComponent().appendingPathComponent("AdoptedRestored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restoredURL)
        let restored = try await ProjectStore.open(at: restoredURL)
        #expect(try await restored.chatState() == durable)
        try await restored.close()
        try await chat.prepareForTermination(); try await store.close()
    }

    @Test func contextPreviewMatchesReplyToEditedUserWithoutExtraDraftOrSeedMutation() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        try await chat.sendAfterDraft("question", sessionID: id)
        let original = try #require(chat.selectedSession?.messages.first)
        _ = try chat.editUserMessage(original.id, text: "edited 中文", sessionID: id)
        let stateBefore = chat.state
        let preview = try chat.contextPreview(sessionID: id)
        #expect(chat.state == stateBefore)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        #expect(chat.selectedSession?.attempts.last?.messagesJSON == preview.messagesJSON)
        #expect(await engine.requests.count == 2)
        try await chat.flush(); try await store.close()
    }

    @Test func contextChoicesExcludeMessagesWithoutDeletingHistoryAndPreserveManualTitle() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        try chat.rename(id, title: "手动题目")
        try await chat.sendAfterDraft("question", sessionID: id)
        #expect(chat.selectedSession?.title == "手动题目")
        let before = try #require(chat.selectedSession)
        var choices = before.contextChoices ?? .init()
        choices.excludedMessageIDs = [try #require(before.messages.last?.id)]
        choices.tags = ["资料", "👩🏽‍🎨"]; choices.pinned = true
        try chat.updateContextChoices(choices, sessionID: id)
        try chat.updateDraft("next", sessionID: id)
        let preview = try chat.contextPreview(sessionID: id)
        #expect(!preview.messagesJSON.contains("reply 1"))
        #expect(preview.messagesJSON.contains("question"))
        #expect(chat.selectedSession?.messages == before.messages)
        try chat.setDeleted(true, sessionID: id)
        await #expect(throws: (any Error).self) { try await chat.send(sessionID: id) }
        #expect(await engine.requests.count == 1)
        try chat.setDeleted(false, sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        #expect(chat.selectedSession?.attempts.last?.messagesJSON == preview.messagesJSON)
        try await chat.flush(); try await store.close()
    }

    @Test func deletionDuringAssetPreparationCannotSubmitOrAddAttempt() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        let ref = try await store.publishWorkflowAsset(data: Data("material".utf8), mediaType: "text/plain",
            name: "material.txt", operationID: "d.asset.import").record.reference
        _ = try await chat.addAttachment(ref, name: "material.txt", sessionID: id)
        try chat.updateDraft("request", sessionID: id); try await chat.flush()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await store.holdChatReadFixture(entered: signal, release: release) }
        defer { release.signal() }
        for await _ in entered { break }
        var started = false
        let submission = Task { @MainActor in
            started = true
            try await chat.send(sessionID: id)
        }
        for _ in 0..<100 {
            if started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started)
        try chat.setDeleted(true, sessionID: id)
        release.signal(); await blocker.value
        await #expect(throws: (any Error).self) { try await submission.value }
        #expect(await engine.requests.isEmpty)
        #expect(chat.selectedSession?.attempts.isEmpty == true)
        try await chat.flush(); try await store.close()
    }

    @Test func newConversationDefaultsUseOnlyInjectedSuiteAndDoNotRewriteExistingSessions() async throws {
        let (store, _, oldChat) = try await fixture()
        let suite = "D.Chat.Defaults." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let chat = ChatController(store: store, settings: settings) { throw WorkflowIssue("No model calls in defaults test") }
        await chat.load()
        let (otherStore, _, _) = try await fixture()
        let other = ChatController(store: otherStore, settings: settings) { throw WorkflowIssue("No model calls in defaults test") }
        await other.load()
        let first = try chat.newSession()
        try chat.setDefaultSystemPrompt("new rules 中文")
        let second = try chat.newSession()
        #expect(chat.state.sessions.first { $0.id == first }?.systemPrompt == "")
        #expect(chat.state.sessions.first { $0.id == second }?.systemPrompt == "new rules 中文")
        _ = try other.newSession()
        #expect(other.selectedSession?.systemPrompt == "new rules 中文")
        try chat.setSystemPrompt("", sessionID: second)
        #expect(chat.selectedSession?.systemPrompt == "")
        #expect(settings.string(forKey: "D.Chat.NewSessionSystemPrompt.v1") == "new rules 中文")
        #expect(oldChat.defaultSystemPrompt == "")
        try chat.setDefaultSystemPrompt("")
        _ = try other.newSession()
        #expect(other.selectedSession?.systemPrompt == "")
        try await other.flush(); try await otherStore.close()
        try await chat.flush(); try await store.close()
    }

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
    @Test func incompleteParametersStayWithControllerAndBlockOnlyTheirOwner() async throws {
        let (store, engine, chat) = try await fixture()
        let a = try chat.newSession(); try configure(chat, session: a)
        try chat.updateDraft("first", sessionID: a)
        try await chat.send(sessionID: a); await chat.waitForCompletion()
        let user = try #require(chat.selectedPath.first)
        let field = a.uuidString + ":temperature"
        chat.parameterText[field] = "-"; chat.invalidParameterFields.insert(field)
        let b = try chat.newSession(); try configure(chat, session: b)
        try chat.updateDraft("independent", sessionID: b)
        try await chat.send(sessionID: b); await chat.waitForCompletion()
        try chat.selectSession(a)
        #expect(chat.parameterText[field] == "-")
        try chat.updateDraft("next", sessionID: a)
        await #expect(throws: (any Error).self) { try await chat.send(sessionID: a) }
        await #expect(throws: (any Error).self) { try await chat.regenerate(user.id, sessionID: a) }
        #expect(await engine.requests.count == 2)
        chat.parameterText[field] = "0.5"; chat.invalidParameterFields.remove(field)
        try await chat.regenerate(user.id, sessionID: a); await chat.waitForCompletion()
        #expect(await engine.requests.count == 3)
        var replacement = try #require(chat.selectedSession?.configuration)
        replacement.parameters["temperature"] = .decimal(0.7)
        chat.parameterText[field] = "0.2"
        let otherField = b.uuidString + ":temperature"
        chat.parameterText[otherField] = "-"; chat.invalidParameterFields.insert(otherField)
        try chat.updateConfiguration(replacement, sessionID: a)
        #expect(chat.parameterText[field] == "0.2")
        try chat.selectModelConfiguration(replacement, sessionID: a)
        #expect(chat.parameterText[field] == nil)
        #expect(chat.selectedSession?.configuration?.parameters["temperature"] == .decimal(0.7))
        #expect(chat.parameterText[otherField] == "-")
        #expect(chat.hasInvalidParameterText(sessionID: b))
        try await chat.prepareForTermination(); try await store.close()
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
    @Test func firstEmojiPromptKeepsFullMessageAndPersistsBoundedTitle() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        let prompt = String(repeating: "👩🏽‍🎨", count: 40)
        #expect(prompt.utf8.count == 600)
        try chat.updateDraft(prompt, sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        try chat.state.validate()
        try await chat.flush()
        let saved = try await store.chatState()
        let session = try #require(saved.sessions.first(where: { $0.id == id }))
        #expect(session.title == String(repeating: "👩🏽‍🎨", count: 34))
        #expect(session.title.utf8.count == 510)
        #expect(session.messages.first?.text == prompt)
        let frozen = try #require(session.attempts.first?.messagesJSON)
        let messages = try #require(JSONSerialization.jsonObject(with: Data(frozen.utf8)) as? [[String: Any]])
        let parts = try #require(messages.last?["parts"] as? [[String: Any]])
        #expect(parts.last?["text"] as? String == prompt)
        #expect(await engine.requests.count == 1)
        #expect(chat.saveIssue == nil)
        try await store.close()
    }
    @Test func forkOfMaximumByteManualTitlePersistsWithoutChangingSource() async throws {
        let (store, _, chat) = try await fixture()
        let source = try chat.newSession()
        let originalTitle = String(repeating: "A", count: 512)
        try chat.rename(source, title: originalTitle)
        let fork = try chat.forkSession(source)
        try chat.state.validate()
        try await chat.flush()
        let saved = try await store.chatState()
        let original = try #require(saved.sessions.first(where: { $0.id == source }))
        let branch = try #require(saved.sessions.first(where: { $0.id == fork }))
        let suffix = " · 分支"
        #expect(original.title == originalTitle)
        #expect(branch.title == String(originalTitle.prefix(512 - suffix.utf8.count)) + suffix)
        #expect(branch.title.utf8.count == 512)
        #expect(branch.originSessionID == source)
        #expect(chat.saveIssue == nil)
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

    @Test func readsAndBackupDoNotRenewStaleChatWriteAuthority() async throws {
        let (store, _, chat) = try await fixture()
        let id = try chat.newSession(); try await chat.flush()
        let sidecar = store.rootURL.appendingPathComponent("quick-chat.json")
        var external = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        var sessions = try #require(external["sessions"] as? [[String: Any]])
        sessions[0]["title"] = "external title B"
        external["sessions"] = sessions
        let bytes = try JSONSerialization.data(withJSONObject: external, options: [.sortedKeys])
        try bytes.write(to: sidecar, options: .atomic)
        #expect((try await store.chatState()).sessions[0].title == "external title B")
        _ = try await store.backupPlan()
        try chat.rename(id, title: "stale controller edit")
        await #expect(throws: ProjectStoreError.externalModification) { try await chat.flush() }
        #expect(try Data(contentsOf: sidecar) == bytes)
        try await store.close()
    }

    @Test func repeatedMediaOccurrencesKeepDistinctOrderedPortItems() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        let image = try await store.publishWorkflowAsset(data: imageData(), mediaType: "image/png",
                                                         metadata: .init(width: 2, height: 2), name: "repeat.png",
                                                         operationID: "d.asset.import").record.reference
        _ = try await chat.addAttachment(image, name: "repeat.png", sessionID: id)
        _ = try await chat.addAttachment(image, name: "repeat again.png", sessionID: id)
        try chat.updateDraft("first", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        let first = try #require(chat.state.sessions.first?.attempts.first)
        if case .list(_, let items)? = first.inputs["images"]?.datum {
            #expect(items.count == 2)
            #expect(Set(items.map(\.id)).count == 2)
            #expect(items.map(\.value.assetReferences) == [[image], [image]])
        } else { Issue.record("Expected first image list") }
        _ = try await chat.addAttachment(image, name: "repeat next turn.png", sessionID: id)
        try chat.updateDraft("second", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        let second = try #require(chat.state.sessions.first?.attempts.last)
        if case .list(_, let items)? = second.inputs["images"]?.datum {
            #expect(items.count == 3)
            #expect(Set(items.map(\.id)).count == 3)
            #expect(items.map(\.value.assetReferences) == [[image], [image], [image]])
        } else { Issue.record("Expected second image list") }
        let messages = try #require(JSONSerialization.jsonObject(with: Data(second.messagesJSON.utf8)) as? [[String: Any]])
        let imageIndexes = messages.flatMap { message in
            (message["parts"] as? [[String: Any]] ?? []).compactMap { part -> Int? in
                guard part["type"] as? String == "image" else { return nil }
                return part["index"] as? Int
            }
        }
        #expect(imageIndexes == [0, 1, 2])
        let requests = await engine.requests
        #expect(requests.count == 2)
        if requests.count == 2, case .text(let body) = requests[1].input {
            #expect(body.allImages.count == 3)
            #expect(body.resolvedMessages.count == 3)
        }
        try await chat.flush(); try await store.close()
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
        await #expect(throws: (any Error).self) { try await chat.prepareForBackup() }
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
        try await chat.prepareForBackup()
        try await chat.flush(); try await store.close()
    }

    @Test func failedAssetPublicationRetriesWithoutNewInference() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        // A real owned directory produces retryable mkdir EACCES. A regular file
        // at this path is unsafePath and must remain a terminal protection failure.
        let obstruction = store.rootURL.appendingPathComponent("WorkflowAssets")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: obstruction.path)[.posixPermissions])
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: obstruction.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: obstruction.path)
        try chat.updateDraft("save once", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        try #require(chat.pendingSaveAttemptID != nil)
        #expect(chat.error == WorkflowSaveFailure(reason: ProjectStoreError.io(String(cString: strerror(EACCES))).localizedDescription).localizedDescription)
        await #expect(throws: (any Error).self) { try await chat.prepareForBackup() }
        #expect(await engine.requests.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: obstruction.path)
        await chat.retrySave()
        #expect(chat.pendingSaveAttemptID == nil)
        #expect(chat.state.sessions.first?.attempts.first?.status == .completed)
        #expect(await engine.requests.count == 1)
        try await chat.flush(); try await store.close()
    }

    @Test func terminalRetryFailureClearsPendingAndKeepsEvidence() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        // A real owned directory produces retryable mkdir EACCES. A regular file
        // at this path is unsafePath and must remain a terminal protection failure.
        let obstruction = store.rootURL.appendingPathComponent("WorkflowAssets")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: obstruction.path)[.posixPermissions])
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: obstruction.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: obstruction.path)
        try chat.updateDraft("retain preview", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        try #require(chat.pendingSaveAttemptID != nil)
        #expect(chat.error == WorkflowSaveFailure(reason: ProjectStoreError.io(String(cString: strerror(EACCES))).localizedDescription).localizedDescription)
        let preview = try #require(chat.state.sessions.first?.attempts.first?.rawText)
        #expect(!preview.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: obstruction.path)
        let manifest = store.rootURL.appendingPathComponent(ProjectStore.manifestFilename)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["name"] = "external project edit"
        let externalBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try externalBytes.write(to: manifest, options: .atomic)
        await chat.retrySave()
        #expect(chat.pendingSaveAttemptID == nil)
        #expect(chat.state.sessions.first?.attempts.first?.status == .failed)
        #expect(chat.state.sessions.first?.attempts.first?.rawText == preview)
        #expect(chat.state.sessions.first?.attempts.first?.issue == ProjectStoreError.externalModification.localizedDescription)
        #expect(chat.error == ProjectStoreError.externalModification.localizedDescription)
        await chat.retrySave()
        #expect(chat.error == ProjectStoreError.externalModification.localizedDescription)
        #expect(await engine.requests.count == 1)
        #expect(try Data(contentsOf: manifest) == externalBytes)
        try await chat.prepareForTermination()
        try await store.close(preserveExternalChanges: true)
    }

    @Test func forkPartialCannotBorrowCompletedOriginAttempt() async throws {
        let (store, engine, chat) = try await fixture()
        let origin = try chat.newSession(); try configure(chat, session: origin)
        // A real owned directory produces retryable mkdir EACCES. A regular file
        // at this path is unsafePath and must remain a terminal protection failure.
        let obstruction = store.rootURL.appendingPathComponent("WorkflowAssets")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: obstruction.path)[.posixPermissions])
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: obstruction.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: obstruction.path)
        try chat.updateDraft("origin", sessionID: origin)
        try await chat.send(sessionID: origin); await chat.waitForCompletion()
        try #require(chat.pendingSaveAttemptID != nil)
        #expect(chat.error == WorkflowSaveFailure(reason: ProjectStoreError.io(String(cString: strerror(EACCES))).localizedDescription).localizedDescription)
        #expect(chat.state.sessions.first?.attempts.first?.status == .partial)
        let fork = try chat.forkSession(origin)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: obstruction.path)
        await chat.retrySave()
        #expect(chat.state.sessions.first?.attempts.first?.status == .completed)
        #expect(chat.state.sessions.last?.attempts.first?.status == .partial)
        try chat.updateDraft("must reject partial history", sessionID: fork)
        await #expect(throws: (any Error).self) { try await chat.send(sessionID: fork) }
        #expect(await engine.requests.count == 1)
        #expect(chat.state.sessions.last?.attempts.first?.status == .partial)
        try await chat.flush(); try await store.close()
    }

    @Test func unsafeAssetDirectoryIsTerminalAndPreservesObstructionAndPreview() async throws {
        let (store, engine, chat) = try await fixture()
        let id = try chat.newSession(); try configure(chat, session: id)
        let obstruction = store.rootURL.appendingPathComponent("WorkflowAssets")
        let original = Data("fixture obstruction".utf8)
        try original.write(to: obstruction)
        try chat.updateDraft("retain unsafe path evidence", sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        #expect(chat.pendingSaveAttemptID == nil)
        #expect(chat.error == ProjectStoreError.unsafePath("WorkflowAssets").localizedDescription)
        #expect(chat.state.sessions.first?.attempts.first?.status == .partial)
        #expect(chat.state.sessions.first?.attempts.first?.rawText.isEmpty == false)
        await chat.retrySave()
        #expect(chat.pendingSaveAttemptID == nil)
        #expect(await engine.requests.count == 1)
        #expect(try Data(contentsOf: obstruction) == original)
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

@MainActor private extension ChatController {
    func sendAfterDraft(_ text: String, sessionID: UUID) async throws {
        try updateDraft(text, sessionID: sessionID)
        try await send(sessionID: sessionID); await waitForCompletion()
    }
}

private extension ProjectStore {
    func holdChatReadFixture(entered: AsyncStream<Void>.Continuation, release: DispatchSemaphore) {
        entered.yield(()); entered.finish()
        // Test-only actor occupation; bounded even if the test fails before release.
        _ = release.wait(timeout: .now() + 3)
    }
}
