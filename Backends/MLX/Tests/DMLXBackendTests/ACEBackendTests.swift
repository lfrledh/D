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
        #expect(admitted.files.count == 21)
        #expect(admitted.sourceFiles.count == 6)
        try admitted.confirmUnchanged()
        try Data("changed official code".utf8).write(to: fixture.vendor.appendingPathComponent("acestep/handler.py"))
        #expect(throws: (any Error).self) { try admitted.confirmUnchanged() }
    }

    @Test("Manifest requires pinned configs, tokenizer, index, and indexed shards")
    func requiredResources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest)) as! [String: Any]
        let entries = original["files"] as! [[String: Any]]
        for suffix in ["checkpoints/vae/config.json",
                       "checkpoints/Qwen3-Embedding-0.6B/tokenizer.json",
                       "checkpoints/acestep-v15-xl-sft/model.safetensors.index.json",
                       "checkpoints/acestep-v15-xl-sft/model-00001-of-00004.safetensors"] {
            var changed = original
            changed["files"] = entries.filter { $0["path"] as? String != suffix }
            try JSONSerialization.data(withJSONObject: changed).write(to: fixture.manifest)
            #expect(throws: (any Error).self) {
                try ACEModelInventory.inspect(fixture.request(), configuration: fixture.configuration())
            }
        }
        let indexPath = "checkpoints/acestep-v15-xl-sft/model.safetensors.index.json"
        let index = fixture.model.appendingPathComponent(indexPath)
        let badIndex = Data(#"{"metadata":{},"weight_map":{"layer":"../vae/diffusion_pytorch_model.safetensors"}}"#.utf8)
        try badIndex.write(to: index)
        var changed = original
        changed["files"] = entries.map { entry -> [String: Any] in
            guard entry["path"] as? String == indexPath else { return entry }
            var updated = entry
            updated["size"] = badIndex.count
            updated["sha256"] = digest(badIndex)
            return updated
        }
        try JSONSerialization.data(withJSONObject: changed).write(to: fixture.manifest)
        #expect(throws: (any Error).self) {
            try ACEModelInventory.inspect(fixture.request(), configuration: fixture.configuration())
        }
    }

    @Test("Float source endpoints pass and clipped or nonfinite samples fail")
    func floatInputRange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for (sample, accepted) in [(Float(1), true), (Float(-1), true),
                                   (Float(1.25), false), (Float.nan, false)] {
            var wav = Data("RIFF".utf8)
            wav.appendLE(UInt32(44)); wav.append(Data("WAVEfmt ".utf8))
            wav.appendLE(UInt32(16)); wav.appendLE(UInt16(3)); wav.appendLE(UInt16(2))
            wav.appendLE(UInt32(48_000)); wav.appendLE(UInt32(384_000))
            wav.appendLE(UInt16(8)); wav.appendLE(UInt16(32))
            wav.append(Data("data".utf8)); wav.appendLE(UInt32(8))
            wav.appendLE(sample.bitPattern); wav.appendLE(Float(-1).bitPattern)
            try wav.write(to: fixture.original)
            let ref = AudioSourceReference(url: fixture.original, sha256: digest(wav),
                frameCount: 1, sampleRate: 48_000, channels: 2)
            if accepted { _ = try ACEInputValidation.check(ref) }
            else { #expect(throws: (any Error).self) { _ = try ACEInputValidation.check(ref) } }
        }
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
        } catch let failure as InferenceFailure {
            if case .inputIntegrityChanged = failure {} else {
                Issue.record("Mutation became \(failure)")
            }
        } catch {
            Issue.record("Mutation became \(error.localizedDescription)")
        }
        await backend.release()
        #expect(try Data(contentsOf: fixture.original).last == 1)
    }

    @Test("Unchanged ordinary child failure remains a backend failure")
    func stoppedChildOrdinaryFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backend = try ExternalACEBackend(configuration: fixture.configuration())
        do {
            _ = try await backend.execute(fixture.request(), emit: { _ in })
            Issue.record("The fake provider must fail")
        } catch let failure as InferenceFailure {
            if case .backendFailed = failure {} else { Issue.record("Unexpected \(failure)") }
        } catch { Issue.record("Unexpected \(error.localizedDescription)") }
        await backend.release()
    }

    @Test("Bad original before admission remains an invalid request")
    func initialBadInput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backend = try ExternalACEBackend(configuration: fixture.configuration())
        let request = fixture.request(source: true)
        var changed = try Data(contentsOf: fixture.original)
        changed[changed.count - 1] = 1
        try changed.write(to: fixture.original)
        do {
            _ = try await backend.execute(request, emit: { _ in })
            Issue.record("The changed original must fail admission")
        } catch let failure as InferenceFailure {
            if case .invalidRequest = failure {} else { Issue.record("Unexpected \(failure)") }
        } catch { Issue.record("Unexpected \(error.localizedDescription)") }
        await backend.release()
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

    @Test("Cancellation after source mutation reports integrity failure")
    func cancelledMutation() async throws {
        let fixture = try Fixture(sleepUntilCancelled: true)
        defer { fixture.remove() }
        let backend = try ExternalACEBackend(configuration: fixture.configuration())
        let task = Task { try await backend.execute(fixture.request(source: true), emit: { _ in }) }
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: fixture.marker.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
        var changed = try Data(contentsOf: fixture.original)
        changed[changed.count - 1] = 1
        try changed.write(to: fixture.original)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Changed source unexpectedly succeeded")
        } catch let failure as InferenceFailure {
            if case .inputIntegrityChanged = failure {} else { Issue.record("Unexpected \(failure)") }
        } catch { Issue.record("Unexpected \(error.localizedDescription)") }
        await backend.release()
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
            let xl = "checkpoints/acestep-v15-xl-sft/"
            let paths = ["config.json", "configuration_acestep_v15.py",
                         "modeling_acestep_v15_xl_base.py", "apg_guidance.py",
                         "silence_latent.pt", "model.safetensors.index.json",
                         "model-00001-of-00004.safetensors", "model-00002-of-00004.safetensors",
                         "model-00003-of-00004.safetensors", "model-00004-of-00004.safetensors"].map { xl + $0 }
                + ["checkpoints/vae/config.json", "checkpoints/vae/diffusion_pytorch_model.safetensors"]
                + ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json",
                   "special_tokens_map.json", "added_tokens.json", "chat_template.jinja",
                   "merges.txt", "vocab.json"].map { "checkpoints/Qwen3-Embedding-0.6B/" + $0 }
            for path in paths {
                let role = path.hasPrefix(xl) ? "xl" : path.hasPrefix("checkpoints/vae/") ? "vae" : "embedding"
                let raw: Data
                if path.hasSuffix("model.safetensors.index.json") {
                    raw = Data(#"{"metadata":{"total_size":4},"weight_map":{"a":"model-00001-of-00004.safetensors","b":"model-00002-of-00004.safetensors","c":"model-00003-of-00004.safetensors","d":"model-00004-of-00004.safetensors"}}"#.utf8)
                } else { raw = Data(("fixture " + path).utf8) }
                files.append(try write(raw, at: model, path: path, role: role))
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
