import CryptoKit
import DInference
import DRuntime
import Foundation
import ImageIO
import Testing
@testable import DMLXBackend

extension MLXHardwareTests {
@Suite("Dev original BF16 SSD runtime", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["D_TEST_DEV_BF16"] != nil))
struct DevLayeredRealModelTests {
    private actor Trace {
        var events: [MLXLifecycleEvent] = []
        func append(_ event: MLXLifecycleEvent) { events.append(event) }
        func snapshot() -> [MLXLifecycleEvent] { events }
    }

    @Test(.timeLimit(.minutes(1440))) func cancelThenGenerateAndUseTwoReferences() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = URL(fileURLWithPath: try #require(env["D_TEST_DEV_BF16"]))
        let root = URL(fileURLWithPath: try #require(env["D_TEST_DEV_OUTPUT"]))
        let trace = Trace()
        let backend = try MLXFluxDevBackend(configuration: .init(artifactDirectory: root,
            profile: .flux2Dev), observer: { event in
                print("D_DEV_PHASE", event.phase, event.memory.activeBytes)
                await trace.append(event)
            })
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(
            memoryBudgetBytes: 15 * 1_073_741_824))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var references: [ImageReference] = []
        var originals: [URL: Data] = [:]
        for index in 0..<2 {
            var bytes = Data()
            for y in 0..<256 { for x in 0..<256 {
                bytes.append(contentsOf: index == 0 ? [UInt8(x), UInt8(y/2), 32] : [32, UInt8(x/2), UInt8(y)])
            } }
            let url = root.appendingPathComponent("reference-\(index).rgb")
            try bytes.write(to: url, options: .withoutOverwriting)
            originals[url] = bytes
            references.append(.init(url: url,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                byteCount: UInt64(bytes.count), width: 256, height: 256))
        }
        do {
            for mode in ["cancel", "generate", "references"] {
                let refs = mode == "references" ? references : nil
                let request = InferenceRequest(model: .init(directory: model,
                    revision: LocalFluxDevInventory.revision), input: .image(.init(
                        prompt: refs == nil
                            ? "A red ceramic teapot on a wooden table beside a window, soft morning light, detailed studio photograph."
                            : "A ceramic sculpture combining the warm red colors of the first image and cool blue colors of the second image, studio photograph.",
                        width: 512, height: 512, steps: 50, guidanceScale: 4, seed: 42,
                        executionProfile: ImageExecutionCapability.flux2Dev.profile,
                        referenceImages: refs, loadingStrategy: .ssdLayered)))
                try encoder.encode(request).write(to: root.appendingPathComponent(mode + "-request.json"), options: .withoutOverwriting)
                let estimate = try await backend.estimate(request)
                try encoder.encode(estimate).write(to: root.appendingPathComponent(mode + "-estimate.json"), options: .withoutOverwriting)
                let start = Date()
                let run = try await runtime.submit(request, backendID: backend.descriptor.id)
                var cancelled = false, artifacts = 0
                var progress: [Int] = []
                var streamFailure: String?
                do {
                    for try await output in run.events {
                        if case .artifact = output { artifacts += 1 }
                        if case .progress(let done, let total) = output {
                            #expect(total == 50)
                            progress.append(done)
                            print("D_DEV_PROGRESS", mode, done, total)
                        }
                        if mode == "cancel", !cancelled,
                           case .progress(let done, let total) = output, total == 50, done > 0 {
                            cancelled = true; await run.cancel()
                        }
                    }
                } catch { streamFailure = error.localizedDescription }
                let outcome = await run.outcome()
                let state = await runtime.snapshot()
                #expect(state.activeRunID == nil && state.reservedBytes == 0)
                for (url, data) in originals { #expect(try Data(contentsOf: url) == data) }
                let lifecycle = await trace.snapshot().filter { $0.runID == request.id }
                try encoder.encode(lifecycle).write(to: root.appendingPathComponent(mode + "-lifecycle.json"), options: .withoutOverwriting)
                #expect(lifecycle.last?.phase == .released)
                #expect(lifecycle.last?.memory.activeBytes == 0 && lifecycle.last?.memory.cacheBytes == 0)
                var record: [String: Any] = ["runID":request.id.uuidString, "seconds":Date().timeIntervalSince(start),
                    "outcome":String(describing: outcome), "cancelRequested":cancelled, "streamFailure":streamFailure ?? "none", "GUI":false, "progress": progress]
                if mode == "cancel" { #expect(cancelled && outcome == .cancelled && artifacts == 0) }
                else {
                    guard case .completed(let result) = outcome else {
                        throw InferenceFailure.backendFailed("Dev original BF16 failed: \(outcome)")
                    }
                    #expect(streamFailure == nil && artifacts == 1)
                    #expect(progress == Array(0...50), "The complete 50-step trajectory must finish before publication")
                    #expect(result.metadata["loadingStrategy"] == "ssdLayered")
                    #expect(result.metadata["modelRevision"] == LocalFluxDevInventory.revision)
                    if refs != nil {
                        #expect(result.metadata["referenceImageCount"] == "2")
                        #expect(result.metadata["referenceImageSHA256Ordered"] == references.map(\.sha256).joined(separator: ","))
                    }
                    let artifact = try #require(result.artifacts.first)
                    let data = try Data(contentsOf: artifact.url)
                    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
                    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                    #expect(image.width == 512 && image.height == 512)
                    try encoder.encode(result).write(to: root.appendingPathComponent(mode + "-result.json"), options: .withoutOverwriting)
                    record["pngSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    record["metadata"] = result.metadata
                }
                try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent(mode + "-run.json"), options: .withoutOverwriting)
                print("D_DEV_BF16 " + mode)
            }
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
}
}
