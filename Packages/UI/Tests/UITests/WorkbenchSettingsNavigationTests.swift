import DWorkbench
import Foundation
import Testing
@testable import UI

/// Store-backed destination checks only: no NSApplication, view, hosting or window.
@Suite("Workbench settings destinations")
@MainActor struct WorkbenchSettingsNavigationTests {
    @Test func destinationBindsControllerStoreAndSelectedSessionWithoutRunning() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("settings-destination-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Target.dproject"), name: "Target")
        let chat = ChatController(store: store) { throw WorkflowIssue("No service may be requested") }
        await chat.load()
        let first = try chat.newSession()
        try await chat.flush()
        let request = ChatToolsNavigationRequest(chat: chat)
        let before = chat.state
        #expect(request.matches(chat))
        #expect(request.sessionID == first)
        #expect(chat.state == before && !chat.isRunning)

        let second = try chat.newSession()
        #expect(second != first && !request.matches(chat))
        #expect(chat.state.sessions.contains { $0.id == first })
        try chat.selectSession(first)
        try await chat.flush()

        // Even the same persisted project/session must not redirect to a new controller.
        let other = ChatController(store: store) { throw WorkflowIssue("No service may be requested") }
        await other.load()
        #expect(other.state.selectedSessionID == first)
        #expect(!request.matches(other))
        #expect(request.matches(chat))
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }

    @Test func preparingDestinationDoesNotCreateAnEmptyConversation() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("settings-empty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Empty.dproject"), name: "Empty")
        let chat = ChatController(store: store) { throw WorkflowIssue("No service may be requested") }
        await chat.load()
        let before = chat.state
        let request = ChatToolsNavigationRequest(chat: chat)
        #expect(request.matches(chat) && request.sessionID == nil)
        #expect(chat.state == before && chat.state.sessions.isEmpty)
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }
}
