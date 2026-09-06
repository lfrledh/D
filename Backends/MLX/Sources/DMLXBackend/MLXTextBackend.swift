import DInference
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// A local-only, per-run Qwen2 backend. One instance belongs to one InferenceRuntime.
/// The runtime owns cancellation and calls release after execute has completely drained.
public actor MLXTextBackend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.text", version: "0.1.1+mlx-0.30.6.d1.lm-2.30.6", capabilities: [.textGeneration])

    private let configuration: MLXBackendConfiguration
    private let observer: @Sendable (MLXLifecycleEvent) async -> Void
    private var container: ModelContainer?
    private var lease: UUID?
    private var runID: UUID?
    private var previousCacheLimit: Int?
    private var executing = false
    private var releasing = false

    public init(configuration: MLXBackendConfiguration = .init(),
                observer: @escaping @Sendable (MLXLifecycleEvent) async -> Void = { _ in }) throws {
        guard (1...32768).contains(configuration.maximumPromptTokens),
              (1...8192).contains(configuration.maximumOutputTokens),
              (0...1024 * 1024 * 1024).contains(configuration.cacheLimitBytes) else {
            throw InferenceFailure.invalidRequest("Invalid MLX backend limits.")
        }
        self.configuration = configuration
        self.observer = observer
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        try Task.checkCancellation()
        return ResourceEstimate(peakBytes: try LocalModelInventory.inspect(request, limits: configuration).estimatedPeakBytes)
    }

    public func execute(_ request: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard !executing, lease == nil else {
            throw InferenceFailure.backendFailed("Backend execution requires release of the preceding run.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()
        let inventory = try LocalModelInventory.inspect(request, limits: configuration)
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
        let limits = configuration
        let result: InferenceResult
        do {
            try Task.checkCancellation()
            await observer(MLXLifecycleEvent(runID: request.id, phase: .loading))
            try Task.checkCancellation()
            // .directory follows the upstream local tokenizer and weight paths, with no Hub download.
            // Model initialization and stochastic sampling use a per-run RNG state.
            // The vendored MLX core separately fixes lazy-array assignment ownership;
            // per-run RNG isolation is not a substitute for that core lifetime fix.
            let randomSeed = UInt64.random(in: .min ... .max)
            let randomState = MLXRandom.RandomState(seed: randomSeed)
            let loaded = try await withRandomState(randomState) {
                try await LLMModelFactory.shared.loadContainer(
                    configuration: ModelConfiguration(directory: inventory.directory))
            }
            container = loaded
            await observer(MLXLifecycleEvent(runID: request.id, phase: .loaded))
            try Task.checkCancellation()
            result = try await withRandomState(randomState) {
                try await loaded.perform { (context: ModelContext) in
                    let prepared = try await context.processor.prepare(input: UserInput(prompt: input.prompt))
                    try Task.checkCancellation()
                    let promptTokens = prepared.text.tokens.size
                    guard promptTokens <= limits.maximumPromptTokens,
                          promptTokens + input.maxTokens <= inventory.contextLimit else {
                        throw InferenceFailure.invalidRequest("Tokenized prompt exceeds the model/backend context limit.")
                    }
                    let parameters = GenerateParameters(maxTokens: input.maxTokens,
                                                        temperature: input.temperature, topP: input.topP)
                    await observer(MLXLifecycleEvent(runID: request.id, phase: .generating))
                    try Task.checkCancellation()
                    // This initializer can synchronously prefill. Cancellation is cooperative;
                    // bounded context and measurement are necessary, not a promise of instant interruption.
                    let iterator = try TokenIterator(input: prepared, model: context.model, parameters: parameters)
                    let (stream, generationTask) = MLXLMCommon.generateTask(
                        promptTokenCount: promptTokens, modelConfiguration: context.configuration,
                        tokenizer: context.tokenizer, iterator: iterator)
                    return try await withTaskCancellationHandler {
                        do {
                            var completion: GenerateCompletionInfo?
                            for await item in stream {
                                try Task.checkCancellation()
                                switch item {
                                case .chunk(let text):
                                    if !text.isEmpty { try await emit(.textDelta(text)) }
                                case .info(let info): completion = info
                                case .toolCall:
                                    throw InferenceFailure.backendFailed("Tool calls are not supported by this text-only backend.")
                                }
                            }
                            await generationTask.value
                            try Task.checkCancellation()
                            guard let completion else {
                                throw InferenceFailure.backendFailed("Generation ended without completion information.")
                            }
                            let stopReason = try GenerationTermination.resolve(
                                completion, requestedTokens: input.maxTokens,
                                taskWasCancelled: Task.isCancelled || generationTask.isCancelled)
                            return InferenceResult(metadata: [
                                "promptTokens": String(completion.promptTokenCount),
                                "generationTokens": String(completion.generationTokenCount),
                                "promptSeconds": String(completion.promptTime),
                                "generationSeconds": String(completion.generateTime),
                                "stopReason": stopReason,
                                "upstreamStopReason": String(describing: completion.stopReason),
                                "modelRevision": request.model.revision ?? "unrecorded",
                                "randomSeed": String(randomSeed),
                                "weightBytes": String(inventory.weightBytes),
                                "estimatedPeakBytes": String(inventory.estimatedPeakBytes),
                            ])
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
        } catch {
            // Includes preparation and partially completed loads, before a task handle exists.
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
        // Sharing one instance between runtimes violates InferenceBackend's ownership contract.
        // In that misuse case, never destroy resources still used by the first execution.
        guard !executing, !releasing, let token = lease else { return }
        // Calls are serialized by the runtime. Also ignore accidental observer reentry,
        // so duplicate cleanup cannot erase ownership while the first call is suspended.
        releasing = true
        defer { releasing = false }
        container = nil
        Self.synchronize()
        Memory.clearCache()
        if let previousCacheLimit { Memory.cacheLimit = previousCacheLimit }
        previousCacheLimit = nil
        if let runID { await observer(MLXLifecycleEvent(runID: runID, phase: .released)) }
        runID = nil
        lease = nil
        await MLXExecutionLease.shared.relinquish(token)
    }

    private static func synchronize() {
        Stream.gpu.synchronize()
        Stream.cpu.synchronize()
    }
}
