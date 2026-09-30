import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DWorkbench

@Suite(.serialized)
struct ReleaseModelCatalogTests {
    @Test func normalizedCatalogUsesProcessedResourcePath() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resource = repo.appendingPathComponent("Packages/UI/Sources/DWorkbench/Models/Resources/release-model-catalog.json")
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any]
        let bundledCount = try ModelCatalog.entries().count
        #expect(source?["schemaVersion"] as? Int == 1)
        #expect((source?["entries"] as? [[String: Any]])?.count == bundledCount)
    }

    @Test func verifiedWorkflowChoicesRequireKnownRouteAndNoPreparation() throws {
        let entries = try ModelCatalog.entries()
        func record(_ entry: ModelCatalogEntry) -> ModelRecord {
            .init(id: ModelID(), catalogID: entry.id, revision: entry.revision, storage: .managed,
                  state: .installed, availability: .available, downloadedBytes: entry.totalBytes,
                  totalBytes: entry.totalBytes, error: nil, directory: nil, activeLeaseCount: 0)
        }
        for id in ["qwen35-9b-q4", "mrt2-small-export-v1", "flux2-dev-bf16", "flux2-klein-4b-bf16"] {
            let entry = try #require(entries.first { $0.id == id })
            #expect(ModelLibrarySelection.canUse(record(entry), entry: entry, hasPendingAction: false))
            #expect(!ModelLibrarySelection.canUse(record(entry), entry: entry, hasPendingAction: true))
        }
        for id in ["minimax-h3-fl2va-bf16", "ltx-2.5-bf16", "wan21-t2v-1.3b-bf16"] {
            let entry = try #require(entries.first { $0.id == id })
            #expect(!ModelLibrarySelection.canUse(record(entry), entry: entry, hasPendingAction: false))
        }
        let qwen = try #require(entries.first { $0.id == "qwen35-9b-q4" })
        let absentRoute = ModelCatalogEntry(id: qwen.id, title: qwen.title, repository: qwen.repository,
            revision: qwen.revision, files: qwen.files, workflowProfileID: "d.model.unknown",
            workflowIdentity: qwen.workflowIdentity)
        #expect(!ModelLibrarySelection.canUse(record(absentRoute), entry: absentRoute, hasPendingAction: false))
        let wrongIdentity = ModelCatalogEntry(id: qwen.id, title: qwen.title, repository: qwen.repository,
            revision: qwen.revision, files: qwen.files, workflowProfileID: WorkflowModelRoutes.qwen35,
            workflowIdentity: "text:other-revision")
        #expect(!ModelLibrarySelection.canUse(record(wrongIdentity), entry: wrongIdentity, hasPendingAction: false))
        let klein = try ModelCatalog.flux2()
        let legacy = ModelCatalogEntry(id: klein.id, title: klein.title, repository: klein.repository,
                                       revision: klein.revision, files: klein.files, imageProfile: .flux2Klein)
        #expect(ModelLibrarySelection.canUse(record(legacy), entry: legacy, hasPendingAction: false))
        var notInstalled = record(legacy)
        notInstalled.state = .preparationRequired
        #expect(!ModelLibrarySelection.canUse(notInstalled, entry: legacy, hasPendingAction: false))
        notInstalled.state = .installed
        notInstalled.availability = .unavailable
        #expect(!ModelLibrarySelection.canUse(notInstalled, entry: legacy, hasPendingAction: false))
    }

    @Test func allFrozenProfilesAndPinsArePresent() throws {
        let entries = try ModelCatalog.entries()
        #expect(entries.count == 12)
        #expect(Set(entries.map(\.id)).count == 12)
        for id in ["qwen35-9b-bf16", "qwen35-9b-q4", "qwen38-27b-bf16", "qwen38-27b-q4",
                   "flux2-klein-4b-q8", "flux2-klein-4b-bf16", "flux2-dev-bf16",
                   "minimax-h3-fl2va-bf16", "ltx-2.5-bf16", "wan21-t2v-1.3b-bf16",
                   "mrt2-small-export-v1", "ace-step-1.5-xl-sft-f32-no-lm"] {
            #expect(entries.contains { $0.id == id })
        }
        #expect(entries.first { $0.id == "qwen35-9b-bf16" }?.revision == "c202236235762e1c871ad0ccb60c8ee5ba337b9a")
        #expect(entries.first { $0.id == "flux2-dev-bf16" }?.revision == "26afe3a78bb242c0a8bb181dcc8937bb16e5c66c")
        #expect(entries.first { $0.id == "wan21-t2v-1.3b-bf16" }?.preparation == .required)
        #expect(entries.first { $0.id == "minimax-h3-fl2va-bf16" }?.preparation == .required)
        #expect(entries.first { $0.id == "ltx-2.5-bf16" }?.preparation == .required)
        let qwen27 = try #require(entries.first { $0.id == "qwen38-27b-bf16" })
        #expect(qwen27.files.contains { $0.size > 16 * 1024 * 1024 * 1024 })
        let ace = try #require(entries.first { $0.id == "ace-step-1.5-xl-sft-f32-no-lm" })
        #expect(ace.files.count == 22)
        #expect(ace.files.contains { $0.sourceRepository == "ACE-Step/Ace-Step1.5" && $0.path.hasPrefix("checkpoints/vae/") })
        #expect(ace.files.contains { $0.sourceRepository == "ACE-Step/acestep-v15-xl-sft" && $0.remotePath == "config.json" })
        #expect(entries.allSatisfy { !$0.files.isEmpty && $0.provenance != nil })
    }

    @Test func legacyFileAndEntryCodableDefaults() throws {
        let oldFile = Data(#"{"path":"config.json","size":3,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8)
        let file = try JSONDecoder().decode(ModelFile.self, from: oldFile)
        #expect(file.digestAlgorithm == .sha256)
        #expect(file.sourceRepository == nil && file.sourceRevision == nil && file.remotePath == nil)
        let encoded = try JSONEncoder().encode(file)
        #expect(try JSONDecoder().decode(ModelFile.self, from: encoded) == file)
        let oldEntry = try ModelCatalog.flux2()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldEntry)) as! [String: Any]
        var legacy = object
        for key in ["workflowProfileID", "workflowIdentity", "preparation", "modelSpec", "memoryGuidance", "provenance"] {
            legacy.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(ModelCatalogEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.imageProfile != nil)
        #expect(decoded.preparation == .none)
        #expect(decoded.files.count == 18)
    }

    @Test func verifiesSHA256AndGitBlobSHA1() throws {
        let fixture = try ReleaseLibraryFixture(); defer { fixture.clean() }
        let model = fixture.root.appendingPathComponent("mixed")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let a = Data("sha-data".utf8), b = Data("git-data".utf8)
        try a.write(to: model.appendingPathComponent("a.bin"))
        try b.write(to: model.appendingPathComponent("b.bin"))
        let files = [ModelFile(path: "a.bin", size: UInt64(a.count), sha256: ReleaseLibraryFixture.sha256(a)),
                     ModelFile(path: "b.bin", size: UInt64(b.count), sha256: ReleaseLibraryFixture.gitBlob(b), digestAlgorithm: .gitBlobSHA1)]
        #expect(try ModelDirectory(model).verify(files).count == 2)
        var corrupt = b; corrupt[0] ^= 1
        try corrupt.write(to: model.appendingPathComponent("b.bin"))
        #expect(throws: ModelLibraryError.self) { try ModelDirectory(model).verify(files) }
    }

    @Test func separateRepositoriesWithSameFilenameInstallAtDistinctDestinations() async throws {
        let fixture = try ReleaseLibraryFixture(); defer { fixture.clean() }
        let a = Data("first".utf8), b = Data("second".utf8)
        let revision = String(repeating: "a", count: 40)
        let files = [
            ModelFile(path: "first/shared.bin", size: UInt64(a.count), sha256: ReleaseLibraryFixture.sha256(a),
                      sourceRepository: "source/first", sourceRevision: revision, remotePath: "shared.bin"),
            ModelFile(path: "second/shared.bin", size: UInt64(b.count), sha256: ReleaseLibraryFixture.sha256(b),
                      sourceRepository: "source/second", sourceRevision: revision, remotePath: "shared.bin")]
        let entry = ModelCatalogEntry(id: "mixed", title: "Mixed", repository: "source/main", revision: revision, files: files)
        let prefix = "/source/"
        let transport = ReleaseFixtureTransport(contents: [
            prefix + "first/resolve/" + revision + "/shared.bin": a,
            prefix + "second/resolve/" + revision + "/shared.bin": b])
        let library = try await fixture.library([entry], transport: transport)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: entry.id)
        let record = try await releaseWait(library, id: id)
        #expect(record.state == .installed, "\(record.error ?? "")")
        let installed = try #require(record.directory)
        #expect(try Data(contentsOf: installed.appendingPathComponent("first/shared.bin")) == a)
        #expect(try Data(contentsOf: installed.appendingPathComponent("second/shared.bin")) == b)
        #expect(await transport.paths.count == 2)
        try await library.shutdown()
    }

    @Test func preparationRequiredHasNoRunnableLeaseAndWrongImportFails() async throws {
        let fixture = try ReleaseLibraryFixture(); defer { fixture.clean() }
        let data = Data("raw".utf8)
        let file = ModelFile(path: "raw.bin", size: UInt64(data.count), sha256: ReleaseLibraryFixture.sha256(data))
        let entry = ModelCatalogEntry(id: "needs-preparation", title: "Raw", repository: "source/raw",
                                      revision: String(repeating: "b", count: 40), files: [file], preparation: .required)
        let transport = ReleaseFixtureTransport(contents: [
            "/source/raw/resolve/" + entry.revision + "/raw.bin": data])
        let library = try await fixture.library([entry], transport: transport)
        try await library.configureRoot(at: fixture.destination)
        let id = try await library.install(catalogID: entry.id)
        #expect(try await releaseWait(library, id: id).state == .preparationRequired)
        await #expect(throws: ModelLibraryError.self) { try await library.acquire(id) }
        let source = fixture.root.appendingPathComponent("wrong-import")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: source.appendingPathComponent("raw.bin"))
        await #expect(throws: ModelLibraryError.self) {
            try await library.registerExisting(at: source, catalogID: entry.id)
        }
        try await library.shutdown()
    }

    @Test func changedComponentRecipeCannotReopenSameRevision() async throws {
        let fixture = try ReleaseLibraryFixture(); defer { fixture.clean() }
        let data = Data("fixed".utf8), revision = String(repeating: "c", count: 40)
        let first = ModelCatalogEntry(id: "recipe", title: "Recipe", repository: "source/main", revision: revision,
            files: [ModelFile(path: "model.bin", size: UInt64(data.count), sha256: ReleaseLibraryFixture.sha256(data),
                              sourceRepository: "source/component", sourceRevision: revision, remotePath: "model.bin")])
        let transport = ReleaseFixtureTransport(contents: [
            "/source/component/resolve/" + revision + "/model.bin": data])
        do {
            let library = try await fixture.library([first], transport: transport)
            try await library.configureRoot(at: fixture.destination)
            let id = try await library.install(catalogID: first.id)
            #expect(try await releaseWait(library, id: id).state == .installed)
            try await library.shutdown()
        }
        let changed = ModelCatalogEntry(id: first.id, title: first.title, repository: first.repository, revision: first.revision,
            files: [ModelFile(path: "model.bin", size: UInt64(data.count), sha256: ReleaseLibraryFixture.sha256(data),
                              sourceRepository: "source/other", sourceRevision: revision, remotePath: "model.bin")])
        do {
            _ = try await fixture.library([changed], transport: transport)
            Issue.record("Changed component reopened an existing recipe")
        } catch ModelLibraryError.integrity(let message) {
            #expect(message.contains("配方"))
        } catch {
            Issue.record("Expected changed recipe rejection, got \(error)")
        }
    }

    @Test(arguments: [401, 403])
    func deniedHTTPIsTypedAccessError(status: Int) async throws {
        let fixture = try ReleaseLibraryFixture(); defer { fixture.clean() }
        let server = try await ReleaseDeniedHTTPFixture(root: fixture.root, status: status)
        let output = fixture.root.appendingPathComponent("denied-output-\(status)")
        let fd = Darwin.open(output.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        defer { Darwin.close(fd) }
        guard fd >= 0 else { throw ModelLibraryError.storage("Fixture output could not be opened") }
        do {
            try await URLSessionModelRangeTransport(allowsLocalHTTP: true).download(
                .init(url: server.url, start: 0, end: 2, total: 3), to: fd)
            Issue.record("HTTP \(status) was accepted")
        } catch ModelLibraryError.accessDenied(let message) {
            #expect(message.contains(String(status)))
        } catch {
            Issue.record("Expected accessDenied for HTTP \(status), got \(error)")
        }
    }

    @Test func unsafeOrUnboundedCatalogIsRejectedBeforeStateWrite() async throws {
        let fixture = try ReleaseLibraryFixture(); defer { fixture.clean() }
        let revision = String(repeating: "a", count: 40)
        let digest = String(repeating: "b", count: 64)
        let invalid = [
            ModelCatalogEntry(id: "unsafe", title: "Unsafe", repository: "source/main", revision: revision,
                files: [ModelFile(path: "safe.bin", size: 1, sha256: digest, remotePath: "../escape")]),
            ModelCatalogEntry(id: "overflow", title: "Overflow", repository: "source/main", revision: revision,
                files: [ModelFile(path: "huge.bin", size: UInt64.max, sha256: digest)])]
        for entry in invalid {
            await #expect(throws: ModelLibraryError.self) {
                _ = try await fixture.library([entry], transport: ReleaseFixtureTransport(contents: [:]))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
    }
}
