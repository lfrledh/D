import AVFoundation
import CryptoKit
import CoreGraphics
import DInference
import DMLXBackend
import DRuntime
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

extension MLXHardwareTests {
@Suite("Fixed Qwen VLM real GPU smoke", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["D_TEST_QWEN_VLM_DIR"] != nil))
struct QwenVLMRealTests {
    @Test(.timeLimit(.minutes(5))) func textAndOrderedImagesThroughRuntime() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = URL(fileURLWithPath: try #require(env["D_TEST_QWEN_VLM_DIR"]))
        let root = URL(fileURLWithPath: try #require(env["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("qwen-real-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let artifacts = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        let backend = try MLXQwenVLMBackend(configuration: .init(artifactDirectory: artifacts,
            maximumPromptTokens: 4096, maximumOutputTokens: 64))
        let runtime = try InferenceRuntime(backends: [backend], configuration: try RuntimeConfiguration(memoryBudgetBytes: 15 * 1024 * 1024 * 1024))
        var images: [TextImageReference] = []
        for (index, component) in [UInt8(0), UInt8(255)].enumerated() {
            let bytes = Data(repeating: component, count: 64 * 64 * 4)
            let provider = try #require(CGDataProvider(data: bytes as CFData))
            let image = try #require(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let data = NSMutableData()
            let target = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(target, image, nil)
            #expect(CGImageDestinationFinalize(target))
            let url = root.appendingPathComponent("image-\(index).png")
            try (data as Data).write(to: url, options: .withoutOverwriting)
            images.append(.init(url: url, width: 64, height: 64, byteCount: UInt64(data.length),
                contentSHA256: SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()))
        }
        do {
            var requests = [[], images].map { inputs in TextRequest(prompt: inputs.isEmpty ? "Say hello briefly." : "Compare the two images in their order. Which is brighter?",
                    maxTokens: 32, temperature: 0,
                    execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: 1024),
                    images: inputs.isEmpty ? nil : inputs) }
            if let videoPath = env["D_TEST_QWEN_VIDEO_FILE"] {
                let url = URL(fileURLWithPath: videoPath), bytes = try Data(contentsOf: url)
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                requests.append(TextRequest(prompt: "Describe this short video briefly.", maxTokens: 32, temperature: 0,
                    execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: 4096),
                    video: .init(url: url, byteCount: UInt64(bytes.count), contentSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), durationSeconds: duration)))
            }
            for (index, input) in requests.enumerated() {
                let request = InferenceRequest(model: .init(directory: model, revision: "8b2b98c00a6b4d291155e4890773ca8f769aee53"), input: .text(input))
                let run = try await runtime.submit(request, backendID: backend.descriptor.id)
                var text = ""
                for try await output in run.events { if case .textDelta(let part) = output { text += part } }
                guard case .completed(let result) = await run.outcome() else { Issue.record("Qwen real run did not complete"); throw InferenceFailure.backendFailed("Qwen real run failed") }
                #expect(!text.isEmpty)
                #expect(result.metadata["imageCount"] == String(input.images?.count ?? 0))
                #expect(result.metadata["modelRevision"] == request.model.revision)
                let evidence = try JSONSerialization.data(withJSONObject: ["metadata": result.metadata, "text": text], options: [.prettyPrinted, .sortedKeys])
                try evidence.write(to: root.appendingPathComponent("result-\(index).json"), options: .withoutOverwriting)
                for image in images {
                    #expect(SHA256.hash(data: try Data(contentsOf: image.url)).map { String(format: "%02x", $0) }.joined() == image.contentSHA256)
                }
            }
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
}
}
