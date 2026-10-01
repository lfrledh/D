import Darwin
import Foundation
import Synchronization
import Testing
@testable import DWorkbench

@Suite(.serialized)
struct ModelDownloadCredentialTests {
    private actor HoldingTransport: ModelRangeTransport {
        private var entered = false
        func download(_ range: ModelByteRange, to descriptor: Int32) async throws {
            entered = true
            try await Task.sleep(for: .seconds(30))
        }
        func hasEntered() -> Bool { entered }
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-credential-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func tokenReaderRejectsUnsafeFilesAndRedactsErrors() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = root.appendingPathComponent("fake-token")
        try Data("hf_fake_test_only".utf8).write(to: token)
        #expect(try ModelDownloadCredential.read(at: token) == "hf_fake_test_only")

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: token)
        #expect(throws: ModelLibraryError.self) { try ModelDownloadCredential.read(at: link) }
        #expect(throws: ModelLibraryError.self) { try ModelDownloadCredential.choose(link) }
        let replaced = root.appendingPathComponent("replaced")
        try Data("hf_old_fake".utf8).write(to: replaced)
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: token)
        #expect(throws: ModelLibraryError.self) { try ModelDownloadCredential.read(at: replaced) }

        for bytes in [Data(), Data(repeating: 65, count: ModelDownloadCredential.maximumBytes + 1),
                      Data("hf_secret_SENTINEL\n".utf8), Data("hf_secret_SENTINEL\u{2028}".utf8),
                      Data("hf_secret_SENTINEL\0".utf8), Data([0xFF])] {
            try bytes.write(to: token)
            do {
                _ = try ModelDownloadCredential.read(at: token)
                Issue.record("Unsafe token was accepted")
            } catch {
                #expect(!error.localizedDescription.contains("SENTINEL"))
                #expect(!error.localizedDescription.contains(token.path))
            }
        }
    }

    @Test func redirectsKeepOnlyWhitelistedHeadersAndNeverReattachToken() throws {
        let origin = try #require(URL(string: "https://huggingface.co:443/owner/repo/resolve/rev/file.bin?download=true"))
        let path = origin.path
        var range = ModelByteRange(url: origin, start: 4, end: 7, total: 12)
        range.authorizedPath = path
        let token = "hf_fake_SENTRY"
        let initial = ModelDownloadRequestPolicy.request(url: origin, range: range, token: token)
        #expect(initial.httpMethod == "GET")
        #expect(initial.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
        #expect(initial.value(forHTTPHeaderField: "Range") == "bytes=4-7")
        #expect(initial.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(initial.allHTTPHeaderFields?.count == 3)

        var allowed = true
        let same = ModelDownloadRequestPolicy.redirect(to: origin, range: range, token: token,
                                                        mayAuthenticate: &allowed)
        #expect(same?.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
        let cdn = try #require(URL(string: "https://cdn.example:443/blob"))
        let offsite = ModelDownloadRequestPolicy.redirect(to: cdn, range: range, token: token,
                                                           mayAuthenticate: &allowed)
        #expect(offsite?.allHTTPHeaderFields?.count == 2)
        #expect(offsite?.value(forHTTPHeaderField: "Authorization") == nil)
        let bounce = ModelDownloadRequestPolicy.redirect(to: origin, range: range, token: token,
                                                          mayAuthenticate: &allowed)
        #expect(bounce?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!allowed)
    }

    @Test func lookalikesDowngradeUserInfoAndOtherPortsAreRejected() throws {
        let path = "/owner/repo/resolve/rev/file.bin"
        for text in ["https://huggingface.co.evil.test\(path)", "https://user@huggingface.co\(path)",
                     "https://huggingface.co:444\(path)", "http://huggingface.co\(path)",
                     "https://huggingface.co/owner/repo/tree/rev/file.bin"] {
            #expect(!ModelDownloadRequestPolicy.isHuggingFaceResolve(URL(string: text), path: path))
        }
        var range = ModelByteRange(url: try #require(URL(string: "https://huggingface.co\(path)")),
                                   start: 0, end: 2, total: 3)
        range.authorizedPath = path
        for text in ["http://cdn.example/blob", "https://user@cdn.example/blob", "https://cdn.example:444/blob"] {
            var allowed = true
            #expect(ModelDownloadRequestPolicy.redirect(to: URL(string: text), range: range,
                token: "hf_fake", mayAuthenticate: &allowed) == nil)
        }
    }

    @Test func delegateRedirectsRebuildRequestsWithoutNetwork() throws {
        let origin = try #require(URL(string: "https://huggingface.co/owner/repo/resolve/rev/file"))
        var range = ModelByteRange(url: origin, start: 4, end: 7, total: 12)
        range.authorizedPath = origin.path
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        let fd = Darwin.open(output.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ModelLibraryError.storage("测试文件无法创建。") }
        defer { _ = Darwin.close(fd) }
        let token = "hf_fake_SENTRY"
        let receiver = try ModelRangeReceiver(range: range, descriptor: fd, allowsLocalHTTP: false, token: token)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin)
        func redirected(to destination: URL) throws -> URLRequest? {
            let response = try #require(HTTPURLResponse(url: origin, statusCode: 302,
                httpVersion: nil, headerFields: ["Location": destination.absoluteString]))
            var supplied = URLRequest(url: destination)
            supplied.setValue("Bearer should-not-survive", forHTTPHeaderField: "Authorization")
            supplied.setValue("private-cookie", forHTTPHeaderField: "Cookie")
            let captured = Mutex<URLRequest?>(nil)
            receiver.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: supplied) { request in captured.withLock { $0 = request } }
            return captured.withLock { $0 }
        }
        let same = try redirected(to: origin)
        #expect(same?.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
        #expect(same?.value(forHTTPHeaderField: "Cookie") == nil)
        let cdn = try redirected(to: #require(URL(string: "https://cdn.example/blob")))
        #expect(cdn?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(cdn?.value(forHTTPHeaderField: "Range") == "bytes=4-7")
        let bounce = try redirected(to: origin)
        #expect(bounce?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try redirected(to: #require(URL(string: "http://cdn.example/blob"))) == nil)
    }

    @Test func cancellationPrecedesCredentialReadAndNeverStartsNetwork() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        let fd = Darwin.open(output.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ModelLibraryError.storage("测试文件无法创建。") }
        defer { _ = Darwin.close(fd) }
        var range = ModelByteRange(url: try #require(URL(string: "https://huggingface.co/owner/repo/resolve/rev/file")),
                                   start: 0, end: 1, total: 2)
        range.authorizedPath = range.url.path
        range.credential = ModelDownloadCredential(bookmark: Data("invalid fake bookmark".utf8))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await URLSessionModelRangeTransport().download(range, to: fd)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: output).isEmpty)
    }

    @Test func bookmarkConnectionDoesNotAlterRecordsOrRecipesAndOldIndexDecodes() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index.json")
        let entry = try ModelCatalog.flux2()
        let record = ModelRecord(id: ModelID(), catalogID: entry.id, revision: entry.revision,
            storage: .managed, state: .paused, availability: .unavailable, downloadedBytes: 17,
            totalBytes: entry.totalBytes, error: nil, directory: nil, activeLeaseCount: 0)
        let recordObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let old: [String: Any] = ["schemaVersion": 1, "libraryID": "00000000-0000-0000-0000-000000000001",
            "revision": 0, "records": [["record": recordObject, "files": [:], "verifiedFiles": [:]]]]
        try JSONSerialization.data(withJSONObject: old).write(to: index)
        let library = try await ModelLibrary(stateDirectory: root, catalog: [entry])
        let before = await library.snapshot()
        #expect(!before.downloadCredentialConnected)
        #expect(before.records.first?.downloadedBytes == 17)
        let beforeIndex = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        let token = root.appendingPathComponent("fake-token")
        try Data("hf_fake_test_only".utf8).write(to: token)
        try await library.connectDownloadCredential(at: token)
        let connected = await library.snapshot()
        #expect(connected.downloadCredentialConnected)
        #expect(connected.records.first?.downloadedBytes == before.records.first?.downloadedBytes)
        #expect(connected.records.first?.state == before.records.first?.state)
        let persisted = try String(contentsOf: index, encoding: .utf8)
        #expect(!persisted.contains("hf_fake_test_only"))
        #expect(persisted.contains("downloadCredentialBookmark"))
        let afterIndex = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        let beforeRecord = try #require((beforeIndex["records"] as? [[String: Any]])?.first)
        let afterRecord = try #require((afterIndex["records"] as? [[String: Any]])?.first)
        #expect(beforeRecord["recipeIdentity"] as? String == afterRecord["recipeIdentity"] as? String)
        #expect(beforeRecord["files"] as? [String: Int] == afterRecord["files"] as? [String: Int])
        let priorBytes = try Data(contentsOf: index)
        let otherToken = root.appendingPathComponent("replacement-fake-token")
        try Data("hf_other_fake_test_only".utf8).write(to: otherToken)
        let cancelledConnect = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await library.connectDownloadCredential(at: otherToken)
        }
        await #expect(throws: CancellationError.self) { try await cancelledConnect.value }
        #expect(try Data(contentsOf: index) == priorBytes)
        let afterCancelledConnect = await library.snapshot()
        #expect(afterCancelledConnect.downloadCredentialConnected)
        #expect(afterCancelledConnect.records.first?.downloadedBytes == 17)
        let cancelledDisconnect = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await library.disconnectDownloadCredential()
        }
        await #expect(throws: CancellationError.self) { try await cancelledDisconnect.value }
        #expect(try Data(contentsOf: index) == priorBytes)
        let afterCancelledDisconnect = await library.snapshot()
        #expect(afterCancelledDisconnect.downloadCredentialConnected)
        #expect(afterCancelledDisconnect.records.first?.downloadedBytes == 17)
        try await library.disconnectDownloadCredential()
        #expect(!(await library.snapshot()).downloadCredentialConnected)
        try await library.shutdown()
    }

    @Test func activeDownloadRejectsCredentialChanges() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let entry = ModelCatalogEntry(id: "credential-test", title: "Credential test", repository: "owner/repo",
            revision: String(repeating: "a", count: 40),
            files: [ModelFile(path: "weights.bin", size: 2, sha256: String(repeating: "0", count: 64))])
        let transport = HoldingTransport()
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"),
            catalog: [entry], transport: transport, availableBytesOverride: 128 * 1024 * 1024)
        try await library.configureRoot(at: storage)
        let token = root.appendingPathComponent("fake-token")
        try Data("hf_fake_test_only".utf8).write(to: token)
        try await library.connectDownloadCredential(at: token)
        let id = try await library.install(catalogID: entry.id)
        for _ in 0..<100 {
            if await transport.hasEntered() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await transport.hasEntered() else {
            try await library.pause(id)
            try await library.shutdown()
            Issue.record("The download never reached the fake transport")
            return
        }
        let before = try Data(contentsOf: root.appendingPathComponent("state/index.json"))
        let replacement = root.appendingPathComponent("replacement-fake-token")
        try Data("hf_other_fake_test_only".utf8).write(to: replacement)
        await #expect(throws: ModelLibraryError.self) { try await library.connectDownloadCredential(at: replacement) }
        await #expect(throws: ModelLibraryError.self) { try await library.disconnectDownloadCredential() }
        #expect(try Data(contentsOf: root.appendingPathComponent("state/index.json")) == before)
        #expect((await library.snapshot()).downloadCredentialConnected)
        try await library.pause(id)
        try await library.shutdown()
    }
}
