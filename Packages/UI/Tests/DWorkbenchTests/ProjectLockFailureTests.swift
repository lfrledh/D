import Darwin
import Foundation
import Synchronization
import Testing
@testable import DWorkbench

@Suite("Project lock failure ownership")
struct ProjectLockFailureTests {
    private enum Interrupted: Error { case migration }

    @Test(arguments: [6, 8])
    func interruptedMigrationReleasesLockWhileDuplicateExists(version: Int) async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "旧作品 👩‍💻")
            try await store.close()
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json["schemaVersion"] = version
            var documents = try #require(json["documents"] as? [[String: Any]])
            for index in documents.indices {
                documents[index].removeValue(forKey: "textSources")
                if version == 6, var draft = documents[index]["draft"] as? [String: Any] {
                    draft.removeValue(forKey: "imageSettings"); documents[index]["draft"] = draft
                }
            }
            json["documents"] = documents
            let raw = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try raw.write(to: file)
            let duplicate = Mutex<Int32>(-1)
            defer { duplicate.withLock { if $0 >= 0 { Darwin.close($0); $0 = -1 } } }
            await #expect(throws: Interrupted.self) {
                _ = try await ProjectStore.open(at: fixture.project, migrationCheckpoint: { point in
                    if point == .backupDurable {
                        let descriptor = try Self.duplicateOwnedLock(at: fixture.project)
                        duplicate.withLock { $0 = descriptor }
                        throw Interrupted.migration
                    }
                })
            }
            #expect(duplicate.withLock { $0 >= 0 })
            #expect(try Data(contentsOf: file) == raw)
            let backup = version == 6 ? ProjectStore.versionSixBackupFilename : ProjectStore.versionEightBackupFilename
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(backup)) == raw)
            // The descriptor copy is still alive: the failed opener must release its lock,
            // not wait for every pre-exec copy of that file description to disappear.
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().schemaVersion == ProjectManifest.currentSchemaVersion)
            try await reopened.close()
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(backup)) == raw)
        }
    }

    @Test func failedAcquisitionDoesNotUnlockAnotherSession() async throws {
        try await withFixture { fixture in
            let owner = try await ProjectStore.create(at: fixture.project, name: "已打开作品")
            let raw = try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.manifestFilename))
            for _ in 0..<2 {
                await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: fixture.project) }
            }
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.manifestFilename)) == raw)
            try await owner.close()
            let next = try await ProjectStore.open(at: fixture.project)
            try await next.close()
        }
    }

    /// Inspect only descriptor metadata matching this test's own lock inode, never contents.
    private static func duplicateOwnedLock(at project: URL) throws -> Int32 {
        var target = stat()
        guard lstat(project.appendingPathComponent(".project.lock").path, &target) == 0 else {
            throw ProjectStoreError.io("Test could not stat its lock")
        }
        for descriptor in 0..<getdtablesize() {
            var info = stat()
            if fstat(descriptor, &info) == 0, info.st_dev == target.st_dev, info.st_ino == target.st_ino {
                let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                guard duplicate >= 0 else { throw ProjectStoreError.io("Test could not duplicate its lock") }
                return duplicate
            }
        }
        throw ProjectStoreError.io("Test did not find its owned lock descriptor")
    }
}
