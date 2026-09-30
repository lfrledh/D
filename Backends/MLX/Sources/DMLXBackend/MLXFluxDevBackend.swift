import DInference
import Flux2
import Foundation
import MLX
import MLXNN

/// Fixed official BF16 Dev installation. Each model stage has a separate lifetime.
public actor MLXFluxDevBackend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.image.flux2-dev", version: "0.1.0+flux2-959a4af.dev-bf16", capabilities: [.imageGeneration])
    public nonisolated let executionCapability: ImageExecutionCapability = .flux2Dev

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
        guard configuration.profile == .flux2Dev,
              (0...1024 * 1024 * 1024).contains(configuration.cacheLimitBytes),
              configuration.memoryLimitBytes.map({ $0 > 0 }) ?? true else {
            throw InferenceFailure.invalidRequest("The Dev backend requires the BF16 Dev profile and valid allocator settings.")
        }
        try ImageArtifactTransaction.validateRoot(configuration.artifactDirectory)
        self.configuration = configuration
        self.observer = observer
    }

    /// The App can validate an explicit installation without initializing MLX models.
    public func validateModel(at directory: URL) async throws -> ModelReference {
        let model = ModelReference(directory: directory, revision: LocalFluxDevInventory.revision)
        let request = InferenceRequest(model: model, input: .image(ImageRequest(
            prompt: "Installation validation", width: 512, height: 512, steps: 1,
            guidanceScale: 4, seed: 0, executionProfile: ImageExecutionCapability.flux2Dev.profile)))
        let inventory = try LocalFluxDevInventory.inspect(request)
        try inventory.verifyContents()
        return model
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        try Task.checkCancellation()
        let inventory = try LocalFluxDevInventory.inspect(request)
        try ImageArtifactTransaction.validateRoot(configuration.artifactDirectory, model: inventory.directory)
        return ResourceEstimate(peakBytes: inventory.estimatedPeakBytes)
    }

    public func execute(_ request: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed("Dev image execution requires release of the preceding run.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()
        let inventory = try LocalFluxDevInventory.inspect(request)
        try ImageArtifactTransaction.validateRoot(configuration.artifactDirectory, model: inventory.directory)
        guard case .image(let input) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        let allocatorLimit = try configuration.allocatorMemoryLimit(estimatedPeakBytes: inventory.estimatedPeakBytes)
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        runID = request.id
        previousCacheLimit = Memory.cacheLimit
        previousMemoryLimit = Memory.memoryLimit
        Memory.cacheLimit = configuration.cacheLimitBytes
        Memory.memoryLimit = allocatorLimit
        Memory.peakMemory = 0
        let result: InferenceResult
        do {
            try await checkpoint(.verifying)
            try inventory.verifyContents()
            result = try await generate(request: request, input: input, inventory: inventory, emit: emit)
        } catch {
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

    public func cleanupUnpublishedArtifacts() async throws {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed("Wait for Dev inference release before cleaning temporary artifacts.")
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

    private struct Denoised {
        let latents: MLXArray
        let ids: MLXArray
        let referenceTokenCount: Int
    }

    @inline(never)
    private func generate(request: InferenceRequest, input: ImageRequest, inventory: LocalFluxDevInventory,
                          emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        let references = try input.resolvedReferences()
        let state = MLXRandom.RandomState(seed: input.seed)
        let reference = try await encodeReferences(references, directory: inventory.directory, state: state)
        Self.synchronize()
        Memory.clearCache()
        let encoding = try await encode(input: input, directory: inventory.directory, state: state)
        Self.synchronize()
        Memory.clearCache()
        let prepared = try await prepare(input: input, directory: inventory.directory, state: state)
        Self.synchronize()
        Memory.clearCache()
        let denoised = try await denoise(input: input, directory: inventory.directory, encoding: encoding,
                                         prepared: prepared, reference: reference, state: state, emit: emit)
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
        try await emit(.artifact(artifact))
        try Task.checkCancellation()
        var metadata = MLXImageBackend.executionProfileMetadata(inventory.executionProfile)
        metadata.merge([
            "modelRepository": LocalFluxDevInventory.repository,
            "modelRevision": LocalFluxDevInventory.revision,
            "flux2SourceRevision": "959a4af7c0721c800851c84431ffd3fa1f353f1f",
            "precision": "bf16", "width": String(input.width), "height": String(input.height),
            "steps": String(input.steps), "guidanceScale": String(input.guidanceScale),
            "seed": String(input.seed), "promptTruncated": "false", "textSequenceLength": "512",
            "modelTimestepScale": "0.001", "weightBytes": String(inventory.weightBytes),
            "estimatedPeakBytes": String(inventory.estimatedPeakBytes),
            "referenceImageCount": String(references.count),
            "referenceImageSHA256Ordered": references.map(\.sha256).joined(separator: ","),
            "referenceLatentTokenCount": String(denoised.referenceTokenCount),
            "referenceImageIDScale": "10", "pngBytes": String(data.count),
            "pngDecodedAndValidated": "true",
        ], uniquingKeysWith: { _, new in new })
        return InferenceResult(artifacts: [artifact], metadata: metadata)
    }

    @inline(never)
    private func encodeReferences(_ submitted: [ImageReference], directory: URL,
                                  state: MLXRandom.RandomState) async throws -> Flux2ImageMath.ReferenceConditioning? {
        guard !submitted.isEmpty else { return nil }
        var frozen: [ImageReferenceInput] = []
        frozen.reserveCapacity(submitted.count)
        for reference in submitted {
            try Task.checkCancellation()
            frozen.append(try ImageReferenceInput.load(reference))
        }
        try await checkpoint(.loadingVAE)
        let vae = try withRandomState(state) { try Flux2AutoencoderKL.load(from: directory, dtype: .bfloat16) }
        try Flux2ImageMath.validateVAEEncoderWeightCoverage(
            vae: vae, snapshot: directory, expectedDType: .bfloat16)
        try await checkpoint(.vaeLoaded)
        try await checkpoint(.encoding)
        let prepared = try withRandomState(state) {
            var images: [MLXArray] = []
            images.reserveCapacity(frozen.count)
            for input in frozen {
                try Task.checkCancellation()
                images.append(try Flux2ImageMath.referenceTensor(input, dtype: .bfloat16))
                try Task.checkCancellation()
            }
            return try Flux2ImageMath.prepareReference(vae: vae, images: images, dtype: .bfloat16)
        }
        try await checkpoint(.encoded)
        return prepared
    }

    @inline(never)
    private func encode(input: ImageRequest, directory: URL,
                        state: MLXRandom.RandomState) async throws -> Flux2PromptEncoding {
        try await checkpoint(.tokenizing)
        let processor = try Flux2PixtralProcessor.load(from: directory, maxLengthOverride: 512)
        let tokens: Flux2TokenBatch
        do {
            tokens = try processor.encode(prompts: [input.prompt],
                                          systemMessage: Flux2SystemMessages.defaultMessage,
                                          maxLength: 512, truncation: false)
        } catch Flux2PixtralProcessorError.tokenExpansionOverflow(let count, let maximum) {
            throw InferenceFailure.invalidRequest(
                "Complete Dev prompt uses \(count) tokens; maximum is \(maximum). Shorten the prompt.")
        }
        try await checkpoint(.loadingTextEncoder)
        let model = try withRandomState(state) { try Flux2Mistral3TextEncoder.load(from: directory, dtype: .bfloat16) }
        MLX.eval(model)
        try await checkpoint(.textEncoderLoaded)
        let encoder = Flux2DevPromptEncoder(textEncoder: model)
        try await checkpoint(.encoding)
        let encoding = try withRandomState(state) {
            try encoder.encodeTokens(inputIds: tokens.inputIds, attentionMask: tokens.attentionMask)
        }
        MLX.eval(encoding.promptEmbeds, encoding.textIds, encoding.inputIds, encoding.attentionMask)
        guard encoding.inputIds.shape == [1, 512], encoding.promptEmbeds.ndim == 3,
              encoding.promptEmbeds.dim(0) == 1, encoding.promptEmbeds.dim(1) == 512 else {
            throw InferenceFailure.backendFailed("Unexpected FLUX.2 Dev prompt encoding dimensions.")
        }
        try Flux2ImageMath.requireFinite(encoding.promptEmbeds, name: "Dev prompt embeddings")
        try await checkpoint(.encoded)
        return encoding
    }

    @inline(never)
    private func prepare(input: ImageRequest, directory: URL,
                         state: MLXRandom.RandomState) async throws -> Flux2PreparedLatents {
        try await checkpoint(.loadingVAE)
        let vae = try withRandomState(state) { try Flux2AutoencoderKL.load(from: directory, dtype: .bfloat16) }
        try await checkpoint(.vaeLoaded)
        // The already verified fixed transformer config supplies the packed channel
        // count before the large transformer is loaded. The VAE is released first.
        let configURL = directory.appendingPathComponent("transformer/config.json")
        let transformerConfig = try JSONDecoder().decode(
            Flux2TransformerConfiguration.self, from: Data(contentsOf: configURL))
        guard transformerConfig.guidanceEmbeds else {
            throw InferenceFailure.backendFailed("The Dev transformer does not support requested guidance.")
        }
        let inChannels = transformerConfig.inChannels
        let patchArea = vae.configuration.patchSizeArea
        guard patchArea > 0, inChannels > 0, inChannels % patchArea == 0 else {
            throw InferenceFailure.backendFailed("Dev transformer channels and VAE patch area are incompatible.")
        }
        state.seed(input.seed)
        let prepared = try withRandomState(state) {
            try Flux2LatentPreparation.prepareLatents(
                batchSize: 1, numLatentChannels: inChannels / patchArea,
                height: input.height, width: input.width, vae: vae, dtype: .bfloat16)
        }
        MLX.eval(prepared.latents, prepared.ids)
        try Task.checkCancellation()
        return prepared
    }

    @inline(never)
    private func denoise(input: ImageRequest, directory: URL, encoding: Flux2PromptEncoding,
                         prepared: Flux2PreparedLatents, reference: Flux2ImageMath.ReferenceConditioning?,
                         state: MLXRandom.RandomState,
                         emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> Denoised {
        try await checkpoint(.loadingTransformer)
        let transformer = try withRandomState(state) { try Flux2Transformer2DModel.load(from: directory, dtype: .bfloat16) }
        MLX.eval(transformer)
        guard transformer.configuration.inChannels == prepared.latents.dim(2) else {
            throw InferenceFailure.backendFailed("Dev transformer and prepared latents have incompatible channels.")
        }
        try await checkpoint(.transformerLoaded)
        let scheduler = try FlowMatchEulerDiscreteScheduler.load(from: directory)
        try Flux2ImageMath.configure(scheduler: scheduler, latents: prepared.latents, steps: input.steps)
        let denoisingIDs = try Flux2ImageMath.appendReferenceIDs(outputIDs: prepared.ids, reference: reference)
        let denoiser = Flux2Denoiser(transformer: transformer, scheduler: scheduler)
        var current = prepared.latents
        try await emit(.progress(completed: 0, total: input.steps))
        for (index, timestep) in scheduler.timestepsValues.enumerated() {
            try await checkpoint(.denoising)
            current = try withRandomState(state) {
                try Flux2ImageMath.step(denoiser, current: current, timestep: timestep,
                                        promptEmbeds: encoding.promptEmbeds, textIDs: encoding.textIds,
                                        imageIDs: denoisingIDs, referenceLatents: reference?.latents,
                                        guidanceScale: input.guidanceScale)
            }
            try await emit(.progress(completed: index + 1, total: input.steps))
            try Task.checkCancellation()
        }
        return Denoised(latents: current, ids: prepared.ids,
                        referenceTokenCount: reference?.latents.dim(1) ?? 0)
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
        guard decoded.shape == [1, 3, height, width] else {
            throw InferenceFailure.backendFailed("Unexpected Dev decoded image dimensions.")
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
