import CryptoKit
import Darwin
import Dispatch
import Foundation
import Testing
@testable import DWorkbench

@Suite("Manual project backup file layer")
struct ProjectBackupTests {
    private enum Interrupted: Error { case now }

    @Test func posixFailureReportsOperationAndNeverPublishes() async throws {
        try await fixture { root in
            let blocked = root.appendingPathComponent("blocked")
            let original = Data("keep existing bytes".utf8)
            try original.write(to: blocked)
            let target = blocked.appendingPathComponent("backup")
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 0, files: [])
            do {
                _ = try await ProjectBackup.create(plan, at: target)
                Issue.record("backup unexpectedly succeeded")
            } catch let error as ProjectBackupError {
                guard case .posix(let failure) = error else {
                    Issue.record("expected a structured POSIX failure, got \(error)")
                    return
                }
                #expect(failure.operation == "open directory")
                #expect(failure.code == ENOTDIR)
                #expect(!failure.published)
                #expect(error.localizedDescription.contains("open directory"))
                #expect(error.localizedDescription.contains("POSIX \(ENOTDIR)"))
                #expect(!error.localizedDescription.contains(blocked.path))
            } catch {
                Issue.record("expected ProjectBackupError, got \(error)")
            }
            #expect(try Data(contentsOf: blocked) == original)
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

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

    @Test func backupAndRestoreStageInsideSystemReplacementDirectory() async throws {
        try await fixture { root in
            let data = Data("same volume".utf8)
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 1, files: [
                .init(relativePath: "project.json", sourceURL: nil, data: data,
                      sha256: hash(data), byteCount: UInt64(data.count))
            ])
            let backup = root.appendingPathComponent("backup")
            _ = try await ProjectBackup.create(plan, at: backup, checkpoint: { _ in }, stageCheckpoint: { stage in
                #expect(stage.deletingLastPathComponent() != root)
                #expect(FileManager.default.fileExists(atPath: stage.path))
                var targetInfo = stat(), stageInfo = stat()
                #expect(stat(root.path, &targetInfo) == 0)
                #expect(stat(stage.path, &stageInfo) == 0)
                #expect(targetInfo.st_dev == stageInfo.st_dev)
            })
            let restored = root.appendingPathComponent("restored")
            _ = try await ProjectBackup.restore(at: backup, to: restored, prepare: { _ in },
                                                 publicationCheckpoint: { stage in
                #expect(stage.deletingLastPathComponent() != root)
                #expect(FileManager.default.fileExists(atPath: stage.path))
            })
            #expect(try Data(contentsOf: restored.appendingPathComponent("project.json")) == data)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["backup", "restored"])
        }
    }

    @Test func existingBackupReadFailureDoesNotClaimUnpublishedResult() async throws {
        try await fixture { root in
            let backup = root.appendingPathComponent("backup")
            _ = try await ProjectBackup.create(.init(projectID: UUID(), revision: 0, files: []), at: backup)
            try FileManager.default.removeItem(at: backup.appendingPathComponent("manifest.json"))
            do {
                _ = try await ProjectBackup.verify(at: backup)
                Issue.record("verification unexpectedly succeeded")
            } catch let error as ProjectBackupError {
                guard case .posix(let failure) = error else {
                    Issue.record("expected a structured read failure, got \(error)")
                    return
                }
                #expect(failure.operation == "open package metadata")
                #expect(failure.code == ENOENT)
                #expect(failure.existingBackup)
                #expect(error.localizedDescription.contains("核验未删除所选备份"))
                #expect(!error.localizedDescription.contains("结果未发布"))
            }
            #expect(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    @Test func publishedIdentityFailureExplainsRetainedResult() {
        let error = ProjectBackupError.publishedIntegrity("published directory identity changed")
        #expect(error.localizedDescription.contains("已发布"))
        #expect(error.localizedDescription.contains("未删除结果"))
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
            let (stages, reportStage) = AsyncStream<URL>.makeStream()
            await #expect(throws: ProjectBackupError.self) {
                try await ProjectBackup.create(plan, at: target, checkpoint: { _ in }, stageCheckpoint: { stage in
                    reportStage.yield(stage)
                    try FileManager.default.moveItem(at: stage, to: root.appendingPathComponent("moved"))
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                })
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("moved/complete.sha256").path))
            reportStage.finish()
            var stageIterator = stages.makeAsyncIterator()
            if let partial = await stageIterator.next() {
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
                defer { signalEntered.finish(); resume.signal() }
                try await ProjectBackup.create(plan, at: target, checkpoint: { _ in
                    signalEntered.yield(())
                    guard resume.wait(timeout: .now() + .seconds(5)) == .success else { throw Interrupted.now }
                })
            }
            var iterator = entered.makeAsyncIterator()
            guard await iterator.next() != nil else {
                _ = try await work.value
                Issue.record("copy finished before the cancellation checkpoint")
                return
            }
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
            _ = try await ProjectBackup.restore(at: backup, to: target, prepare: { stageFD in
                #expect(try readStageFile("project.json", in: stageFD) == data)
                try writeStageFile(Data("new instance".utf8), named: "project.json", in: stageFD)
                guard mkdirat(stageFD, "Tasks", 0o700) == 0 else { throw Interrupted.now }
            })
            #expect(try Data(contentsOf: target.appendingPathComponent("project.json")) == Data("new instance".utf8))
            #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Tasks").path))
            #expect(try await ProjectBackup.verify(at: backup).complete)
        }
    }

    @Test func replacedRestoreStageCannotRedirectPreparation() async throws {
        try await fixture { root in
            let original = Data("verified project".utf8)
            let replacement = Data("other project".utf8)
            let prepared = Data("prepared instance".utf8)
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 1, files: [
                .init(relativePath: "project.json", sourceURL: nil, data: original,
                      sha256: hash(original), byteCount: UInt64(original.count))
            ])
            let backup = root.appendingPathComponent("backup")
            _ = try await ProjectBackup.create(plan, at: backup)
            let target = root.appendingPathComponent("restored")
            let retained = root.appendingPathComponent("retained-stage")
            let (stages, reportStage) = AsyncStream<URL>.makeStream()
            await #expect(throws: ProjectBackupError.self) {
                try await ProjectBackup.restore(at: backup, to: target, prepare: { stageFD in
                    #expect(try readStageFile("project.json", in: stageFD) == original)
                    try writeStageFile(prepared, named: "project.json", in: stageFD)
                }, publicationCheckpoint: { stage in
                    reportStage.yield(stage)
                    try FileManager.default.moveItem(at: stage, to: retained)
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                    try replacement.write(to: stage.appendingPathComponent("project.json"))
                })
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try Data(contentsOf: retained.appendingPathComponent("project.json")) == prepared)
            reportStage.finish()
            var stageIterator = stages.makeAsyncIterator()
            guard let replacementStage = await stageIterator.next() else { Issue.record("replacement stage missing"); return }
            #expect(try Data(contentsOf: replacementStage.appendingPathComponent("project.json")) == replacement)
        }
    }

    @Test func failedPublicationKeepsReplacementCompletionMarker() async throws {
        try await fixture { root in
            let data = Data("source".utf8)
            let replacement = Data("unowned marker".utf8)
            let plan = ProjectBackupPlan(projectID: UUID(), revision: 1, files: [
                .init(relativePath: "file", sourceURL: nil, data: data,
                      sha256: hash(data), byteCount: UInt64(data.count))
            ])
            let target = root.appendingPathComponent("backup")
            let (stages, reportStage) = AsyncStream<URL>.makeStream()
            await #expect(throws: Interrupted.self) {
                try await ProjectBackup.create(plan, at: target, checkpoint: { _ in }, markerCheckpoint: { stage in
                    reportStage.yield(stage)
                    try FileManager.default.moveItem(at: stage.appendingPathComponent("complete.sha256"),
                                                     to: stage.appendingPathComponent("original-marker"))
                    try replacement.write(to: stage.appendingPathComponent("complete.sha256"))
                    throw Interrupted.now
                })
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
            reportStage.finish()
            var stageIterator = stages.makeAsyncIterator()
            guard let partial = await stageIterator.next() else { Issue.record("partial backup missing"); return }
            #expect(try Data(contentsOf: partial.appendingPathComponent("complete.sha256")) == replacement)
            await #expect(throws: ProjectBackupError.self) { try await ProjectBackup.verify(at: partial) }
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

    private func readStageFile(_ name: String, in directory: Int32) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Interrupted.now }
        defer { Darwin.close(fd) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 128)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw Interrupted.now }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeStageFile(_ data: Data, named name: String, in directory: Int32) throws {
        let fd = openat(directory, name, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Interrupted.now }
        defer { Darwin.close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0 else { throw Interrupted.now }
    }
}
