import CryptoKit
import Darwin
import Foundation

@main struct BundledAudioEngineChecks {
    static func main() throws {
        guard let temporary = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] else {
            throw NSError(domain: "BundledAudioEngineChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "D_TEST_TEMP_DIR is required"])
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: temporary).appendingPathComponent("bundled-engine-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws { if !condition { throw NSError(domain: name, code: 1) } }
        func fails(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks.append(name); return }
            throw NSError(domain: "expected failure: \(name)", code: 1)
        }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let required = ["python/bin/python3": "python", "provider/d_audio_backend.py": "backend",
                        "provider/d_audio_contract.py": "contract", "provider/d_audio_sa3.py": "sa3",
                        "provider/d_audio_access.py": "access", "model-manifests/sm-music.json": "{}"]
        func engine(_ name: String, music: Bool = false, mutate: ((URL, inout [[String: Any]]) throws -> Void)? = nil) throws -> URL {
            let resource = root.appendingPathComponent(name + " 模型")
            let engine = resource.appendingPathComponent(music ? "MRT2MusicEngine.dengine" : "AudioEngine.dengine")
            try fm.createDirectory(at: engine, withIntermediateDirectories: true)
            try fm.createDirectory(at: engine.appendingPathComponent("vendor"), withIntermediateDirectories: false)
            var files: [[String: Any]] = []
            let content = music ? ["python/bin/python3": "python", "provider/d_audio_mrt2_backend.py": "mrt2",
                "provider/d_audio_mrt2_contract.py": "mrt2-contract", "provider/d_audio_contract.py": "safe-files",
                "provider/d_mrt2_export.py": "export", "provider/d_audio_access.py": "access",
                "model-manifests/mrt2-small.json": "{}"] : required
            for (path, text) in content {
                let url = engine.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data(text.utf8)
                try data.write(to: url)
                if path == "python/bin/python3" { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
                files.append(["path": path, "sizeBytes": data.count, "sha256": digest(data), "executable": path == "python/bin/python3"])
            }
            files.sort { ($0["path"] as! String) < ($1["path"] as! String) }
            try mutate?(engine, &files)
            let manifest: [String: Any] = ["schemaVersion": 1, "kind": music ? "d-mrt2-music-engine" : "d-audio-engine", "pythonABI": "3.12",
                "pythonExecutable": "python/bin/python3", "providerScript": music ? "provider/d_audio_mrt2_backend.py" : "provider/d_audio_backend.py",
                "vendorDirectory": "vendor", "modelManifestsDirectory": "model-manifests", "files": files]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: engine.appendingPathComponent("engine.json"))
            return resource
        }

        let good = try engine("valid space")
        let resolved = try BundledAudioEngine.resolve(resourceDirectory: good)
        try require(resolved?.modelManifest.lastPathComponent == "sm-music.json", "valid fixed profile")
        try resolved?.confirmUnchanged()
        checks.append("valid-unicode-space-path-and-confirm")
        try require(try BundledAudioEngine.resolve(resourceDirectory: root.appendingPathComponent("absent")) == nil, "absent engine")
        checks.append("absent-engine-is-nil")

        let music = try engine("music fixed profile", music: true)
        let musicResolved = try BundledAudioEngine.resolve(resourceDirectory: music, family: .mrt2Music)
        try require(musicResolved?.modelManifest.lastPathComponent == "mrt2-small.json", "fixed music model manifest")
        try musicResolved?.confirmUnchanged()
        try require(try BundledAudioEngine.resolve(resourceDirectory: music) == nil, "music cannot silently replace SA3")
        checks.append("music-family-distinct-validated-manifest")
        let wrongMusic = try engine("wrong music identity", music: true)
        let wrongManifest = wrongMusic.appendingPathComponent("MRT2MusicEngine.dengine/engine.json")
        var wrongObject = try JSONSerialization.jsonObject(with: Data(contentsOf: wrongManifest)) as! [String: Any]
        wrongObject["kind"] = "d-audio-engine"
        try JSONSerialization.data(withJSONObject: wrongObject).write(to: wrongManifest)
        try fails("music-rejects-SA3-kind") { _ = try BundledAudioEngine.resolve(resourceDirectory: wrongMusic, family: .mrt2Music) }
        let missingMusic = try engine("missing music export", music: true, mutate: { engine, files in
            files.removeAll { $0["path"] as? String == "provider/d_mrt2_export.py" }
            try fm.removeItem(at: engine.appendingPathComponent("provider/d_mrt2_export.py"))
        })
        try fails("music-requires-export-adapter") { _ = try BundledAudioEngine.resolve(resourceDirectory: missingMusic, family: .mrt2Music) }

        let malformed = try engine("malformed")
        try Data("[".utf8).write(to: malformed.appendingPathComponent("AudioEngine.dengine/engine.json"))
        try fails("malformed-json") { _ = try BundledAudioEngine.resolve(resourceDirectory: malformed) }
        let oversize = try engine("oversize")
        try Data(repeating: 0x20, count: 4 * 1024 * 1024 + 1).write(to: oversize.appendingPathComponent("AudioEngine.dengine/engine.json"))
        try fails("oversize-json") { _ = try BundledAudioEngine.resolve(resourceDirectory: oversize) }
        let boolVersion = try engine("bool-version")
        var boolVersionData = try Data(contentsOf: boolVersion.appendingPathComponent("AudioEngine.dengine/engine.json"))
        boolVersionData = Data(String(decoding: boolVersionData, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true").utf8)
        try boolVersionData.write(to: boolVersion.appendingPathComponent("AudioEngine.dengine/engine.json"))
        try fails("bool-schema-rejected") { _ = try BundledAudioEngine.resolve(resourceDirectory: boolVersion) }
        let boolSchema = try engine("bool-schema", mutate: { _, files in files[0]["sizeBytes"] = true })
        try fails("bool-size-rejected") { _ = try BundledAudioEngine.resolve(resourceDirectory: boolSchema) }
        let numericBoolean = try engine("numeric-executable", mutate: { _, files in files[0]["executable"] = 1 })
        try fails("numeric-executable-rejected") { _ = try BundledAudioEngine.resolve(resourceDirectory: numericBoolean) }
        let danglingRoot = root.appendingPathComponent("dangling-root")
        try fm.createDirectory(at: danglingRoot, withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: danglingRoot.appendingPathComponent("AudioEngine.dengine").path, withDestinationPath: "/definitely/not/an/audio/engine")
        try fails("dangling-root-rejected") { _ = try BundledAudioEngine.resolve(resourceDirectory: danglingRoot) }
        let digestMismatch = try engine("bad-digest", mutate: { _, files in files[0]["sha256"] = String(repeating: "0", count: 64) })
        try fails("digest-mismatch") { _ = try BundledAudioEngine.resolve(resourceDirectory: digestMismatch) }
        let undeclared = try engine("undeclared", mutate: { engine, _ in try Data("x".utf8).write(to: engine.appendingPathComponent("extra")) })
        try fails("undeclared-file") { _ = try BundledAudioEngine.resolve(resourceDirectory: undeclared) }
        let duplicate = try engine("duplicate", mutate: { _, files in files.append(files[0]) })
        try fails("duplicate-path") { _ = try BundledAudioEngine.resolve(resourceDirectory: duplicate) }
        let traversal = try engine("traversal", mutate: { _, files in files[0]["path"] = "../escape" })
        try fails("traversal-path") { _ = try BundledAudioEngine.resolve(resourceDirectory: traversal) }
        let linked = try engine("symlink", mutate: { engine, _ in try fm.createSymbolicLink(at: engine.appendingPathComponent("linked"), withDestinationURL: engine.appendingPathComponent("vendor")) })
        try fails("symlink-rejected") { _ = try BundledAudioEngine.resolve(resourceDirectory: linked) }
        let special = try engine("special", mutate: { engine, _ in guard Darwin.mkfifo(engine.appendingPathComponent("pipe").path, 0o600) == 0 else { throw NSError(domain: "mkfifo", code: 1) } })
        try fails("special-file-rejected") { _ = try BundledAudioEngine.resolve(resourceDirectory: special) }
        let missing = try engine("missing-receiver", mutate: { engine, _ in try fm.removeItem(at: engine.appendingPathComponent("provider/d_audio_access.py")) })
        try fails("missing-required-receiver") { _ = try BundledAudioEngine.resolve(resourceDirectory: missing) }
        let execMismatch = try engine("executable-mismatch", mutate: { engine, _ in try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: engine.appendingPathComponent("python/bin/python3").path) })
        try fails("executable-mismatch") { _ = try BundledAudioEngine.resolve(resourceDirectory: execMismatch) }

        let mutated = try engine("post-mutation")
        let mutationResult = try BundledAudioEngine.resolve(resourceDirectory: mutated)!
        try Data("altered".utf8).write(to: mutated.appendingPathComponent("AudioEngine.dengine/provider/d_audio_access.py"))
        try fails("post-resolve-content-mutation") { try mutationResult.confirmUnchanged() }
        let replaced = try engine("replacement")
        let replacementResult = try BundledAudioEngine.resolve(resourceDirectory: replaced)!
        let executable = replaced.appendingPathComponent("AudioEngine.dengine/python/bin/python3")
        try fm.removeItem(at: executable); try Data("python".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try fails("post-resolve-replacement") { try replacementResult.confirmUnchanged() }
        let added = try engine("added")
        let addedResult = try BundledAudioEngine.resolve(resourceDirectory: added)!
        try Data("new".utf8).write(to: added.appendingPathComponent("AudioEngine.dengine/new-file"))
        try fails("post-resolve-added-file") { try addedResult.confirmUnchanged() }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks, "fixtureRoot": root.path], options: [.sortedKeys]), as: UTF8.self))
    }
}
