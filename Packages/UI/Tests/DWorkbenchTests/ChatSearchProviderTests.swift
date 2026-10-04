import Foundation
import Testing
@testable import DWorkbench

private actor SearchFixtureTransport: ChatWebTransport {
    struct Reply: Sendable {
        let body: Data
        var statusCode = 200
        var mimeType: String? = "application/json; charset=utf-8"
        var finalURL: URL? = nil
        var useRequestURL = true
    }

    struct Call: Sendable {
        let request: URLRequest
        let maximumBytes: Int
    }

    private var replies: [Reply]
    private var calls: [Call] = []

    init(_ replies: [Reply] = []) { self.replies = replies }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ChatWebHTTPResponse {
        calls.append(.init(request: request, maximumBytes: maximumBytes))
        guard !replies.isEmpty else { throw ChatWebError.invalidResponse }
        let reply = replies.removeFirst()
        return .init(statusCode: reply.statusCode, mimeType: reply.mimeType,
                     url: reply.useRequestURL ? request.url : reply.finalURL, body: reply.body)
    }

    func recorded() -> [Call] { calls }
}

private actor ControlledSearchTransport: ChatWebTransport {
    private var entered = false
    private var exited = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ChatWebHTTPResponse {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        defer { exited = true }
        try await Task.sleep(for: .seconds(30))
        return .init(statusCode: 200, mimeType: "application/json", url: request.url,
                     body: Data("{\"web\":{\"results\":[]}}".utf8))
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func hasExited() -> Bool { exited }
}

private struct FailingSearchTransport: ChatWebTransport {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ChatWebHTTPResponse {
        throw NSError(domain: "synthetic-key must stay private", code: 1)
    }
}

@Suite("Provider neutral search and Brave adapter")
struct ChatSearchProviderTests {
    private static let moment = Date(timeIntervalSince1970: 1_700_000_000)

    private static func body(title: String = "An article", url: String = "https://example.org/article",
                             description: String = "A plain snippet") -> Data {
        let value: [String: Any] = ["web": ["results": [[
            "title": title, "url": url, "description": description
        ]]]]
        return try! JSONSerialization.data(withJSONObject: value)
    }

    private static func parameters(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func fixedRequestAndResultMetadata() async throws {
        let transport = SearchFixtureTransport([.init(body: Self.body())])
        let client = ChatSearchClient(transport: transport, now: { Self.moment })
        let results = try await client.search(query: "  東京 👩🏽‍🎨  ", provider: .brave,
                                              credential: "synthetic-key", networkAuthorized: true)
        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.provider == .brave)
        #expect(result.title == "An article")
        #expect(result.url.absoluteString == "https://example.org/article")
        #expect(result.snippet == "A plain snippet")
        #expect(result.fetchedAt == Self.moment)
        #expect(try JSONDecoder().decode(ChatSearchResult.self, from: JSONEncoder().encode(result)) == result)
        #expect(ChatSearchProvider.allCases == [.brave, .bocha])

        let call = try #require(await transport.recorded().first)
        #expect(call.maximumBytes == ChatSearchClient.maximumResponseBytes)
        #expect(call.request.httpMethod == "GET")
        #expect(call.request.httpBody == nil)
        #expect(call.request.url?.scheme == "https")
        #expect(call.request.url?.host == "api.search.brave.com")
        #expect(call.request.url?.path == "/res/v1/web/search")
        #expect(call.request.value(forHTTPHeaderField: "X-Subscription-Token") == "synthetic-key")
        #expect(call.request.value(forHTTPHeaderField: "Authorization") == nil)
        let parameters = try Self.parameters(call.request)
        #expect(Set(parameters.keys) == ["q", "count", "result_filter", "text_decorations", "spellcheck"])
        #expect(parameters["q"] == "  東京 👩🏽‍🎨  ")
        #expect(parameters["count"] == "5")
        #expect(parameters["result_filter"] == "web")
        #expect(parameters["text_decorations"] == "false")
        #expect(parameters["spellcheck"] == "false")
        let encoded = try JSONEncoder().encode(result)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("synthetic-key"))
    }

    @Test func validationAndUnsupportedProviderMakeNoCalls() async throws {
        let transport = SearchFixtureTransport()
        let client = ChatSearchClient(transport: transport)
        await #expect(throws: ChatSearchError.permissionDenied) {
            try await client.search(query: "secret", provider: .brave,
                                    credential: "synthetic-key", networkAuthorized: false)
        }
        await #expect(throws: ChatSearchError.unsupportedProvider) {
            try await client.search(query: "secret", provider: .bocha,
                                    credential: "synthetic-key", networkAuthorized: true)
        }
        for query in [" \t ", "a\n b", "a\u{0000}b", "a\u{0085}b",
                      String(repeating: "x", count: 601),
                      Array(repeating: "word", count: 76).joined(separator: " "),
                      String(repeating: "😀", count: 513)] {
            await #expect(throws: ChatSearchError.invalidQuery) {
                try await client.search(query: query, provider: .brave,
                                        credential: "synthetic-key", networkAuthorized: true)
            }
        }
        for credential in ["", "bad\r\nheader", " spaced", "bad space", "é",
                           String(repeating: "x", count: ChatSearchClient.maximumCredentialBytes + 1)] {
            await #expect(throws: ChatSearchError.invalidCredential) {
                try await client.search(query: "public", provider: .brave,
                                        credential: credential, networkAuthorized: true)
            }
        }
        #expect(await transport.recorded().isEmpty)
    }

    @Test func plusSignsSurviveFormStyleQueryParsing() async throws {
        let query = "C++ a+b 100%"
        let transport = SearchFixtureTransport([.init(body: Self.body())])
        _ = try await ChatSearchClient(transport: transport)
            .search(query: query, provider: .brave, credential: "synthetic-key", networkAuthorized: true)
        let call = try #require(await transport.recorded().first)
        let url = try #require(call.request.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let encoded = try #require(parts.percentEncodedQuery)
        #expect(encoded == "q=C%2B%2B%20a%2Bb%20100%25&count=5&result_filter=web&text_decorations=false&spellcheck=false")
        let encodedQuery = try #require(encoded.split(separator: "&").first?.split(separator: "=", maxSplits: 1).last)
        #expect(String(encodedQuery).replacingOccurrences(of: "+", with: " ").removingPercentEncoding == query)
        #expect(try Self.parameters(call.request)["q"] == query)
    }

    @Test func onlyProperSuccessShapeAllowsEmptyResults() async throws {
        let empty = Data("{\"web\":{\"results\":[]}}".utf8)
        let transport = SearchFixtureTransport([.init(body: empty)])
        let result = try await ChatSearchClient(transport: transport)
            .search(query: "public", provider: .brave, credential: "synthetic-key", networkAuthorized: true)
        #expect(result.isEmpty)

        let invalid = [Data("{}".utf8), Data("{\"web\":{}}".utf8),
                       Data("{\"web\":{\"results\":null}}".utf8), Data("{".utf8),
                       Data("{\"web\":{\"results\":[{}]}}".utf8),
                       Data("{\"web\":{\"results\":[]},\"error\":\"failure\"}".utf8),
                       Data("{\"web\":{\"results\":[]},\"error\":{\"code\":\"failure\"}}".utf8)]
        for body in invalid {
            let client = ChatSearchClient(transport: SearchFixtureTransport([.init(body: body)]))
            await #expect(throws: ChatSearchError.invalidResponse) {
                try await client.search(query: "public", provider: .brave,
                                        credential: "synthetic-key", networkAuthorized: true)
            }
        }
    }

    @Test func rejectsPrivateOrMalformedResultURLs() async throws {
        for url in ["http://localhost/a", "https://sub.localhost/a", "http://printer.local/a",
                    "http://127.0.0.1/a", "https://10.1.2.3/a", "http://172.16.0.1/a",
                    "https://192.168.1.1/a", "http://169.254.1.1/a", "http://[::1]/a",
                    "http://2130706433/a", "http://0177.0.0.1/a", "https://user:pass@example.org/a",
                    "file:///tmp/a", "javascript:alert(1)", "/relative"] {
            let client = ChatSearchClient(transport: SearchFixtureTransport([.init(body: Self.body(url: url))]))
            await #expect(throws: ChatSearchError.invalidResponse) {
                try await client.search(query: "public", provider: .brave,
                                        credential: "synthetic-key", networkAuthorized: true)
            }
        }
        let client = ChatSearchClient(transport: SearchFixtureTransport([.init(body: Self.body(url: "http://8.8.8.8/a"))]))
        let hits = try await client.search(query: "public", provider: .brave,
                                           credential: "synthetic-key", networkAuthorized: true)
        #expect(hits.first?.url.host == "8.8.8.8")
    }

    @Test func excessResultsAreRejectedInsteadOfTruncated() async throws {
        let entry = ["title": "An article", "url": "https://example.org/a", "description": "snippet"]
        let body = try JSONSerialization.data(withJSONObject: ["web": ["results": Array(repeating: entry, count: 6)]])
        let client = ChatSearchClient(transport: SearchFixtureTransport([.init(body: body)]))
        await #expect(throws: ChatSearchError.invalidResponse) {
            try await client.search(query: "public", provider: .brave,
                                    credential: "synthetic-key", networkAuthorized: true)
        }
    }

    @Test func statusFinalURLTypeAndByteLimitAreEnforced() async throws {
        let body = Self.body()
        let cases: [(SearchFixtureTransport.Reply, ChatSearchError)] = [
            (.init(body: body, finalURL: URL(string: "https://evil.example/search"), useRequestURL: false), .redirectRejected),
            (.init(body: body, statusCode: 302), .redirectRejected),
            (.init(body: body, statusCode: 401), .unauthorized),
            (.init(body: body, statusCode: 403), .forbidden),
            (.init(body: body, statusCode: 429), .rateLimited),
            (.init(body: body, statusCode: 503), .serviceUnavailable(503)),
            (.init(body: body, statusCode: 400), .httpStatus(400)),
            (.init(body: body, mimeType: "text/html"), .invalidResponse),
            (.init(body: Data(repeating: 65, count: ChatSearchClient.maximumResponseBytes + 1)), .responseTooLarge)
        ]
        for (reply, expected) in cases {
            let client = ChatSearchClient(transport: SearchFixtureTransport([reply]))
            await #expect(throws: expected) {
                try await client.search(query: "public", provider: .brave,
                                        credential: "synthetic-key", networkAuthorized: true)
            }
            #expect(!String(describing: expected).contains("synthetic-key"))
            #expect(!(expected.errorDescription ?? "").contains("synthetic-key"))
        }
    }

    @Test func cancellationPropagates() async throws {
        let transport = ControlledSearchTransport()
        let client = ChatSearchClient(transport: transport)
        let task = Task { try await client.search(query: "public", provider: .brave,
                                                  credential: "synthetic-key", networkAuthorized: true) }
        await transport.waitUntilEntered()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.hasExited())
    }

    @Test func transportErrorsCannotExposeCredential() async throws {
        let client = ChatSearchClient(transport: FailingSearchTransport())
        await #expect(throws: ChatSearchError.transportFailure) {
            try await client.search(query: "public", provider: .brave,
                                    credential: "synthetic-key", networkAuthorized: true)
        }
        #expect(!(ChatSearchError.transportFailure.errorDescription ?? "").contains("synthetic-key"))
    }
}
