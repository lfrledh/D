import AppKit
import DWorkbench
import Foundation
import SwiftUI

enum WorkflowCanvasAssetIdentity {
    static func payload(_ item: WorkflowCanvasTransfer) -> (project: UUID, instance: UUID?, asset: UUID)? {
        switch item {
        case .asset(let project, let asset): return (project, nil, asset)
        case .assetInstance(let project, let instance, let asset): return (project, instance, asset)
        default: return nil
        }
    }

    static func acceptsOwnProject(projectID: UUID, instanceID: UUID?, assetID: UUID,
                                  currentProjectID: UUID?, currentInstanceID: UUID?,
                                  acceptsLegacyAsset: ((UUID, UUID) -> Bool)?) -> Bool {
        guard currentProjectID == projectID, let currentInstanceID else { return false }
        if let instanceID { return instanceID == currentInstanceID }
        return acceptsLegacyAsset?(projectID, assetID) ?? (currentInstanceID == projectID)
    }
}

@MainActor
func workflowText(
    _ store: UILanguageStore?,
    _ key: String,
    fallback: String,
    arguments: [String: String] = [:]
) -> String {
    store?.text(key, fallback: fallback, arguments: arguments)
        ?? LanguagePackCodec.render(fallback, arguments: arguments)
}

/// Native presentation for editable workflow graphs. Persistence and execution remain owned by
/// ``WorkflowController``; this view never reads files or starts inference directly.
@MainActor
public struct WorkflowCanvasView: View {
    private let controller: WorkflowController
    private let nodeTags: ModelNodeTagStore
    private let onTextModel: () -> Void
    private let onImageModel: () -> Void
    private let onAdditionalModel: (WorkflowModelKind) -> Void
    private let onImport: (UUID) -> Void
    private let onRecord: (UUID) -> Void
    private let onImportAsset: () -> Void
    private let onDropFile: (URL) -> Bool
    private let onQuickUse: ((WorkflowNode) -> Void)?
    private let libraryContent: ((WorkflowCanvasLibraryMode, CGPoint, @escaping () -> Void) -> AnyView)?
    private let onSharedAssetDrop: ((UUID, UUID?, UUID, CGPoint, WorkflowCanvasInsertionTarget) -> Bool)?
    private let acceptsLegacyAsset: ((UUID, UUID) -> Bool)?
    private let onDestination: () -> Void
    private let onPublishText: () -> Void
    private let onReturnText: (WorkflowAssetReference) -> Void
    private var nodeSizeObserver: ((UUID, CGSize) -> Void)?
    private var portCenterObserver: (([WorkflowPortIdentity: CGPoint]) -> Void)?
    private var viewportLockObserver: ((Bool) -> Void)?
    private var scrollObserver: ((WorkflowCanvasViewContext, WorkflowCanvasScrollObservation) -> Void)?

    // Read-only layout observation; never rewrites stored node positions.
    func observingNodeSizes(_ observer: @escaping (UUID, CGSize) -> Void) -> Self {
        var copy = self; copy.nodeSizeObserver = observer; return copy
    }

    func observingPortCenters(_ observer: @escaping ([WorkflowPortIdentity: CGPoint]) -> Void) -> Self {
        var copy = self; copy.portCenterObserver = observer; return copy
    }

    func observingViewportLock(_ observer: @escaping (Bool) -> Void) -> Self {
        var copy = self; copy.viewportLockObserver = observer; return copy
    }

    func observingScroll(_ observer: @escaping (WorkflowCanvasViewContext, WorkflowCanvasScrollObservation) -> Void) -> Self {
        var copy = self; copy.scrollObserver = observer; return copy
    }

    @Environment(\.dLanguageStore) private var languageStore

    @Environment(\.chatDisplayPreferences) private var displayPreferences
    @State private var narrowLibrary = false
    @State private var showLibrary = true
    @State private var libraryMode: WorkflowCanvasLibraryMode = .nodes
    @State private var showInspector = true
    @State private var zoom: CGFloat = 1
    @State private var canvasTool: WorkflowCanvasTool = .pointer
    @State private var canvasViewport: WorkflowCanvasViewportMeasurement?
    @State private var measuredCardSizes: [UUID: CGSize] = [:]
    @State private var navigationRequest: WorkflowCanvasNavigationRequest?
    @State private var viewportInteractionLocked = false
    @State private var viewStates = WorkflowCanvasViewStateStore()
    @State private var activeViewContext: WorkflowCanvasViewContext?
    @State private var actualVisibleRawCenter = CGPoint(x: 550, y: 426)
    @State private var canvasInsertionPoint = CGPoint(x: 170, y: 130)
    @State private var pendingConnection: WorkflowPendingConnection?
    @State private var selectedConnectionID: UUID?
    @State private var runPreview: WorkflowRunPreview?
    @State private var runTarget: WorkflowRunTarget?
    @State private var runOnly = false
    @State private var scopePresentation: WorkflowScopePresentation?
    @State private var resultNodeID: UUID?
    @State private var resultsOpened = false
    @State private var resultRunID: UUID?
    @State private var toolsPresented = false
    @State private var interfacePresented = false
    @State private var portLegendPresented = false

    public init(
        controller: WorkflowController,
        onTextModel: @escaping () -> Void,
        onImageModel: @escaping () -> Void,
        onImport: @escaping (UUID) -> Void,
        onDestination: @escaping () -> Void,
        onPublishText: @escaping () -> Void,
        onReturnText: @escaping (WorkflowAssetReference) -> Void,
        onAdditionalModel: @escaping (WorkflowModelKind) -> Void = { _ in },
        onRecord: @escaping (UUID) -> Void = { _ in },
        nodeTags: ModelNodeTagStore? = nil,
        onImportAsset: @escaping () -> Void = {},
        onDropFile: @escaping (URL) -> Bool = { _ in false },
        onQuickUse: ((WorkflowNode) -> Void)? = nil,
        libraryContent: ((WorkflowCanvasLibraryMode, CGPoint, @escaping () -> Void) -> AnyView)? = nil,
        onSharedAssetDrop: ((UUID, UUID?, UUID, CGPoint, WorkflowCanvasInsertionTarget) -> Bool)? = nil,
        acceptsLegacyAsset: ((UUID, UUID) -> Bool)? = nil
    ) {
        self.controller = controller
        self.nodeTags = nodeTags ?? ModelNodeTagStore()
        self.onTextModel = onTextModel
        self.onImageModel = onImageModel
        self.onAdditionalModel = onAdditionalModel
        self.onImport = onImport
        self.onRecord = onRecord
        self.onImportAsset = onImportAsset
        self.onDropFile = onDropFile
        self.onSharedAssetDrop = onSharedAssetDrop
        self.acceptsLegacyAsset = acceptsLegacyAsset
        self.onQuickUse = onQuickUse; self.libraryContent = libraryContent
        self.onDestination = onDestination
        self.onPublishText = onPublishText
        self.onReturnText = onReturnText
        _activeViewContext = State(initialValue: WorkflowCanvasViewContext(projectID: controller.projectID,
            rootGraphID: controller.rootGraph?.id,
            bodyPath: controller.bodyPath.map(WorkflowCanvasBodyLocation.init)))
    }

    public var body: some View {
        #if DEBUG
        let _ = WorkflowCanvasUpdateProbe.canvasBody?()
        #endif
        GeometryReader { viewport in
        VStack(spacing: 0) {
            toolbar(width: viewport.size.width).frame(width: viewport.size.width)
            GeometryReader { proxy in
                panels(height: proxy.size.height, width: proxy.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityIdentifier("workflow-canvas-workspace")
            }
        }
        .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .frame(minWidth: WorkflowCanvasLayoutPolicy.minimumVisibleWidth,
               minHeight: WorkflowCanvasLayoutPolicy.minimumVisibleHeight)
        .sheet(item: $runPreview) { preview in
            WorkflowRunPlanSheet(
                preview: preview,
                readOnly: isReadOnly,
                onCancel: { runPreview = nil },
                onRun: {
                    runPreview = nil
                    Task { @MainActor in
                        guard preview.isCurrent(in: controller) else {
                            controller.errorMessage = workflowText(languageStore, "workflow.run.planChanged",
                                fallback: "流程或配置已变化，请重新查看运行计划。")
                            return
                        }
                        await controller.run(target: preview.nodeID, only: preview.only)
                    }
                }
            )
        }
        .sheet(item: $scopePresentation) { request in
            WorkflowScopePanel(controller: controller, graphID: request.graphID,
                revision: request.revision, nodeID: request.nodeID)
        }
        .sheet(isPresented: $toolsPresented) {
            VStack(alignment: .leading) {
                Button(workflowText(languageStore, "baseline02.ui.label.572cf45ba436", fallback: "返回"), systemImage: "chevron.left") { toolsPresented = false }.padding([.top, .leading])
                WorkflowToolPanel(controller: controller)
            }
        }
        .sheet(isPresented: $interfacePresented) {
            if let graph = controller.graph {
                VStack(alignment: .leading) {
                    Button(workflowText(languageStore, "baseline02.ui.label.572cf45ba436", fallback: "返回"), systemImage: "chevron.left") { interfacePresented = false }.padding([.top, .leading])
                    ScrollView { WorkflowGraphInterfaceEditor(graph: Binding(get: { controller.graph?.id == graph.id ? controller.graph! : graph }, set: { controller.updateInterface($0.interface, in: graph.id) }), registry: controller.registry, tools: controller.tools).padding() }
                }
                    .frame(minWidth: 640, minHeight: 500)
            }
        }
        .onChange(of: controller.graph?.id) { _, _ in
            pendingConnection = nil
            selectedConnectionID = nil
            runPreview = nil
        }
        .onChange(of: runContext) { _, _ in
            runTarget = nil; runPreview = nil; scopePresentation = nil
            if let run = controller.activePresentationRun, controller.presentationRootGraphID(for: run.id) == controller.rootGraph?.id {
                resultRunID = run.id; resultNodeID = run.targetNodeID
            } else { resultRunID = nil; resultNodeID = nil }
        }
        .onChange(of: libraryMode) { _, mode in if mode == .results { resultsOpened = true } }
        .onChange(of: controller.graph) { _, _ in
            if runTarget?.isCurrent(in: controller) != true { runTarget = nil }
            if let runPreview, !runPreview.isCurrent(in: controller) { self.runPreview = nil }
        }
        .onChange(of: selectedConnectionID) { _, value in
            if value != nil { revealInspector() }
        }
        .onChange(of: controller.graph?.connections) { _, connections in
            if let selectedConnectionID,
               connections?.contains(where: { $0.id == selectedConnectionID }) != true {
                self.selectedConnectionID = nil
            }
        }
        .onChange(of: viewContext) { _, next in restoreViewContext(next) }
        .onAppear { activeViewContext = viewContext }
        .onChange(of: zoom) { _, _ in rememberViewContext() }
        .onChange(of: viewportInteractionLocked) { _, locked in viewportLockObserver?(locked) }
        .onChange(of: controller.selectedNodeIDs) { _, ids in
            if !ids.isEmpty {
                controller.selectedNodeID = ids.count == 1 ? ids.first : nil
                selectedConnectionID = nil
            }
        }
        .onChange(of: controller.selectedNodeID) { _, value in
            if value != nil { selectedConnectionID = nil }
            rememberViewContext()
        }
    }

    private func revealInspector() {
        showInspector = true
        narrowLibrary = false
    }

    private func panels(height: CGFloat, width: CGFloat) -> some View {
        let shown = WorkflowCanvasLayoutPolicy.visiblePanels(width: width, library: showLibrary,
            inspector: showInspector, preferLibrary: narrowLibrary)
        let targetCanvasWidth = width - 32 - 24
            - (shown.inspector ? WorkbenchSidebarLayout.leadingWidth : 48)
            - (shown.library ? WorkbenchSidebarLayout.trailingWidth : 48)
        let fitReady = canvasViewport?.permitsFit(targetWidth: targetCanvasWidth) == true
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                WorkbenchSidebar(leading: true, expanded: shown.inspector,
                    title: text("canvas.inspector.title", "当前对象"), identifier: "canvas-inspector-toggle",
                    hostIdentifier: "canvas-inspector-host", toggle: {
                        showInspector = !shown.inspector; narrowLibrary = false
                    }) { objectInspector }
                    .frame(width: shown.inspector ? WorkbenchSidebarLayout.leadingWidth : 48, alignment: .leading)
                VStack(spacing: 0) {
                WorkflowGraphSurface(controller: controller, graph: controller.graph, zoom: $zoom,
                    tool: $canvasTool,
                    navigationRequest: $navigationRequest,
                    viewportInteractionLocked: $viewportInteractionLocked,
                    viewContext: viewContext,
                    pendingConnection: $pendingConnection, selectedConnectionID: $selectedConnectionID,
                    readOnly: !controller.canEditCanvas,
                    onPlan: presentPlan, onSetRunTarget: setRunTarget, nodeSizeObserver: { id, size in
                        measuredCardSizes[id] = size
                        nodeSizeObserver?(id, size)
                    },
                    viewportSizeObserver: { canvasViewport = $0 },
                    portCenterObserver: portCenterObserver,
                    onScrollObservation: { context, observation in
                        if observation.isGestureEnd {
                            // An interrupted pan may finish after another graph has mounted.
                            // Save its captured context without moving the new graph's insertion point.
                            viewStates.capture(zoom: observation.zoom, rawVisibleCenter: observation.visibleRawCenter,
                                selectedNodeID: viewStates.state(for: context)?.selectedNodeID, for: context)
                        }
                        guard context == viewContext, activeViewContext == context else { return }
                        actualVisibleRawCenter = observation.visibleRawCenter
                        canvasInsertionPoint = observation.visibleRawCenter
                        rememberViewContext()
                        scrollObserver?(context, observation)
                    },
                    onDropItem: dropItem,
                    onBindAsset: { project, instance, asset, node in
                        guard controller.canEditCanvas,
                              WorkflowCanvasAssetIdentity.acceptsOwnProject(
                                  projectID: project, instanceID: instance, assetID: asset,
                                  currentProjectID: controller.projectID,
                                  currentInstanceID: controller.projectInstanceID,
                                  acceptsLegacyAsset: acceptsLegacyAsset),
                              controller.availableAssets.contains(where: { $0.id == asset }),
                              let target = controller.assetBindingTarget(nodeID: node) else { return false }
                        Task { await controller.bindLibraryAsset(projectID: project, assetID: asset, target: target) }
                        return true
                    }, onInspect: { id in
                        guard controller.graph?.nodes.contains(where: { $0.id == id }) == true else { return }
                        controller.selectedNodeIDs = []; controller.selectedNodeID = id; selectedConnectionID = nil; revealInspector()
                    })

                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if controller.isRunning && !controller.visibleStreamingText.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(text("generation.preview.pending", "正在生成 · 临时预览")).font(.caption).foregroundStyle(.secondary)
                            ScrollView { Text(controller.visibleStreamingText).textSelection(.enabled) }.frame(maxHeight: 140)
                        }.padding(10).accessibilityIdentifier("canvas-streaming-text")
                    }
                }.frame(minWidth: WorkflowCanvasLayoutPolicy.canvasMinimumWidth, maxWidth: .infinity)
                WorkbenchSidebar(leading: false, expanded: shown.library,
                    title: text("canvas.resources.title", "节点、素材与结果"), identifier: "canvas-library-toggle",
                    hostIdentifier: "canvas-library-host", toggle: {
                        showLibrary = !shown.library; narrowLibrary = true
                    }) { resourcePanel }
                    .frame(width: shown.library ? WorkbenchSidebarLayout.trailingWidth : 48, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            executionBar
            canvasTools(fitReady: fitReady, targetWidth: targetCanvasWidth)
            statusStrip
        }.padding(.top, 8)
    }

    private func text(_ key: String, _ fallback: String) -> String {
        workflowText(languageStore, key, fallback: fallback)
    }
    private var selectedNodes: [WorkflowNode] {
        WorkflowObjectSelection.nodes(in: controller.graph, single: controller.selectedNodeID,
            multiple: controller.selectedNodeIDs, connection: selectedConnectionID)
    }
    @ViewBuilder private var objectInspector: some View {
        if let connection = controller.graph?.connections.first(where: { $0.id == selectedConnectionID }) {
            WorkflowCanvasConnectionInspector(controller: controller, connection: connection,
                onClose: { selectedConnectionID = nil })
        } else if selectedNodes.count > 1 {
            VStack(alignment: .leading, spacing: 14) {
                Text(text("workflow.selection.count", "已选择 {count} 个节点").replacingOccurrences(of: "{count}", with: String(selectedNodes.count)))
                    .font(.headline)
                ForEach(selectedNodes) { node in Text(node.title).lineLimit(2) }
                Button(text("refinement.workflow.extractSelection", "组合为自定义节点…")) { toolsPresented = true }
                    .disabled(!controller.canEditCanvas)
                Button(text("workflow.selection.clear", "清除选择")) {
                    controller.selectedNodeID = nil; controller.selectedNodeIDs = []
                }
                Spacer()
            }.padding(14)
        } else if let node = selectedNodes.first {
WorkflowNodeInspector(controller: controller, node: node,
                    readOnly: isReadOnly, onTextModel: { guard selectForAction(node) else { return }; guarded(onTextModel)() }, onImageModel: { guard selectForAction(node) else { return }; guarded(onImageModel)() },
                    onAdditionalModel: { kind in guard selectForAction(node) else { return }; guarded { onAdditionalModel(kind) }() },
                    onImport: { id in guard !isReadOnly else { return }; onImport(id) },
                    onRecord: { id in guard !isReadOnly else { return }; onRecord(id) },
                    onReturnText: { ref in guard !isReadOnly else { return }; onReturnText(ref) },
                onPlan: presentPlan, onQuickUse: onQuickUse,
                onOpenBody: { nodeID, slot in
                    rememberViewContext()
                    controller.openBody(nodeID: nodeID, slot: slot)
                },
                onOpenTool: { reference in
                    rememberViewContext()
                    controller.openToolCopy(reference)
                })
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(controller.graph?.name ?? text("workflow.toolbar.noGraph", "选择流程")).font(.title3.bold())
                    Text(text("workflow.overview.counts", "{nodes} 个节点 · {wires} 条连接")
                        .replacingOccurrences(of: "{nodes}", with: String(controller.graph?.nodes.count ?? 0))
                        .replacingOccurrences(of: "{wires}", with: String(controller.graph?.connections.count ?? 0)))
                        .foregroundStyle(.secondary)
                    Button(text("workflow.language.interface", "设置流程输入与输出…")) { interfacePresented = true }
                        .disabled(controller.graph == nil || !controller.canEditCanvas)
                    Text(text("workflow.overview.hint", "选择卡片以配置节点；选择连线以查看来源和数据。运行终点在下方单独指定。"))
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(14)
            }
        }
    }

    private func selectForAction(_ node: WorkflowNode) -> Bool {
        guard controller.graph?.nodes.contains(node) == true else { return false }
        controller.selectedNodeID = node.id; return true
    }
    private var resourcePanel: some View {
        VStack(spacing: 8) {
            Picker(text("canvas.library.mode", "资料类型"), selection: $libraryMode) {
                Text(text("canvas.library.nodes", "节点")).tag(WorkflowCanvasLibraryMode.nodes)
                Text(text("canvas.library.assets", "素材")).tag(WorkflowCanvasLibraryMode.assets)
                Text(text("canvas.library.results", "结果")).tag(WorkflowCanvasLibraryMode.results)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10)
            ZStack {
            if resultsOpened || libraryMode == .results {
                RetainedContentHost(content: resultsPanel.workbenchTheme()
                    .environment(\.dLanguageStore, languageStore)
                    .environment(\.chatDisplayPreferences, displayPreferences),
                    visible: libraryMode == .results, identifier: "workflow-results-host")
                    .allowsHitTesting(libraryMode == .results).accessibilityHidden(libraryMode != .results)
            }
            if libraryMode != .results {
            if let libraryContent {
                libraryContent(libraryMode, canvasInsertionPoint, { showLibrary = false }).id(libraryMode)
            } else if libraryMode == .nodes {
                WorkflowNodeLibrary(controller: controller, tagStore: nodeTags) { entry in
                    controller.addNode(operationID: entry.operation.id, modelID: entry.model?.id,
                        x: canvasInsertionPoint.x, y: canvasInsertionPoint.y)
                    revealInspector()
                }
            } else {
                WorkflowAssetLibrary(controller: controller, onAdd: { project, asset in
                    if controller.graph == nil { controller.addBlankGraph() }
                    guard let target = controller.canvasInsertionTarget() else { return }
                    Task { await controller.addAssetNode(projectID: project, assetID: asset,
                        x: canvasInsertionPoint.x, y: canvasInsertionPoint.y, target: target) }
                }, onImport: onImportAsset, onDropFile: onDropFile)
            }
            }
            }
            if libraryMode == .nodes {
                Button(text("workflow.language.tools", "管理自定义节点…")) { toolsPresented = true }.padding(.bottom, 10)
            }
        }
    }

    private var resultSourceNodes: [WorkflowNode] {
        if let resultRunID, let run = controller.runs.first(where: { $0.id == resultRunID }),
           controller.presentationRootGraphID(for: run.id) == controller.rootGraph?.id { return run.graph.nodes }
        return controller.graph?.nodes ?? []
    }
    private var resultNode: WorkflowNode? {
        let id = resultNodeID ?? runTarget?.nodeID ?? selectedNodes.first?.id
        return resultSourceNodes.first { $0.id == id }
    }
    private var resultsPanel: some View {
        VStack(spacing: 8) {
            if let resultRunID {
                Text(text("workflow.results.snapshot", "运行快照") + " · " + resultRunID.uuidString.prefix(8)).font(.caption).foregroundStyle(.secondary)
                Button(text("workflow.results.current", "查看当前节点")) { self.resultRunID = nil; resultNodeID = nil }
            }
            Picker(text("workflow.results.node", "查看节点结果"), selection: Binding(get: { resultNode?.id }, set: { resultNodeID = $0 })) {
                Text(text("workflow.results.choose", "选择节点")).tag(UUID?.none)
                ForEach(resultSourceNodes) { node in Text(node.title).tag(Optional(node.id)) }
            }.padding(.horizontal, 10)
            WorkflowNodeInspector(controller: controller, node: resultNode, readOnly: isReadOnly,
                onTextModel: {}, onImageModel: {}, onAdditionalModel: { _ in }, onImport: { _ in }, onRecord: { _ in },
                onReturnText: { ref in guard !isReadOnly else { return }; onReturnText(ref) },
                onPlan: presentPlan, onQuickUse: nil, onOpenBody: { _, _ in }, onOpenTool: { _ in }, resultsOnly: true, resultRunID: resultRunID)
        }
    }

    private func dropItem(_ value: WorkflowCanvasTransfer, _ point: CGPoint) -> Bool {
        guard controller.canEditCanvas else { return false }
        switch value {
        case .operation(let id, let model):
            guard controller.registry.operation(id) != nil else { return false }
            controller.addNode(operationID: id, modelID: model, x: point.x, y: point.y)
            revealInspector(); return controller.errorMessage == nil
        case .asset, .assetInstance:
            guard let identity = WorkflowCanvasAssetIdentity.payload(value) else { return false }
            return dropAsset(project: identity.project, instance: identity.instance,
                asset: identity.asset, point: point)
        case .tool(let reference):
            guard let tool = controller.tools.first(where: { $0.id == reference.id && $0.version == reference.version && (try? WorkflowPlanCompiler.digest($0)) == reference.digest }) else { return false }
            controller.addTool(tool, x: point.x, y: point.y)
            revealInspector(); return controller.errorMessage == nil
        case .output: return false
        }
    }

    private func dropAsset(project: UUID, instance: UUID?, asset: UUID, point: CGPoint) -> Bool {
        guard let target = controller.canvasInsertionTarget() else { return false }
        if let onSharedAssetDrop {
            return onSharedAssetDrop(project, instance, asset, point, target)
        }
        guard WorkflowCanvasAssetIdentity.acceptsOwnProject(
            projectID: project, instanceID: instance, assetID: asset,
            currentProjectID: controller.projectID, currentInstanceID: controller.projectInstanceID,
            acceptsLegacyAsset: acceptsLegacyAsset),
            controller.availableAssets.contains(where: { $0.id == asset }) else { return false }
        Task { await controller.addAssetNode(projectID: project, assetID: asset,
            x: point.x, y: point.y, target: target) }
        return true
    }

    private func toolbar(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            if !controller.bodyPath.isEmpty {
                Button(text("workflow.language.control.back", "返回外层"), systemImage: "arrow.up.backward") {
                    rememberViewContext(); controller.closeBody()
                }
            }
            Menu {
                ForEach(controller.graphs) { graph in
                    Button(graph.name) { rememberViewContext(); controller.selectedGraphID = graph.id }
                }
            } label: {
                Label(controller.rootGraph?.name ?? text("workflow.toolbar.noGraph", "选择流程"), systemImage: "chevron.down")
                    .lineLimit(1)
            }.accessibilityIdentifier("workflow-graph-picker")
            if !controller.bodyPath.isEmpty {
                Text("/ " + (controller.graph?.name ?? "")).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(text("canvas.new", "新流程"), systemImage: "plus") { controller.addBlankGraph() }
                .disabled(!controller.canEditCanvas).accessibilityIdentifier("canvas-new-flow")
            Button(text("workflow.action.save", "保存"), systemImage: "square.and.arrow.down") {
                Task { await controller.save() }
            }.disabled(isReadOnly || controller.isSaving).accessibilityIdentifier("workflow-save")
            if controller.isSaving { ProgressView().controlSize(.small) }
            else if controller.hasPendingSaves { Text(text("workflow.status.pendingSave", "有待恢复保存")).foregroundStyle(.orange).font(.caption) }
            Menu(text("canvas.flowMenu", "流程菜单"), systemImage: "ellipsis.circle") {
                Menu(text("workflow.toolbar.addExample", "添加样例")) {
                    ForEach(WorkflowLanguageExample.allCases, id: \.rawValue) { example in
                        Button(text("workflow.language.example.\(example.rawValue)",
                            ["data": "数据与控制", "images": "主题与图像批次", "music": "哼唱与和声", "multimodal": "同源四模态"][example.rawValue] ?? example.rawValue)) {
                            controller.addLanguageExample(example)
                        }
                    }
                    ForEach(WorkflowExampleChoice.allCases) { example in Button(example.title(languageStore)) { controller.addExample(example.rawValue) } }
                }.disabled(!controller.canEditCanvas)
                Button(text("workflow.language.interface", "设置流程输入与输出…")) { interfacePresented = true }
                    .disabled(controller.graph == nil || !controller.canEditCanvas)
                Button(text("workflow.language.tools", "管理自定义节点…")) { toolsPresented = true }
                Divider()
                Button(text("workflow.action.publishText", "将当前文稿存为流程素材")) { guarded(onPublishText)() }.disabled(isReadOnly)
                Button(text("workflow.action.exportDirectory", "选择导出文件夹…")) { guarded(onDestination)() }.disabled(isReadOnly)
                Text(controller.destinationDescription)
            }.accessibilityIdentifier("canvas-more")
        }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var runContext: WorkflowRunTarget.Context { .init(controller) }
    private var validRunTarget: WorkflowNode? {
        guard let runTarget, runTarget.isCurrent(in: controller) else { return nil }
        return controller.graph?.nodes.first { $0.id == runTarget.nodeID }
    }
    private func setRunTarget(_ id: UUID) {
        guard controller.graph?.nodes.contains(where: { $0.id == id }) == true else { return }
        runTarget = WorkflowRunTarget(context: runContext, nodeID: id)
        runPreview = nil
    }
    private var executionBar: some View {
        HStack(spacing: 10) {
            if controller.isRunning {
                ProgressView().controlSize(.small)
                if let run = controller.activePresentationRun {
                    Text(text("workflow.run.current", "正在运行到：") + (run.graph.nodes.first { $0.id == run.targetNodeID }?.title ?? run.targetNodeID.uuidString))
                        .lineLimit(1).accessibilityIdentifier("workflow-active-target")
                }
                Button(text("workflow.language.control.pause", "暂停流程"), systemImage: "pause") { controller.pause() }
                    .help(text("workflow.run.pauseHelp", "当前步骤完成并释放资源后暂停。"))
                    .disabled(!controller.canPausePresentation)
                Button(text("workflow.action.stop", "停止流程"), systemImage: "stop.fill", role: .destructive) {
                    Task { await controller.cancel() }
                }.accessibilityIdentifier("workflow-cancel")
            } else {
                Picker(text("workflow.run.target", "运行终点"), selection: Binding(get: { validRunTarget?.id }, set: { id in
                    if let id { setRunTarget(id) } else { runTarget = nil; runPreview = nil }
                })) {
                    Text(text("workflow.run.choose", "请选择运行终点")).tag(UUID?.none)
                    ForEach(controller.graph?.nodes ?? []) { node in Text(node.title).tag(Optional(node.id)) }
                }.frame(maxWidth: 280).accessibilityIdentifier("workflow-run-target")
                Picker(text("workflow.run.range", "范围"), selection: $runOnly) {
                    Text(text("workflow.action.runToHere", "运行到此节点")).tag(false)
                    Text(text("workflow.action.rerunOnly", "只重跑此节点")).tag(true)
                }.frame(maxWidth: 230).accessibilityIdentifier("workflow-run-range")
                Button(text("workflow.run.plan", "查看计划并运行…"), systemImage: "play.fill") {
                    if let node = validRunTarget { presentPlan(nodeID: node.id, only: runOnly) }
                }.buttonStyle(.borderedProminent)
                    .disabled(validRunTarget == nil || !controller.canEditCanvas || !controller.bodyPath.isEmpty)
                    .accessibilityIdentifier("workflow-run")
                Menu(text("workflow.run.advanced", "更多范围"), systemImage: "ellipsis") {
                    Button(text("workflow.scope.title", "选择运行范围与历史输入")) {
                        if let node = validRunTarget, let graph = controller.rootGraph { scopePresentation = .init(graph: graph, nodeID: node.id) }
                    }.disabled(validRunTarget == nil || !controller.canEditCanvas || !controller.bodyPath.isEmpty)
                }.menuStyle(.borderlessButton).fixedSize()
            }
            Button(text("workflow.section.history", "运行历史"), systemImage: "clock.arrow.circlepath") {
                if let run = controller.activePresentationRun {
                    rememberViewContext()
                    guard controller.revealRunForPresentation(run.id) else { return }
                    resultRunID = run.id; resultNodeID = run.targetNodeID
                } else { resultRunID = nil; resultNodeID = validRunTarget?.id ?? selectedNodes.first?.id }
                libraryMode = .results; showLibrary = true; narrowLibrary = true
            }
        }.controlSize(.small).padding(10).workbenchPanel(in: Capsule())
            .padding(.horizontal, 16)
    }

    private func canvasTools(fitReady: Bool, targetWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            Picker(text("refinement.workflow.canvasTool", "画布工具"), selection: $canvasTool) {
                Label(text("refinement.workflow.pointer", "指针"), systemImage: "cursorarrow").tag(WorkflowCanvasTool.pointer)
                Label(text("refinement.workflow.hand", "手形"), systemImage: "hand.draw").tag(WorkflowCanvasTool.hand)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 100).accessibilityIdentifier("workflow-canvas-tool")
            Button(text("workflow.action.undo", "撤销"), systemImage: "arrow.uturn.backward") { controller.undo() }
                .disabled(!controller.canEditCanvas || !controller.canUndo)
            Button(text("workflow.action.redo", "重做"), systemImage: "arrow.uturn.forward") { controller.redo() }
                .disabled(!controller.canEditCanvas || !controller.canRedo)
            Menu(text("workflow.selection.menu", "选择"), systemImage: "square.dashed") {
                Button(text("workflow.selection.all", "选择全部节点")) {
                    controller.selectedNodeID = nil; selectedConnectionID = nil
                    controller.selectedNodeIDs = Set(controller.graph?.nodes.map(\.id) ?? [])
                }
                Button(text("workflow.selection.clear", "清除选择")) {
                    controller.selectedNodeID = nil; controller.selectedNodeIDs = []; selectedConnectionID = nil
                }
                Button(text("refinement.workflow.extractSelection", "组合为自定义节点…")) {
                    if let node = selectedNodes.first, selectedNodes.count == 1 { controller.selectedNodeIDs = [node.id] }
                    toolsPresented = true
                }.disabled(!controller.canEditCanvas || selectedNodes.isEmpty)
                    .accessibilityIdentifier("workflow-canvas-extract-selection")
            }
            Spacer(minLength: 4)
            Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit())
            Slider(value: $zoom, in: WorkflowCanvasLayoutPolicy.sliderZoomRange(current: zoom))
                .frame(width: 78).disabled(viewportInteractionLocked)
                .accessibilityLabel(text("workflow.toolbar.zoom", "画布缩放"))
            Button(text("refinement.workflow.fitAll", "显示全部节点"), systemImage: "arrow.up.left.and.arrow.down.right") {
                fitAllNodes(targetWidth: targetWidth)
            }.disabled(!fitReady || viewportInteractionLocked).accessibilityIdentifier("workflow-canvas-fit-all")
            Button(text("workflow.canvas.resetView", "重置画布视图"), systemImage: "scope") {
                guard !viewportInteractionLocked else { return }
                zoom = 1; navigationRequest = WorkflowCanvasNavigationRequest(rawCenter: nil)
            }.disabled(viewportInteractionLocked).accessibilityIdentifier("workflow-canvas-reset-view")
        }.buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 18)
    }

    @ViewBuilder
    private var statusStrip: some View {
        HStack(spacing: 10) {
            if let reason = controller.readOnlyReason {
                Label(reason, systemImage: "lock.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("workflow-read-only")
            }
            if controller.isSaving {
                ProgressView().controlSize(.small)
                Text(workflowText(languageStore, "workflow.status.savingNow", fallback: "正在保存"))
            } else if controller.isRunning {
                ProgressView().controlSize(.small)
                Text(controller.progressMessage.isEmpty
                     ? workflowText(languageStore, "workflow.status.runningNow", fallback: "正在运行")
                     : controller.progressMessage)
            } else if !controller.progressMessage.isEmpty {
                Text(controller.progressMessage).foregroundStyle(.secondary)
            }
            Spacer()
            Button(workflowText(languageStore, "refinement.workflow.typeLegend", fallback: "类型图例"), systemImage: "paintpalette") { portLegendPresented.toggle() }
                .popover(isPresented: $portLegendPresented) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(WorkflowPortStyle.legend.indices, id: \.self) { index in
                            let entry = WorkflowPortStyle.legend[index]
                            HStack(spacing: 8) {
                                Circle().fill(WorkflowPortStyle.color(for: entry.port))
                                    .frame(width: 10, height: 10)
                                Text(workflowText(languageStore, "refinement.workflow.legend." + entry.key, fallback: entry.fallback))
                            }
                        }
                    }
                    .padding(14)
                }
                .accessibilityIdentifier("workflow-port-legend")
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityIdentifier("workflow-error")
                Button(workflowText(languageStore, "workflow.action.close", fallback: "关闭"),
                       systemImage: "xmark") { controller.errorMessage = nil }
                    .labelStyle(.iconOnly)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .background(.thinMaterial)
    }

    private var viewContext: WorkflowCanvasViewContext {
        WorkflowCanvasViewContext(projectID: controller.projectID, rootGraphID: controller.rootGraph?.id,
            bodyPath: controller.bodyPath.map(WorkflowCanvasBodyLocation.init))
    }

    private func rememberViewContext() {
        viewStates.capture(zoom: zoom, rawVisibleCenter: actualVisibleRawCenter,
            selectedNodeID: controller.selectedNodeID, for: viewContext)
    }

    private func fitAllNodes(targetWidth: CGFloat) {
        guard !viewportInteractionLocked, activeViewContext == viewContext,
              let canvasViewport, canvasViewport.permitsFit(targetWidth: targetWidth), let graph = controller.graph,
              !graph.nodes.isEmpty else { return }
        let geometry = WorkflowGraphGeometry(graph: graph, tools: controller.tools,
                                             registry: controller.registry)
        var bounds = CGRect.null
        for node in graph.nodes {
            let point = geometry.rawPosition(node.id)
            let definition = controller.registry.definition(for: node, tools: controller.tools)
            let height = measuredCardSizes[node.id]?.height ?? CGFloat(WorkflowLayout.cardHeightBudget(
                inputs: definition?.inputs.count ?? 1, outputs: definition?.outputs.count ?? 1))
            bounds = bounds.union(CGRect(x: point.x - WorkflowCanvasLayoutPolicy.nodeWidth / 2,
                                        y: point.y - height / 2,
                                        width: WorkflowCanvasLayoutPolicy.nodeWidth, height: height))
        }
        guard let fitted = WorkflowCanvasFit.view(for: bounds, viewport: canvasViewport.clip) else { return }
        zoom = fitted.zoom
        navigationRequest = WorkflowCanvasNavigationRequest(rawCenter: fitted.center)
    }

    private func restoreViewContext(_ context: WorkflowCanvasViewContext) {
        if let saved = viewStates.state(for: context) {
            zoom = WorkflowCanvasLayoutPolicy.restoredZoom(saved.zoom)
            actualVisibleRawCenter = saved.rawVisibleCenter
            navigationRequest = WorkflowCanvasNavigationRequest(rawCenter: saved.rawVisibleCenter)
            controller.selectedNodeID = controller.graph?.nodes.contains(where: { $0.id == saved.selectedNodeID }) == true
                ? saved.selectedNodeID : nil
        } else {
            zoom = 1
            if let graph = controller.graph {
                let geometry = WorkflowGraphGeometry(graph: graph, tools: controller.tools,
                    registry: controller.registry)
                actualVisibleRawCenter = CGPoint(
                    x: geometry.size.width / 2 - geometry.translation.width,
                    y: geometry.size.height / 2 - geometry.translation.height)
            }
            navigationRequest = WorkflowCanvasNavigationRequest(rawCenter: nil)
        }
        activeViewContext = context
    }

    private var isReadOnly: Bool {
        !WorkflowCanvasPresentation.allowsMutation(readOnlyReason: controller.readOnlyReason)
    }

    private func guarded(_ callback: @escaping () -> Void) -> () -> Void {
        { guard !isReadOnly else { return }; callback() }
    }

    private func presentPlan(nodeID: UUID, only: Bool) {
        guard !isReadOnly else { return }
        do {
            let lines = try controller.plan(target: nodeID, only: only)
            setRunTarget(nodeID); runOnly = only
            runPreview = WorkflowRunPreview(controller: controller, nodeID: nodeID, only: only, lines: lines)
        } catch {
            controller.errorMessage = error.localizedDescription
        }
    }
}

private struct WorkflowFixedToolPresentation: Identifiable {
    let reference: WorkflowToolReference
    var id: String { reference.id.uuidString + ":\(reference.version):" + reference.digest }
}

private struct WorkflowNodeInspector: View {
    let controller: WorkflowController
    let node: WorkflowNode?
    let readOnly: Bool
    let onTextModel: () -> Void
    let onImageModel: () -> Void
    let onAdditionalModel: (WorkflowModelKind) -> Void
    let onImport: (UUID) -> Void
    let onRecord: (UUID) -> Void
    let onReturnText: (WorkflowAssetReference) -> Void
    let onPlan: (UUID, Bool) -> Void
    let onQuickUse: ((WorkflowNode) -> Void)?
    let onOpenBody: (UUID, String) -> Void
    let onOpenTool: (WorkflowToolReference) -> Void
    var resultsOnly = false
    var resultRunID: UUID? = nil
    @Environment(\.dLanguageStore) private var languageStore
    @State private var scopePresentation: WorkflowScopePresentation?
    @State private var fixedToolPresentation: WorkflowFixedToolPresentation?
    @State private var pendingCall: WorkflowCallReference?
    @State private var showHistory = false
    @State private var showTechnical = false

    var body: some View {
        ScrollView {
            if let node {
                VStack(alignment: .leading, spacing: 16) {
                    if !resultsOnly {
                    identity(node)
                    if node.operationID == "d.video.generate", let graph = controller.graph,
                       let target = WorkflowVideoPresetAction(node: node, graph: graph) {
                        videoPresets(target)
                    }
                    if node.operationID == "d.music.generate" {
                        musicCapabilities
                    }
                    parameters(node)
                    if node.operationID.hasPrefix("d.value.") || ["d.model.language", "d.control.human", "d.music.chords"].contains(node.operationID) {
                        WorkflowNodeDataEditor(node: Binding(get: { controller.graph?.nodes.first(where: { $0.id == node.id }) ?? node }, set: { edited in
                            controller.setDataConfiguration(nodeID: node.id, value: edited.dataConfiguration)
                        }), availableRecordSchema: WorkflowFormSupport.connectedRecordFields(nodeID: node.id, graph: controller.graph, tools: controller.tools)).id(node.id).disabled(readOnly)
                    }
                    if node.operationID.hasPrefix("d.control."), node.operationID != "d.control.human", let graphID = controller.graph?.id {
                        WorkflowControlEditor(node: Binding(get: { controller.graph?.nodes.first(where: { $0.id == node.id }) ?? node }, set: { controller.updateNode($0, in: graphID) }), tools: controller.tools, onOpenBody: { slot in
                            if slot == "tool", case .invoke(let reference) = node.control {
                                fixedToolPresentation = .init(reference: reference)
                            }
                            else { onOpenBody(node.id, slot) }
                        }).id(node.id).disabled(readOnly)
                    }
                    ports(node)
                    } else {
                    execution(node)
                    DisclosureGroup(isExpanded: $showHistory) {
                        history(node)
                    } label: {
                        Text(workflowText(languageStore, "workflow.section.history", fallback: "运行历史"))
                    }
                    }
                }
                .padding(14)
            } else {
                ContentUnavailableView(
                    workflowText(languageStore, "workflow.inspector.empty", fallback: "选择节点"),
                    systemImage: "sidebar.right",
                    description: Text(workflowText(
                        languageStore,
                        "workflow.inspector.emptyDescription",
                        fallback: "检查参数、端口、输入身份、结果和运行历史。"
                    ))
                )
                    .padding(.top, 36)
            }
        }
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("workflow-inspector")
        .sheet(item: $scopePresentation) { request in
            WorkflowScopePanel(controller: controller, graphID: request.graphID, revision: request.revision, nodeID: request.nodeID)
        }
        .sheet(item: $fixedToolPresentation) { request in
            WorkflowFixedToolSheet(controller: controller, reference: request.reference,
                onClose: { fixedToolPresentation = nil },
                onCopy: {
                    fixedToolPresentation = nil
                    onOpenTool(request.reference)
                })
        }
        .alert(workflowText(languageStore, "workflow.scope.rerunCall", fallback: "重新运行具体调用"),
               isPresented: Binding(get: { pendingCall != nil }, set: { if !$0 { pendingCall = nil } })) {
            Button(workflowText(languageStore, "workflow.scope.run", fallback: "运行所选范围")) {
                if let reference = pendingCall { Task { await controller.rerunCall(reference) } }
                pendingCall = nil
            }
            Button(workflowText(languageStore, "workflow.scope.cancel", fallback: "取消"), role: .cancel) { pendingCall = nil }
        } message: {
            Text(workflowText(languageStore, "workflow.scope.callExplanation", fallback: "使用这次调用冻结的参数与输入，创建新的运行。不会改写或继续原有循环；模型调用可能耗时。"))
        }
    }

    @ViewBuilder
    private func videoPresets(_ target: WorkflowVideoPresetAction) -> some View {
        WorkflowInspectorSection(workflowText(
            languageStore, "workflow.videoPresets.title", fallback: "视频参数预设"
        )) {
            ForEach(WorkflowVideoPresets.all) { preset in
                Button {
                    applyVideoPreset(preset, target: target)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workflowText(
                            languageStore,
                            "workflow.videoPresets.\(preset.id).title",
                            fallback: preset.id
                        ))
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(workflowText(
                            languageStore,
                            "workflow.videoPresets.\(preset.id).detail",
                            fallback: "\(preset.width)×\(preset.height) · \(preset.frameCount)帧 · \(preset.frameRate)fps · \(preset.steps)步 · CFG \(preset.guidance.formatted()) · shift \(preset.scheduleShift.formatted())"
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(readOnly || controller.isRunning)
                .accessibilityLabel(workflowText(
                    languageStore,
                    "workflow.videoPresets.\(preset.id).title",
                    fallback: preset.id
                ))
                .accessibilityValue(workflowText(
                    languageStore,
                    "workflow.videoPresets.\(preset.id).detail",
                    fallback: "\(preset.width)×\(preset.height) · \(preset.frameCount)帧 · \(preset.frameRate)fps · \(preset.steps)步 · CFG \(preset.guidance.formatted()) · shift \(preset.scheduleShift.formatted())"
                ))
                .accessibilityIdentifier("workflow-video-preset-\(preset.id)")
            }
            Text(workflowText(
                languageStore,
                "workflow.videoPresets.applyNotice",
                fallback: "只在明确选择时更新七项参数；不会运行，也不改变模型、提示、种子或内存预算。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(workflowText(
                languageStore,
                "workflow.videoPresets.qualityNotice",
                fallback: "4步仅检查链路；完整短预览不保证成片质量；官方480p起点未在本机本轮验证。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var musicCapabilities: some View {
        WorkflowInspectorSection(workflowText(
            languageStore, "workflow.musicCapabilities.title", fallback: "MRT2 固定能力与边界"
        )) {
            Text(workflowText(
                languageStore,
                "workflow.musicCapabilities.conditioning",
                fallback: "25Hz（40ms）条件编码音高、起音和延续；同音声部合并，非零力度不编码，鼓当前不受约束。条件服从为近似，不保证精确复现。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(workflowText(
                languageStore,
                "workflow.musicCapabilities.optionalNotes",
                fallback: "音符和和声均未提供时不约束音符；无和声时显式空音符列表发送所有音高OFF条件，而不是省略条件，但不保证静音；连接和声时仍与音符条件合并。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(workflowText(
                languageStore,
                "workflow.musicCapabilities.output",
                fallback: "输出限WAV、48kHz、双声道、最长16秒。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(workflowText(
                languageStore,
                "workflow.musicCapabilities.sampling",
                fallback: "固定采样：温度1.3、Top-k 40、MusicCoCa CFG 3、音符/鼓 CFG 1。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func applyVideoPreset(_ preset: WorkflowVideoPreset, target: WorkflowVideoPresetAction) {
        guard !readOnly, !controller.isRunning, controller.readOnlyReason == nil,
              let graph = controller.graph,
              let replacement = target.replacement(in: graph, preset: preset) else { return }
        controller.updateNode(replacement, in: target.graphID)
    }

    @ViewBuilder
    private func identity(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.node", fallback: "节点")) {
            let resolved = WorkflowNodeIdentity.resolve(node: node,
                definition: controller.registry.definition(for: node, tools: controller.tools),
                modelChoices: controller.modelChoices, assets: controller.availableAssets,
                tools: controller.tools, language: languageStore)
            Text(resolved.title).font(.title3.weight(.semibold))
            if let detail = resolved.detail {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let annotation = resolved.annotation, annotation != resolved.title {
                Text(annotation).font(.callout).foregroundStyle(.secondary)
            }
            if let onQuickUse, controller.registry.definition(for: node, tools: controller.tools)?.modelKind != nil {
                Button(workflowText(languageStore, "canvas.identity.quickUse", fallback: "在快速生成中使用设置")) {
                    onQuickUse(node)
                }
                .accessibilityIdentifier("canvas-quick-use-" + node.id.uuidString)
            }
            if case .invoke(let reference) = node.control {
                Button(workflowText(languageStore, "canvas.tool.fixedTitle", fallback: "查看固定工具")) {
                    fixedToolPresentation = .init(reference: reference)
                }
                .accessibilityIdentifier("canvas-view-fixed-tool-" + node.id.uuidString)
            }
            Button { showTechnical.toggle() } label: {
                HStack {
                    Text(workflowText(languageStore, "canvas.identity.technical", fallback: "技术信息"))
                    Spacer()
                    Image(systemName: showTechnical ? "chevron.down" : "chevron.right")
                }
            }
            .buttonStyle(WorkbenchRowButtonStyle())
            .accessibilityIdentifier("canvas-technical-toggle")
            if showTechnical {
                WorkflowMetadataRow(workflowText(languageStore, "workflow.metadata.operation", fallback: "操作"),
                                    node.operationID)
                WorkflowMetadataRow(workflowText(languageStore, "workflow.metadata.definitionVersion", fallback: "定义版本"),
                                    String(node.definitionVersion))
            }
            HStack {
                Button(workflowText(languageStore, "workflow.action.copy", fallback: "复制"),
                       systemImage: "doc.on.doc") {
                    guard controller.graph?.nodes.contains(node) == true else { return }
                    controller.selectedNodeID = node.id; controller.copySelected()
                }
                Button(workflowText(languageStore, "workflow.action.delete", fallback: "删除"),
                       systemImage: "trash", role: .destructive) {
                    guard let target = controller.canvasInsertionTarget(), controller.graph?.nodes.contains(node) == true else { return }
                    controller.deleteNode(id: node.id, target: target)
                }
            }
            .disabled(readOnly)
            if controller.registry.operation(node.operationID)?.definition.interaction == .assetInput {
                Menu(workflowText(languageStore, "workflow.asset.referenceExisting", fallback: "引用项目已有素材")) {
                    ForEach(controller.availableAssets) { asset in
                        Button(asset.name + " · " + asset.mediaType) {
                            Task { await controller.bindExistingAsset(asset.id, nodeID: node.id) }
                        }
                    }
                }.disabled(readOnly || controller.availableAssets.isEmpty)
                Button(workflowText(languageStore, "workflow.asset.chooseImport", fallback: "选择导入资产"),
                       systemImage: "square.and.arrow.down") { onImport(node.id) }
                    .disabled(readOnly)
                    .accessibilityIdentifier("workflow-import-\(node.id.uuidString)")
                Button(workflowText(languageStore, "workflow.asset.record", fallback: "录制原声"), systemImage: "mic") { onRecord(node.id) }
                    .disabled(readOnly || controller.isRunning)
                    .accessibilityIdentifier("workflow-record-\(node.id.uuidString)")
            }
            if let asset = node.assetReference {
                WorkflowAssetIdentity(reference: asset)
            }
        }
    }

    @ViewBuilder
    private func parameters(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.parameters", fallback: "参数")) {
            if let definition = controller.registry.definition(for: node, tools: controller.tools) {
                if definition.fields.isEmpty {
                    Text(workflowText(languageStore, "workflow.parameters.none", fallback: "此操作没有参数。"))
                        .foregroundStyle(.secondary)
                }
                ForEach(definition.fields) { field in
                    WorkflowFieldEditor(
                        field: field,
                        operationID: node.operationID,
                        value: node.parameters[field.id] ?? field.defaultValue,
                        readOnly: readOnly,
                        modelChoices: controller.modelChoices.filter { $0.kind == definition.modelKind },
                        modelPicker: modelPicker(for: definition.modelKind),
                        onChange: { controller.setParameter(nodeID: node.id, key: field.id, value: $0) }
                    )
                }
            } else {
                Text(workflowText(
                    languageStore,
                    "workflow.parameters.unknown",
                    fallback: "未知操作或定义版本，参数保持原样且不可编辑。"
                ))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func ports(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.ports", fallback: "输入与输出")) {
            if let definition = controller.registry.definition(for: node, tools: controller.tools) {
                Text(workflowText(languageStore, "workflow.port.inputs", fallback: "输入"))
                    .font(.subheadline.weight(.semibold))
                if definition.inputs.isEmpty {
                    Text(workflowText(languageStore, "workflow.port.noInputs", fallback: "无输入"))
                        .foregroundStyle(.secondary)
                }
                ForEach(definition.inputs) { port in
                    let incoming = controller.graph?.connections.filter {
                        $0.targetNode == node.id && $0.targetPort == port.id
                    } ?? []
                    VStack(alignment: .leading, spacing: 5) {
                        Text(WorkflowCanvasPresentation.portTitle(
                            operationID: node.operationID, port: port, input: true, language: languageStore
                        )).font(.callout.weight(.medium))
                        Text(WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                            .font(.caption).foregroundStyle(.secondary)
                        if incoming.isEmpty {
                            Text(port.required
                                 ? workflowText(languageStore, "workflow.port.notConnected", fallback: "尚未连接")
                                 : workflowText(languageStore, "workflow.port.notProvided", fallback: "未提供"))
                                .font(.caption)
                                .foregroundStyle(port.required ? Color.orange : Color.secondary)
                        }
                        ForEach(incoming) { connection in
                            HStack {
                                Text(WorkflowCanvasPresentation.connectionIdentity(connection))
                                    .font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Button(workflowText(languageStore, "workflow.action.disconnect", fallback: "断开"),
                                       systemImage: "link.badge.minus") {
                                    controller.disconnect(connection.id)
                                }
                                .labelStyle(.iconOnly)
                                .disabled(readOnly)
                            }
                            WorkflowConnectionInspection(controller: controller, connection: connection)
                        }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                Text(workflowText(languageStore, "workflow.port.outputs", fallback: "输出"))
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                if definition.outputs.isEmpty {
                    Text(workflowText(languageStore, "workflow.port.noOutputs", fallback: "无输出"))
                        .foregroundStyle(.secondary)
                }
                ForEach(definition.outputs) { port in
                    HStack {
                        Text(WorkflowCanvasPresentation.portTitle(
                            operationID: node.operationID, port: port, input: false, language: languageStore
                        ))
                        Spacer()
                        Text(WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func execution(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.execution", fallback: "运行与结果")) {

            if let step = controller.presentationStep(nodeID: node.id, runID: resultRunID) {
                HStack {
                    WorkflowStatusBadge(status: step.status, stale: resultRunID == nil ? (controller.presentationStatus(for: node.id)?.stale ?? true) : controller.isStale(step))
                    Spacer()
                    Text(step.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                if let error = step.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                WorkflowStepValues(
                                   title: workflowText(languageStore, "workflow.execution.inputSnapshot", fallback: "输入快照"),
                                   values: step.inputs, operationID: node.operationID, portsAreInputs: true,
                                   controller: controller, onReturnText: onReturnText,
                                   allowsReturn: false)
                WorkflowStepValues(title: workflowText(languageStore, "workflow.port.outputs", fallback: "输出"),
                                   values: step.outputs, operationID: node.operationID, portsAreInputs: false,
                                   controller: controller, onReturnText: onReturnText,
                                   allowsReturn: !readOnly)
                if step.status == .waiting {
                    if let task = step.humanTask {
                        WorkflowHumanTaskForm(task: task, onSaveDraft: { controller.editHumanDraft(stepID: step.id, value: $0) },
                            onSubmit: { value in Task { await controller.decideHuman(stepID: step.id, value: value, expectedTask: task) } },
                            onReject: { Task { await controller.decideHuman(stepID: step.id, value: nil, reject: true, expectedTask: task) } }).id(step.id).disabled(readOnly)
                    } else {
                        WorkflowWaitingDecision(controller: controller, step: step, readOnly: readOnly, preview: controller.preview).id(step.id)
                    }
                }
                if step.status == .partial {
                    Button(workflowText(languageStore, "workflow.action.retryFailedCandidates", fallback: "重试失败候选"),
                           systemImage: "arrow.clockwise") {
                        Task { await controller.retryFailedCandidates(stepID: step.id) }
                    }
                    .disabled(readOnly)
                }
            } else {
                Text(workflowText(languageStore, "workflow.execution.noRuns", fallback: "此节点尚无运行记录。"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func history(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.history", fallback: "运行历史")) {
            let related = controller.history(for: node.id).filter { resultRunID == nil || $0.id == resultRunID }
            if related.isEmpty {
                Text(workflowText(languageStore, "workflow.history.none", fallback: "没有历史运行。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(related.reversed()) { run in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                        Spacer()
                        Text(WorkflowCanvasPresentation.statusTitle(run.status, language: languageStore))
                            .foregroundStyle(.secondary)
                    }
                    Text(run.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    ForEach(controller.callRecords(runID: run.id)) { call in
                        DisclosureGroup(call.step.node.title + " · " + WorkflowCanvasPresentation.statusTitle(call.step.status, language: languageStore)) {
                            Text(String(describing: call.address.path)).font(.caption2.monospaced()).textSelection(.enabled)
                            if controller.canRerunCall(call) {
                                Button(workflowText(languageStore, "workflow.scope.rerunCall", fallback: "重新运行具体调用")) {
                                    pendingCall = .init(address: call.address, stepID: call.step.id)
                                }.disabled(readOnly)
                            }
                            WorkflowStepValues(title: workflowText(languageStore, "workflow.port.outputs", fallback: "输出"), values: call.step.outputs, operationID: call.step.node.operationID, portsAreInputs: false, controller: controller, onReturnText: onReturnText, allowsReturn: !readOnly)
                            if call.step.id != controller.presentationStep(nodeID: node.id, runID: resultRunID)?.id, call.step.status == .waiting {
                                if let task = call.step.humanTask {
                                    WorkflowHumanTaskForm(task: task, onSaveDraft: { controller.editHumanDraft(stepID: call.id, value: $0) },
                                        onSubmit: { value in Task { await controller.decideHuman(stepID: call.id, value: value, expectedTask: task) } },
                                        onReject: { Task { await controller.decideHuman(stepID: call.id, value: nil, reject: true, expectedTask: task) } }).id(call.id).disabled(readOnly)
                                } else {
                                    WorkflowWaitingDecision(controller: controller, step: call.step, readOnly: readOnly, preview: controller.preview).id(call.id)
                                }
                            }
                        }
                    }
                    if WorkflowCanvasPresentation.canResume(run.status) {
                        Button(workflowText(languageStore, run.status == .saving ? "workflow.action.resumeSaving" : "workflow.action.resume", fallback: run.status == .saving ? "恢复保存并继续流程" : "继续流程")) {
                            Task { await controller.resume(runID: run.id) }
                        }
                            .disabled(readOnly)
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func modelPicker(for kind: WorkflowModelKind?) -> () -> Void {
        switch kind {
        case .image: onImageModel
        case .music: { onAdditionalModel(.music) }
        case .video: { onAdditionalModel(.video) }
        case .pitch: { onAdditionalModel(.pitch) }
        case .text: onTextModel
        case nil: {}
        }
    }
}

/// Inspecting a fixed tool is read-only. A separate explicit action may open an editable copy.
private struct WorkflowFixedToolSheet: View {
    let controller: WorkflowController
    let reference: WorkflowToolReference
    let onClose: () -> Void
    let onCopy: () -> Void
    @Environment(\.dLanguageStore) private var language

    private var tool: WorkflowToolDefinition? {
        WorkflowNodeIdentity.fixedTool(reference: reference, tools: controller.tools)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(workflowText(language, "baseline02.ui.label.572cf45ba436", fallback: "返回"), systemImage: "chevron.left") { onClose() }
                Text(workflowText(language, "canvas.tool.fixedTitle", fallback: "查看固定工具"))
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text("v\(reference.version) · \(reference.id.uuidString)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let tool {
                Text(tool.name).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        WorkflowInspectorSection(workflowText(language, "canvas.tool.interface", fallback: "公开端口")) {
                            if let interface = tool.graph.interface {
                                Text(workflowText(language, "workflow.port.inputs", fallback: "输入"))
                                    .font(.subheadline.weight(.semibold))
                                ForEach(interface.inputs) { input in
                                    Text(input.name + " · " + String(describing: input.type)
                                        + (input.required ? " · 必选" : " · 可选"))
                                        .font(.callout)
                                }
                                Text(workflowText(language, "workflow.port.outputs", fallback: "输出"))
                                    .font(.subheadline.weight(.semibold))
                                ForEach(interface.outputs) { output in
                                    Text(output.name + " · " + output.port + " · "
                                        + String(describing: output.schema)).font(.callout)
                                }
                            } else {
                                Text(workflowText(language, "canvas.tool.noInterface", fallback: "未声明公开端口"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        WorkflowInspectorSection(workflowText(language, "canvas.tool.nodes", fallback: "内部节点")) {
                            ForEach(tool.graph.nodes) { node in
                                let definition = controller.registry.definition(for: node, tools: controller.tools)
                                let identity = WorkflowNodeIdentity.resolve(node: node, definition: definition,
                                    modelChoices: controller.modelChoices, assets: controller.availableAssets,
                                    tools: controller.tools, language: language)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(identity.title).font(.callout.weight(.medium))
                                    Text(node.operationID).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    if let definition {
                                        Text(definition.inputs.map(\.id).joined(separator: ", ") + " → "
                                            + definition.outputs.map(\.id).joined(separator: ", "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        WorkflowInspectorSection(workflowText(language, "canvas.tool.connections", fallback: "内部连接")) {
                            if tool.graph.connections.isEmpty {
                                Text(workflowText(language, "canvas.tool.noConnections", fallback: "没有内部连接"))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(tool.graph.connections) { connection in
                                Text(connection.sourceNode.uuidString.prefix(8) + "." + connection.sourcePort
                                     + " → " + connection.targetNode.uuidString.prefix(8) + "." + connection.targetPort)
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(workflowText(language, "canvas.tool.copy", fallback: "复制为可编辑流程"), action: onCopy)
                        .disabled(!controller.canEditCanvas)
                }
            } else {
                Label(workflowText(language, "canvas.tool.unavailable", fallback: "固定工具的版本或摘要不匹配，无法查看或复制。"),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .padding(20).frame(minWidth: 620, minHeight: 500)
        .accessibilityIdentifier("canvas-fixed-tool-sheet")
    }
}

/// A rendered inspector action owns the exact graph revision and node value that produced it.
/// Re-evaluating the snapshot at invocation prevents an old SwiftUI action from replacing newer edits.
struct WorkflowVideoPresetAction: Equatable {
    let graphID: UUID
    let revision: UUID
    let node: WorkflowNode

    init?(node: WorkflowNode, graph: WorkflowGraph) {
        guard node.operationID == "d.video.generate",
              graph.nodes.first(where: { $0.id == node.id }) == node else { return nil }
        graphID = graph.id
        revision = graph.revision
        self.node = node
    }

    func replacement(in graph: WorkflowGraph, preset: WorkflowVideoPreset) -> WorkflowNode? {
        guard graph.id == graphID, graph.revision == revision,
              graph.nodes.first(where: { $0.id == node.id }) == node else { return nil }
        return preset.applying(to: node)
    }
}

private struct WorkflowFieldEditor: View {
    let field: WorkflowFieldDefinition
    let operationID: String
    let value: WorkflowScalar
    let readOnly: Bool
    let modelChoices: [WorkflowModelChoice]
    let modelPicker: () -> Void
    let onChange: (WorkflowScalar) -> Void
    @Environment(\.dLanguageStore) private var languageStore

    private var title: String {
        WorkflowCanvasPresentation.fieldTitle(operationID: operationID, field: field, language: languageStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.medium))
            if field.id == "modelID" {
                HStack {
                    Text(value.string.flatMap { $0.isEmpty ? nil : $0 }
                         ?? workflowText(languageStore, "workflow.model.notBound", fallback: "尚未绑定"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Menu(workflowText(languageStore, "workflow.action.chooseModel", fallback: "选择模型")) {
                        ForEach(modelChoices) { choice in
                            Button(choice.displayName) { onChange(.text(choice.id)) }
                        }
                        if !modelChoices.isEmpty { Divider() }
                        Button(workflowText(languageStore, "workflow.model.import", fallback: "选择本地模型文件夹…"),
                               action: modelPicker)
                    }.disabled(readOnly)
                }
            } else {
                editor
            }
        }
        .accessibilityIdentifier("workflow-field-\(field.id)")
    }

    @ViewBuilder
    private var editor: some View {
        switch field.kind {
        case .text(let multiline):
            if multiline {
                TextEditor(text: textBinding)
                    .font(.body)
                    .frame(minHeight: 72)
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                    .disabled(readOnly)
            } else {
                TextField(title, text: textBinding).disabled(readOnly)
            }
        case .integer:
            TextField(title, value: integerBinding, format: .number).disabled(readOnly)
        case .decimal:
            TextField(title, value: decimalBinding, format: .number).disabled(readOnly)
        case .flag:
            Toggle(title, isOn: flagBinding).labelsHidden().disabled(readOnly)
        case .choice(let choices):
            Picker(title, selection: textBinding) {
                ForEach(choices, id: \.self) { Text(WorkflowCanvasPresentation.choiceTitle(fieldID: field.id, value: $0, language: languageStore)).tag($0) }
            }
            .labelsHidden()
            .disabled(readOnly)
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { value.string ?? "" }, set: { onChange(.text($0)) })
    }
    private var integerBinding: Binding<Int> {
        Binding(get: { value.integer ?? 0 }, set: { onChange(.integer($0)) })
    }
    private var decimalBinding: Binding<Double> {
        Binding(get: { value.decimal ?? 0 }, set: { onChange(.decimal($0)) })
    }
    private var flagBinding: Binding<Bool> {
        Binding(get: { value.flag ?? false }, set: { onChange(.flag($0)) })
    }
}

/// Inspection only: historical input ports are explicitly distinct from current wiring.
/// Every nested call remains separate; never guess one Map item from a node UUID.
struct WorkflowConnectionSnapshot: Identifiable {
    var id: String { runID.uuidString + ":" + stepID.uuidString }
    let runID: UUID
    let revision: UUID
    let stepID: UUID
    let address: [WorkflowAddressComponent]
    let operationID: String
    let value: WorkflowValue
}
enum WorkflowConnectionPresentation {
    static func snapshots(_ connection: WorkflowConnection, graphID: UUID, runs: [WorkflowRun]) -> [WorkflowConnectionSnapshot] {
        runs.flatMap { run in
            let records = run.planCheckpoint?.records ?? run.steps.map {
                WorkflowPlanCallRecord(address: .init(runID: run.id, path: [.node($0.node.id)]), step: $0)
            }
            return records.compactMap { call -> WorkflowConnectionSnapshot? in
                let owner: WorkflowPlan?
                if let checkpoint = run.planCheckpoint {
                    owner = owningPlan(path: call.address.path, in: checkpoint.plan)
                    guard call.address.runID == run.id, owner?.graphID == graphID else { return nil }
                } else {
                    guard run.graph.id == graphID else { return nil }
                    owner = nil
                }
                guard call.step.node.id == connection.targetNode,
                      let value = call.step.inputs[connection.targetPort] else { return nil }
                return WorkflowConnectionSnapshot(runID: run.id, revision: owner?.graphRevision ?? run.graph.revision,
                    stepID: call.step.id, address: call.address.path,
                    operationID: call.step.node.operationID, value: value)
            }
        }
    }
    private static func owningPlan(path: [WorkflowAddressComponent], in root: WorkflowPlan) -> WorkflowPlan? {
        var plan = root, offset = 0
        while offset < path.count {
            guard case .node(let id) = path[offset], let step = plan.steps.first(where: { $0.id == id }) else { return nil }
            if offset == path.count - 1 { return plan }
            switch (step.kind, path[offset + 1]) {
            case let (.branch(_, yes, no), .branch(selected)): plan = selected ? yes : no
            case let (.map(body, _), .item): plan = body
            case let (.loop(body, _, _, _), .iteration): plan = body
            case let (.invoke(reference, body), .tool(selected)) where reference == selected: plan = body
            default: return nil
            }
            offset += 2
        }
        return nil
    }
    static func configuredValue(source: WorkflowNode?) -> WorkflowValue? {
        guard let source else { return nil }
        if source.operationID == "d.value.input", let value = source.dataConfiguration?.value { return .data(value) }
        if source.operationID == "d.asset.reference", let reference = source.assetReference { return .asset(reference) }
        return nil
    }
}
private struct WorkflowConnectionInspection: View {
    let controller: WorkflowController
    let connection: WorkflowConnection
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        DisclosureGroup(workflowText(language, "workflow.connection.inspect", fallback: "检查输入数据")) {
            if let value = WorkflowConnectionPresentation.configuredValue(source: controller.graph?.nodes.first {
                $0.id == connection.sourceNode
            }) {
                WorkflowStepValues(title: workflowText(language, "workflow.connection.configured", fallback: "当前源设置（尚非运行结果）"),
                    values: [connection.targetPort: value], operationID: "", portsAreInputs: true,
                    controller: controller, onReturnText: { _ in }, allowsReturn: false)
            }
            let snapshots = WorkflowConnectionPresentation.snapshots(connection, graphID: controller.graph?.id ?? UUID(), runs: controller.history(for: connection.targetNode))
            Text(workflowText(language, "workflow.connection.history", fallback: "此输入端口的历史快照；不代表当前连线"))
                .font(.caption).foregroundStyle(.secondary)
            if snapshots.isEmpty {
                Text(workflowText(language, "workflow.connection.noData", fallback: "尚无已记录数据；查看不会执行上游"))
                    .font(.caption)
            }
            ForEach(snapshots.reversed()) { snapshot in
                DisclosureGroup(snapshot.runID.uuidString.prefix(8) + " / " + snapshot.stepID.uuidString.prefix(8)) {
                    Text(workflowText(language, "workflow.connection.revision", fallback: "运行图版本") + ": " + snapshot.revision.uuidString)
                        .font(.caption2.monospaced()).textSelection(.enabled)
                    Text(String(describing: snapshot.address)).font(.caption2.monospaced()).textSelection(.enabled)
                    WorkflowStepValues(title: snapshot.stepID.uuidString, values: [connection.targetPort: snapshot.value],
                        operationID: snapshot.operationID, portsAreInputs: true, controller: controller,
                        onReturnText: { _ in }, allowsReturn: false)
                }
            }
        }.accessibilityIdentifier("workflow-connection-inspect-" + connection.id.uuidString)
    }
}

private struct WorkflowCanvasConnectionInspector: View {
    let controller: WorkflowController
    let connection: WorkflowConnection
    let onClose: () -> Void
    @Environment(\.dLanguageStore) private var language

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(workflowText(language, "baseline02.ui.label.572cf45ba436", fallback: "返回"), systemImage: "chevron.left") { onClose() }
                    Text(workflowText(language, "canvas.connection.title", fallback: "连接"))
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                if let source = controller.graph?.nodes.first(where: { $0.id == connection.sourceNode }),
                   let target = controller.graph?.nodes.first(where: { $0.id == connection.targetNode }) {
                    let sourceDefinition = controller.registry.definition(for: source, tools: controller.tools)
                    let targetDefinition = controller.registry.definition(for: target, tools: controller.tools)
                    let sourceName = WorkflowNodeIdentity.resolve(node: source, definition: sourceDefinition,
                        modelChoices: controller.modelChoices, assets: controller.availableAssets,
                        tools: controller.tools, language: language).title
                    let targetName = WorkflowNodeIdentity.resolve(node: target, definition: targetDefinition,
                        modelChoices: controller.modelChoices, assets: controller.availableAssets,
                        tools: controller.tools, language: language).title
                    Text(sourceName + " · " + connection.sourcePort)
                    Image(systemName: "arrow.down").foregroundStyle(.secondary)
                    Text(targetName + " · " + connection.targetPort)
                    if let port = sourceDefinition?.outputs.first(where: { $0.id == connection.sourcePort }) {
                        Text(WorkflowCanvasPresentation.portDetail(port, language: language))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let step = controller.latestStep(for: source.id),
                       let value = step.outputs[connection.sourcePort] {
                        Text(controller.presentationStatus(for: source.id)?.stale ?? true
                             ? workflowText(language, "canvas.connection.stale", fallback: "运行记录输出（来源版本已变化）")
                             : workflowText(language, "canvas.connection.saved", fallback: "运行记录输出"))
                            .font(.caption).foregroundStyle(.secondary)
                        WorkflowStepValues(title: connection.sourcePort,
                            values: [connection.sourcePort: value], operationID: source.operationID,
                            portsAreInputs: false, controller: controller,
                            onReturnText: { _ in }, allowsReturn: false)
                    } else {
                        Text(workflowText(language, "canvas.connection.notRun", fallback: "未运行：没有已保存的来源输出"))
                            .foregroundStyle(.secondary)
                    }
                }
                Button(workflowText(language, "workflow.action.disconnect", fallback: "断开"),
                       systemImage: "link.badge.minus", role: .destructive) {
                    controller.disconnect(connection.id)
                    onClose()
                }
                .disabled(!controller.canEditCanvas)
                .accessibilityIdentifier("canvas-disconnect-" + connection.id.uuidString)
                WorkflowConnectionInspection(controller: controller, connection: connection)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("canvas-connection-inspector")
    }
}

private struct WorkflowStepValues: View {
    let title: String
    let values: [String: WorkflowValue]
    let operationID: String
    let portsAreInputs: Bool
    let controller: WorkflowController
    let onReturnText: (WorkflowAssetReference) -> Void
    let allowsReturn: Bool
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if values.isEmpty {
                Text(workflowText(languageStore, "workflow.value.none", fallback: "无"))
                    .foregroundStyle(.secondary)
            }
            ForEach(values.keys.sorted(), id: \.self) { port in
                if let value = values[port] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(WorkflowCanvasPresentation.portTitle(
                            operationID: operationID,
                            portID: port,
                            fallback: port,
                            input: portsAreInputs,
                            language: languageStore
                        )).font(.caption.monospaced()).foregroundStyle(.secondary)
                        switch value {
                        case .asset(let reference):
                            WorkflowAssetPreview(controller: controller, reference: reference)
                            WorkflowAssetIdentity(reference: reference)
                            if reference.kind == .text && allowsReturn {
                                Button(workflowText(languageStore, "workflow.action.returnToText", fallback: "回到文稿"),
                                       systemImage: "arrowshape.turn.up.backward") {
                                    onReturnText(reference)
                                }
                            }
                        case .collection(let candidates):
                            ForEach(candidates) { candidate in
                                WorkflowCandidatePreview(controller: controller, candidate: candidate,
                                                         selected: false, onSelect: nil)
                            }
                        case .data(let value):
                            WorkflowDatumSnapshotView(value: value)
                        case .receipt(let receipt):
                            Text(receipt.names.joined(separator: "、"))
                            Text(receipt.hashes.joined(separator: "\n"))
                                .font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

struct WorkflowAssetPreview: View {
    let controller: WorkflowController
    let reference: WorkflowAssetReference
    @State private var data: Data?
    @State private var failure: String?
    @State private var sourceMetadata: String?
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        Group {
            switch reference.kind {
            case .text:
                if let data {
                    if let text = String(data: data, encoding: .utf8) {
                        ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 150)
                    } else {
                        previewError(workflowText(
                            languageStore,
                            "workflow.preview.invalidText",
                            fallback: "文字预览不是有效的 UTF-8。"
                        ))
                    }
                } else if let failure { previewError(failure) } else { ProgressView() }
            case .image:
                if let data {
                    if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                    } else {
                        previewError(workflowText(
                            languageStore,
                            "workflow.preview.invalidImage",
                            fallback: "图像预览无法解码。"
                        ))
                    }
                } else if let failure { previewError(failure) } else { ProgressView() }
            case .audio, .video:
                Button(workflowText(languageStore, "workflow.preview.playMedia", fallback: "打开播放预览"), systemImage: "play.circle") {
                    controller.mediaPreviewReference = reference
                }
            default:
                Text(workflowText(
                    languageStore,
                    "workflow.preview.unsupported",
                    fallback: "此引用不能作为单项预览。"
                )).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let sourceMetadata {
                DisclosureGroup(workflowText(
                    languageStore,
                    "workflow.preview.provenance",
                    fallback: "来源与实际执行参数（本地记录）"
                )) {
                    ScrollView { Text(sourceMetadata).font(.caption2.monospaced()).textSelection(.enabled) }
                        .frame(maxHeight: 180)
                }
            }
        }
        .task(id: reference.version) {
            data = nil
            failure = nil
            do {
                let bytes = [.audio, .video].contains(reference.kind) ? nil : try await controller.preview(reference)
                let metadata = try await controller.metadata(reference)
                try Task.checkCancellation()
                data = bytes; sourceMetadata = metadata
                failure = nil
            } catch {
                data = nil
                failure = error.localizedDescription
            }
        }
    }

    private func previewError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
    }
}

private struct WorkflowCandidatePreview: View {
    let controller: WorkflowController
    let candidate: WorkflowCandidate
    let selected: Bool
    let onSelect: (() -> Void)?
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        Button {
            onSelect?()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let asset = candidate.asset {
                    WorkflowAssetPreview(controller: controller, reference: asset)
                }
                HStack {
                    Text(workflowText(
                        languageStore,
                        "workflow.candidate.seed",
                        fallback: "seed {seed}",
                        arguments: ["seed": candidate.seed]
                    )).font(.caption.monospaced())
                    Spacer()
                    if selected {
                        Label(workflowText(languageStore, "workflow.candidate.highlighted", fallback: "已高亮"),
                              systemImage: "checkmark.circle.fill")
                    }
                }
                if let error = candidate.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .padding(7)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(onSelect == nil)
    }
}

struct WorkflowWaitingDecision: View {
    let controller: WorkflowController
    let step: WorkflowStepRun
    let readOnly: Bool
    let preview: @MainActor (WorkflowAssetReference) async throws -> Data
    @State private var draft = ""
    @State private var highlightedCandidateID: UUID?
    @State private var acceptPartial = false
    @State private var loadedReference: WorkflowAssetReference?
    @Environment(\.dLanguageStore) private var languageStore

    private var candidates: [WorkflowCandidate] {
        step.outputs.values.flatMap(\.candidates)
    }

    private var textReference: WorkflowAssetReference? {
        step.outputs.values.compactMap(\.asset).first { $0.kind == .text }
    }

    private var textReady: Bool { textReference != nil && loadedReference == textReference }
    private var decisionDisabled: Bool { readOnly || controller.isRunning }
    private var interaction: WorkflowInteraction {
        controller.registry.operation(step.node.operationID)?.definition.interaction ?? .none
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(workflowText(languageStore, "workflow.decision.title", fallback: "等待人工决定"))
                .font(.headline)
            if interaction == .textReview {
                TextSourcesQuestionEditor(value: draft, editEpoch: 0,
                    isEditable: !readOnly && textReady,
                    accessibilityIdentifier: "workflow-review-text") { value in
                        guard !readOnly && textReady else { return }
                        draft = value
                        controller.editReviewText(stepID: step.id, text: value)
                    }
                    .frame(minHeight: 100)
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                    .task(id: textReference?.version) { await loadDraft() }
                HStack {
                    Button(workflowText(languageStore, "workflow.action.acceptText", fallback: "接受文字")) {
                        decide(accept: true, text: draft, candidateID: nil)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!textReady)
                    Button(workflowText(languageStore, "workflow.action.reject", fallback: "拒绝"), role: .destructive) {
                        decide(accept: false, text: nil, candidateID: nil)
                    }
                }
                .disabled(decisionDisabled)
            } else if interaction == .candidateReview {
                ForEach(candidates) { candidate in
                    WorkflowCandidatePreview(
                        controller: controller,
                        candidate: candidate,
                        selected: highlightedCandidateID == candidate.id,
                        onSelect: { highlightedCandidateID = candidate.id }
                    )
                }
                if candidates.contains(where: { $0.error != nil }) {
                    Toggle(workflowText(
                        languageStore,
                        "workflow.decision.acceptPartial",
                        fallback: "接受部分成功的候选"
                    ), isOn: $acceptPartial).disabled(readOnly)
                }
                HStack {
                    Button(workflowText(languageStore, "workflow.action.acceptHighlighted", fallback: "采用高亮候选")) {
                        decide(accept: true, text: nil, candidateID: highlightedCandidateID)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(readOnly || highlightedCandidateID == nil ||
                              (candidates.contains { $0.error != nil } && !acceptPartial))
                    Button(workflowText(languageStore, "workflow.action.reject", fallback: "拒绝"), role: .destructive) {
                        decide(accept: false, text: nil, candidateID: nil)
                    }
                        .disabled(readOnly)
                }
            } else {
                Text(workflowText(
                    languageStore,
                    "workflow.decision.explicit",
                    fallback: "此步骤等待明确决定。"
                )).foregroundStyle(.secondary)
                Button(workflowText(languageStore, "workflow.action.reject", fallback: "拒绝"), role: .destructive) {
                    decide(accept: false, text: nil, candidateID: nil)
                }
                    .disabled(readOnly)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func loadDraft() async {
        guard let reference = textReference, loadedReference != reference else { return }
        do {
            if let saved = step.reviewTextDraft {
                draft = saved
            } else {
                let data = try await preview(reference)
                try Task.checkCancellation()
                guard let text = String(data: data, encoding: .utf8) else {
                    throw WorkflowIssue(workflowText(
                        languageStore,
                        "workflow.decision.invalidText",
                        fallback: "确认文字不是有效 UTF-8。"
                    ))
                }
                draft = text
            }
            loadedReference = reference
        } catch is CancellationError {
            // A removed waiting editor must not write its late load into another selection.
        } catch {
            controller.errorMessage = error.localizedDescription
        }
    }

    private func decide(accept: Bool, text: String?, candidateID: UUID?) {
        guard !decisionDisabled, !accept || interaction != .textReview || textReady else { return }
        Task {
            await controller.decide(stepID: step.id, accept: accept, text: text,
                                    candidateID: candidateID, acceptPartial: acceptPartial)
        }
    }
}

private struct WorkflowRunPlanSheet: View {
    let preview: WorkflowRunPreview
    let readOnly: Bool
    let onCancel: () -> Void
    let onRun: () -> Void
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(workflowText(languageStore, "baseline02.ui.label.572cf45ba436", fallback: "返回"), systemImage: "chevron.left", action: onCancel)
            Text(preview.only
                 ? workflowText(languageStore, "workflow.plan.rerunTitle", fallback: "确认仅重跑本步")
                 : workflowText(languageStore, "workflow.plan.runTitle", fallback: "确认运行到这里"))
                .font(.title2.weight(.semibold))
            Text(workflowText(
                languageStore,
                "workflow.plan.description",
                fallback: "以下计划由运行协调器提供；界面原样显示，不推断或改写执行、复用与等待状态。"
            ))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let lines = WorkflowCanvasPresentation.planLines(preview.lines)
                    if lines.isEmpty {
                        Text(workflowText(languageStore, "workflow.plan.empty", fallback: "计划为空"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top) {
                            Text("\(index + 1).").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                            Text(line).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(workflowText(languageStore, "workflow.action.cancel", fallback: "取消"), action: onCancel)
                Button(workflowText(languageStore, "workflow.plan.submit", fallback: "明确提交运行"), action: onRun)
                    .buttonStyle(.borderedProminent)
                    .disabled(readOnly)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 360)
        .interactiveDismissDisabled(false)
        .accessibilityIdentifier("workflow-run-plan")
    }
}

private struct WorkflowInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct WorkflowMetadataRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}

private struct WorkflowAssetIdentity: View {
    let reference: WorkflowAssetReference
    @Environment(\.dLanguageStore) private var languageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WorkflowMetadataRow(workflowText(languageStore, "workflow.metadata.type", fallback: "类型"),
                                WorkflowCanvasPresentation.kind(reference.kind, language: languageStore))
            WorkflowMetadataRow(workflowText(languageStore, "workflow.metadata.asset", fallback: "资产"),
                                reference.assetID.uuidString)
            WorkflowMetadataRow(workflowText(languageStore, "workflow.metadata.version", fallback: "版本"),
                                reference.version.uuidString)
            WorkflowMetadataRow("SHA-256", reference.sha256)
        }
    }
}

struct WorkflowStatusBadge: View {
    let status: WorkflowStepStatus
    let stale: Bool
    @Environment(\.dLanguageStore) private var languageStore
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(WorkflowCanvasPresentation.statusColor(status)).frame(width: 7, height: 7)
            Text(WorkflowCanvasPresentation.statusTitle(status, language: languageStore))
            if stale {
                Text(workflowText(languageStore, "workflow.status.staleInput", fallback: "旧输入"))
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

private enum WorkflowExampleChoice: String, CaseIterable, Identifiable {
    case text, image, file, template
    var id: String { rawValue }
    @MainActor func title(_ language: UILanguageStore?) -> String {
        switch self {
        case .text: workflowText(language, "workflow.example.text", fallback: "文字")
        case .image: workflowText(language, "workflow.example.image", fallback: "图文")
        case .file: workflowText(language, "workflow.example.file", fallback: "文件")
        case .template: workflowText(language, "workflow.example.template", fallback: "模板")
        }
    }
}

struct WorkflowPendingConnection: Equatable {
    let nodeID: UUID
    let port: String
    var input: Bool = false
}

/// A small, view-owned target: inspection never changes it, and it is never serialized.
struct WorkflowRunTarget: Equatable {
    struct Context: Equatable {
        let owner: ObjectIdentifier
        let project: UUID?
        let instance: UUID?
        let root: UUID?
        let graph: UUID?
        let path: [WorkflowBodyLocation]
        @MainActor init(_ controller: WorkflowController) {
            owner = ObjectIdentifier(controller); project = controller.projectID; instance = controller.projectInstanceID
            root = controller.rootGraph?.id; graph = controller.graph?.id; path = controller.bodyPath
        }
    }
    let context: Context
    let nodeID: UUID
    @MainActor func isCurrent(in controller: WorkflowController) -> Bool {
        context == Context(controller) && controller.graph?.nodes.contains { $0.id == nodeID } == true
    }
}

struct WorkflowRunPreview: Identifiable {
    let id = UUID()
    let target: WorkflowRunTarget
    let only: Bool
    let lines: [String]
    let graph: WorkflowGraph?
    let tools: [WorkflowToolDefinition]
    let defaults: [String: String]
    var nodeID: UUID { target.nodeID }
    @MainActor init(controller: WorkflowController, nodeID: UUID, only: Bool, lines: [String]) {
        target = .init(context: .init(controller), nodeID: nodeID); self.only = only; self.lines = lines
        graph = controller.rootGraph; tools = controller.tools; defaults = controller.services.capturedModelDefaults()
    }
    @MainActor func isCurrent(in controller: WorkflowController) -> Bool {
        target.isCurrent(in: controller) && graph == controller.rootGraph && tools == controller.tools
            && defaults == controller.services.capturedModelDefaults() && controller.canEditCanvas
            && (try? controller.plan(target: nodeID, only: only)) == lines
    }
}

enum WorkflowObjectSelection {
    static func nodes(in graph: WorkflowGraph?, single: UUID?, multiple: Set<UUID>, connection: UUID?) -> [WorkflowNode] {
        guard connection == nil, let graph else { return [] }
        let many = graph.nodes.filter { multiple.contains($0.id) }
        if !many.isEmpty { return many }
        if let selected = graph.nodes.first(where: { $0.id == single }) { return [selected] }
        return many
    }
}

public enum WorkflowCanvasLibraryMode: Hashable { case nodes, assets, results }

enum WorkflowCanvasLayoutPolicy {
    static let minimumVisibleWidth: CGFloat = 760
    static let minimumVisibleHeight: CGFloat = 500
    static let minimumWorkspaceWidth: CGFloat = 760
    static let libraryWidth: CGFloat = WorkbenchSidebarLayout.trailingWidth
    static let inspectorWidth: CGFloat = WorkbenchSidebarLayout.leadingWidth
    static let canvasMinimumWidth: CGFloat = 260
    static let nodeWidth: CGFloat = 240
    static let zoomRange: ClosedRange<CGFloat> = 0.05...1.8

    static func usesHorizontalPanelScroll(width: CGFloat) -> Bool { false }

    static func visiblePanels(width: CGFloat, library: Bool, inspector: Bool,
                              preferLibrary: Bool) -> (library: Bool, inspector: Bool) {
        let bothFit = width >= libraryWidth + inspectorWidth + 440 + 2
        let left = library && (bothFit || preferLibrary || !inspector)
        return (left, inspector && (bothFit || !left))
    }

    static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, value))
    }

    static func clampedInteractiveZoom(_ value: CGFloat, current: CGFloat) -> CGFloat {
        guard value.isFinite else { return current }
        return min(zoomRange.upperBound, max(min(zoomRange.lowerBound, current), value))
    }

    static func sliderZoomRange(current: CGFloat) -> ClosedRange<CGFloat> {
        min(zoomRange.lowerBound, current)...zoomRange.upperBound
    }

    static func restoredZoom(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return min(zoomRange.upperBound, value)
    }

    static func fallbackPosition(index: Int) -> CGPoint {
        CGPoint(x: 170 + CGFloat(index % 4) * 300,
                y: 130 + CGFloat(index / 4) * 250)
    }
}

enum WorkflowCanvasPresentation {
    static func allowsMutation(readOnlyReason: String?) -> Bool { readOnlyReason == nil }

    /// Plan output is an opaque controller-owned display value. Never classify or parse it here.
    static func planLines(_ lines: [String]) -> [String] { lines }

    static func kind(_ kind: WorkflowDataKind) -> String {
        switch kind { case .text: "文字"; case .image: "图像"; case .images: "图像集合"; case .receipt: "导出回执"; default: kind.rawValue }
    }

    @MainActor static func kind(_ kind: WorkflowDataKind, language: UILanguageStore?) -> String {
        workflowText(language, "workflow.kind.\(kind.rawValue)", fallback: self.kind(kind))
    }

    static func portDetail(_ port: WorkflowPortDefinition) -> String {
        "\(port.kinds.map { kind($0) }.joined(separator: "/")) · \(port.required ? "必选" : "可选")"
    }

    @MainActor static func portDetail(_ port: WorkflowPortDefinition, language: UILanguageStore?) -> String {
        let kinds = port.kinds.map { kind($0, language: language) }.joined(separator: "/")
        let requirement = port.required
            ? workflowText(language, "workflow.port.required", fallback: "必选")
            : workflowText(language, "workflow.port.optional", fallback: "可选")
        return workflowText(
            language,
            "workflow.port.detail",
            fallback: "{kinds} · {requirement}",
            arguments: ["kinds": kinds, "requirement": requirement]
        )
    }

    @MainActor static func operationTitle(
        _ definition: WorkflowOperationDefinition,
        language: UILanguageStore?
    ) -> String {
        if definition.modelKind != nil, definition.id != "d.model.language" { return definition.title }
        return workflowText(language, "workflow.operation.\(definition.id).title", fallback: definition.title)
    }

    @MainActor static func operationDetail(
        _ definition: WorkflowOperationDefinition,
        language: UILanguageStore?
    ) -> String {
        workflowText(language, "workflow.operation.\(definition.id).detail", fallback: definition.detail)
    }

    @MainActor static func choiceTitle(fieldID: String, value: String, language: UILanguageStore?) -> String {
        guard fieldID == "loadingStrategy" else { return value }
        let fallback: String
        switch value {
        case "resident": fallback = "常驻内存（精度不变）"
        case "staged": fallback = "分阶段加载（精度不变）"
        case "ssdLayered": fallback = "省内存（SSD 分层加载，精度不变）"
        default: return value
        }
        return workflowText(language, "workflow.loading." + value, fallback: fallback)
    }

    @MainActor static func fieldTitle(
        operationID: String,
        field: WorkflowFieldDefinition,
        language: UILanguageStore?
    ) -> String {
        workflowText(language, "workflow.operation.\(operationID).field.\(field.id)", fallback: field.title)
    }

    @MainActor static func portTitle(
        operationID: String,
        port: WorkflowPortDefinition,
        input: Bool,
        language: UILanguageStore?
    ) -> String {
        portTitle(operationID: operationID, portID: port.id, fallback: port.title,
                  input: input, language: language)
    }

    @MainActor static func portTitle(
        operationID: String,
        portID: String,
        fallback: String,
        input: Bool,
        language: UILanguageStore?
    ) -> String {
        let direction = input ? "input" : "output"
        return workflowText(
            language,
            "workflow.operation.\(operationID).\(direction).\(portID)",
            fallback: fallback
        )
    }

    @MainActor static func statusTitle(_ status: WorkflowStepStatus, language: UILanguageStore?) -> String {
        workflowText(language, "workflow.stepStatus.\(status.rawValue)", fallback: status.title)
    }

    static func connectionIdentity(_ connection: WorkflowConnection) -> String {
        "\(connection.sourceNode.uuidString.prefix(8)).\(connection.sourcePort)"
    }

    static func canResume(_ status: WorkflowStepStatus) -> Bool {
        [.waiting, .interrupted, .saving, .partial, .failed].contains(status)
    }

    static func statusColor(_ status: WorkflowStepStatus) -> Color {
        switch status {
        case .completed: .green
        case .running, .saving: .blue
        case .waiting, .partial: .orange
        case .failed, .rejected: .red
        case .cancelling, .cancelled, .interrupted: .secondary
        case .queued: .gray
        }
    }
}
