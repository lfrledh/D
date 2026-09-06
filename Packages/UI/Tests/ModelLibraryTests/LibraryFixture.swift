import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DWorkbench

struct LibraryFixture: Sendable {
    let root: URL
    let source: URL
    let state: URL
    let destination: URL
    let entry: ModelCatalogEntry
    let contents: [String: Data]
    init(large: Bool = false, payloadBytes: Int? = nil) throws {
        let temporary = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        root = try ModelDirectory.canonicalURL(temporary).appendingPathComponent("D-ModelLibraryTests-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); state = root.appendingPathComponent("state")
        destination = root.appendingPathComponent("destination")
        contents = ["weights/payload.bin": Data(repeating: 0x47, count: payloadBytes ?? (large ? 18 * 1024 * 1024 : 4096)),
                    "config.json": Data("{\"fixture\":true}".utf8)]
        entry = .init(id: "fixture", title: "CPU fixture", repository: "fixture/model", revision: String(repeating: "a", count: 40),
            files: contents.sorted { $0.key < $1.key }.map { path, data in
                .init(path: path, size: UInt64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }, imageProfile: .flux2Klein)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try writeModel(at: source)
    }
    func writeModel(at url: URL) throws {
        for (path, data) in contents {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }
    func library(server: LoopbackServer? = nil, availableBytes: UInt64? = nil) async throws -> ModelLibrary {
        try await ModelLibrary(stateDirectory: state, catalog: [entry],
            transport: URLSessionModelRangeTransport(allowsLocalHTTP: true), sourceBaseURL: server?.url,
            availableBytesOverride: availableBytes)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

/// Python is only a local test HTTP peer. The shipping library uses native URLSession.
final class LoopbackServer {
    let process: Process
    let url: URL
    let control: URL
    let events: URL
    init(_ fixture: LibraryFixture, mode: String = "valid") async throws {
        control = fixture.root.appendingPathComponent("http-mode.json")
        events = fixture.root.appendingPathComponent("http-events.jsonl")
        let portFile = fixture.root.appendingPathComponent("http-port")
        try JSONSerialization.data(withJSONObject: ["mode": mode]).write(to: control)
        process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.script, fixture.source.path, control.path, events.path, portFile.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let port = try? String(contentsOf: portFile, encoding: .utf8), let address = URL(string: "http://127.0.0.1:" + port) else {
            process.terminate(); throw ModelLibraryError.download("Fixture HTTP server failed to start")
        }
        url = address
    }
    deinit { if process.isRunning { process.terminate() } }
    func setMode(_ mode: String) throws {
        try JSONSerialization.data(withJSONObject: ["mode": mode]).write(to: control, options: .atomic)
    }
    func eventRows() throws -> [[String: Any]] {
        guard let data = try? String(contentsOf: events, encoding: .utf8) else { return [] }
        return try data.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    static let script = #"""
import sys, os, json, time, re, threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
root, control, events, portfile = sys.argv[1:]
lock = threading.Lock()
active = 0
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    def log_message(self, *args): pass
    def do_GET(self):
        global active
        mode = json.load(open(control))['mode']
        relative = urlparse(self.path).path
        if '/resolve/' in relative: relative = '/'.join(relative.split('/resolve/')[1].split('/')[1:])
        else: relative = relative.lstrip('/')
        data = open(os.path.join(root, relative), 'rb').read()
        match = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers.get('Range', ''))
        if not match: self.send_error(400); return
        start, end = map(int, match.groups()); body = data[start:end+1]
        with lock:
            active += 1
            with open(events, 'a') as f: f.write(json.dumps(dict(event='start', start=start, end=end, path=relative, active=active))+'\n')
        try:
            self.send_response(200 if mode == 'status' else 206)
            self.send_header('Content-Range', f'bytes {start+1 if mode == "range" else start}-{end}/{len(data)}')
            if mode != 'missing-length': self.send_header('Content-Length', str(len(body) + (1 if mode == 'length' else 0)))
            if mode == 'encoding': self.send_header('Content-Encoding', 'br')
            self.end_headers()
            if mode == 'short': body = body[:max(1, len(body)//2)]
            if mode == 'corrupt': body = bytes([body[0]^1]) + body[1:]
            for i in range(0, len(body), 65536):
                if mode == 'slow' and start >= 16777216: time.sleep(.03)
                self.wfile.write(body[i:i+65536]); self.wfile.flush()
                if mode == 'gate' and start >= 16777216 and i == 0:
                    while json.load(open(control))['mode'] == 'gate': time.sleep(.01)
        except (BrokenPipeError, ConnectionResetError): pass
        finally:
            with lock:
                active -= 1
                with open(events, 'a') as f: f.write(json.dumps(dict(event='end', start=start, path=relative, active=active))+'\n')
server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
open(portfile,'w').write(str(server.server_port))
server.serve_forever()
"""#
}

func waitRecord(_ library: ModelLibrary, id: ModelID,
                matching predicate: @Sendable (ModelRecord) -> Bool) async throws -> ModelRecord {
    for _ in 0..<1500 {
        if let record = await library.snapshot().records.first(where: { $0.id == id }), predicate(record) { return record }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ModelLibraryError.download("Timed out waiting for fixture model state")
}
