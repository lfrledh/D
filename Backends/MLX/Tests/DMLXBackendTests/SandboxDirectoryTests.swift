import CryptoKit
import Darwin
import DInference
@testable import DMLXBackend
import Foundation
import Testing

/// POSIX search-only parents exercise the production descriptor walk. A separate
/// Seatbelt control and the signed app verify the App Sandbox permission boundary.
@Suite("Image roots below search-only ancestors", .enabled(if: geteuid() != 0))
struct SandboxDirectoryTests {
    @Test("Publishing does not require enumerating ancestors of the selected artifact root")
    func publishBelowNonListableParent() throws {
        let fixture = try SearchOnlyDirectoryFixture()
        defer { fixture.remove() }
        try fixture.restrictAncestor()
        try ImageArtifactTransaction.validateRoot(fixture.artifacts)
        let transaction = try ImageArtifactTransaction(root: fixture.artifacts, requestID: UUID())
        let png = try ImagePNG.encode(rgb: [255, 0, 0], width: 1, height: 1)
        let artifact = try transaction.publish(png, width: 1, height: 1)
        try transaction.cleanupUnpublished()
        #expect(try Data(contentsOf: artifact.url) == png)
    }

    @Test("Complete inventory verification needs read access to the model, not its ancestors")
    func inventoryBelowNonListableParent() throws {
        let fixture = try SearchOnlyDirectoryFixture()
        defer { fixture.remove() }
        let template = try LocalImageModelInventory.Manifest.bundled()
        let files = try template.files.map { file in
            let bytes = Data("Offline search-only ancestor fixture: \(file.path)\n".utf8)
            let target = fixture.model.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
            return LocalImageModelInventory.Manifest.File(path: file.path, size: UInt64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
        let manifest = LocalImageModelInventory.Manifest(schemaVersion: template.schemaVersion,
            repository: template.repository, revision: template.revision, files: files)
        try fixture.restrictAncestor()
        let request = InferenceRequest(model: .init(directory: fixture.model), input: .image(
            .init(prompt: "A red teapot", width: 512, height: 512, steps: 4, guidanceScale: 1, seed: 0)))
        let inventory = try LocalImageModelInventory.inspect(request, manifest: manifest)
        try inventory.verifyContents()
        #expect(inventory.directory == fixture.model)
    }

    @Test("The final artifact root still requires read permission")
    func unreadableSelectedRootIsRejected() throws {
        let fixture = try SearchOnlyDirectoryFixture()
        defer { fixture.remove() }
        #expect(chmod(fixture.artifacts.path, 0o100) == 0)
        defer { _ = chmod(fixture.artifacts.path, 0o700) }
        #expect(throws: InferenceFailure.self) { try ImageArtifactTransaction.validateRoot(fixture.artifacts) }
    }

    @Test("Search-only traversal still rejects an ancestor symlink")
    func artifactAncestorSymlinkIsRejected() throws {
        let fixture = try SearchOnlyDirectoryFixture()
        defer { fixture.remove() }
        let alias = fixture.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.ancestor)
        let redirected = alias.appendingPathComponent("artifacts")
        #expect(throws: InferenceFailure.self) { try ImageArtifactTransaction.validateRoot(redirected) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.artifacts.path).isEmpty)
    }
}

private struct SearchOnlyDirectoryFixture {
    let base: URL
    let ancestor: URL
    let artifacts: URL
    let model: URL

    init() throws {
        let parent = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        base = parent.resolvingSymlinksInPath().appendingPathComponent("D-search-only-\(UUID().uuidString)")
        ancestor = base.appendingPathComponent("ancestor")
        artifacts = ancestor.appendingPathComponent("artifacts")
        model = ancestor.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
    }

    func restrictAncestor() throws {
        try #require(chmod(ancestor.path, 0o100) == 0)
        let readable = Darwin.open(ancestor.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if readable >= 0 { Darwin.close(readable) }
        try #require(readable < 0, "The regression requires a parent that cannot be enumerated.")
    }

    func remove() {
        _ = chmod(ancestor.path, 0o700)
        try? FileManager.default.removeItem(at: base)
    }
}
