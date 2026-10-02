import Foundation
import Testing
@testable import DWorkbench

@Suite("Fixed media versions and locations", .serialized)
struct AssetFileLocationsTests {
    private func fixture() async throws -> (URL, ProjectStore, URL) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("Location-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("原声说明 👩🏽‍🎨.txt")
        try Data("原文 e\u{301} 👩🏽‍🎨".utf8).write(to: source)
        return (root, try await ProjectStore.create(at: root.appendingPathComponent("项目.dproject"), name: "位置"), source)
    }
    @Test func referenceDoesNotCopyAndInputSnapshotDoesNotChange() async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let ref = imported.record.reference
        #expect(!FileManager.default.fileExists(atPath: store.rootURL.appendingPathComponent(imported.asset.relativePath).path))
        let original = try Data(contentsOf: source)
        #expect(try await store.workflowData(ref) == original)
        let snapshot = try await store.workflowMedia(ref).0
        try Data("外部替换".utf8).write(to: source)
        #expect(try Data(contentsOf: snapshot) == original)
        await #expect(throws: (any Error).self) { try await store.workflowData(ref) }
        let info = try await store.assetLocationOverview(imported.asset.id, deep: true)
        #expect(info.locations.first?.status == .changed)
        #expect(try await store.workflowState().archive?.assets.first?.reference == ref)
        try await store.close()
    }
    @Test func copiedAssetDeepInspectionChecksPublishedDigest() async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .copy)
        #expect(imported.asset.fileLocations == nil)
        let unchanged = try await store.assetLocationOverview(imported.asset.id, deep: true)
        #expect(unchanged.locations.first?.status == .verified)
        try Data("changed copy".utf8).write(to: store.rootURL.appendingPathComponent(imported.asset.relativePath))
        let changed = try await store.assetLocationOverview(imported.asset.id, deep: true)
        #expect(changed.locations.first?.status == .changed)
        #expect(changed.contentSHA256 == imported.record.reference.sha256)
        try await store.close()
    }
    @Test func legacyProjectCopyMaterializesOnlyAfterKnownDigestMatches() async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .copy)
        let path = store.rootURL.appendingPathComponent(imported.asset.relativePath)
        #expect((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?.fileLocations == nil)
        let original = try Data(contentsOf: path)
        try Data("different".utf8).write(to: path)
        await #expect(throws: (any Error).self) { try await store.verifyAssetLocation(imported.asset.id) }
        #expect((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?.fileLocations == nil)
        try original.write(to: path)
        try await store.verifyAssetLocation(imported.asset.id)
        let placement = try #require((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?.fileLocations)
        #expect(placement.sha256 == imported.record.reference.sha256)
        #expect(placement.locations.count == 1 && placement.locations[0].role == .projectCopy)
        #expect(placement.locations[0].lastVerifiedAt != nil)
        #expect(placement.locations[0].contentCreatedAt == nil)
        try await store.close()
    }
    @Test func collectThenMoveSourceReopenAndExportKeepsOldVersion() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let original = try Data(contentsOf: source)
        #expect(try await store.projectFileOverview().externalCount == 1)
        try await store.collectAsset(imported.asset.id)
        #expect(try await store.projectFileOverview().externalCount == 0)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("moved.txt"))
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.workflowData(imported.record.reference) == original)
        let out = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let receipt = try await reopened.exportWorkflowAssets([imported.record.reference], name: "作品", exportID: UUID(), directory: out)
        #expect(!receipt.names.isEmpty)
        #expect(try await reopened.workflowData(imported.record.reference) == original)
        try await reopened.close()
    }
    @Test func independentLibraryCopyAndSameVersionRelocation() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let original = try Data(contentsOf: source)
        let lib = root.appendingPathComponent("外置库"); try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: false)
        try await store.collectAsset(imported.asset.id, to: lib)
        try Data("改动源".utf8).write(to: source)
        #expect(try await store.workflowData(imported.record.reference) == original)
        let info = try await store.assetLocationOverview(imported.asset.id, deep: true)
        #expect(info.locations.count == 2)
        #expect(info.locations.contains { $0.status == .changed })
        await #expect(throws: (any Error).self) { try await store.relocateAsset(imported.asset.id, to: source) }
        let replacement = root.appendingPathComponent("同版本.txt"); try original.write(to: replacement)
        try await store.relocateAsset(imported.asset.id, to: replacement)
        #expect(try await store.workflowData(imported.record.reference) == original)
        #expect(try await store.workflowState().archive?.assets.first?.reference == imported.record.reference)
        try await store.close()
    }
    @Test func cancelledCollectionAndRequiredSymlinkPreserveRecord() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let before = await store.snapshot()
        let job = Task { try await Task.sleep(for: .milliseconds(30)); try await store.collectAsset(imported.asset.id) }
        job.cancel(); await #expect(throws: (any Error).self) { try await job.value }
        #expect(await store.snapshot() == before)
        let link = root.appendingPathComponent("link.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: (any Error).self) { try await store.importWorkflowMediaFile(at: link, mode: .reference) }
        #expect(await store.snapshot() == before)
        try await store.close()
    }
    @Test func legacyNineteenMigrationPreservesBytesAndLocationsAbsent() async throws {
        let (_, store, _) = try await fixture()
        var legacy = await store.snapshot(); legacy.schemaVersion = 19; legacy.instanceID = nil
        let path = store.rootURL.appendingPathComponent("project.json")
        try await store.close()
        let old = try JSONEncoder().encode(legacy); try old.write(to: path)
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let current = await reopened.snapshot()
        #expect(current.schemaVersion == 20 && current.id == legacy.id && current.effectiveInstanceID == legacy.id)
        #expect(try Data(contentsOf: store.rootURL.appendingPathComponent("project.v19.backup.json")) == old)
        try await reopened.close()
    }

    @Test func failedCollectionDoesNotPublishAndProjectCopyExportChecksDigest() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let before = await store.snapshot()
        let workflow = try await store.workflowState().archive
        await #expect(throws: (any Error).self) { try await store.collectAsset(imported.asset.id, to: root.appendingPathComponent("missing")) }
        #expect(await store.snapshot() == before)
        #expect(try await store.workflowState().archive == workflow)
        try await store.collectAsset(imported.asset.id)
        try Data("modified".utf8).write(to: store.rootURL.appendingPathComponent(imported.asset.relativePath))
        let output = root.appendingPathComponent("export.txt")
        await #expect(throws: (any Error).self) { try await store.export(assetID: imported.asset.id, to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try await store.close()
    }

    @Test func explicitVerificationPersistsOnlyMatchingSelectedPlacement() async throws {
        let (root, store, source) = try await fixture()
        let first = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let other = root.appendingPathComponent("unrelated.txt")
        try Data("other".utf8).write(to: other)
        _ = try await store.importWorkflowMediaFile(at: other, mode: .reference)
        let before = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first)
        try FileManager.default.removeItem(at: other)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try await store.verifyAssetLocation(first.asset.id)
        let verified = try await store.assetLocationOverview(first.asset.id)
        #expect(verified.locations.first?.status == .verified)
        let persisted = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first)
        let originalCheck = try #require(before.lastVerifiedAt)
        let newCheck = try #require(persisted.lastVerifiedAt)
        #expect(persisted.lastVerifiedAt != nil)
        #expect(newCheck >= originalCheck)
        #expect(persisted.fingerprint != nil)
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let reopenedLocation = try #require((await reopened.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first)
        #expect(reopenedLocation.lastVerifiedAt == persisted.lastVerifiedAt)
        #expect(reopenedLocation.fingerprint == persisted.fingerprint)
        try Data("changed content".utf8).write(to: source)
        await #expect(throws: (any Error).self) { try await reopened.verifyAssetLocation(first.asset.id) }
        #expect((await reopened.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first?.lastVerifiedAt == persisted.lastVerifiedAt)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reopened.verifyAssetLocation(first.asset.id)
        }
        await #expect(throws: (any Error).self) { try await cancelled.value }
        #expect((await reopened.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first?.lastVerifiedAt == persisted.lastVerifiedAt)
        try await reopened.close()
    }

    @Test func independentCopyKeepsOriginalCreationAndRecordsItsOwn() async throws {
        let (root, store, source) = try await fixture()
        let first = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let original = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first)
        let folder = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try await store.collectAsset(first.asset.id, to: folder)
        let locations = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations)
        let retained = try #require(locations.first(where: { $0.id == original.id }))
        let copy = try #require(locations.first(where: { $0.role == .independentCopy }))
        #expect(retained.contentCreatedAt == original.contentCreatedAt)
        #expect(retained.registeredAt == original.registeredAt)
        #expect(copy.id != original.id && copy.contentCreatedAt != nil)
        #expect(copy.registeredAt >= original.registeredAt)
        try await store.relocateAsset(first.asset.id, to: try #require(copy.url))
        let sameCopy = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?
            .fileLocations?.locations.first(where: { $0.id == copy.id }))
        #expect(sameCopy.role == .independentCopy)
        #expect(sameCopy.contentCreatedAt == copy.contentCreatedAt)
        #expect(sameCopy.registeredAt == copy.registeredAt)
        try await store.close()
    }

    @Test func movedProjectCopyRelocatesAsExternalAndRemainsReadable() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .copy)
        let original = try Data(contentsOf: source)
        try await store.verifyAssetLocation(imported.asset.id)
        let before = try #require((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?
            .fileLocations?.locations.first)
        let packageFile = store.rootURL.appendingPathComponent(imported.asset.relativePath)
        let moved = root.appendingPathComponent("moved-project-copy.txt")
        try FileManager.default.moveItem(at: packageFile, to: moved)
        try await store.relocateAsset(imported.asset.id, to: moved)
        let relocated = try #require((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?
            .fileLocations?.locations.first)
        #expect(relocated.id == before.id)
        #expect(relocated.role == .externalOriginal)
        #expect(relocated.registeredAt == before.registeredAt)
        if let created = before.contentCreatedAt { #expect(relocated.contentCreatedAt == created) }
        try await store.verifyAssetLocation(imported.asset.id)
        #expect(try await store.workflowData(imported.record.reference) == original)
        let output = root.appendingPathComponent("exported-copy.txt")
        try await store.export(assetID: imported.asset.id, to: output)
        #expect(try Data(contentsOf: output) == original)
        try await store.close()
    }

    @Test func knownUsesNameGraphNodeAndDerivedAsset() async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let child = try await store.publishWorkflowAsset(data: Data("derived".utf8), mediaType: "text/plain",
            name: "派生版本", parents: [imported.record.reference], operationID: "test.derived")
        var node = try #require(WorkflowRegistry.standard.operation("d.asset.reference")).definition.makeNode()
        node.assetReference = imported.record.reference
        let graph = WorkflowGraph(name: "使用素材的流程", nodes: [node])
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: archive.revision)
        let overview = try await store.assetLocationOverview(imported.asset.id)
        #expect(overview.knownUseCount == 2)
        #expect(overview.knownUses.contains { $0.kind == .graph && $0.graphID == graph.id && $0.nodeID == node.id && $0.title == graph.name })
        #expect(overview.knownUses.contains { $0.kind == .derivedAsset && $0.assetID == child.asset.id && $0.title == "派生版本" })
        try await store.close()
    }
}
