import CryptoKit
import Foundation
import Testing
@testable import DWorkbench

@Suite("Manual project backup file layer")
struct ProjectBackupTests {
    private enum Interrupted: Error { case now }

    @Test func completeBackupVerifiesAndRestoresIndependentBytes() async throws {
        try await fixture { root in
            let source = root.appendingPathComponent("source.bin")
            let media = Data("project media".utf8)
            try media.write(to: source)
            let inline = Data("project manifest".utf8)
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 4, files: [
                .init(relativePath: "project.json", sourceURL: nil, data: inline, sha256: hash(inline), byteCount: UInt64(inline.count)),
                .init(relativePath: "Media/source.bin", sourceURL: source, data: nil, sha256: hash(media), byteCount: UInt64(media.count))
            ], modelDependencies: [.init(catalogID: "test-model", revision: "fixed", files: [
                ModelFile(path: "weights.bin", size: 8, sha256: String(repeating: "a", count: 64),
                          sourceRepository: "private/repo", remotePath: "/secret/location")
            ])])
            let backup = root.appendingPathComponent("backup.dbackup")
            let receipt = try await ProjectBackup.create(plan, at: backup)
            #expect(receipt.complete && receipt.fileCount == 2 && receipt.byteCount == UInt64(inline.count + media.count))
            #expect(try await ProjectBackup.verify(at: backup).complete)
            let manifest = try String(contentsOf: backup.appendingPathComponent("manifest.json"), encoding: .utf8)
            #expect(!manifest.contains(source.path))
            #expect(!manifest.contains("private/repo"))
            #expect(!manifest.contains("/secret/location"))
            try FileManager.default.removeItem(at: source)
            let restored = root.appendingPathComponent("restored")
            let result = try await ProjectBackup.restore(at: backup, to: restored)
            #expect(result.directory == restored && result.complete)
            #expect(try Data(contentsOf: restored.appendingPathComponent("Media/source.bin")) == media)
            #expect(try Data(contentsOf: restored.appendingPathComponent("project.json")) == inline)
        }
    }

    @Test func noOverwriteAndCorruptionAreRejected() async throws {
        try await fixture { root in
            let data = Data("same".utf8)
            let source = root.appendingPathComponent("source")
            try data.write(to: source)
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 0, files: [
                .init(relativePath: "media", sourceURL: source, data: nil, sha256: hash(data), byteCount: UInt64(data.count))
            ])
            let backup = root.appendingPathComponent("backup")
            _ = try await ProjectBackup.create(plan, at: backup)
            await #expect(throws: ProjectBackupError.self) { try await ProjectBackup.create(plan, at: backup) }
            #expect(try Data(contentsOf: source) == data)
            #expect(try Data(contentsOf: backup.appendingPathComponent("media")) == data)
            try Data("bad!".utf8).write(to: backup.appendingPathComponent("media"))
            await #expect(throws: ProjectBackupError.self) { try await ProjectBackup.verify(at: backup) }
            await #expect(throws: ProjectBackupError.self) { try await ProjectBackup.restore(at: backup, to: root.appendingPathComponent("restore")) }
        }
    }

    @Test func unsafePathsLinksAndIncompletePolicy() async throws {
        try await fixture { root in
            let data = Data("x".utf8)
            let source = root.appendingPathComponent("source")
            try data.write(to: source)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
            for path in ["../escape", "/absolute", "a/./b", "a\\b", "manifest.json"] {
                let plan = ProjectBackupPlan(projectID: UUID(), revision: 0, files: [
                    .init(relativePath: path, sourceURL: source, data: nil, sha256: hash(data), byteCount: 1)
                ])
                await #expect(throws: ProjectBackupError.self) { try await ProjectBackup.create(plan, at: root.appendingPathComponent(UUID().uuidString)) }
            }
            let linked = ProjectBackupPlan(projectID: UUID(), revision: 0, files: [
                .init(relativePath: "file", sourceURL: alias, data: nil, sha256: hash(data), byteCount: 1)
            ])
            await #expect(throws: ProjectBackupError.self) { try await ProjectBackup.create(linked, at: root.appendingPathComponent("linked")) }
            let incomplete = ProjectBackupPlan(projectID: UUID(), revision: 0, files: [], missing: ["Media/lost.png"])
            await #expect(throws: ProjectBackupError.self) { try await ProjectBackup.create(incomplete, at: root.appendingPathComponent("refused")) }
            let backup = root.appendingPathComponent("incomplete")
            #expect(try await !ProjectBackup.create(incomplete, at: backup, allowIncomplete: true).complete)
            await #expect(throws: ProjectBackupError.self) { try await ProjectBackup.restore(at: backup, to: root.appendingPathComponent("default")) }
            #expect(try await !ProjectBackup.restore(at: backup, to: root.appendingPathComponent("explicit"), allowIncomplete: true).complete)
        }
    }

    @Test func interruptionAndSourceMutationNeverPublishComplete() async throws {
        try await fixture { root in
            let source = root.appendingPathComponent("source")
            let data = Data("original".utf8)
            try data.write(to: source)
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 1, files: [
                .init(relativePath: "file", sourceURL: source, data: nil, sha256: hash(data), byteCount: UInt64(data.count))
            ])
            await #expect(throws: Interrupted.self) {
                try await ProjectBackup.create(plan, at: root.appendingPathComponent("interrupted"), checkpoint: { _ in throw Interrupted.now })
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupted").path))
            await #expect(throws: ProjectBackupError.self) {
                try await ProjectBackup.create(plan, at: root.appendingPathComponent("changed"), checkpoint: { _ in
                    try Data("modified".utf8).write(to: source)
                })
            }
            #expect(try Data(contentsOf: source) == Data("modified".utf8))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("changed").path))
        }
    }

    private func fixture(_ body: @Sendable (URL) async throws -> Void) async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)
        let root = base.appendingPathComponent("ProjectBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
