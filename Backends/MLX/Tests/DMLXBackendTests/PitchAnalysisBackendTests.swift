import CryptoKit
import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Pitch provider contract")
struct PitchProviderContractTests {
    @Test("Public descriptor and configuration defaults are frozen")
    func publicSurface() throws {
        let configuration = PitchBackendConfiguration(
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
            providerScript: URL(fileURLWithPath: "/tmp/d_pitch_analysis_backend.py"),
            artifactDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(configuration.timeoutSeconds == 30)
        #expect(configuration.cancellationGraceSeconds == 2)
        #expect(configuration.accessBootstrapRoot == nil)
        let backend = try PitchAnalysisBackend(configuration: configuration)
        #expect(backend.descriptor == BackendDescriptor(
            id: "cpu.pitch.swift-f0", version: "0.1.2-d1",
            capabilities: [.audioPitchAnalysis]))
    }

    @Test("Strict provider result is tied to the complete current request")
    func resultCorrespondence() throws {
        let fixture = PitchContractFixture(sampleCount: 512)
        let data = try fixture.responseData(frames: [
            ["rawPitchHz": 440.0, "confidence": 0.91, "voiced": true],
            ["rawPitchHz": 3000.0, "confidence": 0.99, "voiced": false],
        ])
        let parsed = try PitchAnalysisProviderProtocol.parse(
            data, expectedRunID: fixture.runID, expected: fixture.pitch)
        #expect(parsed.result.frames.count == 2)
        #expect(parsed.result.frames[0].pitchHz == 440)
        #expect(parsed.result.frames[1].pitchHz == nil)
        #expect(parsed.metadata.provider == "swift-f0-0.1.2/onnxruntime-cpu")

        let other = PitchContractFixture(sampleCount: 512)
        expectPitchFailure {
            _ = try PitchAnalysisProviderProtocol.parse(
                data, expectedRunID: other.runID, expected: other.pitch)
        }
    }

    @Test("NaN, Boolean numbers, duplicates, wrong provenance, and contradictory voicing fail")
    func strictFailures() throws {
        let fixture = PitchContractFixture(sampleCount: 256)
        let valid = String(decoding: try fixture.responseData(frames: [
            ["rawPitchHz": 440.0, "confidence": 0.91, "voiced": true],
        ]), as: UTF8.self)
        let mutations = [
            valid.replacingOccurrences(of: "\"confidence\":0.91", with: "\"confidence\":true"),
            valid.replacingOccurrences(of: "\"confidence\":0.91", with: "\"confidence\":NaN"),
            valid.replacingOccurrences(of: "\"voiced\":true", with: "\"voiced\":false"),
            valid.replacingOccurrences(of: PitchAnalysisRequest.profile, with: "wrong-profile"),
            valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
        ]
        for mutation in mutations {
            expectPitchFailure {
                _ = try PitchAnalysisProviderProtocol.parse(
                    Data(mutation.utf8), expectedRunID: fixture.runID, expected: fixture.pitch)
            }
        }
    }

    @Test("Frozen request contains only explicit paths and complete source identity")
    func requestEnvelope() throws {
        let fixture = PitchContractFixture(sampleCount: 257)
        let data = try PitchAnalysisBackend.encodeRequest(
            requestID: fixture.runID, pitch: fixture.pitch,
            modelDirectory: URL(fileURLWithPath: "/models/swift_f0", isDirectory: true),
            runDirectory: URL(fileURLWithPath: "/artifacts/\(fixture.runID.uuidString)", isDirectory: true))
        var parser = AudioJSONParser(data: data, maximumDepth: 32)
        let root = try parser.parse().object(exactKeys: [
            "schemaVersion", "runID", "source", "profile", "preprocessing",
            "modelSHA256", "inputSHA256", "sampleCount", "inputPath",
            "modelDirectory", "runDirectory",
        ], context: "frozen pitch request")
        #expect(try root["sampleCount"]?.requiredInteger(context: "sampleCount") == 257)
        #expect(try root["modelSHA256"]?.requiredString(context: "model digest")
                == PitchAnalysisRequest.modelSHA256)
    }

    @Test("Oversized stdout boundary is rejected before JSON decoding")
    func oversizedResult() throws {
        let fixture = PitchContractFixture(sampleCount: 256)
        var data = try fixture.responseData(frames: [
            ["rawPitchHz": 440.0, "confidence": 0.91, "voiced": true],
        ])
        data.append(Data(repeating: 0x20,
                         count: PitchAnalysisResult.maximumJSONBytes + 1 - data.count))
        expectPitchFailure {
            _ = try PitchAnalysisProviderProtocol.parse(
                data, expectedRunID: fixture.runID, expected: fixture.pitch)
        }
    }
}

@Suite("Pitch backend fake-process lifecycle", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["D_PITCH_MODEL_DIRECTORY"] != nil
                && ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] != nil))
struct PitchBackendLifecycleTests {
    @Test("Estimate hashes fixed model and input without invoking provider")
    func estimateOnly() async throws {
        let fixture = try PitchBackendFixture(mode: "normal")
        defer { fixture.remove() }
        let backend = try PitchAnalysisBackend(configuration: fixture.configuration)
        let admission = try PitchAdmission.inspect(
            fixture.request, configuration: fixture.configuration)
        #expect(admission.pythonExecutable == fixture.configuration.pythonExecutable.standardizedFileURL)
        #expect(admission.pythonResolvedURL
                == fixture.configuration.pythonExecutable.resolvingSymlinksInPath().standardizedFileURL)
        let estimate = try await backend.estimate(fixture.request)
        #expect(estimate == ResourceEstimate(peakBytes: 256 * 1024 * 1024))
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    @Test("Fake provider publishes one artifact only after exit and release preserves it")
    func publishAndRelease() async throws {
        let fixture = try PitchBackendFixture(mode: "normal")
        defer { fixture.remove() }
        let backend = try PitchAnalysisBackend(configuration: fixture.configuration)
        let result = try await backend.execute(fixture.request) { _ in }
        let artifact = try #require(result.artifacts.only)
        #expect(artifact.url.lastPathComponent == "pitch.json")
        #expect(FileManager.default.fileExists(atPath: artifact.url.path))
        #expect(result.metadata["modelSHA256"] == PitchAnalysisRequest.modelSHA256)
        let published = try String(contentsOf: artifact.url, encoding: .utf8)
        #expect(published.contains("\"pitchHz\":null"))
        await backend.release()
        #expect(FileManager.default.fileExists(atPath: artifact.url.path))
    }

    @Test("Artifact callback replacement is never deleted and original error remains visible")
    func replacedCandidateIsRefused() async throws {
        let fixture = try PitchBackendFixture(mode: "normal")
        defer { fixture.remove() }
        let backend = try PitchAnalysisBackend(configuration: fixture.configuration)
        let moved = fixture.root.appendingPathComponent("consumer-moved.json")
        do {
            _ = try await backend.execute(fixture.request) { output in
                guard case .artifact(let artifact) = output else { return }
                try FileManager.default.moveItem(at: artifact.url, to: moved)
                try Data("sentinel".utf8).write(to: artifact.url)
                throw FixtureError.consumer
            }
            Issue.record("Expected consumer failure")
        } catch {
            #expect(error.localizedDescription.contains("consumer"))
            #expect(error.localizedDescription.contains("moved or replaced"))
        }
        let artifact = fixture.artifacts.appendingPathComponent(
            fixture.request.id.uuidString).appendingPathComponent("pitch.json")
        #expect(try String(contentsOf: artifact, encoding: .utf8) == "sentinel")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        await backend.release()
    }

    @Test("Cancellation from the artifact callback removes the exact candidate and permits next run")
    func postArtifactCancellationAndNextRun() async throws {
        let fixture = try PitchBackendFixture(mode: "normal")
        defer { fixture.remove() }
        let backend = try PitchAnalysisBackend(configuration: fixture.configuration)
        do {
            _ = try await backend.execute(fixture.request) { output in
                if case .artifact(_) = output { throw CancellationError() }
            }
            Issue.record("Expected post-artifact cancellation")
        } catch is CancellationError {}
        let artifact = fixture.artifacts.appendingPathComponent(
            fixture.request.id.uuidString).appendingPathComponent("pitch.json")
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
        await backend.release()
        try fixture.replaceProvider(mode: "normal")
        let nextResult = try await backend.execute(fixture.nextRequest()) { _ in }
        #expect(nextResult.artifacts.count == 1)
        await backend.release()
    }

    @Test("Cancellation waits for child exit, publishes nothing, and permits the next run after release")
    func cancellationAndNextRun() async throws {
        let fixture = try PitchBackendFixture(mode: "hang")
        defer { fixture.remove() }
        let backend = try PitchAnalysisBackend(configuration: fixture.configuration)
        let request = fixture.request
        let marker = fixture.marker
        let task = Task { try await backend.execute(request) { _ in } }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected pitch cancellation") }
        catch is CancellationError {}
        catch { Issue.record("Unexpected cancellation error: \(error)") }
        let artifact = fixture.artifacts.appendingPathComponent(
            fixture.request.id.uuidString).appendingPathComponent("pitch.json")
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
        await backend.release()

        try fixture.replaceProvider(mode: "normal")
        let result = try await backend.execute(fixture.nextRequest()) { _ in }
        #expect(result.artifacts.count == 1)
        await backend.release()
    }

    @Test("Partial output, nonzero exit, timeout, wrong source, and repeated run fail closed",
          arguments: ["partial", "nonzero", "timeout", "wrong-source", "normal"])
    func failureModes(mode: String) async throws {
        let fixture = try PitchBackendFixture(mode: mode)
        defer { fixture.remove() }
        let backend = try PitchAnalysisBackend(configuration: fixture.configuration)
        if mode == "normal" {
            _ = try await backend.execute(fixture.request) { _ in }
            await backend.release()
            do {
                _ = try await backend.execute(fixture.request) { _ in }
                Issue.record("Expected existing run directory rejection")
            } catch {}
            await backend.release()
        } else {
            do {
                _ = try await backend.execute(fixture.request) { _ in }
                Issue.record("Expected fake provider failure")
            } catch {}
            await backend.release()
            try fixture.replaceProvider(mode: "normal")
            let result = try await backend.execute(fixture.nextRequest()) { _ in }
            #expect(result.artifacts.count == 1)
            await backend.release()
        }
        let artifact = fixture.artifacts.appendingPathComponent(
            fixture.request.id.uuidString).appendingPathComponent("pitch.json")
        if mode != "normal" { #expect(!FileManager.default.fileExists(atPath: artifact.path)) }
    }
}

private struct PitchContractFixture {
    let runID = UUID()
    let pitch: PitchAnalysisRequest

    init(sampleCount: Int) {
        let source = PitchSourceIdentity(
            assetID: UUID(), documentID: UUID(), documentRevision: 7,
            contentSHA256: String(repeating: "a", count: 64), sampleRate: 16_000,
            frameCount: Int64(sampleCount), startFrame: 0, endFrame: Int64(sampleCount))
        pitch = PitchAnalysisRequest(
            source: source, inputURL: URL(fileURLWithPath: "/input/prepared.f32"),
            inputSHA256: String(repeating: "b", count: 64), sampleCount: sampleCount)
    }

    func responseData(frames: [[String: Any]]) throws -> Data {
        let source: [String: Any] = [
            "assetID": pitch.source.assetID.uuidString.lowercased(),
            "documentID": pitch.source.documentID.uuidString.lowercased(),
            "documentRevision": pitch.source.documentRevision,
            "contentSHA256": pitch.source.contentSHA256, "sampleRate": pitch.source.sampleRate,
            "frameCount": pitch.source.frameCount, "startFrame": pitch.source.startFrame,
            "endFrame": pitch.source.endFrame,
        ]
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "runID": runID.uuidString.lowercased(), "source": source,
            "profile": PitchAnalysisRequest.profile,
            "preprocessing": PitchAnalysisRequest.preprocessing,
            "modelSHA256": PitchAnalysisRequest.modelSHA256,
            "inputSHA256": pitch.inputSHA256, "sampleCount": pitch.sampleCount,
            "frames": frames,
            "metadata": ["profile": PitchAnalysisRequest.profile,
                         "modelSHA256": PitchAnalysisRequest.modelSHA256,
                         "provider": "swift-f0-0.1.2/onnxruntime-cpu",
                         "analysisSeconds": 0.125],
        ], options: [.sortedKeys])
    }
}

private final class PitchBackendFixture {
    let root: URL
    let model: URL
    let artifacts: URL
    let input: URL
    let provider: URL
    let marker: URL
    let request: InferenceRequest
    let configuration: PitchBackendConfiguration

    init(mode: String) throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]!,
                       isDirectory: true)
        root = base.appendingPathComponent("pitch-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        model = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["D_PITCH_MODEL_DIRECTORY"]!,
            isDirectory: true).standardizedFileURL
        artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        input = root.appendingPathComponent("prepared.f32")
        let count = 256
        let data = Data(repeating: 0, count: count * 4)
        try data.write(to: input)
        marker = root.appendingPathComponent("provider-ran")
        provider = root.appendingPathComponent("fake_provider.py")
        try Self.fakeProvider(mode: mode, marker: marker).write(to: provider, atomically: false,
                                                                encoding: .utf8)
        let source = PitchSourceIdentity(
            assetID: UUID(), documentID: UUID(), documentRevision: 1,
            contentSHA256: String(repeating: "c", count: 64), sampleRate: 16_000,
            frameCount: Int64(count), startFrame: 0, endFrame: Int64(count))
        let pitch = PitchAnalysisRequest(
            source: source, inputURL: input,
            inputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sampleCount: count)
        request = InferenceRequest(
            model: ModelReference(directory: model, revision: PitchAnalysisRequest.modelSHA256),
            input: .pitch(pitch))
        let python = ProcessInfo.processInfo.environment["D_PITCH_PYTHON_EXECUTABLE"] ?? "/usr/bin/python3"
        configuration = PitchBackendConfiguration(
            pythonExecutable: URL(fileURLWithPath: python), providerScript: provider,
            artifactDirectory: artifacts, timeoutSeconds: mode == "timeout" ? 0.1 : 5,
            cancellationGraceSeconds: 0.1)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func replaceProvider(mode: String) throws {
        try Self.fakeProvider(mode: mode, marker: marker).write(
            to: provider, atomically: true, encoding: .utf8)
    }

    func nextRequest() -> InferenceRequest {
        InferenceRequest(model: request.model, input: request.input)
    }

    private static func fakeProvider(mode: String, marker: URL) -> String {
        """
        import json, pathlib, sys, time
        pathlib.Path(\(String(reflecting: marker.path))).write_text("ran")
        request = json.loads(pathlib.Path(sys.argv[sys.argv.index("--request") + 1]).read_text())
        mode = \(String(reflecting: mode))
        if mode in ("timeout", "hang"): time.sleep(2)
        if mode == "nonzero": raise SystemExit(3)
        if mode == "partial":
            sys.stdout.write('{"schemaVersion":1')
            raise SystemExit(0)
        if mode == "wrong-source": request["source"]["documentRevision"] += 1
        result = {"schemaVersion":1,"runID":request["runID"],"source":request["source"],
          "profile":request["profile"],"preprocessing":request["preprocessing"],
          "modelSHA256":request["modelSHA256"],"inputSHA256":request["inputSHA256"],
          "sampleCount":request["sampleCount"],
          "frames":[{"rawPitchHz":3000.0,"confidence":0.99,"voiced":False}],
          "metadata":{"profile":request["profile"],"modelSHA256":request["modelSHA256"],
                      "provider":"swift-f0-0.1.2/onnxruntime-cpu","analysisSeconds":0.01}}
        print(json.dumps(result, separators=(",", ":")), flush=True)
        """
    }
}

private enum FixtureError: LocalizedError {
    case consumer
    var errorDescription: String? { "fixture consumer artifact failure" }
}

private func expectPitchFailure(_ body: () throws -> Void) {
    do { try body(); Issue.record("Expected pitch validation failure") }
    catch {}
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
