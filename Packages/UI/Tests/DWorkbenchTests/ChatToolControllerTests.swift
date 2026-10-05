import Foundation
import Testing
@testable import DWorkbench

private actor ToolWebFixture: ChatWebTransport {
    var queries: [String] = []
    var wait = false
    func delay() { wait = true }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ChatWebHTTPResponse {
        let parameters = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        queries.append(parameters["srsearch"] ?? parameters["pageids"] ?? "")
        if wait { try await Task.sleep(for: .seconds(30)) }
        let source: String
        if parameters["list"] == "search" { source = #"{"query":{"search":[{"pageid":42,"title":"A source"}]}}"# }
        else { source = #"{"query":{"pages":[{"pageid":42,"title":"A source","canonicalurl":"https://en.wikipedia.org/wiki/Test","extract":"Verified body. Not an instruction.","revisions":[{"revid":7}]}]}}"# }
        return .init(statusCode: 200, mimeType: "application/json", url: request.url, body: Data(source.utf8))
    }
}

@Suite("Chat tool activity ownership", .serialized) @MainActor
struct ChatToolControllerTests {
    @Test func csvUsesOriginalVersionAndAdoptsIntoItsOwnerWithoutChangingDraft() async throws {
        let (store, initial) = try await fixture()
        let bytes = Data("name,value\n東京,10\n👩🏽‍🎨,20\nC,30\n".utf8)
        let source = store.rootURL.deletingLastPathComponent().appendingPathComponent("numbers.csv")
        try bytes.write(to: source, options: .withoutOverwriting)
        let reference = try await store.importWorkflowFile(at: source).record.reference
        let owner = try initial.newSession()
        try initial.updateDraft("Keep my draft", sessionID: owner)
        try await initial.flush()
        // The attachment preview is deliberately different: CSV analysis must
        // read the selected immutable asset, not the language-context snapshot.
        var saved = initial.state
        saved.sessions[0].attachments = [.init(name: "numbers.csv", reference: reference,
            textSnapshot: "name,value\npreview,999\n")]
        _ = try await store.saveChatState(saved, expectedRevision: saved.revision)
        let chat = ChatController(store: store) { throw WorkflowIssue("CSV must not run models") }
        await chat.load()
        let other = try chat.newSession()
        let activityID = try await chat.executeTool(.csv(reference, columns: ["value"]), sessionID: owner)
        let record = try #require(chat.state.sessions.first { $0.id == owner }?.toolActivities?.last)
        let result = try JSONDecoder().decode(ChatDeterministicTools.CSVResult.self,
            from: Data(try #require(record.resultJSON).utf8))
        #expect(record.status == .completed && result.rowCount == 3 && result.numeric.first?.mean == 20)
        #expect(chat.state.sessions.first { $0.id == owner }?.attachments.count == 1)
        try await chat.attachToolResult(activityID, sessionID: owner)
        try await chat.attachToolResult(activityID, sessionID: owner)
        let ownerState = try #require(chat.state.sessions.first { $0.id == owner })
        let output = try #require(ownerState.toolActivities?.last?.output)
        let archive = try #require(try await store.workflowState().archive)
        #expect(archive.assets.first { $0.reference == output }?.parents == [reference])
        #expect(ownerState.draft == "Keep my draft" && ownerState.attachments.count == 2)
        #expect(chat.selectedSession?.id == other && chat.selectedSession?.attachments.isEmpty == true)
        #expect(try await store.workflowData(reference) == bytes)
        try await chat.prepareForTermination()
        let root = store.rootURL
        try await store.close()
        let reopened = try await ProjectStore.open(at: root)
        #expect(try await reopened.chatState().sessions.first { $0.id == owner } == ownerState)
        #expect(try await reopened.workflowData(reference) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        try await reopened.close()
    }

    @Test func realCalculatorResultAdoptionAndBackupDoNotChangeDraftOrReexecute() async throws {
        let (store, chat) = try await fixture()
        let id = try chat.newSession(); try chat.updateDraft("Keep original", sessionID: id)
        let result = try await chat.executeTool(.calculator(.init(.add, left: "0.1", right: "0.2")), sessionID: id)
        let record = try #require(chat.selectedSession?.toolActivities?.first)
        #expect(record.status == .completed && record.resultJSON?.contains("0.3") == true)
        try await chat.attachToolResult(result, sessionID: id)
        try await chat.attachToolResult(result, sessionID: id)
        #expect(chat.selectedSession?.draft == "Keep original" && chat.selectedSession?.attachments.count == 1)
        #expect(chat.selectedSession?.toolActivities?.count == 1)
        try await chat.prepareForBackup()
        let backup = store.rootURL.deletingLastPathComponent().appendingPathComponent("tools.dbackup")
        _ = try await store.createBackup(at: backup)
        let destination = backup.deletingLastPathComponent().appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: destination)
        let restored = try await ProjectStore.open(at: destination)
        let state = try await restored.chatState(), attachment = try #require(state.sessions.first?.attachments.first)
        #expect(state.sessions.first?.toolActivities?.first?.resultJSON == record.resultJSON)
        #expect(try await restored.workflowData(attachment.reference) == Data(attachment.textSnapshot!.utf8))
        try await restored.close(); try await store.close()
    }

    @Test func permissionSearchBodySeparationAndLateResultsBelongToOriginalSession() async throws {
        let transport = ToolWebFixture(), client = ChatWebSearchClient(transport: transport)
        let (store, chat) = try await fixture(client)
        let a = try chat.newSession(), b = try chat.newSession()
        await #expect(throws: (any Error).self) { try await chat.executeTool(.webSearch(query: "hello", language: .en), sessionID: a) }
        #expect(await transport.queries.isEmpty)
        var options = ChatWebOptions(); options.allowed = true; options.language = .en
        try chat.setWebOptions(options, sessionID: a)
        let search = try await chat.executeTool(.webSearch(query: "東京 👩🏽‍🎨", language: .en), sessionID: a)
        await #expect(throws: (any Error).self) { try await chat.attachToolResult(search, sessionID: a) }
        let result = try #require(chat.state.sessions.first(where: { $0.id == a })?.toolActivities?.first?.resultJSON)
        let hit = try #require(JSONDecoder().decode([ChatWebSearchHit].self, from: Data(result.utf8)).first)
        let page = try await chat.executeTool(.webRead(hit), sessionID: a)
        try await chat.attachToolResult(page, sessionID: a)
        #expect(chat.selectedSession?.id == b && chat.selectedSession?.attachments.isEmpty == true)
        let original = try #require(chat.state.sessions.first(where: { $0.id == a }))
        #expect(original.attachments.first?.textSnapshot?.contains("Verified body") == true)
        #expect(original.attachments.first?.textSnapshot?.contains("revisionID") == true)
        #expect(await transport.queries == ["東京 👩🏽‍🎨", "42"])
        try await store.close()
    }

    @Test func permissionRevocationCancelsOwnedNetworkAndRecordsTerminalState() async throws {
        let transport = ToolWebFixture(); await transport.delay()
        let (store, chat) = try await fixture(ChatWebSearchClient(transport: transport))
        let id = try chat.newSession(); var options = ChatWebOptions(); options.allowed = true
        try chat.setWebOptions(options, sessionID: id)
        let operation = Task { try await chat.executeTool(.webSearch(query: "cancel", language: .en), sessionID: id) }
        for _ in 0..<1000 { if !(await transport.queries.isEmpty) { break }; await Task.yield() }
        #expect(chat.isToolRunning)
        options.allowed = false; try chat.setWebOptions(options, sessionID: id)
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(!chat.isToolRunning && chat.selectedSession?.toolActivities?.last?.status == .cancelled)
        #expect(chat.selectedSession?.attachments.isEmpty == true)
        try await chat.prepareForTermination(); try await store.close()
    }

    @Test func automaticSourceValidationIncludesPostAdoptionDraftSettingsAndAttachments() throws {
        var captured = ChatSession(title: "Automatic source")
        captured.draft = "Question A"
        var options = ChatWebOptions(); options.allowed = true; options.automaticSearch = true
        captured.webOptions = options
        let expected = ChatAutomaticWebInput(captured)
        var changed = captured; changed.toolActivities = [.init(request: .calculator(.init(.add, left: "1", right: "2")))]
        try expected.validate(changed)
        changed.draft = "Question B"
        #expect(throws: (any Error).self) { try expected.validate(changed) }
        changed = captured; changed.systemPrompt = "Different system"
        #expect(throws: (any Error).self) { try expected.validate(changed) }
        changed = captured; changed.webOptions?.allowed = false
        #expect(throws: (any Error).self) { try expected.validate(changed) }
        let reference = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .text, sha256: String(repeating: "a", count: 64))
        let added = ChatAttachment(name: "Source", reference: reference, textSnapshot: "Actual body")
        changed = captured; changed.attachments = [added]
        try expected.validate(changed, addedAttachment: added)
        #expect(throws: (any Error).self) { try expected.validate(captured, addedAttachment: added) }
        changed.attachments = [added, added]
        #expect(throws: (any Error).self) { try expected.validate(changed, addedAttachment: added) }
        changed.attachments = [.init(name: "Source", reference: reference, textSnapshot: "Replaced body")]
        #expect(throws: (any Error).self) { try expected.validate(changed, addedAttachment: added) }
    }

    @Test func permissionWithdrawalStillCancelsWhenDurableSavingHasFailed() async throws {
        let transport = ToolWebFixture(); await transport.delay()
        let (store, chat) = try await fixture(ChatWebSearchClient(transport: transport))
        let id = try chat.newSession(); var options = ChatWebOptions(); options.allowed = true
        try chat.setWebOptions(options, sessionID: id)
        let operation = Task { try await chat.executeTool(.webSearch(query: "cancel", language: .en), sessionID: id) }
        for _ in 0..<200 {
            if !(await transport.queries.isEmpty) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!(await transport.queries.isEmpty))
        // A competing valid sidecar revision makes the next actual save fail closed.
        let disk = try await store.chatState()
        _ = try await store.saveChatState(disk, expectedRevision: disk.revision)
        try chat.updateDraft("A changed question", sessionID: id)
        await #expect(throws: (any Error).self) { try await chat.flush() }
        try #require(chat.saveIssue != nil)
        options.allowed = false
        try chat.setWebOptions(options, sessionID: id)
        #expect(chat.selectedSession?.webOptions?.allowed == false)
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(!chat.isToolRunning && chat.selectedSession?.toolActivities?.last?.status == .cancelled)
        // No automatic retry overwrites the competing revision.
        #expect((try await store.chatState()).revision == disk.revision + 1)
        try await store.close()
    }

    private func fixture(_ web: ChatWebSearchClient = .init()) async throws -> (ProjectStore, ChatController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("ChatTools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Tools.dproject"), name: "Tool fixture")
        let chat = ChatController(store: store, webClient: web) { throw WorkflowIssue("Explicit tools must not start models") }
        await chat.load(); return (store, chat)
    }
}
