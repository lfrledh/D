import DInference
import Darwin
import Foundation
import Testing
import Synchronization
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

extension ModelVideoPreparationTests {
    @Test func compatiblePreparedCopyClosesEncoderAndSurvivesSourceRemovalAndColdOpen() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let profile = ExternalVideoExecutionProfile.ltx23BF16Full
        let pack = f.root.appendingPathComponent("prepared-local")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        var files = [ModelFile]()
        for prefix in ["model", "text_encoder"] {
            for file in f.entry.files {
                let path = prefix + "/" + file.path, target = pack.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.contents[file.path]!.write(to: target)
                files.append(.init(path: path, size: file.size, sha256: file.sha256))
            }
        }
        try JSONEncoder().encode(ExternalVideoModelManifest(profile: profile)).write(to: pack.appendingPathComponent(ExternalVideoModelManifest.filename))
        let entry = ModelCatalogEntry(id: "local-" + profile.rawValue, title: "Controlled LTX closure fixture", repository: "fixture/local",
            revision: profile.modelRevision, files: files, workflowProfileID: "d.video." + profile.rawValue,
            workflowIdentity: "video:" + profile.modelIdentity, preparation: .required, localPreparedOnly: true)
        let validate: @Sendable (URL) async throws -> ModelReference = { url in
            let marker = try JSONDecoder().decode(ExternalVideoModelManifest.self, from: Data(contentsOf: url.appendingPathComponent(ExternalVideoModelManifest.filename)))
            try marker.validate()
            return .init(directory: url, revision: marker.profile.modelIdentity)
        }
        let before = try ModelDirectory(pack).entries()
        var owner: ModelLibrary? = try await ModelLibrary(stateDirectory: f.state, catalog: [entry])
        try await owner!.configureRoot(at: f.destination)
        await #expect(throws: ModelLibraryError.self) { _ = try await owner!.enqueueDownloads([entry.id], postAction: .register) }
        let choices = try await owner!.inspectLocalCandidates(at: pack, validatePrepared: validate)
        #expect(choices.count == 1 && choices[0].supportsOriginal)
        let id = try await owner!.registerLocalFiles(choices[0], storage: .managed, validatePrepared: validate)
        let snapshot = await owner!.snapshot()
        let copy = try #require(snapshot.records.first { $0.id == id }?.directory)
        #expect(snapshot.uniqueRunnableResource(identity: entry.workflowIdentity!)?.record.id == id)
        #expect(try ModelDirectory(pack).entries() == before)
        #expect(try ModelDirectory(copy).entries().count == files.count + 1)
        try await owner!.shutdown(); owner = nil
        // Disconnect the exact fixture source without modifying its contents.
        try FileManager.default.moveItem(at: pack, to: f.root.appendingPathComponent("source-disconnected"))
        let reopened = try await ModelLibrary(stateDirectory: f.state, catalog: [entry])
        try await reopened.reverifyResource(.init(rawValue: id.rawValue), preparedValidator: validate)
        #expect(await reopened.snapshot().uniqueRunnableResource(identity: entry.workflowIdentity!)?.record.id == id)
        #expect(try ModelDirectory(copy).verifyRequired(files).files.count == files.count)
        #expect(await reopened.snapshot().downloads.isEmpty)
        try await reopened.shutdown()
    }
}

extension ModelVideoPreparationTests {
    @Test func localRecipeResourcesAreExactAndDoNotBecomeDownloads() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try ModelCatalog.entries().filter(\.localPreparedOnly)
        for (index, names) in [["ltx23-bf16", "gemma3-bf16"], ["ltx23-q8-test", "gemma3-q4-test"]].enumerated() {
            var expected = [ModelFile]()
            for (prefix, name) in zip(["model", "text_encoder"], names) {
                let data = try Data(contentsOf: repo.appendingPathComponent("Backends/Video/Adapters/Resources/" + name + ".json"))
                let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                for file in try #require(value["files"] as? [[String: Any]]) {
                    expected.append(.init(path: prefix + "/" + (file["name"] as! String), size: (file["size"] as! NSNumber).uint64Value, sha256: file["sha256"] as! String))
                }
            }
            #expect(entries[index].files == expected)
        }
        #expect(entries.count == 2 && entries.allSatisfy(\.localPreparedOnly))
        #expect(entries.map { $0.files.count } == [28, 26]) // marker is separately validated and captured
        #expect(entries.allSatisfy { $0.files.contains { $0.path == "text_encoder/tokenizer.json" } && $0.files.contains { $0.path == "text_encoder/tokenizer.model" } })
        #expect(entries[0].workflowIdentity != entries[1].workflowIdentity)
        #expect(try ModelCatalog.entries().filter { !$0.localPreparedOnly }.count == 18)
    }

    @Test func copyAdditionDoesNotReenableAnExplicitlyRemovedSource() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let library = try await ModelLibrary(stateDirectory: f.state, catalog: [f.entry])
        try await library.configureRoot(at: f.destination)
        let selection = try await library.inspectLocalCandidates(at: f.source, validatePrepared: nil)[0]
        let original = try await library.registerLocalFiles(selection, storage: .external, validatePrepared: nil)
        try await library.unregister(original)
        let copy = try await library.registerLocalFiles(selection, storage: .managed, validatePrepared: nil)
        let snapshot = await library.snapshot()
        #expect(snapshot.records.first { $0.id == original }?.registrationState == .unregistered)
        #expect(snapshot.records.first { $0.id == copy }?.registrationState == .registered)
        #expect(snapshot.downloads.isEmpty)
        await #expect(throws: ModelLibraryError.self) { _ = try await library.inspectLocalCandidates(at: f.source, catalogID: f.entry.id, revision: "wrong", validatePrepared: nil) }
        try await library.shutdown()
    }
}


extension ModelVideoPreparationTests {
    @Test func prepareAdditionHoldsSlotAndBothIdentitiesThroughValidation() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let server = try await LoopbackServer(f)
        let raw = entry(f), eventFile = server.events
        let library = try await ModelLibrary(stateDirectory: f.state, catalog: [raw, f.entry],
            transport: URLSessionModelRangeTransport(allowsLocalHTTP: true), sourceBaseURL: server.url)
        try await library.configureRoot(at: f.destination)
        let source = try await library.registerExisting(at: f.source, catalogID: raw.id)
        let before = try ModelDirectory(f.source).entries()
        let parent = f.root.appendingPathComponent("prepared")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let output = try await library.prepareAndRegisterVideo(source, in: parent) { url in
            let current = await library.snapshot()
            let child = try #require(current.resources.first { $0.control.parentResourceID?.modelID == source })
            #expect(current.records.first { $0.id == source }?.activeLeaseCount == 1)
            #expect(child.record.activeLeaseCount == 1)
            await #expect(throws: (any Error).self) { try await library.unregister(source) }
            await #expect(throws: (any Error).self) { try await library.unregister(child.record.id) }
            await #expect(throws: (any Error).self) { try await library.remove(child.record.id) }
            _ = try await library.enqueueDownloads([f.entry.id], postAction: .filesOnly)
            #expect(await library.snapshot().downloads.first?.state == .queued)
            if FileManager.default.fileExists(atPath: eventFile.path) { #expect(try Data(contentsOf: eventFile).isEmpty) }
            return .init(directory: url, revision: "fixture-execution")
        }
        let child = try #require(try await library.preparedAdditionResource(for: source))
        let done = try #require(await library.snapshot().resources.first { $0.id == child })
        #expect(done.record.registrationState == .registered)
        #expect(done.id == output && done.record.activeLeaseCount == 0)
        #expect(try ModelDirectory(f.source).entries() == before)
        try await library.shutdown()
    }

    @Test(arguments: ["validation", "save", "cancel"])
    func prepareAdditionFailureReusesExactPublishedChildAfterColdOpen(kind: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = Mutex(false)
        let raw = entry(f)
        var library: ModelLibrary? = try await ModelLibrary(stateDirectory: f.state, catalog: [raw], checkpoint: { point in
            if point == "registration.beforeWrite", fault.withLock({ $0 }) { throw ModelLibraryError.storage("isolated registration write failure") }
        })
        let source = try await library!.registerExisting(at: f.source, catalogID: raw.id)
        let before = try ModelDirectory(f.source).entries()
        fault.withLock { $0 = kind == "save" }
        await #expect(throws: (any Error).self) {
            _ = try await library!.prepareAndRegisterVideo(source, in: f.destination) { url in
                if kind == "validation" { throw ModelLibraryError.integrity("isolated adapter validation failure") }
                if kind == "cancel" { throw CancellationError() }
                return .init(directory: url, revision: "fixture-execution")
            }
        }
        let child = try #require(try await library!.preparedAdditionResource(for: source))
        let failed = try #require(await library!.snapshot().resources.first { $0.id == child })
        #expect(failed.record.registrationState == .unregistered && failed.record.activeLeaseCount == 0)
        let output = try #require(failed.record.directory)
        let published = try ModelDirectory(output).entries()
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).count == 1)
        fault.withLock { $0 = false }
        try await library!.shutdown(); library = nil
        let cold = try await ModelLibrary(stateDirectory: f.state, catalog: [raw])
        #expect(try await cold.preparedAdditionResource(for: source) == child)
        let retry = try await cold.prepareAndRegisterVideo(source, in: f.root.appendingPathComponent("must-not-create")) {
            .init(directory: $0, revision: "fixture-execution")
        }
        #expect(retry == child)
        #expect(try ModelDirectory(output).entries() == published)
        #expect(try ModelDirectory(f.source).entries() == before)
        #expect(await cold.snapshot().resources.filter { $0.control.role == .execution }.count == 1)
        #expect(await cold.snapshot().resources.first { $0.id == child }?.record.registrationState == .registered)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("must-not-create").path))
        try await cold.shutdown()
    }
}


extension ModelVideoPreparationTests {
    @Test(arguments: ["beforeWrite", "afterRename"])
    func preparedInventoryPublicationRecoversWithoutShutdownFlush(boundary: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let blocked = Mutex(false)
        let raw = entry(f)
        var owner: ModelLibrary? = try await ModelLibrary(stateDirectory: f.state, catalog: [raw], checkpoint: { point in
            if point == "prepared." + boundary { blocked.withLock { $0 = true }; throw ModelLibraryError.storage("isolated prepared inventory failure") }
            if point.hasSuffix("beforeWrite"), blocked.withLock({ $0 }) { throw ModelLibraryError.storage("isolated persistent write failure") }
        })
        let source = try await owner!.registerExisting(at: f.source, catalogID: raw.id)
        let original = try ModelDirectory(f.source).entries()
        await #expect(throws: (any Error).self) {
            _ = try await owner!.prepareAndRegisterVideo(source, in: f.destination) { .init(directory: $0, revision: "fixture-execution") }
        }
        let child = try #require(await owner!.snapshot().resources.first { $0.control.parentResourceID?.modelID == source })
        let output = try #require(child.record.directory), files = try ModelDirectory(output).entries()
        #expect(FileManager.default.fileExists(atPath: f.state.appendingPathComponent("prepared-publication.json").path))
        // Persist remains unavailable: recovery must not rely on a successful quit flush.
        await #expect(throws: (any Error).self) { try await owner!.shutdown() }
        owner = nil
        var cold: ModelLibrary? = try await ModelLibrary(stateDirectory: f.state, catalog: [raw])
        #expect(try await cold!.preparedAdditionResource(for: source) == child.id)
        #expect(!FileManager.default.fileExists(atPath: f.state.appendingPathComponent("prepared-publication.json").path))
        let retry = try await cold!.prepareAndRegisterVideo(source, in: f.root.appendingPathComponent("unused")) {
            .init(directory: $0, revision: "fixture-execution")
        }
        #expect(retry == child.id)
        #expect(try ModelDirectory(output).entries() == files)
        #expect(try ModelDirectory(f.source).entries() == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).count == 1)
        try await cold!.shutdown(); cold = nil
        let again = try await ModelLibrary(stateDirectory: f.state, catalog: [raw])
        #expect(try await again.resolve(child.record.id).directory.standardizedFileURL.path == output.standardizedFileURL.path)
        #expect(await again.snapshot().resources.first { $0.id == child.id }?.record.registrationState == .registered)
        try await again.shutdown()
    }
}


extension ModelVideoPreparationTests {
    @Test(.timeLimit(.minutes(1))) func actualCancellationDuringPreparedAdditionKeepsPublishedFiles() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let raw = entry(f), owner = try await ModelLibrary(stateDirectory: f.state, catalog: [entry(f)])
        let source = try await owner.registerExisting(at: f.source, catalogID: raw.id)
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let request = Task {
            try await owner.prepareAndRegisterVideo(source, in: f.destination) { url in
                enter.yield(()); enter.finish()
                for await _ in released { break }
                try Task.checkCancellation()
                return .init(directory: url, revision: "fixture-execution")
            }
        }
        for await _ in entered { break }
        request.cancel(); release.yield(()); release.finish()
        await #expect(throws: CancellationError.self) { try await request.value }
        let child = try #require(try await owner.preparedAdditionResource(for: source))
        let record = try #require(await owner.snapshot().resources.first { $0.id == child })
        #expect(record.record.registrationState == .unregistered)
        #expect(await owner.snapshot().records.allSatisfy { $0.activeLeaseCount == 0 })
        #expect(FileManager.default.fileExists(atPath: try #require(record.record.directory).path))
        try await owner.shutdown()
    }
}


extension ModelVideoPreparationTests {
    @Test(arguments: ["unavailable", "replaced", "source-removed"])
    func unavailablePreparedRecoveryDoesNotBlockOtherInventory(kind: String) async throws {
        let f = try LibraryFixture(); defer { _ = chmod(f.destination.path, 0o700); f.clean() }
        let blocked = Mutex(false), raw = entry(f)
        var owner: ModelLibrary? = try await ModelLibrary(stateDirectory: f.state, catalog: [raw], checkpoint: { point in
            if point == "prepared.beforeWrite" { blocked.withLock { $0 = true }; throw ModelLibraryError.storage("fixture publication failure") }
            if point.hasSuffix("beforeWrite"), blocked.withLock({ $0 }) { throw ModelLibraryError.storage("fixture write blocked") }
        })
        let source = try await owner!.registerExisting(at: f.source, catalogID: raw.id)
        let otherFiles = f.root.appendingPathComponent("other-original")
        try f.writeModel(at: otherFiles)
        let other = try await owner!.registerExisting(at: otherFiles, catalogID: raw.id)
        await #expect(throws: (any Error).self) {
            _ = try await owner!.prepareAndRegisterVideo(source, in: f.destination) { .init(directory: $0, revision: "fixture-execution") }
        }
        let child = try #require(await owner!.snapshot().resources.first { $0.control.parentResourceID?.modelID == source })
        if kind == "source-removed" {
            blocked.withLock { $0 = false }; try await owner!.remove(source)
            blocked.withLock { $0 = true }
        }
        try? await owner!.shutdown(); owner = nil
        if kind == "unavailable" { #expect(chmod(f.destination.path, 0) == 0) }
        if kind == "replaced" {
            try FileManager.default.moveItem(at: f.destination, to: f.root.appendingPathComponent("original-destination"))
            try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)
        }
        let cold = try await ModelLibrary(stateDirectory: f.state, catalog: [raw])
        let state = await cold.snapshot()
        #expect(state.resources.contains { $0.record.id == other })
        #expect(state.resources.first { $0.id == child.id }?.record.availability == .unavailable)
        #expect(state.resources.first { $0.id == child.id }?.record.error != nil)
        #expect(FileManager.default.fileExists(atPath: f.state.appendingPathComponent("prepared-publication.json").path))
        await #expect(throws: (any Error).self) { try await cold.preparedAdditionResource(for: source) }
        if kind == "unavailable" {
            #expect(chmod(f.destination.path, 0o700) == 0)
            #expect(try await cold.preparedAdditionResource(for: source) == child.id)
            #expect(await cold.snapshot().resources.first { $0.id == child.id }?.record.error == nil)
        }
        try await cold.shutdown()
    }
}


extension ModelVideoPreparationTests {
    @Test(arguments: ["remove", "unregister", "register"])
    func pendingPreparedPublicationCannotResurrectExplicitCommands(action: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fail = Mutex(true), raw = entry(f)
        var owner: ModelLibrary? = try await ModelLibrary(stateDirectory: f.state, catalog: [raw], checkpoint: { point in
            if point == "prepared.beforeWrite", fail.withLock({ $0 }) { throw ModelLibraryError.storage("fixture inventory failure") }
        })
        let source = try await owner!.registerExisting(at: f.source, catalogID: raw.id)
        await #expect(throws: (any Error).self) {
            _ = try await owner!.prepareAndRegisterVideo(source, in: f.destination) { .init(directory: $0, revision: "fixture-execution") }
        }
        let child = try #require(await owner!.snapshot().resources.first { $0.control.parentResourceID?.modelID == source })
        // Removal cannot claim success while its exact durable publication is blocked.
        await #expect(throws: (any Error).self) { try await owner!.remove(child.record.id) }
        #expect(await owner!.snapshot().resources.contains { $0.id == child.id })
        fail.withLock { $0 = false }
        switch action {
        case "remove": try await owner!.remove(child.record.id)
        case "unregister": try await owner!.unregister(child.record.id)
        default: try await owner!.registerPreparedResource(child.id) { .init(directory: $0, revision: "fixture-execution") }
        }
        #expect(!FileManager.default.fileExists(atPath: f.state.appendingPathComponent("prepared-publication.json").path))
        try await owner!.shutdown(); owner = nil
        let cold = try await ModelLibrary(stateDirectory: f.state, catalog: [raw])
        let current = await cold.snapshot().resources.first { $0.id == child.id }
        if action == "remove" { #expect(current == nil) }
        else { #expect(current?.record.registrationState == (action == "register" ? .registered : .unregistered)) }
        #expect(FileManager.default.fileExists(atPath: try #require(child.record.directory).path))
        try await cold.shutdown()
    }
}
