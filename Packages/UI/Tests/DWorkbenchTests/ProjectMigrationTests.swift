import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Durable v1 to v2 project migration")
struct ProjectMigrationTests {
    private enum Interrupted: Error { case afterBoundary }

    @Test(arguments: ["0", "-"])
    func migrationPreservesOriginalBytesIDsConditionsAndMedia(seedText: String) async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "旧项目")
            let draft = ProjectDraft(prompt: "Unfinished\n创作条件", randomSeed: false, seedText: seedText)
            _ = try await store.saveDraft(draft)
            let request = fixture.request(seed: 0)
            _ = try await store.enqueue(request: request)
            let image = try fixture.publishPNG(jobID: request.id)
            let before = try await store.complete(id: request.id, result: .init(
                artifacts: [.init(url: image, mediaType: "image/png")], metadata: ["model.revision": "exact fixture revision"]))
            try await store.close()
            let imageBytes = try Data(contentsOf: image)
            let original = try legacyBytes(before)
            let manifestURL = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            try original.write(to: manifestURL)
            let migrated = try await ProjectStore.open(at: fixture.project)
            let after = await migrated.snapshot()
            #expect(after.schemaVersion == ProjectManifest.currentSchemaVersion)
            #expect(after.id == before.id)
            #expect(after.name == before.name)
            #expect(after.createdAt == before.createdAt)
            #expect(after.revision == before.revision + 1)
            #expect(after.documents.count == 1)
            #expect(after.activeDocumentID == before.id)
            #expect(after.draft == draft)
            #expect(after.activeDocument?.sourceAssetID == nil)
            #expect(after.activeDocument?.adoptedAssetID == nil)
            #expect(after.jobs[0].id == before.jobs[0].id)
            #expect(after.jobs[0].documentID == before.id)
            #expect(after.jobs[0].request == before.jobs[0].request)
            #expect(after.jobs[0].state == .completed)
            #expect(after.jobs[0].resultMetadata == before.jobs[0].resultMetadata)
            #expect(after.assets[0].id == before.assets[0].id)
            #expect(after.assets[0].relativePath == before.assets[0].relativePath)
            #expect(after.assets[0].metadata == before.assets[0].metadata)
            #expect(!after.assets[0].isFavorite)
            #expect(after.assets[0].note.isEmpty)
            #expect(try Data(contentsOf: image) == imageBytes)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionOneBackupFilename)) == original)
            let migratedBytes = try Data(contentsOf: manifestURL)
            try await migrated.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot() == after)
            #expect(try Data(contentsOf: manifestURL) == migratedBytes)
            #expect(try Data(contentsOf: image) == imageBytes)
            try await reopened.close()
        }
    }

    @Test func interruptionAfterDurableBackupRetriesWithStableDocumentIdentity() async throws {
        try await withFixture { fixture in
            let (original, identity) = try await prepareLegacy(fixture)
            await #expect(throws: Interrupted.self) {
                try await ProjectStore.open(at: fixture.project, migrationCheckpoint: { point in
                    if point == .backupDurable { throw Interrupted.afterBoundary }
                })
            }
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.manifestFilename)) == original)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionOneBackupFilename)) == original)
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().activeDocumentID == identity)
            #expect(await reopened.snapshot().documents.count == 1)
            try await reopened.close()
        }
    }

    @Test func actualPublicationWriteFailureAfterBackupLeavesVersionOneRecoverable() async throws {
        try await withFixture { fixture in
            let (original, _) = try await prepareLegacy(fixture)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path) }
            await #expect(throws: ProjectStoreError.self) {
                try await ProjectStore.open(at: fixture.project, migrationCheckpoint: { point in
                    if point == .beforePublication {
                        // Fault occurs after the real backup + fsync. The actual v2 temporary
                        // file creation fails in production publication code with EACCES.
                        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.project.path)
                    }
                })
            }
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.manifestFilename)) == original)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionOneBackupFilename)) == original)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path)
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().schemaVersion == ProjectManifest.currentSchemaVersion)
            try await reopened.close()
        }
    }

    @Test func interruptionAfterPublicationReopensVersionTwoWithoutMigratingAgain() async throws {
        try await withFixture { fixture in
            let (original, identity) = try await prepareLegacy(fixture)
            await #expect(throws: Interrupted.self) {
                try await ProjectStore.open(at: fixture.project, migrationCheckpoint: { point in
                    if point == .publicationDurable { throw Interrupted.afterBoundary }
                })
            }
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            let published = try Data(contentsOf: file)
            #expect(published != original)
            #expect(try JSONDecoder().decode(ProjectManifest.self, from: published).activeDocumentID == identity)
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().revision == 1)
            #expect(try Data(contentsOf: file) == published)
            try await reopened.close()
        }
    }

    @Test(arguments: ["different-content", "symlink", "directory"])
    func preexistingBackupIsNeverOverwrittenOrFollowed(kind: String) async throws {
        try await withFixture { fixture in
            let (original, _) = try await prepareLegacy(fixture)
            let backup = fixture.project.appendingPathComponent(ProjectStore.versionOneBackupFilename)
            let outside = fixture.directory.appendingPathComponent("outside-original")
            let outsideBytes = Data("Keep this user's file".utf8)
            try outsideBytes.write(to: outside)
            switch kind {
            case "different-content": try outsideBytes.write(to: backup)
            case "symlink": try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: outside)
            default: try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
            }
            await #expect(throws: ProjectStoreError.self) { try await ProjectStore.open(at: fixture.project) }
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.manifestFilename)) == original)
            #expect(try Data(contentsOf: outside) == outsideBytes)
            if kind == "different-content" { #expect(try Data(contentsOf: backup) == outsideBytes) }
            if kind == "symlink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: backup.path) == outside.path) }
            if kind == "directory" { #expect(try backup.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true) }
        }
    }

    @Test func backupWriteFailureLeavesSoleLegacyManifestUnchanged() async throws {
        try await withFixture { fixture in
            let (original, _) = try await prepareLegacy(fixture)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.project.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path) }
            await #expect(throws: ProjectStoreError.self) { try await ProjectStore.open(at: fixture.project) }
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.manifestFilename)) == original)
            #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(ProjectStore.versionOneBackupFilename).path))
        }
    }

    @Test func externalModificationAfterBackupStopsPublicationAndPreservesBothVersions() async throws {
        try await withFixture { fixture in
            let (original, _) = try await prepareLegacy(fixture)
            var contents = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            contents["name"] = "An external editor's change"
            let changed = try JSONSerialization.data(withJSONObject: contents)
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            await #expect(throws: ProjectStoreError.externalModification) {
                try await ProjectStore.open(at: fixture.project, migrationCheckpoint: { point in
                    if point == .backupDurable { try changed.write(to: file, options: .atomic) }
                })
            }
            #expect(try Data(contentsOf: file) == changed)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionOneBackupFilename)) == original)
            // Retrying cannot silently replace an older immutable backup with this edit.
            await #expect(throws: ProjectStoreError.self) { try await ProjectStore.open(at: fixture.project) }
            #expect(try Data(contentsOf: file) == changed)
        }
    }

    @Test func invalidLegacyReferencesAreRejectedBeforeWritingBackup() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "损坏的旧任务")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            var invalid = await store.snapshot()
            invalid.jobs[0].artifactIDs = [UUID()]
            try await store.close()
            let original = try legacyBytes(invalid)
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            try original.write(to: file)
            await #expect(throws: ProjectStoreError.self) { try await ProjectStore.open(at: fixture.project) }
            #expect(try Data(contentsOf: file) == original)
            #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(ProjectStore.versionOneBackupFilename).path))
        }
    }

    private func prepareLegacy(_ fixture: ProjectFixture) async throws -> (Data, UUID) {
        let store = try await ProjectStore.create(at: fixture.project, name: "迁移边界")
        let manifest = await store.snapshot()
        try await store.close()
        let data = try legacyBytes(manifest)
        try data.write(to: fixture.project.appendingPathComponent(ProjectStore.manifestFilename))
        return (data, manifest.id)
    }

    private func legacyBytes(_ manifest: ProjectManifest) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        json["schemaVersion"] = 1
        json["draft"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest.draft))
        json.removeValue(forKey: "documents")
        json.removeValue(forKey: "activeDocumentID")
        var jobs = try #require(json["jobs"] as? [[String: Any]])
        for index in jobs.indices { jobs[index].removeValue(forKey: "documentID") }
        json["jobs"] = jobs
        var assets = try #require(json["assets"] as? [[String: Any]])
        for index in assets.indices {
            for key in ["name", "isFavorite", "note"] { assets[index].removeValue(forKey: key) }
        }
        json["assets"] = assets
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}
