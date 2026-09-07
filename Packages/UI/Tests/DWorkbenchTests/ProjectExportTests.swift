import DInference
import Foundation
import Synchronization
import Testing
@testable import DWorkbench

@Suite("Atomic export with a single-file destination grant")
struct ProjectExportTests {
    private enum Interrupted: Error { case atCheckpoint }

    @Test func racingDestinationIsPreservedAndSystemStagingIsCleaned() async throws {
        try await withExport { fixture, store, asset, original in
            let destination = fixture.directory.appendingPathComponent("race.png")
            let competingBytes = Data("The other writer's original".utf8)
            let staging = Mutex<URL?>(nil)
            await #expect(throws: ProjectStoreError.alreadyExists(destination.path)) {
                try await store.export(assetID: asset.id, to: destination, checkpoint: { point in
                    if case .contentDurable(let temporary) = point {
                        #expect(temporary.deletingLastPathComponent() != destination.deletingLastPathComponent())
                        #expect(try Data(contentsOf: temporary) == original)
                        staging.withLock { $0 = temporary }
                        try competingBytes.write(to: destination, options: .withoutOverwriting)
                    }
                })
            }
            #expect(try Data(contentsOf: destination) == competingBytes)
            #expect(try Data(contentsOf: await store.assetURL(for: asset)) == original)
            let temporary = try #require(staging.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
        }
    }

    @Test func actualPublishPermissionFailureDoesNotLeaveAnIncompleteTarget() async throws {
        try await withExport { fixture, store, asset, original in
            let folder = fixture.directory.appendingPathComponent("Output")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            let destination = folder.appendingPathComponent("failed.png")
            let staging = Mutex<URL?>(nil)
            await #expect(throws: ProjectStoreError.self) {
                try await store.export(assetID: asset.id, to: destination, checkpoint: { point in
                    if case .contentDurable(let temporary) = point {
                        staging.withLock { $0 = temporary }
                        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
                    }
                })
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try Data(contentsOf: await store.assetURL(for: asset)) == original)
            let temporary = try #require(staging.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try await store.export(assetID: asset.id, to: destination)
            #expect(try Data(contentsOf: destination) == original)
        }
    }

    @Test(arguments: [false, true])
    func interruptionNeverDeletesPublishedOutput(afterPublication: Bool) async throws {
        try await withExport { fixture, store, asset, original in
            let destination = fixture.directory.appendingPathComponent("interrupted.png")
            let staging = Mutex<URL?>(nil)
            await #expect(throws: Interrupted.self) {
                try await store.export(assetID: asset.id, to: destination, checkpoint: { point in
                    switch point {
                    case .contentDurable(let temporary):
                        staging.withLock { $0 = temporary }
                        if !afterPublication { throw Interrupted.atCheckpoint }
                    case .published:
                        if afterPublication { throw Interrupted.atCheckpoint }
                    }
                })
            }
            if afterPublication { #expect(try Data(contentsOf: destination) == original) }
            else { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
            #expect(try Data(contentsOf: await store.assetURL(for: asset)) == original)
            let temporary = try #require(staging.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
        }
    }

    @Test func exportNeverFollowsDestinationOrAncestorSymlinks() async throws {
        try await withExport { fixture, store, asset, _ in
            let original = fixture.directory.appendingPathComponent("outside.txt")
            let bytes = Data("Keep original bytes".utf8)
            try bytes.write(to: original)
            let alias = fixture.directory.appendingPathComponent("alias.png")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
            await #expect(throws: ProjectStoreError.self) { try await store.export(assetID: asset.id, to: alias) }
            #expect(try Data(contentsOf: original) == bytes)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == original.path)
            let directoryAlias = fixture.directory.appendingPathComponent("directory-alias")
            try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: fixture.directory)
            await #expect(throws: ProjectStoreError.self) {
                try await store.export(assetID: asset.id, to: directoryAlias.appendingPathComponent("escaped.png"))
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("escaped.png").path))
        }
    }

    private func withExport(_ body: @Sendable (ProjectFixture, ProjectStore, ProjectAsset, Data) async throws -> Void) async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "导出验证")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let image = try fixture.publishPNG(jobID: request.id)
            let manifest = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            let asset = try #require(manifest.assets.first)
            try await body(fixture, store, asset, Data(contentsOf: image))
            #expect(await store.snapshot() == manifest)
            try await store.close()
        }
    }
}
