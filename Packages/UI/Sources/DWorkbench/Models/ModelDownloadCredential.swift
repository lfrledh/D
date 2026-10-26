import Darwin
import Foundation
import Security
import Synchronization


public enum ModelCredentialIssue: Error, LocalizedError, Sendable {
    case invalidFormat, keychainWrite(Int32), keychainRead, keychainCleanup(Int32), tokenRejected, tokenNetwork, invalidSource, sourceRejected, sourceNetwork
    public var localizationKey: String {
        switch self {
        case .invalidFormat: "invalidFormat"
        case .keychainWrite: "keychainWrite"
        case .keychainRead: "keychainRead"
        case .keychainCleanup: "keychainCleanup"
        case .tokenRejected: "tokenRejected"
        case .tokenNetwork: "tokenNetwork"
        case .invalidSource: "invalidSource"
        case .sourceRejected: "sourceRejected"
        case .sourceNetwork: "sourceNetwork"
        }
    }
    public var statusCode: Int32? { switch self { case .keychainWrite(let code), .keychainCleanup(let code): code; default: nil } }
    public var errorDescription: String? { "Model credential: " + localizationKey + (statusCode.map { " (\($0))" } ?? "") }
}

/// A bookmark to one user-selected token file. Token bytes are never stored in the library index.
struct ModelDownloadCredential: Sendable {
    static let maximumBytes = 4096
    let bookmark: Data
    private let inlineToken: String?
    private let keychainAccount: String?
    private var keychainRead: @Sendable (String) throws -> String = ModelDownloadKeychain.read
    init(bookmark: Data) { self.bookmark = bookmark; inlineToken = nil; keychainAccount = nil }
    init(token: String) throws { bookmark = Data(); inlineToken = try Self.validated(token); keychainAccount = nil }
    init(keychainAccount: String, read: @escaping @Sendable (String) throws -> String = ModelDownloadKeychain.read) { bookmark = Data(); inlineToken = nil; self.keychainAccount = keychainAccount; keychainRead = read }
    static func validated(_ value: String) throws -> String {
        guard value.hasPrefix("hf_"), value.utf8.count > 3, value.utf8.count <= maximumBytes,
              value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 }) else {
            throw ModelCredentialIssue.invalidFormat
        }
        return value
    }

    static func choose(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Do not follow a selected symlink when making the persistent connection.
        var information = stat()
        guard lstat(url.path, &information) == 0, (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size > 0, information.st_size <= maximumBytes else {
            throw invalidFile
        }
        do {
            return Self(bookmark: try url.bookmarkData(options: [.withSecurityScope],
                includingResourceValuesForKeys: nil, relativeTo: nil))
        } catch { throw invalidFile }
    }

    func token() throws -> String {
        if let inlineToken { return inlineToken }
        if let keychainAccount { return try Self.validated(keychainRead(keychainAccount)) }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw Self.invalidFile }
        guard !stale, url.isFileURL else { throw Self.invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Self.read(at: url)
    }

    static func read(at url: URL) throws -> String {
        guard url.isFileURL else { throw invalidFile }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalidFile }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= maximumBytes else { throw invalidFile }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var readCount = 0
        let expectedCount = bytes.count
        while readCount < bytes.count {
            let result = bytes.withUnsafeMutableBytes { pointer in
                Darwin.read(descriptor, pointer.baseAddress!.advanced(by: readCount), expectedCount - readCount)
            }
            guard result > 0 else { throw invalidFile }
            readCount += result
        }
        var extra: UInt8 = 0
        var after = stat()
        var pathAfter = stat()
        guard Darwin.read(descriptor, &extra, 1) == 0, fstat(descriptor, &after) == 0,
              lstat(url.path, &pathAfter) == 0, (pathAfter.st_mode & S_IFMT) == S_IFREG,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_dev == pathAfter.st_dev, before.st_ino == pathAfter.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw invalidFile }
        guard let token = String(bytes: bytes, encoding: .utf8),
              !token.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }),
              !token.isEmpty else { throw invalidFile }
        return token
    }

    private static var invalidFile: ModelLibraryError {
        .accessDenied("所选令牌文件不可用或内容无效；请重新选择单个纯文本令牌文件。")
    }
}

/// Two fixed accounts are owned by one library. No token enters its index.
enum ModelDownloadKeychain {
    private static let service = "D.model-download.huggingface"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func insert(_ token: String, account: String) throws {
        var value = query(account)
        value[kSecValueData as String] = Data(token.utf8)
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else { throw ModelCredentialIssue.keychainWrite(status) }
    }
    static func read(account: String) throws -> String {
        var value = query(account); value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw ModelCredentialIssue.keychainRead
        }
        return token
    }
    static func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelCredentialIssue.keychainCleanup(status)
        }
    }
}

/// Internal CPU-test seam; production uses the system Keychain and fixed API.
struct ModelCredentialServices: Sendable {
    var validate: @Sendable (String) async throws -> Void = ModelTokenProbe.validate
    var insert: @Sendable (String, String) throws -> Void = { try ModelDownloadKeychain.insert($0, account: $1) }
    var read: @Sendable (String) throws -> String = ModelDownloadKeychain.read
    var remove: @Sendable (String) throws -> Void = ModelDownloadKeychain.remove
}

/// No cookies, disk cache, account response storage or authenticated redirects.
private final class ModelTokenProbeDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
enum ModelTokenProbe {
    static func validate(_ token: String) async throws {
        let token = try ModelDownloadCredential.validated(token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: ModelTokenProbeDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/whoami-v2")!)
        request.httpShouldHandleCookies = false; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ModelCredentialIssue.tokenRejected
            }
        } catch is CancellationError { throw CancellationError() }
        catch let issue as ModelCredentialIssue { throw issue }
        catch { throw ModelCredentialIssue.tokenNetwork }
    }
}

private final class ModelAccessProbeDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let range: ModelByteRange
    let token: String?
    let authorization = Synchronization.Mutex(true)
    init(range: ModelByteRange, token: String?) { self.range = range; self.token = token }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let next = authorization.withLock { allowed in
            var next = ModelDownloadRequestPolicy.redirect(to: request.url, range: range, token: token, mayAuthenticate: &allowed)
            next?.httpMethod = "HEAD"; next?.setValue(nil, forHTTPHeaderField: "Range"); return next
        }
        completionHandler(next)
    }
}
enum ModelSourceAccessProbe {
    static func check(_ url: URL, credential: ModelDownloadCredential?) async throws {
        let isHuggingFace = ModelDownloadRequestPolicy.isHuggingFaceResolve(url, path: url.path)
        let isPublicFixedGitHub = url.scheme == "https" && url.host?.lowercased() == "raw.githubusercontent.com"
            && url.port == nil && url.user == nil && url.password == nil
        guard isHuggingFace || isPublicFixedGitHub else { throw ModelCredentialIssue.invalidSource }
        let token = isHuggingFace ? try credential?.token() : nil
        var range = ModelByteRange(url: url, start: 0, end: 0, total: 1); range.authorizedPath = url.path
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil; config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config, delegate: ModelAccessProbeDelegate(range: range, token: token), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = ModelDownloadRequestPolicy.request(url: url, range: range, token: token)
        request.httpMethod = "HEAD"; request.setValue(nil, forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await session.data(for: request)
            guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
                throw ModelCredentialIssue.sourceRejected
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ModelCredentialIssue { throw error }
        catch { throw ModelCredentialIssue.sourceNetwork }
    }
}
