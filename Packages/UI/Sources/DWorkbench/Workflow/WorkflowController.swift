import Foundation
import Observation

/// Coordinates a serial DAG; all expensive model work is still admitted by the shared InferenceRuntime.
@MainActor @Observable public final class WorkflowController {
    public let registry: WorkflowRegistry
    public private(set) var graphs: [WorkflowGraph] = []
    public private(set) var runs: [WorkflowRun] = []
    public private(set) var availableAssets: [ProjectAsset] = []
    public var selectedGraphID: UUID?
    public var selectedNodeID: UUID?
    public private(set) var isRunning = false
    public private(set) var isSaving = false
    public private(set) var readOnlyReason: String?
    public var errorMessage: String?
    public private(set) var progressMessage = "选择一个可编辑样例，或添加节点开始。"
    public var textModelDescription = "尚未选择文字模型"
    public var imageModelDescription = "尚未选择图像模型"
    public private(set) var destinationDescription = "尚未选择导出目录"
    public var graph: WorkflowGraph? { graphs.first { $0.id == selectedGraphID } }
    public var selectedNode: WorkflowNode? { graph?.nodes.first { $0.id == selectedNodeID } }
    public var canUndo: Bool { !closed && !closing && !undoStack.isEmpty && readOnlyReason == nil }
    public var canRedo: Bool { !closed && !closing && !redoStack.isEmpty && readOnlyReason == nil }
    public var hasPendingSaves: Bool { services.hasPendingSaves || persistenceFailed }
    @ObservationIgnored public let services: WorkflowServices
    @ObservationIgnored private var undoStack: [[WorkflowGraph]] = []
    @ObservationIgnored private var redoStack: [[WorkflowGraph]] = []
    @ObservationIgnored private var persistenceFailed = false
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var writeTail: Task<Void, Error>?
    // Internal fault injection at the actual history transaction, used only by CPU tests.
    @ObservationIgnored var beforeHistorySave: () throws -> Void = {}
    @ObservationIgnored public var onChange: @MainActor () async -> Void = {}

    public init(services: WorkflowServices, registry: WorkflowRegistry = .standard) {
        self.services = services; self.registry = registry
        services.progress = { [weak self] in self?.progressMessage = $0 }
        services.candidatesChanged = { [weak self] stepID, items in
            guard let self,
                  let ri = self.runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } }),
                  let si = self.runs[ri].steps.firstIndex(where: { $0.id == stepID }) else { return }
            self.runs[ri].steps[si].outputs = ["output": .collection(items)]
            do { try await self.persist() }
            catch { throw WorkflowSaveFailure(reason: error.localizedDescription) }
        }
    }
    public func load() async {
        do {
            let state = try await services.store.workflowState()
            readOnlyReason = state.readOnlyReason
            guard let archive = state.archive else { return }
            graphs = archive.graphs; runs = archive.runs
            await refreshAssets()
            // Interrupted processes are never silently restarted. Waiting decisions remain valid.
            for i in runs.indices where [.running, .queued, .cancelling].contains(runs[i].status) {
                runs[i].status = .interrupted
                for j in runs[i].steps.indices where [.running, .queued, .cancelling].contains(runs[i].steps[j].status) {
                    runs[i].steps[j].status = .interrupted
                    runs[i].steps[j].error = "上次进程已停止；未自动重新计算。"
                }
            }
            selectedGraphID = graphs.first?.id; selectedNodeID = graph?.nodes.first?.id
        } catch { readOnlyReason = error.localizedDescription; errorMessage = error.localizedDescription }
    }
    public func prepareForClose() async throws {
        guard !isRunning, !services.hasPendingSaves else { throw WorkflowIssue("请先取消运行或恢复待保存结果。") }
        closing = true
        do { if readOnlyReason == nil { try await persist() } }
        catch { closing = false; throw error }
    }
    public func cancelClosing() { closing = false }
    public func deactivateAfterClose() { closed = true; closing = false }
    public func close() async throws { try await prepareForClose(); deactivateAfterClose() }
    public func setDestination(_ url: URL) { services.destination = url; destinationDescription = url.lastPathComponent }
    public func preview(_ ref: WorkflowAssetReference) async throws -> Data { try await services.store.workflowData(ref) }
    public func metadata(_ ref: WorkflowAssetReference) async throws -> String {
        let state = try await services.store.workflowState()
        guard let record = state.archive?.assets.first(where: { $0.reference == ref }) else { throw WorkflowIssue("来源记录不存在。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }
    private func refreshAssets() async {
        availableAssets = await services.store.snapshot().assets.filter { ["text/plain", "image/png", "image/jpeg"].contains($0.mediaType) }
    }
    public func bindExistingAsset(_ id: UUID, nodeID: UUID) async {
        guard !closed, !closing, !isRunning, readOnlyReason == nil else { return }
        let graphID = selectedGraphID
        do {
            let ref = try await services.store.pinWorkflowAsset(id)
            guard graphID == selectedGraphID, !closed, !closing else { throw WorkflowIssue("流程已切换；素材未绑定到另一流程。") }
            attach(ref, nodeID: nodeID); try await persist()
        } catch { errorMessage = error.localizedDescription }
    }
    public func toggleCollapsed(_ id: UUID) {
        edit({ g in if let i = g.layout.firstIndex(where: { $0.nodeID == id }) { g.layout[i].collapsed.toggle() } }, changesConfiguration: false)
    }

    public func editReviewText(stepID: UUID, text: String) {
        guard !closed, !closing, !isRunning, readOnlyReason == nil,
              let ri = runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } }),
              runs[ri].graph.id == selectedGraphID,
              let si = runs[ri].steps.firstIndex(where: { $0.id == stepID }),
              runs[ri].steps[si].node.operationID == "d.text.confirm",
              runs[ri].steps[si].status == .waiting,
              runs[ri].steps[si].decision == nil else { return }
        do {
            try TextDraftDocument.validate(text)
            runs[ri].steps[si].reviewTextDraft = text
        } catch { errorMessage = "确认草稿未改变：\(error.localizedDescription)" }
    }

    private func edit(_ action: (inout WorkflowGraph) throws -> Void, changesConfiguration: Bool = true) {
        guard !closed, !closing, readOnlyReason == nil, let index = graphs.firstIndex(where: { $0.id == selectedGraphID }) else { return }
        do {
            let before = graphs; var value = graphs[index]
            try action(&value)
            if changesConfiguration { value.revision = UUID() }
            try registry.validate(value)
            guard value != graphs[index] else { return }
            undoStack.append(before); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack = []
            graphs[index] = value; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    public func addNode(operationID: String) {
        guard let op = registry.operation(operationID) else { errorMessage = "未知操作。"; return }
        let node = op.definition.makeNode()
        edit { graph in
            graph.nodes.append(node)
            graph.layout.append(.init(nodeID: node.id, x: 80 + Double(graph.nodes.count % 5) * 250, y: 100 + Double(graph.nodes.count / 5) * 210))
        }
        selectedNodeID = node.id
    }
    public func deleteSelected() {
        guard let id = selectedNodeID else { return }
        edit { g in g.nodes.removeAll { $0.id == id }; g.connections.removeAll { $0.sourceNode == id || $0.targetNode == id }; g.layout.removeAll { $0.nodeID == id } }
        selectedNodeID = nil
    }
    public func copySelected() {
        guard var node = selectedNode else { return }; node.id = UUID(); node.title += " 副本"
        edit { g in g.nodes.append(node); g.layout.append(.init(nodeID: node.id, x: 100, y: 100)) }; selectedNodeID = node.id
    }
    public func moveNode(id: UUID, x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        edit({ g in
            if let i = g.layout.firstIndex(where: { $0.nodeID == id }) { g.layout[i].x = max(0, x); g.layout[i].y = max(0, y) }
            else { g.layout.append(.init(nodeID: id, x: max(0, x), y: max(0, y))) }
        }, changesConfiguration: false)
    }
    public func setParameter(nodeID: UUID, key: String, value: WorkflowScalar) {
        edit { g in guard let i = g.nodes.firstIndex(where: { $0.id == nodeID }) else { return }; g.nodes[i].parameters[key] = value }
    }
    public func connect(source: UUID, sourcePort: String, target: UUID, targetPort: String) {
        edit { $0.connections.append(.init(sourceNode: source, sourcePort: sourcePort, targetNode: target, targetPort: targetPort)) }
    }
    public func disconnect(_ connectionID: UUID) { edit { $0.connections.removeAll { $0.id == connectionID } } }
    public func undo() { guard canUndo, let value = undoStack.popLast() else { return }; redoStack.append(graphs); graphs = value }
    public func redo() { guard canRedo, let value = redoStack.popLast() else { return }; undoStack.append(graphs); graphs = value }
    public func addExample(_ name: String) {
        guard !closed, !closing, readOnlyReason == nil else { return }
        let next: WorkflowGraph
        switch name { case "image": next = WorkflowExamples.image(); case "file": next = WorkflowExamples.file()
        case "template": next = WorkflowExamples.template(); default: next = WorkflowExamples.text() }
        undoStack.append(graphs); redoStack = []; graphs.append(next); selectedGraphID = next.id; selectedNodeID = next.nodes.first?.id
    }
    public func attach(_ reference: WorkflowAssetReference, nodeID: UUID) {
        edit { g in guard let i = g.nodes.firstIndex(where: { $0.id == nodeID }), g.nodes[i].operationID == "d.asset.reference" else { throw WorkflowIssue("请选择文件／资产输入节点。") }; g.nodes[i].assetReference = reference }
    }
    public func importFile(_ url: URL, nodeID: UUID) async {
        guard !closed, !closing, readOnlyReason == nil else { return }
        let graphID = selectedGraphID
        do {
            let asset = try await services.store.importWorkflowFile(at: url)
            guard graphID == selectedGraphID else { throw WorkflowIssue("导入期间已切换流程；资产已保存，未绑定到另一流程。") }
            attach(asset.record.reference, nodeID: nodeID); try await persist(); await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    public func publishText(_ text: String, origin: String) async {
        guard !closed, !closing, readOnlyReason == nil else { return }
        do {
            let asset = try await services.store.publishWorkflowAsset(data: Data(text.utf8), mediaType: "text/plain",
                name: "已发布文稿", operationID: "d.text.publish", details: ["origin": origin])
            if graph == nil { addExample("text") }
            guard let operation = registry.operation("d.asset.reference") else { return }
            var node = operation.definition.makeNode(); node.assetReference = asset.record.reference; node.title = "已发布文稿"
            edit { g in g.nodes.append(node); g.layout.append(.init(nodeID: node.id, x: 40, y: 360)) }
            selectedNodeID = node.id; try await persist(); await onChange()
        } catch { errorMessage = error.localizedDescription }
    }

    public func latestStep(for nodeID: UUID) -> WorkflowStepRun? {
        runs.reversed().filter { $0.graph.id == selectedGraphID }.flatMap { $0.steps.reversed() }.first { $0.node.id == nodeID }
    }
    public func isStale(_ step: WorkflowStepRun) -> Bool {
        guard let graph else { return true }
        if (try? registry.signature(step.node.id, in: graph)) != step.signature { return true }
        func upstreamChanged(_ value: WorkflowStepRun, visited: Set<UUID>) -> Bool {
            if visited.contains(value.node.id) { return true }
            let seen = visited.union([value.node.id])
            for edge in graph.connections where edge.targetNode == value.node.id {
                guard let upstream = reusable(nodeID: edge.sourceNode, graph: graph, inputs: nil),
                      value.inputs[edge.targetPort] == upstream.outputs[edge.sourcePort],
                      !upstreamChanged(upstream, visited: seen) else { return true }
            }
            return false
        }
        return upstreamChanged(step, visited: [])
    }
    private func reusable(nodeID: UUID, graph: WorkflowGraph, inputs: [String: WorkflowValue]?) -> WorkflowStepRun? {
        guard let signature = try? registry.signature(nodeID, in: graph) else { return nil }
        return runs.reversed().filter { $0.graph.id == graph.id }.flatMap { $0.steps.reversed() }.first {
            $0.node.id == nodeID && $0.signature == signature && [.completed, .partial].contains($0.status) && (inputs == nil || $0.inputs == inputs)
        }
    }
    public func plan(target: UUID, only: Bool) throws -> [String] {
        guard let graph else { throw WorkflowIssue("请先创建流程。") }
        let ids = try registry.plan(graph, target: target, only: only)
        return try ids.map { id in
            guard let node = graph.nodes.first(where: { $0.id == id }) else { throw WorkflowIssue("节点已不存在。") }
            if only {
                let old = graph.connections.filter { $0.targetNode == id }.contains { edge in
                    reusable(nodeID: edge.sourceNode, graph: graph, inputs: nil).map(isStale) ?? true
                }
                return "重新执行 \(node.title)；使用已就绪的上游资产版本，不重算上游。" + (old ? " 注意：包含旧输入结果。" : "")
            }
            if let step = reusable(nodeID: id, graph: graph, inputs: nil) { return "检查后复用 \(node.title)（\(step.id.uuidString.prefix(8))）；若输入版本不同则重新执行。" }
            if ["d.text.confirm", "d.asset.choose"].contains(node.operationID) { return "等待人工确认：\(node.title)；不会自动启动后续生成。" }
            return "执行：\(node.title)"
        }
    }

    private func persist() async throws {
        guard !closed, readOnlyReason == nil else { throw WorkflowIssue(readOnlyReason ?? "项目已关闭。") }
        // Chain the complete transaction, including its read, so actor reentrancy cannot lose another save.
        let preceding = writeTail, store = services.store, capturedGraphs = graphs, capturedRuns = runs
        let task = Task { @MainActor in
            if let preceding { _ = try? await preceding.value }
            let state = try await store.workflowState()
            guard let archive = state.archive else { throw WorkflowIssue(state.readOnlyReason ?? "流程只读。") }
            try self.beforeHistorySave()
            _ = try await store.saveWorkflow(graphs: capturedGraphs, runs: capturedRuns, expectedRevision: archive.revision)
        }
        writeTail = task; isSaving = true
        do { try await task.value; persistenceFailed = false; isSaving = false; await refreshAssets() }
        catch { persistenceFailed = true; isSaving = false; throw error }
    }
    public func save() async {
        do { try await persist(); progressMessage = "流程、人工决定与运行历史已保存。"; await onChange() }
        catch { errorMessage = error.localizedDescription }
    }
    public func run(target: UUID, only: Bool) async {
        guard !closed, !closing, !isRunning, readOnlyReason == nil, var frozen = graph else { return }
        guard !hasPendingSaves else { errorMessage = "请先恢复保存，避免重复计算。"; return }
        isRunning = true; cancelled = false; errorMessage = nil
        defer { isRunning = false; activeRunID = nil }
        do {
            let ids = try registry.plan(frozen, target: target, only: only)
            let originalRevision = frozen.revision
            frozen = try await services.prepare(frozen, nodes: ids)
            if let i = graphs.firstIndex(where: { $0.id == frozen.id }), graphs[i].revision == originalRevision { graphs[i] = frozen }
            var run = WorkflowRun(graph: frozen, targetNodeID: target, status: .running)
            for id in ids {
                let node = frozen.nodes.first { $0.id == id }!
                var step = WorkflowStepRun(node: node, signature: try registry.signature(id, in: frozen))
                step.repeatRequested = only && id == target
                run.steps.append(step)
            }
            runs.append(run); activeRunID = run.id
            try await persist()
            try await execute(runID: run.id, force: only ? target : nil)
        } catch { errorMessage = error.localizedDescription }
        await services.finish(); await onChange()
    }

    private func inputs(for node: WorkflowNode, run: WorkflowRun) throws -> [String: WorkflowValue] {
        var result: [String: WorkflowValue] = [:]
        for edge in run.graph.connections where edge.targetNode == node.id {
            let source = run.steps.last { $0.node.id == edge.sourceNode && [.completed, .partial].contains($0.status) }
                ?? reusable(nodeID: edge.sourceNode, graph: run.graph, inputs: nil)
            guard let value = source?.outputs[edge.sourcePort] else {
                throw WorkflowIssue("已连接的输入尚未就绪；先运行上游或完成确认。", nodeID: node.id, port: edge.targetPort)
            }
            result[edge.targetPort] = value
        }
        try registry.validateInputs(result, node: node, connectedPorts: Set(run.graph.connections.filter { $0.targetNode == node.id }.map(\.targetPort)))
        return result
    }
    private func execute(runID: UUID, force: UUID? = nil, retryCandidates: [WorkflowCandidate]? = nil) async throws {
        guard let ri = runs.firstIndex(where: { $0.id == runID }) else { throw WorkflowIssue("运行记录不存在。") }
        runs[ri].status = .running
        for si in runs[ri].steps.indices {
            if [.completed, .partial].contains(runs[ri].steps[si].status) { continue }
            if cancelled { runs[ri].status = .cancelled; try await persist(); return }
            if runs[ri].steps[si].status == .waiting { runs[ri].status = .waiting; try await persist(); return }
            let node = runs[ri].steps[si].node
            do {
                let values: [String: WorkflowValue]
                if runs[ri].steps[si].inputsBound == true { values = runs[ri].steps[si].inputs }
                else { values = try inputs(for: node, run: runs[ri]) }
                runs[ri].steps[si].inputs = values
                runs[ri].steps[si].inputsBound = true
                if force != node.id, runs[ri].steps[si].repeatRequested != true, runs[ri].steps[si].status == .queued,
                   let cached = reusable(nodeID: node.id, graph: runs[ri].graph, inputs: values), cached.id != runs[ri].steps[si].id {
                    runs[ri].steps[si].outputs = cached.outputs; runs[ri].steps[si].status = cached.status
                    try await persist(); continue
                }
                try registry.validate(node)
                guard let operation = registry.operation(node.operationID) else { throw WorkflowIssue("操作未注册。") }
                runs[ri].steps[si].status = .running; progressMessage = node.title
                try await persist()
                let retained = retryCandidates ?? runs[ri].steps[si].outputs["output"]?.candidates
                let context = WorkflowExecutionContext(node: node, stepID: runs[ri].steps[si].id, inputs: values, retryCandidates: retained)
                let result = try await operation.execute(context, services)
                if cancelled { throw CancellationError() }
                switch result {
                case .outputs(let values):
                    runs[ri].steps[si].outputs = values
                    let failed = values.values.contains { value in if case .collection(let items) = value { items.contains { $0.asset == nil } } else { false } }
                    runs[ri].steps[si].status = failed ? .partial : .completed
                case .reviewText(let ref):
                    runs[ri].steps[si].outputs = ["preview": .asset(ref)]; runs[ri].steps[si].status = .waiting
                case .choose(let candidates):
                    runs[ri].steps[si].outputs = ["preview": .collection(candidates)]; runs[ri].steps[si].status = .waiting
                }
                if runs[ri].steps[si].status == .waiting {
                    runs[ri].status = .waiting; progressMessage = "等待明确确认，后续尚未执行。"
                    try await persist(); return
                }
                try await persist()
            } catch {
                if [.completed, .partial, .waiting].contains(runs[ri].steps[si].status) {
                    // The operation already delivered its result. Only its history commit failed.
                    // Keep the terminal step so resuming cannot execute it a second time.
                    runs[ri].status = .saving; persistenceFailed = true
                    throw WorkflowSaveFailure(reason: error.localizedDescription)
                }
                let status: WorkflowStepStatus = error is CancellationError ? .cancelled : error is WorkflowSaveFailure ? .saving : .failed
                runs[ri].steps[si].status = status; runs[ri].steps[si].error = error.localizedDescription; runs[ri].status = status
                if let retained = services.retainedCandidates(stepID: runs[ri].steps[si].id) { runs[ri].steps[si].outputs = ["output": .collection(retained)] }
                do { try await persist() } catch { persistenceFailed = true }
                throw error
            }
        }
        runs[ri].status = .completed; progressMessage = "此次运行已完成；旧版本与输入快照均保留。"; try await persist()
    }

    public func cancel() async {
        guard isRunning else { return }; cancelled = true
        if let id = activeRunID, let i = runs.firstIndex(where: { $0.id == id }) { runs[i].status = .cancelling }
        progressMessage = "正在取消，等待计算停止并释放资源。"
        await services.cancel()
    }
    public func decide(stepID: UUID, accept: Bool, text: String?, candidateID: UUID?, acceptPartial: Bool) async {
        guard !closed, !closing, !isRunning, readOnlyReason == nil else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            guard let ri = runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } }),
                  let si = runs[ri].steps.firstIndex(where: { $0.id == stepID }) else { throw WorkflowIssue("等待点不存在。") }
            let step = runs[ri].steps[si]
            if step.decision != nil { return } // Idempotent replay never creates a second derived asset.
            guard step.status == .waiting, !isStale(step) else { throw WorkflowIssue("此等待点已经过期；原输入或连接已改变，请运行新的快照。") }
            var output: WorkflowAssetReference?
            if accept {
                if step.node.operationID == "d.text.confirm" {
                    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let parent = step.outputs["preview"]?.asset else { throw WorkflowIssue("确认文字不能为空。") }
                    output = try await services.publishText(text, parents: [parent], context: .init(node: step.node, stepID: step.id, inputs: step.inputs))
                } else {
                    let items = step.outputs["preview"]?.candidates ?? []
                    guard let chosen = items.first(where: { $0.id == candidateID }), let asset = chosen.asset,
                          acceptPartial || items.allSatisfy({ $0.asset != nil }) else { throw WorkflowIssue("请选择成功候选；部分集合需要明确同意。") }
                    try await services.verifyAsset(asset); output = asset
                }
            }
            guard !isStale(step), runs[ri].steps[si].decision == nil else {
                throw WorkflowIssue("确认期间原输入已改变；派生资产保留，但未采用到新的流程。")
            }
            // Do not resume downstream here. Confirmation and expensive continuation are separate user actions.
            runs[ri].steps[si].decision = WorkflowDecision(waitingStepID: stepID, accepted: accept, selectedCandidateID: candidateID, output: output)
            runs[ri].steps[si].outputs = output.map { ["output": .asset($0)] } ?? [:]
            runs[ri].steps[si].status = accept ? .completed : .rejected
            runs[ri].status = accept ? .waiting : .rejected
            try await persist(); progressMessage = accept ? "决定已保存。明确点击继续运行才会执行下游。" : "已拒绝；没有发布空输出。"
            await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    public func resume(runID: UUID) async {
        guard !closed, !closing, !isRunning, readOnlyReason == nil, let i = runs.firstIndex(where: { $0.id == runID }) else { return }
        guard runs[i].graph.id == selectedGraphID, let current = graph,
              runs[i].steps.allSatisfy({ (try? registry.signature($0.node.id, in: current)) == $0.signature }) else {
            errorMessage = "当前流程已变化；旧运行保留，请运行新的快照。"; return
        }
        guard runs[i].status != .rejected && runs[i].status != .completed else { return }
        isRunning = true; cancelled = false; activeRunID = runID
        defer { isRunning = false; activeRunID = nil }
        do {
            if persistenceFailed { try await persist() }
            _ = try await services.prepare(runs[i].graph, nodes: runs[i].steps.filter { ![.completed, .partial].contains($0.status) }.map { $0.node.id })
            try await execute(runID: runID)
        } catch { errorMessage = error.localizedDescription }
        await services.finish(); await onChange()
    }
    public func retryFailedCandidates(stepID: UUID) async {
        guard !closed, !closing, !isRunning, readOnlyReason == nil,
              let ri = runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } }),
              let si = runs[ri].steps.firstIndex(where: { $0.id == stepID }),
              runs[ri].steps[si].node.operationID == "d.image.generate" else { return }
        let old = runs[ri].steps[si]
        guard !hasPendingSaves else { errorMessage = "先恢复保存并继续原运行，避免重复生成。"; return }
        guard !isStale(old), old.outputs["output"]?.candidates.contains(where: { $0.asset == nil }) == true else { return }
        isRunning = true; cancelled = false; errorMessage = nil
        defer { isRunning = false; activeRunID = nil }
        do {
            let frozen = runs[ri].graph
            _ = try await services.prepare(frozen, nodes: [old.node.id])
            var replacement = WorkflowStepRun(node: old.node, signature: old.signature, inputs: old.inputs)
            replacement.repeatRequested = true
            replacement.inputsBound = true
            replacement.outputs = old.outputs // Retry set survives save failure, cancellation and cold reopen.
            let retry = WorkflowRun(graph: frozen, targetNodeID: old.node.id, steps: [replacement], status: .running)
            runs.append(retry); activeRunID = retry.id
            try await persist()
            try await execute(runID: retry.id, force: old.node.id, retryCandidates: old.outputs["output"]?.candidates)
            progressMessage = "失败项已重试；成功项保留。重新运行选择节点以查看新集合。"
        } catch { errorMessage = error.localizedDescription }
        await services.finish(); await onChange()
    }
}
