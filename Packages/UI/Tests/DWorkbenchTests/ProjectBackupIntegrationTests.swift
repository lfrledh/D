import Foundation
import Testing
@testable import DWorkbench

@Suite("Project backup snapshot and independent restore", .serialized)
struct ProjectBackupIntegrationTests {
    @Test func restoreWithoutOriginalPreservesWorkflowAndSeparatesInstance() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("BackupIntegration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("melody.txt")
        let content = Data("哼唱记录 e\u{301} 🎵".utf8); try content.write(to: source)
        let store = try await ProjectStore.create(at: base.appendingPathComponent("original.dproject"), name: "原项目")
        let asset = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let before = await store.snapshot()
        let archive = try await store.workflowState().archive
        let plan = try await store.backupPlan()
        #expect(plan.missing.isEmpty)
        let backup = base.appendingPathComponent("backup.dbackup")
        _ = try await ProjectBackup.create(plan, at: backup)
        let backupManifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: backup.appendingPathComponent("project.json")))
        #expect(backupManifest.assets.allSatisfy { $0.fileLocations == nil })
        #expect(!plan.files.contains { $0.relativePath.hasPrefix("AssetInputs/") || $0.relativePath.hasPrefix(".lock") })
        try await store.close()
        try FileManager.default.moveItem(at: store.rootURL, to: base.appendingPathComponent("moved-original.dproject"))
        try FileManager.default.removeItem(at: source)
        let destination = base.appendingPathComponent("restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: destination)
        let restored = try await ProjectStore.open(at: destination)
        let after = await restored.snapshot()
        #expect(after.id == before.id && after.effectiveInstanceID != before.effectiveInstanceID)
        #expect(try await restored.workflowData(asset.record.reference) == content)
        #expect(try await restored.workflowState().archive == archive)
        #expect(after.assets.map(\.id) == before.assets.map(\.id))
        await #expect(throws: (any Error).self) { try await ProjectStore.restoreBackup(at: backup, to: destination) }
        #expect(try await restored.workflowData(asset.record.reference) == content)
        try await restored.close()
    }

    @Test func missingOriginalIsAnExplicitIncompleteBackup() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("IncompleteBackup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("source.txt"); try Data("fixed".utf8).write(to: source)
        let store = try await ProjectStore.create(at: base.appendingPathComponent("original.dproject"), name: "不完整")
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        try FileManager.default.removeItem(at: source)
        let plan = try await store.backupPlan()
        #expect(plan.missing == [imported.asset.relativePath])
        let backup = base.appendingPathComponent("incomplete")
        await #expect(throws: (any Error).self) { try await ProjectBackup.create(plan, at: backup) }
        #expect(try await !ProjectBackup.create(plan, at: backup, allowIncomplete: true).complete)
        await #expect(throws: (any Error).self) { try await ProjectStore.restoreBackup(at: backup, to: base.appendingPathComponent("restore.dproject")) }
        #expect(await store.snapshot().assets.contains { $0.id == imported.asset.id })
        try await store.close()
    }
}
