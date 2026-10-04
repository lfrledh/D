import CryptoKit
import Darwin
import Foundation
import dnssd

/// Text extracted from fetched bytes. The digest covers the original response body, not this text.
/// Remote text remains untrusted data; callers must not treat it as instructions.
public struct ChatWebPageSource: Codable, Sendable, Equatable {
    public let url: URL
    /// The last URL actually fetched, without a fragment. Older saved sources omit this field.
    public let resolvedURL: URL?
    public let title: String
    public let text: String
    public let fetchedAt: Date
    public let contentSHA256: String
    public let extractorVersion: String
}

public enum ChatWebPageError: Error, Equatable, LocalizedError, Sendable {
    case permissionDenied, invalidURL, addressUnavailable, transportFailure, timedOut
    case redirectRejected, httpStatus(Int), unsupportedContentType, invalidResponse
    case responseTooLarge, sourceTooLarge, unsafeHTML, emptyContent

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow network access before reading a public page."
        case .invalidURL: "This reader accepts only public HTTPS URLs on port 443, without credentials."
        case .addressUnavailable: "No public IPv4 address was available for this page. IPv6-only pages are not supported yet."
        case .transportFailure: "The page could not be downloaded securely."
        case .timedOut: "The page download or DNS lookup timed out."
        case .redirectRejected: "The page redirected to an unsafe location, a loop, or beyond the three-hop limit."
        case .httpStatus(let status): "The page returned HTTP status \(status)."
        case .unsupportedContentType: "This reader supports UTF-8 HTML and plain text only."
        case .invalidResponse: "The page response could not be read."
        case .responseTooLarge: "The page download exceeds 2 MiB."
        case .sourceTooLarge: "The extracted page text exceeds 512 KiB."
        case .unsafeHTML: "The page contains a document type or entity declaration."
        case .emptyContent: "The page has no readable static text. Dynamic pages are not supported."
        }
    }
}

public struct ChatWebPageClient: Sendable {
    public static let maximumResponseBytes = 2 * 1024 * 1024
    public static let maximumTextBytes = 512 * 1024
    public static let maximumRedirects = 3
    private let transport: any ChatWebTransport
    private let now: @Sendable () -> Date

    public init(transport: any ChatWebTransport = PinnedChatWebPageTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    /// Checks URL syntax and public-address policy before showing a read action. DNS is checked during read.
    public static func validateReadURL(_ url: URL) throws {
        try ChatWebPagePolicy.validate(fetchURL(for: url))
    }

    private static func fetchURL(for url: URL) throws -> URL {
        guard url.absoluteString.utf8.count <= 2048 else { throw ChatWebPageError.invalidURL }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ChatWebPageError.invalidURL
        }
        parts.fragment = nil
        guard let fetchURL = parts.url else { throw ChatWebPageError.invalidURL }
        return fetchURL
    }

    public func read(_ url: URL, networkAuthorized: Bool) async throws -> ChatWebPageSource {
        guard networkAuthorized else { throw ChatWebPageError.permissionDenied }
        try Task.checkCancellation()
        var fetchURL = try Self.fetchURL(for: url)
        try ChatWebPagePolicy.validate(fetchURL)
        let deadline = ContinuousClock.now + .seconds(30)
        var visited: Set<URL> = []
        var redirects = 0
        var receivedBytes = 0
        var response: ChatWebHTTPResponse
        while true {
            try Task.checkCancellation()
            guard visited.insert(fetchURL).inserted else { throw ChatWebPageError.redirectRejected }
            guard receivedBytes < Self.maximumResponseBytes else { throw ChatWebPageError.responseTooLarge }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw ChatWebPageError.timedOut }
            var request = URLRequest(url: fetchURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: Self.seconds(remaining))
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            response = try await transport.send(request, maximumBytes: Self.maximumResponseBytes - receivedBytes)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ChatWebPageError.timedOut }
            guard response.url == fetchURL else { throw ChatWebPageError.redirectRejected }
            guard response.body.count <= Self.maximumResponseBytes - receivedBytes else {
                throw ChatWebPageError.responseTooLarge
            }
            receivedBytes += response.body.count
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard redirects < Self.maximumRedirects,
                      let location = response.location, !location.isEmpty,
                      !location.unicodeScalars.contains(where: { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) }),
                      let target = URL(string: location, relativeTo: fetchURL)?.absoluteURL else {
                    throw ChatWebPageError.redirectRejected
                }
                let next: URL
                do {
                    next = try Self.fetchURL(for: target)
                    try ChatWebPagePolicy.validate(next)
                }
                catch { throw ChatWebPageError.redirectRejected }
                fetchURL = next
                redirects += 1
                continue
            }
            break
        }
        if (300...399).contains(response.statusCode) { throw ChatWebPageError.redirectRejected }
        guard response.statusCode == 200 else { throw ChatWebPageError.httpStatus(response.statusCode) }
        guard response.body.count <= Self.maximumResponseBytes else { throw ChatWebPageError.responseTooLarge }
        let type = response.mimeType?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard type == "text/html" || type == "text/plain" else {
            throw ChatWebPageError.unsupportedContentType
        }
        let body = response.body
        let parsed = try await WorkflowCPU.run {
            try ChatWebPageExtractor.extract(body, type: type!)
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ChatWebPageError.timedOut }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return ChatWebPageSource(url: url, resolvedURL: fetchURL, title: parsed.title, text: parsed.text,
                                 fetchedAt: now(), contentSHA256: digest,
                                 extractorVersion: "d.static-html.v1")
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return max(0.001, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
}

// Kept internal so fixture tests can verify URL and command boundaries without launching curl.
enum ChatWebPagePolicy {
    static func validate(_ url: URL) throws {
        let raw = url.absoluteString
        guard raw.utf8.count <= 2048,
              !raw.unicodeScalars.contains(where: { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) }),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let host = parts.host?.lowercased(), !host.isEmpty, host.utf8.count <= 253,
              !host.hasSuffix("."), !host.contains(":"), !host.contains("%"),
              host == url.host?.lowercased(), parts.percentEncodedHost?.lowercased() == host else {
            throw ChatWebPageError.invalidURL
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard publicIPv4(host) else { throw ChatWebPageError.invalidURL }
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2,
                  !["local", "localhost", "internal", "invalid", "test", "example"].contains(String(labels.last!)),
                  labels.allSatisfy({ label in
                      !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                      label.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
                  }) else { throw ChatWebPageError.invalidURL }
            // Numeric-looking names may be accepted as alternate IPv4 notation by network stacks.
            guard host.utf8.contains(where: { (97...122).contains($0) }) else {
                throw ChatWebPageError.invalidURL
            }
        }
    }

    static func publicIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, (part.count == 1 || part.first != "0"),
                  part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt8(part)
        }
        guard octets.count == 4 else { return false }
        let a = octets[0], b = octets[1], c = octets[2]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && (b == 168 || (b == 0 && c == 0) || (b == 0 && c == 2) ||
                         (b == 88 && c == 99)) { return false }
        if a == 198 && ((b == 18 || b == 19) || (b == 51 && c == 100)) { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        return true
    }

    static func curlArguments(url: URL, address: String, bodyPath: String,
                              timeout: TimeInterval = 30, maximumBytes: Int = ChatWebPageClient.maximumResponseBytes) -> [String] {
        let host = url.host!.lowercased()
        let maximumTime = timeout == 30 ? "30" : String(format: "%.3f", max(0.001, timeout))
        return ["-q", "--globoff", "--silent", "--show-error", "--request", "GET",
                "--proto", "=https", "--proxy", "", "--noproxy", "*",
                "--resolve", "\(host):443:\(address)", "--connect-timeout", "10",
                "--max-time", maximumTime, "--max-filesize", String(maximumBytes),
                "--header", "Accept-Encoding: identity", "--output", bodyPath,
                "--write-out", "%{http_code}\n%{content_type}\n%{redirect_url}\n", url.absoluteString]
    }

    static func curlExitError(_ status: Int32) -> ChatWebPageError? {
        switch status {
        case 0: nil
        case 28: .timedOut
        case 63: .responseTooLarge
        default: .transportFailure
        }
    }
}

private enum ChatWebPageExtractor {
    static func extract(_ data: Data, type: String) throws -> (title: String, text: String) {
        guard let raw = String(data: data, encoding: .utf8) else { throw ChatWebPageError.invalidResponse }
        if type == "text/plain" {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ChatWebPageError.emptyContent }
            guard text.utf8.count <= ChatWebPageClient.maximumTextBytes else { throw ChatWebPageError.sourceTooLarge }
            return ("", text)
        }
        let safe = try withoutSafeDoctype(raw)
        // The input was strictly decoded as UTF-8. A BOM tells Foundation HTML tidy
        // to retain that encoding when the page has no charset declaration.
        let document: XMLDocument
        do { document = try XMLDocument(data: Data([0xef, 0xbb, 0xbf]) + Data(safe.utf8), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) }
        catch { throw ChatWebPageError.invalidResponse }
        guard let root = document.rootElement() else { throw ChatWebPageError.emptyContent }
        var title = "", text = "", nodes = 0, textBytes = 0
        let omitted: Set<String> = ["script", "style", "noscript", "iframe", "object", "embed", "svg",
                                    "template", "nav", "footer", "header", "form"]
        let blocks: Set<String> = ["p", "div", "section", "article", "main", "br", "li", "h1", "h2", "h3",
                                   "h4", "h5", "h6", "blockquote", "pre", "tr"]
        func append(_ piece: String) throws {
            let added = piece.utf8.count
            guard textBytes + added <= ChatWebPageClient.maximumTextBytes else {
                throw ChatWebPageError.sourceTooLarge
            }
            text += piece
            textBytes += added
        }
        func visit(_ node: XMLNode, depth: Int, inBody: Bool, inTitle: Bool) throws {
            nodes += 1
            guard nodes <= 50_000, depth <= 64 else { throw ChatWebPageError.sourceTooLarge }
            if node.kind == .text {
                let value = node.stringValue ?? ""
                if inTitle { title += value; guard title.utf8.count <= 4096 else { throw ChatWebPageError.sourceTooLarge }; return }
                if inBody { try append(value) }
                return
            }
            guard let element = node as? XMLElement else { return }
            let name = (element.name ?? "").lowercased()
            if omitted.contains(name) { return }
            let body = inBody || name == "body"
            let heading = inTitle || name == "title"
            if body && blocks.contains(name) && !text.isEmpty && !text.hasSuffix("\n") { try append("\n") }
            var cells = 0
            for child in element.children ?? [] {
                if body && name == "tr", let cell = child as? XMLElement,
                   ["td", "th"].contains((cell.name ?? "").lowercased()) {
                    if cells > 0 { try append("\t") }
                    cells += 1
                }
                try visit(child, depth: depth + 1, inBody: body, inTitle: heading)
            }
            if body && blocks.contains(name) && !text.hasSuffix("\n") { try append("\n") }
        }
        try visit(root, depth: 0, inBody: false, inTitle: false)
        text = text.split(whereSeparator: \.isNewline).map { line in
            // Tidy may insert formatting spaces at cell ends. Keep every cell separator,
            // including empty cells, while normalizing only surrounding display whitespace.
            line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\t")
        }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatWebPageError.emptyContent }
        return (title.trimmingCharacters(in: .whitespacesAndNewlines), text)
    }

    private static func withoutSafeDoctype(_ raw: String) throws -> String {
        func starts(_ token: String, at index: String.Index) -> Bool {
            raw.range(of: token, options: [.anchored, .caseInsensitive],
                      range: index..<raw.endIndex) != nil
        }
        func tagEnd(from start: String.Index) -> String.Index? {
            var cursor = start
            var quote: Character?
            while cursor < raw.endIndex {
                let character = raw[cursor]
                if let currentQuote = quote {
                    if character == currentQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    return raw.index(after: cursor)
                }
                cursor = raw.index(after: cursor)
            }
            return nil
        }
        var cursor = raw.startIndex
        var declarations: [Range<String.Index>] = []
        var rawTextElements: [Range<String.Index>] = []
        var sawElement = false
        while cursor < raw.endIndex {
            guard raw[cursor] == "<" else { cursor = raw.index(after: cursor); continue }
            if raw[cursor...].hasPrefix("<!--") {
                guard let end = raw.range(of: "-->", range: cursor..<raw.endIndex) else {
                    throw ChatWebPageError.unsafeHTML
                }
                cursor = end.upperBound
                continue
            }
            if starts("<!doctype", at: cursor) {
                guard !sawElement, let end = tagEnd(from: cursor) else { throw ChatWebPageError.unsafeHTML }
                let declaration = raw[cursor..<end].dropFirst(2).dropLast()
                let fields = declaration.split(whereSeparator: { " \t\n\r\u{000C}".contains($0) })
                let simple = fields.count == 2 && fields[0].lowercased() == "doctype" && fields[1].lowercased() == "html"
                let legacy = fields.count == 4 && fields[0].lowercased() == "doctype" &&
                    fields[1].lowercased() == "html" && fields[2].lowercased() == "system" &&
                    (fields[3] == "\"about:legacy-compat\"" || fields[3] == "'about:legacy-compat'")
                guard declarations.isEmpty, simple || legacy else { throw ChatWebPageError.unsafeHTML }
                declarations.append(cursor..<end)
                cursor = end
                continue
            }
            if starts("<!entity", at: cursor) || starts("<?xml", at: cursor) {
                throw ChatWebPageError.unsafeHTML
            }
            if starts("<script", at: cursor) || starts("<style", at: cursor) {
                let name = starts("<script", at: cursor) ? "script" : "style"
                let afterName = raw.index(cursor, offsetBy: name.count + 1)
                if afterName == raw.endIndex || " \t\n\r\u{000C}/>".contains(raw[afterName]) {
                    guard let openingEnd = tagEnd(from: cursor) else { break }
                    sawElement = true
                    var searchStart = openingEnd
                    var closingEnd: String.Index?
                    while let closing = raw.range(of: "</\(name)", options: .caseInsensitive,
                                                  range: searchStart..<raw.endIndex) {
                        let endOfName = closing.upperBound
                        if endOfName < raw.endIndex, " \t\n\r\u{000C}/>".contains(raw[endOfName]) {
                            closingEnd = tagEnd(from: closing.lowerBound)
                            break
                        }
                        searchStart = endOfName
                    }
                    let end = closingEnd ?? raw.endIndex
                    // Foundation's HTML4 recovery may treat </scripture> as </script>.
                    // These elements are omitted from extracted text anyway; remove the
                    // complete HTML raw-text region before asking it to recover the tree.
                    rawTextElements.append(cursor..<end)
                    cursor = end
                    continue
                }
            }
            if let end = tagEnd(from: cursor) {
                if raw.index(after: cursor) < raw.endIndex, raw[raw.index(after: cursor)] != "!" {
                    sawElement = true
                }
                cursor = end
            } else {
                break
            }
        }
        var safe = raw
        for range in (declarations + rawTextElements).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            safe.removeSubrange(range)
        }
        return safe
    }
}

/// Resolves exactly one IPv4 answer. DNS-SD is scheduled on a private serial queue so
/// cancellation and the ten-second deadline deallocate the query on that same queue.
private final class PageDNSQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.d.chat.page-dns")
    private var reference: DNSServiceRef?
    private var continuation: CheckedContinuation<String, Error>?
    private var completed = false

    static func resolve(_ host: String, timeout: TimeInterval) async throws -> String {
        if ChatWebPagePolicy.publicIPv4(host) { return host }
        let query = PageDNSQuery()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                query.queue.async { query.start(host, timeout: timeout, continuation: continuation) }
            }
        } onCancel: {
            query.queue.async { query.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ host: String, timeout: TimeInterval,
                       continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
        if completed { self.continuation = nil; continuation.resume(throwing: CancellationError()); return }
        let error = DNSServiceGetAddrInfo(&reference, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_IPv4),
                                          host, { _, _, _, code, _, address, _, context in
            guard let context else { return }
            let query = Unmanaged<PageDNSQuery>.fromOpaque(context).takeUnretainedValue()
            if code != kDNSServiceErr_NoError {
                query.queue.async { query.finish(.failure(ChatWebPageError.addressUnavailable)) }
                return
            }
            guard let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return }
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            var bytes = ipv4.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let value = withUnsafePointer(to: &bytes) { pointer in
                inet_ntop(AF_INET, pointer, &buffer, socklen_t(buffer.count))
            }
            guard value != nil else { return }
            let candidate = String(cString: buffer)
            if ChatWebPagePolicy.publicIPv4(candidate) {
                query.queue.async { query.finish(.success(candidate)) }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let reference else {
            finish(.failure(ChatWebPageError.addressUnavailable)); return
        }
        guard DNSServiceSetDispatchQueue(reference, queue) == kDNSServiceErr_NoError else {
            finish(.failure(ChatWebPageError.addressUnavailable)); return
        }
        queue.asyncAfter(deadline: .now() + min(10, timeout)) { [self] in
            finish(.failure(ChatWebPageError.timedOut))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard !completed else { return }
        completed = true
        if let reference { DNSServiceRefDeallocate(reference); self.reference = nil }
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

/// The production page transport pins a checked DNS answer to the original HTTPS host.
/// It owns one private temporary directory and one child process per request.
public struct PinnedChatWebPageTransport: ChatWebTransport {
    public init() {}

    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> ChatWebHTTPResponse {
        try Task.checkCancellation()
        guard request.httpMethod == "GET", request.httpBody == nil, let url = request.url,
              maximumBytes > 0, maximumBytes <= ChatWebPageClient.maximumResponseBytes,
              request.timeoutInterval > 0 else {
            throw ChatWebPageError.invalidURL
        }
        try ChatWebPagePolicy.validate(url)
        let deadline = ContinuousClock.now + .seconds(request.timeoutInterval)
        let address = try await PageDNSQuery.resolve(url.host!.lowercased(), timeout: request.timeoutInterval)
        try Task.checkCancellation()
        let remaining = Self.remaining(until: deadline)
        guard remaining > 0 else { throw ChatWebPageError.timedOut }
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = directory.appendingPathComponent("body")
        let metadata = directory.appendingPathComponent("metadata")
        let descriptor = open(metadata.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ChatWebPageError.transportFailure }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ChatWebPagePolicy.curlArguments(url: url, address: address,
                                                            bodyPath: body.path, timeout: remaining, maximumBytes: maximumBytes)
        process.environment = ["HOME": directory.path, "CURL_HOME": directory.path,
                               "XDG_CONFIG_HOME": directory.path, "LC_ALL": "C"]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let control = PageChildControl(process: process, timeout: remaining)
        do {
            try Task.checkCancellation()
            try process.run()
        } catch is CancellationError {
            try? output.close()
            throw CancellationError()
        } catch {
            try? output.close()
            throw ChatWebPageError.transportFailure
        }
        control.attach()
        let status = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        } onCancel: {
            control.stop(cancelled: true)
        }
        control.exited()
        try? output.close()
        try Task.checkCancellation()
        if control.didTimeOut { throw ChatWebPageError.timedOut }
        guard Self.remaining(until: deadline) > 0 else { throw ChatWebPageError.timedOut }
        if let error = ChatWebPagePolicy.curlExitError(status) { throw error }
        let meta = try Data(contentsOf: metadata)
        guard meta.count <= 4096, let result = String(data: meta, encoding: .utf8) else {
            throw ChatWebPageError.invalidResponse
        }
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 4, lines[3].isEmpty,
              let statusCode = Int(lines[0]), (100...599).contains(statusCode) else {
            throw ChatWebPageError.invalidResponse
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: body.path)[.size] as? NSNumber)?.intValue
        guard let size else { throw ChatWebPageError.invalidResponse }
        guard size <= maximumBytes else { throw ChatWebPageError.responseTooLarge }
        let bytes = try Data(contentsOf: body)
        guard bytes.count <= maximumBytes else { throw ChatWebPageError.responseTooLarge }
        return .init(statusCode: statusCode, mimeType: String(lines[1]), url: url, body: bytes,
                     location: lines[2].isEmpty ? nil : String(lines[2]))
    }

    private static func remaining(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let parts = (deadline - ContinuousClock.now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func privateDirectory() throws -> URL {
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("d-page-XXXXXX").path
        var name = Array(template.utf8CString)
        guard name.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) != nil else {
            throw ChatWebPageError.transportFailure
        }
        return URL(fileURLWithPath: String(cString: name), isDirectory: true)
    }
}

// Process is confined to this owned child. Cancellation records intent before attach,
// then TERM is escalated to KILL after one second; the caller still waits for actual exit.
private final class PageChildControl: @unchecked Sendable {
    private let process: Process
    private let timeoutInterval: TimeInterval
    private let lock = NSLock()
    private var attached = false
    private var finished = false
    private var stopped = false
    private var timeout = false

    init(process: Process, timeout: TimeInterval) {
        self.process = process
        self.timeoutInterval = timeout
    }

    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timeout }

    func attach() {
        lock.lock()
        attached = true
        let shouldStop = stopped
        lock.unlock()
        if shouldStop { terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutInterval) { [self] in
            stop(cancelled: false)
        }
    }

    func stop(cancelled: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if !cancelled { timeout = true }
        let first = !stopped
        stopped = true
        let ready = attached
        lock.unlock()
        if first && ready { terminate() }
    }

    func exited() {
        lock.lock(); finished = true; lock.unlock()
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            let pid = !finished && process.isRunning ? process.processIdentifier : 0
            lock.unlock()
            if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
        }
    }
}
