import DInference
import Darwin
import Foundation
import Testing
@testable import DWorkbench

@Suite(.serialized)
struct ModelVideoPreparationTests {
    @Test(.timeLimit(.minutes(120)),
          .enabled(if: ProcessInfo.processInfo.environment["D_TEST_LTX25_RAW"] != nil))
    func fixedLTX25OriginalResourcesUseProductionPreparation() async throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(env["D_TEST_LTX25_RAW"]))
        let root = URL(fileURLWithPath: try #require(env["D_TEST_LTX25_PREPARE_ROOT"]))
        let state = root.appendingPathComponent("state"), destination = root.appendingPathComponent("prepared")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let expected = try #require(ModelCatalog.entries().first { $0.id == "ltx-2.5-bf16" })
        let directory = try ModelDirectory(source), before = try directory.entries()
        let start = Date(), library = try await ModelLibrary(stateDirectory: state, catalog: [expected])
        do {
            let id = try await library.registerExisting(at: source, catalogID: expected.id)
            #expect(await library.snapshot().records.first?.state == .preparationRequired)
            let output = try await library.prepareVideo(id, in: destination)
            let target = try ModelDirectory(output)
            let manifest = try #require(JSONSerialization.jsonObject(with: target.read("D-VIDEO-PACK.json")) as? [String: Any])
            #expect(manifest["profile"] as? String == "ltx-2.5-dev-bf16-full-v1")
            #expect(manifest["modelRevision"] as? String == expected.revision)
            #expect(Set(manifest.keys) == ["schemaVersion", "profile", "modelRevision"])
            #expect(try directory.entries() == before)
            #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
            for file in expected.files {
                #expect(try !target.fileIdentity("model/" + file.path).sameNode(directory.fileIdentity(file.path)))
            }
            try JSONSerialization.data(withJSONObject: ["prepared": output.path, "modelRevision": expected.revision,
                "fileCount": expected.files.count, "seconds": Date().timeIntervalSince(start),
                "sourceUnchanged": true, "activeLeaseCount": 0, "guiVerified": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
            try await library.shutdown()
        } catch { try? await library.shutdown(); throw error }
    }

    private func entry(_ fixture: LibraryFixture) -> ModelCatalogEntry {
        .init(id: "minimax-h3-fl2va-bf16", title: "H3 controlled fixture", repository: "fixture/model",
            revision: "42ed227ee7df40d41602854ae760620d6eb651fe", files: fixture.entry.files,
            workflowProfileID: "d.video.minimax-h3-fl2va-bf16-full-v1", preparation: .required)
    }
    @Test func preparesIndependentExactBytesAndKeepsRawInstallationNonExecutable() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [entry(fixture)])
        let id = try await library.registerExisting(at: fixture.source, catalogID: entry(fixture).id)
        #expect(try await library.canPrepareVideo(id))
        await #expect(throws: (any Error).self) { try await library.acquire(id) }
        let source = try ModelDirectory(fixture.source), before = try source.entries()
        let prepared = try await library.prepareVideo(id, in: fixture.destination)
        let target = try ModelDirectory(prepared)
        for (path, bytes) in fixture.contents {
            #expect(try target.read("model/" + path) == bytes)
            #expect(try !target.fileIdentity("model/" + path).sameNode(source.fileIdentity(path)))
        }
        let manifest = try #require(JSONSerialization.jsonObject(with: target.read("D-VIDEO-PACK.json")) as? [String: Any])
        #expect(manifest["profile"] as? String == "minimax-h3-fl2va-bf16-full-v1")
        #expect(manifest["modelRevision"] as? String == entry(fixture).revision)
        #expect(try source.entries() == before)
        let record = try #require(await library.snapshot().records.first)
        #expect(record.state == .preparationRequired && record.activeLeaseCount == 0)
        await #expect(throws: (any Error).self) { try await library.acquire(id) }
        try await library.remove(id) // external registration only: prepared copy must survive.
        #expect(try target.read("model/config.json") == fixture.contents["config.json"])
        try await library.shutdown()
    }
    @Test func cancelledCopyIsNotPublishedAndNeverOverwritesOrFollowsLinks() throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let source = try ModelDirectory(fixture.source), parent = try ModelDirectory(fixture.destination)
        let before = try source.entries()
        #expect(throws: CancellationError.self) {
            try ModelVideoPreparation.prepare(source: source, entry: entry(fixture), parent: parent, name: "cancelled") { index in
                if index == 1 { throw CancellationError() }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("cancelled").path))
        #expect(try source.entries() == before)
        let completed = try ModelVideoPreparation.prepare(source: source, entry: entry(fixture), parent: parent, name: "complete")
        let completeBefore = try ModelDirectory(completed).entries()
        #expect(throws: (any Error).self) {
            try ModelVideoPreparation.prepare(source: source, entry: entry(fixture), parent: parent, name: "complete")
        }
        #expect(try ModelDirectory(completed).entries() == completeBefore)
        try FileManager.default.createSymbolicLink(at: fixture.destination.appendingPathComponent("alias"), withDestinationURL: fixture.source)
        #expect(throws: (any Error).self) {
            try ModelVideoPreparation.prepare(source: source, entry: entry(fixture), parent: parent, name: "alias")
        }
        #expect(throws: (any Error).self) {
            try ModelVideoPreparation.prepare(source: source, entry: entry(fixture), parent: try source.child("weights"), name: "inside")
        }
    }
    @Test(arguments: ["readme", "cache", "link"])
    func fixedVideoSourceIgnoresUnrelatedEntries(kind: String) throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let extra = fixture.source.appendingPathComponent(kind)
        switch kind {
        case "readme": try Data("unrelated".utf8).write(to: extra)
        case "cache": try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        default: try FileManager.default.createSymbolicLink(at: extra,
            withDestinationURL: fixture.root.appendingPathComponent("missing-extra"))
        }
        let source = try ModelDirectory(fixture.source), parent = try ModelDirectory(fixture.destination)
        let before = try source.verifyRequired(entry(fixture).files)
        let output = try ModelVideoPreparation.prepare(source: source, entry: entry(fixture), parent: parent, name: "with-extra")
        let target = try ModelDirectory(output)
        #expect(try source.requiredTree(paths: Set(entry(fixture).files.map(\.path))) == before)
        for (path, bytes) in fixture.contents { #expect(try target.read("model/" + path) == bytes) }
        var info = stat()
        #expect(lstat(extra.path, &info) == 0)
        #expect(try target.entries().keys.sorted() == (fixture.contents.keys.map { "model/" + $0 } + ["D-VIDEO-PACK.json"]).sorted())
    }
    @Test(arguments: ["missing", "changed", "leaf-link", "parent-link"])
    func fixedVideoSourceRejectsChangedRequiredPaths(kind: String) throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let leaf = fixture.source.appendingPathComponent("weights/payload.bin")
        switch kind {
        case "missing": try FileManager.default.removeItem(at: leaf)
        case "changed": try Data(repeating: 0, count: fixture.contents["weights/payload.bin"]!.count).write(to: leaf)
        case "leaf-link":
            try FileManager.default.removeItem(at: leaf)
            try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: fixture.root.appendingPathComponent("missing"))
        default:
            let parent = fixture.source.appendingPathComponent("weights")
            let moved = fixture.root.appendingPathComponent("moved-weights")
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        }
        let source = try ModelDirectory(fixture.source), parent = try ModelDirectory(fixture.destination)
        #expect(throws: (any Error).self) {
            try ModelVideoPreparation.prepare(source: source, entry: entry(fixture), parent: parent, name: "invalid")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("invalid").path))
    }
    @Test func sourceChangeDuringFixedVideoPreparationCannotPublish() throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let source = try ModelDirectory(fixture.source), parent = try ModelDirectory(fixture.destination)
        let expected = entry(fixture)
        #expect(throws: (any Error).self) {
            try ModelVideoPreparation.prepare(source: source, entry: expected, parent: parent, name: "source-changed") { index in
                if index == expected.files.count {
                    try Data(repeating: 0, count: fixture.contents["weights/payload.bin"]!.count)
                        .write(to: fixture.source.appendingPathComponent("weights/payload.bin"))
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("source-changed").path))
    }
    @Test func damagedBytesAndUnconvertedRecipeCannotBecomeReadyPack() throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        try Data("not the original".utf8).write(to: fixture.source.appendingPathComponent("config.json"))
        let source = try ModelDirectory(fixture.source), parent = try ModelDirectory(fixture.destination)
        #expect(throws: (any Error).self) {
            try ModelVideoPreparation.prepare(source: source, entry: entry(fixture), parent: parent, name: "damaged")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("damaged").path))
        #expect(ModelVideoPreparation.profile(for: fixture.entry) == nil)
        #expect(throws: (any Error).self) {
            try ModelVideoPreparation.prepare(source: source, entry: fixture.entry, parent: parent, name: "unconverted")
        }
    }
    @Test func postVerificationTamperIsNotPublished() throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let source = try ModelDirectory(fixture.source), parent = try ModelDirectory(fixture.destination)
        let expected = entry(fixture)
        #expect(throws: (any Error).self) {
            try ModelVideoPreparation.prepare(source: source, entry: expected, parent: parent, name: "tampered") { index in
                if index == expected.files.count {
                    let stage = try #require(FileManager.default.contentsOfDirectory(at: fixture.destination, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".d-video-preparing-") })
                    try Data(repeating: 0, count: fixture.contents["config.json"]!.count).write(to: stage.appendingPathComponent("model/config.json"))
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("tampered").path))
    }
    @Test func shutdownCancelsAndDrainsPreparationBeforeReleasingItsLease() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [entry(fixture)])
        let id = try await library.registerExisting(at: fixture.source, catalogID: entry(fixture).id)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let preparing = Task {
            defer { signal.finish() }
            return try await library.prepareVideo(id, in: fixture.destination) { index in
                if index == 0 {
                    signal.yield(())
                    let deadline = Date().addingTimeInterval(5)
                    while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                    try Task.checkCancellation()
                    throw ModelLibraryError.storage("Fixture expected shutdown cancellation within five seconds")
                }
            }
        }
        var iterator = entered.makeAsyncIterator()
        let observed = await iterator.next()
        #expect(observed != nil)
        try await library.shutdown()
        await #expect(throws: CancellationError.self) { try await preparing.value }
        #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).allSatisfy { $0.hasPrefix(".d-video-preparing-") })
    }

}


extension ModelVideoPreparationTests {
    @Test func localFileModesPrepareOneFinalCopyAndKeepOriginalReadOnly() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let raw = entry(fixture)
        let entry = ModelCatalogEntry(id: raw.id, title: raw.title, repository: raw.repository, revision: raw.revision,
            files: raw.files, workflowProfileID: raw.workflowProfileID, workflowIdentity: "video:fixture-execution", preparation: .required)
        var library: ModelLibrary? = try await ModelLibrary(stateDirectory: fixture.state, catalog: [entry])
        try await library!.configureRoot(at: fixture.destination)
        let source = try ModelDirectory(fixture.source), before = try source.entries()
        let validate: @Sendable (URL) async throws -> ModelReference = { url in .init(directory: url, revision: "fixture-execution") }
        let selection = try await library!.inspectLocalFiles(at: fixture.source, catalogID: entry.id, validatePrepared: validate)
        #expect(!selection.supportsOriginal && !selection.prepared)
        await #expect(throws: (any Error).self) { _ = try await library!.registerLocalFiles(selection, storage: .external, validatePrepared: validate) }
        let copy = try await library!.registerLocalFiles(selection, storage: .managed, validatePrepared: validate)
        let resources = await library!.snapshot().resources
        #expect(resources.filter { $0.record.storage == .managed }.count == 1)
        #expect(resources.first { $0.record.id == copy }?.control.role == .execution)
        let output = try await library!.resolve(copy).directory
        #expect(try source.entries() == before)
        #expect(try await library!.registerLocalFiles(selection, storage: .managed, validatePrepared: validate) == copy)
        try await library!.reverifyResource(.init(rawValue: copy.rawValue), preparedValidator: validate)
        #expect(try await library!.resolve(copy).directory == output)
        // Managed files may never be aliased under a second external owner.
        let managed = try await library!.inspectLocalFiles(at: output, catalogID: entry.id, validatePrepared: validate)
        await #expect(throws: (any Error).self) { _ = try await library!.registerLocalFiles(managed, storage: .external, validatePrepared: validate) }
        try await library!.shutdown(); library = nil
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("isolated-source"))
        let cold = try await ModelLibrary(stateDirectory: fixture.state, catalog: [entry])
        #expect(try await cold.resolve(copy).directory == output)
        #expect(try ModelDirectory(output).verify(ModelVideoPreparation.requiredFiles(in: ModelDirectory(output), entry: entry)).count == entry.files.count + 1)
        try await cold.deleteOwnedCopy(.init(rawValue: copy.rawValue))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try await cold.shutdown()
    }

    @Test func preparedMarkerWithoutWeightsNeverRegisters() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let raw = entry(fixture)
        let entry = ModelCatalogEntry(id: raw.id, title: raw.title, repository: raw.repository, revision: raw.revision,
            files: raw.files, workflowProfileID: raw.workflowProfileID, workflowIdentity: "video:fixture-execution", preparation: .required)
        let fake = fixture.root.appendingPathComponent("incomplete")
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("model"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "profile": "minimax-h3-fl2va-bf16-full-v1", "modelRevision": entry.revision]).write(to: fake.appendingPathComponent("D-VIDEO-PACK.json"))
        let library = try await ModelLibrary(stateDirectory: fixture.state, catalog: [entry])
        let validate: @Sendable (URL) async throws -> ModelReference = { .init(directory: $0, revision: "fixture-execution") }
        let selection = try await library.inspectLocalFiles(at: fake, catalogID: entry.id, validatePrepared: validate)
        await #expect(throws: (any Error).self) { _ = try await library.registerLocalFiles(selection, storage: .external, validatePrepared: validate) }
        #expect(await library.snapshot().records.isEmpty)
        try await library.shutdown()
    }
}
