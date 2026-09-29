import Foundation
import Observation

public struct WorkflowAssetBindingTarget: Sendable, Equatable {
    public let graphID: UUID
    public let revision: UUID
    public let path: [WorkflowBodyLocation]
    public let node: WorkflowNode
}

public struct WorkflowCanvasInsertionTarget: Sendable, Equatable {
    public let projectID: UUID
    public let rootID: UUID
    public let revision: UUID
    public let bodyID: UUID
    public let path: [WorkflowBodyLocation]
}

/// Coordinates compiled structured workflows; all expensive model work is still admitted by the shared InferenceRuntime.
@MainActor @Observable public final class WorkflowController {
    public let registry: WorkflowRegistry
    public private(set) var graphs: [WorkflowGraph] = []
    public private(set) var runs: [WorkflowRun] = []
    public private(set) var tools: [WorkflowToolDefinition] = []
    @ObservationIgnored private var activeExecutor: WorkflowPlanExecutor?
    public private(set) var availableAssets: [ProjectAsset] = []
    public private(set) var projectID: UUID?
    public private(set) var assetReferences: [UUID: WorkflowAssetReference] = [:]
    public var canEditCanvas: Bool { !closed && !closing && !isRunning && !externalOperationBusy() && readOnlyReason == nil }
    public var selectedGraphID: UUID? { didSet { if oldValue != selectedGraphID { bodyPath = []; selectedNodeIDs = [] } } }
    public private(set) var bodyPath: [WorkflowBodyLocation] = []
    public var selectedNodeIDs: Set<UUID> = []
    public var selectedNodeID: UUID?
    public private(set) var isRunning = false
    public private(set) var isSaving = false
    public private(set) var readOnlyReason: String?
    public var errorMessage: String?
    public var mediaPreviewReference: WorkflowAssetReference?
    /// The existing project recording owner may temporarily reserve interactive work.
    @ObservationIgnored public var externalOperationBusy: () -> Bool = { false }
    public private(set) var progressMessage = "选择一个可编辑样例，或添加节点开始。"
    public var textModelDescription = "尚未选择文字模型"
    public var imageModelDescription = "尚未选择图像模型"
    public var modelChoices: [WorkflowModelChoice] = []
    public private(set) var destinationDescription = "尚未选择导出目录"
    public var rootGraph: WorkflowGraph? { graphs.first { $0.id == selectedGraphID } }
    public var graph: WorkflowGraph? { rootGraph.flatMap { try? WorkflowGraphEditing.body(in: $0, path: bodyPath) } }
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
            guard let self, let executor = self.activeExecutor else { throw WorkflowIssue("图像进度没有当前执行所有者。") }
            do { try await executor.updateCandidates(stepID: stepID, candidates: items) }
            catch { throw WorkflowSaveFailure(reason: error.localizedDescription) }
        }
    }
    public func load() async {
        do {
            let state = try await services.store.workflowState()
            readOnlyReason = state.readOnlyReason
            guard let archive = state.archive else { return }
            graphs = archive.graphs; runs = archive.runs; tools = archive.tools ?? []
            await refreshAssets()
            // Interrupted processes are never silently restarted. Waiting decisions remain valid.
            for i in runs.indices where [.running, .queued, .cancelling].contains(runs[i].status) {
                runs[i].status = .interrupted
                if var checkpoint = runs[i].planCheckpoint {
                    checkpoint.state = .interrupted
                    for j in checkpoint.records.indices where [.running, .queued, .cancelling].contains(checkpoint.records[j].step.status) {
                        checkpoint.records[j].step.status = .interrupted
                        checkpoint.records[j].step.error = "上次进程已停止；未自动重新计算。"
                    }
                    runs[i].planCheckpoint = checkpoint
                }
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
    public func libraryKind(of asset: ProjectAsset) -> WorkflowDataKind? { WorkflowMediaFormat.descriptor(asset.mediaType)?.kind }
    private func refreshAssets() async {
        let snapshot = await services.store.snapshot()
        projectID = snapshot.id
        availableAssets = snapshot.assets.filter { WorkflowMediaFormat.descriptor($0.mediaType) != nil }
        assetReferences = [:]
        do {
            let state = try await services.store.workflowState()
            if let reason = state.readOnlyReason { errorMessage = reason; return }
            if let archive = state.archive {
                assetReferences = Dictionary(archive.assets.map { ($0.reference.assetID, $0.reference) }, uniquingKeysWith: { _, last in last })
            }
        } catch { errorMessage = error.localizedDescription }
    }
    public func bindExistingAsset(_ id: UUID, nodeID: UUID) async {
        guard !closed, !closing, !isRunning, readOnlyReason == nil else { return }
        guard let target = assetBindingTarget(nodeID: nodeID) else { return }
        do {
            let ref = try await services.store.pinWorkflowAsset(id)
            guard isCurrent(target) else { throw WorkflowIssue("流程或输入节点已改变；素材未绑定到另一位置。") }
            attach(ref, nodeID: nodeID); try await persist()
        } catch { errorMessage = error.localizedDescription }
    }
    public func assetBindingTarget(nodeID: UUID) -> WorkflowAssetBindingTarget? {
        guard !closed, !closing, readOnlyReason == nil, let root = rootGraph,
              let node = graph?.nodes.first(where: { $0.id == nodeID }),
              registry.operation(node.operationID)?.definition.interaction == .assetInput else { return nil }
        return .init(graphID: root.id, revision: root.revision, path: bodyPath, node: node)
    }
    public func isCurrent(_ target: WorkflowAssetBindingTarget) -> Bool {
        !closed && !closing && readOnlyReason == nil && rootGraph?.id == target.graphID &&
        rootGraph?.revision == target.revision && bodyPath == target.path &&
        graph?.nodes.first(where: { $0.id == target.node.id }) == target.node
    }
    public func bindRecordedAsset(_ id: UUID, target: WorkflowAssetBindingTarget) async {
        do {
            let ref = try await services.store.pinWorkflowAsset(id)
            guard isCurrent(target), ref.kind == .audio else { throw WorkflowIssue("录音已保存，但原输入位置已改变；请从项目素材中重新选择。") }
            attach(ref, nodeID: target.node.id); try await persist(); await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    public func toggleCollapsed(_ id: UUID) {
        edit({ g in if let i = g.layout.firstIndex(where: { $0.nodeID == id }) { g.layout[i].collapsed.toggle() } }, changesConfiguration: false)
    }

    public func editReviewText(stepID: UUID, text: String) {
        // Editing a waiting draft is safe during another run: execute() never
        // consumes an undecided waiting step, and acceptance still requires idle.
        guard !closed, !closing, readOnlyReason == nil,
              let ri = runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } || $0.planCheckpoint?.records.contains { $0.id == stepID } == true }),
              let step = runs[ri].planCheckpoint?.records.first(where: { $0.id == stepID })?.step ?? runs[ri].steps.first(where: { $0.id == stepID }),
              belongsToSelectedWorkflow(runs[ri]),
              registry.operation(step.node.operationID)?.definition.interaction == .textReview,
              step.status == .waiting, step.decision == nil else { return }
        do {
            try TextDraftDocument.validate(text)
            if let si = runs[ri].steps.firstIndex(where: { $0.id == stepID }) { runs[ri].steps[si].reviewTextDraft = text }
            if let ci = runs[ri].planCheckpoint?.records.firstIndex(where: { $0.step.id == stepID }) { runs[ri].planCheckpoint?.records[ci].step.reviewTextDraft = text }
        } catch { errorMessage = "确认草稿未改变：\(error.localizedDescription)" }
    }

    private func edit(_ action: (inout WorkflowGraph) throws -> Void, changesConfiguration: Bool = true) {
        guard !closed, !closing, readOnlyReason == nil, let index = graphs.firstIndex(where: { $0.id == selectedGraphID }) else { return }
        do {
            let before = graphs
            var value = try WorkflowGraphEditing.body(in: graphs[index], path: bodyPath)
            try action(&value)
            if changesConfiguration { value.revision = UUID() }
            try registry.validate(value, tools: tools)
            let replacement = try WorkflowGraphEditing.replacingBody(in: graphs[index], path: bodyPath, with: value)
            guard replacement != graphs[index] else { return }
            undoStack.append(before); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack = []
            graphs[index] = replacement; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    public func openBody(nodeID: UUID, slot: String) {
        guard !isRunning, let rootGraph else { return }
        do {
            let path = bodyPath + [.init(nodeID: nodeID, slot: slot)]
            let body = try WorkflowGraphEditing.body(in: rootGraph, path: path)
            bodyPath = path; selectedNodeID = body.nodes.first?.id; selectedNodeIDs = []
        } catch { errorMessage = error.localizedDescription }
    }
    public func closeBody() {
        guard !isRunning, let location = bodyPath.last else { return }
        bodyPath.removeLast(); selectedNodeID = location.nodeID; selectedNodeIDs = []
    }
    public func updateNode(_ node: WorkflowNode, in graphID: UUID) {
        guard graph?.id == graphID else { errorMessage = "编辑目标已切换。"; return }
        edit { graph in
            guard let index = graph.nodes.firstIndex(where: { $0.id == node.id }), graph.nodes[index].operationID == node.operationID else {
                throw WorkflowIssue("编辑节点已改变。")
            }
            graph.nodes[index] = node
        }
    }
    public func updateInterface(_ interface: WorkflowGraphInterface?, in graphID: UUID) {
        guard graph?.id == graphID else { return }
        edit { $0.interface = interface }
    }
    public func extractSelection(name: String, inputs: [WorkflowToolInputBinding], outputs: [WorkflowNamedOutput], expectedGraphID: UUID, expectedRevision: UUID) {
        guard !closed, !closing, !isRunning, readOnlyReason == nil, let graph,
              graph.id == expectedGraphID, graph.revision == expectedRevision else { errorMessage = "封装期间原图已改变；请重新检查边界。"; return }
        do {
            let result = try WorkflowToolEditing.extract(graph, selected: selectedNodeIDs, name: name, inputs: inputs, outputs: outputs, tools: tools, registry: registry)
            let oldTools = tools; tools.append(result.tool)
            edit { $0 = result.graph }
            if self.graph?.nodes.contains(where: { $0.id == result.invocationID }) != true { tools = oldTools; return }
            selectedNodeID = result.invocationID; selectedNodeIDs = []
        } catch { errorMessage = error.localizedDescription }
    }
    public func addTool(_ tool: WorkflowToolDefinition, x: Double = 160, y: Double = 160) {
        guard canEditCanvas, x.isFinite, y.isFinite,
              let definition = registry.operation("d.control.invoke")?.definition else { return }
        do {
            guard tools.contains(tool), let interface = tool.graph.interface else { throw WorkflowIssue("工具版本不在项目中。") }
            var node = definition.makeNode(); node.title = tool.name
            node.control = .invoke(.init(id: tool.id, version: tool.version, digest: try WorkflowPlanCompiler.digest(tool)))
            node.dataConfiguration = .init(fields: interface.inputs)
            let createdGraph = graph == nil
            if createdGraph { addBlankGraph() }
            edit { $0.nodes.append(node); $0.layout.append(.init(nodeID: node.id, x: x, y: y)) }
            if graph?.nodes.contains(where: { $0.id == node.id }) == true {
                if createdGraph { _ = undoStack.popLast() }
                selectedNodeID = node.id
            }
        } catch { errorMessage = error.localizedDescription }
    }
    public func openToolCopy(_ reference: WorkflowToolReference) {
        guard !closed, !closing, !isRunning, readOnlyReason == nil,
              let tool = tools.first(where: { $0.id == reference.id && $0.version == reference.version }) else { return }
        do {
            guard try WorkflowPlanCompiler.digest(tool) == reference.digest else { throw WorkflowIssue("工具内容与引用不一致。") }
            let draft = WorkflowToolEditing.editableCopy(of: tool)
            undoStack.append(graphs); redoStack = []; graphs.append(draft); selectedGraphID = draft.id; selectedNodeID = draft.nodes.first?.id
        } catch { errorMessage = error.localizedDescription }
    }
    public func saveGraphAsTool(name: String) {
        guard !closed, !closing, !isRunning, readOnlyReason == nil, let graph else { return }
        do {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf8.count <= 256, !tools.contains(where: { $0.name == title }), graph.interface?.outputs.isEmpty == false else { throw WorkflowIssue("请填写唯一名称，并在公开接口中指定输出。") }
            let tool = WorkflowToolDefinition(name: title, graph: graph)
            _ = try WorkflowPlanCompiler(registry: registry).compile(graph, tools: tools + [tool])
            tools.append(tool); progressMessage = "工具已加入项目工具箱；保存项目后可重开。"
        } catch { errorMessage = error.localizedDescription }
    }
    public func addBlankGraph(name: String = "新流程") {
        guard canEditCanvas else { return }
        let next = WorkflowGraph(name: name)
        undoStack.append(graphs); redoStack = []; graphs.append(next)
        selectedGraphID = next.id; selectedNodeID = nil
    }
    public func addNode(operationID: String, modelID: String? = nil, x: Double? = nil, y: Double? = nil) {
        guard canEditCanvas else { return }
        guard let op = registry.operation(operationID) else { errorMessage = "未知操作。"; return }
        if let modelID, !modelChoices.contains(where: { $0.id == modelID && $0.kind == op.definition.modelKind }) {
            errorMessage = "此模型没有登记到当前项目；请选择可用模型。"; return
        }
        guard x?.isFinite != false, y?.isFinite != false else { return }
        let createdGraph = graph == nil
        if createdGraph { addBlankGraph() }
        var node = op.definition.makeNode()
        if operationID == "d.model.language" { node.dataConfiguration = .init(schema: .text) }
        if let modelID { node.parameters["modelID"] = .text(modelID) }
        edit { graph in
            graph.nodes.append(node)
            graph.layout.append(.init(nodeID: node.id,
                x: x ?? (80 + Double(graph.nodes.count % 5) * 250),
                y: y ?? (100 + Double(graph.nodes.count / 5) * 210)))
        }
        if graph?.nodes.contains(where: { $0.id == node.id }) == true {
            // New graph plus its first node is one user insertion, not two undo steps.
            if createdGraph { _ = undoStack.popLast() }
            selectedNodeID = node.id
        }
    }

    /// Copy explicit settings and input snapshots; no runner is invoked by this command.
    public func insertQuickSettings(_ draft: QuickDraft, target: WorkflowCanvasInsertionTarget) async throws {
        guard isCurrent(target) else { throw WorkflowIssue("目标流程已改变，未添加到其他流程。") }
        try registry.validate(draft.node)
        var model = draft.node; model.id = UUID()
        var inputs: [(WorkflowNode, String)] = []
        for (port, value) in draft.inputs.sorted(by: { $0.key < $1.key }) {
            guard let datum = value.datum, let definition = registry.operation("d.value.input")?.definition else {
                throw WorkflowIssue("此输入必须先选择单项结果，不能隐式转换。")
            }
            var node = definition.makeNode(); node.title = port
            node.dataConfiguration = .init(value: datum)
            inputs.append((node, port))
        }
        edit { graph in
            graph.nodes.append(model)
            graph.layout.append(.init(nodeID: model.id, x: 400, y: 100))
            for (index, input) in inputs.enumerated() {
                graph.nodes.append(input.0)
                graph.layout.append(.init(nodeID: input.0.id, x: 60, y: 100 + Double(index) * 180))
                graph.connections.append(.init(sourceNode: input.0.id, targetNode: model.id, targetPort: input.1))
            }
        }
        selectedNodeID = model.id
        try await persist(); await onChange()
    }

    public func insertQuickResult(_ reference: WorkflowAssetReference, target: WorkflowCanvasInsertionTarget, x: Double = 80, y: Double = 100) async throws {
        guard isCurrent(target), let definition = registry.operation("d.asset.reference")?.definition else { throw WorkflowIssue("目标流程已改变。") }
        _ = try await services.store.workflowData(reference)
        guard isCurrent(target) else { throw WorkflowIssue("读取期间流程已改变。") }
        var node = definition.makeNode(); node.assetReference = reference
        edit { $0.nodes.append(node); $0.layout.append(.init(nodeID: node.id, x: x, y: y)) }
        guard graph?.nodes.contains(where: { $0.id == node.id }) == true else { throw WorkflowIssue("没有插入结果节点。") }
        selectedNodeID = node.id
        try await persist(); await onChange()
    }

    /// A structured published result is a frozen value input, not a generator or hidden execution.
    public func insertQuickValue(_ value: WorkflowDatum, target: WorkflowCanvasInsertionTarget) async throws {
        guard isCurrent(target), let definition = registry.operation("d.value.input")?.definition else { throw WorkflowIssue("目标流程已改变。") }
        try value.validate()
        for reference in value.assetReferences { _ = try await services.store.workflowData(reference) }
        guard isCurrent(target) else { throw WorkflowIssue("读取期间流程已改变。") }
        var node = definition.makeNode(); node.dataConfiguration = .init(value: value)
        edit { $0.nodes.append(node); $0.layout.append(.init(nodeID: node.id, x: 80, y: 100)) }
        guard graph?.nodes.contains(where: { $0.id == node.id }) == true else { throw WorkflowIssue("没有插入结果节点。") }
        selectedNodeID = node.id
        try await persist(); await onChange()
    }

    public func canvasInsertionTarget() -> WorkflowCanvasInsertionTarget? {
        guard canEditCanvas, let projectID, let rootGraph, let graph else { return nil }
        return .init(projectID: projectID, rootID: rootGraph.id, revision: rootGraph.revision, bodyID: graph.id, path: bodyPath)
    }
    public func isCurrent(_ target: WorkflowCanvasInsertionTarget) -> Bool {
        canEditCanvas && projectID == target.projectID && rootGraph?.id == target.rootID &&
        rootGraph?.revision == target.revision && graph?.id == target.bodyID && bodyPath == target.path
    }
    /// The UI captures the insertion scope synchronously before starting its Task.
    public func addAssetNode(projectID expectedProject: UUID, assetID: UUID, x: Double, y: Double,
                             target: WorkflowCanvasInsertionTarget) async {
        guard expectedProject == target.projectID, isCurrent(target),
              availableAssets.contains(where: { $0.id == assetID }), x.isFinite, y.isFinite,
              let definition = registry.operation("d.asset.reference")?.definition else { return }
        do {
            let ref = try await services.store.pinWorkflowAsset(assetID)
            guard isCurrent(target) else { throw WorkflowIssue("拖入期间流程已改变；资产保留，未添加到其他流程。") }
            var node = definition.makeNode(); node.assetReference = ref
            node.title = availableAssets.first(where: { $0.id == assetID })?.name ?? node.title
            edit { $0.nodes.append(node); $0.layout.append(.init(nodeID: node.id, x: x, y: y)) }
            guard graph?.nodes.contains(where: { $0.id == node.id }) == true else { return }
            selectedNodeID = node.id
            try await persist(); await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    public func bindLibraryAsset(projectID expectedProject: UUID, assetID: UUID, target: WorkflowAssetBindingTarget) async {
        guard canEditCanvas, projectID == expectedProject, isCurrent(target),
              availableAssets.contains(where: { $0.id == assetID }) else { return }
        do {
            let ref = try await services.store.pinWorkflowAsset(assetID)
            guard canEditCanvas, projectID == expectedProject, isCurrent(target) else {
                throw WorkflowIssue("资产输入已改变；素材未绑定到其他节点。")
            }
            attach(ref, nodeID: target.node.id); try await persist(); await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    /// An explicit import publishes a copy in this project's existing Store, without executing a node.
    public func importLibraryFile(_ url: URL) async {
        guard canEditCanvas else { return }
        do {
            _ = try await services.store.importWorkflowMediaFile(at: url)
            await refreshAssets(); await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    public func setAssetTags(id: UUID, tags: [String]) async throws {
        guard canEditCanvas, availableAssets.contains(where: { $0.id == id }) else {
            throw WorkflowIssue("当前不能编辑此资产标签。")
        }
        _ = try await services.store.updateAsset(id: id, tags: tags)
        await refreshAssets(); await onChange()
    }
    public func deleteSelected() {
        guard let id = selectedNodeID, let target = canvasInsertionTarget() else { return }
        _ = deleteNode(id: id, target: target)
    }
    /// The card owns an explicit identity; selection may belong to another card.
    @discardableResult
    public func deleteNode(id: UUID, target: WorkflowCanvasInsertionTarget) -> Bool {
        guard isCurrent(target), graph?.nodes.contains(where: { $0.id == id }) == true else { return false }
        edit { g in g.nodes.removeAll { $0.id == id }; g.connections.removeAll { $0.sourceNode == id || $0.targetNode == id }; g.layout.removeAll { $0.nodeID == id } }
        guard graph?.nodes.contains(where: { $0.id == id }) == false else { return false }
        if selectedNodeID == id { selectedNodeID = nil }
        selectedNodeIDs.remove(id)
        return true
    }
    public func copySelected() {
        guard var node = selectedNode else { return }; node.id = UUID(); node.title += " 副本"
        edit { g in g.nodes.append(node); g.layout.append(.init(nodeID: node.id, x: 100, y: 100)) }; selectedNodeID = node.id
    }
    public func moveNode(id: UUID, x: Double, y: Double) {
        guard canEditCanvas, x.isFinite, y.isFinite else { return }
        edit({ g in
            if let i = g.layout.firstIndex(where: { $0.nodeID == id }) { g.layout[i].x = x; g.layout[i].y = y }
            else { g.layout.append(.init(nodeID: id, x: x, y: y)) }
        }, changesConfiguration: false)
    }
    public func modelSelectionTarget() -> WorkflowModelSelectionTarget? {
        guard !isRunning, !closed, !closing, let graph, let node = selectedNode,
              let kind = registry.operation(node.operationID)?.definition.modelKind else { return nil }
        return .init(graphID: graph.id, nodeID: node.id, operationID: node.operationID, kind: kind,
                     previousIdentity: node.parameters["modelID"]?.string ?? "")
    }
    public func isCurrent(_ target: WorkflowModelSelectionTarget) -> Bool {
        guard !closed, !closing, !isRunning, graph?.id == target.graphID,
              let node = graph?.nodes.first(where: { $0.id == target.nodeID }),
              node.operationID == target.operationID,
              registry.operation(node.operationID)?.definition.modelKind == target.kind,
              node.parameters["modelID"]?.string == target.previousIdentity else { return false }
        return true
    }
    public func bindModel(_ identity: String, to target: WorkflowModelSelectionTarget) {
        guard isCurrent(target) else { errorMessage = "目标节点已改变，模型未绑定到其他节点。"; return }
        setParameter(nodeID: target.nodeID, key: "modelID", value: .text(identity))
    }

    public func setParameter(nodeID: UUID, key: String, value: WorkflowScalar) {
        edit { g in guard let i = g.nodes.firstIndex(where: { $0.id == nodeID }) else { return }; g.nodes[i].parameters[key] = value }
    }
    public func setDataConfiguration(nodeID: UUID, value: WorkflowDataConfiguration?) {
        edit { graph in
            guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            try value?.schema?.validateDefinition(); try value?.value?.validate()
            graph.nodes[index].dataConfiguration = value
        }
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
    public func addLanguageExample(_ choice: WorkflowLanguageExample) {
        guard !closed, !closing, readOnlyReason == nil else { return }
        do {
            let bundle = try WorkflowLanguageExamples.make(choice)
            // Every addition is an independent editable copy. Tool identity and
            // digest remain fixed for existing instances; never overwrite them.
            let combined = tools + bundle.tools
            _ = try WorkflowPlanCompiler(registry: registry).compile(bundle.graph, tools: combined)
            undoStack.append(graphs); redoStack = []
            tools = combined; graphs.append(bundle.graph); selectedGraphID = bundle.graph.id
            selectedNodeID = bundle.graph.nodes.first?.id; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    public func attach(_ reference: WorkflowAssetReference, nodeID: UUID) {
        edit { g in guard let i = g.nodes.firstIndex(where: { $0.id == nodeID }), registry.operation(g.nodes[i].operationID)?.definition.interaction == .assetInput else { throw WorkflowIssue("请选择文件／资产输入节点。") }; g.nodes[i].assetReference = reference }
    }
    public func importFile(_ url: URL, nodeID: UUID) async {
        guard !closed, !closing, readOnlyReason == nil else { return }
        guard let target = assetBindingTarget(nodeID: nodeID) else { return }
        do {
            let asset = try await services.store.importWorkflowMediaFile(at: url)
            guard isCurrent(target) else { throw WorkflowIssue("导入期间流程或输入已改变；资产已保存，未绑定到另一位置。") }
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
        if (try? registry.signature(step.node.id, in: graph, tools: tools)) != step.signature { return true }
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
        guard let signature = try? registry.signature(nodeID, in: graph, tools: tools) else { return nil }
        return runs.reversed().filter { $0.graph.id == graph.id }.flatMap { $0.steps.reversed() }.first {
            $0.node.id == nodeID && $0.signature == signature && [.completed, .partial].contains($0.status) && (inputs == nil || $0.inputs == inputs)
        }
    }
    public func plan(target: UUID, only: Bool) throws -> [String] {
        guard bodyPath.isEmpty else { throw WorkflowIssue("局部流程是编辑模板；请返回外层运行，或在运行详情选择具体调用。") }
        guard let graph else { throw WorkflowIssue("请先创建流程。") }
        let ids = try WorkflowPlanCompiler(registry: registry).compile(graph, tools: tools, target: target, only: only).steps.map(\.id)
        return try ids.map { id in
            guard let node = graph.nodes.first(where: { $0.id == id }) else { throw WorkflowIssue("节点已不存在。") }
            if only {
                let old = graph.connections.filter { $0.targetNode == id }.contains { edge in
                    reusable(nodeID: edge.sourceNode, graph: graph, inputs: nil).map(isStale) ?? true
                }
                return "重新执行 \(node.title)；使用已就绪的上游资产版本，不重算上游。" + (old ? " 注意：包含旧输入结果。" : "")
            }
            if let step = reusable(nodeID: id, graph: graph, inputs: nil) { return "检查后复用 \(node.title)（\(step.id.uuidString.prefix(8))）；若输入版本不同则重新执行。" }
            if registry.operation(node.operationID).map { [.textReview, .candidateReview].contains($0.definition.interaction) } == true { return "等待人工确认：\(node.title)；不会自动启动后续生成。" }
            return "执行：\(node.title)"
        }
    }

    private func persist() async throws {
        guard !closed, readOnlyReason == nil else { throw WorkflowIssue(readOnlyReason ?? "项目已关闭。") }
        // Chain the complete transaction, including its read, so actor reentrancy cannot lose another save.
        let preceding = writeTail, store = services.store, capturedGraphs = graphs, capturedRuns = runs, capturedTools = tools
        let task = Task { @MainActor in
            if let preceding { _ = try? await preceding.value }
            let state = try await store.workflowState()
            guard let archive = state.archive else { throw WorkflowIssue(state.readOnlyReason ?? "流程只读。") }
            try self.beforeHistorySave()
            _ = try await store.saveWorkflow(graphs: capturedGraphs, runs: capturedRuns, expectedRevision: archive.revision, tools: capturedTools.isEmpty ? nil : capturedTools)
        }
        writeTail = task; isSaving = true
        do { try await task.value; persistenceFailed = false; isSaving = false; await refreshAssets() }
        catch { persistenceFailed = true; isSaving = false; throw error }
    }
    public func save() async {
        do { try await persist(); progressMessage = "流程、人工决定与运行历史已保存。"; await onChange() }
        catch { errorMessage = error.localizedDescription }
    }
    public func saveExplicitEdits() async throws { try await persist(); await onChange() }
    public func run(target: UUID, only: Bool) async {
        guard !externalOperationBusy() else { errorMessage = "请先结束录音或恢复保存，再运行流程。"; return }
        guard bodyPath.isEmpty else { errorMessage = "请返回外层运行；不能把局部模板当作独立调用。"; return }
        guard !closed, !closing, !isRunning, readOnlyReason == nil, let original = graph else { return }
        guard !hasPendingSaves else { errorMessage = "请先恢复保存，避免重复计算。"; return }
        isRunning = true; cancelled = false; errorMessage = nil
        defer { isRunning = false; activeRunID = nil; activeExecutor = nil }
        var failure: (any Error)?
        do {
            let frozen = services.freezeModels(in: original)
            let defaults = services.capturedModelDefaults()
            let compiled = try WorkflowPlanCompiler(registry: registry).compile(frozen, tools: tools, target: target, only: only)
            let plan = try WorkflowPlanBinding.freeze(compiled, defaults: defaults, registry: registry)
            if let i = graphs.firstIndex(where: { $0.id == frozen.id }), graphs[i].revision == original.revision { graphs[i] = frozen }
            var arguments: [String: WorkflowDatum] = [:]
            for field in plan.interface.inputs {
                if let input = frozen.nodes.first(where: { $0.operationID == "d.value.input" && $0.parameters["publicName"]?.string == field.name }), let value = input.dataConfiguration?.value {
                    try value.validate(as: field.type); arguments[field.name] = value
                } else if field.required { throw WorkflowIssue("公开输入尚未填写：\(field.name)。") }
            }
            var checkpoint = WorkflowPlanCheckpoint(plan: plan, arguments: arguments)
            checkpoint.modelDefaults = defaults
            if only {
                guard let node = frozen.nodes.first(where: { $0.id == target }) else { throw WorkflowIssue("节点不存在。") }
                checkpoint.externalInputs[target] = try inputs(for: node, run: .init(graph: frozen, targetNodeID: target))
                var requested = WorkflowStepRun(node: plan.steps[0].node, signature: plan.steps[0].sourceSignature ?? "")
                requested.repeatRequested = true
                checkpoint.records = [.init(address: .init(runID: checkpoint.runID, path: [.node(target)]), step: requested)]
            }
            var run = WorkflowRun(id: checkpoint.runID, graph: frozen, targetNodeID: target, status: .running)
            run.planCheckpoint = checkpoint
            run.steps = checkpoint.records.filter { $0.address.path.count == 1 }.map(\.step)
            runs.append(run); activeRunID = run.id
            try await persist()
            try await executePlan(runID: run.id, force: only ? target : nil)
        } catch { failure = error }
        await finishExecution(failure)
    }

    public func scopeBoundaries(_ selection: WorkflowGraphSelection) throws -> [WorkflowScopeBoundary] {
        guard bodyPath.isEmpty, let graph = rootGraph else { throw WorkflowIssue("请返回外层选择运行范围；模板不能冒充实际调用。") }
        return try WorkflowScopePlanner.select(graph: graph, selection: selection, tools: tools, registry: registry).boundaries
    }

    public func history(for nodeID: UUID) -> [WorkflowRun] {
        return runs.filter { run in
            belongsToSelectedWorkflow(run) && (run.graph.nodes.contains { $0.id == nodeID } ||
                run.planCheckpoint?.records.contains { $0.step.node.id == nodeID } == true)
        }
    }

    private func belongsToSelectedWorkflow(_ run: WorkflowRun) -> Bool {
        var current = run, seen = Set<UUID>()
        while seen.insert(current.id).inserted {
            if current.graph.id == selectedGraphID { return true }
            guard let id = current.scope?.originCall?.address.runID,
                  let parent = runs.first(where: { $0.id == id }) else { return false }
            current = parent
        }
        return false
    }

    public func canRerunCall(_ call: WorkflowPlanCallRecord) -> Bool {
        // Presentation hint only. The action independently validates full provenance.
        call.step.node.control == nil && call.step.inputsBound == true &&
            [.completed, .partial, .failed, .cancelled].contains(call.step.status)
    }

    /// Choices are explicit old output versions; never an implicit 'latest' binding.
    public func historicalCalls(for boundary: WorkflowScopeBoundary) -> [WorkflowPlanCallRecord] {
        runs.reversed().filter { $0.graph.id == rootGraph?.id }.flatMap { run in
            (run.planCheckpoint?.records ?? []).filter {
                $0.address.path.count == 1 && $0.step.node.id == boundary.sourceNodeID &&
                [.completed, .partial].contains($0.step.status) && $0.step.outputs[boundary.sourcePort] != nil
            }
        }
    }

    public func runScoped(_ selection: WorkflowGraphSelection, pins: [WorkflowHistoricalInput],
                          expectedGraphID: UUID, expectedRevision: UUID) async {
        guard !externalOperationBusy(), !closed, !closing, !isRunning, readOnlyReason == nil,
              !hasPendingSaves, bodyPath.isEmpty, let original = rootGraph,
              original.id == expectedGraphID, original.revision == expectedRevision else {
            errorMessage = "运行范围或原图已改变，或当前有未完成操作；请重新确认。"; return
        }
        isRunning = true; cancelled = false; errorMessage = nil
        defer { isRunning = false; activeRunID = nil; activeExecutor = nil }
        var failure: (any Error)?
        do {
            let frozen = services.freezeModels(in: original), defaults = services.capturedModelDefaults()
            let plan = try WorkflowScopePlanner.rebuild(graph: frozen, selection: selection, modelDefaults: defaults,
                tools: tools, registry: registry)
            var checkpoint = WorkflowPlanCheckpoint(plan: plan, arguments: try publicArguments(plan, graph: frozen))
            checkpoint.modelDefaults = defaults
            let sourceIDs = Set(pins.map { $0.sourceCall.address.runID })
            let sources = try runs.filter { sourceIDs.contains($0.id) }.map {
                try WorkflowArchiveInspection.scopeSource($0, tools: tools, registry: registry)
            }
            checkpoint.externalInputs = try WorkflowScopePlanner.resolveHistoricalInputs(pins,
                destination: .init(graph: frozen, selection: selection, checkpoint: checkpoint),
                sources: sources, tools: tools, registry: registry)
            let target: UUID, recompute: Bool
            switch selection {
            case .through(let id): target = id; recompute = false
            case .only(let id), .downstream(let id, _): target = id; recompute = true
            }
            var run = WorkflowRun(id: checkpoint.runID, graph: frozen, targetNodeID: target, status: .running)
            run.scope = .init(selection: selection, historicalInputs: pins, recomputeSelected: recompute)
            run.planCheckpoint = checkpoint
            try WorkflowArchiveInspection.validateScopeHistory(runs + [run], tools: tools, registry: registry)
            if let i = graphs.firstIndex(where: { $0.id == frozen.id }), graphs[i].revision == original.revision { graphs[i] = frozen }
            runs.append(run); activeRunID = run.id
            try await persist(); try await executePlan(runID: run.id)
        } catch { failure = error }
        await finishExecution(failure)
    }

    /// A selected concrete call becomes a new run on its frozen local graph.
    /// It does not mutate or resume the original Map item, Loop iteration or waiting task.
    public func rerunCall(_ reference: WorkflowCallReference) async {
        guard !externalOperationBusy(), !closed, !closing, !isRunning, readOnlyReason == nil, !hasPendingSaves else { return }
        isRunning = true; cancelled = false; errorMessage = nil
        defer { isRunning = false; activeRunID = nil; activeExecutor = nil }
        var failure: (any Error)?
        do {
            guard let old = runs.first(where: { $0.id == reference.address.runID }) else { throw WorkflowIssue("原调用记录不存在。") }
            try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
            let source = try WorkflowArchiveInspection.scopeSource(old, tools: tools, registry: registry)
            let resolved = try WorkflowScopePlanner.resolveCall(reference, source: source, tools: tools, registry: registry)
            guard let node = resolved.plan.steps.first?.node else { throw WorkflowIssue("具体调用为空。") }
            var checkpoint = WorkflowPlanCheckpoint(plan: resolved.plan, arguments: resolved.arguments)
            checkpoint.modelDefaults = resolved.modelDefaults; checkpoint.externalInputs = resolved.externalInputs
            var run = WorkflowRun(id: checkpoint.runID, graph: resolved.graph, targetNodeID: node.id, status: .running)
            run.scope = .init(selection: .only(node.id), originCall: reference, recomputeSelected: true)
            run.planCheckpoint = checkpoint
            try WorkflowArchiveInspection.validateScopeHistory(runs + [run], tools: tools, registry: registry)
            runs.append(run); activeRunID = run.id
            try await persist(); try await executePlan(runID: run.id)
        } catch { failure = error }
        await finishExecution(failure)
    }

    private func publicArguments(_ plan: WorkflowPlan, graph: WorkflowGraph) throws -> [String: WorkflowDatum] {
        var result: [String: WorkflowDatum] = [:]
        for field in plan.interface.inputs {
            if let input = graph.nodes.first(where: { $0.operationID == "d.value.input" && $0.parameters["publicName"]?.string == field.name }),
               let value = input.dataConfiguration?.value {
                try value.validate(as: field.type); result[field.name] = value
            } else if field.required { throw WorkflowIssue("公开输入尚未填写：\(field.name)。") }
        }
        return result
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
    private func capture(_ checkpoint: WorkflowPlanCheckpoint, runIndex: Int) {
        runs[runIndex].planCheckpoint = checkpoint
        // Top-level compatibility projection; nested records remain in the checkpoint.
        runs[runIndex].steps = checkpoint.records.filter { $0.address.path.count == 1 }.map(\.step)
        switch checkpoint.state {
        case .ready: runs[runIndex].status = .queued
        case .running: runs[runIndex].status = cancelled ? .cancelling : .running
        case .paused, .waiting: runs[runIndex].status = .waiting
        case .completed: runs[runIndex].status = .completed
        case .failed: runs[runIndex].status = .failed
        case .cancelled: runs[runIndex].status = checkpoint.records.contains { $0.step.status == .rejected } ? .rejected : .cancelled
        case .saving: runs[runIndex].status = .saving
        case .interrupted: runs[runIndex].status = .interrupted
        }
    }
    private func executePlan(runID: UUID, force: UUID? = nil) async throws {
        guard let ri = runs.firstIndex(where: { $0.id == runID }), let checkpoint = runs[ri].planCheckpoint else { throw WorkflowIssue("结构化恢复点不存在。") }
        if cancelled {
            var stopped = checkpoint; stopped.state = .cancelled
            for i in stopped.records.indices where [.queued, .running].contains(stopped.records[i].step.status) { stopped.records[i].step.status = .cancelled }
            capture(stopped, runIndex: ri); try await persist(); return
        }
        try services.beginPlan()
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { [unowned self] context in
            self.progressMessage = context.node.title
            let top = context.address?.path.count == 1
            let record = self.activeExecutor?.checkpoint?.records.first { $0.step.id == context.stepID }
            if top, self.runs[ri].scope?.recomputeSelected != true, force != context.node.id, record?.step.repeatRequested != true, record?.step.outputs.isEmpty == true, !services.hasPendingSaves,
               let cached = self.reusable(nodeID: context.node.id, graph: self.runs[ri].graph, inputs: context.inputs), cached.id != context.stepID {
                return .outputs(cached.outputs)
            }
            return try await self.services.executeCall(context)
        }, save: { [unowned self] value in
            self.capture(value, runIndex: ri)
            try await self.persist()
        })
        activeExecutor = executor
        do {
            let result = try await executor.execute(checkpoint)
            capture(result, runIndex: ri)
            progressMessage = result.state == .waiting ? "等待明确决定，后续尚未执行。" : result.state == .paused ? "已在安全边界暂停，资源已释放。" : "此次运行已保存。"
        } catch {
            if let latest = executor.checkpoint { capture(latest, runIndex: ri) }
            throw error
        }
    }
    /// Convert an old run only on explicit resume. No new Call is added or executed here.
    private func checkpointForResume(_ index: Int) throws -> WorkflowPlanCheckpoint {
        if let checkpoint = runs[index].planCheckpoint { return try WorkflowPlanExecutor.preparingRetry(checkpoint) }
        let run = runs[index]
        let full = try WorkflowPlanCompiler(registry: registry).compile(run.graph, tools: tools, target: run.targetNodeID,
            only: run.steps.count == 1 && run.steps.first?.node.id == run.targetNodeID)
        var checkpoint = WorkflowPlanCheckpoint(runID: run.id, plan: full)
        checkpoint.records = run.steps.map { .init(address: .init(runID: run.id, path: [.node($0.node.id)]), step: $0) }
        if full.steps.count == 1, let step = run.steps.first { checkpoint.externalInputs[step.node.id] = step.inputs }
        checkpoint.state = run.status == .saving ? .saving : .ready
        return try WorkflowPlanExecutor.preparingRetry(checkpoint)
    }
    public func pause() { activeExecutor?.requestPause(); progressMessage = "等待当前步骤结束并释放资源后暂停。" }

    /// A cancellation is terminal only after the operation drained and its model leases were released.
    private func finishExecution(_ failure: (any Error)?) async {
        await services.finish()
        if let failure, !(failure is CancellationError) {
            errorMessage = failure.localizedDescription
            progressMessage = "运行未完成，请查看错误；已完成的产物仍保留。"
        }
        if hasPendingSaves {
            progressMessage = "运行已停止，但保存尚未完成；请恢复保存。"
            if errorMessage == nil { errorMessage = "运行记录或结果尚未保存，请恢复保存。" }
        } else if failure is CancellationError || (failure == nil && runs.first(where: { $0.id == activeRunID })?.status == .cancelled) {
            errorMessage = nil
            progressMessage = "已取消，计算已停止并释放资源。"
        }
        await onChange()
    }

    public func cancel() async {
        guard isRunning else { return }
        if let id = activeRunID, let i = runs.firstIndex(where: { $0.id == id }) {
            guard [.running, .queued, .cancelling].contains(runs[i].status) else { return }
            runs[i].status = .cancelling
        }
        cancelled = true
        progressMessage = "正在取消，等待计算停止并释放资源。"
        activeExecutor?.requestStop()
        await services.cancel()
    }
    public func editHumanDraft(stepID: UUID, value: WorkflowDatum?) {
        guard !closed, !closing, readOnlyReason == nil, !isRunning,
              let ri = runs.firstIndex(where: { $0.planCheckpoint?.records.contains { $0.step.id == stepID } == true }),
              let ci = runs[ri].planCheckpoint?.records.firstIndex(where: { $0.step.id == stepID }),
              runs[ri].planCheckpoint?.records[ci].step.status == .waiting,
              runs[ri].planCheckpoint?.records[ci].step.humanTask?.decision == nil else { return }
        do {
            try value?.validate()
            runs[ri].planCheckpoint?.records[ci].step.humanTask?.draft = value
            if let cp = runs[ri].planCheckpoint { capture(cp, runIndex: ri) }
        } catch { errorMessage = error.localizedDescription }
    }
    public func decideHuman(stepID: UUID, value: WorkflowDatum?, reject: Bool = false, expectedTask: WorkflowHumanTask) async {
        guard !closed, !closing, readOnlyReason == nil, !isRunning else { return }
        isRunning = true; defer { isRunning = false }
        do {
            guard let ri = runs.firstIndex(where: { $0.planCheckpoint?.records.contains { $0.step.id == stepID } == true }),
                  var cp = runs[ri].planCheckpoint,
                  let ci = cp.records.firstIndex(where: { $0.step.id == stepID }),
                  var human = cp.records[ci].step.humanTask, human.id == stepID, human == expectedTask,
                  cp.records[ci].step.status == .waiting, human.decision == nil, !human.rejected,
                  waitingSnapshotIsCurrent(runs[ri]) else {
                throw WorkflowIssue("等待点或原图已改变；未应用到其他调用。")
            }
            if !reject {
                guard let value else { throw WorkflowIssue("请明确提供人工结果。") }
                try value.validate(as: human.resultSchema)
                for ref in value.assetReferences { try await services.verifyAsset(ref) }
            }
            guard waitingSnapshotIsCurrent(runs[ri]) else { throw WorkflowIssue("确认期间流程已改变。") }
            try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
            human.decision = reject ? nil : value; human.rejected = reject
            cp.records[ci].step.humanTask = human
            let executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in throw WorkflowIssue("提交人工结果不执行下游。") }, save: { [unowned self] latest in
                self.capture(latest, runIndex: ri); try await self.persist()
            })
            do { let settled = try await executor.settleWaiting(cp, stepID: stepID); capture(settled, runIndex: ri) }
            catch { if let latest = executor.checkpoint { capture(latest, runIndex: ri) }; throw error }
            progressMessage = reject ? "已拒绝；未执行下游。" : "结果已保存；继续原运行才执行下游。"
        } catch { errorMessage = error.localizedDescription }
    }
    public func callRecords(runID: UUID) -> [WorkflowPlanCallRecord] {
        runs.first { $0.id == runID }?.planCheckpoint?.records ?? []
    }
    private func waitingSnapshotIsCurrent(_ run: WorkflowRun) -> Bool {
        if run.scope?.originCall != nil { return belongsToSelectedWorkflow(run) }
        return rootGraph?.id == run.graph.id && rootGraph?.revision == run.graph.revision
    }
    private func canDecide(_ step: WorkflowStepRun, in run: WorkflowRun) -> Bool {
        if run.scope?.originCall != nil || !run.steps.contains(where: { $0.id == step.id }) { return waitingSnapshotIsCurrent(run) }
        if let scope = run.scope, !scope.historicalInputs.isEmpty {
            // An explicit historical boundary is not the latest upstream value.
            // Keep the selected graph frozen and validate the actual source chain,
            // both before publishing and again after the publication suspension.
            guard rootGraph == run.graph else { return false }
            do {
                try WorkflowArchiveInspection.validateRun(run, tools: tools, registry: registry)
                try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
                return true
            } catch { return false }
        }
        return belongsToSelectedWorkflow(run) && !isStale(step)
    }
    public func decide(stepID: UUID, accept: Bool, text: String?, candidateID: UUID?, acceptPartial: Bool) async {
        guard !closed, !closing, !isRunning, readOnlyReason == nil else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            guard let ri = runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } || $0.planCheckpoint?.records.contains { $0.id == stepID } == true }),
                  let step = runs[ri].planCheckpoint?.records.first(where: { $0.id == stepID })?.step ?? runs[ri].steps.first(where: { $0.id == stepID }) else { throw WorkflowIssue("等待点不存在。") }
            if step.decision != nil { return } // Idempotent replay never creates a second derived asset.
            guard step.status == .waiting, canDecide(step, in: runs[ri]) else { throw WorkflowIssue("此等待点已经过期；原输入或连接已改变，请运行新的快照。") }
            var output: WorkflowAssetReference?
            if accept {
                if registry.operation(step.node.operationID)?.definition.interaction == .textReview {
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
            guard canDecide(step, in: runs[ri]) else {
                throw WorkflowIssue("确认期间原输入已改变；派生资产保留，但未采用到新的流程。")
            }
            try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
            // Do not resume downstream here. Confirmation and expensive continuation are separate user actions.
            let decision = WorkflowDecision(waitingStepID: stepID, accepted: accept, selectedCandidateID: candidateID, output: output)
            if var cp = runs[ri].planCheckpoint, let ci = cp.records.firstIndex(where: { $0.step.id == stepID }) {
                cp.records[ci].step.decision = decision
                let executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in throw WorkflowIssue("提交决定不能运行节点。") }, save: { [unowned self] value in
                    self.capture(value, runIndex: ri); try await self.persist()
                })
                do { let settled = try await executor.settleWaiting(cp, stepID: stepID); capture(settled, runIndex: ri) }
                catch { if let latest = executor.checkpoint { capture(latest, runIndex: ri) }; throw error }
            } else {
                // Historical checkpoint-free wait: retain its established decision format.
                guard let si = runs[ri].steps.firstIndex(where: { $0.id == stepID }) else { throw WorkflowIssue("等待点不存在。") }
                runs[ri].steps[si].decision = decision
                runs[ri].steps[si].outputs = output.map { ["output": .asset($0)] } ?? [:]
                runs[ri].steps[si].status = accept ? .completed : .rejected
                runs[ri].status = accept ? .waiting : .rejected
                try await persist()
            }
            progressMessage = accept ? "决定已保存。明确点击继续运行才会执行下游。" : "已拒绝；没有发布空输出。"
            await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    public func resume(runID: UUID) async {
        guard !externalOperationBusy() else { errorMessage = "请先结束录音或恢复保存，再恢复流程。"; return }
        guard !closed, !closing, !isRunning, readOnlyReason == nil, let i = runs.firstIndex(where: { $0.id == runID }) else { return }
        if runs[i].scope?.originCall != nil {
            guard belongsToSelectedWorkflow(runs[i]) else { errorMessage = "请在原调用所属流程中恢复。"; return }
        } else {
            guard runs[i].graph.id == selectedGraphID, let current = rootGraph,
                  (runs[i].planCheckpoint?.plan.steps.map(\.node) ?? runs[i].steps.map(\.node)).allSatisfy({ (try? registry.signature($0.id, in: current, tools: tools)) == (try? registry.signature($0.id, in: runs[i].graph, tools: tools)) }) else {
                errorMessage = "当前流程已变化；旧运行保留，请运行新的快照。"; return
            }
        }
        guard runs[i].status != .rejected && runs[i].status != .completed else { return }
        isRunning = true; cancelled = false; errorMessage = nil
        defer { isRunning = false; activeRunID = nil; activeExecutor = nil }
        var failure: (any Error)?
        do {
            try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
            if persistenceFailed { try await persist() }
            let resumedCheckpoint = try checkpointForResume(i)
            runs[i].planCheckpoint = resumedCheckpoint
            activeRunID = runID
            try await executePlan(runID: runID)
        } catch { failure = error }
        await finishExecution(failure)
    }
    public func retryFailedCandidates(stepID: UUID) async {
        guard !externalOperationBusy() else { errorMessage = "请先结束录音或恢复保存，再重试候选。"; return }
        guard !closed, !closing, !isRunning, readOnlyReason == nil,
              let ri = runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } }),
              let si = runs[ri].steps.firstIndex(where: { $0.id == stepID }),
              registry.operation(runs[ri].steps[si].node.operationID)?.definition.modelKind == .image else { return }
        let old = runs[ri].steps[si]
        guard !hasPendingSaves else { errorMessage = "先恢复保存并继续原运行，避免重复生成。"; return }
        guard !isStale(old), old.outputs["output"]?.candidates.contains(where: { $0.asset == nil }) == true else { return }
        isRunning = true; cancelled = false; errorMessage = nil
        defer { isRunning = false; activeRunID = nil; activeExecutor = nil }
        var failure: (any Error)?
        do {
            let frozen = runs[ri].graph

            var replacement = WorkflowStepRun(node: old.node, signature: old.signature, inputs: old.inputs)
            replacement.repeatRequested = true
            replacement.inputsBound = true
            replacement.outputs = old.outputs // Retry set survives save failure, cancellation and cold reopen.
            var retry = WorkflowRun(graph: frozen, targetNodeID: old.node.id, steps: [replacement], status: .running)
            let compiled = try WorkflowPlanCompiler(registry: registry).compile(frozen, tools: tools, target: old.node.id, only: true)
            var checkpoint = WorkflowPlanCheckpoint(runID: retry.id, plan: compiled)
            checkpoint.externalInputs[old.node.id] = old.inputs
            checkpoint.records = [.init(address: .init(runID: retry.id, path: [.node(old.node.id)]), step: replacement)]
            retry.planCheckpoint = checkpoint
            runs.append(retry); activeRunID = retry.id
            try await persist()
            try await executePlan(runID: retry.id, force: old.node.id)
            progressMessage = "失败项已重试；成功项保留。重新运行选择节点以查看新集合。"
        } catch { failure = error }
        await finishExecution(failure)
    }
}
