import CryptoKit
import DInference
import DRuntime
@testable import DMLXBackend
import Foundation
import Testing

@Suite("VIDEO V0 explicit contract and owned process", .serialized)
struct VideoBackendTests {
    private func video(width: Int = 64, height: Int = 48, frames: Int = 5,
                       steps: Int = 1, seed: UInt64 = 42) -> VideoRequest {
        VideoRequest(prompt: "A red square moves right.", negativePrompt: "blurry", width: width, height: height,
            frameCount: frames, frameRate: .init(numerator: 16), steps: steps, guidanceScale: 6,
            scheduleShift: 8, seed: seed, executionProfile: VideoBackendConfiguration.profile)
    }

    @Test("Adapter checks model constraints, not the development Mac memory ceiling")
    func explicitScaleAndRejection() throws {
        for value in [video(), video(width: 1920, height: 1088, frames: 81)] {
            try VideoBackendConfiguration.validate(value)
            #expect(try VideoBackendConfiguration.estimate(value) > 0)
        }
        for value in [video(width: 65), video(frames: 6), video(steps: 1001), video(seed: UInt64.max)] {
            #expect(throws: (any Error).self) { try VideoBackendConfiguration.validate(value) }
        }
    }

    @Test("Serialized request preserves Unicode, explicit seed and exact rational time")
    func immutableRequest() throws {
        let input = video()
        let request = InferenceRequest(model: .init(directory: URL(fileURLWithPath: "/fixed"),
            revision: VideoBackendConfiguration.revision), input: .video(input))
        try request.validate()
        #expect(try JSONDecoder().decode(InferenceRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(request.input.capability == .videoGeneration)
    }

    @Test("Progress consumer failure and timeout stop the child before returning")
    func stoppedProcesses() async throws {
        let root = try root()
        let provider = root.appendingPathComponent("provider.py")
        let id = UUID()
        let source = """
        import json,time,sys
        print(json.dumps({"schema":"d.video.frames.v1","type":"progress","runID":sys.argv[1],"stage":"denoise","completed":1,"total":1}),flush=True)
        time.sleep(30)
        """
        try source.write(to: provider, atomically: false, encoding: .utf8)
        let config = process(provider, root: root, arguments: [id.uuidString.lowercased()], timeout: 0.5)
        let started = Date()
        do {
            _ = try await config.run { reader, control in
                await VideoProviderProtocol.read(reader, control: control, runID: id, steps: 1) { _ in
                    throw InferenceFailure.backendFailed("controlled consumer failure")
                }
            }
            Issue.record("consumer failure unexpectedly succeeded")
        } catch { #expect(error.localizedDescription.contains("controlled consumer failure")) }
        #expect(Date().timeIntervalSince(started) < 5)
        do {
            _ = try await config.run { reader, control in
                await VideoProviderProtocol.read(reader, control: control, runID: id, steps: 1) { _ in }
            }
            Issue.record("timeout unexpectedly succeeded")
        } catch { #expect(error.localizedDescription.contains("timed out")) }
    }

    @Test("Malformed output, missing terminal, wrong identity and trailing events fail")
    func badProtocols() async throws {
        let root = try root(), id = UUID()
        let progress = "{\"schema\":\"d.video.frames.v1\",\"type\":\"progress\",\"runID\":\"\(id.uuidString.lowercased())\",\"stage\":\"denoise\",\"completed\":0,\"total\":1}"
        let terminal = "{\"schema\":\"d.video.frames.v1\",\"type\":\"result\",\"runID\":\"\(id.uuidString.lowercased())\"}"
        let lines = ["not-json", "{}", progress, terminal + "\n" + progress, "{\"schema\":\"d.video.frames.v1\",\"type\":\"result\",\"runID\":\"wrong\"}"]
        for (index, line) in lines.enumerated() {
            let script = root.appendingPathComponent("bad-\(index).py")
            let literal = String(data: try JSONEncoder().encode(line), encoding: .utf8)!
            try ("print(" + literal + ")\n").write(to: script, atomically: false, encoding: .utf8)
            do {
                _ = try await process(script, root: root).run { reader, control in
                    await VideoProviderProtocol.read(reader, control: control, runID: id, steps: 1) { _ in }
                }
                Issue.record("invalid protocol unexpectedly succeeded")
            } catch { /* Frozen failure is expected; no artifact is published. */ }
        }
    }

    @Test("Runtime result is validated, can repeat after release, and published files survive consumer/report failure")
    func runtimePublication() async throws {
        let root = try root()
        let model = root.appendingPathComponent("model"), tokenizer = root.appendingPathComponent("tokenizer")
        let code = root.appendingPathComponent("code"), outputs = root.appendingPathComponent("outputs")
        for directory in [model, tokenizer, code, outputs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let manifest = model.appendingPathComponent("D-VIDEO-PREPARED.json")
        try JSONSerialization.data(withJSONObject: ["complete": true, "revision": VideoBackendConfiguration.revision])
            .write(to: manifest)
        let before = try Data(contentsOf: manifest)
        let script = code.appendingPathComponent("fixture.py")
        for mode in ["normal", "consumer", "report-collision", "wrong-frames"] {
            try Self.fixture.replacingOccurrences(of: "MODE_VALUE", with: mode)
                .write(to: script, atomically: false, encoding: .utf8)
            let backend = try MLXVideoBackend(configuration: .init(
                pythonExecutable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_VIDEO_TEST_PYTHON"]!),
                providerScript: script, tokenizerDirectory: tokenizer, artifactDirectory: outputs,
                memoryLimitBytes: 14 * 1024 * 1024 * 1024, timeoutSeconds: 10, cancellationGraceSeconds: 0.2))
            let request = InferenceRequest(model: .init(directory: model, revision: VideoBackendConfiguration.revision), input: .video(video()))
            do {
                let result = try await backend.execute(request) { _ in
                    if mode == "consumer" { throw InferenceFailure.backendFailed("controlled media consumer failure") }
                }
                #expect(mode == "normal")
                #expect(result.artifacts.count == 1)
                #expect(FileManager.default.fileExists(atPath: result.artifacts[0].url.path))
                await backend.release()
                let repeated = try await backend.execute(request) { _ in }
                #expect(repeated.artifacts[0].url != result.artifacts[0].url)
                #expect(FileManager.default.fileExists(atPath: result.artifacts[0].url.path))
            } catch {
                #expect(mode != "normal")
                if mode == "report-collision" { #expect(error.localizedDescription.contains("Video was preserved at")) }
            }
            await backend.release()
            let runs = try FileManager.default.contentsOfDirectory(at: outputs, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(request.id.uuidString.lowercased()) }
            #expect(!runs.isEmpty)
            for run in runs {
                #expect(FileManager.default.fileExists(atPath: run.appendingPathComponent("output.mp4").path) == (mode != "wrong-frames"))
                if mode == "report-collision" { #expect(try String(contentsOf: run.appendingPathComponent("media.json"), encoding: .utf8) == "preserve") }
            }
            #expect(try Data(contentsOf: manifest) == before)
        }
    }

    private static let fixture = #"""
    import json,hashlib,pathlib,argparse
    p=argparse.ArgumentParser()
    for k in ("request","model","tokenizer","output"):p.add_argument("--"+k,required=True)
    a=p.parse_args();r=pathlib.Path(a.request);data=r.read_bytes();q=json.loads(data)
    o=pathlib.Path(a.output);o.mkdir();mode="MODE_VALUE"
    raw=bytes([180,40,20])*q["width"]*q["height"]*q["frameCount"];(o/"frames.rgb").write_bytes(raw)
    if mode=="report-collision":(o.parent/"media.json").write_text("preserve")
    m=(pathlib.Path(a.model)/"D-VIDEO-PREPARED.json").read_bytes()
    stages=[dict(stage="released",completed=q["frameCount"],total=q["frameCount"],seconds=0.1,activeBytes=0,cacheBytes=0,peakBytes=0,peakRSSBytes=0)]
    result=dict(schema="d.video.frames.v1",type="result",runID=q["runID"],request=q,requestSHA256=hashlib.sha256(data).hexdigest(),modelManifestSHA256=hashlib.sha256(m).hexdigest(),precision=dict(text="BF16",diffusion="BF16 with original FP32 time/head/modulation/norm tensors",vae="F32"),conditions=[dict(tokenCount=1,effectiveText=q[x]) for x in ("prompt","negativePrompt")],frames=dict(file="frames.rgb",width=q["width"]+(16 if mode=="wrong-frames" else 0),height=q["height"],frameCount=q["frameCount"],fpsNumerator=q["fpsNumerator"],fpsDenominator=q["fpsDenominator"],layout="RGB8-top-down",colorInterpretation="full-range Rec.709 display RGB",sha256=hashlib.sha256(raw).hexdigest(),byteCount=len(raw)),stages=stages,seconds=0.1)
    (o/"result.json").write_text(json.dumps(result));print(json.dumps(result),flush=True)
    """#

    private func root() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["D_VIDEO_TEST_OUTPUT"] else {
            throw InferenceFailure.invalidRequest("D_VIDEO_TEST_OUTPUT is required for owned CPU outputs.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func process(_ script: URL, root: URL, arguments: [String] = [], timeout: Double = 3) -> LocalProviderProcess {
        LocalProviderProcess(executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_VIDEO_TEST_PYTHON"] ?? "/usr/bin/python3"),
            arguments: ["-B", script.path] + arguments,
            environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": root.path],
            currentDirectory: root, timeoutSeconds: timeout, cancellationGraceSeconds: 0.2, label: "Video fixture")
    }
}
