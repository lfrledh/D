import Foundation
import Testing
@testable import DWorkbench

@Suite(.serialized)
struct ModelVideoPreparationTests {
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
