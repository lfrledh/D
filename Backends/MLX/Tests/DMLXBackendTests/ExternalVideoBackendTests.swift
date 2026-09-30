import CryptoKit
import Darwin
import DInference
import Foundation
import Testing
@testable import DMLXBackend

@Suite("External video publication and terminal ownership (CPU fixtures)", .serialized)
struct ExternalVideoBackendTests {
    @Test func independentPublicationAndFrozenDigest() throws {
        let fixture = try Fixture()
        let source = fixture.root.appendingPathComponent("candidate.mp4")
        let output = fixture.root.appendingPathComponent("output.mp4")
        let bytes = Data("owned bytes—not a media acceptance sample".utf8)
        try bytes.write(to: source)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try ExternalVideoBackend.copyVerifiedCandidate(source, to: output, expectedDigest: digest)
        var a = stat(), b = stat()
        #expect(lstat(source.path, &a) == 0 && lstat(output.path, &b) == 0)
        #expect(a.st_ino != b.st_ino && a.st_nlink == 1 && b.st_nlink == 1)
        #expect(try Data(contentsOf: output) == bytes)
        let replaced = fixture.root.appendingPathComponent("replaced.mp4")
        try bytes.write(to: source)
        #expect(throws: (any Error).self) {
            try ExternalVideoBackend.copyVerifiedCandidate(source, to: replaced, expectedDigest: digest) {
                try FileManager.default.moveItem(at: replaced, to: fixture.root.appendingPathComponent("held.mp4"))
                try Data("replacement destination".utf8).write(to: replaced)
            }
        }
        #expect(try Data(contentsOf: replaced) == Data("replacement destination".utf8))
        #expect(throws: (any Error).self) {
            try ExternalVideoBackend.copyVerifiedCandidate(source, to: output, expectedDigest: digest)
        }
        try Data("replacement".utf8).write(to: source)
        #expect(throws: (any Error).self) {
            try ExternalVideoBackend.copyVerifiedCandidate(source, to: fixture.root.appendingPathComponent("wrong.mp4"), expectedDigest: digest)
        }
        #expect(try Data(contentsOf: output) == bytes)
    }

    @Test func successSurvivesReleaseAndAnotherExecution() async throws {
        let fixture = try Fixture()
        let backend = try fixture.backend(mode: "success")
        for _ in 0..<2 {
            let request = fixture.request()
            let result = try await backend.execute(request) { _ in }
            await backend.release()
            let file = try #require(result.artifacts.first?.url)
            #expect(file.lastPathComponent == "output.mp4")
            #expect(try Data(contentsOf: file) == Data("controlled candidate".utf8))
        }
    }

    @Test func changedFrozenInputWinsOverNonzeroExitAndReleases() async throws {
        let fixture = try Fixture()
        let backend = try fixture.backend(mode: "mutate-input")
        do {
            _ = try await backend.execute(fixture.request()) { _ in Issue.record("No result after input mutation") }
            Issue.record("Expected protected input failure")
        } catch InferenceFailure.inputIntegrityChanged { }
        catch { Issue.record("Wrong error: \(error)") }
        await backend.release()
        let token = UUID(); try await MLXExecutionLease.shared.acquire(token)
        await MLXExecutionLease.shared.relinquish(token)
    }

    @Test func bootstrapRemainderReportsFailureWithoutPoisoningComputeLease() async throws {
        let fixture = try Fixture()
        let backend = try fixture.backend(mode: "bootstrap-remainder", access: true)
        do {
            _ = try await backend.execute(fixture.request()) { _ in Issue.record("Cleanup failure must precede publication") }
            Issue.record("Expected bootstrap cleanup failure")
        } catch InferenceFailure.backendFailed { }
        catch { Issue.record("Wrong error: \(error)") }
        await backend.release()
        let directories = try FileManager.default.contentsOfDirectory(at: fixture.access, includingPropertiesForKeys: nil)
        #expect(directories.count == 1)
        #expect(FileManager.default.fileExists(atPath: directories[0].appendingPathComponent("unknown-marker").path))
        let next = try fixture.backend(mode: "success")
        _ = try await next.execute(fixture.request()) { _ in }
        await next.release()
    }

    @Test func declaredButUnavailable25CannotBecomeReady() async throws {
        let fixture = try Fixture(profile: .ltx25BF16Full)
        let backend = try fixture.backend(mode: "success")
        await #expect(throws: InferenceFailure.self) { _ = try await backend.validateModel(at: fixture.model) }
    }
}

private struct Fixture {
    let root: URL, model: URL, outputs: URL, access: URL, script: URL
    let profile: ExternalVideoExecutionProfile
    init(profile: ExternalVideoExecutionProfile = .ltx23Q8GemmaQ4) throws {
        let parent = try #require(ProcessInfo.processInfo.environment["D_TEST_EXTERNAL_VIDEO_ROOT"])
        root = URL(fileURLWithPath: parent).appendingPathComponent("backend-" + UUID().uuidString)
        self.profile = profile
        model = root.appendingPathComponent("pack"); outputs = root.appendingPathComponent("outputs")
        access = root.appendingPathComponent("access"); script = root.appendingPathComponent("provider/provider.py")
        for item in [model.appendingPathComponent("model"), model.appendingPathComponent("text_encoder"), outputs, access, script.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        }
        try JSONEncoder().encode(ExternalVideoModelManifest(profile: profile))
            .write(to: model.appendingPathComponent(ExternalVideoModelManifest.filename))
    }
    func backend(mode: String, access useAccess: Bool = false) throws -> ExternalVideoBackend {
        let code = "mode = " + String(reflecting: mode) + "\n" + #"""
        import sys,json,hashlib,pathlib
        def arg(name): return pathlib.Path(sys.argv[sys.argv.index(name)+1])
        request=arg('--request'); raw=request.read_bytes(); wire=json.loads(raw)
        run=request.parent; pack=arg('--pack'); manifest=(pack/'D-VIDEO-PACK.json').read_bytes()
        if mode=='mutate-input':
            request.write_bytes(b'changed'); sys.exit(7)
        if mode=='bootstrap-remainder': pathlib.Path('unknown-marker').write_text('retain me')
        candidate=run/'candidate.mp4'; candidate.write_bytes(b'controlled candidate')
        result={'schema':'d.external-video.app-result.v1','run_id':wire['run_id'],
          'request_sha256':hashlib.sha256(raw).hexdigest(),'manifest_sha256':hashlib.sha256(manifest).hexdigest(),
          'profile':wire['request']['profile'],'media_verified':True,'published':False,
          'candidate_file':'candidate.mp4','sha256':hashlib.sha256(candidate.read_bytes()).hexdigest()}
        (run/'result.json').write_text(json.dumps(result))
        """#
        try Data(code.utf8).write(to: script)
        return try ExternalVideoBackend(configuration: .init(profile: profile,
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"), providerScript: script,
            ffmpeg: URL(fileURLWithPath: "/usr/bin/true"), ffprobe: URL(fileURLWithPath: "/usr/bin/true"),
            artifactDirectory: outputs, accessBootstrapRoot: useAccess ? access : nil,
            timeoutSeconds: 10, cancellationGraceSeconds: 0.2))
    }
    func request() -> InferenceRequest {
        .init(model: .init(directory: model, revision: profile.modelIdentity),
            input: .video(.init(prompt: "CPU fixture", negativePrompt: "", width: 64, height: 64,
                frameCount: 9, frameRate: .init(numerator: 24), steps: 2,
                guidanceScale: 1, scheduleShift: 1, seed: 42, executionProfile: profile.reference,
                adapterOptions: .ltx(streamWeights: true, spatiotemporalGuidance: 0))))
    }
}
