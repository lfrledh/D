import CryptoKit
import DInference
import DRuntime
import Foundation
import Testing
@testable import DMLXBackend

/// Explicit opt-in: complete original F32 model, real provider and existing runtime.
/// This is not a GUI or listening test; evidence and generated audio are retained.
@Suite("ACE SSD full original model", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["D_TEST_ACE_ENGINE"] != nil))
struct ACERealModelTests {
    @Test func cancelLayerThenCompleteReferenceLyrics() async throws {
        let env = ProcessInfo.processInfo.environment
        func path(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(env[key])) }
        let engine = try path("D_TEST_ACE_ENGINE")
        let model = try path("D_TEST_ACE_MODEL")
        let base = try path("D_TEST_ACE_OUTPUT")
        let source = try path("D_TEST_ACE_REFERENCE")
        let bytes = try Data(contentsOf: source)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let reference = AudioSourceReference(url: source, sha256: sha, frameCount: 288_000,
                                             sampleRate: 48_000, channels: 2)
        let backend = try ExternalACEBackend(configuration: .init(
            pythonExecutable: engine.appendingPathComponent("python/bin/python3"),
            providerScript: engine.appendingPathComponent("provider/d_audio_ace_backend.py"),
            vendorDirectory: engine.appendingPathComponent("vendor"),
            modelManifest: engine.appendingPathComponent("model-manifests/ace-xl-sft.json"),
            artifactDirectory: base, cancellationGraceSeconds: 120))
        let runtime = try InferenceRuntime(backends: [backend],
            configuration: .init(memoryBudgetBytes: 12 * 1_073_741_824))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            for cancel in [true, false] {
                let request = InferenceRequest(model: .init(directory: model, revision: ACEModelInventory.modelRevision),
                    input: .audio(.init(operation: .generate, prompt: "A warm acoustic song with gentle piano accompaniment.",
                        durationSeconds: 6, seed: 7,
                        ace: .init(vocal: .lyrics(text: "[Verse]\nLa la la, morning light\nLa la la, shining bright", language: "en"),
                            bpm: 100, keyScale: "C major", timeSignature: .four, steps: 50, guidanceScale: 7,
                            referenceAudio: reference, loadingStrategy: .ssdLayered))))
                let name = cancel ? "cancel" : "complete"
                try encoder.encode(request).write(to: base.appendingPathComponent(name + "-request.json"), options: .withoutOverwriting)
                let estimate = try await backend.estimate(request)
                try encoder.encode(estimate).write(to: base.appendingPathComponent(name + "-estimate.json"), options: .withoutOverwriting)
                let started = Date()
                let run = try await runtime.submit(request, backendID: backend.descriptor.id)
                var requestedCancel = false, progressEvents = 0, outputArtifacts = 0
                var streamFailure: String?
                do {
                    for try await event in run.events {
                        if case .artifact = event { outputArtifacts += 1 }
                        if case .progress(let completed, let total) = event {
                            progressEvents += 1
                            if cancel && !requestedCancel && total == 32 * 50 && completed > 0 {
                                requestedCancel = true
                                await run.cancel()
                            }
                        }
                    }
                } catch { streamFailure = error.localizedDescription }
                let outcome = await run.outcome()
                let snapshot = await runtime.snapshot()
                #expect(snapshot.activeRunID == nil && snapshot.reservedBytes == 0)
                #expect(try Data(contentsOf: source) == bytes)
                var record: [String: Any] = ["runID": request.id.uuidString, "outcome": String(describing: outcome),
                    "seconds": Date().timeIntervalSince(started), "progressEvents": progressEvents,
                    "requestedLayerCancellation": requestedCancel, "streamFailure": streamFailure ?? "none",
                    "originalSHA256": sha, "estimateBytes": estimate.peakBytes, "GUI": false]
                if case .completed(let result) = outcome {
                    try encoder.encode(result).write(to: base.appendingPathComponent(name + "-result.json"), options: .withoutOverwriting)
                    record["metadata"] = result.metadata
                    #expect(result.metadata["loadingStrategy"] == "ssdLayered")
                    #expect(result.metadata["referenceSHA256"] == sha)
                    #expect(result.metadata["deliveredFrames"] == "288000")
                    #expect(result.artifacts.count == 1 && outputArtifacts == 1)
                    #expect(streamFailure == nil)
                }
                try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                    .write(to: base.appendingPathComponent(name + "-run.json"), options: .withoutOverwriting)
                print("D_ACE_REAL " + base.appendingPathComponent(name + "-run.json").path)
                if cancel {
                    #expect(requestedCancel && outcome == .cancelled && outputArtifacts == 0)
                } else if case .completed = outcome {} else {
                    throw InferenceFailure.backendFailed("Complete ACE runtime generation failed: \(outcome)")
                }
            }
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
}
