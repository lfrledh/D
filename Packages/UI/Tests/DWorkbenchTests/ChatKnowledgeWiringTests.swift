import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor KnowledgeOrderingEngine: InferenceEngine {
    private(set) var requests: [InferenceRequest] = []
    private var output = "", held = false, cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func configure(_ output: String, hold: Bool = false) { self.output = output; held = hold; cancelled = false }
    func release() { held = false; waiter?.resume(); waiter = nil }
    func cancel() { cancelled = true; release() }
    func outcome() async -> RunOutcome {
        if held { await withCheckedContinuation { waiter = $0 } }
        return cancelled ? .cancelled : .completed(.init(textResponse: .init(rawText: output, finalText: output, finishReason: .stop)))
    }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        return .init(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: { await self.cancel() }, outcome: { await self.outcome() })
    }
}

@Suite("Knowledge production routing", .serialized) @MainActor
struct ChatKnowledgeWiringTests {
    @Test func exactOrderingKeepsSourcesAndDraftAndRestoresIndependentBackup() async throws {
        let (store, engine, chat, id, excerpts) = try await fixture()
        try chat.updateDraft("Do not replace draft", sessionID: id)
        let before = try #require(chat.selectedSession)
        let order = Array(excerpts.reversed())
        await engine.configure(try ordering(order))
        let result = try await chat.rerankKnowledge(excerpts, query: "apple", sessionID: id, maximumOutputTokens: 512)
        #expect(result == order)
        #expect(chat.selectedSession?.draft == before.draft && chat.selectedSession?.messages == before.messages)
        #expect(chat.selectedSession?.knowledgeExcerpts == nil)
        let record = try #require(chat.selectedSession?.knowledgeReranks?.last)
        #expect(record.status == .completed && record.order == order.map(\.id))
        #expect(record.node.parameters["maximumOutputTokens"]?.integer == 512)
        let requests = await engine.requests
        #expect(requests.count == 1 && requests.first?.priority == .background)
        _ = try await store.workflowData(#require(record.output))
        try await chat.prepareForBackup()
        let backup = store.rootURL.deletingLastPathComponent().appendingPathComponent("Knowledge.dbackup")
        _ = try await store.createBackup(at: backup)
        let restored = backup.deletingLastPathComponent().appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restored)
        let reopened = try await ProjectStore.open(at: restored)
        #expect(try await reopened.chatState().sessions == chat.state.sessions)
        #expect(try await reopened.workflowData(#require(record.output)) == store.workflowData(#require(record.output)))
        try await reopened.close(); try await store.close()
    }
    @Test func scopeChangedDuringOrderingIsStaleAndCancelDrains() async throws {
        let (store, engine, chat, id, excerpts) = try await fixture()
        await engine.configure(try ordering(excerpts), hold: true)
        let work = Task { try await chat.rerankKnowledge(excerpts, query: "apple", sessionID: id, maximumOutputTokens: 512) }
        try await wait(engine, count: 1)
        try chat.setKnowledgeScope([], sessionID: id)
        await engine.release()
        await #expect(throws: (any Error).self) { try await work.value }
        #expect(chat.selectedSession?.knowledgeReranks?.last?.status == .stale && !chat.isBusy)
        try chat.setKnowledgeScope(excerpts.map { $0.source.assetID }, sessionID: id)
        await engine.configure(try ordering(excerpts), hold: true)
        let cancelled = Task { try await chat.rerankKnowledge(excerpts, query: "apple", sessionID: id, maximumOutputTokens: 512) }
        try await wait(engine, count: 2)
        await chat.cancelAll()
        await #expect(throws: (any Error).self) { try await cancelled.value }
        #expect(chat.selectedSession?.knowledgeReranks?.last?.status == .cancelled && !chat.isBusy)
        #expect(chat.selectedSession?.knowledgeExcerpts == nil)
        try await chat.prepareForTermination(); try await store.close()
    }
    @Test func failedPublicationRetainsOwnerAndSaveRetryDoesNotRerunModel() async throws {
        let (store, engine, chat, id, excerpts) = try await fixture()
        await engine.configure(try ordering(excerpts), hold: true)
        let work = Task { try await chat.rerankKnowledge(excerpts, query: "apple", sessionID: id, maximumOutputTokens: 512) }
        try await wait(engine, count: 1)
        let folder = store.rootURL.appendingPathComponent("WorkflowAssets")
        // Keep existing sources readable; deny only new publication in this fixture-owned folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        await engine.release()
        await #expect(throws: (any Error).self) { try await work.value }
        #expect(chat.pendingKnowledgeRerankSaveID != nil)
        await #expect(throws: (any Error).self) { try await chat.prepareForBackup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try await chat.retryKnowledgeRerankSave()
        let record = try #require(chat.selectedSession?.knowledgeReranks?.last)
        #expect(record.status == .completed && record.output != nil && chat.pendingKnowledgeRerankSaveID == nil)
        #expect(await engine.requests.count == 1)
        try await chat.prepareForTermination(); try await store.close()
    }
    @Test func badModelOrderRetainsRawAndDoesNotFabricateSources() async throws {
        let (store, engine, chat, id, excerpts) = try await fixture()
        await engine.configure(try ordering([excerpts[0], excerpts[0]]))
        await #expect(throws: (any Error).self) {
            try await chat.rerankKnowledge(excerpts, query: "apple", sessionID: id, maximumOutputTokens: 512)
        }
        let record = try #require(chat.selectedSession?.knowledgeReranks?.last)
        #expect(record.status == .failed && record.order == nil && record.output != nil)
        #expect(chat.selectedSession?.knowledgeExcerpts == nil)
        await #expect(throws: (any Error).self) {
            try await chat.rerankKnowledge(excerpts, query: "apple", sessionID: id, maximumOutputTokens: 1025)
        }
        #expect(await engine.requests.count == 1)
        try await store.close()
    }
    @Test func personalSourceCopiesAreExplicitAndSurviveOriginalRemoval() async throws {
        let (personalStore, _, personal, _, _) = try await fixture(ownsPersonal: true)
        let (store, _, chat, _, _) = try await fixture(owner: personal)
        let original = try #require(chat.state.knowledgeDocuments?.first)
        try await chat.copyKnowledgeDocument(original.id, toPersonal: true)
        let copied = try #require(personal.state.knowledgeDocuments?.first { $0.id == original.id })
        #expect(copied.material.reference.projectID != original.material.reference.projectID)
        #expect(try copied.extraction().text == original.extraction().text)
        try chat.removeKnowledgeDocument(original.id)
        try await chat.copyKnowledgeDocument(copied.id, toPersonal: false)
        #expect(chat.state.knowledgeDocuments?.contains(where: { $0.id == original.id }) == true)
        #expect(try await personalStore.workflowData(copied.material.reference) == store.workflowData(original.material.reference))
        try await chat.prepareForTermination(); try await personal.prepareForTermination()
        try await store.close(); try await personalStore.close()
    }
    private func ordering(_ excerpts: [ChatKnowledgeExcerpt]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["order": excerpts.map { $0.id.uuidString }]), as: UTF8.self)
    }
    private func wait(_ engine: KnowledgeOrderingEngine, count: Int) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < end {
            if await engine.requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkflowIssue("No bounded fixture request arrived")
    }
    private func fixture(owner: ChatController? = nil, ownsPersonal: Bool = false) async throws -> (ProjectStore, KnowledgeOrderingEngine, ChatController, UUID, [ChatKnowledgeExcerpt]) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("Knowledge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Chat.dproject"), name: "Knowledge")
        let engine = KnowledgeOrderingEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let chat = ChatController(store: store, ownsPersonalMemory: ownsPersonal, personalMemoryProvider: { owner }) {
            WorkflowServices(store: store, session: runtime) { _, identity in
                .init(identity: identity, reference: .init(directory: root, revision: identity), backendID: "fixture.text", operationID: WorkflowModelRoutes.qwen35,
                    textCapability: .init(maximumPromptTokens: 8192, maximumOutputTokens: 1024, profile: TextExecutionCapability.qwen35VLMProfile))
            }
        }
        await chat.load(); let id = try chat.newSession()
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture"); node.parameters["maximumPromptTokens"] = .integer(8192); node.parameters["maximumOutputTokens"] = .integer(1024)
        try chat.updateConfiguration(node, sessionID: id)
        var excerpts: [ChatKnowledgeExcerpt] = []
        for text in ["apple 中文", "apple e\u{301}"] {
            let ref = try await store.publishWorkflowAsset(data: Data(text.utf8), mediaType: "text/plain", name: text, operationID: "fixture").record.reference
            try await chat.addKnowledgeDocument(ref, name: text)
            excerpts.append(.init(source: ref, name: text, text: text, utf16Offset: 0, utf16Length: text.utf16.count, page: nil, line: 1))
        }
        try chat.setKnowledgeScope(excerpts.map { $0.source.assetID }, sessionID: id)
        return (store, engine, chat, id, excerpts)
    }
}
