import CryptoKit
import Darwin
import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Pinned image model admission (offline, no MLX allocation)")
struct LocalImageModelInventoryTests {
    struct Dimensions: Sendable {
        let width: Int
        let height: Int
    }

    @Test("Production resource pins all 18 files and four weight shards")
    func bundledManifest() throws {
        let manifest = try LocalImageModelInventory.Manifest.bundled()
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.repository == "mzbac/FLUX.2-klein-4B-q8")
        #expect(manifest.revision == "ef52ee019fd1d0e75ae4deb40476ba65989716d7")
        #expect(manifest.files.count == 18)
        #expect(manifest.files.filter { $0.path.hasSuffix(".safetensors") }.count == 4)
        #expect(manifest.files.reduce(UInt64(0)) { $0 + $1.size } == 9_426_536_934)
    }

    @Test("Complete local fixtures verify repeatedly with any UInt64 seed", arguments: [UInt64(0), 42, UInt64.max])
    func validInstallation(seed: UInt64) throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let inventory = try LocalImageModelInventory.inspect(fixture.request(seed: seed), manifest: fixture.manifest)
        #expect(inventory.directory == fixture.directory)
        #expect(inventory.estimatedPeakBytes == 8 * 1024 * 1024 * 1024)
        #expect(inventory.weightBytes == fixture.manifest.files.filter { $0.path.hasSuffix(".safetensors") }
            .reduce(UInt64(0)) { $0 + $1.size })
        try inventory.verifyContents()
        try inventory.verifyContents()
    }

    @Test("The scalable profile preserves pinned installation admission", arguments: [
        Dimensions(width: 512, height: 256), Dimensions(width: 768, height: 512),
        Dimensions(width: 1024, height: 1024), Dimensions(width: 2048, height: 2048),
    ])
    func scalableInstallation(dimensions: Dimensions) throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let inventory = try LocalImageModelInventory.inspect(
            fixture.request(width: dimensions.width, height: dimensions.height), manifest: fixture.manifest,
            profile: .scalableKlein4B)
        #expect(inventory.directory == fixture.directory)
        #expect(inventory.estimatedPeakBytes >= 8 * 1024 * 1024 * 1024)
        try inventory.verifyContents()
    }

    @Test("Absent provenance label is accepted only alongside verified contents")
    func revisionIsNotProof() throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let inventory = try LocalImageModelInventory.inspect(fixture.request(revision: nil), manifest: fixture.manifest)
        try inventory.verifyContents()
        let wrong = fixture.request(revision: "0000000000000000000000000000000000000000")
        expectInvalidImageRequest(containing: "revision") {
            _ = try LocalImageModelInventory.inspect(wrong, manifest: fixture.manifest)
        }
    }

    @Test("Unsupported image settings and empty/oversized UTF-8 prompts fail admission", arguments: [
        "width", "height", "steps", "guidance", "nonfinite", "empty", "whitespace", "utf8Limit",
    ])
    func unsupportedRequest(setting: String) throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let prompt: String
        switch setting {
        case "empty": prompt = ""
        case "whitespace": prompt = " \t\n"
        case "utf8Limit": prompt = String(repeating: "🙂", count: 262_145)
        default: prompt = "A red teapot."
        }
        let image = ImageRequest(prompt: prompt, width: setting == "width" ? 256 : 512,
                                 height: setting == "height" ? 768 : 512,
                                 steps: setting == "steps" ? 5 : 4,
                                 guidanceScale: setting == "nonfinite" ? .nan : (setting == "guidance" ? 2 : 1),
                                 seed: 42)
        let request = InferenceRequest(model: .init(directory: fixture.directory), input: .image(image))
        expectInvalidImageRequest {
            _ = try LocalImageModelInventory.inspect(request, manifest: fixture.manifest)
        }
    }

    @Test("Text capability is rejected by the image inventory")
    func unsupportedCapability() throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let request = InferenceRequest(model: .init(directory: fixture.directory), input: .text(.init(prompt: "Hello")))
        #expect(throws: InferenceFailure.unsupportedCapability(.textGeneration)) {
            _ = try LocalImageModelInventory.inspect(request, manifest: fixture.manifest)
        }
    }

    @Test("Remote and missing directories are rejected", arguments: [false, true])
    func invalidDirectory(remote: Bool) throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let directory = remote ? URL(string: "https://example.invalid/model")!
            : fixture.base.appendingPathComponent("missing")
        expectInvalidImageRequest {
            _ = try LocalImageModelInventory.inspect(fixture.request(directory: directory), manifest: fixture.manifest)
        }
    }

    @Test("Required files must have exact regular-file type and size", arguments: ["missing", "empty", "larger", "directory", "fifo"])
    func requiredFiles(kind: String) throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let path = fixture.directory.appendingPathComponent(ImageInventoryFixture.weightPath)
        try FileManager.default.removeItem(at: path)
        switch kind {
        case "empty": try Data().write(to: path)
        case "larger": try Data(repeating: 0, count: 4096).write(to: path)
        case "directory": try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        case "fifo": #expect(Darwin.mkfifo(path.path, 0o600) == 0)
        default: break
        }
        expectInvalidImageRequest {
            _ = try LocalImageModelInventory.inspect(fixture.request(), manifest: fixture.manifest)
        }
    }

    @Test("Same-size metadata corruption fails before model loading")
    func corruptMetadata() throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let name = "tokenizer/tokenizer.json"
        try Data(repeating: 0x7f, count: try #require(fixture.contents[name]).count)
            .write(to: fixture.directory.appendingPathComponent(name))
        expectInvalidImageRequest(containing: "SHA-256 mismatch") {
            _ = try LocalImageModelInventory.inspect(fixture.request(), manifest: fixture.manifest)
        }
    }

    @Test("Admission does not hash weights; full verification detects same-size corruption")
    func weightVerificationIsSeparate() throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let name = ImageInventoryFixture.weightPath
        try Data(repeating: 0x7f, count: try #require(fixture.contents[name]).count)
            .write(to: fixture.directory.appendingPathComponent(name))
        let inventory = try LocalImageModelInventory.inspect(fixture.request(), manifest: fixture.manifest)
        expectInvalidImageRequest(containing: "SHA-256 mismatch") { try inventory.verifyContents() }
    }

    @Test("Extra loadable files, hidden files, directories and download state are rejected", arguments: [
        "scheduler/config.json", "transformer/extra.safetensors", ".DS_Store", "unused/", ".d-model-download/",
    ])
    func unlistedEntries(name: String) throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let url = fixture.directory.appendingPathComponent(name)
        if name.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            try Data("unlisted".utf8).write(to: url)
        }
        expectInvalidImageRequest(containing: "Unlisted") {
            _ = try LocalImageModelInventory.inspect(fixture.request(), manifest: fixture.manifest)
        }
    }

    @Test("Symbolic links in files, subdirectories, root or ancestors are rejected", arguments: ["file", "directory", "root", "ancestor"])
    func symbolicLinks(kind: String) throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        var requestDirectory = fixture.directory
        switch kind {
        case "file":
            let file = fixture.directory.appendingPathComponent("tokenizer/tokenizer.json")
            try manager.removeItem(at: file)
            try manager.createSymbolicLink(at: file, withDestinationURL: fixture.directory.appendingPathComponent("tokenizer/vocab.json"))
        case "directory":
            let source = fixture.directory.appendingPathComponent("tokenizer")
            let target = fixture.base.appendingPathComponent("original-tokenizer")
            try manager.moveItem(at: source, to: target)
            try manager.createSymbolicLink(at: source, withDestinationURL: target)
        case "root":
            requestDirectory = fixture.base.appendingPathComponent("linked-model")
            try manager.createSymbolicLink(at: requestDirectory, withDestinationURL: fixture.directory)
        default:
            let ancestor = fixture.base.appendingPathComponent("linked-parent")
            try manager.createSymbolicLink(at: ancestor, withDestinationURL: fixture.base)
            requestDirectory = ancestor.appendingPathComponent("model")
        }
        expectInvalidImageRequest {
            _ = try LocalImageModelInventory.inspect(fixture.request(directory: requestDirectory), manifest: fixture.manifest)
        }
    }

    @Test("Replacing admitted bytes with an identical new file still invalidates its recorded identity")
    func replacementAfterAdmission() throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let inventory = try LocalImageModelInventory.inspect(fixture.request(), manifest: fixture.manifest)
        let name = ImageInventoryFixture.weightPath
        try #require(fixture.contents[name]).write(to: fixture.directory.appendingPathComponent(name), options: .atomic)
        expectInvalidImageRequest(containing: "changed after admission") { try inventory.verifyContents() }
    }

    @Test("New files appearing after admission cannot bypass the complete tree check")
    func extraFileAfterAdmission() throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let inventory = try LocalImageModelInventory.inspect(fixture.request(), manifest: fixture.manifest)
        try Data("unexpected".utf8).write(to: fixture.directory.appendingPathComponent("extra.safetensors"))
        expectInvalidImageRequest(containing: "Unlisted") { try inventory.verifyContents() }
    }

    @Test("Full file verification honors task cancellation")
    func cancelledVerification() async throws {
        let fixture = try ImageInventoryFixture()
        defer { fixture.remove() }
        let inventory = try LocalImageModelInventory.inspect(fixture.request(), manifest: fixture.manifest)
        let task = Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            try inventory.verifyContents()
        }
        do {
            try await task.value
            Issue.record("Cancelled verification unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: no model loading or network is involved.
        }
    }
}

private struct ImageInventoryFixture {
    static let weightPath = "transformer/diffusion_pytorch_model.safetensors"
    let base: URL
    let directory: URL
    let manifest: LocalImageModelInventory.Manifest
    let contents: [String: Data]

    init() throws {
        // Follow the test harness's external-SSD root; a default /var temporary
        // location can regain the symlink spelling during Foundation normalization.
        let parent = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let base = parent.resolvingSymlinksInPath()
            .appendingPathComponent("D-image-inventory-\(UUID().uuidString)")
        let directory = base.appendingPathComponent("model")
        let template = try LocalImageModelInventory.Manifest.bundled()
        let contents = Dictionary(uniqueKeysWithValues: template.files.map { file in
            (file.path, Data("Small offline fixture for \(file.path)\n".utf8))
        })
        let files = template.files.map { file in
            let data = contents[file.path]!
            return LocalImageModelInventory.Manifest.File(
                path: file.path, size: UInt64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            )
        }
        do {
            for file in files {
                let target = directory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents[file.path]!.write(to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
        self.base = base
        self.directory = directory
        self.contents = contents
        manifest = .init(schemaVersion: template.schemaVersion, repository: template.repository,
                         revision: template.revision, files: files)
    }

    func request(directory: URL? = nil, revision: String? = LocalImageModelInventory.revision,
                 seed: UInt64 = 42, width: Int = 512, height: Int = 512,
                 steps: Int = 4, guidanceScale: Float = 1) -> InferenceRequest {
        .init(model: .init(directory: directory ?? self.directory, revision: revision),
              input: .image(.init(prompt: "A red teapot.", width: width, height: height,
                                  steps: steps, guidanceScale: guidanceScale, seed: seed)))
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func expectInvalidImageRequest(containing text: String? = nil, _ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Invalid image installation/request unexpectedly passed")
    } catch InferenceFailure.invalidRequest(let reason) {
        if let text { #expect(reason.contains(text)) }
    } catch {
        Issue.record("Expected invalidRequest, received \(error)")
    }
}
