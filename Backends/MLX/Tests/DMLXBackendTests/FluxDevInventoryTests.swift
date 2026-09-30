import CryptoKit
import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Pinned FLUX.2 Dev BF16 inventory")
struct FluxDevInventoryTests {
    @Test("Bundled official tree has 32 pinned files and BF16 components")
    func bundledManifest() throws {
        let manifest = try LocalFluxDevInventory.Manifest.bundled()
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.repository == LocalFluxDevInventory.repository)
        #expect(manifest.revision == LocalFluxDevInventory.revision)
        #expect(manifest.profile == "flux2-dev-bf16-v1")
        #expect(manifest.files.count == 32)
        #expect(manifest.files.filter { $0.path.hasSuffix(".safetensors") }.count == 18)
        #expect(manifest.files.filter { $0.digestAlgorithm == "sha256" }.count == 19)
        #expect(manifest.files.filter { $0.digestAlgorithm == "git-blob-sha1" }.count == 13)
    }

    @Test("Small offline tree verifies both digest algorithms and rejects changed bytes")
    func fixtureIntegrity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inventory = try LocalFluxDevInventory.inspect(fixture.request(), manifest: fixture.manifest)
        #expect(inventory.executionProfile == ImageExecutionCapability.flux2Dev.profile)
        #expect(inventory.estimatedPeakBytes >= 128 * 1024 * 1024 * 1024)
        try inventory.verifyContents()
        try inventory.verifyContents()
        let target = fixture.directory.appendingPathComponent("transformer/diffusion_pytorch_model-00001-of-00007.safetensors")
        try Data(repeating: 0, count: fixture.contents["transformer/diffusion_pytorch_model-00001-of-00007.safetensors"]!.count).write(to: target)
        #expect(throws: (any Error).self) { try inventory.verifyContents() }
    }

    @Test("Missing component and algorithm substitution are rejected")
    func strictTree() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.directory.appendingPathComponent("text_encoder/model-00010-of-00010.safetensors")
        try FileManager.default.removeItem(at: missing)
        #expect(throws: (any Error).self) {
            _ = try LocalFluxDevInventory.inspect(fixture.request(), manifest: fixture.manifest)
        }
        let replaced = fixture.manifest.files.map { file in
            LocalFluxDevInventory.Manifest.File(path: file.path, size: file.size,
                digestAlgorithm: file.path == "model_index.json" ? "sha256" : file.digestAlgorithm,
                digest: file.digest)
        }
        let altered = LocalFluxDevInventory.Manifest(schemaVersion: fixture.manifest.schemaVersion,
            repository: fixture.manifest.repository, revision: fixture.manifest.revision,
            profile: fixture.manifest.profile, files: replaced)
        #expect(throws: (any Error).self) {
            _ = try LocalFluxDevInventory.inspect(fixture.request(), manifest: altered)
        }
    }

    private struct Fixture {
        let directory: URL
        let manifest: LocalFluxDevInventory.Manifest
        let contents: [String: Data]

        init() throws {
            let parent = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            directory = parent.resolvingSymlinksInPath().appendingPathComponent("D-dev-inventory-\(UUID())")
            let template = try LocalFluxDevInventory.Manifest.bundled()
            var contents: [String: Data] = [:]
            var files: [LocalFluxDevInventory.Manifest.File] = []
            do {
                for file in template.files {
                    let bytes = Data("Offline Dev fixture: \(file.path)\n".utf8)
                    contents[file.path] = bytes
                    let digest: String
                    if file.digestAlgorithm == "sha256" {
                        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    } else {
                        var blob = Insecure.SHA1()
                        blob.update(data: Data("blob \(bytes.count)\0".utf8))
                        blob.update(data: bytes)
                        digest = blob.finalize().map { String(format: "%02x", $0) }.joined()
                    }
                    files.append(.init(path: file.path, size: UInt64(bytes.count),
                                       digestAlgorithm: file.digestAlgorithm, digest: digest))
                    let target = directory.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try bytes.write(to: target)
                }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            self.contents = contents
            manifest = .init(schemaVersion: template.schemaVersion, repository: template.repository,
                             revision: template.revision, profile: template.profile, files: files)
        }

        func request() -> InferenceRequest {
            .init(model: .init(directory: directory, revision: LocalFluxDevInventory.revision),
                  input: .image(.init(prompt: "A red cup", width: 512, height: 512,
                                      steps: 4, guidanceScale: 3.5, seed: 42,
                                      executionProfile: ImageExecutionCapability.flux2Dev.profile)))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
