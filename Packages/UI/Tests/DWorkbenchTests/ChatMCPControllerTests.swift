import Foundation
import Testing
@testable import DWorkbench

@Suite("MCP chat ownership", .serialized) @MainActor
struct ChatMCPControllerTests {
    @Test func noConnectionWithoutExplicitGrantOrOnRestore() async throws {
        let (store, chat) = try await fixture()
        let id = try chat.newSession(); let before = chat.state
        await #expect(throws: ChatMCPError.permissionDenied) { try await chat.connectMCP(endpoint: "https://example.com/mcp", sessionID: id, permitted: false) }
        await #expect(throws: ChatMCPError.invalidEndpoint) { try await chat.connectMCP(endpoint: "https://example.com/mcp?token=secret", sessionID: id, permitted: true) }
        #expect(chat.state == before && chat.mcpSessionID == nil)
        try await chat.flush()
        var saved = chat.state; saved.sessions[0].mcpEndpoint = "http://127.0.0.1:12345/mcp"
        _ = try await store.saveChatState(saved, expectedRevision: saved.revision)
        let restored = ChatController(store: store) { throw WorkflowIssue("No generation") }
        await restored.load()
        #expect(restored.isLoaded && restored.mcpStatus == .disconnected && restored.mcpSessionID == nil && restored.mcpTools.isEmpty)
        await #expect(throws: ChatMCPError.permissionDenied) { try await restored.executeTool(.mcp(endpoint: "http://127.0.0.1:12345/mcp", tool: "fake", argumentsJSON: "{}"), sessionID: id, mcpPermission: true) }
        // Finish the original controller's owned write tail before closing its store.
        try await store.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_CHAT_LIVE_MCP"] == "1"))
    func actualClientToolsBelongToOriginAndBackupNeverReplays() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["D_CHAT_MCP_ENDPOINT"])
        try #require(try ChatMCPService.validateEndpoint(endpoint).host == "127.0.0.1")
        let (store, chat) = try await fixture()
        let a = try chat.newSession(), b = try chat.newSession()
        try chat.updateDraft("Keep both drafts", sessionID: a)
        try await chat.connectMCP(endpoint: endpoint, sessionID: a, permitted: true)
        #expect(chat.selectedSession?.id == b && chat.mcpSessionID == a && !chat.mcpTools.isEmpty)
        let request = ChatToolRequest.mcp(endpoint: endpoint, tool: "add_numbers", argumentsJSON: #"{"a":17,"b":25}"#)
        await #expect(throws: ChatMCPError.permissionDenied) { try await chat.executeTool(request, sessionID: b, mcpPermission: true) }
        await #expect(throws: ChatMCPError.permissionDenied) { try await chat.executeTool(request, sessionID: a) }
        let result = try await chat.executeTool(request, sessionID: a, mcpPermission: true)
        let owner = try #require(chat.state.sessions.first { $0.id == a })
        #expect(owner.draft == "Keep both drafts" && owner.attachments.isEmpty && owner.toolActivities?.last?.resultJSON?.contains("42") == true)
        try await chat.attachToolResult(result, sessionID: a)
        #expect(chat.selectedSession?.id == b && chat.selectedSession?.attachments.isEmpty == true)
        _ = try await chat.executeTool(.mcp(endpoint: endpoint, tool: "test_error_handling", argumentsJSON: "{}"), sessionID: a, mcpPermission: true)
        #expect(chat.state.sessions.first { $0.id == a }?.toolActivities?.last?.status == .failed)
        let task = Task { try await chat.executeTool(.mcp(endpoint: endpoint, tool: "test_progress", argumentsJSON: #"{"duration_ms":2000}"#), sessionID: a, mcpPermission: true) }
        try await Task.sleep(for: .milliseconds(200)); await chat.cancelAll()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!chat.isBusy && chat.mcpSessionID == nil)
        #expect(chat.state.sessions.first { $0.id == a }?.toolActivities?.last?.status == .cancelled)
        try await chat.prepareForBackup()
        let backup = store.rootURL.deletingLastPathComponent().appendingPathComponent("mcp.dbackup")
        _ = try await store.createBackup(at: backup)
        let target = store.rootURL.deletingLastPathComponent().appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: target)
        let restoredStore = try await ProjectStore.open(at: target)
        let restored = ChatController(store: restoredStore) { throw WorkflowIssue("No generation") }
        await restored.load()
        #expect(restored.mcpSessionID == nil && restored.mcpStatus == .disconnected && restored.mcpTools.isEmpty)
        #expect(restored.state.sessions == chat.state.sessions)
        try await restoredStore.close(); try await store.close()
    }

    private func fixture() async throws -> (ProjectStore, ChatController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("ChatMCP-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Fixture.dproject"), name: "MCP")
        let chat = ChatController(store: store) { throw WorkflowIssue("No generation") }
        await chat.load(); return (store, chat)
    }
}

private actor ControlledChatMCP: ChatMCPServing {
    private var current: ChatMCPStatus = .disconnected
    private var hold = true
    private var releases: [CheckedContinuation<Void, Never>] = []
    private(set) var disconnects = 0
    func status() -> ChatMCPStatus { current }
    func connect(endpoint: String, permitted: Bool, timeoutSeconds: Int) throws { current = .connected(endpoint: endpoint) }
    func listTools(timeoutSeconds: Int) -> [ChatMCPTool] { [] }
    func callTool(name: String, argumentsJSON: String, permitted: Bool, timeoutSeconds: Int) throws -> ChatMCPCallResult { throw ChatMCPError.unknownTool }
    func cancel() async { await disconnect() }
    func disconnect() async {
        disconnects += 1
        if hold { await withCheckedContinuation { releases.append($0) } }
        current = .disconnected
    }
    func resume() { hold = false; let pending = releases; releases = []; for item in pending { item.resume() } }
}

private actor UnrelatedSlowWeb: ChatWebTransport {
    private(set) var entered = false
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ChatWebHTTPResponse {
        entered = true
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}

extension ChatMCPControllerTests {
    @Test func mcpDisconnectDoesNotCancelAnUnrelatedWebRequest() async throws {
        let (store, unused) = try await fixture(); _ = unused
        let service = ControlledChatMCP(), web = UnrelatedSlowWeb()
        await service.resume()
        let chat = ChatController(store: store, webClient: .init(transport: web), mcpService: service) { throw WorkflowIssue("No generation") }
        await chat.load(); let id = try chat.newSession()
        try await chat.connectMCP(endpoint: "http://127.0.0.1:12345/mcp", sessionID: id, permitted: true)
        var options = ChatWebOptions(); options.allowed = true; try chat.setWebOptions(options, sessionID: id)
        let tool = Task { try await chat.executeTool(.webSearch(query: "unrelated", language: .en), sessionID: id) }
        for _ in 0..<1000 { if await web.entered { break }; await Task.yield() }
        try #require(await web.entered)
        await chat.disconnectMCP()
        #expect(chat.isToolRunning && chat.state.sessions[0].toolActivities?.last?.status == .running)
        await chat.cancelTool(); _ = try? await tool.value
        try await chat.flush(); try await store.close()
    }

    @Test func duplicateDisconnectsShareOneDrainAndBlockNewConnectionUntilComplete() async throws {
        let (store, unused) = try await fixture(); _ = unused
        let service = ControlledChatMCP()
        let chat = ChatController(store: store, mcpService: service) { throw WorkflowIssue("No generation") }
        await chat.load(); let a = try chat.newSession(), b = try chat.newSession()
        try await chat.connectMCP(endpoint: "http://127.0.0.1:12345/mcp", sessionID: a, permitted: true)
        let first = Task { await chat.disconnectMCP() }
        for _ in 0..<1000 { if await service.disconnects > 0 { break }; await Task.yield() }
        let second = Task { await chat.disconnectMCP() }
        for _ in 0..<20 { await Task.yield() }
        #expect(await service.disconnects == 1)
        await #expect(throws: ChatMCPError.busy) { try await chat.connectMCP(endpoint: "http://127.0.0.1:12346/mcp", sessionID: b, permitted: true) }
        await service.resume(); await first.value; await second.value
        try await chat.connectMCP(endpoint: "http://127.0.0.1:12346/mcp", sessionID: b, permitted: true)
        #expect(chat.mcpSessionID == b && chat.mcpStatus == .connected(endpoint: "http://127.0.0.1:12346/mcp"))
        await chat.disconnectMCP(); try await chat.flush(); try await store.close()
    }
}
