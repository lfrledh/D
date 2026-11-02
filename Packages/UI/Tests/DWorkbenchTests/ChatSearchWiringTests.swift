import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor SearchWiringTransport: ChatWebTransport {
    nonisolated let entered: AsyncStream<URLRequest>
    private let signal: AsyncStream<URLRequest>.Continuation
    private var calls: [URLRequest] = []
    private let searchBody: String?
    private let waits: Bool
    private let failure: Failure?
    enum Failure: Sendable { case searchHTTP, pageHTTP, timeout }
    init(waits: Bool = false, searchBody: String? = nil, failure: Failure? = nil) {
        self.failure = failure
        self.searchBody = searchBody
        (entered, signal) = AsyncStream.makeStream()
        self.waits = waits
    }
    func requests() -> [URLRequest] { calls }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ChatWebHTTPResponse {
        calls.append(request); signal.yield(request)
        if waits { try await Task.sleep(for: .seconds(30)) }
        let search = request.url?.host == "api.search.brave.com"
        if failure == .timeout { throw URLError(.timedOut) }
        if (search && failure == .searchHTTP) || (!search && failure == .pageHTTP) {
            return .init(statusCode: 503, mimeType: "text/plain", url: request.url, body: Data("not source text".utf8))
        }
        let body = search
            ? (searchBody ?? #"{"web":{"results":[{"title":"Search title","url":"https://example.com/source","description":"TRANSIENT_SNIPPET_CANARY"}]}}"#)
            : "PAGE_BODY_CANARY: actual independently read text."
        return .init(statusCode: 200, mimeType: search ? "application/json" : "text/plain", url: request.url, body: Data(body.utf8))
    }
}

private actor SearchAnswerEngine: InferenceEngine {
    private(set) var requests: [InferenceRequest] = []
    private let emitsDelta: Bool
    init(emitsDelta: Bool = true) { self.emitsDelta = emitsDelta }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        return .init(id: request.id, events: AsyncThrowingStream { c in
            if emitsDelta { c.yield(.textDelta("Local model answer")) }; c.finish()
        }, cancel: {}, outcome: {
            .completed(.init(textResponse: .init(rawText: "Local model answer", finalText: "Local model answer", finishReason: .stop)))
        })
    }
}

private actor SearchCredentialGate {
    nonisolated let entered: AsyncStream<Bool>
    private let signal: AsyncStream<Bool>.Continuation
    private var continuation: CheckedContinuation<String, Never>?
    init() { (entered, signal) = AsyncStream.makeStream() }
    func credential() async -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            signal.yield(true)
        }
    }
    func release() { continuation?.resume(returning: "fixture-secret-canary"); continuation = nil }
}

@Suite("Search provider app wiring", .serialized) @MainActor
struct ChatSearchWiringTests {
    @Test func unauthorizedAndWrongProviderNeverSend() async throws {
        let transport = SearchWiringTransport(), (store, chat) = try await fixture(transport)
        let id = try chat.newSession()
        await #expect(throws: (any Error).self) { try await chat.executeTool(.providerSearch(query: "question", provider: .brave), sessionID: id) }
        var options = ChatWebOptions(); options.allowed = true; options.provider = .bocha
        try chat.setWebOptions(options, sessionID: id)
        await #expect(throws: (any Error).self) { try await chat.executeTool(.providerSearch(query: "question", provider: .brave), sessionID: id) }
        #expect(await transport.requests().isEmpty)
        #expect(chat.selectedSession?.toolActivities?.isEmpty != false)
        try await store.close()
    }

    @Test func searchPreviewIsTransientWhileActualPageAndAdoptionSurviveIndependentRestore() async throws {
        let transport = SearchWiringTransport(), (store, chat) = try await fixture(transport)
        let a = try chat.newSession(); try chat.updateDraft("Keep original", sessionID: a)
        let b = try chat.newSession()
        var options = ChatWebOptions(); options.allowed = true; options.provider = .brave
        try chat.setWebOptions(options, sessionID: a)
        let id = try await chat.executeTool(.providerSearch(query: "question", provider: .brave), sessionID: a)
        let hit = try #require(chat.searchResults(activityID: id, sessionID: a)?.first)
        #expect(hit.snippet == "TRANSIENT_SNIPPET_CANARY")
        #expect(chat.searchResults(activityID: id, sessionID: b) == nil)
        await #expect(throws: (any Error).self) { try await chat.attachToolResult(id, sessionID: a) }
        let record = try #require(chat.state.sessions.first(where: { $0.id == a })?.toolActivities?.first)
        #expect(record.status == .completed && record.resultJSON == nil && record.output == nil)
        let page = try await chat.executeTool(.pageRead(hit.url), sessionID: a)
        try await chat.attachToolResult(page, sessionID: a)
        #expect(chat.selectedSession?.id == b && chat.selectedSession?.attachments.isEmpty == true)
        let original = try #require(chat.state.sessions.first(where: { $0.id == a }))
        #expect(original.draft == "Keep original" && original.attachments.count == 1)
        #expect(original.attachments.first?.textSnapshot?.contains("PAGE_BODY_CANARY") == true)
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "X-Subscription-Token") == "fixture-secret-canary")
        #expect(requests[1].value(forHTTPHeaderField: "X-Subscription-Token") == nil)
        try await chat.prepareForBackup()
        let snapshot = String(decoding: try JSONEncoder().encode(await store.chatState()), as: UTF8.self)
        #expect(!snapshot.contains("TRANSIENT_SNIPPET_CANARY") && !snapshot.contains("fixture-secret-canary"))
        let backup = store.rootURL.deletingLastPathComponent().appendingPathComponent("search.dbackup")
        _ = try await store.createBackup(at: backup)
        let destination = backup.deletingLastPathComponent().appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: destination)
        let restored = try await ProjectStore.open(at: destination)
        let reopened = ChatController(store: restored) { throw WorkflowIssue("Restore must not run a model") }
        await reopened.load()
        #expect(reopened.searchResults(activityID: id, sessionID: a) == nil)
        let recovered = try #require(reopened.state.sessions.first { $0.id == a })
        #expect(recovered.toolActivities?.first?.status == .completed)
        let attachment = try #require(recovered.attachments.first)
        #expect(try await restored.workflowData(attachment.reference) == Data(attachment.textSnapshot!.utf8))
        #expect(await transport.requests().count == 2)
        try await restored.close(); try await store.close()
    }

    @Test func providerChangeCancelsEnteredRequestWithoutFallback() async throws {
        let transport = SearchWiringTransport(waits: true), (store, chat) = try await fixture(transport)
        let id = try chat.newSession(); var options = ChatWebOptions(); options.allowed = true; options.provider = .brave
        try chat.setWebOptions(options, sessionID: id)
        let operation = Task { try await chat.executeTool(.providerSearch(query: "question", provider: .brave), sessionID: id) }
        var events = transport.entered.makeAsyncIterator()
        _ = try #require(await events.next())
        options.provider = .bocha; try chat.setWebOptions(options, sessionID: id)
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(!chat.isToolRunning)
        #expect(chat.selectedSession?.toolActivities?.last?.status == .cancelled)
        #expect(await transport.requests().count == 1)
        try await store.close()
    }

    @Test func automaticSearchReadsActualPageBeforeLocalModelWithoutSendingHistory() async throws {
        let transport = SearchWiringTransport(searchBody: #"{"web":{"results":[{"title":"Bad","url":"file:///private","description":"REJECTED_CANARY"},{"title":"Good","url":"https://example.com/source","description":"TRANSIENT_SNIPPET_CANARY"}]}}"#), engine = SearchAnswerEngine()
        let (store, chat, id) = try await generationFixture(transport, engine: engine)
        try chat.setSystemPrompt("PRIVATE_SYSTEM_CANARY", sessionID: id)
        try chat.updateDraft("visible question", sessionID: id)
        var options = ChatWebOptions(); options.allowed = true; options.automaticSearch = true; options.provider = .brave
        try chat.setWebOptions(options, sessionID: id)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        let requests = await transport.requests()
        #expect(requests.count == 2)
        let searchRecord = try #require(chat.selectedSession?.toolActivities?.first)
        #expect(chat.searchResponse(activityID: searchRecord.id, sessionID: id)?.rejectedCount == 1)
        #expect(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value == "visible question")
        #expect(!requests.contains { $0.url!.absoluteString.contains("PRIVATE_SYSTEM_CANARY") })
        #expect(await engine.requests.count == 1)
        let attempt = try #require(chat.selectedSession?.attempts.last)
        #expect(attempt.status == .completed && attempt.rawText == "Local model answer")
        #expect(attempt.messagesJSON.contains("PAGE_BODY_CANARY"))
        // Decode both serialization layers instead of treating JSON slash escaping as missing provenance.
        let pageRecord = try #require(chat.selectedSession?.toolActivities?.first { if case .pageRead = $0.request { true } else { false } })
        let pageSource = try JSONDecoder().decode(ChatWebPageSource.self, from: Data(try #require(pageRecord.resultJSON).utf8))
        #expect(pageSource.url.absoluteString == "https://example.com/source")
        let messages = try #require(JSONSerialization.jsonObject(with: Data(attempt.messagesJSON.utf8)) as? [[String: Any]])
        let content = messages.flatMap { $0["parts"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        #expect(content.contains(try #require(pageRecord.resultJSON)))
        #expect(!attempt.messagesJSON.contains("TRANSIENT_SNIPPET_CANARY") && !attempt.messagesJSON.contains("fixture-secret-canary"))
        #expect(!attempt.messagesJSON.contains("REJECTED_CANARY"))
        try await chat.flush()
        #expect(!String(decoding: try JSONEncoder().encode(await store.chatState()), as: UTF8.self).contains("REJECTED_CANARY"))
        try await store.close()
    }

    @Test func allRejectedAndZeroResultsKeepFilteringFactsAndContinueOneModelCall() async throws {
        for body in [#"{"web":{"results":[{},null]}}"#, #"{"web":{"results":[]}}"#] {
            let transport = SearchWiringTransport(searchBody: body)
            let engine = SearchAnswerEngine()
            let (store, chat, id) = try await generationFixture(transport, engine: engine)
            try chat.updateDraft("original question", sessionID: id)
            var options = ChatWebOptions(); options.allowed = true; options.automaticSearch = true; options.provider = .brave
            try chat.setWebOptions(options, sessionID: id)
            try await chat.send(sessionID: id); await chat.waitForCompletion()
            let activity = try #require(chat.selectedSession?.toolActivities?.last)
            let preview = try #require(chat.searchResponse(activityID: activity.id, sessionID: id))
            #expect(preview.rejectedCount == (body.contains("null") ? 2 : 0))
            #expect(preview.allRejected == body.contains("null"))
            #expect(await transport.requests().count == 1)
            #expect(await engine.requests.count == 1)
            let attempt = try #require(chat.selectedSession?.attempts.last)
            #expect(attempt.automaticSearch?.outcome == .noResults)
            #expect(attempt.automaticSearch?.generationStarted == true)
            #expect(attempt.messagesJSON.contains("Do not claim this request was verified by web search"))
            #expect(chat.selectedSession?.messages.first?.text == "original question")
            #expect(activity.status == .completed && activity.resultJSON == nil)
            try await store.close()
        }
    }

    @Test func closingSessionWhileCredentialWaitsPreventsNetworkAndLateResults() async throws {
        for action in 0..<3 {
            let transport = SearchWiringTransport(), gate = SearchCredentialGate()
            let (store, chat) = try await fixture(transport, credential: { _ in await gate.credential() })
            let id = try chat.newSession(); var options = ChatWebOptions(); options.allowed = true; options.provider = .brave
            try chat.setWebOptions(options, sessionID: id)
            let operation = Task { try await chat.executeTool(.providerSearch(query: "question", provider: .brave), sessionID: id) }
            var events = gate.entered.makeAsyncIterator()
            _ = try #require(await events.next())
            if action == 0 { try chat.archive(id) }
            else if action == 1 { try chat.setArchived(true, sessionID: id) }
            else { try chat.setDeleted(true, sessionID: id) }
            await gate.release()
            await #expect(throws: (any Error).self) { try await operation.value }
            #expect(await transport.requests().isEmpty)
            let record = try #require(chat.state.sessions.first { $0.id == id }?.toolActivities?.last)
            #expect(record.status == .cancelled)
            #expect(chat.searchResults(activityID: record.id, sessionID: id) == nil)
            #expect(!chat.isToolRunning)
            try await store.close()
        }
    }

    @Test func failedAutomaticSearchContinuesOnceAndNoticeSurvivesReopen() async throws {
        for (failure, emitsDelta) in [(SearchWiringTransport.Failure.searchHTTP, true), (.pageHTTP, true), (.timeout, true), (.searchHTTP, false)] {
            let transport = SearchWiringTransport(failure: failure), engine = SearchAnswerEngine(emitsDelta: emitsDelta)
            let (store, chat, id) = try await generationFixture(transport, engine: engine)
            try chat.setSystemPrompt("Keep the user's system instructions", sessionID: id)
            try chat.updateDraft("original question", sessionID: id)
            var options = ChatWebOptions(); options.allowed = true; options.automaticSearch = true; options.provider = .brave
            try chat.setWebOptions(options, sessionID: id)
            try await chat.send(sessionID: id); await chat.waitForCompletion()
            #expect(await engine.requests.count == 1)
            let session = try #require(chat.selectedSession), attempt = try #require(session.attempts.last)
            #expect(attempt.status == .completed)
            #expect(session.messages.filter { $0.role == .user }.map(\.text) == ["original question"])
            #expect(session.systemPrompt == "Keep the user's system instructions")
            #expect(attempt.automaticSearch?.outcome == .failed)
            #expect(attempt.automaticSearch?.generationStarted == true)
            #expect(attempt.automaticSearch?.issueCode != nil)
            #expect(attempt.messagesJSON.contains("D request source status"))
            #expect(!attempt.messagesJSON.contains("not source text"))
            #expect(!attempt.messagesJSON.contains("TRANSIENT_SNIPPET_CANARY"))
            #expect(session.attachments.isEmpty)
            try await chat.flush()
            let root = store.rootURL
            try await store.close()
            let reopenedStore = try await ProjectStore.open(at: root)
            let reopened = ChatController(store: reopenedStore) { throw WorkflowIssue("Reopen must not infer") }
            await reopened.load()
            #expect(reopened.selectedSession?.attempts.last?.automaticSearch == attempt.automaticSearch)
            #expect(await engine.requests.count == 1)
            try await reopenedStore.close()
        }
    }

    @Test func failedSearchPreservesManualReferenceAndSaveRetryNeverQueriesOrInfersAgain() async throws {
        let transport = SearchWiringTransport(failure: .searchHTTP), engine = SearchAnswerEngine()
        let (store, chat, id) = try await generationFixture(transport, engine: engine)
        let reference = try await store.publishWorkflowAsset(data: Data("MANUAL_REFERENCE_CANARY".utf8),
            mediaType: "text/plain", name: "User-owned reference", operationID: "d.asset.import").record.reference
        _ = try await chat.addAttachment(reference, name: "User-owned reference", sessionID: id)
        try chat.updateDraft("original question", sessionID: id)
        var options = ChatWebOptions(); options.allowed = true; options.automaticSearch = true; options.provider = .brave
        try chat.setWebOptions(options, sessionID: id)
        let obstruction = store.rootURL.appendingPathComponent("WorkflowAssets")
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: obstruction.path)[.posixPermissions])
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: obstruction.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: obstruction.path)
        try await chat.send(sessionID: id); await chat.waitForCompletion()
        let attempt = try #require(chat.selectedSession?.attempts.last)
        try #require(chat.pendingSaveAttemptID == attempt.id)
        #expect(attempt.automaticSearch?.outcome == .failed && attempt.messagesJSON.contains("MANUAL_REFERENCE_CANARY"))
        #expect(chat.selectedSession?.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.selectedSession?.messages.first { $0.role == .user }?.attachments.first?.reference == reference)
        #expect(await engine.requests.count == 1)
        #expect(await transport.requests().count == 1)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: obstruction.path)
        await chat.retrySave(); await chat.retrySave()
        #expect(chat.pendingSaveAttemptID == nil && chat.selectedSession?.attempts.last?.status == .completed)
        #expect(chat.selectedSession?.attempts.last?.automaticSearch == attempt.automaticSearch)
        #expect(await engine.requests.count == 1)
        #expect(await transport.requests().count == 1)
        try await chat.flush(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.chatState().sessions.first?.attempts.last?.automaticSearch == attempt.automaticSearch)
        #expect(try await reopened.workflowData(reference) == Data("MANUAL_REFERENCE_CANARY".utf8))
        try await reopened.close()
    }

    @Test func cancelledOrChangedPreparationNeverContinuesEvenIfSelectionReturns() async throws {
        for action in 0..<6 {
            let transport = SearchWiringTransport(), engine = SearchAnswerEngine(), gate = SearchCredentialGate()
            let (store, chat, id) = try await generationFixture(transport, engine: engine, credential: { _ in await gate.credential() })
            let other = try chat.newSession(); try chat.selectSession(id)
            try chat.updateDraft("original question", sessionID: id)
            var options = ChatWebOptions(); options.allowed = true; options.automaticSearch = true; options.provider = .brave
            try chat.setWebOptions(options, sessionID: id)
            let operation = Task { try await chat.send(sessionID: id) }
            var events = gate.entered.makeAsyncIterator(); _ = try #require(await events.next())
            #expect(chat.canStopGeneration && chat.isBusy)
            var cancellation: Task<Void, Never>?
            switch action {
            case 0: cancellation = Task { await chat.cancel() }; await Task.yield()
            case 1: try chat.selectSession(other); try chat.selectSession(id)
            case 2: try chat.updateDraft("changed", sessionID: id)
            case 3: options.allowed = false; options.automaticSearch = false; try chat.setWebOptions(options, sessionID: id)
            case 4: try chat.archive(id)
            default: try chat.setDeleted(true, sessionID: id)
            }
            await gate.release()
            await #expect(throws: (any Error).self) { try await operation.value }
            await cancellation?.value
            #expect(await engine.requests.isEmpty)
            let target = try #require(chat.state.sessions.first { $0.id == id })
            #expect(target.messages.isEmpty && target.attempts.isEmpty)
            #expect(!chat.canStopGeneration && !chat.isCancelling)
            try await store.close()
        }
    }

    @Test func transientResultsCannotBeSmuggledIntoPersistentActivity() throws {
        var record = ChatToolActivity(request: .providerSearch(query: "q", provider: .brave))
        record.status = .completed
        try record.validate()
        record.resultJSON = "[]"
        #expect(throws: (any Error).self) { try record.validate() }
        var legacy = ChatWebOptions(); legacy.allowed = true; legacy.automaticSearch = true
        let encoded = try JSONEncoder().encode(legacy)
        #expect(try JSONDecoder().decode(ChatWebOptions.self, from: encoded).provider == nil)
        let old = Data(#"{"allowed":true,"automaticSearch":true,"language":"zh"}"#.utf8)
        #expect(try JSONDecoder().decode(ChatWebOptions.self, from: old).provider == nil)
    }

    private func generationFixture(_ transport: SearchWiringTransport, engine: SearchAnswerEngine,
                                   credential: @escaping @Sendable (ChatSearchProvider) async throws -> String = { _ in "fixture-secret-canary" }) async throws -> (ProjectStore, ChatController, UUID) {
        let parent = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("AutomaticSearch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: parent.appendingPathComponent("Search.dproject"), name: "Automatic search")
        let runtime = WorkbenchSession(engine: engine, backendID: "fixture", status: {
            .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
        }, shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let chat = ChatController(store: store, searchClient: .init(transport: transport), pageClient: .init(transport: transport), searchCredential: credential) {
            WorkflowServices(store: store, session: runtime) { _, identity in
                .init(identity: identity, reference: .init(directory: parent, revision: identity),
                      backendID: "fixture.text", operationID: WorkflowModelRoutes.qwen35,
                      textCapability: .init(maximumPromptTokens: 8192, maximumOutputTokens: 1024, profile: TextExecutionCapability.qwen35VLMProfile))
            }
        }
        await chat.load(); let id = try chat.newSession()
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture"); node.parameters["maximumPromptTokens"] = .integer(8192)
        try chat.updateConfiguration(node, sessionID: id)
        return (store, chat, id)
    }

    private func fixture(_ transport: SearchWiringTransport, credential: @escaping @Sendable (ChatSearchProvider) async throws -> String = { _ in "fixture-secret-canary" }) async throws -> (ProjectStore, ChatController) {
        let parent = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("SearchWiring-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: parent.appendingPathComponent("Search.dproject"), name: "Search fixture")
        let chat = ChatController(store: store, searchClient: .init(transport: transport), pageClient: .init(transport: transport),
                                  searchCredential: credential) { throw WorkflowIssue("Explicit search must not run a model") }
        await chat.load(); return (store, chat)
    }
}
