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
        let missingFixture = try Fixture()
        defer { missingFixture.remove() }
        let missing = missingFixture.directory.appendingPathComponent("text_encoder/model-00010-of-00010.safetensors")
        try FileManager.default.removeItem(at: missing)
        do {
            _ = try LocalFluxDevInventory.inspect(missingFixture.request(), manifest: missingFixture.manifest)
            Issue.record("Missing Dev text encoder shard unexpectedly passed admission")
        } catch InferenceFailure.invalidRequest(let reason) {
            #expect(reason.contains("Cannot open image model file"))
        } catch {
            Issue.record("Expected missing-file admission failure, received \(error)")
        }

        let completeFixture = try Fixture()
        defer { completeFixture.remove() }
        let complete = try LocalFluxDevInventory.inspect(
            completeFixture.request(), manifest: completeFixture.manifest)
        try complete.verifyContents()
        let replaced = completeFixture.manifest.files.map { file in
            LocalFluxDevInventory.Manifest.File(path: file.path, size: file.size,
                digestAlgorithm: file.path == "model_index.json" ? "sha256" : file.digestAlgorithm,
                digest: file.digest)
        }
        let altered = LocalFluxDevInventory.Manifest(schemaVersion: completeFixture.manifest.schemaVersion,
            repository: completeFixture.manifest.repository, revision: completeFixture.manifest.revision,
            profile: completeFixture.manifest.profile, files: replaced)
        do {
            _ = try LocalFluxDevInventory.inspect(completeFixture.request(), manifest: altered)
            Issue.record("Dev manifest with substituted digest algorithm unexpectedly passed admission")
        } catch InferenceFailure.invalidRequest(let reason) {
            #expect(reason.contains("digest"))
        } catch {
            Issue.record("Expected digest algorithm failure, received \(error)")
        }
    }

    @Test("Dev inventory ignores unrelated files and broken links but detects required changes")
    func externalExtras() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("notes".utf8).write(to: fixture.directory.appendingPathComponent("README.md"))
        try FileManager.default.createSymbolicLink(
            at: fixture.directory.appendingPathComponent("unrelated-link"),
            withDestinationURL: fixture.directory.appendingPathComponent("absent"))
        let inventory = try LocalFluxDevInventory.inspect(fixture.request(), manifest: fixture.manifest)
        try Data("cache".utf8).write(to: fixture.directory.appendingPathComponent("tokenizer/unrelated.cache"))
        try inventory.verifyContents()
        let required = fixture.directory.appendingPathComponent("model_index.json")
        try Data("changed".utf8).write(to: required)
        #expect(throws: (any Error).self) { try inventory.verifyContents() }
    }

    @Test("Layered budget includes every ordered reference and stays below resident floor")
    func layeredBudget() throws {
        let gib = UInt64(1024 * 1024 * 1024)
        let stage = LocalFluxDevInventory.LayeredStages(
            text: 3 * gib, transformer: 3 * gib, vae: gib,
            transformerWidth: 3072, textWidth: 5120)
        func reference(_ suffix: String) -> ImageReference {
            ImageReference(url: URL(fileURLWithPath: "/tmp/\(suffix)"),
                           sha256: String(repeating: "a", count: 64),
                           byteCount: 256 * 256 * 3, width: 256, height: 256)
        }
        let base = ImageRequest(prompt: "A red cup", width: 512, height: 512,
            steps: 50, guidanceScale: 4, seed: 42,
            executionProfile: ImageExecutionCapability.flux2Dev.profile,
            loadingStrategy: .ssdLayered)
        let one = ImageRequest(prompt: base.prompt, width: base.width, height: base.height,
            steps: base.steps, guidanceScale: base.guidanceScale, seed: base.seed,
            executionProfile: base.executionProfile, referenceImages: [reference("first")],
            loadingStrategy: .ssdLayered)
        let two = ImageRequest(prompt: base.prompt, width: base.width, height: base.height,
            steps: base.steps, guidanceScale: base.guidanceScale, seed: base.seed,
            executionProfile: base.executionProfile, referenceImages: [reference("first"), reference("second")],
            loadingStrategy: .ssdLayered)
        let noReference = try LocalFluxDevInventory.layeredPeak(stage: stage, image: base)
        let oneReference = try LocalFluxDevInventory.layeredPeak(stage: stage, image: one)
        let twoReferences = try LocalFluxDevInventory.layeredPeak(stage: stage, image: two)
        #expect(noReference < oneReference)
        #expect(oneReference < twoReferences)
        #expect(twoReferences < 128 * gib)
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
