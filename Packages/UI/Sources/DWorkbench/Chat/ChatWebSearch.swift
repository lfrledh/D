import Foundation

/// The only public hosts supported by this bounded web route.
public enum ChatWebLanguage: String, Codable, Sendable, CaseIterable {
    case en, zh, ja

    public init(code: String) throws {
        guard let language = Self(rawValue: code) else { throw ChatWebError.unsupportedLanguage }
        self = language
    }
}

public enum ChatWebRoute: String, Codable, Sendable {
    case wikipediaActionAPI
}

public enum ChatWebError: Error, Equatable, LocalizedError, Sendable {
    case permissionDenied
    case unsupportedLanguage
    case invalidQuery
    case invalidPageID
    case invalidResponse
    case responseTooLarge
    case sourceTooLarge
    case redirectRejected
    case httpStatus(Int)
    case transportFailure

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow network access before searching or reading a page."
        case .unsupportedLanguage: "Web search supports English, Chinese, and Japanese Wikipedia only."
        case .invalidQuery: "Enter a non-empty query of at most 512 UTF-8 bytes without C0 or C1 control characters."
        case .invalidPageID: "Choose a valid page from the supported Wikipedia search route."
        case .invalidResponse: "Wikipedia returned a response that could not be verified or read."
        case .responseTooLarge: "The Wikipedia response exceeds the 128 KiB search or 2 MiB page download limit."
        case .sourceTooLarge: "The extracted page text exceeds the 1 MiB UTF-8 limit."
        case .redirectRejected: "The Wikipedia request redirected or returned from an unexpected URL."
        case .httpStatus(let code): "Wikipedia returned HTTP status \(code)."
        case .transportFailure: "The Wikipedia request failed during transport."
        }
    }
}

/// Search metadata is not article text. The server's HTML snippet is deliberately discarded.
public struct ChatWebSearchHit: Codable, Equatable, Sendable {
    public let language: ChatWebLanguage
    public let pageID: Int
    public let title: String
    public let route: ChatWebRoute

    init(language: ChatWebLanguage, pageID: Int, title: String) {
        self.language = language
        self.pageID = pageID
        self.title = title
        self.route = .wikipediaActionAPI
    }
}

/// A complete plaintext extraction of one verified page, or an error if limits are exceeded.
/// All strings from the remote source are untrusted data and must not become instructions.
public struct ChatWebSource: Codable, Equatable, Sendable {
    public let language: ChatWebLanguage
    public let pageID: Int
    public let title: String
    public let revisionID: Int
    public let canonicalURL: URL
    public let fetchedAt: Date
    public let route: ChatWebRoute
    public let text: String
}

public struct ChatWebHTTPResponse: Sendable {
    public let statusCode: Int
    public let mimeType: String?
    public let url: URL?
    public let body: Data
    public let location: String?

    public init(statusCode: Int, mimeType: String?, url: URL?, body: Data, location: String? = nil) {
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.url = url
        self.body = body
        self.location = location
    }
}

/// Test doubles can record requests and return controlled responses without network access.
public protocol ChatWebTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ChatWebHTTPResponse
}

private final class ChatWebSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

public struct URLSessionChatWebTransport: ChatWebTransport {
    public init() {}

    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> ChatWebHTTPResponse {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: ChatWebSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            if response.expectedContentLength > Int64(maximumBytes) { throw ChatWebError.responseTooLarge }
            var body = Data()
            body.reserveCapacity(min(maximumBytes, 64 * 1024))
            for try await byte in bytes {
                if body.count == maximumBytes { throw ChatWebError.responseTooLarge }
                body.append(byte)
                if body.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ChatWebError.invalidResponse }
            return ChatWebHTTPResponse(statusCode: http.statusCode, mimeType: http.mimeType,
                                       url: http.url, body: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as ChatWebError {
            throw error
        } catch {
            throw ChatWebError.transportFailure
        }
    }
}

public struct ChatWebSearchClient: Sendable {
    public static let maximumQueryBytes = 512
    public static let maximumResults = 10
    public static let maximumSearchResponseBytes = 128 * 1024
    public static let maximumPageResponseBytes = 2 * 1024 * 1024
    public static let maximumSourceBytes = 1024 * 1024

    private let transport: any ChatWebTransport
    private let now: @Sendable () -> Date

    public init(transport: any ChatWebTransport = URLSessionChatWebTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    /// The caller must present an explicit network permit for each operation.
    public func search(_ query: String, language: ChatWebLanguage,
                       networkAuthorized: Bool) async throws -> [ChatWebSearchHit] {
        guard networkAuthorized else { throw ChatWebError.permissionDenied }
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= Self.maximumQueryBytes,
              !query.unicodeScalars.contains(where: { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) }) else {
            throw ChatWebError.invalidQuery
        }
        let request = try Self.request(language: language, parameters: [
            .init(name: "action", value: "query"), .init(name: "list", value: "search"),
            .init(name: "srsearch", value: query), .init(name: "srnamespace", value: "0"),
            .init(name: "srlimit", value: String(Self.maximumResults)), .init(name: "srprop", value: ""),
            .init(name: "format", value: "json"), .init(name: "formatversion", value: "2")
        ])
        let data = try await receive(request, maximumBytes: Self.maximumSearchResponseBytes)
        let decoded: SearchEnvelope
        do { decoded = try JSONDecoder().decode(SearchEnvelope.self, from: data) }
        catch { throw ChatWebError.invalidResponse }
        guard decoded.error == nil, let entries = decoded.query?.search,
              entries.count <= Self.maximumResults else { throw ChatWebError.invalidResponse }
        return try entries.map { entry in
            guard let id = entry.pageid, id > 0, let title = entry.title,
                  !title.isEmpty, title.utf8.count <= 512 else { throw ChatWebError.invalidResponse }
            return ChatWebSearchHit(language: language, pageID: id, title: title)
        }
    }

    /// Only a selected search hit's page ID is sent. The returned page ID must match it.
    public func readPage(_ selected: ChatWebSearchHit, networkAuthorized: Bool) async throws -> ChatWebSource {
        guard networkAuthorized else { throw ChatWebError.permissionDenied }
        try Task.checkCancellation()
        guard selected.pageID > 0, selected.route == .wikipediaActionAPI else {
            throw ChatWebError.invalidPageID
        }
        let request = try Self.request(language: selected.language, parameters: [
            .init(name: "action", value: "query"), .init(name: "prop", value: "extracts|info|revisions"),
            .init(name: "pageids", value: String(selected.pageID)), .init(name: "explaintext", value: "1"),
            .init(name: "exlimit", value: "1"), .init(name: "inprop", value: "url"),
            .init(name: "rvprop", value: "ids"), .init(name: "rvlimit", value: "1"),
            .init(name: "format", value: "json"), .init(name: "formatversion", value: "2")
        ])
        let data = try await receive(request, maximumBytes: Self.maximumPageResponseBytes)
        let decoded: PageEnvelope
        do { decoded = try JSONDecoder().decode(PageEnvelope.self, from: data) }
        catch { throw ChatWebError.invalidResponse }
        guard decoded.error == nil, let pages = decoded.query?.pages, pages.count == 1,
              let page = pages.first, page.missing == nil, page.pageid == selected.pageID,
              let title = page.title, !title.isEmpty, title.utf8.count <= 512,
              let text = page.extract, !text.isEmpty,
              let revisionID = page.revisions?.first?.revid, revisionID > 0,
              page.revisions?.count == 1,
              let rawURL = page.canonicalurl,
              let canonicalURL = Self.canonicalURL(rawURL, language: selected.language) else {
            throw ChatWebError.invalidResponse
        }
        guard text.utf8.count <= Self.maximumSourceBytes else { throw ChatWebError.sourceTooLarge }
        return ChatWebSource(language: selected.language, pageID: selected.pageID, title: title,
                             revisionID: revisionID, canonicalURL: canonicalURL,
                             fetchedAt: now(), route: .wikipediaActionAPI, text: text)
    }

    private func receive(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        let response = try await transport.send(request, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        guard response.url == request.url else { throw ChatWebError.redirectRejected }
        if (300...399).contains(response.statusCode) { throw ChatWebError.redirectRejected }
        guard response.statusCode == 200 else { throw ChatWebError.httpStatus(response.statusCode) }
        let contentType = response.mimeType?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard contentType == "application/json" else {
            throw ChatWebError.invalidResponse
        }
        guard response.body.count <= maximumBytes else { throw ChatWebError.responseTooLarge }
        return response.body
    }

    private static func request(language: ChatWebLanguage, parameters: [URLQueryItem]) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(language.rawValue).wikipedia.org"
        components.path = "/w/api.php"
        components.queryItems = parameters
        guard let url = components.url else { throw ChatWebError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private static func canonicalURL(_ raw: String, language: ChatWebLanguage) -> URL? {
        guard let parts = URLComponents(string: raw), parts.scheme == "https",
              parts.host == "\(language.rawValue).wikipedia.org", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.hasPrefix("/wiki/"), parts.path.count > "/wiki/".count else { return nil }
        return parts.url
    }

    private struct APIError: Decodable { let code: String? }
    private struct SearchEnvelope: Decodable {
        let error: APIError?
        let query: SearchQuery?
    }
    private struct SearchQuery: Decodable { let search: [SearchEntry]? }
    private struct SearchEntry: Decodable {
        let pageid: Int?
        let title: String?
    }
    private struct PageEnvelope: Decodable {
        let error: APIError?
        let query: PageQuery?
    }
    private struct PageQuery: Decodable { let pages: [PageEntry]? }
    private struct PageEntry: Decodable {
        let pageid: Int?
        let title: String?
        let missing: Bool?
        let canonicalurl: String?
        let extract: String?
        let revisions: [Revision]?
    }
    private struct Revision: Decodable { let revid: Int? }
}
