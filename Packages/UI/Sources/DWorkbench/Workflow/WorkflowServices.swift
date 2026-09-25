import DInference
import Foundation
import ImageIO

@MainActor public struct WorkflowModelBinding {
    public let identity: String
    public let reference: ModelReference
    public let backendID: String
    public let release: @MainActor () async -> Void
    public init(identity: String, reference: ModelReference, backendID: String,
                release: @escaping @MainActor () async -> Void = {}) {
        self.identity = identity; self.reference = reference; self.backendID = backendID; self.release = release
    }
}

struct WorkflowSaveFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { "计算结果仍保留，保存未完成：\(reason)。恢复磁盘后重试保存，不必重新推理。" }
}

/// Concrete application operations share the existing Store and runtime. No view or global selected document is consulted.
@MainActor public final class WorkflowServices: WorkflowOperationServices {
    public let store: ProjectStore
    private let session: WorkbenchSession
    private let resolveText: @MainActor () async throws -> WorkflowModelBinding
    private let resolveImage: @MainActor () async throws -> WorkflowModelBinding
    private var bindings: [String: WorkflowModelBinding] = [:]
    private var activeRun: InferenceRun?
    private var textSession: TextDraftSession?
    public var streamedTextCharacterCount: Int { textSession?.partialText.count ?? 0 }
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

    public init(store: ProjectStore, session: WorkbenchSession,
                resolveText: @escaping @MainActor () async throws -> WorkflowModelBinding,
                resolveImage: @escaping @MainActor () async throws -> WorkflowModelBinding) {
        self.store = store; self.session = session; self.resolveText = resolveText; self.resolveImage = resolveImage
    }

    public func prepare(_ graph: WorkflowGraph, nodes: [UUID]) async throws -> WorkflowGraph {
        cancelled = false
        var result = graph
        do {
            for i in result.nodes.indices where nodes.contains(result.nodes[i].id) {
                let kind = result.nodes[i].operationID
                guard kind == "d.text.rewrite" || kind == "d.image.generate" else { continue }
                if bindings[kind] == nil { bindings[kind] = try await (kind == "d.text.rewrite" ? resolveText() : resolveImage()) }
                guard let binding = bindings[kind] else { throw WorkflowIssue("模型尚未登记。") }
                let required = result.nodes[i].parameters["modelID"]?.string ?? ""
                guard required.isEmpty || required == binding.identity else { throw WorkflowIssue("当前模型与节点冻结的模型身份不同，请明确重新绑定。", nodeID: result.nodes[i].id) }
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
        if let textSession { await textSession.cancel() }
        if let activeRun { await activeRun.cancel(); _ = await activeRun.outcome() }
    }
    private func checkCancellation() throws { if cancelled || Task.isCancelled { throw CancellationError() } }

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
            let result = try await store.publishWorkflowAsset(data: content.data, mediaType: content.mediaType,
                metadata: content.metadata, name: context.node.title, parents: content.parents,
                operationID: context.node.operationID, stepID: context.stepID, request: content.request,
                details: content.details, assetID: content.id)
            pending.removeValue(forKey: context.stepID)
            return result.record.reference
        } catch { throw WorkflowSaveFailure(reason: error.localizedDescription) }
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
        guard let binding = bindings["d.text.rewrite"], binding.identity == context.node.parameters["modelID"]?.string else {
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
            details: candidate.result.metadata.merging(["backend": binding.backendID, "modelIdentity": binding.identity,
                                                        "operation": "TextDraftSession.requestRewrite"]) { _, new in new })
        return try await publish(context)
    }

    public func generateImages(prompt: String, reference: WorkflowAssetReference?, context: WorkflowExecutionContext) async throws -> [WorkflowCandidate] {
        guard let binding = bindings["d.image.generate"], binding.identity == context.node.parameters["modelID"]?.string else { throw WorkflowIssue("图像模型未绑定到本次运行。") }
        let p = context.node.parameters
        guard let seed = UInt64(p["seed"]?.string ?? ""), let count = p["count"]?.integer, (1...8).contains(count) else { throw WorkflowIssue("候选数量或 seed 无效。") }
        var items = candidateProgress[context.stepID] ?? context.retryCandidates ?? (0..<count).map { offset in
            WorkflowCandidate(seed: String(seed &+ UInt64(offset)))
        }
        guard items.count == count else { throw WorkflowIssue("候选重试数量与原快照不符。") }
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
                    let input = ImageRequest(prompt: prompt, width: p["width"]?.integer ?? 512, height: p["height"]?.integer ?? 512,
                        steps: p["steps"]?.integer ?? 4, guidanceScale: Float(p["guidance"]?.decimal ?? 1), seed: UInt64(old.seed)!,
                        executionProfile: inputRef == nil ? session.imageCapability.profile : ImageExecutionCapability.referenceKlein4B.profile,
                        referenceImage: inputRef)
                    try session.imageCapability.validate(input)
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
                    let data = try await store.readWorkflowBackendImage(artifact, runID: attempt)
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
        let refs: [WorkflowAssetReference]
        switch value {
        case .asset(let ref): refs = [ref]
        case .collection(let candidates):
            guard candidates.allSatisfy({ $0.asset != nil }), !candidates.isEmpty else { throw WorkflowIssue("含失败候选的集合不能直接导出；先明确选择成功结果。") }
            refs = candidates.compactMap(\.asset)
        case .receipt: throw WorkflowIssue("回执不是可导出媒体。")
        }
        return try await store.exportWorkflowAssets(refs, name: context.node.parameters["fileName"]?.string ?? "D作品",
            exportID: context.stepID, directory: destination)
    }
}
