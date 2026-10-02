@preconcurrency import AVFoundation
import CoreImage
import DInference
import Foundation
import ImageIO
import MLX
import MLXLMCommon
import MLXVLM
import UniformTypeIdentifiers

public struct QwenVLMConfiguration: Sendable {
    public let artifactDirectory: URL
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let cacheLimitBytes: Int

    public init(artifactDirectory: URL, maximumPromptTokens: Int = 32_768,
                maximumOutputTokens: Int = 8_192, cacheLimitBytes: Int = 64 * 1024 * 1024) {
        self.artifactDirectory = artifactDirectory
        self.maximumPromptTokens = maximumPromptTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.cacheLimitBytes = cacheLimitBytes
    }
}

/// Local Qwen3.5 vision-language execution. Runtime serialization extends through release().
public actor MLXQwenVLMBackend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.vlm.qwen35", version: "0.1.0+mlx-0.31.4.d1.lm-3.31.4", capabilities: [.textGeneration])
    public nonisolated let executionCapability: TextExecutionCapability

    private let configuration: QwenVLMConfiguration
    private let observer: @Sendable (MLXLifecycleEvent) async -> Void
    private var container: ModelContainer?
    private var snapshot: QwenVLMInputSnapshot?
    private var lease: UUID?
    private var runID: UUID?
    private var previousCacheLimit: Int?
    private var executing = false
    private var releasing = false

    public init(configuration: QwenVLMConfiguration,
                observer: @escaping @Sendable (MLXLifecycleEvent) async -> Void = { _ in }) throws {
        guard (1...262_144).contains(configuration.maximumPromptTokens),
              (1...262_144).contains(configuration.maximumOutputTokens),
              (0...1024 * 1024 * 1024).contains(configuration.cacheLimitBytes) else {
            throw InferenceFailure.invalidRequest("Invalid Qwen3.5 VLM backend limits.")
        }
        self.configuration = configuration
        self.observer = observer
        executionCapability = TextExecutionCapability(
            maximumPromptTokens: configuration.maximumPromptTokens,
            maximumOutputTokens: configuration.maximumOutputTokens,
            profile: TextExecutionCapability.qwen35VLMProfile)
    }

    public nonisolated static func validateModel(at directory: URL) throws -> QwenVLMModelInventory {
        try QwenVLMModelInventory.validateModel(at: directory)
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        try Task.checkCancellation()
        let inventory = try QwenVLMModelInventory.inspect(request, capability: executionCapability)
        guard case .text(let input) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        let prompt = UInt64(try executionCapability.resolvedPromptTokens(for: input))
        let tokens = prompt + UInt64(input.maxTokens)
        let kvPerToken: UInt64 = inventory.size == "27B" ? 64 * 4 * 256 * 8 : 32 * 4 * 256 * 8
        let minimumPixels = UInt64(input.visualProcessing?.minimumPixels ?? inventory.minimumPixels)
        let maximumPixels = UInt64(input.visualProcessing?.maximumPixels ?? inventory.maximumPixels)
        guard minimumPixels <= maximumPixels else {
            throw InferenceFailure.invalidRequest("Conflicting pixel overrides.")
        }
        let imagePixels = input.allImages.reduce(UInt64(0)) { total, image in
            let sourcePixels = Self.saturatingMultiply(UInt64(image.width), UInt64(image.height))
            return Self.saturatingAdd(total, min(max(sourcePixels, minimumPixels), maximumPixels))
        }
        var videoPixels: UInt64 = 0
        for video in input.allVideos {
            let samples = video.durationSeconds * 2
            let maximumFrames = input.visualProcessing?.maximumVideoFrames ?? 64
            guard samples.isFinite, samples <= Double(maximumFrames) else {
                throw InferenceFailure.invalidRequest("The full 2 FPS video sample exceeds maximumVideoFrames.")
            }
            let frames = UInt64(samples.rounded(.up))
            // The vision processor pads an odd temporal pair with one extra frame.
            videoPixels = Self.saturatingAdd(videoPixels,
                Self.saturatingMultiply(frames + frames % 2, maximumPixels))
        }
        let visualPixels = Self.saturatingAdd(imagePixels, videoPixels)
        // Estimated peak: transient weights, f32 KV cache, active visual pixels,
        // allocator cache and workspace. No visual term is added for text-only input.
        let peak: UInt64
        if input.loadingStrategy == .ssdLayered {
            peak = try QwenLayeredResourceEstimate.peak(inventory: inventory, tokens: tokens,
                visualPixels: visualPixels, cacheLimit: configuration.cacheLimitBytes)
        } else {
            peak = Self.saturatingAdd(
                Self.saturatingAdd(Self.saturatingMultiply(inventory.weightBytes, 2),
                                   Self.saturatingMultiply(tokens, kvPerToken)),
                Self.saturatingAdd(Self.saturatingMultiply(visualPixels, 8),
                                   UInt64(configuration.cacheLimitBytes) + 512 * 1024 * 1024))
        }
        return ResourceEstimate(peakBytes: peak, confidence: .estimated)
    }

    public func execute(_ request: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard !executing, lease == nil else {
            throw InferenceFailure.backendFailed("VLM execution requires release of the previous run.")
        }
        executing = true
        defer { executing = false }
        let inventory = try QwenVLMModelInventory.inspect(request, capability: executionCapability)
        guard case .text(let input) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        runID = request.id
        previousCacheLimit = Memory.cacheLimit
        Memory.cacheLimit = configuration.cacheLimitBytes
        Memory.peakMemory = 0
        let observer = self.observer
        var outcome: Result<InferenceResult, Error>
        do {
            try Task.checkCancellation()
            let frozen = try QwenVLMInputSnapshot.freeze(input, in: configuration.artifactDirectory,
                                                         modelDirectory: inventory.directory)
            snapshot = frozen
            var decodedClips = [DecodedVideo]()
            for (index, reference) in input.allVideos.enumerated() {
                decodedClips.append(try await decodeVideo(reference, source: frozen.videos[index],
                    maximumFrames: input.visualProcessing?.maximumVideoFrames ?? 64))
            }
            let videos = decodedClips
            try Task.checkCancellation()
            await observer(MLXLifecycleEvent(runID: request.id, phase: .loading))
            let randomSeed = input.seed ?? UInt64.random(in: .min ... .max)
            let randomState = MLXRandom.RandomState(seed: randomSeed)
            let processing = input.visualProcessing
            let registry = ProcessorTypeRegistry(creators: [
                "Qwen3VLProcessor": { data, tokenizer in
                    let normalized = try QwenVLMProcessorConfiguration.normalized(data, overrides: processing)
                    let config = try JSONDecoder().decode(Qwen3VLProcessorConfiguration.self, from: normalized.data)
                    return Qwen3VLProcessor(config, tokenizer: tokenizer, preserveSuppliedVideoFrames: true)
                }
            ])
            let factory = VLMModelFactory(typeRegistry: VLMTypeRegistry.shared,
                                          processorRegistry: registry, modelRegistry: VLMRegistry.shared,
                                          layeredQwen35: input.loadingStrategy == .ssdLayered,
                                          fileSelection: inventory.fileSet?.selection)
            let loaded = try await withRandomState(randomState) {
                try await factory.loadContainer(from: inventory.directory,
                                                using: LocalTokenizerLoader(fileSet: inventory.fileSet))
            }
            container = loaded
            await observer(MLXLifecycleEvent(runID: request.id, phase: .loaded))
            try Task.checkCancellation()
            // Resolve actor-owned capability before sending the generation body to MLX.
            let promptLimit = try executionCapability.resolvedPromptTokens(for: input)
            let executionProfile = executionCapability.profile
            let templateContext = try QwenMessageMapping.context(for: input.thinking, modelSize: inventory.size)
            let generated = try await withRandomState(randomState) {
                try await loaded.perform { (context: ModelContext) in
                    let decodedVideos = try videos.map { video -> UserInput.Video in
                        let frames = try video.frames.map { encoded -> UserInput.VideoFrame in
                            guard let image = CIImage(data: encoded.png) else {
                                throw InferenceFailure.backendFailed("Cannot reconstruct decoded MP4 frame.")
                            }
                            return UserInput.VideoFrame(frame: image,
                                timeStamp: CMTime(value: encoded.timeValue, timescale: encoded.timescale))
                        }
                        return .frames(frames)
                    }
                    var userInput = UserInput(messages: QwenMessageMapping.messages(input),
                                              images: frozen.images.map { .url($0.privateURL) },
                                              videos: decodedVideos,
                                              tools: QwenMessageMapping.tools(input.tools),
                                              additionalContext: templateContext)
                    userInput.processing = .init(minPixels: processing?.minimumPixels,
                                                 maxPixels: processing?.maximumPixels)
                    let prepared = try await context.processor.prepare(input: userInput)
                    try Task.checkCancellation()
                    let promptTokens = prepared.text.tokens.size
                    guard promptTokens <= promptLimit,
                          promptTokens <= inventory.contextLimit,
                          input.maxTokens <= inventory.contextLimit - promptTokens else {
                        throw InferenceFailure.invalidRequest("Tokenized visual prompt exceeds configured or model context.")
                    }
                    let parameters = GenerateParameters(maxTokens: input.maxTokens,
                                                        temperature: input.temperature, topP: input.topP,
                                                        seed: randomSeed)
                    await observer(MLXLifecycleEvent(runID: request.id, phase: .generating))
                    try Task.checkCancellation()
                    let residentStream: AsyncStream<TokenGeneration>?
                    let layeredStream: AsyncThrowingStream<TokenGeneration, Error>?
                    let generationTask: Task<Void, Never>
                    if input.loadingStrategy == .ssdLayered {
                        guard let throwingModel = context.model as? any ThrowingLanguageModel else {
                            throw InferenceFailure.backendFailed("Layered model lacks throwing decode support.")
                        }
                        let iterator = try TokenIterator(throwingInput: prepared,
                            model: throwingModel, parameters: parameters)
                        (layeredStream, generationTask) = MLXLMCommon.generateThrowingTokenTask(
                            promptTokenCount: promptTokens, modelConfiguration: context.configuration,
                            tokenizer: context.tokenizer, iterator: iterator)
                        residentStream = nil
                    } else {
                        let iterator = try TokenIterator(input: prepared, model: context.model,
                            parameters: parameters)
                        (residentStream, generationTask) = MLXLMCommon.generateTokenTask(
                            promptTokenCount: promptTokens, modelConfiguration: context.configuration,
                            tokenizer: context.tokenizer, iterator: iterator)
                        layeredStream = nil
                    }
                    return try await withTaskCancellationHandler {
                        do {
                            var completion: GenerateCompletionInfo?
                            var tokens = [Int]()
                            guard let openID = context.tokenizer.convertTokenToId("<think>"),
                                  let closeID = context.tokenizer.convertTokenToId("</think>") else {
                                throw InferenceFailure.invalidRequest("Qwen tokenizer is missing required response-channel tokens.")
                            }
                            var responseStream = QwenResponseStream(
                                openID: openID, closeID: closeID,
                                thinking: input.thinking?.enableThinking ?? true,
                                tools: input.tools)
                            if let layeredStream {
                              for try await item in layeredStream {
                                try Task.checkCancellation()
                                switch item {
                                case .token(let token):
                                    tokens.append(token)
                                    if let delta = try responseStream.accept(token,
                                        decode: { context.tokenizer.decode(tokenIds: $0) }) {
                                        try await emit(.textDelta(delta))
                                    }
                                case .info(let info): completion = info
                                }
                              }
                            } else if let residentStream {
                              for await item in residentStream {
                                try Task.checkCancellation()
                                switch item {
                                case .token(let token):
                                    tokens.append(token)
                                    if let delta = try responseStream.accept(token,
                                        decode: { context.tokenizer.decode(tokenIds: $0) }) {
                                        try await emit(.textDelta(delta))
                                    }
                                case .info(let info): completion = info
                                }
                              }
                            }
                            await generationTask.value
                            try Task.checkCancellation()
                            guard let completion else {
                                throw InferenceFailure.backendFailed("VLM generation omitted completion information.")
                            }
                            let stop = try GenerationTermination.resolve(
                                completion, requestedTokens: input.maxTokens,
                                taskWasCancelled: Task.isCancelled || generationTask.isCancelled)
                            let raw = context.tokenizer.decode(tokenIds: tokens)
                            let finished = try responseStream.finish(raw: raw, stopped: stop,
                                tools: input.tools, runID: request.id,
                                decode: { context.tokenizer.decode(tokenIds: $0) })
                            if let delta = finished.delta {
                                try await emit(.textDelta(delta))
                            }
                            let imageFrames = prepared.image?.frames ?? []
                            let videoFrames = prepared.video?.frames ?? []
                            let visualTokens = imageFrames.reduce(0) { $0 + $1.product / 4 } +
                                videoFrames.reduce(0) { $0 + $1.product / 4 }
                            let thw = (imageFrames + videoFrames).map { "\($0.t)x\($0.h)x\($0.w)" }.joined(separator: ",")
                            return InferenceResult(metadata: [
                                "promptTokens": String(completion.promptTokenCount),
                                "generationTokens": String(completion.generationTokenCount),
                                "stopReason": stop,
                                "modelRevision": request.model.revision ?? "unrecorded",
                                "modelFamily": inventory.family, "modelSize": inventory.size,
                                "weightBytes": String(inventory.weightBytes),
                                "loadingStrategy": input.loadingStrategy?.rawValue ?? "resident",
                                "randomSeed": String(randomSeed),
                                "executionProfileIdentifier": executionProfile.identifier,
                                "executionProfileRevision": String(executionProfile.revision),
                                "imageCount": String(frozen.images.count),
                                "imageSourceSHA256": frozen.images.map(\.digest).joined(separator: ","),
                                "videoSourceSHA256": frozen.videos.isEmpty ? "none" : frozen.videos.map(\.digest).joined(separator: ","),
                                "visualTHW": thw, "visualTokens": String(visualTokens),
                                "sourceMinimumPixels": String(inventory.minimumPixels),
                                "sourceMaximumPixels": String(inventory.maximumPixels),
                                "effectiveMinimumPixels": String(processing?.minimumPixels ?? inventory.minimumPixels),
                                "effectiveMaximumPixels": String(processing?.maximumPixels ?? inventory.maximumPixels),
                                "videoRequestedFrames": String(videos.reduce(0) { $0 + $1.requestedTimestamps.count }),
                                "videoDecodedFrames": String(videos.reduce(0) { $0 + $1.frames.count }),
                                "videoRequestedTimestamps": videos.flatMap(\.requestedTimestamps).map { String($0) }.joined(separator: ","),
                                "videoActualTimestamps": videos.flatMap(\.actualTimestamps).map { String($0) }.joined(separator: ","),
                                "videoSamplingFPS": "2", "videoAudio": videos.isEmpty ? "none" : "ignored",
                                "videoSemantics": videos.isEmpty ? "none" : "sampled-clip-understanding",
                                "videoTemporalPadding": videos.isEmpty ? "none" : "upstream-odd-frame-padding",
                            ], textResponse: finished.response)
                        } catch {
                            generationTask.cancel()
                            await generationTask.value
                            throw error
                        }
                    } onCancel: {
                        generationTask.cancel()
                    }
                }
            }
            outcome = .success(generated)
        } catch {
            outcome = .failure(error)
        }
        Self.synchronize()
        await observer(MLXLifecycleEvent(runID: request.id, phase: .drained))
        // Source corruption is more informative than a simultaneous cancellation or inference error.
        do { try snapshot?.verifyOriginals() } catch { outcome = .failure(error) }
        // Report filesystem cleanup before returning the outcome. GPU ownership is
        // still released by release(), even when unknown files must be preserved.
        do { try snapshot?.removePrivateFiles() }
        catch { outcome = .failure(InferenceFailure.resourceCleanupUnconfirmed(
            "VLM snapshot retained at \(snapshot?.directory.path ?? "unknown"): \(error.localizedDescription)")) }
        snapshot = nil
        switch outcome {
        case .success(let result):
            try Task.checkCancellation()
            return result
        case .failure(let error): throw error
        }
    }

    public func release() async {
        guard !executing, !releasing, let token = lease else { return }
        releasing = true
        defer { releasing = false }
        container = nil
        Self.synchronize()
        Memory.clearCache()
        if let previousCacheLimit { Memory.cacheLimit = previousCacheLimit }
        previousCacheLimit = nil
        snapshot = nil
        if let runID { await observer(MLXLifecycleEvent(runID: runID, phase: .released)) }
        runID = nil
        lease = nil
        await MLXExecutionLease.shared.relinquish(token)
    }

    private static func synchronize() {
        Stream.gpu.synchronize()
        Stream.cpu.synchronize()
    }

    private static func saturatingMultiply(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? UInt64.max : value
    }
    private static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : value
    }

    private struct EncodedFrame: Sendable {
        let png: Data
        let timeValue: Int64
        let timescale: Int32
    }

    private struct DecodedVideo: Sendable {
        let frames: [EncodedFrame]
        let requestedTimestamps: [Double]
        let actualTimestamps: [Double]

        static let empty = Self(frames: [], requestedTimestamps: [], actualTimestamps: [])
    }

    /// Decode every requested timestamp from the frozen MP4. Upstream `.url` silently
    /// skips failed frames and includes the endpoint, so it is never used here.
    private func decodeVideo(_ reference: TextVideoReference, source: QwenVLMInputSnapshot.Source,
                             maximumFrames: Int) async throws -> DecodedVideo {
        let asset = AVURLAsset(url: source.privateURL)
        let duration = try await asset.load(.duration)
        let actualDuration = duration.seconds
        guard actualDuration.isFinite, actualDuration > 0,
              abs(actualDuration - reference.durationSeconds) <= 0.01,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw InferenceFailure.invalidRequest("MP4 duration or video track disagrees with the request.")
        }
        let requestedSamples = actualDuration * 2
        guard requestedSamples.isFinite, requestedSamples <= Double(maximumFrames),
              requestedSamples <= Double(Int.max / 2) else {
            throw InferenceFailure.invalidRequest("The full 2 FPS video sample exceeds maximumVideoFrames.")
        }
        var times = [CMTime]()
        for index in 0..<Int(requestedSamples.rounded(.up)) {
            let seconds = Double(index) / 2
            if seconds >= actualDuration { break }
            times.append(CMTime(value: Int64(index), timescale: 2))
        }
        guard !times.isEmpty else { throw InferenceFailure.invalidRequest("MP4 has no sampleable timestamp.") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames = [Int: EncodedFrame]()
        var actual = [Int: Double]()
        var failed = false
        await withTaskCancellationHandler {
            for await result in generator.images(for: times) {
                switch result {
                case .success(requestedTime: let requested, let image, actualTime: let timestamp):
                    guard let index = times.firstIndex(of: requested), frames[index] == nil,
                          timestamp.seconds.isFinite else {
                        failed = true
                        continue
                    }
                    let buffer = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
                        failed = true
                        continue
                    }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { failed = true; continue }
                    frames[index] = EncodedFrame(png: buffer as Data, timeValue: timestamp.value,
                                                 timescale: timestamp.timescale)
                    actual[index] = timestamp.seconds
                case .failure(requestedTime: _, _):
                    failed = true
                }
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        try Task.checkCancellation()
        guard !failed, frames.count == times.count, actual.count == times.count else {
            throw InferenceFailure.invalidRequest("MP4 frame decoding did not return every requested 2 FPS frame.")
        }
        return DecodedVideo(frames: times.indices.map { frames[$0]! },
                            requestedTimestamps: times.map(\.seconds),
                            actualTimestamps: times.indices.map { actual[$0]! })
    }

}
