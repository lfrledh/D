import Foundation
import Testing
@testable import DWorkbench

@Suite("Chat editable artifact storage", .serialized) @MainActor
struct ChatArtifactStoreTests {
    @Test func exactVersionsRemainIndependentAndBackupRestoresAllSources() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("artifact-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Original.dproject"), name: "Artifact")
        let chat = ChatController(store: store) { throw WorkflowIssue("No inference") }
        await chat.load(); let id = try chat.newSession()
        let original = try await store.publishWorkflowAsset(data: Data("Original e\u{301}".utf8), mediaType: "text/plain",
            name: "Original", operationID: "fixture").record.reference
        let first = try await chat.saveArtifact(.init(sessionID: id, title: "文稿", kind: .html,
            text: "<p>e\u{301} 👩🏽‍🎨</p>", source: original))
        var next = try first.revised(); next.text = "<p>é 👩🏽‍🎨</p>"
        let second = try await chat.saveArtifact(next)
        #expect(first.output != second.output)
        #expect(try await store.workflowData(#require(first.output)) == Data(first.text.utf8))
        #expect(try await store.workflowData(#require(second.output)) == Data(next.text.utf8))
        #expect(try await store.workflowData(original) == Data("Original e\u{301}".utf8))
        #expect(try await chat.saveArtifact(next).output == second.output)
        var stale = next; stale.text = "conflicting content"
        await #expect(throws: (any Error).self) { try await chat.saveArtifact(stale) }
        #expect(chat.selectedSession?.artifacts?.count == 2)
        try await chat.prepareForBackup()
        let backup = root.appendingPathComponent("Artifacts.dbackup")
        _ = try await store.createBackup(at: backup)
        let destination = root.appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: destination)
        let restored = try await ProjectStore.open(at: destination)
        let copied = try await restored.chatState()
        #expect(copied.sessions.first?.artifacts == [first, second])
        #expect(try await restored.workflowData(#require(second.output)) == Data(next.text.utf8))
        try await restored.close(); try await store.close()
    }

    @Test func failedSidecarSaveRetainsPublishedVersionAndRetriesWithoutDuplicateAsset() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("artifact-sidecar-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Original.dproject"), name: "Artifact")
        let chat = ChatController(store: store) { throw WorkflowIssue("No inference") }
        await chat.load(); let id = try chat.newSession()
        let first = try await chat.saveArtifact(.init(sessionID: id, title: "First", kind: .plainText, text: "original"))
        let sidecar = store.rootURL.appendingPathComponent("quick-chat.json")
        let previous = try Data(contentsOf: sidecar)
        // Deliberate external edit in this test's own project, restored only by the fixture.
        try Data("invalid external fixture".utf8).write(to: sidecar)
        var next = try first.revised(); next.text = "revised"
        await #expect(throws: (any Error).self) { try await chat.saveArtifact(next) }
        #expect(chat.saveIssue != nil)
        let pending = try #require(chat.selectedSession?.artifacts?.last)
        #expect(pending.revision == 2)
        let assets = await store.snapshot().assets.count
        #expect(try Data(contentsOf: sidecar) == Data("invalid external fixture".utf8))
        try previous.write(to: sidecar)
        let retried = try await chat.saveArtifact(next)
        #expect(retried.output == pending.output && chat.saveIssue == nil)
        #expect(await store.snapshot().assets.count == assets)
        #expect(try await store.chatState().sessions.first?.artifacts?.count == 2)
        try await store.close()
    }

    @Test func admittedSaveDrainsEvenWhenNewAdmissionHasClosed() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("artifact-drain-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Original.dproject"), name: "Artifact")
        var admissions = 0
        let chat = ChatController(store: store, allowsSubmission: { admissions += 1; return admissions == 1 }) { throw WorkflowIssue("No inference") }
        await chat.load(); let id = try chat.newSession()
        let saved = try await chat.saveArtifact(.init(sessionID: id, title: "Accepted", kind: .plainText, text: "preserve"))
        #expect(try await store.chatState().sessions.first?.artifacts == [saved])
        await #expect(throws: (any Error).self) { try await chat.saveArtifact(saved.revised()) }
        try await chat.prepareForTermination(); try await store.close()
    }

    @Test func completeSidecarBudgetRejectsBeforePublishingWithoutPoisoningState() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("artifact-budget-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Original.dproject"), name: "Artifact")
        var state = ChatState()
        for index in 0..<15 {
            var existing = ChatSession(title: "Existing history \(index)")
            let message = ChatMessage(parentID: nil, role: .user, text: String(repeating: "a", count: 1_048_576))
            existing.messages = [message]; existing.selectedLeafID = message.id
            state.sessions.append(existing)
        }
        let session = try #require(state.sessions.first)
        state.selectedSessionID = session.id
        _ = try await store.saveChatState(state, expectedRevision: 0)
        let chat = ChatController(store: store) { throw WorkflowIssue("No inference") }; await chat.load()
        let before = chat.state, assets = await store.snapshot().assets
        let content = ChatArtifactContent(sessionID: session.id, title: "Large", kind: .code, text: String(repeating: "b", count: 1_048_576))
        await #expect(throws: (any Error).self) { try await chat.saveArtifact(content) }
        #expect(chat.state == before && chat.saveIssue == nil && !chat.isBusy)
        #expect(await store.snapshot().assets == assets)
        try chat.updateDraft("Still usable", sessionID: session.id)
        try await chat.prepareForTermination(); try await store.close()
    }

    @Test func invalidAndUnavailableSaveDoNotAlterExistingVersionOrInput() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("artifact-failure-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Original.dproject"), name: "Artifact")
        var admission = true
        let chat = ChatController(store: store, allowsSubmission: { admission }) { throw WorkflowIssue("No inference") }
        await chat.load(); let id = try chat.newSession()
        try chat.updateDraft("Unsent original 原文", sessionID: id)
        let first = try await chat.saveArtifact(.init(sessionID: id, title: "Code", kind: .code, text: "print('a')"))
        var next = try first.revised(); next.text = "print('b')"
        admission = false
        await #expect(throws: (any Error).self) { try await chat.saveArtifact(next) }
        admission = true
        #expect(chat.selectedSession?.draft == "Unsent original 原文")
        #expect(chat.selectedSession?.artifacts == [first])
        try await store.close()
        await #expect(throws: (any Error).self) { try await chat.saveArtifact(next) }
        #expect(chat.selectedSession?.artifacts == [first])
        #expect(!chat.isBusy)
    }
}
