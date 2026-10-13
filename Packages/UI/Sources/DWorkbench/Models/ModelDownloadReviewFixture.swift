#if DEBUG
import CryptoKit
import Foundation

/// Explicit, DEBUG-only small-file review entry. Production construction always
/// uses the unchanged frozen catalog. This fixture has no inference route.
public enum ModelDownloadReviewFixture {
    public static func makeLibrary(stateDirectory: URL, destination: URL, source: URL) async throws -> ModelLibrary {
        guard source.scheme == "http", source.host == "127.0.0.1", source.port != nil,
              source.user == nil, source.password == nil, source.query == nil, source.fragment == nil,
              source.path.isEmpty || source.path == "/" else {
            throw ModelLibraryError.invalidCatalog("Review fixture requires an explicit loopback HTTP peer.")
        }
        let data = Data(repeating: 0x47, count: 18 * 1024 * 1024)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let catalog = ["a", "b", "c"].map { name in
            ModelCatalogEntry(id: "review-" + name, title: "D review fixture " + name.uppercased(), repository: "fixture/model",
                revision: String(repeating: "a", count: 40), files: [.init(path: "payload.bin", size: UInt64(data.count), sha256: digest)],
                modelSpec: "DEBUG · 18 MiB · CPU file fixture", memoryGuidance: "Review fixture only; no inference route.")
        }
        let library = try await ModelLibrary(stateDirectory: stateDirectory, catalog: catalog,
            transport: URLSessionModelRangeTransport(allowsLocalHTTP: true), sourceBaseURL: source)
        if await library.snapshot().rootURL == nil { try await library.configureRoot(at: destination) }
        return library
    }
}
#endif
