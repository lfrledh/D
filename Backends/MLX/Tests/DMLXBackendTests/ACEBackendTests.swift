import CryptoKit
import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("ACE pinned inventory and stopped-process audit", .serialized)
struct ACEBackendTests {
    @Test("Source inventory is required and changes are caught after admission")
    func sourceInventory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let admitted = try ACEModelInventory.inspect(fixture.request(), configuration: fixture.configuration())
        #expect(admitted.files.count == 3)
        #expect(admitted.sourceFiles.count == 6)
        try admitted.confirmUnchanged()
        try Data("changed official code".utf8).write(to: fixture.vendor.appendingPathComponent("acestep/handler.py"))
        #expect(throws: (any Error).self) { try admitted.confirmUnchanged() }
    }

    @Test("A drained fake provider that changes a source is reported as mutation")
    func stoppedChildMutation() async throws {
        let fixture = try Fixture(mutateSource: true)
        defer { fixture.remove() }
        let backend = try ExternalACEBackend(configuration: fixture.configuration())
        let request = fixture.request(source: true)
        do {
            _ = try await backend.execute(request, emit: { _ in })
            Issue.record("The fake provider must fail")
        } catch {
            #expect(error.localizedDescription.contains("mutation"))
        }
        await backend.release()
        #expect(try Data(contentsOf: fixture.original).last == 1)
    }

    @Test("A drained unchanged fake child reports real caller cancellation")
    func stoppedChildCancellation() async throws {
        let fixture = try Fixture(sleepUntilCancelled: true)
        defer { fixture.remove() }
        let backend = try ExternalACEBackend(configuration: fixture.configuration())
        let task = Task {
            try await backend.execute(fixture.request(source: true), emit: { _ in })
        }
        var started = false
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: fixture.marker.path) {
                started = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled fake child unexpectedly succeeded")
        } catch is CancellationError {
            // The bridge has drained the owned process before execute returns.
        } catch {
            Issue.record("Unchanged cancellation became \(error.localizedDescription)")
        }
        await backend.release()
        #expect(started)
        #expect(try Data(contentsOf: fixture.original).last == 0)
    }

    private struct Fixture {
        let root: URL
        let model: URL
        let vendor: URL
        let artifacts: URL
        let manifest: URL
        let provider: URL
        let original: URL
        let marker: URL

        init(mutateSource: Bool = false, sleepUntilCancelled: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ace-test-\(UUID())", isDirectory: true)
            model = root.appendingPathComponent("model", isDirectory: true)
            vendor = root.appendingPathComponent("vendor", isDirectory: true)
            artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
            manifest = root.appendingPathComponent("manifest.json")
            provider = root.appendingPathComponent("fake-provider.py")
            original = root.appendingPathComponent("original.wav")
            marker = root.appendingPathComponent("child-started")
            for directory in [root, model, vendor, artifacts] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            var files: [[String: Any]] = []
            for (role, name) in [("xl", "acestep-v15-xl-sft"), ("vae", "vae"),
                                 ("embedding", "Qwen3-Embedding-0.6B")] {
                let path = "checkpoints/\(name)/weights.safetensors"
                files.append(try write(Data(role.utf8), at: model, path: path, role: role))
            }
            var sourceFiles: [[String: Any]] = []
            for path in ["acestep/handler.py", "acestep/model_downloader.py",
                         "acestep/models/xl_sft/modeling_acestep_v15_xl_base.py",
                         "acestep/models/xl_sft/configuration_acestep_v15.py",
                         "acestep/models/xl_sft/apg_guidance.py"] {
                sourceFiles.append(try write(Data(("# " + path).utf8), at: vendor, path: path))
            }
            sourceFiles.append(try write(Data(), at: vendor,
                                         path: "acestep/models/xl_sft/__init__.py"))
            let value: [String: Any] = [
                "schemaVersion": 1, "profile": ACEModelInventory.profile,
                "modelRepository": ACEModelInventory.modelRepository,
                "modelRevision": ACEModelInventory.modelRevision,
                "sharedRepository": ACEModelInventory.sharedRepository,
                "sharedRevision": ACEModelInventory.sharedRevision,
                "sourceRevision": ACEModelInventory.sourceRevision,
                "files": files, "sourceFiles": sourceFiles,
            ]
            try JSONSerialization.data(withJSONObject: value).write(to: manifest)
            let frames = 4_800
            var wav = Data("RIFF".utf8)
            wav.appendLE(UInt32(36 + frames * 4))
            wav.append(Data("WAVEfmt ".utf8)); wav.appendLE(UInt32(16))
            wav.appendLE(UInt16(1)); wav.appendLE(UInt16(2))
            wav.appendLE(UInt32(48_000)); wav.appendLE(UInt32(192_000))
            wav.appendLE(UInt16(4)); wav.appendLE(UInt16(16))
            wav.append(Data("data".utf8)); wav.appendLE(UInt32(frames * 4))
            wav.append(Data(repeating: 0, count: frames * 4))
            try wav.write(to: original)
            let markerToken = Data(marker.path.utf8).base64EncodedString()
            let script = sleepUntilCancelled ? """
                import base64,json,sys,time
                a=sys.argv
                r=json.load(open(a[a.index('--request')+1]))
                open(base64.b64decode('\(markerToken)').decode(),'wb').write(b'1')
                print(json.dumps({'schemaVersion':1,'type':'progress','runID':r['runID'],
                                  'phase':'denoising','completed':0,'total':1}),flush=True)
                while True: time.sleep(1)
                """ : mutateSource ? """
                import json,sys,urllib.parse
                a=sys.argv
                r=json.load(open(a[a.index('--request')+1]))
                p=urllib.parse.urlsplit(r['requestedSource']).path
                with open(p,'r+b') as f:
                    f.seek(-1,2);f.write(b'\\x01');f.flush()
                print(json.dumps({'schemaVersion':1,'type':'error','runID':r['runID'],
                                  'kind':'engine','message':'fake child failed'}),flush=True)
                sys.exit(2)
                """ : "raise SystemExit(2)\n"
            try Data(script.utf8).write(to: provider)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func configuration() -> ACEBackendConfiguration {
            ACEBackendConfiguration(pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
                providerScript: provider, vendorDirectory: vendor, modelManifest: manifest,
                artifactDirectory: artifacts, timeoutSeconds: 10, cancellationGraceSeconds: 1)
        }

        func request(source: Bool = false) -> InferenceRequest {
            let reference: AudioSourceReference? = source ? {
                let bytes = try! Data(contentsOf: original)
                return AudioSourceReference(url: original, sha256: digest(bytes),
                    frameCount: 4_800, sampleRate: 48_000, channels: 2)
            }() : nil
            let audio = AudioRequest(operation: source ? .variation : .generate, prompt: "test",
                durationSeconds: 0.1, seed: 1,
                ace: ACERequest(editOptions: source ? .cover(audioCoverStrength: 0.5,
                                                              noiseStrength: 0.5) : nil),
                source: reference)
            return InferenceRequest(model: ModelReference(directory: model,
                revision: ACEModelInventory.modelRevision), input: .audio(audio))
        }

        private func write(_ data: Data, at root: URL, path: String,
                           role: String? = nil) throws -> [String: Any] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
            var entry: [String: Any] = ["path": path, "size": data.count, "sha256": digest(data)]
            if let role { entry["role"] = role }
            return entry
        }
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
