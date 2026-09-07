import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DWorkbench

@Suite(.serialized)
struct ModelLibraryTests {
    @Test func bundledCatalogMatchesCanonicalBackendManifest() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let canonical = repo.appendingPathComponent("Backends/MLX/Sources/DMLXBackend/Resources/flux2-klein-model.json")
        let copy = repo.appendingPathComponent("Packages/UI/Sources/DWorkbench/Models/Resources/flux2-klein-model.json")
        #expect(try Data(contentsOf: canonical) == Data(contentsOf: copy))
        let entry = try ModelCatalog.flux2()
        #expect(entry.files.count == 18)
        #expect(entry.totalBytes == 9_426_536_934)
    }

    @Test(arguments: ["status", "range", "length", "missing-length", "encoding", "short"])
    func strictHTTPRangeValidation(mode: String) async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture, mode: mode)
        let output = fixture.root.appendingPathComponent("range-output")
        let fd = Darwin.open(output.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        defer { Darwin.close(fd) }
        let transport = URLSessionModelRangeTransport(allowsLocalHTTP: true)
        await #expect(throws: (any Error).self) {
            try await transport.download(.init(url: server.url.appendingPathComponent("weights/payload.bin"), start: 0, end: 4095, total: 4096), to: fd)
        }
        let count = try Data(contentsOf: output).count
        if mode != "short" { #expect(count == 0) }
        else { #expect(count < 4096) }
    }

    @Test func installsVerifiedTreeThenOwnedRemoval() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture)
        let library = try await fixture.library(server: server)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: fixture.entry.id)
        let installed = try await waitRecord(library, id: id) { [.installed, .failed].contains($0.state) }
        #expect(installed.state == .installed, "\(installed.error ?? "")")
        let url = try #require(installed.directory)
        #expect(try ModelDirectory(url).verify(fixture.entry.files).count == 2)
        #expect(try ModelDirectory(url).entries().keys.sorted() == fixture.contents.keys.sorted())
        let pin = try await library.acquire(id)
        await #expect(throws: ModelLibraryError.self) { try await library.remove(id) }
        await library.release(pin)
        try await library.remove(id)
        #expect(await library.snapshot().records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let active = try server.eventRows().compactMap { $0["active"] as? Int }
        #expect(active.max() ?? 0 <= 2)
        try await library.shutdown()
    }

    @Test func pauseShutdownReopenAndResumeFromDurableRange() async throws {
        let fixture = try LibraryFixture(large: true); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture, mode: "gate")
        var library: ModelLibrary? = try await fixture.library(server: server)
        try await library!.configureRoot(at: fixture.destination)
        let id = try await library!.install(catalogID: fixture.entry.id)
        _ = try await waitRecord(library!, id: id) { $0.downloadedBytes >= 16 * 1024 * 1024 && $0.state == .downloading }
        let partial = fixture.destination.appendingPathComponent(".d-model-library/Staging/" + id.description + "/Content/weights/payload.bin")
        for _ in 0..<200 {
            let size = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if size > 16 * 1024 * 1024 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect((try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0 > 16 * 1024 * 1024)
        try await library!.pause(id)
        let paused = try #require(await library!.snapshot().records.first)
        #expect(paused.state == .paused)
        #expect(paused.downloadedBytes < paused.totalBytes)
        try await library!.shutdown(); library = nil
        let reopened = try await fixture.library(server: server)
        #expect(await reopened.snapshot().records.first?.id == id)
        #expect(await reopened.snapshot().records.first?.state == .paused)
        let eventCount = try server.eventRows().filter { $0["event"] as? String == "start" }.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(try server.eventRows().filter { $0["event"] as? String == "start" }.count == eventCount)
        try server.setMode("valid")
        try await reopened.resume(id)
        let finished = try await waitRecord(reopened, id: id) { [.installed, .failed].contains($0.state) }
        #expect(finished.state == .installed, "\(finished.error ?? "")")
        let starts = try server.eventRows().filter { ($0["event"] as? String) == "start" && ($0["path"] as? String) == "weights/payload.bin" }
        #expect(starts.filter { ($0["start"] as? Int) == 0 }.count == 1)
        #expect(starts.filter { ($0["start"] as? Int) == 16 * 1024 * 1024 }.count >= 1)
        try await reopened.shutdown()
    }

    @Test func corruptDownloadRequiresRestartThenRecovers() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture, mode: "corrupt")
        let library = try await fixture.library(server: server)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: fixture.entry.id)
        let failed = try await waitRecord(library, id: id) { $0.state == .failed }
        #expect(failed.error?.contains("SHA-256") == true)
        await #expect(throws: ModelLibraryError.self) { _ = try await library.acquire(id) }
        try server.setMode("valid")
        try await library.restart(id)
        let installed = try await waitRecord(library, id: id) { [.installed, .failed].contains($0.state) }
        #expect(installed.state == .installed, "\(installed.error ?? "")")
        try await library.shutdown()
    }

    @Test func failedDownloadCanDiscardOnlyItsStaging() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture, mode: "status")
        let library = try await fixture.library(server: server)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: fixture.entry.id)
        _ = try await waitRecord(library, id: id) { $0.state == .failed }
        try await library.remove(id)
        #expect(await library.snapshot().records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent(".d-model-library/Staging/" + id.description).path))
        try await library.shutdown()
    }

    @Test func externalRebindFailureKeepsPriorModelAndUnregisterKeepsFiles() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let library = try await fixture.library()
        let id = try await library.registerExisting(at: fixture.source, catalogID: fixture.entry.id)
        let bad = fixture.root.appendingPathComponent("bad"); try fixture.writeModel(at: bad)
        try Data(repeating: 0, count: 4096).write(to: bad.appendingPathComponent("weights/payload.bin"))
        await #expect(throws: ModelLibraryError.self) { try await library.rebind(id, to: bad) }
        #expect(try await library.resolve(id).directory.path == fixture.source.path)
        let pin = try await library.acquire(id)
        await #expect(throws: ModelLibraryError.self) { try await library.shutdown() }
        // Failed shutdown restores admission and retains security scope for retry.
        #expect(try await library.resolve(id).directory.path == fixture.source.path)
        await library.release(pin)
        try await library.remove(id)
        #expect(try ModelDirectory(fixture.source).verify(fixture.entry.files).count == 2)
        try await library.shutdown()
    }

    @Test func sameAndMovedRootReuseLockAndIdentity() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let library = try await fixture.library()
        try await library.configureRoot(at: fixture.destination)
        try await library.configureRoot(at: fixture.destination)
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: fixture.destination, to: moved)
        try await library.configureRoot(at: moved)
        #expect(await library.snapshot().rootURL?.path == moved.path)
        try await library.shutdown()
    }

    @Test func copiedRootRejectedWhileSameFilesystemMoveRetainsInstalledModel() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture)
        let library = try await fixture.library(server: server)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: fixture.entry.id)
        #expect(try await waitRecord(library, id: id) { [.installed, .failed].contains($0.state) }.state == .installed)
        let original = try await library.resolve(id)
        let copied = fixture.root.appendingPathComponent("copied")
        try FileManager.default.copyItem(at: fixture.destination, to: copied)
        await #expect(throws: ModelLibraryError.self) { try await library.configureRoot(at: copied) }
        #expect(try await library.resolve(id).directory.path == original.directory.path)
        #expect(await library.snapshot().rootURL?.path == fixture.destination.path)
        let copiedModel = copied.appendingPathComponent(".d-model-library/Installations/" + id.description)
        #expect(try ModelDirectory(copiedModel).verify(fixture.entry.files).count == 2)
        let moved = fixture.root.appendingPathComponent("moved-original")
        try FileManager.default.moveItem(at: fixture.destination, to: moved)
        try await library.configureRoot(at: moved)
        #expect(try await library.resolve(id).directory.path.hasPrefix(moved.path + "/"))
        #expect(await library.snapshot().records.first?.availability == .available)
        try await library.shutdown()
    }

    @Test func legacyIndexRejectsCopiedRootAndCanReauthorizeOriginal() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture)
        var library: ModelLibrary? = try await fixture.library(server: server)
        try await library!.configureRoot(at: fixture.destination)
        let id = try await library!.install(catalogID: fixture.entry.id)
        let installed = try await waitRecord(library!, id: id) { [.installed, .failed].contains($0.state) }
        try #require(installed.state == .installed, "Fixture installation failed: \(installed.error ?? "no error details"); HTTP peer: \(server.url)")
        try await library!.shutdown(); library = nil
        let copied = fixture.root.appendingPathComponent("copied")
        try FileManager.default.copyItem(at: fixture.destination, to: copied)
        let indexURL = fixture.state.appendingPathComponent("index.json")
        var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        index.removeValue(forKey: "rootIdentity")
        index["rootURL"] = copied.absoluteString
        index["rootBookmark"] = try copied.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL)
        let reopened = try await fixture.library(server: server)
        #expect(await reopened.snapshot().records.first?.availability == .unavailable)
        await #expect(throws: ModelLibraryError.self) { _ = try await reopened.resolve(id) }
        try await reopened.configureRoot(at: fixture.destination)
        #expect(try await reopened.resolve(id).directory.path.hasPrefix(fixture.destination.path + "/"))
        #expect(await reopened.snapshot().records.first?.id == id)
        try await reopened.shutdown()
    }

    @Test func reauthorizingMovedPartialLibraryRestoresResumeAvailability() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture, mode: "status")
        let library = try await fixture.library(server: server)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: fixture.entry.id)
        _ = try await waitRecord(library, id: id) { $0.state == .failed }
        let moved = fixture.root.appendingPathComponent("moved-original")
        try FileManager.default.moveItem(at: fixture.destination, to: moved)
        #expect(await library.snapshot().records.first?.availability == .unavailable)
        try await library.configureRoot(at: moved)
        #expect(await library.snapshot().records.first?.availability == .available)
        try server.setMode("valid")
        try await library.resume(id)
        #expect(try await waitRecord(library, id: id) { [.installed, .failed].contains($0.state) }.state == .installed)
        try await library.shutdown()
    }

    @Test func ownershipAndIdentityGuards() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let library = try await fixture.library()
        let id = try await library.registerExisting(at: fixture.source, catalogID: fixture.entry.id)
        let old = fixture.root.appendingPathComponent("old")
        try FileManager.default.moveItem(at: fixture.source, to: old)
        try fixture.writeModel(at: fixture.source)
        #expect(await library.snapshot().records.first?.availability == .unavailable)
        await #expect(throws: ModelLibraryError.self) { _ = try await library.acquire(id) }
        let unknownRoot = fixture.destination.appendingPathComponent(".d-model-library/unknown-empty")
        try FileManager.default.createDirectory(at: unknownRoot, withIntermediateDirectories: true)
        await #expect(throws: ModelLibraryError.self) { try await library.configureRoot(at: fixture.destination) }
        #expect(FileManager.default.fileExists(atPath: unknownRoot.path))
        try await library.shutdown()
    }

    @Test(arguments: ["symlink", "hardlink", "empty-directory", "extra-file"])
    func verificationRejectsUnknownContent(kind: String) async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let extra = fixture.source.appendingPathComponent("unknown")
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: fixture.source.appendingPathComponent("config.json"))
        case "hardlink": try FileManager.default.linkItem(at: fixture.source.appendingPathComponent("config.json"), to: extra)
        case "empty-directory": try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        default: try Data("unknown".utf8).write(to: extra)
        }
        let library = try await fixture.library()
        await #expect(throws: ModelLibraryError.self) { _ = try await library.registerExisting(at: fixture.source, catalogID: fixture.entry.id) }
        #expect(await library.snapshot().records.first?.state == .failed)
        #expect(FileManager.default.fileExists(atPath: extra.path))
        try await library.shutdown()
    }

    @Test func insufficientSpaceCreatesNoInstallationRecord() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let library = try await fixture.library(availableBytes: 1)
        try await library.configureRoot(at: fixture.destination)
        await #expect(throws: ModelLibraryError.self) { _ = try await library.install(catalogID: fixture.entry.id) }
        #expect(await library.snapshot().records.isEmpty)
        try await library.shutdown()
    }

    @Test func secondStateOwnerRejected() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let library = try await fixture.library()
        await #expect(throws: ModelLibraryError.self) { _ = try await fixture.library() }
        try await library.shutdown()
    }

    @Test func registrationPauseIsTypedAndCanResumeFullVerification() async throws {
        let fixture = try LibraryFixture(payloadBytes: 128 * 1024 * 1024); defer { fixture.clean() }
        let library = try await fixture.library()
        let registration = Task { try await library.registerExisting(at: fixture.source, catalogID: fixture.entry.id) }
        var candidate: ModelID?
        for _ in 0..<1000 {
            if let record = await library.snapshot().records.first { candidate = record.id; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let id = try #require(candidate)
        try await library.pause(id)
        do { _ = try await registration.value; Issue.record("Registration should report its requested pause") }
        catch ModelLibraryError.operationPaused { }
        #expect(await library.snapshot().records.first?.state == .paused)
        try await library.resume(id)
        #expect(try await waitRecord(library, id: id) { [.installed, .failed].contains($0.state) }.state == .installed)
        try await library.shutdown()
    }

    @Test func rebindIndexFailureRestoresAdmissionAndOriginalLocation() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let library = try await fixture.library()
        let id = try await library.registerExisting(at: fixture.source, catalogID: fixture.entry.id)
        let candidate = fixture.root.appendingPathComponent("candidate"); try fixture.writeModel(at: candidate)
        let index = fixture.state.appendingPathComponent("index.json"), backup = fixture.state.appendingPathComponent("index.backup")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        await #expect(throws: ModelLibraryError.self) { try await library.rebind(id, to: candidate) }
        #expect(await library.snapshot().records.first?.state == .installed)
        #expect(try await library.resolve(id).directory.path == fixture.source.path)
        try FileManager.default.removeItem(at: index); try FileManager.default.moveItem(at: backup, to: index)
        try await library.shutdown()
    }

    @Test func finalRebindIndexFailureRetainsVerifiedOriginal() async throws {
        let fixture = try LibraryFixture(payloadBytes: 128 * 1024 * 1024); defer { fixture.clean() }
        let library = try await fixture.library()
        let id = try await library.registerExisting(at: fixture.source, catalogID: fixture.entry.id)
        let candidate = fixture.root.appendingPathComponent("candidate"); try fixture.writeModel(at: candidate)
        let rebinding = Task { try await library.rebind(id, to: candidate) }
        _ = try await waitRecord(library, id: id) { $0.state == .verifying }
        let index = fixture.state.appendingPathComponent("index.json"), backup = fixture.state.appendingPathComponent("index.backup")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        await #expect(throws: ModelLibraryError.self) { try await rebinding.value }
        #expect(await library.snapshot().records.first?.state == .installed)
        #expect(try await library.resolve(id).directory.path == fixture.source.path)
        try FileManager.default.removeItem(at: index); try FileManager.default.moveItem(at: backup, to: index)
        try await library.shutdown()
    }

    @Test func rootPersistenceFailureRetainsPreviousRoot() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let library = try await fixture.library()
        try await library.configureRoot(at: fixture.destination)
        let candidate = fixture.root.appendingPathComponent("candidate")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        let index = fixture.state.appendingPathComponent("index.json"), backup = fixture.state.appendingPathComponent("index.backup")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        await #expect(throws: ModelLibraryError.self) { try await library.configureRoot(at: candidate) }
        #expect(await library.snapshot().rootURL?.path == fixture.destination.path)
        try FileManager.default.removeItem(at: index); try FileManager.default.moveItem(at: backup, to: index)
        try await library.configureRoot(at: fixture.destination)
        try await library.shutdown()
    }

    @Test func repeatedRemovalNeverForgetsChangedPublishedFiles() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture)
        let library = try await fixture.library(server: server)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: fixture.entry.id)
        let installed = try await waitRecord(library, id: id) { [.installed, .failed].contains($0.state) }
        let url = try #require(installed.directory)
        try Data(repeating: 1, count: 4096).write(to: url.appendingPathComponent("weights/payload.bin"))
        for _ in 0..<2 {
            await #expect(throws: ModelLibraryError.self) { try await library.remove(id) }
            #expect(await library.snapshot().records.first?.id == id)
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("weights/payload.bin").path))
        }
        await #expect(throws: ModelLibraryError.self) { try await library.restart(id) }
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("weights/payload.bin").path))
        try await library.shutdown()
    }

    @Test func existingPublicationIsNeverOverwrittenOrForgotten() async throws {
        let fixture = try LibraryFixture(large: true); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture, mode: "slow")
        let library = try await fixture.library(server: server)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: fixture.entry.id)
        _ = try await waitRecord(library, id: id) { $0.state == .downloading }
        let unknown = fixture.destination.appendingPathComponent(".d-model-library/Installations/" + id.description)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let marker = unknown.appendingPathComponent("user-file")
        try Data("preserve".utf8).write(to: marker)
        _ = try await waitRecord(library, id: id) { $0.state == .failed }
        await #expect(throws: ModelLibraryError.self) { try await library.remove(id) }
        #expect(await library.snapshot().records.first?.id == id)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "preserve")
        try await library.shutdown()
    }

    @Test func restartAndRemovalRejectHardlinkedStaging() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let server = try await LoopbackServer(fixture, mode: "status")
        let library = try await fixture.library(server: server)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: fixture.entry.id)
        _ = try await waitRecord(library, id: id) { $0.state == .failed }
        let partial = fixture.destination.appendingPathComponent(".d-model-library/Staging/" + id.description + "/Content/config.json")
        let outside = fixture.root.appendingPathComponent("outside-link")
        try FileManager.default.linkItem(at: partial, to: outside)
        await #expect(throws: ModelLibraryError.self) { try await library.restart(id) }
        await #expect(throws: ModelLibraryError.self) { try await library.remove(id) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: partial.path))
        try await library.shutdown()
    }

    @Test(arguments: ["../escape", "/absolute", "x//y", "x/./y", "x\\y"])
    func rejectsCatalogPathEscapes(path: String) async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let entry = ModelCatalogEntry(id: "bad", title: "bad", repository: "fixture/model", revision: fixture.entry.revision,
            files: [.init(path: path, size: 1, sha256: String(repeating: "0", count: 64))], imageProfile: .flux2Klein)
        await #expect(throws: ModelLibraryError.self) { _ = try await ModelLibrary(stateDirectory: fixture.state, catalog: [entry]) }
    }
}
