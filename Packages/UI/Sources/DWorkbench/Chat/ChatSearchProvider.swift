import Foundation

public enum ChatSearchProvider: String, Codable, CaseIterable, Sendable {
    case brave
    case bocha
}

/// Search metadata only. Result URLs are never opened by this client.
public struct ChatSearchResult: Codable, Equatable, Sendable {
    public let provider: ChatSearchProvider
    public let title: String
    public let url: URL
    public let snippet: String
    public let fetchedAt: Date

    public init(provider: ChatSearchProvider, title: String, url: URL, snippet: String, fetchedAt: Date) {
        self.provider = provider
        self.title = title
        self.url = url
        self.snippet = snippet
        self.fetchedAt = fetchedAt
    }
}

public enum ChatSearchError: Error, Equatable, LocalizedError, Sendable {
    case permissionDenied
    case unsupportedProvider
    case invalidQuery
    case invalidCredential
    case invalidResponse
    case responseTooLarge
    case redirectRejected
    case unauthorized
    case forbidden
    case rateLimited
    case serviceUnavailable(Int)
    case httpStatus(Int)
    case transportFailure

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow network access before searching."
        case .unsupportedProvider: "This search provider is not available yet."
        case .invalidQuery: "Enter a non-empty query of at most 600 characters, 75 words, and 2048 UTF-8 bytes, without control characters."
        case .invalidCredential: "Enter a valid search API credential."
        case .invalidResponse: "The search provider returned an invalid response."
        case .responseTooLarge: "The search response exceeds the download limit."
        case .redirectRejected: "The search request redirected or returned from an unexpected URL."
        case .unauthorized: "The search credential was rejected. Check the API key."
        case .forbidden: "The search provider denied access. Check the API key and subscription."
        case .rateLimited: "The search provider rate limit was reached. Try again later."
        case .serviceUnavailable(let status): "The search provider is unavailable (HTTP \(status)). Try again later."
        case .httpStatus(let status): "The search provider returned HTTP \(status)."
        case .transportFailure: "The search request failed during transport."
        }
    }
}

public struct ChatSearchClient: Sendable {
    // Brave's q limit is 600 characters / 75 words. The byte cap bounds local URL construction.
    public static let maximumQueryCharacters = 600
    public static let maximumQueryWords = 75
    public static let maximumQueryBytes = 2_048
    public static let maximumCredentialBytes = 512
    public static let maximumResults = 5
    public static let maximumResponseBytes = 128 * 1_024

    private let transport: any ChatWebTransport
    private let now: @Sendable () -> Date

    public init(transport: any ChatWebTransport = URLSessionChatWebTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    /// The caller must authorize this operation and supply its credential explicitly.
    public func search(query: String, provider: ChatSearchProvider, credential: String,
                       networkAuthorized: Bool) async throws -> [ChatSearchResult] {
        guard networkAuthorized else { throw ChatSearchError.permissionDenied }
        try Task.checkCancellation()
        guard provider == .brave else { throw ChatSearchError.unsupportedProvider }
        guard Self.validQuery(query) else { throw ChatSearchError.invalidQuery }
        guard Self.validCredential(credential) else { throw ChatSearchError.invalidCredential }

        let request = try Self.braveRequest(query: query, credential: credential)
        let response: ChatWebHTTPResponse
        do {
            response = try await transport.send(request, maximumBytes: Self.maximumResponseBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ChatWebError {
            if Task.isCancelled { throw CancellationError() }
            switch error {
            case .responseTooLarge: throw ChatSearchError.responseTooLarge
            case .redirectRejected: throw ChatSearchError.redirectRejected
            default: throw ChatSearchError.transportFailure
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ChatSearchError.transportFailure
        }
        try Task.checkCancellation()
        guard response.url == request.url else { throw ChatSearchError.redirectRejected }
        if (300...399).contains(response.statusCode) { throw ChatSearchError.redirectRejected }
        switch response.statusCode {
        case 200: break
        case 401: throw ChatSearchError.unauthorized
        case 403: throw ChatSearchError.forbidden
        case 429: throw ChatSearchError.rateLimited
        case 500...599: throw ChatSearchError.serviceUnavailable(response.statusCode)
        default: throw ChatSearchError.httpStatus(response.statusCode)
        }
        guard response.body.count <= Self.maximumResponseBytes else { throw ChatSearchError.responseTooLarge }
        let mimeType = response.mimeType?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mimeType == "application/json" else { throw ChatSearchError.invalidResponse }

        let envelope: BraveEnvelope
        do { envelope = try JSONDecoder().decode(BraveEnvelope.self, from: response.body) }
        catch { throw ChatSearchError.invalidResponse }
        guard envelope.error == nil, let entries = envelope.web?.results,
              entries.count <= Self.maximumResults else {
            throw ChatSearchError.invalidResponse
        }
        try Task.checkCancellation()
        let fetchedAt = now()
        return try entries.map { entry in
            try Task.checkCancellation()
            guard !entry.title.isEmpty, let url = Self.validResultURL(entry.url) else {
                throw ChatSearchError.invalidResponse
            }
            return ChatSearchResult(provider: .brave, title: entry.title, url: url,
                                    snippet: entry.description, fetchedAt: fetchedAt)
        }
    }

    private static func validQuery(_ query: String) -> Bool {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.count <= maximumQueryCharacters,
              query.utf8.count <= maximumQueryBytes,
              query.split(whereSeparator: { $0.isWhitespace }).count <= maximumQueryWords else { return false }
        return !query.unicodeScalars.contains(where: { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) })
    }

    private static func validCredential(_ credential: String) -> Bool {
        let bytes = credential.utf8
        return !bytes.isEmpty && bytes.count <= maximumCredentialBytes && bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private static func braveRequest(query: String, credential: String) throws -> URLRequest {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.search.brave.com"
        parts.path = "/res/v1/web/search"
        parts.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(maximumResults)),
            URLQueryItem(name: "result_filter", value: "web"),
            URLQueryItem(name: "text_decorations", value: "false"),
            URLQueryItem(name: "spellcheck", value: "false")
        ]
        // URLComponents leaves '+' literal, but form-style query parsers read it as a space.
        // Escape it in the encoded query so the provider receives the exact user text.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url, url.scheme == "https", url.host == "api.search.brave.com" else {
            throw ChatSearchError.invalidQuery
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(credential, forHTTPHeaderField: "X-Subscription-Token")
        return request
    }

    private static func validResultURL(_ raw: String) -> URL? {
        guard !raw.unicodeScalars.contains(where: { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) }),
              let parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true,
              !host.hasSuffix("."), !host.contains("%"),
              host != "localhost", !host.hasSuffix(".localhost"),
              host != "localdomain", !host.hasSuffix(".localdomain"),
              !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              host != "home.arpa", !host.hasSuffix(".home.arpa"),
              host.contains("."),
              let url = parts.url else { return nil }

        // Do not expose local or unusual numeric addresses as search results. Public dotted IPv4 is allowed.
        if host.contains(":") { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-") &&
            label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0.value == 45 }
        }) else { return nil }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            let octets = labels.compactMap { UInt8($0) }
            guard labels.count == 4,
                  octets.count == 4,
                  labels.allSatisfy({ $0.count == 1 || !$0.hasPrefix("0") }),
                  octets[0] > 0, octets[0] < 224,
                  octets[0] != 10, octets[0] != 127,
                  !(octets[0] == 169 && octets[1] == 254),
                  !(octets[0] == 172 && (16...31).contains(octets[1])),
                  !(octets[0] == 192 && octets[1] == 168),
                  !(octets[0] == 100 && (64...127).contains(octets[1])),
                  !(octets[0] == 192 && octets[1] == 0),
                  !(octets[0] == 198 && (octets[1] == 18 || octets[1] == 19 ||
                                           (octets[1] == 51 && octets[2] == 100))),
                  !(octets[0] == 203 && octets[1] == 0 && octets[2] == 113) else { return nil }
        } else if labels.last?.allSatisfy(\.isNumber) == true ||
                    host.hasPrefix("0x") || host.allSatisfy(\.isNumber) {
            return nil
        }
        return url
    }

    private struct BraveEnvelope: Decodable {
        let web: BraveWeb?
        let error: String?
    }
    private struct BraveWeb: Decodable { let results: [BraveEntry] }
    private struct BraveEntry: Decodable {
        let title: String
        let url: String
        let description: String
    }
}
