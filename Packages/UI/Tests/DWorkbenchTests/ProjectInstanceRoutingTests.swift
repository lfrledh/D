import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor RoutingNoInferenceEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw WorkflowIssue("This routing fixture does not execute inference.")
    }
}

@Suite("Independent project instance routing", .serialized)
@MainActor
struct ProjectInstanceRoutingTests {
    @Test func restoredProjectKeepsLogicalHistoryButGetsDistinctRecentAndControllerTargets() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("instance-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "D.InstanceRouting." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = RoutingNoInferenceEngine()
        let owner = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "routing.none",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: settings)
        let originalURL = base.appendingPathComponent("Original.dproject")
        await owner.createProject(at: originalURL)
        let original = try #require(owner.manifest)
        await owner.openWorkflow()
        let controller = try #require(owner.workflow)
        let referencedSource = base.appendingPathComponent("referenced.txt")
        let copiedSource = base.appendingPathComponent("copied.txt")
        try Data("referenced".utf8).write(to: referencedSource)
        try Data("copied".utf8).write(to: copiedSource)
        await controller.importLibraryFile(referencedSource, mode: .reference)
        await controller.importLibraryFile(copiedSource, mode: .copy)
        let imported = try #require(owner.currentStore)
        let importedAssets = await imported.snapshot().assets
        #expect(importedAssets.contains { $0.fileLocations?.locations.first?.role == .externalOriginal })
        #expect(importedAssets.contains { $0.fileLocations == nil })
        controller.addBlankGraph()
        try await controller.saveExplicitEdits()
        let captured = try #require(controller.canvasInsertionTarget())
        let backup = base.appendingPathComponent("Backup.dbackup")
        let store = try #require(owner.currentStore)
        _ = try await store.createBackup(at: backup)
        await owner.closeProject()
        let restoredURL = base.appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restoredURL)
        await owner.openProject(at: restoredURL)
        let restored = try #require(owner.manifest)
        #expect(restored.id == original.id)
        #expect(restored.effectiveInstanceID != original.effectiveInstanceID)
        await owner.openWorkflow()
        let restoredController = try #require(owner.workflow)
        #expect(restoredController.rootGraph?.id == captured.rootID)
        #expect(restoredController.rootGraph?.revision == captured.revision)
        #expect(!restoredController.isCurrent(captured))
        let recents = owner.recentProjects
        #expect(recents.count == 2)
        #expect(Set(recents.map(\.id)).count == 2)
        #expect(Set(recents.map(\.effectiveInstanceID)) == Set([original.effectiveInstanceID, restored.effectiveInstanceID]))
        #expect(await owner.openRecentProject(id: original.effectiveInstanceID))
        #expect(owner.manifest?.effectiveInstanceID == original.effectiveInstanceID)
        await owner.closeProject()
    }
}
