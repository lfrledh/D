import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor TemporaryFixtureEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw WorkflowIssue("This lifecycle fixture must not run inference")
    }
}
@Suite("Temporary chat ownership", .serialized) @MainActor
struct ChatTemporaryTests {
    @Test func isolatedMemoryBackupAndOriginalProtection() async throws {
        let (owner, longStore, parent, settings) = try await fixture()
        settings.set("long-term default", forKey: "D.Chat.NewSessionSystemPrompt.v1")
        let original = try await longStore.publishWorkflowAsset(data: Data("private original".utf8), mediaType: "text/plain", name: "original", operationID: "fixture").record.reference
        let child = try await owner.startTemporaryChat(in: parent)
        let chat = try #require(child.chat), id = try #require(chat.selectedSession?.id)
        #expect(chat.isTemporary && !chat.ownsPersonalMemory && chat.defaultSystemPrompt.isEmpty)
        #expect(chat.personalMemories.isEmpty && chat.personalKnowledgeDocuments.isEmpty)
        #expect(throws: (any Error).self) { try chat.setMemoryScopes([.personal], sessionID: id) }
        await #expect(throws: (any Error).self) { try await chat.writeMemory(.manual(text: "do not persist", scope: .personal)) }
        await #expect(throws: (any Error).self) { try await chat.prepareForBackup() }
        await #expect(throws: (any Error).self) { _ = try await chat.store.backupPlan() }
        #expect(try await longStore.chatState().sessions.isEmpty)
        try chat.updateDraft("temporary secret", sessionID: id); try await chat.flush()
        let root = chat.store.rootURL.deletingLastPathComponent()
        try await owner.endTemporaryChat()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try await longStore.workflowText(original) == "private original")
        #expect(settings.string(forKey: "D.Chat.NewSessionSystemPrompt.v1") == "long-term default")
        #expect(throws: (any Error).self) { try chat.updateDraft("late", sessionID: id) }
        #expect(owner.temporaryChatSession == nil)
        #expect(await owner.cancelAndCloseProject())
    }
    @Test func closeWaitsOwnedFileActivityAndRejectsLateAdmission() async throws {
        let (owner, destination, parent, _) = try await fixture()
        let child = try await owner.startTemporaryChat(in: parent), chat = try #require(child.chat)
        let output = try await chat.store.publishWorkflowAsset(data: Data("admitted save".utf8), mediaType: "text/plain", name: "save", operationID: "fixture").record.reference
        let activity = try chat.beginExternalActivity()
        let root = chat.store.rootURL
        let closing = Task { try await owner.endTemporaryChat() }
        while !chat.isDiscarding { await Task.yield() }
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(throws: (any Error).self) { _ = try chat.beginExternalActivity() }
        let retained = try await chat.retainTemporaryText(output, in: destination, admittedActivity: activity)
        chat.endExternalActivity(activity)
        try await closing.value
        #expect(try await destination.workflowText(retained) == "admitted save")
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(await owner.cancelAndCloseProject())
    }
    @Test func explicitRetainedTextDoesNotCopyPrivateParents() async throws {
        let (owner, destination, parent, _) = try await fixture()
        let child = try await owner.startTemporaryChat(in: parent), chat = try #require(child.chat)
        let prompt = try await chat.store.publishWorkflowAsset(data: Data("private prompt".utf8), mediaType: "text/plain", name: "private", operationID: "fixture").record.reference
        let output = try await chat.store.publishWorkflowAsset(data: Data("selected output 🐈".utf8), mediaType: "text/plain", name: "answer", parents: [prompt], operationID: "fixture").record.reference
        let retained = try await chat.retainTemporaryText(output, in: destination)
        let archive = try #require(try await destination.workflowState().archive)
        #expect(archive.assets.count == 1 && archive.assets[0].parents.isEmpty)
        #expect(archive.assets[0].request == nil && archive.assets[0].metadata["selectedContentSHA256"] == output.sha256)
        try await owner.endTemporaryChat()
        #expect(try await destination.workflowText(retained) == "selected output 🐈")
        #expect(await owner.cancelAndCloseProject())
    }
    @Test func quitPreflightPreservesTemporarySessionWhenAnotherOwnerMayRefuse() async throws {
        let (owner, _, parent, _) = try await fixture()
        let child = try await owner.startTemporaryChat(in: parent), chat = try #require(child.chat)
        let id = try #require(chat.selectedSession?.id)
        try chat.updateDraft("must survive cancelled Quit", sessionID: id)
        #expect(await owner.prepareInternalForTermination())
        #expect(owner.temporaryChatSession === child && !chat.isDiscarding)
        #expect(FileManager.default.fileExists(atPath: chat.store.rootURL.path))
        try chat.updateDraft("still editable", sessionID: id)
        try await owner.endTemporaryChat()
        #expect(await owner.cancelAndCloseProject())
    }
    @Test func cleanupUnlinksOwnedLinkAndPreservesExternalTarget() async throws {
        let (_, store, parent, _) = try await fixture()
        let owned = try await ChatTemporaryStorage.create(in: parent)
        let outside = parent.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: owned.root.appendingPathComponent("link"), withDestinationURL: outside)
        try await owned.store.close(); try owned.discardClosedStore()
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        try owned.discardClosedStore()
        try await store.close()
    }
    private func fixture() async throws -> (ProjectSession, ProjectStore, URL, UserDefaults) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("TempChat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("LongTerm.dproject"), name: "long term")
        let runtime = WorkbenchSession(engine: TemporaryFixtureEngine(), backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let settings = try #require(UserDefaults(suiteName: "ChatTemporaryTests." + UUID().uuidString))
        let owner = ProjectSession(sessionFactory: { _ in runtime.borrowed(artifactStore: store) }, settings: settings)
        try await owner.activateInternalWorkspace(store)
        return (owner, store, root.appendingPathComponent("Temporary"), settings)
    }
}
