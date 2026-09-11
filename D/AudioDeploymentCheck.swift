#if DEBUG
import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Development-only deployment gate. It does not configure or enable the audio engine.
struct AudioDeploymentCheck: View {
    let expectedExecutable: String
    let expectedDigest: String
    @State private var running = false
    @State private var result = "检查既有 Python 的普通沙盒执行与依赖发现；不加载模型、不录音。"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音频引擎部署检查").font(.title)
            Text("请选择已准备的 Python 执行文件；只检查明确指定的文件，不扫描其他目录。")
            Button("选择并检查既有引擎…") { Task { await check() } }
                .disabled(running).accessibilityIdentifier("audio-deployment-check")
            ScrollView { Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .accessibilityIdentifier("audio-deployment-result")
        }.padding(24).frame(minWidth: 700, minHeight: 480)
    }

    @MainActor private func check() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择已授权测试环境的 Python 执行文件。此检查不会下载或运行模型。"
        panel.directoryURL = URL(fileURLWithPath: expectedExecutable).deletingLastPathComponent()
        guard await panel.begin() == .OK, let selected = panel.url else { return }
        let accessing = selected.startAccessingSecurityScopedResource()
        defer { if accessing { selected.stopAccessingSecurityScopedResource() } }
        do {
            guard selected.standardizedFileURL.path == expectedExecutable else {
                throw NSError(domain: "D.AudioDeployment", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "所选路径不是本次明确指定的引擎，未执行。"])
            }
            let data = try Data(contentsOf: selected, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expectedDigest else {
                throw NSError(domain: "D.AudioDeployment", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "执行文件摘要与本次准备不符，未执行。"])
            }
            result = "正在检查；最长约 17 秒。"
            let report = try await Task.detached(priority: .utility) {
                try Self.execute(selected, digest: digest)
            }.value
            result = report
            print("D_AUDIO_DEPLOYMENT_REPORT " + report.replacingOccurrences(of: "\n", with: " "))
        } catch {
            result = "部署检查未通过：\(error.localizedDescription)"
            print("D_AUDIO_DEPLOYMENT_ERROR \(error)")
        }
    }

    private static func execute(_ executable: URL, digest: String) throws -> String {
        let fm = FileManager.default
        let parent = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
        let directory = parent.appendingPathComponent("D/AudioDeployment/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent("stdout.txt")
        let err = directory.appendingPathComponent("stderr.txt")
        guard fm.createFile(atPath: out.path, contents: nil), fm.createFile(atPath: err.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let script = "import sys,json,importlib.util; print(json.dumps({'version':sys.version,'prefix':sys.prefix,'base_prefix':sys.base_prefix,'modules':{n:importlib.util.find_spec(n) is not None for n in ['mlx','numpy','sentencepiece']}}))"
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-B", "-c", script]
        process.currentDirectoryURL = directory
        process.environment = ["PATH":"/usr/bin:/bin", "LANG":"en_US.UTF-8", "LC_ALL":"en_US.UTF-8",
            "PYTHONDONTWRITEBYTECODE":"1", "PYTHONNOUSERSITE":"1",
            "TMPDIR":directory.path, "XDG_CACHE_HOME":directory.path,
            "PYTHONPYCACHEPREFIX":directory.appendingPathComponent("pycache").path]
        process.standardOutput = stdout
        process.standardError = stderr
        let start = Date()
        var launchError: String?
        var timedOut = false
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                timedOut = true
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        } catch { launchError = String(describing: error) }
        try stdout.synchronize()
        try stderr.synchronize()
        func boundedText(_ url: URL) throws -> String {
            let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
            return String(decoding: try h.read(upToCount: 65536) ?? Data(), as: UTF8.self)
        }
        var object: [String: Any] = ["executable":executable.path, "sha256":digest,
            "arguments":process.arguments ?? [], "environment":process.environment ?? [:],
            "timeout":timedOut, "elapsed":Date().timeIntervalSince(start), "directory":directory.path,
            "stdout":try boundedText(out), "stderr":try boundedText(err), "weightsLoaded":false]
        if let launchError { object["launchError"] = launchError }
        else { object["exitCode"] = process.terminationStatus; object["terminationReason"] = process.terminationReason.rawValue }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("report.json"), options: .withoutOverwriting)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
