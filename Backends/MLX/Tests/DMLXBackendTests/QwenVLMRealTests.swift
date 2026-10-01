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
    private actor Trace {
        var events: [MLXLifecycleEvent] = []
        func append(_ value: MLXLifecycleEvent) { events.append(value) }
        func forRun(_ id: UUID) -> [MLXLifecycleEvent] { events.filter { $0.runID == id } }
    }
    /// A separate entry avoids regenerating the already-validated text, image and
    /// tool samples when only timestamped, multi-frame video coverage is missing.
    @Test(.timeLimit(.minutes(120)),
          .enabled(if: ProcessInfo.processInfo.environment["D_TEST_QWEN_MULTIFRAME_FILE"] != nil))
    func timestampedMultiFrameVideoThroughRuntime() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = URL(fileURLWithPath: try #require(env["D_TEST_QWEN_VLM_DIR"]))
        let revision = try #require(env["D_TEST_QWEN_REVISION"])
        let video = URL(fileURLWithPath: try #require(env["D_TEST_QWEN_MULTIFRAME_FILE"]))
        let bytes = try Data(contentsOf: video)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        try #require(duration >= 2 && duration <= 4, "Use the short multi-frame fixture, not a one-frame smoke clip")
        let root = URL(fileURLWithPath: try #require(env["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("qwen-video-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let artifacts = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        let trace = Trace(), encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let backend = try MLXQwenVLMBackend(configuration: .init(artifactDirectory: artifacts,
            maximumPromptTokens: 4096, maximumOutputTokens: 128), observer: { await trace.append($0) })
        let runtime = try InferenceRuntime(backends: [backend], configuration: try .init(memoryBudgetBytes: 15 * 1024 * 1024 * 1024))
        let input = TextRequest(prompt: "Describe the changes you see over time in this short video. Be concise.",
            maxTokens: 128, temperature: 0,
            execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: 4096),
            video: .init(url: video, byteCount: UInt64(bytes.count), contentSHA256: digest, durationSeconds: duration),
            thinking: .init(enableThinking: false), seed: 42, loadingStrategy: .ssdLayered)
        let request = InferenceRequest(model: .init(directory: model, revision: revision), input: .text(input))
        try encoder.encode(request).write(to: root.appendingPathComponent("request.json"), options: .withoutOverwriting)
        let start = Date()
        do {
            let run = try await runtime.submit(request, backendID: backend.descriptor.id)
            var streamed = ""
            for try await event in run.events { if case .textDelta(let value) = event { streamed += value } }
            guard case .completed(let result) = await run.outcome() else { throw InferenceFailure.backendFailed("Multi-frame run did not complete") }
            let text = try #require(result.textResponse?.finalText)
            #expect(!text.isEmpty && text == streamed && result.textResponse?.finishReason == .stop)
            let requested = try #require(result.metadata["videoRequestedTimestamps"]?.split(separator: ",").compactMap { Double($0) })
            let actual = try #require(result.metadata["videoActualTimestamps"]?.split(separator: ",").compactMap { Double($0) })
            let expected = (0..<Int(ceil(duration * 2))).map { Double($0) / 2 }.filter { $0 < duration }
            #expect(requested == expected && actual.count == expected.count && expected.count >= 4)
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 0.001 })
            #expect(Set(actual).count == actual.count)
            #expect(result.metadata["videoDecodedFrames"] == String(expected.count))
            #expect(result.metadata["videoSourceSHA256"] == digest && result.metadata["modelRevision"] == revision)
            #expect((Int(result.metadata["visualTokens"] ?? "") ?? 0) > 0)
            let lifecycle = await trace.forRun(request.id), state = await runtime.snapshot()
            #expect(state.activeRunID == nil && state.reservedBytes == 0)
            #expect(lifecycle.last?.phase == .released)
            #expect(lifecycle.last?.memory.activeBytes == 0 && lifecycle.last?.memory.cacheBytes == 0)
            #expect(SHA256.hash(data: try Data(contentsOf: video)).map { String(format: "%02x", $0) }.joined() == digest)
            try encoder.encode(lifecycle).write(to: root.appendingPathComponent("lifecycle.json"), options: .withoutOverwriting)
            try JSONSerialization.data(withJSONObject: ["seconds": Date().timeIntervalSince(start), "metadata": result.metadata,
                "text": text, "semanticReview": "Response retained for inspection; frame consumption asserted independently"], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
            print("D_QWEN_MULTIFRAME", root.path, "seconds", Date().timeIntervalSince(start))
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
    @Test(.timeLimit(.minutes(720))) func textAndOrderedImagesThroughRuntime() async throws {
        let env = ProcessInfo.processInfo.environment
        let strategy: TextLoadingStrategy?
        if let value = env["D_TEST_QWEN_LOADING"] { strategy = try #require(TextLoadingStrategy(rawValue: value)) }
        else { strategy = nil }
        let revision = strategy == .ssdLayered
            ? try #require(env["D_TEST_QWEN_REVISION"])
            : env["D_TEST_QWEN_REVISION"] ?? "8b2b98c00a6b4d291155e4890773ca8f769aee53"
        let trace = Trace()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let model = URL(fileURLWithPath: try #require(env["D_TEST_QWEN_VLM_DIR"]))
        let root = URL(fileURLWithPath: try #require(env["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("qwen-real-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let artifacts = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        let backend = try MLXQwenVLMBackend(configuration: .init(artifactDirectory: artifacts,
            maximumPromptTokens: 4096, maximumOutputTokens: 256), observer: { await trace.append($0) })
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
            if strategy == .ssdLayered {
                let request = InferenceRequest(model: .init(directory: model, revision: revision), input: .text(.init(
                    prompt: "Write a detailed poem in twelve long stanzas about the changing seasons.", maxTokens: 256,
                    temperature: 0, execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: 1024),
                    thinking: .init(enableThinking: false), seed: 42, loadingStrategy: strategy)))
                let start = Date(), run = try await runtime.submit(request, backendID: backend.descriptor.id)
                var cancelled = false
                do {
                    for try await output in run.events {
                        if case .textDelta = output, !cancelled { cancelled = true; await run.cancel() }
                    }
                } catch { if !cancelled { throw error } }
                let outcome = await run.outcome(), state = await runtime.snapshot()
                #expect(cancelled && outcome == .cancelled)
                #expect(state.activeRunID == nil && state.reservedBytes == 0)
                let lifecycle = await trace.forRun(request.id)
                #expect(lifecycle.last?.phase == .released)
                #expect(lifecycle.last?.memory.activeBytes == 0 && lifecycle.last?.memory.cacheBytes == 0)
                try encoder.encode(lifecycle).write(to: root.appendingPathComponent("cancel-lifecycle.json"), options: .withoutOverwriting)
                try JSONSerialization.data(withJSONObject: ["outcome": String(describing: outcome), "seconds": Date().timeIntervalSince(start), "cancelRequested": cancelled], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("cancel-run.json"), options: .withoutOverwriting)
                print("D_QWEN_REAL cancelled and released", root.path)
            }
            var requests = [[], images].map { inputs in TextRequest(prompt: inputs.isEmpty ? "Return only this JSON object, no explanation: {\"answer\":42,\"ok\":true}" : "Compare the two images in their order. Answer only first or second: which is brighter?",
                    maxTokens: 256, temperature: 0,
                    execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: 1024),
                    images: inputs.isEmpty ? nil : inputs, thinking: .init(enableThinking: false), seed: 42, loadingStrategy: strategy) }
            if let videoPath = env["D_TEST_QWEN_VIDEO_FILE"] {
                let url = URL(fileURLWithPath: videoPath), bytes = try Data(contentsOf: url)
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                requests.append(TextRequest(prompt: "Describe this short video briefly.", maxTokens: 256, temperature: 0,
                    execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: 4096),
                    video: .init(url: url, byteCount: UInt64(bytes.count), contentSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), durationSeconds: duration), thinking: .init(enableThinking: false), seed: 42, loadingStrategy: strategy))
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
                ], tools: [tool], thinking: .init(enableThinking: false), seed: 42, loadingStrategy: strategy))
            for (index, input) in requests.enumerated() {
                let request = InferenceRequest(model: .init(directory: model, revision: revision), input: .text(input))
                let estimate = try await backend.estimate(request)
                try encoder.encode(request).write(to: root.appendingPathComponent("request-\(index).json"), options: .withoutOverwriting)
                try encoder.encode(estimate).write(to: root.appendingPathComponent("estimate-\(index).json"), options: .withoutOverwriting)
                let start = Date(), run = try await runtime.submit(request, backendID: backend.descriptor.id)
                print("D_QWEN_REAL started", index, root.path)
                var text = "", deltas = 0
                for try await output in run.events { if case .textDelta(let part) = output {
                    text += part; deltas += 1
                    if deltas == 1 || deltas % 16 == 0 { print("D_QWEN_REAL progress", index, deltas) }
                } }
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
                #expect(result.metadata["loadingStrategy"] == (strategy?.rawValue ?? "resident"))
                let lifecycle = await trace.forRun(request.id)
                try encoder.encode(lifecycle).write(to: root.appendingPathComponent("lifecycle-\(index).json"), options: .withoutOverwriting)
                let state = await runtime.snapshot()
                #expect(state.activeRunID == nil && state.reservedBytes == 0)
                #expect(lifecycle.last?.phase == .released)
                #expect(lifecycle.last?.memory.activeBytes == 0 && lifecycle.last?.memory.cacheBytes == 0)
                let evidence = try JSONSerialization.data(withJSONObject: ["seconds": Date().timeIntervalSince(start), "loadingStrategy": strategy?.rawValue ?? "resident", "metadata": result.metadata, "text": text, "response": try JSONSerialization.jsonObject(with: JSONEncoder().encode(response))], options: [.prettyPrinted, .sortedKeys])
                try evidence.write(to: root.appendingPathComponent("result-\(index).json"), options: .withoutOverwriting)
                print("D_QWEN_REAL complete", index, Date().timeIntervalSince(start))
                for image in images {
                    #expect(SHA256.hash(data: try Data(contentsOf: image.url)).map { String(format: "%02x", $0) }.joined() == image.contentSHA256)
                }
            }
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
}
}
