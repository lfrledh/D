import CryptoKit
import Darwin
import Foundation

@main struct BundledVideoEngineChecks {
    static func main() throws {
        guard let temporary = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] else {
            throw NSError(domain: "BundledVideoEngineChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "D_TEST_TEMP_DIR is required"])
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: temporary).appendingPathComponent("bundled-video-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var checks: [String] = []

        func require(_ condition: Bool, _ name: String) throws {
            if !condition { throw NSError(domain: name, code: 1) }
        }
        func fails(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks.append(name); return }
            throw NSError(domain: "expected failure: \(name)", code: 1)
        }
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func writeEngine(
            resource: URL,
            family: BundledAudioEngine.Family,
            mutation: ((URL, inout [[String: Any]]) throws -> Void)? = nil
        ) throws {
            let directory: String
            let kind: String
            let script: String
            let model: String
            let vendor: String
            let content: [String: String]
            switch family {
            case .stableAudio:
                directory = "AudioEngine.dengine"; kind = "d-audio-engine"
                script = "provider/d_audio_backend.py"; model = "model-manifests/sm-music.json"; vendor = "vendor"
                content = ["python/bin/python3": "python", script: "backend", "provider/d_audio_access.py": "access",
                           "provider/d_audio_contract.py": "contract", "provider/d_audio_sa3.py": "sa3", model: "{}"]
            case .mrt2Music:
                directory = "MRT2MusicEngine.dengine"; kind = "d-mrt2-music-engine"
                script = "provider/d_audio_mrt2_backend.py"; model = "model-manifests/mrt2-small.json"; vendor = "vendor"
                content = ["python/bin/python3": "python", script: "backend", "provider/d_audio_access.py": "access",
                           "provider/d_audio_contract.py": "contract", "provider/d_audio_mrt2_contract.py": "mrt2",
                           "provider/d_mrt2_export.py": "export", model: "{}"]
            case .video:
                directory = "VideoEngine.dengine"; kind = "d-video-engine"
                script = "provider/d_video_run.py"; model = "model-manifests/wan21.json"; vendor = "Vendor"
                content = [
                    "python/bin/python3": "python", script: "runner", "provider/d_video_model.py": "model",
                    "provider/d_video_prepare.py": "prepare", "provider/d_audio_access.py": "access", model: "{}",
                    "tokenizer/special_tokens_map.json": "special", "tokenizer/spiece.model": "sentencepiece",
                    "tokenizer/tokenizer.json": "tokenizer", "tokenizer/tokenizer_config.json": "config",
                    "Vendor/wan21/__init__.py": "init", "Vendor/wan21/PROVENANCE.json": "{}",
                    "Vendor/wan21/LICENSE-MIT.txt": "MIT", "Vendor/wan21/LICENSE-WAN-APACHE-2.0.txt": "Apache",
                ]
            }
            let engine = resource.appendingPathComponent(directory)
            try fm.createDirectory(at: engine.appendingPathComponent(vendor), withIntermediateDirectories: true)
            var files: [[String: Any]] = []
            for (path, text) in content {
                let url = engine.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data(text.utf8)
                try data.write(to: url)
                if path == "python/bin/python3" {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
                files.append(["path": path, "sizeBytes": data.count, "sha256": digest(data),
                              "executable": path == "python/bin/python3"])
            }
            files.sort { ($0["path"] as! String) < ($1["path"] as! String) }
            try mutation?(engine, &files)
            let manifest: [String: Any] = [
                "schemaVersion": 1, "kind": kind, "pythonABI": "3.12",
                "pythonExecutable": "python/bin/python3", "providerScript": script,
                "vendorDirectory": vendor, "modelManifestsDirectory": "model-manifests", "files": files,
            ]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                .write(to: engine.appendingPathComponent("engine.json"))
        }

        let audio = root.appendingPathComponent("audio compatibility")
        try require(BundledAudioEngine.Family.stableAudio.directory == "AudioEngine.dengine" &&
                    BundledAudioEngine.Family.stableAudio.kind == "d-audio-engine" &&
                    BundledAudioEngine.Family.stableAudio.script == "provider/d_audio_backend.py",
                    "stable audio family constants unchanged")
        try writeEngine(resource: audio, family: .stableAudio)
        let resolvedAudio = try BundledAudioEngine.resolve(resourceDirectory: audio)
        try require(resolvedAudio?.modelManifest.lastPathComponent == "sm-music.json", "stable audio default unchanged")
        try require(resolvedAudio?.videoTokenizerDirectory == nil, "audio has no video tokenizer")
        try resolvedAudio?.confirmUnchanged()
        checks.append("stable-audio-default-compatible")

        let music = root.appendingPathComponent("music compatibility")
        try require(BundledAudioEngine.Family.mrt2Music.directory == "MRT2MusicEngine.dengine" &&
                    BundledAudioEngine.Family.mrt2Music.kind == "d-mrt2-music-engine" &&
                    BundledAudioEngine.Family.mrt2Music.script == "provider/d_audio_mrt2_backend.py",
                    "MRT2 family constants unchanged")
        try writeEngine(resource: music, family: .mrt2Music)
        let resolvedMusic = try BundledAudioEngine.resolve(resourceDirectory: music, family: .mrt2Music)
        try require(resolvedMusic?.modelManifest.lastPathComponent == "mrt2-small.json", "MRT2 path unchanged")
        try require(resolvedMusic?.videoTokenizerDirectory == nil, "music has no video tokenizer")
        checks.append("mrt2-compatible")

        let video = root.appendingPathComponent("视频 engine")
        try writeEngine(resource: video, family: .video)
        let resolvedVideo = try BundledAudioEngine.resolve(resourceDirectory: video, family: .video)
        try require(resolvedVideo?.providerScript.lastPathComponent == "d_video_run.py", "video provider")
        try require(resolvedVideo?.vendorDirectory.lastPathComponent == "Vendor", "video vendor casing")
        try require(resolvedVideo?.modelManifest.lastPathComponent == "wan21.json", "video model declaration")
        try require(resolvedVideo?.videoTokenizerDirectory?.lastPathComponent == "tokenizer", "video tokenizer")
        try resolvedVideo?.confirmUnchanged()
        try require(try BundledAudioEngine.resolve(resourceDirectory: video) == nil, "video does not replace audio default")
        checks.append("video-family-valid-distinct-and-confirmed")

        let wrongKind = root.appendingPathComponent("wrong video kind")
        try writeEngine(resource: wrongKind, family: .video)
        let wrongManifest = wrongKind.appendingPathComponent("VideoEngine.dengine/engine.json")
        var wrong = try JSONSerialization.jsonObject(with: Data(contentsOf: wrongManifest)) as! [String: Any]
        wrong["kind"] = "d-audio-engine"
        try JSONSerialization.data(withJSONObject: wrong).write(to: wrongManifest)
        try fails("video-rejects-audio-kind") {
            _ = try BundledAudioEngine.resolve(resourceDirectory: wrongKind, family: .video)
        }

        let missingTokenizer = root.appendingPathComponent("missing tokenizer")
        try writeEngine(resource: missingTokenizer, family: .video, mutation: { engine, files in
            let path = "tokenizer/tokenizer.json"
            files.removeAll { $0["path"] as? String == path }
            try fm.removeItem(at: engine.appendingPathComponent(path))
        })
        try fails("video-requires-all-tokenizer-files") {
            _ = try BundledAudioEngine.resolve(resourceDirectory: missingTokenizer, family: .video)
        }

        let numericExecutable = root.appendingPathComponent("video numeric executable")
        try writeEngine(resource: numericExecutable, family: .video, mutation: { _, files in
            files[0]["executable"] = 1
        })
        try fails("video-rejects-numeric-executable") {
            _ = try BundledAudioEngine.resolve(resourceDirectory: numericExecutable, family: .video)
        }

        let floatingSize = root.appendingPathComponent("video floating size")
        try writeEngine(resource: floatingSize, family: .video)
        let floatingManifest = floatingSize.appendingPathComponent("VideoEngine.dengine/engine.json")
        let floatingText = String(decoding: try Data(contentsOf: floatingManifest), as: UTF8.self)
        let expression = try NSRegularExpression(pattern: "\\\"sizeBytes\\\":([0-9]+)")
        let range = NSRange(floatingText.startIndex..<floatingText.endIndex, in: floatingText)
        let replaced = expression.stringByReplacingMatches(
            in: floatingText, options: [], range: range, withTemplate: "\\\"sizeBytes\\\":$1.0"
        )
        try Data(replaced.utf8).write(to: floatingManifest)
        try fails("video-rejects-floating-size") {
            _ = try BundledAudioEngine.resolve(resourceDirectory: floatingSize, family: .video)
        }

        let booleanVersion = root.appendingPathComponent("video boolean schema")
        try writeEngine(resource: booleanVersion, family: .video)
        let booleanManifest = booleanVersion.appendingPathComponent("VideoEngine.dengine/engine.json")
        let booleanText = String(decoding: try Data(contentsOf: booleanManifest), as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true")
        try Data(booleanText.utf8).write(to: booleanManifest)
        try fails("video-rejects-boolean-schema") {
            _ = try BundledAudioEngine.resolve(resourceDirectory: booleanVersion, family: .video)
        }

        let changed = try BundledAudioEngine.resolve(resourceDirectory: video, family: .video)!
        try Data("changed".utf8).write(to: video.appendingPathComponent("VideoEngine.dengine/provider/d_video_model.py"))
        try fails("video-post-resolve-mutation") { try changed.confirmUnchanged() }

        print(String(decoding: try JSONSerialization.data(
            withJSONObject: ["checks": checks], options: [.sortedKeys]
        ), as: UTF8.self))
    }
}
