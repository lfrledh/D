import DInference
import Flux2
import Foundation
import MLX
import MLXNN

public struct MLXImageBackendConfiguration: Sendable {
    /// Existing, host-owned local directory. Each execution creates its own unique child.
    public let artifactDirectory: URL
    public let cacheLimitBytes: Int
    public let profile: ImageExecutionProfile
    public let memoryLimitBytes: Int?
    public init(artifactDirectory: URL, cacheLimitBytes: Int = 256 * 1024 * 1024,
                profile: ImageExecutionProfile = .verified512, memoryLimitBytes: Int? = nil) {
        self.artifactDirectory = artifactDirectory.standardizedFileURL
        self.cacheLimitBytes = cacheLimitBytes
        self.profile = profile
        self.memoryLimitBytes = memoryLimitBytes
    }

    func allocatorMemoryLimit(estimatedPeakBytes: UInt64) throws -> Int {
        if let memoryLimitBytes { return memoryLimitBytes }
        guard estimatedPeakBytes <= UInt64(Int.max) else {
            throw InferenceFailure.invalidRequest("The image allocator limit exceeds platform Int capacity.")
        }
        return Int(estimatedPeakBytes)
    }
}

/// Fixed local FLUX.2 Klein 4B q8 pipeline. One instance belongs to one runtime.
/// Encoder, transformer and decoder have separate lifetimes; only evaluated arrays bridge stages.
public actor MLXImageBackend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.image.flux2-klein", version: "0.1.0+flux2-959a4af.d1", capabilities: [.imageGeneration])
    private let configuration: MLXImageBackendConfiguration
    private let observer: @Sendable (MLXLifecycleEvent) async -> Void
    private var lease: UUID?
    private var runID: UUID?
    private var executing = false
    private var releasing = false
    private var previousCacheLimit: Int?
    private var previousMemoryLimit: Int?
    private var unpublished: [ImageArtifactTransaction] = []

    public init(configuration: MLXImageBackendConfiguration,
                observer: @escaping @Sendable (MLXLifecycleEvent) async -> Void = { _ in }) throws {
        guard (0...1024 * 1024 * 1024).contains(configuration.cacheLimitBytes),
              configuration.memoryLimitBytes.map({ $0 > 0 }) ?? true else {
            throw InferenceFailure.invalidRequest("Invalid image backend cache or memory limit.")
        }
        try ImageArtifactTransaction.validateRoot(configuration.artifactDirectory)
        self.configuration = configuration
        self.observer = observer
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        try Task.checkCancellation()
        let inventory = try LocalImageModelInventory.inspect(request, profile: configuration.profile)
        try ImageArtifactTransaction.validateRoot(configuration.artifactDirectory, model: inventory.directory)
        return ResourceEstimate(peakBytes: inventory.estimatedPeakBytes)
    }

    public func execute(_ request: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed("Image execution requires release of the preceding run.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()
        let inventory = try LocalImageModelInventory.inspect(request, profile: configuration.profile)
        try ImageArtifactTransaction.validateRoot(configuration.artifactDirectory, model: inventory.directory)
        guard case .image(let input) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        let allocatorMemoryLimit = try configuration.allocatorMemoryLimit(
            estimatedPeakBytes: inventory.estimatedPeakBytes)
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        runID = request.id
        previousCacheLimit = Memory.cacheLimit
        previousMemoryLimit = Memory.memoryLimit
        Memory.cacheLimit = configuration.cacheLimitBytes
        // This is an allocator scheduling limit, not a hard process RSS cap.
        Memory.memoryLimit = allocatorMemoryLimit
        Memory.peakMemory = 0
        let result: InferenceResult
        do {
            try await checkpoint(.verifying)
            try inventory.verifyContents()
            result = try await generate(request: request, input: input, inventory: inventory, emit: emit)
        } catch {
            // Scope unwinding has dropped partial models, tensors and per-run random state.
            // eval is synchronous; no unstructured generation work survives this boundary.
            Self.synchronize()
            await observer(MLXLifecycleEvent(runID: request.id, phase: .drained))
            throw error
        }
        Self.synchronize()
        await observer(MLXLifecycleEvent(runID: request.id, phase: .drained))
        try Task.checkCancellation()
        return result
    }

    public func release() async {
        guard !executing, !releasing, let token = lease else { return }
        releasing = true
        defer { releasing = false }
        Self.synchronize()
        Flux2RuntimeResources.clearCaches()
        Self.synchronize()
        Memory.clearCache()
        if let previousCacheLimit { Memory.cacheLimit = previousCacheLimit }
        if let previousMemoryLimit { Memory.memoryLimit = previousMemoryLimit }
        previousCacheLimit = nil
        previousMemoryLimit = nil
        if let runID { await observer(MLXLifecycleEvent(runID: runID, phase: .released)) }
        runID = nil
        lease = nil
        await MLXExecutionLease.shared.relinquish(token)
    }

    /// Called by the host after terminal outcome/shutdown. Never deletes a published image.
    /// This tracks only this instance's private transactions, and never scans the host's root.
    public func cleanupUnpublishedArtifacts() async throws {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed("Wait for inference release before cleaning temporary artifacts.")
        }
        var remaining: [ImageArtifactTransaction] = []
        var firstError: (any Error)?
        for transaction in unpublished {
            do { try transaction.cleanupUnpublished() }
            catch { remaining.append(transaction); if firstError == nil { firstError = error } }
        }
        unpublished = remaining
        if let firstError { throw firstError }
    }

    @inline(never)
    private func generate(request: InferenceRequest, input: ImageRequest, inventory: LocalImageModelInventory,
                          emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        let state = MLXRandom.RandomState(seed: input.seed)
        // Use synchronous RNG scopes around each compute call. The upstream async helper
        // does not inherit actor isolation, so tensors must never cross that boundary.
        let denoised = try await generateLatents(input: input, directory: inventory.directory, state: state, emit: emit)
        Self.synchronize()
        Memory.clearCache()
        let rgb = try await decodeRGB(directory: inventory.directory, denoised: denoised,
                                      width: input.width, height: input.height, state: state)
        try await checkpoint(.publishing)
        let data = try ImagePNG.encode(rgb: rgb, width: input.width, height: input.height)
        let transaction = try ImageArtifactTransaction(root: configuration.artifactDirectory, requestID: request.id)
        unpublished.append(transaction)
        let artifact = try transaction.publish(data, width: input.width, height: input.height)
        unpublished.removeAll { $0 === transaction }
        // Publication precedes notification: an error from the consumer must not delete the image.
        try await emit(.artifact(artifact))
        try Task.checkCancellation()
        return InferenceResult(artifacts: [artifact], metadata: [
            "modelRepository": LocalImageModelInventory.repository,
            "modelRevision": LocalImageModelInventory.revision,
            "imageExecutionProfile": configuration.profile.identifier,
            "flux2SourceRevision": "959a4af7c0721c800851c84431ffd3fa1f353f1f",
            "width": String(input.width), "height": String(input.height), "steps": String(input.steps),
            "guidanceScale": String(input.guidanceScale), "seed": String(input.seed),
            "textSequenceLength": "512", "promptTruncated": "false", "modelTimestepScale": "0.001",
            "weightBytes": String(inventory.weightBytes), "estimatedPeakBytes": String(inventory.estimatedPeakBytes),
            "pngBytes": String(data.count), "pngDecodedAndValidated": "true",
        ])
    }

    private struct Denoised {
        let latents: MLXArray
        let ids: MLXArray
    }

    @inline(never)
    private func encode(input: ImageRequest, directory: URL, state: MLXRandom.RandomState) async throws -> Flux2PromptEncoding {
        try await checkpoint(.tokenizing)
        let tokenizer = try Flux2QwenTokenizer.load(from: directory, maxLengthOverride: 512)
        let tokens: Flux2TokenBatch
        do {
            tokens = try tokenizer.encode(prompts: [input.prompt], maxLength: 512, truncation: false)
        } catch Flux2TokenizerError.promptTooLong(_, let count, let maximum) {
            throw InferenceFailure.invalidRequest("Prompt uses \(count) tokens including the model template; maximum is \(maximum). Shorten the prompt.")
        }
        try await checkpoint(.loadingTextEncoder)
        let model = try withRandomState(state) { try Flux2Qwen3TextEncoder.load(from: directory, dtype: .bfloat16) }
        MLX.eval(model)
        try await checkpoint(.textEncoderLoaded)
        let encoder = Flux2KleinPromptEncoder(textEncoder: model, hiddenStateLayers: [9, 18, 27])
        try await checkpoint(.encoding)
        let encoding = try withRandomState(state) {
            try encoder.encodeTokens(inputIds: tokens.inputIds, attentionMask: tokens.attentionMask)
        }
        MLX.eval(encoding.promptEmbeds, encoding.textIds, encoding.inputIds, encoding.attentionMask)
        guard encoding.inputIds.shape == [1, 512], encoding.promptEmbeds.shape == [1, 512, 7680] else {
            throw InferenceFailure.backendFailed("Unexpected FLUX.2 prompt encoding dimensions.")
        }
        try Flux2ImageMath.requireFinite(encoding.promptEmbeds, name: "Prompt embeddings")
        try await checkpoint(.encoded)
        return encoding
    }

    @inline(never)
    private func prepare(directory: URL, inChannels: Int, width: Int, height: Int, dtype: DType,
                         state: MLXRandom.RandomState, seed: UInt64) throws -> Flux2PreparedLatents {
        try Task.checkCancellation()
        // The upstream preparation API uses VAE configuration. Its small model is scoped here,
        // preserving the already verified calculation without retaining it throughout denoising.
        let vae = try withRandomState(state) { try Flux2AutoencoderKL.load(from: directory, dtype: .bfloat16) }
        let patchArea = vae.configuration.patchSizeArea
        guard patchArea > 0, inChannels > 0, inChannels % patchArea == 0 else {
            throw InferenceFailure.backendFailed("Transformer channels and VAE patch area are incompatible.")
        }
        // Model initializers consume random values. Reset ONLY this run's state at the noise boundary.
        state.seed(seed)
        let prepared = try withRandomState(state) {
            try Flux2LatentPreparation.prepareLatents(
                batchSize: 1, numLatentChannels: inChannels / patchArea,
                height: height, width: width, vae: vae, dtype: dtype)
        }
        MLX.eval(prepared.latents, prepared.ids)
        return prepared
    }

    @inline(never)
    private func generateLatents(input: ImageRequest, directory: URL, state: MLXRandom.RandomState,
                                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> Denoised {
        let encoding = try await encode(input: input, directory: directory, state: state)
        Self.synchronize()
        Memory.clearCache()
        return try await denoise(input: input, directory: directory, encoding: encoding, state: state, emit: emit)
    }

    @inline(never)
    private func denoise(input: ImageRequest, directory: URL, encoding: Flux2PromptEncoding,
                         state: MLXRandom.RandomState,
                         emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> Denoised {
        try await checkpoint(.loadingTransformer)
        let transformer = try withRandomState(state) { try Flux2Transformer2DModel.load(from: directory, dtype: .bfloat16) }
        MLX.eval(transformer)
        try await checkpoint(.transformerLoaded)
        let scheduler = try FlowMatchEulerDiscreteScheduler.load(from: directory)
        let prepared = try prepare(directory: directory, inChannels: transformer.configuration.inChannels,
                                   width: input.width, height: input.height,
                                   dtype: encoding.promptEmbeds.dtype, state: state, seed: input.seed)
        Self.synchronize()
        Memory.clearCache()
        try Flux2ImageMath.configure(scheduler: scheduler, latents: prepared.latents, steps: input.steps)
        let denoiser = Flux2Denoiser(transformer: transformer, scheduler: scheduler)
        var current = prepared.latents
        try await emit(.progress(completed: 0, total: input.steps))
        for (index, timestep) in scheduler.timestepsValues.enumerated() {
            try await checkpoint(.denoising)
            current = try withRandomState(state) {
                try Flux2ImageMath.step(denoiser, current: current, timestep: timestep,
                                       promptEmbeds: encoding.promptEmbeds, textIDs: encoding.textIds,
                                       imageIDs: prepared.ids)
            }
            try await emit(.progress(completed: index + 1, total: input.steps))
            try Task.checkCancellation()
        }
        return Denoised(latents: current, ids: prepared.ids)
    }

    @inline(never)
    private func decodeRGB(directory: URL, denoised: Denoised, width: Int, height: Int,
                           state: MLXRandom.RandomState) async throws -> [UInt8] {
        try await checkpoint(.loadingVAE)
        let vae = try withRandomState(state) { try Flux2AutoencoderKL.load(from: directory, dtype: .bfloat16) }
        MLX.eval(vae)
        try await checkpoint(.vaeLoaded)
        try await checkpoint(.decoding)
        let decoded = try withRandomState(state) {
            try Flux2ImageMath.decode(vae: vae, latents: denoised.latents, ids: denoised.ids)
        }
        let expectedShape = [1, 3, height, width]
        guard decoded.shape == expectedShape else {
            throw InferenceFailure.backendFailed("Expected decoded image shape \(expectedShape).")
        }
        try await checkpoint(.decoded)
        return (MLX.clip(decoded[0].asType(.float32) / 2 + 0.5, min: 0, max: 1) * 255)
            .transposed(1, 2, 0).reshaped(-1).asType(.uint8).asArray(UInt8.self)
    }

    private func checkpoint(_ phase: MLXLifecycleEvent.Phase) async throws {
        try Task.checkCancellation()
        Self.synchronize()
        if let runID { await observer(MLXLifecycleEvent(runID: runID, phase: phase)) }
        try Task.checkCancellation()
    }

    private static func synchronize() {
        Stream.gpu.synchronize()
        Stream.cpu.synchronize()
    }
}
