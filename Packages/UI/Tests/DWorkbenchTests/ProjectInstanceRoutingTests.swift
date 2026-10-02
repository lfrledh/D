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
    @Test func verificationRefreshUpdatesRevisionWithoutReadingUnrelatedAsset() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("verification-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "D.VerificationRefresh." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = RoutingNoInferenceEngine()
        let owner = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "routing.none",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: settings)
        await owner.createProject(at: base.appendingPathComponent("Work.dproject"))
        let store = try #require(owner.currentStore)
        let instanceID = try #require(owner.manifest?.effectiveInstanceID)
        let selected = base.appendingPathComponent("selected.txt")
        let unrelated = base.appendingPathComponent("unrelated.txt")
        try Data("selected".utf8).write(to: selected)
        try Data("unrelated".utf8).write(to: unrelated)
        let first = try await store.importWorkflowMediaFile(at: selected, mode: .reference)
        _ = try await store.importWorkflowMediaFile(at: unrelated, mode: .reference)
        try FileManager.default.removeItem(at: unrelated)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try await store.verifyAssetLocation(first.asset.id)
        await owner.refreshAfterFileOperation(store: store, instanceID: instanceID, refreshMedia: false)
        #expect(owner.manifest?.revision == (await store.snapshot()).revision)
        #expect(owner.manifest?.assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first?.lastVerifiedAt != nil)
        #expect(owner.assetURLs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.rootURL.appendingPathComponent("AssetInputs").path))
        #expect(owner.errorMessage == nil)
        try Data("changed selected".utf8).write(to: selected)
        await #expect(throws: (any Error).self) { try await store.verifyAssetLocation(first.asset.id) }
        await owner.refreshAfterFileOperation(store: store, instanceID: instanceID, refreshMedia: false)
        #expect(owner.manifest?.revision == (await store.snapshot()).revision)
        #expect(owner.assetURLs.isEmpty)
        #expect(owner.errorMessage == nil)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.verifyAssetLocation(first.asset.id)
        }
        await #expect(throws: (any Error).self) { try await cancelled.value }
        await owner.refreshAfterFileOperation(store: store, instanceID: instanceID, refreshMedia: false)
        #expect(owner.manifest?.revision == (await store.snapshot()).revision)
        #expect(owner.assetURLs.isEmpty)
        #expect(owner.errorMessage == nil)
        await owner.closeProject()
    }

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
        let laterSource = base.appendingPathComponent("later.txt")
        try Data("later".utf8).write(to: laterSource)
        _ = try await store.importWorkflowMediaFile(at: laterSource, mode: .copy)
        let staleHighRevision = await store.snapshot()
        await owner.closeProject()
        let restoredURL = base.appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restoredURL)
        await owner.openProject(at: restoredURL)
        let restored = try #require(owner.manifest)
        #expect(restored.id == original.id)
        #expect(restored.effectiveInstanceID != original.effectiveInstanceID)
        #expect(staleHighRevision.revision > restored.revision)
        #expect(!ProjectSession.acceptsManifest(staleHighRevision, current: restored))
        await owner.openWorkflow()
        let restoredController = try #require(owner.workflow)
        #expect(restoredController.rootGraph?.id == captured.rootID)
        #expect(restoredController.rootGraph?.revision == captured.revision)
        #expect(!restoredController.isCurrent(captured))
        restoredController.addNode(operationID: "d.text.input", x: 20, y: 30)
        let unsavedGraph = restoredController.graph
        let selectedNode = restoredController.selectedNodeID
        let restoredStore = try #require(owner.currentStore)
        let freshSource = base.appendingPathComponent("fresh.txt")
        try Data("fresh".utf8).write(to: freshSource)
        let fresh = try await restoredStore.importWorkflowMediaFile(at: freshSource, mode: .copy)
        await owner.refreshAfterFileOperation(store: restoredStore, instanceID: restored.effectiveInstanceID)
        #expect(owner.manifest?.assets.contains(where: { $0.id == fresh.asset.id }) == true)
        #expect(restoredController.availableAssets.contains(where: { $0.id == fresh.asset.id }))
        #expect(restoredController.graph == unsavedGraph)
        #expect(restoredController.selectedNodeID == selectedNode)
        await owner.refreshAfterFileOperation(store: restoredStore, instanceID: original.effectiveInstanceID)
        #expect(owner.manifest?.effectiveInstanceID == restored.effectiveInstanceID)
        try await restoredController.saveExplicitEdits()
        let recents = owner.recentProjects
        #expect(recents.count == 2)
        #expect(Set(recents.map(\.id)).count == 2)
        #expect(Set(recents.map(\.effectiveInstanceID)) == Set([original.effectiveInstanceID, restored.effectiveInstanceID]))
        #expect(await owner.openRecentProject(id: original.effectiveInstanceID))
        #expect(owner.manifest?.effectiveInstanceID == original.effectiveInstanceID)
        await owner.closeProject()
    }

    @Test func confirmedSamePathOpenMigratesLegacyRecentWithoutRemovingRestoredCopy() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("legacy-recent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "D.LegacyRecent." + UUID().uuidString
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
        let backup = base.appendingPathComponent("Backup.dbackup")
        let originalStore = try #require(owner.currentStore)
        _ = try await originalStore.createBackup(at: backup)
        await owner.closeProject()
        let restoredURL = base.appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restoredURL)
        let bookmark = try originalURL.bookmarkData(options: [.withSecurityScope],
            includingResourceValuesForKeys: nil, relativeTo: nil)
        let legacy = [["id": original.id.uuidString, "name": "Original", "bookmark": bookmark.base64EncodedString()]]
        settings.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "workbench.recentProjects.v1")
        await owner.openProject(at: restoredURL)
        let restored = try #require(owner.manifest)
        #expect(owner.recentProjects.count == 2)
        await owner.openProject(at: originalURL)
        #expect(owner.recentProjects.count == 2)
        #expect(owner.recentProjects.filter { $0.instanceID == nil }.isEmpty)
        #expect(Set(owner.recentProjects.map(\.effectiveInstanceID)) ==
            Set([original.effectiveInstanceID, restored.effectiveInstanceID]))
        await owner.closeProject()
    }
}
