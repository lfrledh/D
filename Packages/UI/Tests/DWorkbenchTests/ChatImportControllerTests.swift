import Foundation
import Testing
@testable import DWorkbench

@Suite("Imported conversation provenance and persistence", .serialized) @MainActor
struct ChatImportControllerTests {
    private let bytes = Data(#"{"format":"openai-messages","version":1,"messages":[{"role":"system","content":"Original system"},{"role":"user","content":"你好 é 👩🏽‍🎨"},{"role":"assistant","content":"<script>not executable</script>","tool_calls":[]},{"role":"tool","content":"ignored"}]}"#.utf8)

    @Test func explicitLossAcceptanceCreatesNewNonExecutionHistoryAndRestores() async throws {
        let (store, chat) = try await fixture()
        let prior = try chat.newSession(); try chat.updateDraft("Keep original draft", sessionID: prior)
        try await chat.flush(); let original = chat.state
        await #expect(throws: (any Error).self) { try await chat.importConversation(bytes, title: "External", allowingLosses: false) }
        #expect(chat.state == original)
        let id = try await chat.importConversation(bytes, title: "External", allowingLosses: true)
        let imported = try #require(chat.selectedSession)
        #expect(imported.id == id && imported.attempts.isEmpty && imported.configuration == nil)
        #expect(imported.messages.count == 2 && imported.importLossNotes?.count == 2)
        #expect(imported.messages.allSatisfy { $0.importedSource?.sourceSHA256.count == 64 && $0.attemptID == nil })
        #expect(chat.state.sessions.first(where: { $0.id == prior }) == original.sessions.first)
        let plan = try ChatContextPlan.build(path: imported.path(to: imported.selectedLeafID), attempts: [], prompt: "Continue", attachments: [], system: imported.systemPrompt)
        #expect(plan.messagesJSON.contains("not executable") && plan.messagesJSON.contains("Original system"))
        let html = try ChatInterchange.exportHTML(session: imported, leafID: #require(imported.selectedLeafID))
        #expect(html.contains("&lt;script&gt;") && !html.contains("<script>"))
        let exportRoot = store.rootURL.deletingLastPathComponent().appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: false)
        let manifestBefore = try await store.snapshot()
        _ = try await store.exportChatHTML(imported, leafID: #require(imported.selectedLeafID), exportID: UUID(), directory: exportRoot)
        #expect(try await store.snapshot() == manifestBefore)
        let fork = try chat.forkSession(id)
        #expect(chat.selectedSession?.id == fork && chat.selectedSession?.importLossNotes == imported.importLossNotes)
        try await chat.prepareForBackup()
        let backup = store.rootURL.deletingLastPathComponent().appendingPathComponent("import.dbackup")
        _ = try await store.createBackup(at: backup)
        let destination = backup.deletingLastPathComponent().appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: destination)
        let restored = try await ProjectStore.open(at: destination)
        let restoredState = try await restored.chatState(), savedState = try await store.chatState()
        #expect(restoredState == savedState)
        try await restored.close(); try await store.close()
    }

    @Test func sameImportReceiptRetriesSavingWithoutDuplicatingAndRejectsDifferentBytes() async throws {
        let (store, chat) = try await fixture(); let receipt = UUID()
        let id = try await chat.importConversation(bytes, title: "Import", allowingLosses: true, importID: receipt)
        _ = try await chat.importConversation(bytes, title: "Must not overwrite", allowingLosses: true, importID: receipt)
        #expect(chat.state.sessions.count == 1 && chat.selectedSession?.id == id && chat.selectedSession?.title == "Import")
        let other = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "not executable", with: "different").utf8)
        await #expect(throws: (any Error).self) { try await chat.importConversation(other, title: "Conflict", allowingLosses: true, importID: receipt) }
        #expect(chat.state.sessions.count == 1)
        try await store.close()
    }

    @Test func failedFirstSaveCanRetrySameReceiptWithoutOverwritingOtherInputs() async throws {
        let (store, chat) = try await fixture(); let receipt = UUID()
        let obstruction = store.rootURL.appendingPathComponent("quick-chat.json")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await chat.importConversation(bytes, title: "Import", allowingLosses: true, importID: receipt) }
        #expect(chat.saveIssue != nil && chat.state.sessions.count == 1)
        await #expect(throws: (any Error).self) { try await chat.importConversation(bytes, title: "New must be blocked", allowingLosses: true) }
        let preserved = store.rootURL.deletingLastPathComponent().appendingPathComponent("preserved-obstruction")
        try FileManager.default.moveItem(at: obstruction, to: preserved) // Only this fixture's empty directory.
        _ = try await chat.importConversation(bytes, title: "Same receipt", allowingLosses: true, importID: receipt)
        #expect(chat.saveIssue == nil && chat.state.sessions.count == 1)
        #expect(try await store.chatState().sessions.first?.id == receipt)
        #expect(FileManager.default.fileExists(atPath: preserved.path))
        try await store.close()
    }

    @Test func importedAssistantCannotAlsoClaimLocalAttempt() async throws {
        let (store, chat) = try await fixture()
        _ = try await chat.importConversation(bytes, title: "Import", allowingLosses: true)
        var state = chat.state
        let imported = state.sessions[0].messages[1]
        state.sessions[0].messages[1] = .init(id: imported.id, parentID: imported.parentID, role: .assistant,
            text: imported.text, attemptID: UUID(), importedSource: imported.importedSource)
        #expect(throws: (any Error).self) { try state.validate() }
        try await store.close()
    }

    @Test func selectedExternalConversationKeepsSourceIdentityAcrossRetryAndBackup() async throws {
        let entry = #"{"title":"External","history":{"currentId":"a","messages":{"u":{"id":"u","parentId":null,"childrenIds":["a"],"role":"user","content":"中文 👩🏽‍🎨"},"a":{"id":"a","parentId":"u","childrenIds":[],"role":"assistant","content":"A <script>literal</script>","done":true}}}}"#
        let bytes = Data(("[" + entry + "," + entry.replacingOccurrences(of: "External", with: "Second") + "]").utf8)
        let original = bytes
        let (store, chat) = try await fixture()
        await #expect(throws: (any Error).self) {
            try await chat.importConversation(bytes, title: "Must choose", allowingLosses: true)
        }
        #expect(chat.state.sessions.isEmpty)
        let receipt = UUID()
        let id = try await chat.importConversation(bytes, title: "Second", allowingLosses: true,
                                                   importID: receipt, selectedConversationIndex: 1)
        let session = try #require(chat.selectedSession)
        #expect(session.id == id && session.attempts.isEmpty && session.configuration == nil)
        #expect(session.messages.allSatisfy { $0.importedSource?.conversationIndex == 1 })
        _ = try await chat.importConversation(bytes, title: "Retry title ignored", allowingLosses: true,
                                              importID: receipt, selectedConversationIndex: 1)
        await #expect(throws: (any Error).self) {
            try await chat.importConversation(bytes, title: "Wrong entry", allowingLosses: true,
                                               importID: receipt, selectedConversationIndex: 0)
        }
        #expect(chat.state.sessions == [session])
        let leaf = try #require(session.selectedLeafID)
        let output = try await chat.saveAssistantFinal(leaf, sessionID: id)
        #expect(String(decoding: try await store.workflowData(output), as: UTF8.self) == "A <script>literal</script>")
        try await chat.prepareForBackup()
        let backup = store.rootURL.deletingLastPathComponent().appendingPathComponent("external.dbackup")
        _ = try await store.createBackup(at: backup)
        let target = backup.deletingLastPathComponent().appendingPathComponent("ExternalRestored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: target)
        let restored = try await ProjectStore.open(at: target)
        let saved = try await store.chatState(), recovered = try await restored.chatState()
        #expect(saved == recovered)
        #expect(bytes == original)
        try await restored.close(); try await store.close()
    }

    private func fixture() async throws -> (ProjectStore, ChatController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("ChatImport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Import.dproject"), name: "Import fixture")
        let chat = ChatController(store: store) { throw WorkflowIssue("Import must never load a model") }
        await chat.load(); return (store, chat)
    }
}
