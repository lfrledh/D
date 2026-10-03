import Foundation
import MCP

/// Values crossing into the UI are local copies. Server text, schemas and results are untrusted.
public struct ChatMCPTool: Sendable, Equatable {
    public let name: String
    public let title: String?
    public let description: String?
    public let inputSchemaJSON: String
}

public struct ChatMCPCallResult: Sendable, Equatable {
    public let toolName: String
    public let resultJSON: String
    public let isError: Bool
}

public enum ChatMCPStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(endpoint: String)
    case stopping
    /// Local transport and owned work have stopped; server-side completion is unknown.
    case localStoppedServerUnknown
}

public enum ChatMCPError: Error, Sendable, Equatable {
    case permissionDenied
    case invalidEndpoint
    case invalidArguments
    case notConnected
    case busy
    case unknownTool
    case catalogLimit
    case resultLimit
    case timedOut
    case cancelled
    case connectionFailed
    case requestFailed
}

/// URLSession's delegate is the last boundary before the SDK can forward a request body.
private final class ChatMCPURLSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
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

/// One explicit MCP endpoint and one operation at a time. This service never handles reverse requests.
public actor ChatMCPService {
    private struct OperationIdentity: Hashable, Sendable {
        let generation: Int
        let sequence: Int
    }

    public static let maximumEndpointBytes = 2 * 1024
    public static let maximumArgumentBytes = 256 * 1024
    public static let maximumResultBytes = 2 * 1024 * 1024
    public static let maximumTools = 64
    public static let maximumPages = 10

    private var client: MCP.Client?
    private var session: URLSession?
    private var names: Set<String> = []
    private var generation = 0
    private var operationSequence = 0
    private var activeOperation: OperationIdentity?
    private var stoppingOperation: OperationIdentity?
    private var activeTask: Task<Void, Never>?
    private var activeCancel: (@Sendable () -> Void)?
    private var activeContext: RequestContext<CallTool.Result>?
    private var timeoutTask: Task<Void, Never>?
    private var stopReasons: [OperationIdentity: ChatMCPError] = [:]
    private var stopping = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentStatus: ChatMCPStatus = .disconnected
    private let testingProtocolClasses: [AnyClass]?

    public init() { testingProtocolClasses = nil }

    /// Keeps lifecycle tests on the SDK's injected URLSession path.
    internal init(testingProtocolClasses: [AnyClass]) {
        self.testingProtocolClasses = testingProtocolClasses
    }

    public func status() -> ChatMCPStatus { currentStatus }

    /// Only an explicit caller choice authorizes this exact endpoint. No credentials are accepted.
    public func connect(endpoint rawEndpoint: String, permitted: Bool, timeoutSeconds: Int = 30) async throws {
        guard permitted else { throw ChatMCPError.permissionDenied }
        let url = try Self.validateEndpoint(rawEndpoint)
        guard client == nil, activeTask == nil, !stopping else { throw ChatMCPError.busy }
        let configuration = URLSessionConfiguration.ephemeral
        if let testingProtocolClasses { configuration.protocolClasses = testingProtocolClasses }
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = TimeInterval(Self.boundedTimeout(timeoutSeconds))
        configuration.timeoutIntervalForResource = TimeInterval(Self.boundedTimeout(timeoutSeconds))
        let session = URLSession(configuration: configuration, delegate: ChatMCPURLSessionDelegate(), delegateQueue: nil)
        let transport = HTTPClientTransport(endpoint: url, session: session, streaming: true,
                                            authorizer: nil)
        let client = MCP.Client(name: "DWorkbench", version: "1", capabilities: .init(),
                                configuration: .strict)
        self.client = client
        self.session = session
        generation &+= 1
        let connectionGeneration = generation
        currentStatus = .connecting
        do {
            try await run(timeoutSeconds: timeoutSeconds) { token in
                do {
                    try await self.requireCurrent(token)
                    try Task.checkCancellation()
                    _ = try await client.connect(transport: transport)
                    try await self.requireCurrent(token)
                } catch {
                    // A stop may have disconnected before a delayed SDK connect begins.
                    // Close this captured client even if another connection now owns self.client.
                    await client.disconnect()
                    session.invalidateAndCancel()
                    throw error
                }
            }
            try Task.checkCancellation()
            guard connectionGeneration == generation, client === self.client else {
                throw ChatMCPError.cancelled
            }
            currentStatus = .connected(endpoint: rawEndpoint)
        } catch {
            let mapped = Self.map(error, fallback: .connectionFailed)
            if client === self.client { await stop(reason: mapped) }
            throw mapped
        }
    }

    /// Lists at most ten pages and 64 tools. A repeated cursor is rejected.
    public func listTools(timeoutSeconds: Int = 30) async throws -> [ChatMCPTool] {
        guard let client, case .connected = currentStatus else { throw ChatMCPError.notConnected }
        do { return try await run(timeoutSeconds: timeoutSeconds) { token in
            var result: [ChatMCPTool] = []
            var names = Set<String>()
            var cursors = Set<String>()
            var cursor: String?
            var totalBytes = 0
            for page in 0..<Self.maximumPages {
                try await self.requireCurrent(token)
                let response = try await client.listTools(cursor: cursor)
                try await self.requireCurrent(token)
                if result.count + response.tools.count > Self.maximumTools { throw ChatMCPError.catalogLimit }
                for tool in response.tools {
                    guard !tool.name.isEmpty, names.insert(tool.name).inserted else {
                        throw ChatMCPError.catalogLimit
                    }
                    let data = try JSONEncoder().encode(tool.inputSchema)
                    totalBytes += data.count + tool.name.utf8.count
                        + (tool.title?.utf8.count ?? 0) + (tool.description?.utf8.count ?? 0)
                    guard totalBytes <= Self.maximumResultBytes,
                          let schema = String(data: data, encoding: .utf8) else {
                        throw ChatMCPError.catalogLimit
                    }
                    result.append(ChatMCPTool(name: tool.name, title: tool.title,
                                              description: tool.description, inputSchemaJSON: schema))
                }
                guard let next = response.nextCursor else {
                    try await self.storeNames(names, token: token)
                    return result
                }
                guard page + 1 < Self.maximumPages, !next.isEmpty,
                      cursors.insert(next).inserted else { throw ChatMCPError.catalogLimit }
                cursor = next
            }
            throw ChatMCPError.catalogLimit
        } } catch { throw Self.map(error, fallback: .requestFailed) }
    }

    /// Call permission is separate from endpoint permission and applies to these exact arguments.
    public func callTool(name: String, argumentsJSON: String, permitted: Bool,
                         timeoutSeconds: Int = 30) async throws -> ChatMCPCallResult {
        guard permitted else { throw ChatMCPError.permissionDenied }
        let arguments = try Self.parseArguments(argumentsJSON)
        guard let client, case .connected = currentStatus else { throw ChatMCPError.notConnected }
        guard names.contains(name) else { throw ChatMCPError.unknownTool }
        do { return try await run(timeoutSeconds: timeoutSeconds) { token in
            let context: RequestContext<CallTool.Result> = try await client.callTool(
                name: name, arguments: arguments)
            try await self.storeContext(context, token: token, client: client)
            let result = try await context.value
            try await self.requireCurrent(token)
            let data = try JSONEncoder().encode(result)
            guard data.count <= Self.maximumResultBytes,
                  let json = String(data: data, encoding: .utf8) else { throw ChatMCPError.resultLimit }
            return ChatMCPCallResult(toolName: name, resultJSON: json, isError: result.isError == true)
        } } catch { throw Self.map(error, fallback: .requestFailed) }
    }

    /// Sends an advisory protocol cancellation where a request ID exists, then drains locally.
    public func cancel() async {
        await stop(reason: .cancelled)
    }

    /// Invalidates this transport; it does not issue an HTTP DELETE.
    public func disconnect() async {
        await stop(reason: nil)
    }

    public static func validateEndpoint(_ raw: String) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= maximumEndpointBytes,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(),
              let parsedHost = parts.host?.lowercased(),
              !parsedHost.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url, url.scheme?.lowercased() == scheme else {
            throw ChatMCPError.invalidEndpoint
        }
        let host = parsedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard scheme == "https" || (scheme == "http" && (host == "127.0.0.1" || host == "::1")) else {
            throw ChatMCPError.invalidEndpoint
        }
        return url
    }

    public static func parseArguments(_ json: String) throws -> [String: Value] {
        guard json.utf8.count <= maximumArgumentBytes, let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              let arguments = try? JSONDecoder().decode([String: Value].self, from: data) else {
            throw ChatMCPError.invalidArguments
        }
        return arguments
    }

    private static func boundedTimeout(_ requested: Int) -> Int { min(120, max(1, requested)) }

    private func requireCurrent(_ token: Int) throws {
        guard token == generation else { throw ChatMCPError.cancelled }
        try Task.checkCancellation()
    }

    private func storeNames(_ newNames: Set<String>, token: Int) throws {
        try requireCurrent(token)
        names = newNames
    }

    private func storeContext(_ context: RequestContext<CallTool.Result>, token: Int,
                              client: MCP.Client) async throws {
        guard token == generation else {
            try? await client.cancelRequest(context.requestID, reason: "Local operation stopped")
            throw ChatMCPError.cancelled
        }
        activeContext = context
        try Task.checkCancellation()
    }

    private func run<T: Sendable>(timeoutSeconds: Int,
                                  operation: @escaping @Sendable (Int) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard activeTask == nil, !stopping else { throw ChatMCPError.busy }
        let token = generation
        operationSequence &+= 1
        let identity = OperationIdentity(generation: token, sequence: operationSequence)
        let task = Task { try await operation(token) }
        activeOperation = identity
        activeTask = Task { _ = await task.result }
        activeCancel = { task.cancel() }
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(Int64(Self.boundedTimeout(timeoutSeconds))))
            if !Task.isCancelled { await self.expire(identity) }
        }
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.stop(reason: .cancelled, matching: identity) }
            }
            if Task.isCancelled {
                await stop(reason: .cancelled, matching: identity)
                throw ChatMCPError.cancelled
            }
            if activeOperation == identity {
                timeoutTask?.cancel()
                timeoutTask = nil
                activeTask = nil
                activeCancel = nil
                activeContext = nil
                activeOperation = nil
                return value
            }
            if stoppingOperation == identity {
                await withCheckedContinuation { stopWaiters.append($0) }
            }
            throw stopReasons.removeValue(forKey: identity) ?? .cancelled
        } catch {
            if Task.isCancelled {
                await stop(reason: .cancelled, matching: identity)
            } else if stoppingOperation == identity {
                await withCheckedContinuation { stopWaiters.append($0) }
            }
            if activeOperation == identity {
                timeoutTask?.cancel()
                timeoutTask = nil
                activeTask = nil
                activeCancel = nil
                activeContext = nil
                activeOperation = nil
            }
            if let stopped = stopReasons.removeValue(forKey: identity) { throw stopped }
            if Task.isCancelled { throw ChatMCPError.cancelled }
            throw error
        }
    }

    private func expire(_ identity: OperationIdentity) async {
        await stop(reason: .timedOut, matching: identity)
    }

    private func stop(reason: ChatMCPError?, matching identity: OperationIdentity? = nil) async {
        if stopping {
            if let identity, identity != stoppingOperation { return }
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        if let identity, identity != activeOperation { return }
        guard client != nil || activeTask != nil else {
            if reason == nil { currentStatus = .disconnected }
            return
        }
        stopping = true
        stoppingOperation = activeOperation
        generation &+= 1
        if let activeOperation { stopReasons[activeOperation] = reason ?? .cancelled }
        let oldClient = client
        let oldSession = session
        let oldTask = activeTask
        let oldCancel = activeCancel
        let oldContext = activeContext
        client = nil
        session = nil
        names = []
        activeTask = nil
        activeOperation = nil
        activeCancel = nil
        activeContext = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        currentStatus = .stopping
        if let oldContext, let oldClient {
            // The SDK removes its pending request locally before attempting notification.
            let advisory = Task { try? await oldClient.cancelRequest(oldContext.requestID,
                                                                      reason: "Local operation stopped") }
            oldCancel?()
            await oldClient.disconnect()
            oldSession?.invalidateAndCancel()
            _ = await advisory.result
        } else {
            oldCancel?()
            if let oldClient { await oldClient.disconnect() }
            oldSession?.invalidateAndCancel()
        }
        _ = await oldTask?.value
        currentStatus = reason == nil ? .disconnected : .localStoppedServerUnknown
        stopping = false
        stoppingOperation = nil
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private static func map(_ error: Error, fallback: ChatMCPError) -> ChatMCPError {
        if let error = error as? ChatMCPError { return error }
        if error is CancellationError { return .cancelled }
        return fallback
    }
}
