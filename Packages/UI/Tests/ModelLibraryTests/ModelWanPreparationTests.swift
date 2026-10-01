import CryptoKit
import Foundation
import DInference
import Testing
@testable import DWorkbench

@Suite(.serialized)
struct ModelWanPreparationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_TEST_WAN_PREPARED_OUTPUT"] != nil))
    func realPreparedPackPassesApplicationVerifier() throws {
        let path = try #require(ProcessInfo.processInfo.environment["D_TEST_WAN_PREPARED_OUTPUT"])
        let directory = try ModelDirectory(URL(fileURLWithPath: path))
        let model = try #require(ModelCatalog.entries().first { $0.id == "wan21-t2v-1.3b-bf16" })
        let files = try ModelWanPreparation.verifiedFiles(in: directory, entry: model)
        #expect(files.count == 1_262)
        #expect(try directory.entries(expectedPaths: Set(files.keys)) == files)
    }

    private actor ConverterSignal {
        var entered = false
        func markEntered() { entered = true }
    }
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
        let expected = entry(fixture), signal = ConverterSignal()
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, _ in
            await signal.markEntered()
            do { try await Task.sleep(for: .seconds(10)) } catch is CancellationError {}
            throw InferenceFailure.resourceCleanupUnconfirmed("controlled cancelled fixture")
        })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        let task = Task { try await library.prepareVideo(id, in: fixture.destination) }
        for _ in 0..<100 {
            if await signal.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await signal.entered)
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
    private func nestedEntry(_ fixture: LibraryFixture) throws -> ModelCatalogEntry {
        let old = fixture.source.appendingPathComponent("weights/payload.bin")
        let nested = fixture.source.appendingPathComponent("a/b/payload.bin")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: nested)
        let files = fixture.entry.files.map { file in
            ModelFile(path: file.path == "weights/payload.bin" ? "a/b/payload.bin" : file.path,
                      size: file.size, sha256: file.sha256)
        }
        return .init(id: "wan21-t2v-1.3b-bf16", title: "Wan nested fixture", repository: "Wan-AI/Wan2.1-T2V-1.3B",
                     revision: ModelWanPreparation.revision, files: files,
                     workflowProfileID: "d.video.generate", preparation: .required)
    }
    private func threeRootFileEntry(_ fixture: LibraryFixture) throws -> ModelCatalogEntry {
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("weights/payload.bin"),
                                         to: fixture.source.appendingPathComponent("payload.bin"))
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("weights"))
        let third = Data("third root fixture".utf8)
        try third.write(to: fixture.source.appendingPathComponent("third.bin"))
        let files = fixture.entry.files.map { file in
            ModelFile(path: file.path == "weights/payload.bin" ? "payload.bin" : file.path,
                      size: file.size, sha256: file.sha256)
        } + [ModelFile(path: "third.bin", size: UInt64(third.count),
                       sha256: SHA256.hash(data: third).map { String(format: "%02x", $0) }.joined())]
        return .init(id: "wan21-t2v-1.3b-bf16", title: "Wan legacy root fixture", repository: "Wan-AI/Wan2.1-T2V-1.3B",
                     revision: ModelWanPreparation.revision, files: files,
                     workflowProfileID: "d.video.generate", preparation: .required)
    }
    private static func replaceRequiredParent(_ fixture: LibraryFixture, source: ModelDirectory) throws {
        let leaf = "a/b/payload.bin"
        let before = try source.fileIdentity(leaf)
        let parentBefore = try #require(source.requiredTree(paths: [leaf]).directories["a"])
        let directory = fixture.source.appendingPathComponent("a")
        let moved = fixture.root.appendingPathComponent("moved-a")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: moved.appendingPathComponent("b"), to: directory.appendingPathComponent("b"))
        let parentAfter = try #require(source.requiredTree(paths: [leaf]).directories["a"])
        #expect(try source.fileIdentity(leaf) == before)
        #expect(!parentBefore.sameNode(parentAfter))
    }
    private func addIrrelevantContent(_ fixture: LibraryFixture) throws -> URL {
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("untouched".utf8).write(to: outside.appendingPathComponent("marker"))
        try FileManager.default.createDirectory(at: fixture.source.appendingPathComponent("google/tokenizer"), withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: fixture.source.appendingPathComponent("google/tokenizer/cache"))
        try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("outside-link"), withDestinationURL: outside)
        return outside
    }

    @Test func externalRawImportProjectsOnlyRequiredPathsAcrossResolveRebindAndPreparation() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture), outside = try addIrrelevantContent(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, target in
            try Self.writePack(at: target, original: expected)
        })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        #expect(await library.snapshot().records.first?.state == .preparationRequired)
        try Data("new cache".utf8).write(to: fixture.source.appendingPathComponent("google/tokenizer/cache"))
        let candidate = fixture.root.appendingPathComponent("candidate")
        try fixture.writeModel(at: candidate)
        try FileManager.default.createSymbolicLink(at: candidate.appendingPathComponent("ignored-link"), withDestinationURL: outside)
        try await library.rebind(id, to: candidate)
        #expect(await library.snapshot().records.first?.directory == candidate)
        let output = try await library.prepareVideo(id, in: fixture.destination)
        #expect(try ModelWanPreparation.verifiedFiles(in: ModelDirectory(output), entry: expected).count == 1262)
        try FileManager.default.createDirectory(at: output.appendingPathComponent("google"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { _ = try ModelWanPreparation.verifiedFiles(in: ModelDirectory(output), entry: expected) }
        #expect(try String(contentsOf: outside.appendingPathComponent("marker"), encoding: .utf8) == "untouched")
        #expect(FileManager.default.fileExists(atPath: candidate.appendingPathComponent("ignored-link").path))
        #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
        try await library.shutdown()
    }

    @Test(arguments: ["required-link", "parent-link", "missing", "wrong-digest", "hardlink"])
    func externalRawImportRejectsUnsafeRequiredPaths(kind: String) async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture), file = fixture.source.appendingPathComponent("weights/payload.bin")
        let outside = fixture.root.appendingPathComponent("outside.bin")
        try Data(repeating: 0x47, count: 4096).write(to: outside)
        switch kind {
        case "required-link":
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        case "parent-link":
            try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("weights"))
            let outsideDirectory = fixture.root.appendingPathComponent("outside-weights")
            try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: outside, to: outsideDirectory.appendingPathComponent("payload.bin"))
            try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("weights"), withDestinationURL: outsideDirectory)
        case "missing": try FileManager.default.removeItem(at: file)
        case "wrong-digest": try Data(repeating: 0x48, count: 4096).write(to: file)
        default: try FileManager.default.linkItem(at: file, to: fixture.root.appendingPathComponent("hardlink"))
        }
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected])
        await #expect(throws: (any Error).self) { _ = try await library.registerExisting(at: fixture.source, catalogID: expected.id) }
        #expect(await library.snapshot().records.first?.state == .failed)
        try await library.shutdown()
    }

    @Test func requiredFileReplacementInvalidatesRegisteredRaw() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, target in
            try Self.writePack(at: target, original: expected)
        })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        let file = fixture.source.appendingPathComponent("weights/payload.bin")
        let saved = fixture.root.appendingPathComponent("saved.bin")
        try FileManager.default.moveItem(at: file, to: saved)
        try Data(repeating: 0x47, count: 4096).write(to: file)
        await #expect(throws: (any Error).self) { _ = try await library.prepareVideo(id, in: fixture.destination) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: saved, to: file)
        try await library.shutdown()
    }

    @Test func requiredDirectoryReplacementInvalidatesRegisteredRaw() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = try nestedEntry(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, target in
            try Self.writePack(at: target, original: expected)
        })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        let source = try ModelDirectory(fixture.source)
        try Self.replaceRequiredParent(fixture, source: source)
        await #expect(throws: (any Error).self) { _ = try await library.prepareVideo(id, in: fixture.destination) }
        try await library.shutdown()
    }

    @Test func requiredDirectoryIdentitiesPersistAcrossReopen() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = try nestedEntry(fixture)
        var library: ModelLibrary? = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, target in
            try Self.writePack(at: target, original: expected)
        })
        let id = try await library!.registerExisting(at: fixture.source, catalogID: expected.id)
        try await library!.shutdown(); library = nil
        let indexURL = fixture.state.appendingPathComponent("index.json")
        let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        let records = try #require(index["records"] as? [[String: Any]])
        let record = try #require(records.first)
        let directories = try #require(record["verifiedDirectories"] as? [String: Any])
        #expect(Set(directories.keys) == ["a", "a/b"])
        try FileManager.default.createDirectory(at: fixture.source.appendingPathComponent("google"), withIntermediateDirectories: false)
        let reopened = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, target in
            try Self.writePack(at: target, original: expected)
        })
        #expect(await reopened.snapshot().records.first?.availability == .available)
        let output = try await reopened.prepareVideo(id, in: fixture.destination)
        #expect(FileManager.default.fileExists(atPath: output.path))
        try Self.replaceRequiredParent(fixture, source: ModelDirectory(fixture.source))
        #expect(await reopened.snapshot().records.first?.availability == .unavailable)
        await #expect(throws: (any Error).self) { _ = try await reopened.prepareVideo(id, in: fixture.destination) }
        try await reopened.shutdown()
    }

    @Test func legacyThreeRootFileRecordWithoutDirectoriesStillReopens() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = try threeRootFileEntry(fixture)
        var library: ModelLibrary? = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, target in
            try Self.writePack(at: target, original: expected)
        })
        let id = try await library!.registerExisting(at: fixture.source, catalogID: expected.id)
        try await library!.shutdown(); library = nil
        let indexURL = fixture.state.appendingPathComponent("index.json")
        var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        var records = try #require(index["records"] as? [[String: Any]])
        #expect(records.count == 1)
        records[0].removeValue(forKey: "verifiedDirectories")
        index["records"] = records
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL)
        let reopened = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, target in
            try Self.writePack(at: target, original: expected)
        })
        #expect(await reopened.snapshot().records.first?.availability == .available)
        let output = try await reopened.prepareVideo(id, in: fixture.destination)
        #expect(FileManager.default.fileExists(atPath: output.path))
        try await reopened.shutdown()
    }

    @Test func rawRootReplacementAndFailedRebindPreserveOriginalRecord() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected], wanPreparation: { _, target in
            try Self.writePack(at: target, original: expected)
        })
        let id = try await library.registerExisting(at: fixture.source, catalogID: expected.id)
        let bad = fixture.root.appendingPathComponent("bad")
        try fixture.writeModel(at: bad)
        try Data("wrong".utf8).write(to: bad.appendingPathComponent("config.json"))
        await #expect(throws: (any Error).self) { try await library.rebind(id, to: bad) }
        #expect(await library.snapshot().records.first?.directory == fixture.source)
        let moved = fixture.root.appendingPathComponent("moved-source")
        try FileManager.default.moveItem(at: fixture.source, to: moved)
        try fixture.writeModel(at: fixture.source)
        await #expect(throws: (any Error).self) { _ = try await library.prepareVideo(id, in: fixture.destination) }
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("config.json").path))
        try await library.shutdown()
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
    @Test func lateRequiredReplacementRejectsPublicationButIrrelevantChangeDoesNot() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture), source = try ModelDirectory(fixture.source), parent = try ModelDirectory(fixture.destination)
        let paths = Set(expected.files.map(\.path))
        let old = try source.requiredTree(paths: paths)
        let output = try await ModelWanPreparation.prepare(source: source, entry: expected, parent: parent,
            name: "irrelevant", externalRawProjection: true) { _, target in
            try Self.writePack(at: target, original: expected)
            try FileManager.default.createDirectory(at: fixture.source.appendingPathComponent("google"), withIntermediateDirectories: false)
            try Data("new".utf8).write(to: fixture.source.appendingPathComponent("google/cache"))
        }
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try source.requiredTree(paths: paths) == old)
        let file = fixture.source.appendingPathComponent("weights/payload.bin")
        await #expect(throws: (any Error).self) {
            try await ModelWanPreparation.prepare(source: source, entry: expected, parent: parent,
                name: "replaced-file", externalRawProjection: true) { _, target in
                try Self.writePack(at: target, original: expected)
                let moved = fixture.root.appendingPathComponent("moved-payload")
                try FileManager.default.moveItem(at: file, to: moved)
                try Data(repeating: 0x47, count: 4096).write(to: file)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("replaced-file").path))
    }

    @Test func lateRequiredDirectoryReplacementRejectsPublicationWithSameFileNode() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = try nestedEntry(fixture), source = try ModelDirectory(fixture.source), parent = try ModelDirectory(fixture.destination)
        await #expect(throws: (any Error).self) {
            try await ModelWanPreparation.prepare(source: source, entry: expected, parent: parent,
                name: "replaced-directory", externalRawProjection: true) { _, target in
                try Self.writePack(at: target, original: expected)
                try Self.replaceRequiredParent(fixture, source: source)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("replaced-directory").path))
    }

    @Test func managedWanStillRejectsExtrasDuringPreparation() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let expected = entry(fixture)
        let server = try await LoopbackServer(fixture)
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [expected],
            transport: URLSessionModelRangeTransport(allowsLocalHTTP: true), sourceBaseURL: server.url,
            wanPreparation: { _, target in try Self.writePack(at: target, original: expected) })
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: expected.id)
        let record = try await waitRecord(library, id: id) { [.preparationRequired, .failed].contains($0.state) }
        #expect(record.state == .preparationRequired)
        let installed = try #require(record.directory)
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("google"), withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { _ = try await library.prepareVideo(id, in: fixture.root) }
        try await library.shutdown()
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
