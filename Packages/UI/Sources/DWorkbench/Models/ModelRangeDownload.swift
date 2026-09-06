import Darwin
import Foundation
import Synchronization

struct ModelByteRange: Sendable {
    let url: URL
    let start: UInt64
    let end: UInt64
    let total: UInt64
    var count: UInt64 { end - start + 1 }
}

protocol ModelRangeTransport: Sendable {
    func download(_ range: ModelByteRange, to descriptor: Int32) async throws
}

struct URLSessionModelRangeTransport: ModelRangeTransport {
    let allowsLocalHTTP: Bool
    init(allowsLocalHTTP: Bool = false) { self.allowsLocalHTTP = allowsLocalHTTP }

    func download(_ range: ModelByteRange, to descriptor: Int32) async throws {
        let receiver = try ModelRangeReceiver(range: range, descriptor: descriptor, allowsLocalHTTP: allowsLocalHTTP)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: range.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("D-ModelLibrary/1", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in receiver.start(task, continuation: continuation) }
        } onCancel: { receiver.cancel() }
    }
}

/// URLSession sends bounded Data chunks; no complete response is accumulated in memory.
/// Mutable transfer state is protected by Mutex, including cancellation before task startup.
private final class ModelRangeReceiver: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Void, any Error>?
        var received: UInt64 = 0
        var accepted = false
        var failure: (any Error)?
        var cancelled = false
    }
    private let state = Mutex(State())
    private let range: ModelByteRange
    private let descriptor: Int32
    private let allowsLocalHTTP: Bool

    init(range: ModelByteRange, descriptor: Int32, allowsLocalHTTP: Bool) throws {
        guard range.start <= range.end, range.end < range.total, range.count <= 16 * 1024 * 1024 else {
            throw ModelLibraryError.download("下载分段范围无效。")
        }
        self.range = range
        self.allowsLocalHTTP = allowsLocalHTTP
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
        guard let url else { return false }
        return url.scheme == "https" || (allowsLocalHTTP && url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard allowed(request.url) else {
            state.withLock { $0.failure = ModelLibraryError.download("下载重定向不安全，已停止。") }
            completionHandler(nil); task.cancel(); return
        }
        var redirected = request
        redirected.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let expectedRange = "bytes \(range.start)-\(range.end)/\(range.total)"
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
            if let failure = value.failure ?? error { return (continuation, failure) }
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
