import CryptoKit
import Foundation
import DInference
import Testing
@testable import DWorkbench

@Suite(.serialized)
struct ModelWanPreparationTests {
    @Test func unconfirmedDrainRetainsLeaseAndScopesAcrossShutdown() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, _ in
            throw InferenceFailure.resourceCleanupUnconfirmed("controlled fixture; no child process exists")
        })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        do { _ = try await library.prepareVideo(id, in: fixture.destination); Issue.record("Expected quarantine") }
        catch let failure as InferenceFailure { guard case .resourceCleanupUnconfirmed = failure else { Issue.record("Quarantine lost"); return } }
        #expect(await library.snapshot().records.first?.activeLeaseCount == 1)
        await #expect(throws: (any Error).self) { _ = try await library.prepareVideo(id, in: fixture.destination) }
        await #expect(throws: (any Error).self) { try await library.remove(id) }
        await #expect(throws: (any Error).self) { try await library.rebind(id, to: fixture.source) }
        await #expect(throws: (any Error).self) { try await library.configureRoot(at: fixture.destination) }
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) { try await library.shutdown() }
            #expect(await library.snapshot().records.first?.activeLeaseCount == 1)
        }
    }
    @Test func shutdownCancellationCannotReleaseAnUnconfirmedChild() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, _ in
            do { try await Task.sleep(for: .seconds(10)) } catch is CancellationError {}
            throw InferenceFailure.resourceCleanupUnconfirmed("controlled cancelled fixture")
        })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        let task = Task { try await library.prepareVideo(id, in: fixture.destination) }
        for _ in 0..<100 {
            if await library.snapshot().records.first?.activeLeaseCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await library.snapshot().records.first?.activeLeaseCount == 1)
        await #expect(throws: (any Error).self) { try await library.shutdown() }
        _ = await task.result
        #expect(await library.snapshot().records.first?.activeLeaseCount == 1)
    }
    @Test func confirmedDrainFailureReleasesLease() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, _ in
            throw InferenceFailure.backendFailed("controlled cleanup error after drain")
        })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        await #expect(throws: (any Error).self) { try await library.prepareVideo(id, in: fixture.destination) }
        #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
        try await library.shutdown()
    }
    private func entry(_ fixture: LibraryFixture) -> ModelCatalogEntry {
        .init(id: "wan21-t2v-1.3b-bf16", title: "Wan controlled fixture", repository: "Wan-AI/Wan2.1-T2V-1.3B",
              revision: ModelWanPreparation.revision, files: fixture.entry.files,
              workflowProfileID: "d.video.generate", preparation: .required)
    }
    private static func writePack(at destination: URL, original: ModelCatalogEntry, corrupt: Bool = false) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let bytes = Data([1, 2, 3, 4]), hash = SHA256.hash(data: Data([1, 2, 3, 4])).map { String(format: "%02x", $0) }.joined()
        var rows: [[String: Any]] = []
        for (role, count) in [("text", 242), ("diffusion", 825), ("vae", 194)] {
            try FileManager.default.createDirectory(at: destination.appendingPathComponent(role), withIntermediateDirectories: false)
            for i in 0..<count {
                let path = String(format: "%@/%04d.safetensors", role, i)
                try bytes.write(to: destination.appendingPathComponent(path), options: .withoutOverwriting)
                rows.append(["role":role, "name":"weight_\(i)", "path":path, "shape":[1],
                             "dtype":role == "vae" ? "F32" : "BF16", "size":bytes.count, "sha256":hash])
            }
        }
        let value: [String: Any] = ["schemaVersion":1, "complete":true,
            "repository": "Wan-AI/Wan2.1-T2V-1.3B", "revision": ModelWanPreparation.revision,
            "preparation":"original-names-tensor-shards-v1", "precision":["text":"BF16", "diffusion":"BF16 with original FP32 time/head/modulation/norm tensors", "vae":"F32"],
            "originals":original.files.map { ["path":$0.path,"size":$0.size,"sha256":$0.sha256] as [String:Any] },
            "tensors":rows]
        try JSONSerialization.data(withJSONObject: value).write(to: destination.appendingPathComponent("D-VIDEO-PREPARED.json"), options: .withoutOverwriting)
        if corrupt { try Data([9, 9, 9, 9]).write(to: destination.appendingPathComponent("text/0000.safetensors")) }
    }
    @Test func preparationRequiresInjectedConverterAndPublishesIndependentPack() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, destination in
            try Self.writePack(at: destination, original: expected)
        })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        #expect(try await library.canPrepareVideo(id))
        let source = try ModelDirectory(fixture.source), before = try source.entries()
        let output = try await library.prepareVideo(id, in: fixture.destination)
        #expect(!output.lastPathComponent.hasPrefix("."))
        #expect(try ModelWanPreparation.verifiedFiles(in: ModelDirectory(output), entry: expected).count == 1262)
        #expect(try source.entries() == before)
        #expect(await library.snapshot().records.first?.state == .preparationRequired)
        #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
        await #expect(throws: (any Error).self) { try await library.acquire(id) }
        try await library.shutdown()
    }
    @Test func unsupportedMissingConverterIsNotReportedReady() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected])
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        #expect(try await !library.canPrepareVideo(id))
        await #expect(throws: (any Error).self) { try await library.prepareVideo(id, in: fixture.destination) }
        try await library.shutdown()
    }
    @Test func damagedOutputOrLateSourceChangeCannotPublish() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture), source = try ModelDirectory(fixture.source), parent = try ModelDirectory(fixture.destination)
        await #expect(throws: (any Error).self) {
            try await ModelWanPreparation.prepare(source: source, entry: expected, parent: parent, name: "corrupt") { _, target in
                try Self.writePack(at: target, original: expected, corrupt: true)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("corrupt").path))
        await #expect(throws: (any Error).self) {
            try await ModelWanPreparation.prepare(source: source, entry: expected, parent: parent, name: "changed") { original, target in
                try Self.writePack(at: target, original: expected)
                try Data("changed".utf8).write(to: original.appendingPathComponent("config.json"))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("changed").path))
    }
    @Test func incompleteOrCancelledPreparationDoesNotPublishAndReleasesLease() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, _ in throw CancellationError() })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        await #expect(throws: CancellationError.self) { try await library.prepareVideo(id, in: fixture.destination) }
        #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
        try await library.shutdown()
        let fake = fixture.destination.appendingPathComponent("fake")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: false)
        try Data("{\"complete\":true,\"revision\":\"\(expected.revision)\",\"tensors\":[{\"name\":\"synthetic\"}]}".utf8).write(to: fake.appendingPathComponent("D-VIDEO-PREPARED.json"))
        #expect(throws: (any Error).self) { try ModelWanPreparation.verifiedFiles(in: ModelDirectory(fake), entry: expected) }
    }
}
