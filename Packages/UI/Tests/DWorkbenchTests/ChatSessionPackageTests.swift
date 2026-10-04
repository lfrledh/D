import Foundation
import Testing
@testable import DWorkbench

@Suite("Recoverable single session package", .serialized) @MainActor
struct ChatSessionPackageTests {
    @Test func wholeTreeRestoresIndependentlyWithoutOtherSessionOrQuickDraft() async throws {
        let (root, store, chat) = try await fixture()
        let selected = try chat.newSession(title: "Selected 中文 👩🏽‍🎨")
        let parent = try await store.publishWorkflowAsset(data: Data("original source".utf8), mediaType: "text/plain", name: "source", operationID: "fixture").record.reference
        let first = try await chat.saveArtifact(.init(sessionID: selected, title: "Versioned", kind: .code, text: "print(1)", source: parent))
        var next = try first.revised(); next.text = "print(2)"
        _ = try await chat.saveArtifact(next)
        try chat.updateDraft("unsent selected", sessionID: selected)
        try await chat.addAttachment(parent, name: "source", sessionID: selected)
        let other = try chat.newSession(title: "Unrelated CANARY")
        try chat.updateDraft("CANARY unrelated secret", sessionID: other)
        _ = try await chat.saveArtifact(.init(sessionID: other, title: "Other", kind: .code, text: "CANARY artifact"))
        try await chat.flush()
        // Two roots are legitimate branches; no inference or selected-path flattening.
        var state = chat.state
        let index = try #require(state.sessions.firstIndex { $0.id == selected })
        let a = ChatMessage(parentID: nil, role: .user, text: "branch a")
        let b = ChatMessage(parentID: nil, role: .user, text: "branch b")
        state.sessions[index].messages = [a, b]; state.sessions[index].selectedLeafID = b.id
        // Reviewing a suggestion must survive export even before another request uses it.
        let source = try ChatContextSource.capture(session: state.sessions[index], coveredMessageIDs: [b.id])
        let projectID = await store.snapshot().id
        let suggestion = try ChatMemoryEntry.suggestion(text: "记忆 e\u{301} 👩🏽‍🎨", scope: .project(projectID), source: source)
        let approved = try suggestion.approved()
        let unused = try ChatMemoryEntry.manual(text: "CANARY unrelated project memory", scope: approved.scope)
        state.memoryEntries = [suggestion, approved, unused]
        _ = try await store.saveChatState(state, expectedRevision: state.revision)
        let before = try await store.chatState(), manifestBefore = await store.snapshot()
        let plan = try await store.chatSessionBackupPlan(sessionID: selected, expectedChatRevision: before.revision)
        #expect(plan.files.filter { $0.relativePath == "quick-chat.json" }.count == 1)
        #expect(!plan.files.contains { $0.relativePath == "quick-creation.json" })
        #expect(!plan.files.compactMap(\.data).contains { String(decoding: $0, as: UTF8.self).contains("CANARY") })
        let backup = root.appendingPathComponent("Session.dbackup")
        _ = try await ProjectBackup.create(plan, at: backup)
        await #expect(throws: (any Error).self) { _ = try await ProjectBackup.create(plan, at: backup) }
        #expect(try await store.chatState() == before)
        #expect(await store.snapshot() == manifestBefore)
        try await store.close()
        try FileManager.default.moveItem(at: store.rootURL, to: root.appendingPathComponent("Original-preserved.dproject"))
        let destination = root.appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: destination)
        let restored = try await ProjectStore.open(at: destination), restoredChat = try await restored.chatState()
        #expect(restoredChat.sessions.count == 1 && restoredChat.selectedSessionID == selected)
        #expect(restoredChat.sessions[0].messages == [a, b])
        #expect(restoredChat.sessions[0].draft == "unsent selected")
        #expect(restoredChat.sessions[0].artifacts?.count == 2)
        #expect(restoredChat.sessions[0].memoryScopes == [])
        #expect(restoredChat.memoryEntries == [suggestion, approved])
        #expect(try await restored.workflowText(parent) == "original source")
        #expect(try await restored.workflowText(#require(first.output)) == "print(1)")
        #expect(await restored.snapshot().effectiveInstanceID != manifestBefore.effectiveInstanceID)
        #expect(await restored.snapshot().assets.count == 3)
        try await restored.close()
    }
    @Test func sourceMutationAfterSnapshotFailsWithoutPublishingPackage() async throws {
        let (root, store, chat) = try await fixture()
        let id = try chat.newSession()
        let content = try await chat.saveArtifact(.init(sessionID: id, title: "keep", kind: .plainText, text: "original"))
        let plan = try await chat.sessionBackupPlan(sessionID: id)
        let source = try #require(plan.files.first { $0.sourceURL != nil }?.sourceURL)
        try Data("changed fixture".utf8).write(to: source)
        let destination = root.appendingPathComponent("Rejected.dbackup")
        await #expect(throws: (any Error).self) { _ = try await ProjectBackup.create(plan, at: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(chat.selectedSession?.artifacts?.first?.id == content.id)
        try await store.close()
    }
    @Test func staleSnapshotRejectsAndUnrelatedMissingAssetDoesNotBlockSelectedExport() async throws {
        let (_, store, chat) = try await fixture()
        let id = try chat.newSession()
        try chat.updateDraft("Selected", sessionID: id); try await chat.flush()
        let old = chat.state.revision
        try chat.updateDraft("Changed", sessionID: id); try await chat.flush()
        await #expect(throws: (any Error).self) { _ = try await store.chatSessionBackupPlan(sessionID: id, expectedChatRevision: old) }
        let extra = try await store.publishWorkflowAsset(data: Data("unrelated".utf8), mediaType: "text/plain", name: "unrelated", operationID: "fixture").record.reference
        let entry = try #require(await store.snapshot().assets.first { $0.id == extra.assetID })
        let path = store.rootURL.appendingPathComponent(entry.relativePath)
        try FileManager.default.moveItem(at: path, to: path.deletingLastPathComponent().appendingPathComponent("preserved-missing.txt"))
        let plan = try await chat.sessionBackupPlan(sessionID: id)
        #expect(plan.files.count == 3 && plan.missing.isEmpty)
        try await store.close()
    }
    @Test func sameRevisionExternalEditIsRejectedWithoutReauthorizingLoadedState() async throws {
        let (_, store, chat) = try await fixture()
        let id = try chat.newSession(); try chat.updateDraft("visible", sessionID: id); try await chat.flush()
        var external = chat.state; external.sessions[0].draft = "unseen external edit"
        let bytes = try JSONEncoder().encode(external), url = store.rootURL.appendingPathComponent("quick-chat.json")
        try bytes.write(to: url)
        await #expect(throws: (any Error).self) { _ = try await chat.sessionBackupPlan(sessionID: id) }
        #expect(chat.selectedSession?.draft == "visible")
        #expect(try Data(contentsOf: url) == bytes)
        try await store.close()
    }
    @Test func microphoneOriginalAndTranscriptRestoreWithRealOrigin() async throws {
        let (root, store, chat) = try await fixture()
        let capture = try await store.reserveAudioCapture(name: "recorded fixture")
        let url = try await store.audioCaptureURL(id: capture.id)
        try AudioTestMedia.writePCM(to: url, samples: [[-0.25, 0, 0.25]], sampleRate: 8_000, bitDepth: 32, floatingPoint: true)
        _ = try await store.finalizeAudioCapture(id: capture.id)
        let original = try await store.pinWorkflowAsset(capture.id)
        let transcript = try await store.publishWorkflowAsset(data: Data("transcript fixture, not real ASR".utf8), mediaType: "text/plain",
            name: "transcript", parents: [original], operationID: "d.chat.transcribe").record.reference
        let id = try chat.newSession(); _ = try await chat.addAttachment(transcript, name: "transcript", sessionID: id)
        let backup = root.appendingPathComponent("Recorded.dbackup")
        let plan = try await chat.sessionBackupPlan(sessionID: id)
        _ = try await ProjectBackup.create(plan, at: backup)
        try await store.close()
        try FileManager.default.moveItem(at: store.rootURL, to: root.appendingPathComponent("Recorded-original-preserved.dproject"))
        let restoredURL = root.appendingPathComponent("Recorded-restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restoredURL)
        let restored = try await ProjectStore.open(at: restoredURL)
        let asset = try #require(await restored.snapshot().assets.first { $0.id == original.assetID })
        #expect(asset.metadata.audio?.origin == .microphone && asset.relativePath == capture.relativePath)
        #expect(try await restored.workflowData(original).count > 0)
        #expect(try await restored.workflowText(transcript) == "transcript fixture, not real ASR")
        try await restored.close()
    }
    private func fixture() async throws -> (URL, ProjectStore, ChatController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("ChatPackage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Original.dproject"), name: "Package")
        let chat = ChatController(store: store) { throw WorkflowIssue("No inference") }
        await chat.load(); return (root, store, chat)
    }
}
