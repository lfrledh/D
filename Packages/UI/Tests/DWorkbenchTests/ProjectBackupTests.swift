import CryptoKit
import Dispatch
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

    @Test func replacedStageAndLateDestinationCollisionNeverPublishReplacement() async throws {
        try await fixture { root in
            let data = Data("original".utf8)
            let source = root.appendingPathComponent("source")
            try data.write(to: source)
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 1, files: [
                .init(relativePath: "file", sourceURL: source, data: nil, sha256: hash(data), byteCount: UInt64(data.count))
            ])
            let target = root.appendingPathComponent("backup")
            await #expect(throws: ProjectBackupError.self) {
                try await ProjectBackup.create(plan, at: target, checkpoint: { _ in
                    let stage = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                        .first { $0.lastPathComponent.hasPrefix(".d-backup-") && $0.lastPathComponent.hasSuffix(".partial") }
                    guard let stage else { throw Interrupted.now }
                    try FileManager.default.moveItem(at: stage, to: root.appendingPathComponent("moved"))
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                })
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("moved/complete.sha256").path))
            let partial = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".d-backup-") && $0.lastPathComponent.hasSuffix(".partial") }
            if let partial {
                await #expect(throws: ProjectBackupError.self) { try await ProjectBackup.verify(at: partial) }
                await #expect(throws: ProjectBackupError.self) {
                    try await ProjectBackup.restore(at: partial, to: root.appendingPathComponent("refused"))
                }
            } else { Issue.record("replacement staging directory missing") }

            await #expect(throws: ProjectBackupError.self) {
                try await ProjectBackup.create(plan, at: target, checkpoint: { _ in
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                })
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    @Test func cancellationForwardsToDetachedCopy() async throws {
        try await fixture { root in
            let data = Data("cancel me".utf8)
            let source = root.appendingPathComponent("source")
            try data.write(to: source)
            let target = root.appendingPathComponent("backup")
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 1, files: [
                .init(relativePath: "file", sourceURL: source, data: nil, sha256: hash(data), byteCount: UInt64(data.count))
            ])
            let (entered, signalEntered) = AsyncStream<Void>.makeStream()
            let resume = DispatchSemaphore(value: 0)
            let work = Task {
                try await ProjectBackup.create(plan, at: target, checkpoint: { _ in
                    signalEntered.yield(())
                    resume.wait()
                })
            }
            var iterator = entered.makeAsyncIterator()
            _ = await iterator.next()
            work.cancel()
            resume.signal()
            await #expect(throws: CancellationError.self) { try await work.value }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func restorePreparationGetsVerifiedStageBeforeExclusivePublication() async throws {
        try await fixture { root in
            let data = Data("logical project bytes".utf8)
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 1, files: [
                .init(relativePath: "project.json", sourceURL: nil, data: data, sha256: hash(data), byteCount: UInt64(data.count))
            ])
            let backup = root.appendingPathComponent("backup")
            _ = try await ProjectBackup.create(plan, at: backup)
            let target = root.appendingPathComponent("restored")
            _ = try await ProjectBackup.restore(at: backup, to: target, prepare: { stage in
                #expect(try Data(contentsOf: stage.appendingPathComponent("project.json")) == data)
                try Data("new instance".utf8).write(to: stage.appendingPathComponent("project.json"))
                try FileManager.default.createDirectory(at: stage.appendingPathComponent("Tasks"), withIntermediateDirectories: false)
            })
            #expect(try Data(contentsOf: target.appendingPathComponent("project.json")) == Data("new instance".utf8))
            #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Tasks").path))
            #expect(try await ProjectBackup.verify(at: backup).complete)
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
