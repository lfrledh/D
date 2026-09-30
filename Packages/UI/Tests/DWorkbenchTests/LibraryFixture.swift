import CryptoKit
import Darwin
import Foundation
@testable import DWorkbench

struct ReleaseLibraryFixture {
    let root: URL
    let state: URL
    let destination: URL
    init() throws {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try ModelDirectory.canonicalURL(base).appendingPathComponent("D-ReleaseLibrary-" + UUID().uuidString)
        state = root.appendingPathComponent("state")
        destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func library(_ entries: [ModelCatalogEntry], transport: any ModelRangeTransport) async throws -> ModelLibrary {
        try await ModelLibrary(stateDirectory: state, catalog: entries, transport: transport,
                               sourceBaseURL: URL(string: "http://127.0.0.1:54321"), availableBytesOverride: 100 * 1024 * 1024)
    }
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func gitBlob(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8)); hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

actor ReleaseFixtureTransport: ModelRangeTransport {
    let contents: [String: Data]
    private(set) var paths: [String] = []
    init(contents: [String: Data]) { self.contents = contents }
    func download(_ range: ModelByteRange, to descriptor: Int32) async throws {
        let path = range.url.path
        paths.append(path)
        guard let data = contents[path], range.end < UInt64(data.count) else {
            throw ModelLibraryError.download("Unexpected fixture URL: \(path)")
        }
        let chunk = data[Int(range.start)...Int(range.end)]
        try Data(chunk).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw ModelLibraryError.download("Fixture write failed") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw ModelLibraryError.download("Fixture sync failed") }
    }
}

func releaseWait(_ library: ModelLibrary, id: ModelID) async throws -> ModelRecord {
    for _ in 0..<500 {
        if let record = await library.snapshot().records.first(where: { $0.id == id }),
           [.installed, .preparationRequired, .failed].contains(record.state) { return record }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ModelLibraryError.download("Fixture worker did not finish")
}

final class ReleaseDeniedHTTPFixture {
    let process: Process
    let url: URL
    init(root: URL, status: Int) async throws {
        let portFile = root.appendingPathComponent("denied-port-\(status)")
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.script, String(status), portFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var port: Int?
        for _ in 0..<300 {
            if let value = try? String(contentsOf: portFile, encoding: .utf8),
               let parsed = Int(value), (1...65535).contains(parsed) { port = parsed; break }
            guard process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let port, let resolved = URL(string: "http://127.0.0.1:\(port)/model.bin") else {
            if process.isRunning { process.terminate() }
            throw ModelLibraryError.download("Denied fixture server failed to start")
        }
        url = resolved
    }
    deinit { if process.isRunning { process.terminate() } }
    private static let script = #"""
import sys, os
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
status, portfile = int(sys.argv[1]), sys.argv[2]
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.send_response(status)
        self.send_header('Content-Length', '0')
        self.end_headers()
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(portfile, 'w') as output: output.write(str(server.server_port))
server.serve_forever()
"""#
}
