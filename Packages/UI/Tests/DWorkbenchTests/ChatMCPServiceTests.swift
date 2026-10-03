import Foundation
import Testing
@testable import DWorkbench

private actor MCPHTTPFixture {
    private var initializeCount = 0
    private var firstStarted: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    func waitForFirstInitialize() async {
        if initializeCount > 0 { return }
        await withCheckedContinuation { firstStarted.append($0) }
    }

    func releaseFirstInitialize() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func response(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let url = try #require(request.url)
        if request.httpMethod == "GET" {
            return (HTTPURLResponse(url: url, statusCode: 405, httpVersion: "HTTP/1.1",
                                    headerFields: [:])!, Data())
        }
        let body = try #require(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let method = try #require(json["method"] as? String)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        if method == "notifications/initialized" { return (response, Data()) }
        let id = try #require(json["id"] as? String)
        if method == "initialize" {
            initializeCount += 1
            if initializeCount == 1 {
                let waiters = firstStarted
                firstStarted = []
                for waiter in waiters { waiter.resume() }
                await withCheckedContinuation { firstRelease = $0 }
            }
            let result: [String: Any] = [
                "protocolVersion": "2025-11-25",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "fixture", "version": "1"]
            ]
            return (response, try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result
            ]))
        }
        if method == "tools/list" {
            return (response, try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": ["tools": []]
            ]))
        }
        throw ChatMCPError.requestFailed
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class MCPFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = MCPHTTPFixture()
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        responseTask = Task {
            do {
                let (response, data) = try await Self.fixture.response(for: request)
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
    }

    override func stopLoading() { responseTask?.cancel() }
}

@Suite("MCP local permission and input boundary")
struct ChatMCPServiceTests {
    @Test func endpointValidationAllowsOnlyExplicitSecureOrLiteralLoopbackRoutes() throws {
        #expect(try ChatMCPService.validateEndpoint("https://example.org/mcp").absoluteString == "https://example.org/mcp")
        #expect(try ChatMCPService.validateEndpoint("http://127.0.0.1:8765/mcp").host == "127.0.0.1")
        let ipv6Host = try ChatMCPService.validateEndpoint("http://[::1]/mcp").host
        #expect(ipv6Host == "[::1]" || ipv6Host == "::1")
        for rejected in [
            "http://example.org/mcp", "http://localhost/mcp", "http://127.0.0.2/mcp",
            "http://[::2]/mcp", "file:///tmp/mcp", "https://user:pass@example.org/mcp",
            "https://example.org/mcp#secret", " https://example.org/mcp",
            String(repeating: "a", count: ChatMCPService.maximumEndpointBytes + 1)
        ] {
            #expect(throws: ChatMCPError.invalidEndpoint) {
                try ChatMCPService.validateEndpoint(rejected)
            }
        }
    }

    @Test func argumentsMustBeBoundedJSONObject() throws {
        let args = try ChatMCPService.parseArguments("{\"count\":2,\"nested\":{\"ok\":true}}")
        #expect(args["count"]?.intValue == 2)
        #expect(args["nested"]?.objectValue?["ok"]?.boolValue == true)
        for rejected in ["[]", "null", "42", "{", String(repeating: "x", count: ChatMCPService.maximumArgumentBytes + 1)] {
            #expect(throws: ChatMCPError.invalidArguments) {
                try ChatMCPService.parseArguments(rejected)
            }
        }
    }

    @Test func noPermissionMeansNoConnectionOrToolRequest() async {
        let service = ChatMCPService()
        await #expect(throws: ChatMCPError.permissionDenied) {
            try await service.connect(endpoint: "https://example.org/mcp", permitted: false)
        }
        await #expect(throws: ChatMCPError.permissionDenied) {
            try await service.callTool(name: "read", argumentsJSON: "{}", permitted: false)
        }
        #expect(await service.status() == .disconnected)
    }

    @Test func cancelledInitializationDrainsBeforeNextConnection() async throws {
        let service = ChatMCPService(testingProtocolClasses: [MCPFixtureURLProtocol.self])
        let first = Task {
            try await service.connect(endpoint: "https://example.org/mcp", permitted: true)
        }
        await MCPFixtureURLProtocol.fixture.waitForFirstInitialize()
        first.cancel()
        await MCPFixtureURLProtocol.fixture.releaseFirstInitialize()
        await #expect(throws: ChatMCPError.cancelled) { try await first.value }

        try await service.connect(endpoint: "https://example.org/mcp", permitted: true)
        #expect(await service.status() == .connected(endpoint: "https://example.org/mcp"))
        #expect(try await service.listTools().isEmpty)
        await service.disconnect()
        #expect(await service.status() == .disconnected)
    }
}
