import DInference
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// A local-only, per-run Qwen2 backend. One instance belongs to one InferenceRuntime.
/// The runtime owns cancellation and calls release after execute has completely drained.
public actor MLXTextBackend: InferenceExecutionPlanning {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.text", version: "0.1.3+mlx-0.31.4.d1.lm-3.31.4", capabilities: [.textGeneration])
    public nonisolated let executionCapability: TextExecutionCapability

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
        executionCapability = TextExecutionCapability(
            maximumPromptTokens: configuration.maximumPromptTokens,
            maximumOutputTokens: configuration.maximumOutputTokens)
        self.configuration = configuration
        self.observer = observer
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        try Task.checkCancellation()
        return ResourceEstimate(peakBytes: try LocalModelInventory.inspect(
            request, capability: executionCapability,
            cacheLimitBytes: configuration.cacheLimitBytes).estimatedPeakBytes)
    }

    private func planSeal(_ request: InferenceRequest) throws -> ModelExecutionSeal {
        let inventory = try LocalModelInventory.inspect(request, capability: executionCapability,
            cacheLimitBytes: configuration.cacheLimitBytes)
        guard let files = inventory.fileSet else {
            throw InferenceFailure.invalidRequest("Layered Qwen2 requires an exact supported revision.")
        }
        return try ModelExecutionSeal.capture(request.model, backend: descriptor, names: Array(files.files.keys))
    }
    public func lowMemoryPlans(for request: InferenceRequest) async throws -> [InferenceExecutionPlan] {
        let seal = try planSeal(request)
        return [.init(request: try request.lowMemoryRequest(method: .layered), method: .layered,
            strategyVersion: 1, modelIdentityToken: seal.token)]
    }
    public func validate(_ plan: InferenceExecutionPlan, for original: InferenceRequest) async throws {
        try plan.validateSemantics(original: original)
        guard plan.method == .layered, plan.strategyVersion == 1,
              try planSeal(original).token == plan.modelIdentityToken else {
            throw InferenceFailure.inputIntegrityChanged("Approved Qwen2 model files changed.")
        }
    }
    public func execute(_ plan: InferenceExecutionPlan, for original: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        try await validate(plan, for: original)
        return try await execute(plan.request, expectedPlan: plan, emit: emit)
    }
    public func execute(_ request: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        try await execute(request, expectedPlan: nil, emit: emit)
    }
    private func execute(_ request: InferenceRequest, expectedPlan: InferenceExecutionPlan?,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard !executing, lease == nil else {
            throw InferenceFailure.backendFailed("Backend execution requires release of the preceding run.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()
        let inventory = try LocalModelInventory.inspect(
            request, capability: executionCapability,
            cacheLimitBytes: configuration.cacheLimitBytes)
        guard case .text(let input) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        let layered = input.loadingStrategy == .ssdLayered
        let admitted = layered ? try planSeal(request) : nil
        if let expectedPlan, admitted?.token != expectedPlan.modelIdentityToken {
            throw InferenceFailure.inputIntegrityChanged("Approved Qwen2 model changed before execution.")
        }
        let selectedModel = request.model, selectedBackend = descriptor
        let selectedNames = inventory.fileSet.map { Array($0.files.keys) } ?? []
        let confirm: @Sendable () throws -> Void = {
            if let admitted, try ModelExecutionSeal.capture(selectedModel, backend: selectedBackend,
                names: selectedNames).token != admitted.token {
                throw InferenceFailure.inputIntegrityChanged("Qwen2 files changed during layered execution.")
            }
        }
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        runID = request.id
        previousCacheLimit = Memory.cacheLimit
        Memory.cacheLimit = configuration.cacheLimitBytes
        Memory.peakMemory = 0
        let observer = self.observer
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
            let factory = inventory.fileSet.map {
                LLMModelFactory(typeRegistry: LLMTypeRegistry.shared, modelRegistry: LLMRegistry.shared,
                                fileSelection: $0.selection, layeredQwen2: layered, admissionValidator: confirm)
            } ?? LLMModelFactory.shared
            let loaded = try await withRandomState(randomState) {
                try await factory.loadContainer(
                    from: inventory.directory, using: LocalTokenizerLoader(fileSet: inventory.fileSet))
            }
            container = loaded
            await observer(MLXLifecycleEvent(runID: request.id, phase: .loaded))
            try Task.checkCancellation()
            result = try await withRandomState(randomState) {
                try await loaded.perform { (context: ModelContext) in
                    let prepared = try await context.processor.prepare(input: UserInput(prompt: input.prompt))
                    try Task.checkCancellation()
                    let promptTokens = prepared.text.tokens.size
                    guard promptTokens <= inventory.maximumPromptTokens,
                          promptTokens + input.maxTokens <= inventory.contextLimit else {
                        throw InferenceFailure.invalidRequest("Tokenized prompt exceeds the model/backend context limit.")
                    }
                    let parameters = GenerateParameters(maxTokens: input.maxTokens,
                                                        temperature: input.temperature, topP: input.topP,
                                                        topK: input.topK ?? 0, minP: input.minP ?? 0,
                                                        repetitionPenalty: input.repetitionPenalty,
                                                        presencePenalty: input.presencePenalty,
                                                        presenceContextSize: input.maxTokens,
                                                        presenceIncludesPrompt: false,
                                                        normalizedTopKFirst: (input.topK ?? 0) > 0,
                                                        seed: randomSeed)
                    await observer(MLXLifecycleEvent(runID: request.id, phase: .generating))
                    try Task.checkCancellation()
                    // This initializer can synchronously prefill. Cancellation is cooperative;
                    // bounded context and measurement are necessary, not a promise of instant interruption.
                    guard let throwingModel = context.model as? any ThrowingLanguageModel else {
                        throw InferenceFailure.backendFailed("Qwen2 model lacks throwing execution support.")
                    }
                    let iterator = try TokenIterator(throwingInput: prepared, model: throwingModel, parameters: parameters)
                    // Keep the upstream token loop/task ownership, but avoid its Character-count
                    // detokenizer (2.30.6), which drops combining scalars and ZWJ sequences.
                    let (stream, generationTask) = MLXLMCommon.generateThrowingTokenTask(
                        promptTokenCount: promptTokens, modelConfiguration: context.configuration,
                        tokenizer: context.tokenizer, iterator: iterator)
                    return try await withTaskCancellationHandler {
                        do {
                            var completion: GenerateCompletionInfo?
                            var tokens = [Int]()
                            var decoder = IncrementalTextDecoder()
                            let toolCalls = ToolCallProcessor(format: context.configuration.toolCallFormat ?? .json)
                            for try await item in stream {
                                try Task.checkCancellation()
                                switch item {
                                case .token(let token):
                                    tokens.append(token)
                                    if let delta = try decoder.consume(context.tokenizer.decode(tokenIds: tokens)),
                                       let text = toolCalls.processChunk(delta), !text.isEmpty {
                                        try await emit(.textDelta(text))
                                    }
                                    if !toolCalls.toolCalls.isEmpty {
                                        throw InferenceFailure.backendFailed("Tool calls are not supported by this text-only backend.")
                                    }
                                case .info(let info): completion = info
                                }
                            }
                            await generationTask.value
                            try Task.checkCancellation()
                            guard let completion else {
                                throw InferenceFailure.backendFailed("Generation ended without completion information.")
                            }
                            if let delta = try decoder.consume(context.tokenizer.decode(tokenIds: tokens), final: true),
                               let text = toolCalls.processChunk(delta), !text.isEmpty {
                                try await emit(.textDelta(text))
                            }
                            if let trailing = toolCalls.processEOS(returnBufferedText: true), !trailing.isEmpty {
                                try await emit(.textDelta(trailing))
                            }
                            if !toolCalls.toolCalls.isEmpty {
                                throw InferenceFailure.backendFailed("Tool calls are not supported by this text-only backend.")
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
                                "loadingStrategy": layered ? "ssdLayered" : "resident",
                                "estimatedPeakBytes": String(inventory.estimatedPeakBytes),
                                "executionProfileIdentifier": inventory.profile.identifier,
                                "executionProfileRevision": String(inventory.profile.revision),
                                "maximumPromptTokens": String(inventory.maximumPromptTokens),
                                "maximumOutputTokens": String(input.maxTokens),
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
