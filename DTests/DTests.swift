import CryptoKit
import Foundation
import DWorkbench
import DInference
import Testing
@testable import D

@MainActor
struct WorkbenchCloseTests {
    @Test func simultaneousWindowCloseAndQuitShareOneDecisionAndDrain() async {
        let prompt = SuspendedCloseDecision()
        let gate = CloseRequestGate { await prompt.decide() }
        let windowClose = Task { await gate.prepareToClose() }
        await prompt.waitUntilRequested()

        // The direct second request enters the gate before this queued answer is processed.
        Task { @MainActor in prompt.answer(true) }
        let quit = await gate.prepareToClose()
        let closed = await windowClose.value
        #expect(quit && closed)
        #expect(prompt.requestCount == 1)
    }

    @Test func choosingKeepEditingAllowsALaterCloseAttempt() async {
        var count = 0
        let gate = CloseRequestGate {
            count += 1
            return count == 2
        }
        #expect(await gate.prepareToClose() == false)
        #expect(await gate.prepareToClose() == true)
        #expect(count == 2)
    }
}

@MainActor
private final class SuspendedCloseDecision {
    private(set) var requestCount = 0
    private var answerContinuation: CheckedContinuation<Bool, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func decide() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            answerContinuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilRequested() async {
        if answerContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func answer(_ approved: Bool) {
        answerContinuation?.resume(returning: approved)
        answerContinuation = nil
    }
}


@MainActor
struct AudioDeploymentIsolationTests {
    @Test func accessDirectoryFailureKeepsNonAudioSessionAvailable() async throws {
        let fixture = try TinyBundledEngine()
        defer { fixture.remove() }
        let availability = WorkbenchBootstrap.prepareAudioEngine(resolve: { fixture.engine },
            prepareAccess: { throw CocoaError(.fileWriteNoPermission) })
        #expect(availability.engine == nil)
        #expect(availability.issue?.contains("图像、文稿") == true)
        let session = try await AppSessionFactory.makeSession(artifactDirectory: fixture.root.appendingPathComponent("tasks"),
            bundledAudioEngine: availability.engine)
        #expect(session.textBackendID != nil)
        #expect(session.audioBackendID == nil)
    }

    @Test func engineChangedAfterStartupDoesNotPreventProjectSession() async throws {
        let fixture = try TinyBundledEngine()
        defer { fixture.remove() }
        try Data("changed".utf8).write(to: fixture.engine.providerScript)
        #expect(throws: (any Error).self) { try fixture.engine.confirmUnchanged() }
        let suite = "D.Tests.AudioDeployment." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let session = try await AppSessionFactory.makeSession(artifactDirectory: fixture.root.appendingPathComponent("tasks"),
            bundledAudioEngine: fixture.engine, audioConsent: AudioModelUsePermission(settings: settings),
            audioAccessRoot: fixture.root.appendingPathComponent("access"))
        #expect(session.textBackendID != nil)
        #expect(session.audioBackendID != nil)
        // The bundled engine remains rejected at audio admission, before model reads.
        let validate = try #require(session.validateAudioModel)
        await #expect(throws: (any Error).self) { _ = try await validate(fixture.root.appendingPathComponent("missing-model")) }
    }
}

private struct TinyBundledEngine {
    let root: URL
    let engine: BundledAudioEngine
    init() throws {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("D-audio-deployment-" + UUID().uuidString)
        let resources = root.appendingPathComponent("Resources")
        let bundle = resources.appendingPathComponent("AudioEngine.dengine")
        let files = ["python/bin/python3", "provider/d_audio_backend.py", "provider/d_audio_contract.py",
                     "provider/d_audio_sa3.py", "provider/d_audio_access.py", "model-manifests/sm-music.json", "vendor/example"]
        let bytes = Data("fixture".utf8)
        var records: [[String: Any]] = []
        for path in files {
            let url = bundle.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: path == "python/bin/python3" ? 0o755 : 0o644], ofItemAtPath: url.path)
            records.append(["path": path, "sizeBytes": bytes.count,
                            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                            "executable": path == "python/bin/python3"])
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "d-audio-engine", "pythonABI": "3.12",
            "pythonExecutable": "python/bin/python3", "providerScript": "provider/d_audio_backend.py",
            "vendorDirectory": "vendor", "modelManifestsDirectory": "model-manifests", "files": records]
        try JSONSerialization.data(withJSONObject: manifest).write(to: bundle.appendingPathComponent("engine.json"))
        let resolved = try BundledAudioEngine.resolve(resourceDirectory: resources)
        engine = try #require(resolved)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
