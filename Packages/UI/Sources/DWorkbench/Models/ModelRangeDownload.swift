import Darwin
import Foundation
import Synchronization

struct ModelByteRange: Sendable {
    let url: URL
    let start: UInt64
    let end: UInt64
    let total: UInt64
    var credential: ModelDownloadCredential? = nil
    var authorizedPath: String? = nil
    var count: UInt64 { end - start + 1 }
}

protocol ModelRangeTransport: Sendable {
    func download(_ range: ModelByteRange, to descriptor: Int32) async throws
}

struct URLSessionModelRangeTransport: ModelRangeTransport {
    let allowsLocalHTTP: Bool
    init(allowsLocalHTTP: Bool = false) { self.allowsLocalHTTP = allowsLocalHTTP }

    func download(_ range: ModelByteRange, to descriptor: Int32) async throws {
        try Task.checkCancellation()
        guard range.start <= range.end, range.end < range.total,
              range.count <= 16 * 1024 * 1024 else {
            throw ModelLibraryError.download("下载分段范围无效。")
        }
        let token: String?
        if let credential = range.credential {
            guard ModelDownloadRequestPolicy.isHuggingFaceResolve(range.url, path: range.authorizedPath) else {
                throw ModelLibraryError.download("令牌下载来源不符合固定仓库路径。")
            }
            token = try credential.token()
        } else { token = nil }
        let receiver = try ModelRangeReceiver(range: range, descriptor: descriptor,
                                              allowsLocalHTTP: allowsLocalHTTP, token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let request = ModelDownloadRequestPolicy.request(url: range.url, range: range, token: token)
        let task = session.dataTask(with: request)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in receiver.start(task, continuation: continuation) }
            } onCancel: { receiver.cancel() }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ModelLibraryError { throw error }
        catch { throw ModelLibraryError.download("网络下载失败；请检查连接后重试。") }
    }
}

enum ModelDownloadRequestPolicy {
    static func safe(_ url: URL?, allowsLocalHTTP: Bool = false) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let host = parts.host, !host.isEmpty else { return false }
        if parts.scheme == "https" { return parts.port == nil || parts.port == 443 }
        return allowsLocalHTTP && parts.scheme == "http" &&
            ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    static func isHuggingFaceResolve(_ url: URL?, path: String?) -> Bool {
        guard safe(url), let url, let path,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host?.lowercased() == "huggingface.co", url.path == path else { return false }
        let sections = path.split(separator: "/", omittingEmptySubsequences: false)
        return sections.count >= 6 && sections[0].isEmpty && sections[3] == "resolve" &&
            sections.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func request(url: URL, range: ModelByteRange, token: String?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func redirect(to url: URL?, range: ModelByteRange, token: String?,
                         mayAuthenticate: inout Bool, allowsLocalHTTP: Bool = false) -> URLRequest? {
        guard safe(url, allowsLocalHTTP: allowsLocalHTTP), let url else { return nil }
        mayAuthenticate = mayAuthenticate && isHuggingFaceResolve(url, path: range.authorizedPath)
        return request(url: url, range: range, token: mayAuthenticate ? token : nil)
    }
}

/// URLSession sends bounded Data chunks; no complete response is accumulated in memory.
/// Mutable transfer state is protected by Mutex, including cancellation before task startup.
final class ModelRangeReceiver: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Void, any Error>?
        var received: UInt64 = 0
        var accepted = false
        var failure: (any Error)?
        var cancelled = false
        var redirectMayAuthenticate = true
    }
    private let state = Mutex(State())
    private let range: ModelByteRange
    private let descriptor: Int32
    private let allowsLocalHTTP: Bool
    private let token: String?

    init(range: ModelByteRange, descriptor: Int32, allowsLocalHTTP: Bool, token: String?) throws {
        guard range.start <= range.end, range.end < range.total, range.count <= 16 * 1024 * 1024 else {
            throw ModelLibraryError.download("下载分段范围无效。")
        }
        self.range = range
        self.allowsLocalHTTP = allowsLocalHTTP
        self.token = token
        guard ModelDownloadRequestPolicy.safe(range.url, allowsLocalHTTP: allowsLocalHTTP) else {
            throw ModelLibraryError.download("下载来源 URL 不安全。")
        }
        self.descriptor = Darwin.dup(descriptor)
        guard self.descriptor >= 0 else { throw ModelDirectory.failure("复制下载文件引用") }
    }
    deinit { Darwin.close(descriptor) }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, any Error>) {
        let cancelled = state.withLock { value in
            value.task = task
            if value.cancelled { return true }
            value.continuation = continuation
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        else { task.resume() }
    }
    func cancel() {
        let task = state.withLock { value in value.cancelled = true; return value.task }
        task?.cancel()
    }
    private func allowed(_ url: URL?) -> Bool {
        ModelDownloadRequestPolicy.safe(url, allowsLocalHTTP: allowsLocalHTTP)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let redirected = state.withLock { value in
            ModelDownloadRequestPolicy.redirect(to: request.url, range: range, token: token,
                mayAuthenticate: &value.redirectMayAuthenticate, allowsLocalHTTP: allowsLocalHTTP)
        }
        guard let redirected else {
            state.withLock { $0.failure = ModelLibraryError.download("下载重定向不安全，已停止。") }
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let expectedRange = "bytes \(range.start)-\(range.end)/\(range.total)"
        if let http = response as? HTTPURLResponse, allowed(http.url), [401, 403].contains(http.statusCode) {
            state.withLock { $0.failure = ModelLibraryError.accessDenied("模型来源拒绝访问（HTTP \(http.statusCode)）；请在来源平台完成所需访问手续。") }
            completionHandler(.cancel); return
        }
        guard let http = response as? HTTPURLResponse, allowed(http.url), http.statusCode == 206,
              http.value(forHTTPHeaderField: "Content-Range") == expectedRange,
              http.value(forHTTPHeaderField: "Content-Length").flatMap(UInt64.init) == range.count,
              [nil, "identity"].contains(http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()) else {
            state.withLock { $0.failure = ModelLibraryError.download("服务器未返回准确的 206 分段范围或长度，已停止下载。") }
            completionHandler(.cancel); return
        }
        state.withLock { $0.accepted = true }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stop = state.withLock { value -> Bool in
            guard value.accepted, !value.cancelled, value.failure == nil else { return true }
            guard UInt64(data.count) <= range.count - value.received else {
                value.failure = ModelLibraryError.download("下载内容超过声明的分段长度。"); return true
            }
            do { try ModelDirectory.write(data, to: descriptor); value.received += UInt64(data.count); return false }
            catch { value.failure = error; return true }
        }
        if stop { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result = state.withLock { value -> (CheckedContinuation<Void, any Error>?, (any Error)?) in
            let continuation = value.continuation
            value.continuation = nil; value.task = nil
            if value.cancelled { return (continuation, CancellationError()) }
            if let failure = value.failure { return (continuation, failure) }
            if error != nil { return (continuation, ModelLibraryError.download("网络下载失败；请检查连接后重试。")) }
            guard value.accepted, value.received == range.count else {
                return (continuation, ModelLibraryError.download("下载分段不完整；已保留前面的完整分段。"))
            }
            guard fsync(descriptor) == 0 else { return (continuation, ModelDirectory.failure("保存下载分段")) }
            return (continuation, nil)
        }
        if let failure = result.1 { result.0?.resume(throwing: failure) }
        else { result.0?.resume() }
    }
}
