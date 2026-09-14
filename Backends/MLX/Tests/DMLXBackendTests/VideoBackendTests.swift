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
        let measuredProfile = try VideoBackendConfiguration.estimate(video(width: 832, height: 480, frames: 17))
        #expect(measuredProfile >= 19_642_860_430) // Recorded MLX peak, not system RSS.
        #expect(measuredProfile > 14 * 1024 * 1024 * 1024)
        #expect(try VideoBackendConfiguration.estimate(video(width: 1920, height: 1088, frames: 81)) > measuredProfile)
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
        let slowProvider = root.appendingPathComponent("slow-provider.py")
        try source.replacingOccurrences(of: "import json,time,sys\n", with: "import json,time,sys\ntime.sleep(0.6)\n")
            .write(to: slowProvider, atomically: false, encoding: .utf8)
        let consumerConfig = process(slowProvider, root: root, arguments: [id.uuidString.lowercased()], timeout: 10)
        let started = Date()
        do {
            _ = try await consumerConfig.run { reader, control in
                await VideoProviderProtocol.read(reader, control: control, runID: id, steps: 1) { _ in
                    throw InferenceFailure.backendFailed("controlled consumer failure")
                }
            }
            Issue.record("consumer failure unexpectedly succeeded")
        } catch { #expect(error.localizedDescription.contains("controlled consumer failure")) }
        #expect(Date().timeIntervalSince(started) < 5)
        let timeoutConfig = process(provider, root: root, arguments: [id.uuidString.lowercased()], timeout: 0.5)
        do {
            _ = try await timeoutConfig.run { reader, control in
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

    @Test("Backend result is validated, can repeat after release, and published files survive consumer/report failure")
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

    @Test("Application access stays narrow, drains on errors, and per-task budgets reach wire and result")
    func applicationAccessAndBudget() async throws {
        let root = try root(), model = root.appendingPathComponent("model"), tokenizer = root.appendingPathComponent("tokenizer")
        let code = root.appendingPathComponent("code"), output = root.appendingPathComponent("outputs"), access = root.appendingPathComponent("access")
        for directory in [model, tokenizer, code, output, access] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try JSONSerialization.data(withJSONObject: ["complete": true, "revision": VideoBackendConfiguration.revision])
            .write(to: model.appendingPathComponent("D-VIDEO-PREPARED.json"))
        let script = code.appendingPathComponent("fixture.py")
        var fixture = Self.fixture.replacingOccurrences(of: "MODE_VALUE", with: "normal")
        fixture = fixture.replacingOccurrences(of: "a=p.parse_args();", with: "p.add_argument('--access-manifest');p.add_argument('--access-run-id');a=p.parse_args();")
        fixture = fixture.replacingOccurrences(of: "o=pathlib.Path(a.output);", with: """
        if a.access_manifest:
            grant=json.loads(pathlib.Path(a.access_manifest).read_bytes())
            assert grant['runID']==q['runID']==a.access_run_id
            assert [g['path'] for g in grant['grants']]==[a.model,str(r.parent)]
        o=pathlib.Path(a.output);
        """)
        for selected: UInt64? in [nil, 15 * 1024 * 1024 * 1024] {
            for fail in [false, true] {
                let source = fail ? fixture.replacingOccurrences(of: "o=pathlib.Path(a.output);", with: "raise RuntimeError('controlled child failure')\no=pathlib.Path(a.output);") : fixture
                try source.write(to: script, atomically: false, encoding: .utf8)
                let backend = try MLXVideoBackend(configuration: .init(
                    pythonExecutable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_VIDEO_TEST_PYTHON"]!),
                    providerScript: script, tokenizerDirectory: tokenizer, artifactDirectory: output,
                    memoryLimitBytes: 14 * 1024 * 1024 * 1024, timeoutSeconds: 10,
                    cancellationGraceSeconds: 0.2, accessBootstrapRoot: access))
                let request = InferenceRequest(model: .init(directory: model, revision: VideoBackendConfiguration.revision),
                    input: .video(video()), memoryBudgetBytes: selected)
                do {
                    let result = try await backend.execute(request) { _ in }
                    #expect(!fail)
                    #expect(result.metadata["memoryGuidelineBytes"] == String(selected ?? 14 * 1024 * 1024 * 1024))
                    let wire = result.artifacts[0].url.deletingLastPathComponent().appendingPathComponent("request.json")
                    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: wire)) as? [String: Any])
                    #expect((object["memoryLimitBytes"] as? NSNumber)?.uint64Value == selected ?? 14 * 1024 * 1024 * 1024)
                } catch {
                    #expect(fail, "\(error)")
                }
                await backend.release()
                #expect(try FileManager.default.contentsOfDirectory(atPath: access.path).isEmpty)
            }
        }
    }

    @Test("Runtime cancels promptly and queued video starts after the cancelled provider exits")
    func runtimeCancelHandoff() async throws {
        let root = try root()
        let model = root.appendingPathComponent("model"), tokenizer = root.appendingPathComponent("tokenizer")
        let code = root.appendingPathComponent("code"), outputs = root.appendingPathComponent("outputs")
        for d in [model, tokenizer, code, outputs] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try JSONSerialization.data(withJSONObject: ["complete": true, "revision": VideoBackendConfiguration.revision])
            .write(to: model.appendingPathComponent("D-VIDEO-PREPARED.json"))
        let script = code.appendingPathComponent("fixture.py")
        try Self.fixture.replacingOccurrences(of: "MODE_VALUE", with: "normal")
            .write(to: script, atomically: false, encoding: .utf8)
        let backend = try MLXVideoBackend(configuration: .init(
            pythonExecutable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_VIDEO_TEST_PYTHON"]!),
            providerScript: script, tokenizerDirectory: tokenizer, artifactDirectory: outputs,
            memoryLimitBytes: 14 * 1024 * 1024 * 1024, timeoutSeconds: 10, cancellationGraceSeconds: 0.2))
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 14 * 1024 * 1024 * 1024))
        let waiting = VideoRequest(prompt: "WAIT", negativePrompt: "", width: 64, height: 48, frameCount: 5,
            frameRate: .init(numerator: 16), steps: 1, guidanceScale: 6, scheduleShift: 8, seed: 42,
            executionProfile: VideoBackendConfiguration.profile)
        let reference = ModelReference(directory: model, revision: VideoBackendConfiguration.revision)
        do {
            let first = try await runtime.submit(.init(model: reference, input: .video(waiting)), backendID: backend.descriptor.id)
            let second = try await runtime.submit(.init(model: reference, input: .video(video())), backendID: backend.descriptor.id)
            var cancellationStarted: ContinuousClock.Instant?
            do {
                for try await event in first.events {
                    if case .progress = event, cancellationStarted == nil {
                        cancellationStarted = ContinuousClock.now
                        await first.cancel()
                    }
                }
            } catch { /* Outcome below is the authoritative cancellation state. */ }
            if case .cancelled = await first.outcome() {} else { Issue.record("first run was not cancelled") }
            // The fixture's 30-second sleep and provider's 10-second deadline must
            // not satisfy this test merely because the runtime remembers cancellation.
            if let cancellationStarted {
                #expect(cancellationStarted.duration(to: .now) < .seconds(5))
            } else { Issue.record("cancellation progress boundary was never observed") }
            for try await _ in second.events {}
            if case .completed(let result) = await second.outcome() {
                #expect(result.artifacts.count == 1)
            } else { Issue.record("queued video did not recover after cancellation") }
            await runtime.shutdown()
            #expect(try String(contentsOf: code.appendingPathComponent("previous-process-ended"), encoding: .utf8) == "confirmed")
            let runs = try FileManager.default.contentsOfDirectory(at: outputs, includingPropertiesForKeys: nil)
            let cancelled = runs.filter { $0.lastPathComponent.hasPrefix(first.id.uuidString.lowercased()) }
            #expect(cancelled.count == 1)
            let cancelledDirectory = try #require(cancelled.first)
            #expect(!FileManager.default.fileExists(atPath: cancelledDirectory.appendingPathComponent("output.mp4").path))
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    private static let fixture = #"""
    import json,hashlib,pathlib,argparse
    p=argparse.ArgumentParser()
    for k in ("request","model","tokenizer","output"):p.add_argument("--"+k,required=True)
    a=p.parse_args();r=pathlib.Path(a.request);data=r.read_bytes();q=json.loads(data)
    o=pathlib.Path(a.output);o.mkdir();mode="MODE_VALUE"
    if q["prompt"]=="WAIT":
        import time,os
        pathlib.Path(__file__).with_name("waiting-pid").write_text(str(os.getpid()))
        print(json.dumps(dict(schema="d.video.frames.v1",type="progress",runID=q["runID"],stage="denoise",completed=0,total=1)),flush=True)
        time.sleep(30)
    else:
        owned_pid=pathlib.Path(__file__).with_name("waiting-pid")
        if owned_pid.exists():
            import os
            try:os.kill(int(owned_pid.read_text()),0)
            except ProcessLookupError:pathlib.Path(__file__).with_name("previous-process-ended").write_text("confirmed")
            else:raise RuntimeError("Queued provider started while previous owned provider still exists")
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
