import DInference
import DWorkbench
import Foundation
import Testing
@testable import UI

private actor ConfigurationPanelEngine: InferenceEngine {
    private(set) var requests: [InferenceRequest] = []
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func setHeld(_ value: Bool) {
        held = value
        if !value {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
    private func waitIfHeld() async {
        if !held { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        let answer = "answer \(requests.count) 👩🏽‍🎨"
        return .init(id: request.id, events: AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(answer))
            continuation.finish()
        }, cancel: {}, outcome: {
            await self.waitIfHeld()
            return .completed(.init(textResponse: .init(rawText: answer, finalText: answer, finishReason: .stop)))
        })
    }
}

@Suite("Chat configuration panels", .serialized)
@MainActor struct ChatConfigurationPanelsTests {
    private func fixture() async throws -> (ProjectStore, ConfigurationPanelEngine, ChatController, URL) {
        let root = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("chat-configuration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Fixture.dproject"),
            name: "Configuration panel fixture")
        let engine = ConfigurationPanelEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "configuration.fixture",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let chat = ChatController(store: store) {
            WorkflowServices(store: store, session: runtime) { _, identity in
                .init(identity: identity, reference: .init(directory: root, revision: identity),
                      backendID: "fixture.text", operationID: WorkflowModelRoutes.qwen35,
                      textCapability: .init(maximumPromptTokens: 8192, maximumOutputTokens: 1024,
                                            profile: TextExecutionCapability.qwen35VLMProfile))
            }
        }
        await chat.load()
        return (store, engine, chat, root)
    }

    private func configuration() throws -> WorkflowNode {
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture")
        node.parameters["maximumPromptTokens"] = .integer(8192)
        return node
    }

    private func close(_ store: ProjectStore, root: URL) async throws {
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }

    @Test func presetManagementWithoutSessionDoesNotCreateOrRunConversation() async throws {
        let (store, engine, chat, root) = try await fixture()
        #expect(chat.state.sessions.isEmpty && chat.state.selectedSessionID == nil)
        var preset = ChatPromptPreset(name: "Rules", prompt: "Be clear")
        try ChatConfigurationActions.savePreset(preset, captureCurrentConfiguration: false, sessionID: nil, chat: chat)
        preset.prompt = "Preserve uncertainty"
        try ChatConfigurationActions.savePreset(preset, captureCurrentConfiguration: false, sessionID: nil, chat: chat)
        let copy = try chat.copyPreset(preset.id, name: "Copy")
        try chat.removePreset(copy)
        #expect(throws: (any Error).self) {
            try ChatConfigurationActions.savePreset(preset, captureCurrentConfiguration: true, sessionID: nil, chat: chat)
        }
        #expect(chat.state.sessions.isEmpty && chat.state.selectedSessionID == nil)
        #expect(await engine.requests.isEmpty)
        try await chat.flush()
        #expect(try await store.chatState().presets == [preset])
        try await close(store, root: root)
    }

    @Test func assistanceGroupsMergeIntoLatestOptionsWithoutOverwritingOtherGroups() {
        let current = ChatAssistanceOptions(summary: true, title: false, tags: true, followUps: false,
            memoryMode: .suggest, memoryTarget: .personal,
            outputTokenBudgets: .init(summary: 101, title: 102, tags: 103, followUps: 104, memory: 105),
            summaryThresholdEstimatedTokens: 800)
        let draft = ChatAssistanceOptions(summary: false, title: true, tags: false, followUps: true,
            memoryMode: .off, memoryTarget: nil,
            outputTokenBudgets: .init(summary: 201, title: 202, tags: 203, followUps: 204, memory: 205),
            summaryThresholdEstimatedTokens: 900)
        let summary = ChatAssistanceSection.summary.merging(draft, into: current)
        #expect(!summary.summary && summary.summaryThresholdEstimatedTokens == 900)
        #expect(summary.memoryMode == current.memoryMode && summary.memoryTarget == current.memoryTarget)
        #expect(summary.title == current.title && summary.tags == current.tags && summary.followUps == current.followUps)
        #expect(summary.outputTokenBudgets == .init(summary: 201, title: 102, tags: 103, followUps: 104, memory: 105))
        let memory = ChatAssistanceSection.memory.merging(draft, into: current)
        #expect(memory.memoryMode == .off && memory.memoryTarget == nil)
        #expect(memory.summary && memory.summaryThresholdEstimatedTokens == 800)
        #expect(memory.title == current.title && memory.tags == current.tags && memory.followUps == current.followUps)
        #expect(memory.outputTokenBudgets == .init(summary: 101, title: 102, tags: 103, followUps: 104, memory: 205))
        let organization = ChatAssistanceSection.organization.merging(draft, into: current)
        #expect(organization.title && !organization.tags && organization.followUps)
        #expect(organization.summary && organization.summaryThresholdEstimatedTokens == 800)
        #expect(organization.memoryMode == current.memoryMode && organization.memoryTarget == current.memoryTarget)
        #expect(organization.outputTokenBudgets == .init(summary: 101, title: 202, tags: 203, followUps: 204, memory: 105))
    }

    @Test func presetCaptureRejectsIncompleteNumberAndApplyLeavesDraftAndHistoryUntouched() async throws {
        let (store, _, chat, root) = try await fixture()
        let id = try chat.newSession()
        try chat.updateConfiguration(try configuration(), sessionID: id)
        try chat.setSystemPrompt("Original system", sessionID: id)
        try chat.updateDraft("Unsent original draft", sessionID: id)
        let proposed = ChatPromptPreset(name: "Explain selection", prompt: "Explain clearly",
            selectionInstruction: "Explain the selected passage")
        let field = id.uuidString + ":temperature"
        chat.parameterText[field] = "-"
        chat.invalidParameterFields.insert(field)
        #expect(throws: (any Error).self) {
            try ChatConfigurationActions.savePreset(proposed, captureCurrentConfiguration: true,
                sessionID: id, chat: chat)
        }
        #expect(chat.state.presets.isEmpty)
        #expect(chat.selectedSession?.draft == "Unsent original draft")

        chat.invalidParameterFields.remove(field)
        chat.parameterText.removeValue(forKey: field)
        try ChatConfigurationActions.savePreset(proposed, captureCurrentConfiguration: true,
            sessionID: id, chat: chat)
        let saved = try #require(chat.state.presets.first)
        #expect(saved.configuration == chat.selectedSession?.configuration)
        #expect(saved.selectionInstruction == "Explain the selected passage")
        #expect(chat.selectedSession?.systemPrompt == "Original system")

        let duplicateID = try chat.copyPreset(saved.id, name: "Explain copy")
        #expect(duplicateID != saved.id)
        #expect(chat.state.presets.first(where: { $0.id == duplicateID })?.configuration == saved.configuration)
        try chat.applyPreset(saved.id, sessionID: id)
        #expect(chat.selectedSession?.systemPrompt == "Explain clearly")
        #expect(chat.selectedSession?.configuration == saved.configuration)
        #expect(chat.selectedSession?.draft == "Unsent original draft")
        var edited = saved; edited.prompt = "Updated for later use"
        try ChatConfigurationActions.savePreset(edited, captureCurrentConfiguration: false,
            sessionID: id, chat: chat)
        #expect(chat.selectedSession?.systemPrompt == "Explain clearly")
        try chat.removePreset(duplicateID)
        #expect(chat.state.presets.map(\.id) == [saved.id])
        try await chat.flush()
        #expect(try await store.chatState().presets == chat.state.presets)
        try await close(store, root: root)
    }

    @Test func comparisonUsesExactFrozenInputAndChoosingOnlyMovesLeaf() async throws {
        let (store, engine, chat, root) = try await fixture()
        let id = try chat.newSession()
        try chat.updateConfiguration(try configuration(), sessionID: id)
        try chat.setSystemPrompt("Frozen rules", sessionID: id)
        try chat.updateDraft("Same user question", sessionID: id)
        try await chat.send(sessionID: id)
        await chat.waitForCompletion()
        let source = try #require(chat.selectedSession?.attempts.first)
        let originalOutput = source.rawText

        var current = try #require(chat.selectedSession?.configuration)
        current.parameters["temperature"] = .decimal(0.2)
        current.parameters["modelID"] = .text("text:another-fixture")
        try chat.updateConfiguration(current, sessionID: id)
        try chat.setSystemPrompt("Future rules only", sessionID: id)
        try chat.updateDraft("Keep this unsent draft", sessionID: id)
        let before = try #require(chat.selectedSession)
        #expect(ChatConfigurationActions.canCompare(before, source: source, chat: chat))
        try await ChatConfigurationActions.compareCurrent(source, sessionID: id, chat: chat)
        await chat.waitForCompletion()
        let compared = try #require(chat.selectedSession?.attempts.last)
        #expect(compared.comparisonSourceAttemptID == source.id)
        #expect(compared.messagesJSON == source.messagesJSON)
        #expect(compared.inputs == source.inputs)
        #expect(compared.systemPrompt == source.systemPrompt)
        #expect(compared.node.parameters["modelID"] == current.parameters["modelID"])
        #expect(chat.selectedSession?.attempts.first?.rawText == originalOutput)
        #expect(chat.selectedSession?.draft == "Keep this unsent draft")
        #expect(ChatConfigurationActions.answers(in: try #require(chat.selectedSession), source: source).map(\.id) ==
            [source.id, compared.id])

        // Regeneration shares the user message but uses the now edited system prompt.
        try await chat.regenerate(source.userMessageID, sessionID: id)
        await chat.waitForCompletion()
        let changedInput = try #require(chat.selectedSession?.attempts.last)
        #expect(changedInput.userMessageID == source.userMessageID)
        #expect(!ChatConfigurationActions.matchesFrozenInput(changedInput, source: source))
        #expect(ChatConfigurationActions.answers(in: try #require(chat.selectedSession), source: source).map(\.id) ==
            [source.id, compared.id])

        let frozenAttempts = try #require(chat.selectedSession).attempts
        try ChatConfigurationActions.choose(source, sessionID: id, chat: chat)
        #expect(chat.selectedSession?.selectedLeafID == source.assistantMessageID)
        #expect(chat.selectedSession?.attempts == frozenAttempts)
        #expect(chat.selectedSession?.draft == "Keep this unsent draft")
        #expect(await engine.requests.count == 3)
        try await close(store, root: root)
    }

    @Test func archivedDeletedAndRunningConversationsCannotStartComparisonOrChoose() async throws {
        let (store, engine, chat, root) = try await fixture()
        let id = try chat.newSession()
        try chat.updateConfiguration(try configuration(), sessionID: id)
        try chat.updateDraft("Question", sessionID: id)
        try await chat.send(sessionID: id)
        await chat.waitForCompletion()
        let source = try #require(chat.selectedSession?.attempts.first)
        try chat.setArchived(true, sessionID: id)
        #expect(!ChatConfigurationActions.canCompare(try #require(chat.selectedSession), source: source, chat: chat))
        #expect(!ChatConfigurationActions.canChoose(try #require(chat.selectedSession), attempt: source, chat: chat))
        await #expect(throws: (any Error).self) {
            try await ChatConfigurationActions.compareCurrent(source, sessionID: id, chat: chat)
        }
        try chat.setArchived(false, sessionID: id)
        try chat.setDeleted(true, sessionID: id)
        #expect(!ChatConfigurationActions.canCompare(try #require(chat.selectedSession), source: source, chat: chat))
        #expect(!ChatConfigurationActions.canChoose(try #require(chat.selectedSession), attempt: source, chat: chat))
        try chat.setDeleted(false, sessionID: id)

        await engine.setHeld(true)
        try await chat.regenerate(source.userMessageID, sessionID: id)
        #expect(chat.isRunning)
        #expect(!ChatConfigurationActions.canCompare(try #require(chat.selectedSession), source: source, chat: chat))
        #expect(!ChatConfigurationActions.canChoose(try #require(chat.selectedSession), attempt: source, chat: chat))
        await engine.setHeld(false)
        await chat.waitForCompletion()
        #expect(ChatConfigurationActions.canCompare(try #require(chat.selectedSession), source: source, chat: chat))
        try await close(store, root: root)
    }
}
