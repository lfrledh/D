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
@Suite("Fixed Qwen VLM real GPU responses", .serialized,
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
            maximumPromptTokens: 4096, maximumOutputTokens: 256))
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
            var requests = [[], images].map { inputs in TextRequest(prompt: inputs.isEmpty ? "Return only this JSON object, no explanation: {\"answer\":42,\"ok\":true}" : "Compare the two images in their order. Answer only first or second: which is brighter?",
                    maxTokens: 256, temperature: 0,
                    execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: 1024),
                    images: inputs.isEmpty ? nil : inputs, thinking: .init(enableThinking: false), seed: 42) }
            if let videoPath = env["D_TEST_QWEN_VIDEO_FILE"] {
                let url = URL(fileURLWithPath: videoPath), bytes = try Data(contentsOf: url)
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                requests.append(TextRequest(prompt: "Describe this short video briefly.", maxTokens: 256, temperature: 0,
                    execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: 4096),
                    video: .init(url: url, byteCount: UInt64(bytes.count), contentSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), durationSeconds: duration), thinking: .init(enableThinking: false), seed: 42))
            }
            let tool = TextToolDefinition(name: "read_number", description: "Read a stored integer", parameters: [
                "type": .string("object"), "properties": .object([:]), "required": .array([])])
            let conversationIndex = requests.count
            requests.append(TextRequest(prompt: "", maxTokens: 256, temperature: 0,
                execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: 4096),
                messages: [
                    .init(role: .system, parts: [.text("Use the tool result as data. Answer with a single integer only.")]),
                    .init(role: .user, parts: [.text("Read the stored number and add one.")]),
                    .init(role: .assistant, parts: [], toolCalls: [.init(id: "call_0", name: "read_number", arguments: [:])]),
                    .init(role: .tool, parts: [.text("41")], toolCallID: "call_0")
                ], tools: [tool], thinking: .init(enableThinking: false), seed: 42))
            for (index, input) in requests.enumerated() {
                let request = InferenceRequest(model: .init(directory: model, revision: "8b2b98c00a6b4d291155e4890773ca8f769aee53"), input: .text(input))
                let run = try await runtime.submit(request, backendID: backend.descriptor.id)
                var text = ""
                for try await output in run.events { if case .textDelta(let part) = output { text += part } }
                guard case .completed(let result) = await run.outcome() else { Issue.record("Qwen real run did not complete"); throw InferenceFailure.backendFailed("Qwen real run failed") }
                let response = try #require(result.textResponse)
                let final = try #require(response.finalText)
                #expect(response.finishReason == .stop)
                #expect(text == final && !final.isEmpty)
                #expect(!final.contains("<think>"))
                if index == 0 {
                    let object = try #require(JSONSerialization.jsonObject(with: Data(final.utf8)) as? [String: Any])
                    #expect(object["answer"] as? Int == 42 && object["ok"] as? Bool == true)
                } else if index == 1 {
                    #expect(final.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("second"))
                } else if index == conversationIndex {
                    #expect(final.trimmingCharacters(in: .whitespacesAndNewlines) == "42")
                } else { #expect(final.split(whereSeparator: \.isWhitespace).count >= 3) }
                #expect(result.metadata["imageCount"] == String(input.images?.count ?? 0))
                #expect(result.metadata["modelRevision"] == request.model.revision)
                let evidence = try JSONSerialization.data(withJSONObject: ["metadata": result.metadata, "text": text, "response": try JSONSerialization.jsonObject(with: JSONEncoder().encode(response))], options: [.prettyPrinted, .sortedKeys])
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
