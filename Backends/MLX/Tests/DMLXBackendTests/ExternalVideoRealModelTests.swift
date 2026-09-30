import DInference
import DRuntime
import Foundation
import Testing
@testable import DMLXBackend

/// Opt-in, serial local-weight acceptance. No download, GUI, system preferences,
/// or model substitution. This is runtime validation, not native App acceptance.
@Suite("Prepared external video engine with real local weights", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["D_TEST_REAL_VIDEO_PROFILE"] != nil))
struct ExternalVideoRealModelTests {
    @Test func generateCancelAdmissionAndRecover() async throws {
        let env = ProcessInfo.processInfo.environment
        let profileName = try #require(env["D_TEST_REAL_VIDEO_PROFILE"])
        let profile = try #require(ExternalVideoExecutionProfile(rawValue: profileName))
        let engine = URL(fileURLWithPath: try #require(env["D_TEST_REAL_VIDEO_ENGINE"]))
        let pack = URL(fileURLWithPath: try #require(env["D_TEST_REAL_VIDEO_PACK"]))
        let base = URL(fileURLWithPath: try #require(env["D_TEST_EXTERNAL_VIDEO_ROOT"]))
            .appendingPathComponent("real-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        let backend = try ExternalVideoBackend(configuration: .init(profile: profile,
            pythonExecutable: engine.appendingPathComponent("python/bin/python3"),
            providerScript: engine.appendingPathComponent("provider/app_video_driver.py"),
            ffmpeg: engine.appendingPathComponent("native/ffmpeg"), ffprobe: engine.appendingPathComponent("native/ffprobe"),
            h3Executable: profile == .h3BF16Full ? engine.appendingPathComponent("native/h3") : nil,
            h3Shader: profile == .h3BF16Full ? engine.appendingPathComponent("native/h3_shaders.metal") : nil,
            artifactDirectory: base, timeoutSeconds: 3600, cancellationGraceSeconds: 5))
        let model = try await backend.validateModel(at: pack)
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 12 * 1_073_741_824))
        do {
            for cycle in 0..<3 {
                let video = VideoRequest(prompt: "A red ceramic cup on a wooden table, steady camera, natural light.",
                    negativePrompt: "", width: 256, height: 256,
                    frameCount: profile == .h3BF16Full ? 22 : 9, frameRate: .init(numerator: 24), steps: 2,
                    guidanceScale: 1, scheduleShift: 1, seed: 42, executionProfile: profile.reference,
                    adapterOptions: profile == .h3BF16Full ? .h3(streamWeights: true)
                        : .ltx(streamWeights: true, spatiotemporalGuidance: 0))
                let request = InferenceRequest(model: model, input: .video(video))
                let start = Date()
                let run = try await runtime.submit(request, backendID: backend.descriptor.id)
                // This deliberately proves cancellation during resource admission;
                // the separate process tests cover live child group escalation.
                if cycle == 1 { try await Task.sleep(for: .seconds(3)); await run.cancel() }
                var streamFailure: String?
                do { for try await _ in run.events {} } catch { streamFailure = error.localizedDescription }
                let outcome = await run.outcome()
                let snapshot = await runtime.snapshot()
                #expect(snapshot.activeRunID == nil && snapshot.reservedBytes == 0)
                var record: [String: Any] = ["cycle": cycle, "runID": request.id.uuidString,
                    "profile": profile.rawValue, "seconds": Date().timeIntervalSince(start),
                    "outcome": String(describing: outcome), "streamFailure": streamFailure ?? "none",
                    "guiVerified": false]
                if case .completed(let result) = outcome {
                    record["artifacts"] = result.artifacts.map { $0.url.path }
                    record["metadata"] = result.metadata
                }
                try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                    .write(to: base.appendingPathComponent("cycle-\(cycle).json"), options: .withoutOverwriting)
                print("D_EXTERNAL_VIDEO_REAL cycle=\(cycle) record=\(base.path)/cycle-\(cycle).json")
                if cycle == 1 { #expect(outcome == .cancelled) }
                else {
                    guard case .completed(let result) = outcome else {
                        Issue.record("Real video did not complete: \(outcome)")
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    #expect(streamFailure == nil)
                    #expect(result.artifacts.count == 1)
                    #expect(result.metadata["profile"] == profile.rawValue)
                    #expect(result.metadata["streamWeights"] == "true")
                }
            }
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }
}
