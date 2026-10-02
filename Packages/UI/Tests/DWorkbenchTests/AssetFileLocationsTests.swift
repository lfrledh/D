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
}
