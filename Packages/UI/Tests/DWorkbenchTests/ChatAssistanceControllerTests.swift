import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor AssistanceFixtureEngine: InferenceEngine {
    private(set) var requests: [InferenceRequest] = []
    private var result = #"{"title":"Generated title"}"#
    private var holding = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var cancelled = false
    func configure(_ result: String, hold: Bool = false) { self.result = result; holding = hold; cancelled = false }
    func release() { holding = false; waiter?.resume(); waiter = nil }
    private func finish() async -> RunOutcome {
        if holding { await withCheckedContinuation { waiter = $0 } }
        if cancelled { return .cancelled }
        return .completed(.init(textResponse: .init(rawText: result, finalText: result, finishReason: .stop)))
    }
    private func cancel() { cancelled = true; release() }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        if request.priority != .background {
            return .init(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: {
                .completed(.init(textResponse: .init(rawText: "Original answer", finalText: "Original answer", finishReason: .stop)))
            })
        }
        return .init(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: { await self.cancel() },
            outcome: { await self.finish() })
    }
}

@Suite("Assistance production wiring", .serialized) @MainActor
struct ChatAssistanceControllerTests {
    @Test func offByDefaultAndAutomaticTitleUsesBackgroundWithoutChangingDraftOrHistory() async throws {
        let (store, engine, chat, id) = try await fixture()
        try await send(chat, id)
        #expect(await engine.requests.count == 1)
        let original = try #require(chat.selectedSession)
        try chat.updateDraft("Unsent 中文 👩🏽‍🎨", sessionID: id)
        try chat.setAssistanceOptions(.init(title: true), sessionID: id)
        try chat.runAssistance(sessionID: id); await chat.waitForAssistance()
        let session = try #require(chat.selectedSession)
        #expect(session.title == "Generated title")
        #expect(session.draft == "Unsent 中文 👩🏽‍🎨")
        #expect(session.messages == original.messages && session.attempts == original.attempts)
        #expect(session.assistanceExecutions?.last?.record.status == .completed)
        let requests = await engine.requests
        #expect(requests.count == 2 && requests.last?.priority == .background)
        let lastInput = String(describing: requests.last?.input)
        #expect(!lastInput.contains("Unsent"))
        try chat.runAssistance(sessionID: id); await chat.waitForAssistance()
        #expect(await engine.requests.count == 2)
        try await chat.flush(); #expect(try await store.chatState().sessions == chat.state.sessions)
        try await store.close()
    }
    @Test func primaryCompletionSchedulesAuxiliaryAndBackupRestoresItsFrozenRecordAndRawAsset() async throws {
        let (store, engine, chat, id) = try await fixture()
        await engine.configure(#"{"memory":["Source-derived fact"]}"#)
        try chat.setAssistanceOptions(.init(memoryMode: .suggest, memoryTarget: .project(try #require(chat.projectIdentity))), sessionID: id)
        try await send(chat, id)
        let execution = try #require(chat.selectedSession?.assistanceExecutions?.last)
        #expect(execution.record.status == .completed)
        #expect(chat.state.memoryEntries?.last?.acceptance == .suggested)
        #expect(await engine.requests.count == 2)
        try await chat.prepareForBackup()
        let backup = store.rootURL.deletingLastPathComponent().appendingPathComponent("assistance.dbackup")
        _ = try await store.createBackup(at: backup)
        let destination = backup.deletingLastPathComponent().appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: destination)
        let restoredStore = try await ProjectStore.open(at: destination)
        let restored = ChatController(store: restoredStore) { throw WorkflowIssue("No inference in restore") }
        await restored.load()
        #expect(restored.state == chat.state)
        #expect(try await restoredStore.workflowData(#require(execution.record.output)) == store.workflowData(#require(execution.record.output)))
        try await restoredStore.close(); try await store.close()
    }
    @Test func manualRenameAndChangingConsentDuringRunDoNotApplyLateTitle() async throws {
        let (store, engine, chat, id) = try await fixture(); try await send(chat, id)
        try chat.setAssistanceOptions(.init(title: true), sessionID: id)
        await engine.configure(#"{"title":"Late"}"#, hold: true)
        try chat.runAssistance(sessionID: id); try await waitBackground(engine)
        try chat.rename(id, title: "My title")
        await engine.release(); await chat.waitForAssistance()
        #expect(chat.selectedSession?.title == "My title")
        #expect(chat.selectedSession?.assistanceExecutions?.last?.record.status == .completed)
        // A new source plus revoked consent is stale; completed old source is never re-run.
        try chat.setAssistanceOptions(.init(), sessionID: id)
        try await send(chat, id)
        try chat.setAssistanceOptions(.init(tags: true), sessionID: id)
        await engine.configure(#"{"tags":["late"]}"#, hold: true)
        try chat.runAssistance(sessionID: id); try await waitBackground(engine, count: 2)
        try chat.setAssistanceOptions(.init(), sessionID: id)
        await engine.release(); await chat.waitForAssistance()
        #expect(chat.selectedSession?.contextChoices?.tags.isEmpty != false)
        #expect(chat.selectedSession?.assistanceExecutions?.last?.record.status == .stale)
        #expect(chat.selectedSession?.assistanceExecutions?.last?.record.output != nil)
        try await store.close()
    }
    @Test func cancelledAuxiliaryDrainsAndBackupDoesNotPretendActiveTaskIsDurable() async throws {
        let (store, engine, chat, id) = try await fixture(); try await send(chat, id)
        try chat.setAssistanceOptions(.init(title: true), sessionID: id)
        await engine.configure(#"{"title":"Late"}"#, hold: true)
        try chat.runAssistance(sessionID: id); try await waitBackground(engine)
        await #expect(throws: (any Error).self) { try await chat.prepareForBackup() }
        await chat.cancelAll(); await chat.waitForAssistance()
        #expect(!chat.isBusy && chat.selectedSession?.assistanceExecutions?.last?.record.status == .cancelled)
        #expect(chat.selectedSession?.title != "Late")
        try await chat.prepareForBackup(); try await store.close()
    }
    @Test func summaryThresholdOriginalSourceAndMemoryRecordingRemainSeparateFromReads() async throws {
        let (store, engine, chat, id) = try await fixture(); try await send(chat, id)
        try chat.setAssistanceOptions(.init(summary: true, summaryThresholdEstimatedTokens: 100_000), sessionID: id)
        try chat.runAssistance(sessionID: id); await chat.waitForAssistance()
        #expect(await engine.requests.count == 1)
        await engine.configure(#"{"summary":"Source summary"}"#)
        try chat.setAssistanceOptions(.init(summary: true, summaryThresholdEstimatedTokens: 1), sessionID: id)
        try chat.runAssistance(sessionID: id); await chat.waitForAssistance()
        let summary = try #require(chat.selectedSession?.contextSummaries?.last)
        #expect(summary.auxiliaryAttemptID != nil && !summary.enabled)
        #expect(chat.selectedSession?.messages.count == 2)
        await engine.configure(#"{"memory":["The source is local"]}"#)
        let project = try #require(chat.projectIdentity)
        try chat.setAssistanceOptions(.init(memoryMode: .automatic, memoryTarget: .project(project)), sessionID: id)
        try chat.runAssistance(sessionID: id); await chat.waitForAssistance()
        let memory = try #require(chat.state.memoryEntries?.last)
        #expect(memory.acceptance == .accepted && !memory.enabled)
        #expect(chat.selectedSession?.memoryScopes?.isEmpty != false)
        try await store.close()
    }
    @Test func malformedJSONRetainsRawAndForgottenMemoryCannotBeRecreatedByInFlightTask() async throws {
        let (store, engine, chat, id) = try await fixture(); try await send(chat, id)
        await engine.configure("not json")
        try chat.setAssistanceOptions(.init(tags: true), sessionID: id)
        try chat.runAssistance(sessionID: id); await chat.waitForAssistance()
        let failed = try #require(chat.selectedSession?.assistanceExecutions?.last?.record)
        #expect(failed.status == .failed && failed.result == nil && failed.output != nil)
        let scope = ChatMemoryScope.project(try #require(chat.projectIdentity))
        let original = try ChatMemoryEntry.manual(text: "forget me", scope: scope)
        try await chat.writeMemory(original)
        await engine.configure(#"{"memory":["forget me"]}"#, hold: true)
        try chat.setAssistanceOptions(.init(memoryMode: .automatic, memoryTarget: scope), sessionID: id)
        try chat.runAssistance(sessionID: id); try await waitBackground(engine, count: 2)
        try await chat.writeMemory(original.forgotten())
        await engine.release(); await chat.waitForAssistance()
        #expect(chat.state.memoryEntries?.count == 2)
        #expect(chat.selectedSession?.assistanceExecutions?.last?.record.status == .failed)
        try await store.close()
    }
    @Test func receiptFailureKeepsAppliedMemoryAndRetriesSaveOnly() async throws {
        let (store, engine, chat, id) = try await fixture(); try await send(chat, id)
        let scope = ChatMemoryScope.project(try #require(chat.projectIdentity))
        try chat.setAssistanceOptions(.init(memoryMode: .automatic, memoryTarget: scope), sessionID: id)
        await engine.configure(#"{"memory":["Recorded value"]}"#, hold: true)
        try chat.runAssistance(sessionID: id); try await waitBackground(engine)
        let sidecar = store.rootURL.appendingPathComponent("quick-chat.json")
        let original = try Data(contentsOf: sidecar)
        try (original + Data("\n".utf8)).write(to: sidecar) // This task's controlled external-write fixture only.
        await engine.release(); await chat.waitForAssistance()
        #expect(chat.state.memoryEntries?.count == 1)
        #expect(chat.pendingAssistanceSaveID != nil)
        #expect(chat.selectedSession?.assistanceExecutions?.last?.record.status == .completed)
        #expect(!chat.isBusy)
        await #expect(throws: (any Error).self) { try await chat.prepareForTermination() }
        try original.write(to: sidecar)
        async let first: Void = chat.retryAssistanceSave()
        async let second: Void = chat.retryAssistanceSave()
        try await first; try await second
        #expect(chat.state.memoryEntries?.count == 1 && chat.pendingAssistanceSaveID == nil)
        #expect(chat.selectedSession?.assistanceExecutions?.last?.record.status == .completed)
        #expect(await engine.requests.count == 2)
        try await chat.prepareForTermination(); try await store.close()
    }
    @Test func personalSaveFailureHasDurableContinuationAndColdRetryDoesNotRegenerate() async throws {
        let (personalStore, _, owner, _) = try await fixture(ownsPersonal: true)
        try await owner.flush()
        let (store, engine, chat, id) = try await fixture(owner: owner)
        try await send(chat, id)
        try chat.setAssistanceOptions(.init(memoryMode: .automatic, memoryTarget: .personal), sessionID: id)
        await engine.configure(#"{"memory":["Personal derived value"]}"#, hold: true)
        try chat.runAssistance(sessionID: id); try await waitBackground(engine)
        let personalSidecar = personalStore.rootURL.appendingPathComponent("quick-chat.json")
        let personalOriginal = try Data(contentsOf: personalSidecar)
        try (personalOriginal + Data("\n".utf8)).write(to: personalSidecar)
        await engine.release(); await chat.waitForAssistance()
        #expect(chat.pendingAssistanceSaveID != nil && !chat.isBusy)
        try await chat.flush() // This is also what the normal debounce may do.
        let persisted = try await store.chatState()
        #expect(persisted.sessions.first?.assistanceExecutions?.last?.pendingMemoryEntries?.count == 1)
        #expect(try await personalStore.chatState().memoryEntries?.isEmpty != false)
        try personalOriginal.write(to: personalSidecar) // Restore this fixture's controlled failure only.
        let personalRoot = personalStore.rootURL, projectRoot = store.rootURL
        try await personalStore.close(); try await store.close()
        let freshPersonalStore = try await ProjectStore.open(at: personalRoot)
        let freshProjectStore = try await ProjectStore.open(at: projectRoot)
        let freshOwner = ChatController(store: freshPersonalStore, ownsPersonalMemory: true) { throw WorkflowIssue("No execution during recovery") }
        await freshOwner.load()
        let fresh = ChatController(store: freshProjectStore, personalMemoryProvider: { freshOwner }) { throw WorkflowIssue("No execution during recovery") }
        await fresh.load()
        #expect(fresh.pendingAssistanceSaveID != nil)
        try await fresh.retryAssistanceSave()
        #expect(fresh.pendingAssistanceSaveID == nil)
        #expect(try await freshPersonalStore.chatState().memoryEntries?.count == 1)
        #expect(try await freshProjectStore.chatState().sessions.first?.assistanceExecutions?.last?.pendingMemoryEntries == nil)
        #expect(await engine.requests.count == 2)
        try await fresh.prepareForTermination(); try await freshOwner.prepareForTermination()
        try await freshProjectStore.close(); try await freshPersonalStore.close()
    }
    @Test(arguments: ["forget", "revoke", "cancel"])
    func coldPendingMemoryCannotReviveForgottenContentOrTrapRevokedSession(action: String) async throws {
        let (personalStore, _, owner, _) = try await fixture(ownsPersonal: true)
        let old = try ChatMemoryEntry.manual(text: "Remembered fact", scope: .personal)
        try await owner.writeMemory(old); try await owner.flush()
        let (store, engine, chat, id) = try await fixture(owner: owner); try await send(chat, id)
        try chat.setAssistanceOptions(.init(memoryMode: .automatic, memoryTarget: .personal), sessionID: id)
        await engine.configure(#"{"memory":["Remembered fact"]}"#, hold: true)
        try chat.runAssistance(sessionID: id); try await waitBackground(engine)
        let sidecar = personalStore.rootURL.appendingPathComponent("quick-chat.json")
        let original = try Data(contentsOf: sidecar)
        try (original + Data("\n".utf8)).write(to: sidecar)
        await engine.release(); await chat.waitForAssistance(); try await chat.flush()
        try original.write(to: sidecar)
        let personalRoot = personalStore.rootURL, projectRoot = store.rootURL
        try await personalStore.close(); try await store.close()
        let ps = try await ProjectStore.open(at: personalRoot), cs = try await ProjectStore.open(at: projectRoot)
        let po = ChatController(store: ps, ownsPersonalMemory: true) { throw WorkflowIssue("No recovery inference") }
        await po.load()
        let recovered = ChatController(store: cs, personalMemoryProvider: { po }) { throw WorkflowIssue("No recovery inference") }
        await recovered.load()
        if action == "forget" { try await po.writeMemory(old.forgotten()) }
        if action == "revoke" { try recovered.setAssistanceOptions(.init(), sessionID: id) }
        if action == "cancel" { await recovered.cancelAssistance() }
        try await recovered.retryAssistanceSave()
        #expect(recovered.pendingAssistanceSaveID == nil && !recovered.isBusy)
        let record = try #require(recovered.selectedSession?.assistanceExecutions?.last?.record)
        #expect(record.status == .stale && record.output != nil && record.result == nil)
        #expect(po.state.memoryEntries?.allSatisfy { $0.id == old.id } == true)
        #expect(await engine.requests.count == 2)
        try await recovered.prepareForTermination(); try await po.prepareForTermination()
        try await cs.close(); try await ps.close()
    }
    private func fixture(owner: ChatController? = nil, ownsPersonal: Bool = false) async throws -> (ProjectStore, AssistanceFixtureEngine, ChatController, UUID) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("Assistance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Chat.dproject"), name: "Assistance CPU")
        let engine = AssistanceFixtureEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let chat = ChatController(store: store, ownsPersonalMemory: ownsPersonal, personalMemoryProvider: { owner }) {
            WorkflowServices(store: store, session: runtime) { _, identity in
                .init(identity: identity, reference: .init(directory: root, revision: identity), backendID: "fixture.text",
                    operationID: WorkflowModelRoutes.qwen35, textCapability: .init(maximumPromptTokens: 8192,
                    maximumOutputTokens: 1024, profile: TextExecutionCapability.qwen35VLMProfile))
            }
        }
        await chat.load(); let id = try chat.newSession()
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture")
        node.parameters["maximumPromptTokens"] = .integer(8192)
        node.parameters["maximumOutputTokens"] = .integer(1024)
        try chat.updateConfiguration(node, sessionID: id)
        return (store, engine, chat, id)
    }
    private func send(_ chat: ChatController, _ id: UUID) async throws {
        try chat.updateDraft("Question", sessionID: id); try await chat.send(sessionID: id)
        await chat.waitForCompletion(); await chat.waitForAssistance()
    }
    private func waitBackground(_ engine: AssistanceFixtureEngine, count: Int = 1) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await engine.requests.filter({ $0.priority == .background }).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkflowIssue("Background request did not arrive.")
    }
}
