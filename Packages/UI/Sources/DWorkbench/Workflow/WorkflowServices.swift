import DInference
import Foundation
import ImageIO

struct WorkflowSaveFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { "计算结果仍保留，保存未完成：\(reason)。恢复磁盘后重试保存，不必重新推理。" }
}

/// Concrete application operations share the existing Store and runtime. No view or global selected document is consulted.
@MainActor public final class WorkflowServices: WorkflowOperationServices {
    public let store: ProjectStore
    private let session: WorkbenchSession
    private let resolveModel: @MainActor (WorkflowModelKind, String) async throws -> WorkflowModelBinding
    private let defaultIdentity: @MainActor (WorkflowModelKind) -> String
    private let registry: WorkflowRegistry
    private var bindings: [UUID: WorkflowModelBinding] = [:]
    private var activeRun: InferenceRun?
    private var languageCallActive = false
    private var activeOperation: Task<WorkflowOperationResult, Error>?
    private var textSession: TextDraftSession?
    private var languagePreview = ""
    public var streamedTextCharacterCount: Int { textSession?.partialText.count ?? languagePreview.count }
    public private(set) var cancelled = false
    public var progress: @MainActor (String) -> Void = { _ in }
    public var candidatesChanged: @MainActor (UUID, [WorkflowCandidate]) async throws -> Void = { _, _ in }
    public var destination: URL?
    private struct Publication {
        let id: UUID; let data: Data; let mediaType: String; let metadata: MediaMetadata
        let parents: [WorkflowAssetReference]; let request: InferenceRequest?; let details: [String: String]
    }
    private var pending: [UUID: Publication] = [:]
    private var candidateProgress: [UUID: [WorkflowCandidate]] = [:]
    public var hasPendingSaves: Bool { !pending.isEmpty }

    public init(store: ProjectStore, session: WorkbenchSession, registry: WorkflowRegistry = .standard,
                defaultIdentity: @escaping @MainActor (WorkflowModelKind) -> String = { _ in "" },
                resolveModel: @escaping @MainActor (WorkflowModelKind, String) async throws -> WorkflowModelBinding) {
        self.store = store; self.session = session; self.registry = registry; self.resolveModel = resolveModel; self.defaultIdentity = defaultIdentity
    }

    /// Compatibility for existing callers with one model per kind. Exact identity is
    /// still checked in prepare; this never silently substitutes a different model.
    public convenience init(store: ProjectStore, session: WorkbenchSession,
                defaultIdentity: @escaping @MainActor (WorkflowModelKind) -> String = { _ in "" },
                resolveText: @escaping @MainActor () async throws -> WorkflowModelBinding,
                resolveImage: @escaping @MainActor () async throws -> WorkflowModelBinding) {
        self.init(store: store, session: session, defaultIdentity: defaultIdentity) { kind, _ in
            guard kind == .text || kind == .image else { throw WorkflowIssue("旧模型解析入口不支持此模态。") }
            let binding = try await (kind == .text ? resolveText() : resolveImage())
            return WorkflowModelBinding(identity: binding.identity, reference: binding.reference,
                backendID: binding.backendID, imageRecipe: binding.imageRecipe ?? (kind == .image ? .klein(capability: session.imageCapability) : nil),
                release: binding.release)
        }
    }

    public func prepare(_ graph: WorkflowGraph, nodes: [UUID]) async throws -> WorkflowGraph {
        guard bindings.isEmpty else { throw WorkflowIssue("上一运行的模型使用权尚未释放。") }
        cancelled = false
        var result = graph
        // Capture defaults before the first suspension; each nonempty node ID remains authoritative.
        let defaults = Dictionary(uniqueKeysWithValues: WorkflowModelKind.allCases.map { ($0, defaultIdentity($0)) })
        do {
            for i in result.nodes.indices where nodes.contains(result.nodes[i].id) {
                try checkCancellation()
                let node = result.nodes[i]
                guard let definition = registry.operation(node.operationID)?.definition else {
                    throw WorkflowIssue("未知操作，不能准备模型。", nodeID: node.id)
                }
                guard let kind = definition.modelKind else { continue }
                let required = node.parameters["modelID"]?.string ?? ""
                let selected = required.isEmpty ? (defaults[kind] ?? "") : required
                let binding = try await resolveModel(kind, selected)
                // Retain immediately: validation/cancellation after await must release it too.
                bindings[node.id] = binding
                guard !binding.identity.isEmpty, selected.isEmpty || selected == binding.identity else {
                    throw WorkflowIssue("节点模型缺失或身份不符，不会改用当前模型。", nodeID: node.id)
                }
                if kind == .image && binding.imageRecipe == nil { throw WorkflowIssue("图像实现未提供执行配方。", nodeID: node.id) }
                result.nodes[i].parameters["modelID"] = .text(binding.identity)
                try checkCancellation()
            }
            return result
        } catch { await finish(); throw error }
    }
    public func finish() async {
        let captured = bindings; bindings = [:]
        for binding in captured.values { await binding.release() }
    }
    public func cancel() async {
        cancelled = true
        activeOperation?.cancel()
        if let textSession { await textSession.cancel() }
        if let activeRun { await activeRun.cancel(); _ = await activeRun.outcome() }
    }
    private func checkCancellation() throws { if cancelled || Task.isCancelled { throw CancellationError() } }


    /// Freeze selected identities without resolving files or acquiring leases in unselected branches.
    public func freezeModels(in graph: WorkflowGraph) -> WorkflowGraph {
        var value = graph
        for i in value.nodes.indices {
            if let kind = registry.operation(value.nodes[i].operationID)?.definition.modelKind,
               value.nodes[i].parameters["modelID"]?.string == "" {
                value.nodes[i].parameters["modelID"] = .text(defaultIdentity(kind))
            }
            switch value.nodes[i].control {
            case .branch(let rule, let yes, let no): value.nodes[i].control = .branch(predicate: rule, then: freezeModels(in: yes), otherwise: freezeModels(in: no))
            case .map(let body, let keep): value.nodes[i].control = .map(body: freezeModels(in: body), continueOnFailure: keep)
            case .loop(let body, let schema, let maximum, let rule): value.nodes[i].control = .loop(body: freezeModels(in: body), stateSchema: schema, maximumIterations: maximum, until: rule)
            default: break
            }
        }
        return value
    }
    public func capturedModelDefaults() -> [String: String] { Dictionary(uniqueKeysWithValues: WorkflowModelKind.allCases.map { ($0.rawValue, defaultIdentity($0)) }) }
    public func beginPlan() throws {
        guard bindings.isEmpty, activeRun == nil, !languageCallActive else { throw WorkflowIssue("上一操作尚未释放。") }
        cancelled = false; languagePreview = ""
    }
    /// Plan Call is the only lazy admission point. A branch/tool does not own a model by itself.
    public func executeCall(_ context: WorkflowExecutionContext) async throws -> WorkflowOperationResult {
        try checkCancellation()
        guard !languageCallActive, bindings.isEmpty, let operation = registry.operation(context.node.operationID) else { throw WorkflowIssue("操作未注册或上一模型租约未释放。") }
        try registry.validate(context.node)
        try registry.validateInputs(context.inputs, node: context.node, connectedPorts: Set(context.inputs.keys))
        languageCallActive = true
        defer { languageCallActive = false; activeOperation = nil }
        do {
            if pending[context.stepID] == nil, let kind = operation.definition.modelKind {
                let identity = context.node.parameters["modelID"]?.string ?? ""
                guard !identity.isEmpty else { throw WorkflowIssue("请为节点选择模型。", nodeID: context.node.id) }
                let binding = try await resolveModel(kind, identity)
                bindings[context.node.id] = binding
                guard binding.identity == identity else { throw WorkflowIssue("指定模型身份不一致；不会替换。") }
                try checkCancellation()
            }
            let child = Task { @MainActor in try await operation.execute(context, self) }
            activeOperation = child
            let result = try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
            await finish()
            // A published result survives cancellation during lease release. The interpreter
            // persists it before honoring stop, so a later resume cannot generate it twice.
            return result
        } catch { await finish(); throw error }
    }
    public func transformAudio(_ reference: WorkflowAssetReference, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        if pending[context.stepID] != nil { return try await publish(context) }
        let (url, asset) = try await store.workflowMedia(reference)
        guard let audio = asset.metadata.audio else { throw WorkflowIssue("缺少原声音频规格。") }
        let p = context.node.parameters
        let range = p["whole"]?.flag == false ? AudioFrameRange(startFrame: Int64(p["startFrame"]?.integer ?? -1), endFrame: Int64(p["endFrame"]?.integer ?? -1)) : nil
        let rate = p["sampleRate"]?.integer ?? 0, channels = p["channels"]?.integer ?? 0
        let data = try await WorkflowCPU.run {
            try WorkflowAudioPrograms.transform(at: url, registered: audio, range: range,
                sampleRate: rate == 0 ? nil : rate, channels: channels == 0 ? nil : channels)
        }
        try checkCancellation()
        return try await publishMedia(data, mediaType: "audio/wav", parents: [reference], context: context)
    }
    public func readData(_ reference: WorkflowAssetReference) async throws -> Data { try await store.workflowData(reference) }
    public func publishMedia(_ data: Data, mediaType: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        if pending[context.stepID] == nil {
            pending[context.stepID] = Publication(id: UUID(), data: data, mediaType: mediaType, metadata: .init(),
                parents: parents, request: nil, details: [:])
        }
        return try await publish(context)
    }
    private func model(for context: WorkflowExecutionContext) throws -> WorkflowModelBinding {
        guard let binding = bindings[context.node.id], binding.identity == context.node.parameters["modelID"]?.string else {
            throw WorkflowIssue("模型未绑定到本次操作。")
        }
        return binding
    }
    private func infer(_ request: InferenceRequest, binding: WorkflowModelBinding) async throws -> (InferenceResult, String) {
        try request.validate(); try checkCancellation()
        let run = try await session.engine.submit(request, backendID: binding.backendID)
        activeRun = run
        if cancelled || Task.isCancelled { await run.cancel() }
        var text = "", failure: (any Error)?
        do {
            for try await event in run.events {
                if cancelled || Task.isCancelled { await run.cancel() }
                switch event {
                case .textDelta(let delta):
                    guard text.utf8.count + delta.utf8.count <= 1_048_576 else { throw WorkflowIssue("文字输出超过上限。") }
                    text += delta; languagePreview = text
                case .progress(let completed, let total): progress("\(completed)/\(total)")
                default: break
                }
            }
        } catch { failure = error; await run.cancel() }
        let outcome = await run.outcome(); activeRun = nil
        if case .failed(let authoritativeFailure) = outcome {
            switch authoritativeFailure {
            case .inputIntegrityChanged, .resourceCleanupUnconfirmed: throw authoritativeFailure
            default: break
            }
        }
        try checkCancellation()
        if let failure { throw failure }
        switch outcome {
        case .completed(let result): return (result, text)
        case .cancelled: throw CancellationError()
        case .failed(let error): throw error
        }
    }
    public func generateLanguage(task: String, content: String?, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        if pending[context.stepID] != nil { return try await publish(context) }
        let binding = try model(for: context), p = context.node.parameters
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkflowIssue("任务不能为空。") }
        let prompt = task + (content.map { "\n\nContent:\n" + $0 } ?? "")
        let input = TextRequest(prompt: prompt, maxTokens: p["maximumOutputTokens"]?.integer ?? 256,
            temperature: Float(p["temperature"]?.decimal ?? 0.7), topP: Float(p["topP"]?.decimal ?? 0.95),
            execution: .init(profile: TextExecutionCapability.qwen2Profile, maximumPromptTokens: p["maximumPromptTokens"]?.integer ?? 2048))
        try session.textCapability?.validate(input)
        let request = InferenceRequest(id: context.stepID, model: binding.reference, input: .text(input))
        languagePreview = ""
        let (result, text) = try await infer(request, binding: binding)
        guard !text.isEmpty else { throw WorkflowIssue("语言模型未交付文字。") }
        pending[context.stepID] = Publication(id: UUID(), data: Data(text.utf8), mediaType: "text/plain", metadata: .init(),
            parents: context.inputs.values.flatMap { $0.datum?.assetReferences ?? [] }, request: request,
            details: result.metadata.merging(["backend": binding.backendID, "modelIdentity": binding.identity,
                "outputValidation": "raw model text; structured parsing is separate"]) { _, new in new })
        return try await publish(context)
    }
    public func generateMusic(_ input: AudioRequest, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        if pending[context.stepID] != nil { return try await publish(context) }
        let binding = try model(for: context)
        guard input.noteSequence != nil, let capability = session.musicCapability else { throw WorkflowIssue("需要 MRT2 的真实音符条件配方。") }
        try input.validate(); try capability.validateDuration(input.durationSeconds)
        return try await generateMedia(.audio(input), mediaType: "audio/wav", parents: parents, binding: binding, context: context)
    }
    public func generateVideo(context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        if pending[context.stepID] != nil { return try await publish(context) }
        let binding = try model(for: context), p = context.node.parameters
        guard let seed = UInt64(p["seed"]?.string ?? ""),
              let numerator = Int32(exactly: p["frameRate"]?.integer ?? 16) else { throw WorkflowIssue("T2V 配方或 seed 无效。") }
        let prompt: String
        if let value = context.inputs["prompt"] {
            if let text = value.datum?.text { prompt = text }
            else if let ref = value.datum?.assetReferences.first, ref.kind == .text { prompt = try await readText(ref) }
            else { throw WorkflowIssue("视频提示输入需要文字。") }
        } else { prompt = p["promptText"]?.string ?? "" }
        let input: VideoRequest
        if let recipe = binding.videoRecipe {
            guard context.node.operationID == recipe.operationID else {
                throw WorkflowIssue("所选视频模型与此节点的执行配方不同；不会静默替换。")
            }
            input = try recipe.request(node: context.node, prompt: prompt, seed: seed)
        } else {
            guard context.node.operationID == "d.video.generate", let capability = session.videoCapability else {
                throw WorkflowIssue("指定视频实现尚未准备。")
            }
            input = VideoRequest(prompt: prompt, negativePrompt: p["negativePrompt"]?.string ?? "",
            width: p["width"]?.integer ?? 256, height: p["height"]?.integer ?? 256, frameCount: p["frameCount"]?.integer ?? 17,
            frameRate: .init(numerator: numerator), steps: p["steps"]?.integer ?? 4,
            guidanceScale: Float(p["guidance"]?.decimal ?? 5), scheduleShift: Float(p["scheduleShift"]?.decimal ?? 5),
            seed: seed, executionProfile: capability.profile)
            try capability.validate(input)
        }
        return try await generateMedia(.video(input), mediaType: "video/mp4", parents: context.inputs.values.flatMap { $0.datum?.assetReferences ?? [] },
            binding: binding, context: context)
    }
    public func analyzePitch(_ reference: WorkflowAssetReference, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        if pending[context.stepID] != nil { return try await publish(context) }
        let binding = try model(for: context)
        guard let graphID = context.graphID else { throw WorkflowIssue("音高任务缺少冻结的流程身份。") }
        let input = try await store.prepareWorkflowPitchInput(reference, graphID: graphID, runID: context.stepID)
        return try await generateMedia(.pitch(input), mediaType: PitchAnalysisResult.mediaType, parents: [reference], binding: binding, context: context)
    }
    private func generateMedia(_ input: InferenceInput, mediaType: String, parents: [WorkflowAssetReference],
                               binding: WorkflowModelBinding, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        let budget = context.node.parameters["memoryBudgetGiB"]?.integer ?? 0
        guard budget >= 0, let gib = UInt64(exactly: budget), gib <= UInt64(Int64.max) / 1_073_741_824 else { throw WorkflowIssue("内存预算无效。") }
        let request = InferenceRequest(id: context.stepID, model: binding.reference, input: input,
            memoryBudgetBytes: gib == 0 ? nil : gib * 1_073_741_824)
        let (result, _) = try await infer(request, binding: binding)
        guard result.artifacts.count == 1, let artifact = result.artifacts.first, artifact.mediaType == mediaType else { throw WorkflowIssue("模型未交付预期的单个完整媒体。") }
        let data = try await (session.artifactStore ?? store).readWorkflowBackendMedia(artifact, request: request)
        pending[context.stepID] = Publication(id: UUID(), data: data, mediaType: mediaType, metadata: .init(), parents: parents, request: request,
            details: result.metadata.merging(["backend": binding.backendID, "modelIdentity": binding.identity]) { _, new in new })
        return try await publish(context)
    }

    public func readText(_ reference: WorkflowAssetReference) async throws -> String {
        guard reference.kind == .text, let text = String(data: try await store.workflowData(reference), encoding: .utf8) else {
            throw WorkflowIssue("此端口需要完整 UTF-8 文字资产。")
        }
        return text
    }
    public func verifyAsset(_ reference: WorkflowAssetReference) async throws { _ = try await store.workflowData(reference) }

    private func publish(_ context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        guard let content = pending[context.stepID] else { throw WorkflowIssue("没有待保存结果。") }
        do {
            let result: WorkflowPublishedAsset
            if let request = content.request, case .video(let expected) = request.input {
                result = try await store.publishWorkflowVideo(data: content.data, expected: expected, name: context.node.title,
                    parents: content.parents, operationID: context.node.operationID, stepID: context.stepID,
                    request: request, details: content.details, assetID: content.id)
            } else {
                result = try await store.publishWorkflowAsset(data: content.data, mediaType: content.mediaType,
                    metadata: content.metadata, name: context.node.title, parents: content.parents,
                    operationID: context.node.operationID, stepID: context.stepID, request: content.request,
                    details: content.details, assetID: content.id)
            }
            pending.removeValue(forKey: context.stepID)
            return result.record.reference
        } catch {
            if ["audio/wav", "video/mp4", PitchAnalysisResult.mediaType].contains(content.mediaType) {
                // A corrupt artifact or cancelled decode will not become valid by retrying the disk.
                let retryable: Bool
                switch error {
                case ProjectStoreError.io, AudioMediaError.io, VideoInspectionError.io: retryable = true
                default: retryable = false
                }
                if !retryable { pending.removeValue(forKey: context.stepID); throw error }
            }
            throw WorkflowSaveFailure(reason: error.localizedDescription)
        }
    }
    public func publishText(_ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        if pending[context.stepID] == nil {
            pending[context.stepID] = Publication(id: UUID(), data: Data(text.utf8), mediaType: "text/plain",
                metadata: .init(), parents: parents, request: nil, details: ["encoding": "UTF-8"])
        }
        return try await publish(context)
    }
    public func rewriteText(_ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        if pending[context.stepID] != nil { return try await publish(context) }
        guard let binding = bindings[context.node.id], binding.identity == context.node.parameters["modelID"]?.string else {
            throw WorkflowIssue("文字模型未绑定到本次运行。")
        }
        let p = context.node.parameters
        let settings = TextGenerationSettings(maximumPromptTokens: p["maximumPromptTokens"]?.integer ?? 2048,
            maximumOutputTokens: p["maximumOutputTokens"]?.integer ?? 128)
        let editor = TextDraftSession(document: try TextDraftDocument(text: text, generationSettings: settings),
                                      engine: session.engine, backendID: binding.backendID)
        textSession = editor
        defer { textSession = nil }
        let selection = try editor.selection(inUTF16: NSRange(location: 0, length: text.utf16.count))
        try checkCancellation()
        progress("正在改写；流式文字是预览，尚未发布为流程输入")
        try await editor.requestRewrite(selection: selection, instruction: p["instruction"]?.string ?? "",
            model: binding.reference, temperature: Float(p["temperature"]?.decimal ?? 0.7), topP: Float(p["topP"]?.decimal ?? 0.95))
        try checkCancellation()
        guard let candidate = editor.candidate else { throw WorkflowIssue("后端没有返回可发布文字。") }
        pending[context.stepID] = Publication(id: UUID(), data: Data(candidate.replacement.utf8), mediaType: "text/plain",
            metadata: .init(), parents: parents, request: candidate.request,
            details: candidate.executionDetails()
                .merging(["modelIdentity": binding.identity]) { _, actual in actual })
        return try await publish(context)
    }

    public func generateImages(prompt: String, reference: WorkflowAssetReference?, context: WorkflowExecutionContext) async throws -> [WorkflowCandidate] {
        guard let binding = bindings[context.node.id], binding.identity == context.node.parameters["modelID"]?.string else { throw WorkflowIssue("图像模型未绑定到本次运行。") }
        let p = context.node.parameters
        guard let seed = UInt64(p["seed"]?.string ?? ""), let count = p["count"]?.integer, (1...8).contains(count) else { throw WorkflowIssue("候选数量或 seed 无效。") }
        var items = candidateProgress[context.stepID] ?? context.retryCandidates ?? (0..<count).map { offset in
            WorkflowCandidate(seed: String(seed &+ UInt64(offset)))
        }
        guard items.count == count else { throw WorkflowIssue("候选重试数量与原快照不符。") }
        candidateProgress[context.stepID] = items
        try await candidatesChanged(context.stepID, items)
        let parents = context.inputs.values.compactMap(\.asset)
        for i in items.indices {
            if items[i].asset != nil { continue }
            try checkCancellation()
            progress("生成候选 \(i + 1)/\(count)；等待本次计算及释放完成")
            let old = items[i]
            let attempt = pending[old.attemptID] == nil && old.error != nil ? UUID() : old.attemptID
            let itemContext = WorkflowExecutionContext(node: context.node, stepID: attempt, inputs: context.inputs)
            do {
                if pending[attempt] == nil {
                    let inputRef: ImageReference?
                    if let reference {
                        guard reference.kind == .image else { throw WorkflowIssue("参考端口不是图片。") }
                        _ = try await store.workflowData(reference)
                        // Existing Klein reference preparation accepts PNG; JPEG must pass the explicit conversion node.
                        inputRef = try await store.prepareImageReference(assetID: reference.assetID, runID: attempt)
                    } else { inputRef = nil }
                    guard let recipe = binding.imageRecipe else { throw WorkflowIssue("此图像实现缺少执行配方。") }
                    let input = try recipe.request(node: context.node, prompt: prompt, seed: UInt64(old.seed)!, reference: inputRef)
                    let request = InferenceRequest(id: attempt, model: binding.reference, input: .image(input))
                    try checkCancellation()
                    let run = try await session.engine.submit(request, backendID: binding.backendID)
                    activeRun = run
                    if cancelled { await run.cancel() }
                    var streamFailure: Error?
                    do {
                        for try await event in run.events {
                            if cancelled || Task.isCancelled { await run.cancel() }
                            if case .progress(let completed, let total) = event { progress("候选 \(i + 1)/\(count) · \(completed)/\(total)") }
                        }
                    } catch { streamFailure = error; await run.cancel() }
                    let outcome = await run.outcome(); activeRun = nil
                    try checkCancellation()
                    if let streamFailure { throw streamFailure }
                    let result: InferenceResult
                    switch outcome {
                    case .completed(let value): result = value
                    case .cancelled: throw CancellationError()
                    case .failed(let failure): throw failure
                    }
                    guard result.artifacts.count == 1, let artifact = result.artifacts.first, artifact.mediaType == "image/png" else {
                        throw WorkflowIssue("后端未交付单张完整 PNG。")
                    }
                    let data = try await (session.artifactStore ?? store).readWorkflowBackendImage(artifact, runID: attempt)
                    let metadata = MediaMetadata(width: input.width, height: input.height, bitDepth: 8, colorSpace: "sRGB")
                    pending[attempt] = Publication(id: UUID(), data: data, mediaType: "image/png", metadata: metadata,
                        parents: parents, request: request,
                        details: result.metadata.merging(["backend": binding.backendID, "modelIdentity": binding.identity]) { _, new in new })
                }
                let asset = try await publish(itemContext)
                items[i] = WorkflowCandidate(id: old.id, attemptID: attempt, asset: asset, seed: old.seed)
            } catch is CancellationError {
                items[i] = WorkflowCandidate(id: old.id, attemptID: attempt, error: "已取消", seed: old.seed)
                candidateProgress[context.stepID] = items
                throw CancellationError()
            } catch let failure as WorkflowSaveFailure {
                items[i] = WorkflowCandidate(id: old.id, attemptID: attempt, error: failure.localizedDescription, seed: old.seed)
                candidateProgress[context.stepID] = items
                throw failure
            } catch {
                items[i] = WorkflowCandidate(id: old.id, attemptID: attempt, error: error.localizedDescription, seed: old.seed)
            }
            candidateProgress[context.stepID] = items
            // Each successful candidate is durable before starting the next expensive attempt.
            try await candidatesChanged(context.stepID, items)
        }
        candidateProgress.removeValue(forKey: context.stepID)
        return items
    }
    /// Save-only recovery for the Quick caller. This path never resolves a model or submits inference.
    public func retryQuickPublications(_ context: WorkflowExecutionContext) async throws -> [String: WorkflowValue] {
        if context.node.operationID == "d.image.generate" {
            guard var items = candidateProgress[context.stepID] else { throw WorkflowIssue("没有待保存的候选记录。") }
            for index in items.indices {
                let old = items[index]
                if pending[old.attemptID] != nil {
                    let ref = try await publish(.init(node: context.node, stepID: old.attemptID, inputs: context.inputs))
                    items[index] = .init(id: old.id, attemptID: old.attemptID, asset: ref, seed: old.seed)
                    candidateProgress[context.stepID] = items
                } else if old.asset == nil, old.error == nil {
                    items[index].error = "尚未执行；保存恢复不会自动开始新的推理。"
                }
            }
            return ["output": .collection(items)]
        }
        guard (["d.model.language", "d.music.generate", "d.video.generate", "d.music.pitch"]
            + ExternalVideoExecutionProfile.allCases.map { WorkflowVideoRecipe(profile: $0).operationID }).contains(context.node.operationID) else {
            throw WorkflowIssue("此操作不支持快速保存恢复。")
        }
        let ref = try await publish(context)
        if context.node.operationID == "d.music.pitch" {
            let input = try WorkflowExecution.inputAsset("input", kind: .audio, context: context)
            let result = try JSONDecoder().decode(PitchAnalysisResult.self, from: await readData(ref))
            return try WorkflowMusicOperations.pitchOutputs(input: input, reference: ref, result: result)
        }
        if context.node.operationID == "d.model.language" {
            let text = try await readText(ref)
            let value: WorkflowDatum
            if context.node.parameters["outputMode"]?.string == "json" {
                guard let schema = context.node.dataConfiguration?.schema else { throw WorkflowIssue("缺少输出结构。") }
                value = try WorkflowStructuredText.parse(text, as: schema)
            } else { value = .text(text) }
            return ["raw": .asset(ref), "output": .data(value)]
        }
        return ["output": .asset(ref)]
    }

    public func retainedCandidates(stepID: UUID) -> [WorkflowCandidate]? { candidateProgress[stepID] }

    public func transformImage(_ reference: WorkflowAssetReference, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference {
        if pending[context.stepID] == nil {
            let data = try await store.workflowData(reference)
            let operation = context.node.operationID, parameters = context.node.parameters
            let product = try await Task.detached { try WorkflowImageProcessor.process(data, operationID: operation, parameters: parameters) }.value
            pending[context.stepID] = Publication(id: UUID(), data: product.data, mediaType: product.mediaType,
                metadata: product.metadata, parents: [reference], request: nil, details: product.details)
        }
        return try await publish(context)
    }
    public func export(_ value: WorkflowValue, context: WorkflowExecutionContext) async throws -> WorkflowExportReceipt {
        guard let destination else { throw WorkflowIssue("请先显式选择导出目录；重开项目后需重新授权目的地。") }
        let format = context.node.parameters["format"]?.string ?? "auto"
        guard ["auto", "json", "midi"].contains(format) else { throw WorkflowIssue("导出格式不支持。") }
        if format != "auto" {
            let datum: WorkflowDatum
            switch value {
            case .data(let data): datum = data
            case .asset(let ref): datum = .asset(ref)
            case .collection:
                throw WorkflowIssue("候选集合请先转换为有类型的列表或选择一个结果；未忽略格式选择。")
            case .receipt: throw WorkflowIssue("回执不是可导出内容。")
            }
            return try await store.exportWorkflowDatum(datum, format: format,
                name: context.node.parameters["fileName"]?.string ?? "D作品", exportID: context.stepID, directory: destination)
        }
        let refs: [WorkflowAssetReference]
        switch value {
        case .asset(let ref): refs = [ref]
        case .collection(let candidates):
            guard candidates.allSatisfy({ $0.asset != nil }), !candidates.isEmpty else { throw WorkflowIssue("含失败候选的集合不能直接导出；先明确选择成功结果。") }
            refs = candidates.compactMap(\.asset)
        case .data(let datum):
            if case .asset(let reference) = datum, context.node.parameters["format"]?.string != "json" && context.node.parameters["format"]?.string != "midi" { refs = [reference] }
            else {
                return try await store.exportWorkflowDatum(datum, format: context.node.parameters["format"]?.string ?? "json",
                    name: context.node.parameters["fileName"]?.string ?? "D作品", exportID: context.stepID, directory: destination)
            }
        case .receipt: throw WorkflowIssue("回执不是可导出媒体。")
        }
        return try await store.exportWorkflowAssets(refs, name: context.node.parameters["fileName"]?.string ?? "D作品",
            exportID: context.stepID, directory: destination)
    }
}
