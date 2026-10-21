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
    fallback: String = "",
    arguments: [String: String] = [:]
) -> String {
    let language = store ?? WorkflowLanguageDefaults.chinese
    return language.text(key, fallback: language.sourceFallback(key, fallback: fallback.isEmpty ? "—" : fallback), arguments: arguments)
}

@MainActor private enum WorkflowLanguageDefaults { static let chinese = UILanguageStore(preferredLanguages: ["zh-Hans"]) }

// These are display-only projections of the two existing terminal-failure
// messages. Unknown progress and the diagnostic payload remain unchanged.
@MainActor
func workflowRecoveryProgressText(_ value: String, language: UILanguageStore?) -> String {
    let key: String
    switch value {
    case "计算已失败，失败记录尚未保存；请重试保存记录。": key = "workflow.failureRecord.pending"
    case "失败记录已保存；流程仍失败。需要重新计算时，请明确重试计算。": key = "workflow.failureRecord.saved"
    default: return value
    }
    return workflowText(language, key, fallback: value)
}

@MainActor
func workflowRecoveryErrorText(_ value: String, runs: [WorkflowRun], language: UILanguageStore?) -> String {
    let separator = "\n失败记录保存错误："
    let bytes = Array(value.utf8)
    let boundaries = Set(runs.compactMap { run -> Int? in
        guard run.status == .saving || run.status == .failed,
              let checkpoint = run.planCheckpoint, checkpoint.runID == run.id,
              let recordedError = checkpoint.error, recordedError.utf8.elementsEqual(bytes),
              let record = checkpoint.records.last(where: { $0.address.path.count == 1 && $0.step.status == .failed }),
              record.address.runID == run.id, let primary = record.step.error,
              bytes.starts(with: (primary + separator).utf8) else { return nil }
        return primary.utf8.count
    })
    // No inferred delimiter: verify it against the stored primary diagnostic and
    // exact run/checkpoint identity. Ambiguous histories remain unmodified.
    guard boundaries.count == 1, let boundary = boundaries.first else { return value }
    let title = workflowText(language, "workflow.failureRecord.saveError")
    return String(decoding: bytes.prefix(boundary), as: UTF8.self) + "\n" + title
        + String(decoding: bytes.dropFirst(boundary + separator.utf8.count), as: UTF8.self)
}

/// Native presentation for editable workflow graphs. Persistence and execution remain owned by
/// ``WorkflowController``; this view never reads files or starts inference directly.
@MainActor
public struct WorkflowCanvasView: View {
    private let controller: WorkflowController
    private let nodeTags: ModelNodeTagStore
    private let metadata: SharedLibraryStore?
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
    private let captureControls: AnyView
    private var nodeSizeObserver: ((UUID, CGSize) -> Void)?
    private var portCenterObserver: (([WorkflowPortIdentity: CGPoint]) -> Void)?
    private var viewportLockObserver: ((Bool) -> Void)?
    private var scrollObserver: ((WorkflowCanvasViewContext, WorkflowCanvasScrollObservation) -> Void)?

    #if DEBUG
    /// Seeds the production page state for offscreen layout fixtures. This does
    /// not claim a tab click; normal selection/Undo never becomes navigation.
    func startingPanels(_ panels: WorkflowWorkspacePanels) -> Self {
        var copy = self; copy._panelsState = State(initialValue: panels); copy._activityVisible = State(initialValue: panels.runID != nil); return copy
    }
    #endif

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

    #if DEBUG
    func testingOverlayState(_ state: WorkbenchSidebarState) -> Self {
        var copy = self; copy._overlayState = State(initialValue: state); return copy
    }
    #endif

    @Environment(\.dLanguageStore) private var languageStore

    @Environment(\.chatDisplayPreferences) private var displayPreferences
    @State private var narrowLibrary = false
    @State private var requestedPanelWidths = WorkbenchPanelWidths(leading: 320, trailing: 320)
    @State private var consoleHeight: CGFloat = 88
    @State private var overlayState = WorkbenchSidebarState(leading: true, trailing: true)
    private var showLibrary: Bool { get { overlayState.trailing } nonmutating set { overlayState.trailing = newValue } }
    @Environment(\.workflowViewerModel) private var viewerModel
    @State private var resourceCategory:WorkflowResourceCategory = .all
    @State private var planInputLabels:[UUID:String]=[:]
    @State private var visitedResources:Set<WorkflowResourceCategory>=[.all]
    @State private var resourceContext:WorkflowLibraryContext?
    @State private var returnResourceCategory: WorkflowResourceCategory?
    @State private var activityVisible=false
    @State private var workspaceDraft:WorkflowWorkspaceRunDraft?
    @State private var pendingHistoryRetry:WorkflowCallReference?
    @State private var panelsState = WorkflowWorkspacePanels()
    @State private var visitedPreparation: Set<WorkflowWorkspacePanels.Preparation> = [.models]
    @State private var visitedOutput: Set<WorkflowWorkspacePanels.Output> = [.overview]
    private var showInspector: Bool { get { overlayState.leading } nonmutating set { overlayState.leading = newValue } }
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
    @State private var runRange = 0
    @State private var scopePresentation: WorkflowScopePresentation?
    @State private var extractSelection = false
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
        metadata: SharedLibraryStore? = nil,
        onImportAsset: @escaping () -> Void = {},
        onDropFile: @escaping (URL) -> Bool = { _ in false },
        onQuickUse: ((WorkflowNode) -> Void)? = nil,
        libraryContent: ((WorkflowCanvasLibraryMode, CGPoint, @escaping () -> Void) -> AnyView)? = nil,
        onSharedAssetDrop: ((UUID, UUID?, UUID, CGPoint, WorkflowCanvasInsertionTarget) -> Bool)? = nil,
        acceptsLegacyAsset: ((UUID, UUID) -> Bool)? = nil,
        captureControls: AnyView = AnyView(EmptyView())
    ) {
        self.controller = controller
        self.captureControls = captureControls
        self.nodeTags = nodeTags ?? ModelNodeTagStore()
        self.metadata = metadata
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
        let _ = WorkflowCanvasUpdateProbe.workspace?(.init(draftTarget:workspaceDraft?.target,open:{id,mode in setRunTarget(id);runRange=mode;presentWorkspacePlan(id,mode:mode)},target:setRunTarget,range:setRunRange))
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
        .focusable()
        .workflowKeyboardCommands(performKeyboardCommand)
        .environment(\.workbenchMenuContext, "canvas:\(ObjectIdentifier(controller)):\(controller.projectID):\(controller.projectInstanceID):\(controller.bodyPath):\(controller.rootGraph?.revision.uuidString ?? "none"):\(controller.rootGraph?.id.uuidString ?? "none"):\(controller.graph?.id.uuidString ?? "none"):\(controller.graph?.revision.uuidString ?? "none")")
        .alert(text("workflow.scope.rerunCall","重新运行具体调用"),isPresented:Binding(get:{pendingHistoryRetry != nil},set:{if !$0 { pendingHistoryRetry=nil }})) {
            Button(workspaceText(languageStore, "retryFrozen")) {
                if let call=pendingHistoryRetry { pendingHistoryRetry=nil;Task { await controller.rerunCall(call) } }
            }
            Button(workspaceText(languageStore, "cancel"),role:.cancel) { pendingHistoryRetry=nil }
        } message: { Text(workspaceText(languageStore, "retryHistoryExplanation")) }
        .sheet(isPresented: $toolsPresented) {
            VStack(alignment: .leading) {
                Button(workflowText(languageStore, "baseline02.ui.label.572cf45ba436"), systemImage: "chevron.left") { toolsPresented = false }.padding([.top, .leading])
                WorkflowToolPanel(controller: controller, selectionOnly: extractSelection)
            }.workbenchPresentation()
        }
        .sheet(isPresented: $interfacePresented) {
            if let graph = controller.graph {
                VStack(alignment: .leading) {
                    Button(workflowText(languageStore, "baseline02.ui.label.572cf45ba436"), systemImage: "chevron.left") { interfacePresented = false }.padding([.top, .leading])
                    WorkbenchScrollView { WorkflowGraphInterfaceEditor(graph: Binding(get: { controller.graph?.id == graph.id ? controller.graph! : graph }, set: { controller.updateInterface($0.interface, in: graph.id) }), registry: controller.registry, tools: controller.tools).padding() }
                }
                    .frame(minWidth: 640, minHeight: 500).workbenchPresentation()
            }
        }
        .onChange(of: controller.graph?.id) { _, _ in
            pendingConnection = nil
            selectedConnectionID = nil
            runPreview = nil
        }
        .onChange(of: runContext) { _, _ in
            runTarget = nil; runPreview = nil; scopePresentation = nil
        }
        .onChange(of: ObjectIdentifier(controller)) { _, _ in panelsState = .init(); workspaceDraft=nil;resourceContext=nil;returnResourceCategory=nil }
        .onChange(of: panelsState.preparation) { _, tab in visitedPreparation.insert(tab) }
        .onChange(of: panelsState.output) { _, tab in visitedOutput.insert(tab) }
        .onChange(of: resourceCategory) { _,tab in visitedResources.insert(tab) }
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

    private func performKeyboardCommand(_ command: WorkflowKeyboardCommand) -> Bool {
        guard !toolsPresented, !interfacePresented else { return false }
        switch command {
        case .leftTools:
            let tabs = WorkflowWorkspacePanels.Preparation.allCases
            panelsState.selectPreparation(tabs[((tabs.firstIndex(of: panelsState.preparation) ?? 0) + 1) % tabs.count]); showInspector = true
        case .rightTools:
            let tabs = WorkflowResourceCategory.allCases
            resourceCategory = tabs[((tabs.firstIndex(of: resourceCategory) ?? 0) + 1) % tabs.count]; showLibrary = true
        case .activity: panelsState.output = .overview; activityVisible = true; workspaceDraft = nil
        case .pointer: guard !viewportInteractionLocked else { return false }; canvasTool = .pointer
        case .hand: guard !viewportInteractionLocked else { return false }; canvasTool = .hand
        case .undo: guard controller.canEditCanvas, controller.canUndo else { return false }; controller.undo()
        case .redo: guard controller.canEditCanvas, controller.canRedo else { return false }; controller.redo()
        case .showAll:
            guard let canvasViewport, !viewportInteractionLocked else { return false }
            fitAllNodes(targetWidth: canvasViewport.clip.width)
        case .runCheck:
            guard controller.canEditCanvas, let target = validRunTarget else { return false }
            presentWorkspacePlan(target.id, mode: runRange)
        case .search, .tags, .preview: return false
        }
        return true
    }

    private func revealInspector() {
        showInspector = true
        narrowLibrary = false
        panelsState.selectPreparation(.configuration)
    }

    private func panels(height: CGFloat, width: CGFloat) -> some View {
        let shown = WorkflowCanvasLayoutPolicy.visiblePanels(width: width, library: showLibrary,
            inspector: showInspector, preferLibrary: narrowLibrary)
        let panelWidths = WorkbenchPanelWidths(leading: min(requestedPanelWidths.leading, max(260, width - 64)),
            trailing: min(requestedPanelWidths.trailing, max(260, width - 64)))
        let targetCanvasWidth = max(1, width - 32) // Sidebars cover this fixed workspace; they never reserve canvas space.
        let fitReady = canvasViewport?.permitsFit(targetWidth: targetCanvasWidth) == true
        let inspectedNodeID = shown.inspector && panelsState.preparation == .configuration
            && selectedNodes.count == 1 ? selectedNodes.first?.id : nil
        return ZStack(alignment: .bottom) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                WorkflowGraphSurface(controller: controller, graph: controller.graph, zoom: $zoom,
                    tool: $canvasTool,
                    navigationRequest: $navigationRequest,
                    viewportInteractionLocked: $viewportInteractionLocked,
                    viewContext: viewContext,
                    pendingConnection: $pendingConnection, selectedConnectionID: $selectedConnectionID,
                    readOnly: !controller.canEditCanvas,
                    inspectedNodeID: inspectedNodeID, runTargetNodeID: validRunTarget?.id,
                    planMarks: currentPlanMarks,
                    onPlan: presentPlan, onSetRunTarget: setRunTarget,
                    onPlanRange: { id, mode in
                        guard let graph = controller.rootGraph, controller.bodyPath.isEmpty, !isReadOnly else { return }
                        setRunTarget(id); runRange = mode; presentWorkspacePlan(id,mode:mode)
                    }, onViewResults: { id in
                        guard let node=controller.graph?.nodes.first(where:{$0.id == id}) else { return }
                        revealLibrary(.init(controller: controller, source: .node(id), name: node.title))
                    }, nodeSizeObserver: { id, size in
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
                        controller.selectedNodeIDs = []; controller.selectedNodeID = id; selectedConnectionID = nil
                        panelsState.inspect(id); showInspector = true; narrowLibrary = false
                    }, onClearSelection: { panelsState.clearSelection() })

                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(width: targetCanvasWidth)
                    .workbenchMeasureLayout("workflow-center")
                .transaction { $0.animation = nil }
                    .frame(maxWidth: .infinity).clipped()
                WorkbenchSidebar(leading: true, expanded: shown.inspector,
                    title: workspaceText(languageStore, "operations"), identifier: "canvas-inspector-toggle",
                    hostIdentifier: "canvas-inspector-host", toggle: {
                        showInspector = !shown.inspector; narrowLibrary = false
                    }) { preparationPanel }
                    .overlay(alignment: .trailing) { if shown.inspector { panelResizeHandle(leading: true) } }
                    .frame(width: shown.inspector ? panelWidths.leading : 48, alignment: .leading)
                    // The sidebar clips its own content; this layout slot must
                    // neither crop the glass shadow nor animate across the button.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.bottom, consoleHeight + 24)
                WorkbenchSidebar(leading: false, expanded: shown.library,
                    title: workspaceText(languageStore, "resources"), identifier: "canvas-library-toggle",
                    hostIdentifier: "canvas-library-host", toggle: {
                        showLibrary = !shown.library; narrowLibrary = true
                    }) { resourcePanel }
                    .overlay(alignment: .leading) { if shown.library { panelResizeHandle(leading: false) } }
                    .frame(width: shown.library ? panelWidths.trailing : 48, alignment: .trailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.bottom, consoleHeight + 24)
            }
            .padding(.horizontal, 16)
            VStack(spacing:8) {
                if let draft=workspaceDraft {
                    WorkflowWorkspaceRunPlan(controller:controller,draft:draft,close:{workspaceDraft=nil},inputsChanged:{planInputLabels=$0},preview: { value, call, title, port in openValue(value, call, title, port: port) })
                        .frame(height:min(440,max(240,height*0.58))).workbenchPanel(cornerRadius:18)
                } else if activityVisible {
                    outputPanel.frame(height:min(420,max(230,height*0.55))).workbenchPanel(cornerRadius:18)
                }
                VStack(spacing:4) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            canvasTools(fitReady: fitReady, targetWidth: targetCanvasWidth).fixedSize(horizontal: true, vertical: false)
                            Divider().frame(height: 28)
                            executionBar.fixedSize(horizontal: true, vertical: false)
                            activityToggle.fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(spacing: 6) {
                            HStack { canvasTools(fitReady: fitReady, targetWidth: targetCanvasWidth); activityToggle }
                            executionBar
                        }
                    }
                    if controller.errorMessage != nil || controller.readOnlyReason != nil { statusStrip }
                    captureControls
                }.padding(8).workbenchPanel(cornerRadius:22)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { value in
                        if abs(consoleHeight - value) > 0.5 { consoleHeight = value }
                    }
            }.padding(.horizontal,16).padding(.bottom,12)
        }.padding(.top, 8).environment(\.workbenchPanelWidths, panelWidths)
    }

    private func panelResizeHandle(leading: Bool) -> some View {
        WorkflowPanelResizeHandle(width: Binding(
            get: { leading ? requestedPanelWidths.leading : requestedPanelWidths.trailing },
            set: { if leading { requestedPanelWidths.leading = $0 } else { requestedPanelWidths.trailing = $0 } }), leading: leading)
    }

    private var activityToggle:some View {
        VStack(alignment:.trailing,spacing:3) {
            let pending=controller.runs.reduce(0) { $0+WorkflowWorkspacePanels.records(in:$1).filter { $0.step.status == .waiting }.count }
            Text(controller.isRunning ? workspaceText(languageStore, "running") : pending > 0 ? workspaceText(languageStore, "waitingCount")+" · \(pending)" : controller.isSaving || controller.hasPendingSaves ? workspaceText(languageStore, "savingPending") : workspaceText(languageStore, "ready"))
                .font(.caption).foregroundStyle(.secondary)
            Button(workspaceText(languageStore, "activity"),systemImage:activityVisible ? "chevron.down" : "chevron.up") {
                activityVisible.toggle();workspaceDraft=nil
            }.accessibilityIdentifier("workflow-activity-toggle").workbenchHelp("WORKSPACE-ACTIVITY")
        }
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
                Button(text("refinement.workflow.extractSelection", "组合为自定义节点…")) { extractSelection = true; toolsPresented = true }
                    .disabled(!controller.canEditCanvas)
                Button(text("workflow.selection.clear", "清除选择")) {
                    controller.selectedNodeID = nil; controller.selectedNodeIDs = []
                }
                Spacer()
            }.padding(14)
        } else if let node = selectedNodes.first {
WorkflowNodeInspector(controller: controller, metadata: metadata, node: node,
                    readOnly: isReadOnly, onTextModel: { guard selectForAction(node) else { return }; guarded(onTextModel)() }, onImageModel: { guard selectForAction(node) else { return }; guarded(onImageModel)() },
                    onAdditionalModel: { kind in guard selectForAction(node) else { return }; guarded { onAdditionalModel(kind) }() },
                    onImport: { id in guard !isReadOnly else { return }; onImport(id) },
                    onRecord: { id in guard !isReadOnly else { return }; onRecord(id) },
                    onReturnText: { ref in guard !isReadOnly else { return }; onReturnText(ref) },
                onPlan: presentPlan, onPlanRange: presentWorkspacePlan, onQuickUse: onQuickUse,
                onOpenBody: { nodeID, slot in
                    rememberViewContext()
                    controller.openBody(nodeID: nodeID, slot: slot)
                },
                onOpenTool: { reference in
                    rememberViewContext()
                    controller.openToolCopy(reference)
                }, revealLibrary: revealLibrary)
        } else {
            WorkbenchScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(controller.graph?.name ?? text("workflow.toolbar.noGraph", "选择流程")).font(.title3.bold())
                    Text(text("workflow.overview.counts", "{nodes} 个节点 · {wires} 条连接")
                        .replacingOccurrences(of: "{nodes}", with: String(controller.graph?.nodes.count ?? 0))
                        .replacingOccurrences(of: "{wires}", with: String(controller.graph?.connections.count ?? 0)))
                        .foregroundStyle(.secondary)
                    Button(text("workflow.language.interface", "设置流程输入与输出…")) { interfacePresented = true }.workbenchHelp("MENU-FLOW-INTERFACE")
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
    private func retained<V: View>(_ content: V, visible: Bool, id: String) -> some View {
        // The surrounding panel owns its plate. A nested canvas fill would leave
        // an opaque rectangle whose width changes with the pane's current content.
        RetainedContentHost(content: content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .workbenchTheme(paintsCanvas: false)
            .environment(\.dLanguageStore, languageStore)
            .environment(\.chatDisplayPreferences, displayPreferences), visible: visible, identifier: id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(visible).accessibilityHidden(!visible)
    }
    private var preparationPanel: some View {
        VStack(spacing: 0) {
            WorkbenchSidebarTabs(title: workspaceText(languageStore, "operations"),
                selection: Binding(get: { panelsState.preparation }, set: { panelsState.selectPreparation($0) }), choices: [
                    (WorkflowWorkspacePanels.Preparation.models, workspaceText(languageStore, "models")),
                    (.programs, workspaceText(languageStore, "programs")), (.configuration, consistencyText(languageStore, "tabs.properties"))], helpPrefix: "TAB-WORKFLOW-LEFT-")
            ZStack {
                ForEach(WorkflowWorkspacePanels.Preparation.allCases, id: \.self) { tab in
                    if visitedPreparation.contains(tab) || panelsState.preparation == tab {
                        retained(preparationContent(tab), visible: panelsState.preparation == tab,
                            id: "workflow-preparation-" + tab.rawValue)
                    }
                }
            }
        }
    }
    @ViewBuilder private func preparationContent(_ tab: WorkflowWorkspacePanels.Preparation) -> some View {
        if tab == .configuration { objectInspector }
        else {
            VStack(spacing: 8) {
                if let libraryContent {
                    libraryContent(tab == .programs ? .programs : .nodes, canvasInsertionPoint, { showInspector = false })
                } else if tab == .models {
                    WorkflowNodeLibrary(controller: controller, tagStore: nodeTags, metadata: metadata) { entry in
                        controller.addNode(operationID: entry.operation.id, modelID: entry.model?.id,
                            x: canvasInsertionPoint.x, y: canvasInsertionPoint.y)
                    }
                } else {
                    WorkflowNodeLibrary(controller:controller,tagStore:nodeTags,metadata:metadata) { entry in
                        controller.addNode(operationID:entry.operation.id,modelID:entry.model?.id,x:canvasInsertionPoint.x,y:canvasInsertionPoint.y)
                    }
                }
                if tab == .programs {
                    Button(text("workflow.language.tools", "管理自定义节点…")) { extractSelection = false; toolsPresented = true }.workbenchHelp("MENU-FLOW-CUSTOM")
                }
            }
        }
    }
    private func revealLibrary(_ context: WorkflowLibraryContext) {
        if resourceContext == nil { returnResourceCategory = resourceCategory }
        resourceContext = context; resourceCategory = .all; showLibrary = true
    }
    private func clearLibraryLocation() {
        resourceContext = nil
        if let original = returnResourceCategory { resourceCategory = original }
        returnResourceCategory = nil
    }
    private var resourcePanel:some View {
        VStack(spacing:6) {
            WorkbenchSidebarTabs(title:workspaceText(languageStore, "resources"),selection:$resourceCategory,
                choices:WorkflowResourceCategory.allCases.map { ($0,$0.title(languageStore)) },helpPrefix:"WORKSPACE-RESOURCE-")
            if let context=resourceContext {
                Button { clearLibraryLocation() } label: { Label(context.displayName(in: controller, language: languageStore),systemImage:"xmark.circle") }
                    .help(workspaceText(languageStore, "removeRelated"))
                Text(workspaceText(languageStore, context.isCurrent(in: controller) ? "locationQuery" : "locationUnavailable", "", "")).font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                ForEach(WorkflowResourceCategory.allCases,id:\.self) { tab in
                    if visitedResources.contains(tab) || resourceCategory == tab {
                        if let libraryContent {
                            retained(libraryContent(tab.mode,canvasInsertionPoint,{showLibrary=false})
                                .environment(\.workflowLibraryContext,resourceContext),visible:resourceCategory == tab,id:"workflow-resource-"+tab.rawValue)
                        } else {
                            retained(WorkflowAssetLibrary(controller:controller,metadata:metadata,onAdd:{project,asset in
                                if controller.graph == nil { controller.addBlankGraph() }
                                guard let target=controller.canvasInsertionTarget() else { return }
                                Task { await controller.addAssetNode(projectID:project,assetID:asset,x:canvasInsertionPoint.x,y:canvasInsertionPoint.y,target:target) }
                            },onImport:onImportAsset,onDropFile:onDropFile),visible:resourceCategory == tab,id:"workflow-resource-"+tab.rawValue)
                        }
                    }
                }
            }
            Button(text("workflow.action.publishText","将当前文稿存为流程素材")) { guarded(onPublishText)() }.disabled(!controller.canEditCanvas)
        }
    }
    private var selectedResultRun: WorkflowRun? { controller.runs.first { $0.id == panelsState.runID } }
    private var selectedResultRecord: WorkflowPlanCallRecord? { panelsState.record(in: selectedResultRun) }
    private var resultSourceNodes: [WorkflowNode] {
        guard let run = selectedResultRun else { return [] }
        var seen = Set<UUID>()
        return (run.graph.nodes + WorkflowWorkspacePanels.records(in: run).map(\.step.node)).filter { seen.insert($0.id).inserted }
    }
    private var outputPanel: some View {
        VStack(spacing: 0) {
            WorkbenchSidebarTabs(title: workspaceText(languageStore, "activity"), selection: $panelsState.output, choices: [
                (WorkflowWorkspacePanels.Output.node, text("workspace.nodeResults", "节点结果")),
                (.overview, text("workspace.runOverview", "运行总览")),
                (.batches, workspaceText(languageStore, "batches"))], helpPrefix: "TAB-WORKFLOW-RIGHT-")
            WorkbenchPicker(text("workspace.selectedRun", "所选运行"), selection: Binding(get: { panelsState.runID }, set: { panelsState.selectRun($0) })) {
                WorkbenchChoice(text("workspace.chooseRun", "选择运行记录"), value:UUID?.none)
                WorkbenchChoiceForEach(controller.runs.reversed()) { run in
                    WorkbenchChoice(WorkflowHumanPresentation.run(run, in: controller.runs, language: languageStore), value:Optional(run.id))
                }
            }.padding(.horizontal, 10).workbenchPanel(cornerRadius: 0).workbenchSurface(.scrollEdge).accessibilityIdentifier("workflow-result-run").workbenchHelp("RESULT-RUN")
            ZStack {
                if visitedOutput.contains(.node) || panelsState.output == .node {
                    retained(resultsPanel, visible: panelsState.output == .node, id: "workflow-results-host")
                }
                retained(runOverview, visible: panelsState.output == .overview, id: "workflow-overview-host")
                if panelsState.output == .batches {
                    WorkflowBatchPanel(controller: controller, revealLibrary: revealLibrary) { run, record in
                        panelsState.selectRun(run.id)
                        panelsState.selectResult(node: record.step.node.id, call: .init(address: record.address, stepID: record.id))
                    }
                }
            }
        }
    }
    private var resultHelpTarget: String { "result:\(panelsState.runID):\(panelsState.nodeID):\(panelsState.call?.stepID):\(selectedResultRecord?.address)" }
    private var resultsPanel: some View {
        VStack(spacing: 8) {
            Toggle(text("workspace.pinResult", "固定查看"), isOn: Binding(get: { panelsState.pinned }, set: { value in
                if value, let record = selectedResultRecord { panelsState.call = .init(address: record.address, stepID: record.step.id) }
                panelsState.pinned = value
            })).workbenchHelp("RESULT-PIN", unavailableReason: panelsState.nodeID == nil ? consistencyText(languageStore, "help.reason.result") : nil, target: resultHelpTarget).toggleStyle(.button).disabled(panelsState.nodeID == nil).padding(.horizontal, 10)
            WorkbenchPicker(text("workflow.results.node", "查看节点结果"), selection: Binding(get: { panelsState.nodeID }, set: { id in
                panelsState.nodeID = id; panelsState.call = nil
            })) {
                WorkbenchChoice(text("workflow.results.choose", "选择节点"), value:UUID?.none)
                WorkbenchChoiceForEach(resultSourceNodes) { node in WorkbenchChoice(WorkflowHumanPresentation.name(node, in: resultSourceNodes, language: languageStore), value:Optional(node.id)) }
            }.padding(.horizontal, 10)
            if let run = selectedResultRun {
                let calls = WorkflowWorkspacePanels.records(in: run).filter { $0.step.node.id == panelsState.nodeID }
                if calls.count > 1 {
                    WorkbenchPicker(text("workspace.call", "具体调用"), selection: Binding(get: { panelsState.call?.stepID }, set: { id in
                        panelsState.call = calls.first(where: { $0.id == id }).map { .init(address: $0.address, stepID: $0.id) }
                    })) {
                        WorkbenchChoice(text("workspace.chooseCall", "请选择一次调用"), value:UUID?.none)
                        WorkbenchChoiceForEach(calls) { call in
                            WorkbenchChoice(WorkflowHumanPresentation.call(call, in: WorkflowWorkspacePanels.records(in: run), language: languageStore), value:Optional(call.id))
                        }
                    }.workbenchHelp("RESULT-CALL", target: resultHelpTarget).padding(.horizontal, 10)
                }
            }
            if let record = selectedResultRecord {
                WorkbenchScrollView {
                    VStack(alignment:.leading,spacing:10) {
                        Button(workspaceText(languageStore, "locateResults", "", ""), systemImage: "tray.full") {
                            revealLibrary(.init(controller: controller, source: .call(.init(address: record.address, stepID: record.id)), name: record.step.node.title + " · " + WorkflowHumanPresentation.call(record, in: selectedResultRun.map(WorkflowWorkspacePanels.records) ?? [], language: languageStore)))
                        }.accessibilityIdentifier("call-locate-results")
                        HStack { Text(record.step.node.title).font(.headline);Spacer();WorkflowStatusBadge(status:record.step.status,stale:false) }
                        if let error=record.step.error { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                        if record.step.status == .waiting,let run=selectedResultRun {
                            Button(workspaceText(languageStore, "viewReadonly"),systemImage:"arrow.up.right.square") { openCall(run,record:record) }
                                .disabled(viewerModel == nil)
                            if let task = record.step.humanTask {
                                WorkflowHumanTaskForm(task: task,
                                    onSaveDraft: { controller.editHumanDraft(stepID: record.id, value: $0) },
                                    onSubmit: { value in Task { await controller.decideHuman(stepID: record.id, value: value, expectedTask: task) } },
                                    onReject: { Task { await controller.decideHuman(stepID: record.id, value: nil, reject: true, expectedTask: task) } })
                                    .id(record.id).disabled(controller.isRunning || isReadOnly)
                            } else {
                                WorkflowWaitingDecision(controller: controller, step: record.step, readOnly: isReadOnly,
                                    preview: controller.preview).id(record.id).disabled(controller.isRunning)
                            }
                        }
                        ForEach(record.step.outputs.keys.sorted(),id:\.self) { port in
                            if let value=record.step.outputs[port] {
                                HStack {
                                    Button(WorkflowCanvasPresentation.portTitle(operationID:record.step.node.operationID,portID:port,fallback:port,input:false,language:languageStore),systemImage:"arrow.up.right.square") {
                                        openValue(value,.init(address:record.address,stepID:record.id),record.step.node.title, port: port)
                                    }
                                    if let ref=value.asset,ref.kind == .text {
                                        Button(text("workflow.action.returnText","返回文稿")) { guarded { onReturnText(ref) }() }.disabled(isReadOnly)
                                    }
                                }
                            }
                        }
                        if record.step.status == .partial {
                            Button(text("workflow.action.retryFailedCandidates","重试失败候选")) { Task { await controller.retryFailedCandidates(stepID:record.id) } }.disabled(isReadOnly || controller.isRunning)
                        }
                        if controller.canRerunCall(record) {
                            Button(text("workflow.scope.rerunCall","重新运行具体调用")) { pendingHistoryRetry = .init(address:record.address,stepID:record.id) }
                                .disabled(isReadOnly || controller.isRunning || controller.hasPendingSaves)
                        }
                        DisclosureGroup(text("workspace.recordedDetails","当时的输入与参数")) {
                            ForEach(record.step.inputs.keys.sorted(),id:\.self) { port in
                                if let value=record.step.inputs[port] {
                                    Button(port,systemImage:"arrow.up.right.square") { openValue(value,.init(address:record.address,stepID:record.id),record.step.node.title+" · "+port, port: port, side: .input) }
                                }
                            }
                            Text(String(describing:record.step.node.parameters)).font(.caption).textSelection(.enabled)
                        }
                        WorkflowTechnicalDetails(value:String(describing:record.address)+"\n"+record.id.uuidString)
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                }
            } else {
                ContentUnavailableView(text("workspace.noResult", "此范围没有所选结果"), systemImage: "doc.text.magnifyingglass",
                    description: Text(text("workspace.noResultDetail", "请选择运行与具体调用。节点可能未参与此运行，或固定对象已不可访问；不会替换为其他运行。")))
            }
        }
    }
    private var runOverview: some View {
        WorkbenchScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let run = selectedResultRun {
                    Button(workspaceText(languageStore, "locateResults", "", ""), systemImage: "tray.full") {
                        revealLibrary(.init(controller: controller, source: .run(run.id), name: WorkflowHumanPresentation.run(run, in: controller.runs, language: languageStore)))
                    }.accessibilityIdentifier("run-locate-results")
                    Text(run.graph.name).font(.headline)
                    Text(WorkflowCanvasPresentation.statusTitle(run.status, language: languageStore)).font(.title3)
                    Text(run.graph.nodes.first(where: { $0.id == run.targetNodeID })?.title ?? text("workspace.unavailableTarget", "目标已不可访问")).font(.callout)
                    if let issue = run.planCheckpoint?.error { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    if WorkflowCanvasPresentation.canResume(run.status) {
                        recoveryActions(run)
                    }
                    if controller.isRunning && controller.activePresentationRun?.id == run.id && !controller.visibleStreamingText.isEmpty {
                        Text(workspaceText(languageStore, "streaming")).font(.caption)
                        Text(controller.visibleStreamingText).lineLimit(4).textSelection(.enabled)
                    }
                    DisclosureGroup(text("workspace.runAssets", "此运行的已保存结果")) {
                        ForEach(WorkflowHumanPresentation.outputs(run)) { output in
                            Button(WorkflowHumanPresentation.name(output.call.step.node,in:WorkflowHumanPresentation.nodes(in:run),language:languageStore)+" · "+output.port,systemImage:"arrow.up.right.square") {
                                openValue(output.value,.init(address:output.call.address,stepID:output.call.id),output.call.step.node.title, port: output.port)
                            }
                        }
                    }
                    ForEach(WorkflowWorkspacePanels.records(in: run)) { record in
                        Button {
                            panelsState.selectResult(node: record.step.node.id, call: .init(address: record.address, stepID: record.id))
                        } label: {
                            HStack {
                                VStack(alignment: .leading) { Text(WorkflowHumanPresentation.name(record.step.node, in: WorkflowHumanPresentation.nodes(in: run), language: languageStore)); Text(WorkflowHumanPresentation.call(record, in: WorkflowWorkspacePanels.records(in: run), language: languageStore)).font(.caption2) }
                                Spacer()
                                WorkflowStatusBadge(status: record.step.status, stale: false)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(WorkbenchRowButtonStyle())
                    }
                } else {
                    Text(text("workspace.chooseRun", "选择运行记录")).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }

    func dropItem(_ value: WorkflowCanvasTransfer, _ point: CGPoint) -> Bool {
        guard controller.canEditCanvas else { return false }
        switch value {
        case .operation(let id, let model):
            guard controller.registry.operation(id) != nil else { return false }
            controller.addNode(operationID: id, modelID: model, x: point.x, y: point.y)
            return controller.errorMessage == nil
        case .asset, .assetInstance:
            guard let identity = WorkflowCanvasAssetIdentity.payload(value) else { return false }
            return dropAsset(project: identity.project, instance: identity.instance,
                asset: identity.asset, point: point)
        case .tool(let reference):
            guard let tool = controller.tools.first(where: { $0.id == reference.id && $0.version == reference.version && (try? WorkflowPlanCompiler.digest($0)) == reference.digest }) else { return false }
            controller.addTool(tool, x: point.x, y: point.y)
            return controller.errorMessage == nil
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
            WorkbenchMenu {
                WorkbenchMenuForEach(controller.graphs) { graph in
                    WorkbenchMenuAction(graph.name) { rememberViewContext(); controller.selectedGraphID = graph.id }
                }
            } label: {
                Label(text("semantics.flowPrefix", "流程：") + (controller.rootGraph?.name ?? text("workflow.toolbar.noGraph", "选择流程")), systemImage: "chevron.down")
                    .lineLimit(1)
            }.accessibilityIdentifier("workflow-graph-picker").workbenchHelp("FLOW-SELECT")
            WorkbenchMenu {
                WorkbenchMenuAction(text("workspace.blankFlow", "空白流程")) { controller.addBlankGraph() }.featureHelp("MENU-FLOW-BLANK", language: languageStore)
                WorkbenchSubmenu(consistencyText(languageStore, "menu.flow.templates")) {
                    WorkbenchMenuForEach(WorkflowLanguageExample.allCases, id: \.rawValue) { example in
                        WorkbenchMenuAction(text("workflow.language.example.\(example.rawValue)",
                            ["data": "数据与控制", "images": "主题与图像批次", "music": "哼唱与和声", "multimodal": "同源四模态"][example.rawValue] ?? example.rawValue)) {
                            controller.addLanguageExample(example)
                        }.featureHelp(example.rawValue == "images" ? "MENU-FLOW-TEMPLATE-IMAGES" : "MENU-FLOW-TEMPLATE-EXISTING", language: languageStore)
                    }
                    WorkbenchMenuForEach(WorkflowExampleChoice.allCases) { example in WorkbenchMenuAction(example.title(languageStore)) { controller.addExample(example.rawValue) }.featureHelp(example.rawValue == "template" ? "MENU-FLOW-TEMPLATE-TEXT" : "MENU-FLOW-TEMPLATE-EXISTING", language: languageStore) }
                }.featureHelp("MENU-FLOW-TEMPLATES", language: languageStore).disabled(!controller.canEditCanvas)
            } label: { Label(consistencyText(languageStore, "FLOW-NEW"), systemImage: "plus") }
                .disabled(!controller.canEditCanvas).accessibilityIdentifier("canvas-new-flow").workbenchHelp("FLOW-NEW", unavailableReason: canvasHelpReason(controller, language: languageStore))
            if !controller.bodyPath.isEmpty {
                Text(bodyBreadcrumb).foregroundStyle(.secondary).lineLimit(1)
            }
            if controller.presentationEditingOriginalID == controller.rootGraph?.id {
                Label(consistencyText(languageStore, "copy.runningWorkflow"), systemImage: "lock").help(consistencyText(languageStore, "copy.copyOnEdit")).font(.caption).foregroundStyle(.secondary)
            } else if controller.presentationCopySourceID != nil {
                Text(text("workspace.editingCopy", "编辑副本")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(consistencyText(languageStore, "FLOW-SAVE"), systemImage: "square.and.arrow.down") {
                Task { await controller.save() }
            }.disabled(isReadOnly || controller.isSaving).accessibilityIdentifier("workflow-save").workbenchHelp("FLOW-SAVE", unavailableReason: controller.isSaving ? consistencyText(languageStore, "help.reason.saving") : controller.readOnlyReason)
            if controller.isSaving { ProgressView().controlSize(.small) }
            else if controller.hasPendingSaves { Text(text("workflow.status.pendingSave", "有待恢复保存")).foregroundStyle(.orange).font(.caption) }
            WorkbenchMenu(text("canvas.flowMenu", "流程设置"), systemImage: "ellipsis.circle") {
                WorkbenchMenuAction(text("workflow.language.interface", "设置流程输入与输出…")) { interfacePresented = true }
                    .disabled(controller.graph == nil || !controller.canEditCanvas)
                WorkbenchMenuAction(text("workflow.language.tools", "管理自定义节点…")) { extractSelection = false; toolsPresented = true }
            }.accessibilityIdentifier("canvas-more").workbenchHelp("FLOW-MORE")
        }.buttonStyle(WorkbenchGlassButtonStyle()).padding(.horizontal, 18).padding(.vertical, 10)
            .padding(.top, 6)
    }

    private var bodyBreadcrumb: String {
        guard let root = controller.rootGraph else { return "" }
        return controller.bodyPath.indices.compactMap { index in
            let path = Array(controller.bodyPath.prefix(index))
            guard let parent = try? WorkflowGraphEditing.body(in: root, path: path),
                  let node = parent.nodes.first(where: { $0.id == controller.bodyPath[index].nodeID }) else { return nil }
            return WorkflowHumanPresentation.name(node, in: parent.nodes, language: languageStore)
        }.joined(separator: " / ")
    }

    private var runHelpReason: String? {
        if let reason = canvasHelpReason(controller, language: languageStore) { return reason }
        if !controller.bodyPath.isEmpty { return consistencyText(languageStore, "help.reason.body") }
        if validRunTarget == nil { return consistencyText(languageStore, "help.reason.target") }
        return nil
    }
    private var runContext: WorkflowRunTarget.Context { .init(controller) }
    private var validRunTarget: WorkflowNode? {
        guard let runTarget, runTarget.isCurrent(in: controller) else { return nil }
        return controller.graph?.nodes.first { $0.id == runTarget.nodeID }
    }
    private func setRunTarget(_ id: UUID) {
        guard controller.graph?.nodes.contains(where: { $0.id == id }) == true else { return }
        runTarget = WorkflowRunTarget(context: runContext, nodeID: id)
        runPreview = nil;workspaceDraft=nil;planInputLabels=[:]
    }
    private func setRunRange(_ value:Int) {
        runRange=value;runPreview=nil;workspaceDraft=nil;planInputLabels=[:]
    }
    private var recoveryRuns: [WorkflowRun] {
        controller.runs.reversed().filter { WorkflowCanvasPresentation.canResume($0.status) }
    }
    private var recoveryRun: WorkflowRun? {
        if let selectedResultRun, WorkflowCanvasPresentation.canResume(selectedResultRun.status) { return selectedResultRun }
        return recoveryRuns.count == 1 ? recoveryRuns.first : nil
    }
    private var executionBar: some View {
        VStack(spacing: 8) {
        HStack(spacing: 10) {
            if controller.isRunning {
                ProgressView().controlSize(.small)
                if let run = controller.activePresentationRun {
                    Text(text("workflow.run.current", "正在运行到：") + (run.graph.nodes.first { $0.id == run.targetNodeID }?.title ?? run.targetNodeID.uuidString))
                        .lineLimit(1).accessibilityIdentifier("workflow-active-target")
                }
                Button(text("workflow.language.control.pause", "暂停流程"), systemImage: "pause") { controller.pause() }.workbenchHelp("RUN-PAUSE")
                    .help(text("workflow.run.pauseHelp", "当前步骤完成并释放资源后暂停。"))
                    .disabled(!controller.canPausePresentation)
                Button(text("workflow.action.stop", "停止流程"), systemImage: "stop.fill", role: .destructive) {
                    Task { await controller.cancel() }
                }.accessibilityIdentifier("workflow-cancel").workbenchHelp("RUN-STOP")
            } else {
                WorkbenchPicker(text("workflow.run.range", "范围"), selection: Binding(get:{runRange},set:setRunRange)) {
                    WorkbenchChoice(text("workflow.action.runToHere", "运行到此节点"), value:0)
                    WorkbenchChoice(text("workflow.action.rerunOnly", "只重跑此节点"), value:1)
                    WorkbenchChoice(text("workflow.scope.from", "从这里重新运行（含此节点）"), value:2)
                    WorkbenchChoice(text("workflow.scope.after", "从其输出继续（不重算此节点）"), value:3)
                }.frame(maxWidth: 230).accessibilityIdentifier("workflow-run-range").workbenchHelp("RUN-RANGE")
                WorkbenchPicker(text(["semantics.targetThrough", "semantics.targetOnly", "semantics.targetFrom", "semantics.targetAfter"][runRange], ["运行终点", "执行节点", "重新运行起点", "使用其输出的节点"][runRange]), selection: Binding(get: { validRunTarget?.id }, set: { id in
                    if let id { setRunTarget(id) } else { runTarget = nil; runPreview = nil;workspaceDraft=nil;planInputLabels=[:] }
                })) {
                    WorkbenchChoice(consistencyText(languageStore, "run.choose." + String(runRange)), value:UUID?.none)
                    WorkbenchChoiceForEach(controller.graph?.nodes ?? []) { node in WorkbenchChoice(WorkflowHumanPresentation.name(node, in: controller.graph?.nodes ?? [], language: languageStore), value:Optional(node.id)) }
                }.frame(maxWidth: 280).accessibilityIdentifier("workflow-run-target").workbenchHelp("RUN-TARGET")
                Button(consistencyText(languageStore, "RUN-REVIEW"), systemImage: "play.fill") {
                    if let node = validRunTarget {
                        if runRange < 2 { presentPlan(nodeID: node.id, only: runRange == 1) }
                        else { presentWorkspacePlan(node.id,mode:runRange) }
                    }
                }.buttonStyle(WorkbenchPrimaryButtonStyle())
                    .disabled(validRunTarget == nil || !controller.canEditCanvas || !controller.bodyPath.isEmpty)
                    .accessibilityIdentifier("workflow-run").workbenchHelp("RUN-REVIEW", unavailableReason: runHelpReason, target: "target:\(validRunTarget?.id):\(runRange)")

            }
            Button(text("workflow.section.history", "运行历史"), systemImage: "clock.arrow.circlepath") {
                if let run = controller.activePresentationRun {
                    panelsState.selectRun(run.id); panelsState.nodeID = run.targetNodeID
                } else if panelsState.runID == nil {
                    panelsState.selectRun(controller.runs.last(where: { controller.presentationRootGraphID(for: $0.id) == controller.rootGraph?.id })?.id)
                }
                panelsState.output = .overview; activityVisible=true;workspaceDraft=nil
            }.workbenchHelp("RUN-HISTORY")
        }
        if !controller.isRunning, recoveryRun == nil, !recoveryRuns.isEmpty {
            WorkbenchMenu(text("semantics.choosePendingRun", "选择要处理的运行…")) {
                WorkbenchMenuForEach(recoveryRuns) { run in
                    WorkbenchMenuAction(WorkflowHumanPresentation.run(run, in: controller.runs, language: languageStore)) {
                        panelsState.selectRun(run.id); panelsState.output = .overview; activityVisible=true;workspaceDraft=nil
                    }
                }
            }
        }
        if !controller.isRunning, let run = recoveryRun {
            HStack {
                WorkbenchMenu {
                    WorkbenchMenuForEach(recoveryRuns) { item in
                        WorkbenchMenuAction(WorkflowHumanPresentation.run(item, in: controller.runs, language: languageStore)) {
                            panelsState.selectRun(item.id); panelsState.output = .overview; activityVisible=true;workspaceDraft=nil
                        }
                    }
                } label: {
                    Text(WorkflowHumanPresentation.run(run, in: controller.runs, language: languageStore))
                }
                recoveryActions(run)
            }
        }
        }.controlSize(.small).padding(.horizontal,6)
    }

    @ViewBuilder private func recoveryActions(_ run: WorkflowRun) -> some View {
        let waiting = WorkflowWorkspacePanels.records(in: run).filter { $0.step.status == .waiting }
        if WorkflowHumanPresentation.opensPendingDecision(run) {
            WorkbenchMenu(text("semantics.pending", "处理待确认内容")) {
                WorkbenchMenuForEach(waiting) { call in
                    WorkbenchMenuAction(WorkflowHumanPresentation.name(call.step.node, in: WorkflowHumanPresentation.nodes(in: run), language: languageStore) + " · " + WorkflowHumanPresentation.call(call, in: WorkflowWorkspacePanels.records(in: run), language: languageStore)) {
                        panelsState.selectRun(run.id)
                        panelsState.selectResult(node: call.step.node.id, call: .init(address: call.address, stepID: call.id))
                        openCall(run,record:call)
                    }
                }
            }.accessibilityIdentifier("workflow-open-pending-" + run.id.uuidString)
        } else {
            WorkflowRunRecoveryButton(controller: controller, run: run, readOnly: isReadOnly || controller.isRunning)
        }
    }

    private func canvasTools(fitReady: Bool, targetWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            WorkbenchGlassSegments(title: text("refinement.workflow.canvasTool", "画布工具"), selection: $canvasTool, choices: [
                (WorkflowCanvasTool.pointer, text("refinement.workflow.pointer", "指针")),
                (.hand, text("refinement.workflow.hand", "手形"))], featureIDs: ["CANVAS-POINTER", "CANVAS-HAND"])
                .frame(width: 100).accessibilityIdentifier("workflow-canvas-tool")
            Button(text("workflow.action.undo", "撤销"), systemImage: "arrow.uturn.backward") { controller.undo() }.workbenchHelp("CANVAS-UNDO", unavailableReason: controller.canUndo ? nil : (canvasHelpReason(controller, language: languageStore) ?? consistencyText(languageStore, "help.reason.undo")))
                .disabled(!controller.canEditCanvas || !controller.canUndo)
            Button(text("workflow.action.redo", "重做"), systemImage: "arrow.uturn.forward") { controller.redo() }.workbenchHelp("CANVAS-REDO", unavailableReason: controller.canRedo ? nil : (canvasHelpReason(controller, language: languageStore) ?? consistencyText(languageStore, "help.reason.redo")))
                .disabled(!controller.canEditCanvas || !controller.canRedo)
            WorkbenchMenu(text("workflow.selection.menu", "选择"), systemImage: "square.dashed") {
                WorkbenchMenuAction(text("workflow.selection.all", "选择全部节点")) {
                    controller.selectedNodeID = nil; selectedConnectionID = nil
                    controller.selectedNodeIDs = Set(controller.graph?.nodes.map(\.id) ?? [])
                }
                WorkbenchMenuAction(text("workflow.selection.clear", "清除选择")) {
                    controller.selectedNodeID = nil; controller.selectedNodeIDs = []; selectedConnectionID = nil
                }
                WorkbenchMenuAction(text("refinement.workflow.extractSelection", "组合为自定义节点…")) {
                    if let node = selectedNodes.first, selectedNodes.count == 1 { controller.selectedNodeIDs = [node.id] }
                    extractSelection = true; toolsPresented = true
                }.disabled(!controller.canEditCanvas || selectedNodes.isEmpty)
                    .accessibilityIdentifier("workflow-canvas-extract-selection")
            }
            Button(workflowText(languageStore, "refinement.workflow.typeLegend"), systemImage: "paintpalette") { portLegendPresented.toggle() }
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
            Spacer(minLength: 4)
            Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit())
            Slider(value: $zoom, in: WorkflowCanvasLayoutPolicy.sliderZoomRange(current: zoom))
                .frame(width: 78).disabled(viewportInteractionLocked)
                .accessibilityLabel(text("workflow.toolbar.zoom", "画布缩放"))
            Button(text("refinement.workflow.fitAll", "显示全部节点"), systemImage: "arrow.up.left.and.arrow.down.right") {
                fitAllNodes(targetWidth: targetWidth)
            }.disabled(!fitReady || viewportInteractionLocked).accessibilityIdentifier("workflow-canvas-fit-all").workbenchHelp("CANVAS-FIT")

        }.buttonStyle(WorkbenchGlassButtonStyle()).controlSize(.small).padding(.horizontal, 18).padding(.vertical, 8)
            .workbenchPanel(cornerRadius: 12).padding(.horizontal, 12)
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
                Text(workflowText(languageStore, "workflow.status.savingNow"))
            } else if controller.isRunning {
                ProgressView().controlSize(.small)
                Text(controller.progressMessage.isEmpty && controller.progressPresentation == nil
                     ? workflowText(languageStore, "workflow.status.runningNow")
                     : controller.progressPresentation.map { workflowProgressText($0, language: languageStore) } ?? workflowRecoveryProgressText(controller.progressMessage, language: languageStore))
            } else if !controller.progressMessage.isEmpty || controller.progressPresentation != nil {
                Text(controller.progressPresentation.map { workflowProgressText($0, language: languageStore) } ?? workflowRecoveryProgressText(controller.progressMessage, language: languageStore)).foregroundStyle(.secondary)
            }
            Spacer()
            if let rawError = controller.errorMessage {
                let error = WorkbenchOwnedIssue.summary(rawError, language: languageStore)
                    ?? workflowRecoveryErrorText(rawError, runs: controller.runs, language: languageStore)
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(error)
                    .accessibilityIdentifier("workflow-error")
                Button(workflowText(languageStore, "workflow.action.close"),
                       systemImage: "xmark") { controller.errorMessage = nil }
                    .labelStyle(.iconOnly)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 34)

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
        setRunTarget(nodeID);runRange=only ? 1:0;presentWorkspacePlan(nodeID,mode:runRange)
    }
    private var currentPlanMarks:[UUID:WorkflowPlanMark] {
        guard let draft=workspaceDraft,draft.isCurrent(in:controller) else { return [:] }
        return draft.marks.mapValues { $0 }.reduce(into:[:]) { result,item in
            var mark=item.value;mark.historicalLabel=planInputLabels[item.key];result[item.key]=mark
        }
    }
    private func presentWorkspacePlan(_ node:UUID,mode:Int) {
        guard !isReadOnly else { return }
        do { planInputLabels=[:];workspaceDraft=try .init(controller:controller,target:node,mode:mode);activityVisible=false }
        catch { controller.errorMessage=error.localizedDescription }
    }
    private func openValue(_ value:WorkflowValue,_ call:WorkflowCallReference,_ title:String, port: String? = nil, side: WorkflowViewerValueSide = .output) {
        guard let viewerModel,viewerModel.projectSession.workflow === controller else { return }
        do { try viewerModel.viewers.open(.init(title:title,subtitle:controller.runs.first { $0.id == call.address.runID }.map { WorkflowHumanPresentation.run($0,in:controller.runs,language:languageStore) } ?? "",value:value,call:call,port:port,side:side,usesCallTitle: true),model:viewerModel,language:languageStore) }
        catch { controller.errorMessage=error.localizedDescription }
    }
    private func openCall(_ run:WorkflowRun,record:WorkflowPlanCallRecord) {
        let port=record.step.outputs.keys.sorted().first
        let value=port.flatMap { record.step.outputs[$0] } ?? record.step.humanTask.map { WorkflowValue.data($0.materials) } ?? .data(.text(""))
        openValue(value,.init(address:record.address,stepID:record.id),WorkflowHumanPresentation.name(record.step.node,in:WorkflowHumanPresentation.nodes(in:run),language:languageStore), port: port, side: port == nil ? .materials : .output)
    }

}

private struct WorkflowFixedToolPresentation: Identifiable {
    let reference: WorkflowToolReference
    var id: String { reference.id.uuidString + ":\(reference.version):" + reference.digest }
}

private struct WorkflowNodeInspector: View {
    let controller: WorkflowController
    var metadata: SharedLibraryStore? = nil
    let node: WorkflowNode?
    let readOnly: Bool
    let onTextModel: () -> Void
    let onImageModel: () -> Void
    let onAdditionalModel: (WorkflowModelKind) -> Void
    let onImport: (UUID) -> Void
    let onRecord: (UUID) -> Void
    let onReturnText: (WorkflowAssetReference) -> Void
    let onPlan: (UUID, Bool) -> Void
    let onPlanRange: (UUID, Int) -> Void
    let onQuickUse: ((WorkflowNode) -> Void)?
    let onOpenBody: (UUID, String) -> Void
    let onOpenTool: (WorkflowToolReference) -> Void
    var revealLibrary: ((WorkflowLibraryContext) -> Void)? = nil
    var resultsOnly = false
    var resultRunID: UUID? = nil
    var exactResult = false
    var resultRecord: WorkflowPlanCallRecord? = nil
    @Environment(\.dLanguageStore) private var languageStore
    @Environment(\.workbenchModelReadiness) private var modelReadiness
    @State private var scopePresentation: WorkflowScopePresentation?
    @State private var fixedToolPresentation: WorkflowFixedToolPresentation?
    @State private var pendingCall: WorkflowCallReference?
    @State private var showHistory = false
    @State private var showTechnical = false

    var body: some View {
        WorkbenchScrollView {
            if let node {
                VStack(alignment: .leading, spacing: 16) {
                    if !resultsOnly {
                    identity(node)
                    WorkflowRegistrationView(node: node, controller: controller)
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
                        }), availableRecordSchema: WorkflowFormSupport.connectedRecordFields(nodeID: node.id, graph: controller.graph, tools: controller.tools)).id(node.id).disabled(readOnly || !controller.canEditCanvas)
                    }
                    if node.operationID.hasPrefix("d.control."), node.operationID != "d.control.human", let graphID = controller.graph?.id {
                        WorkflowControlEditor(node: Binding(get: { controller.graph?.nodes.first(where: { $0.id == node.id }) ?? node }, set: { controller.updateNode($0, in: graphID) }), tools: controller.tools, onOpenBody: { slot in
                            if slot == "tool", case .invoke(let reference) = node.control {
                                fixedToolPresentation = .init(reference: reference)
                            }
                            else { onOpenBody(node.id, slot) }
                        }).id(node.id).disabled(readOnly || !controller.canEditCanvas)
                    }
                    ports(node)
                    } else {
                    execution(node)
                    if let record = resultRecord, controller.canRerunCall(record) {
                        Button(workflowText(languageStore, "workflow.scope.rerunCall")) {
                            pendingCall = .init(address: record.address, stepID: record.id)
                        }.disabled(readOnly || controller.isRunning || controller.hasPendingSaves)
                    }
                    if !exactResult {
                        DisclosureGroup(isExpanded: $showHistory) { history(node) } label: {
                            Text(workflowText(languageStore, "workflow.section.history"))
                        }
                    }
                    }
                }
                .padding(14)
            } else {
                ContentUnavailableView(
                    workflowText(languageStore, "workflow.inspector.empty"),
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
        .workbenchPanel(cornerRadius: 12)
        .environment(\.workbenchMenuContext, "inspector:\(ObjectIdentifier(controller)):\(controller.projectID):\(controller.projectInstanceID):\(controller.bodyPath):\(controller.rootGraph?.revision.uuidString ?? "none"):\(controller.graph?.id.uuidString ?? "none"):\(controller.graph?.revision.uuidString ?? "none"):\(node?.id.uuidString ?? "none"):\(resultRunID):\(resultRecord?.id):\(resultRecord?.address)")
        .accessibilityIdentifier("workflow-inspector")
        .sheet(item: $scopePresentation) { request in
            WorkflowScopePanel(controller: controller, graphID: request.graphID, revision: request.revision, nodeID: request.nodeID, initialMode: request.mode).workbenchPresentation()
        }
        .sheet(item: $fixedToolPresentation) { request in
            WorkflowFixedToolSheet(controller: controller, reference: request.reference,
                onClose: { fixedToolPresentation = nil },
                onCopy: {
                    fixedToolPresentation = nil
                    onOpenTool(request.reference)
                })
        }
        .alert(workflowText(languageStore, "workflow.scope.rerunCall"),
               isPresented: Binding(get: { pendingCall != nil }, set: { if !$0 { pendingCall = nil } })) {
            Button(workflowText(languageStore, "workflow.scope.run")) {
                if let reference = pendingCall { Task { await controller.rerunCall(reference) } }
                pendingCall = nil
            }
            Button(workflowText(languageStore, "workflow.scope.cancel"), role: .cancel) { pendingCall = nil }
        } message: {
            Text(workflowText(languageStore, "workflow.scope.callExplanation"))
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
                .buttonStyle(WorkbenchGlassButtonStyle())
                .disabled(readOnly || !controller.canEditCanvas)
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
        guard !readOnly, controller.canEditCanvas,
              let graph = controller.graph,
              let replacement = target.replacement(in: graph, preset: preset) else { return }
        controller.updateNode(replacement, in: target.graphID)
    }

    private func resolvedModelID(_ node: WorkflowNode, definition: WorkflowOperationDefinition) -> String? {
        WorkflowNodeIdentity.modelIdentity(node: node, definition: definition, defaults: controller.services.capturedModelDefaults())
    }
    private func identity(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.node")) {
            let resolved = WorkflowNodeIdentity.resolve(node: node,
                definition: controller.registry.definition(for: node, tools: controller.tools),
                modelChoices: controller.modelChoices, assets: controller.availableAssets,
                tools: controller.tools, language: languageStore)
            Text(WorkflowHumanPresentation.name(node, in: controller.graph?.nodes ?? [node], language: languageStore)).font(.title3.weight(.semibold))
            if let detail = resolved.detail, controller.registry.definition(for: node, tools: controller.tools)?.modelKind == nil {
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let definition = controller.registry.definition(for: node, tools: controller.tools) {
                WorkbenchModelCard(definition: definition, modelID: resolvedModelID(node, definition: definition),
                    choices: controller.modelChoices, status: workbenchModelReadinessText(modelReadiness[resolvedModelID(node, definition: definition) ?? ""] ?? .unknown, language: languageStore),
                    change: definition.modelKind == nil || resultsOnly ? nil : modelPicker(for: definition.modelKind),
                    canChange: !readOnly && controller.canEditCanvas,
                    changeUnavailableReason: canvasHelpReason(controller, readOnly: readOnly, language: languageStore),
                    usingDefault: node.parameters["modelID"]?.string?.isEmpty != false)
            }
            if let annotation = resolved.annotation, annotation != resolved.title {
                Text(annotation).font(.callout).foregroundStyle(.secondary)
            }
            let commandScope = controller.rootGraph.flatMap { root in controller.graph.map { graph in
                WorkflowCanvasScope(rootGraphID: root.id, rootRevision: root.revision, graphID: graph.id,
                    bodyPath: controller.bodyPath, projectID: controller.projectID, instanceID: controller.projectInstanceID)
            } }
            let commandIsCurrent = { commandScope?.isCurrent(in: controller) == true && controller.graph?.nodes.contains(node) == true && controller.canEditCanvas && !readOnly }
            WorkbenchMenu(workflowText(languageStore, "semantics.nodePlan")) {
                WorkbenchMenuAction(workflowText(languageStore, "workflow.action.runToHere")) { if commandIsCurrent() { onPlan(node.id, false) } }
                WorkbenchMenuAction(workflowText(languageStore, "workflow.action.rerunOnly")) { if commandIsCurrent() { onPlan(node.id, true) } }
                WorkbenchMenuAction(workflowText(languageStore, "workflow.scope.from")) {
                    if commandIsCurrent() { onPlanRange(node.id,2) }
                }
                WorkbenchMenuAction(workflowText(languageStore, "workflow.scope.after")) {
                    if commandIsCurrent() { onPlanRange(node.id,3) }
                }
            }.disabled(readOnly || !controller.canEditCanvas || !controller.bodyPath.isEmpty)
            if let onQuickUse, controller.registry.definition(for: node, tools: controller.tools)?.modelKind != nil {
                Button(workflowText(languageStore, "canvas.identity.quickUse", fallback: "在快速生成中使用设置")) {
                    onQuickUse(node)
                }
                .accessibilityIdentifier("canvas-quick-use-" + node.id.uuidString)
            }
            if case .invoke(let reference) = node.control {
                Button(workflowText(languageStore, "canvas.tool.fixedTitle")) {
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
                WorkflowTechnicalDetails(value: node.id.uuidString + "\n" + node.operationID + "\n" + String(node.definitionVersion) + "\n" + String(describing: node.parameters) + "\n" + String(describing: node.assetReference) + "\n" + String(describing: node.control))
                WorkflowMetadataRow(workflowText(languageStore, "workflow.metadata.operation"),
                                    node.operationID)
                WorkflowMetadataRow(workflowText(languageStore, "workflow.metadata.definitionVersion"),
                                    String(node.definitionVersion))
            }
            HStack {
                Button(workflowText(languageStore, "workflow.action.copy"),
                       systemImage: "doc.on.doc") {
                    guard controller.graph?.nodes.contains(node) == true else { return }
                    controller.selectedNodeID = node.id; controller.copySelected()
                }
                Button(workflowText(languageStore, "workflow.action.delete"),
                       systemImage: "trash", role: .destructive) {
                    guard let target = controller.canvasInsertionTarget(), controller.graph?.nodes.contains(node) == true else { return }
                    controller.deleteNode(id: node.id, target: target)
                }
            }
            .disabled(readOnly || !controller.canEditCanvas)
            if controller.registry.operation(node.operationID)?.definition.interaction == .assetInput {
                WorkbenchMenu(workflowText(languageStore, "workflow.asset.referenceExisting")) {
                    WorkbenchMenuForEach(controller.availableAssets) { asset in
                        WorkbenchMenuAction(asset.name + " · " + asset.mediaType) {
                            Task { await controller.bindExistingAsset(asset.id, nodeID: node.id) }
                        }
                    }
                }.disabled(readOnly || !controller.canEditCanvas || controller.availableAssets.isEmpty)
                Button(workflowText(languageStore, "workflow.asset.chooseImport"),
                       systemImage: "square.and.arrow.down") { onImport(node.id) }
                    .disabled(readOnly || !controller.canEditCanvas)
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
        WorkflowInspectorSection(workflowText(languageStore, "workspace.commonSettings")) {
            if let definition = controller.registry.definition(for: node, tools: controller.tools) {
                if definition.fields.isEmpty {
                    Text(workflowText(languageStore, "workflow.parameters.none"))
                        .foregroundStyle(.secondary)
                }
                ForEach(definition.fields.filter { !WorkflowParameterPresentation.advanced.contains($0.id) }) { field in
                    fieldEditor(field, node: node, definition: definition)
                }
                let advanced = definition.fields.filter { WorkflowParameterPresentation.advanced.contains($0.id) }
                if !advanced.isEmpty {
                    DisclosureGroup(workflowText(languageStore, "workspace.advanced")) {
                        ForEach(advanced) { field in fieldEditor(field, node: node, definition: definition) }
                    }.workbenchHelp("MODEL-ADVANCED")
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

    private func fieldEditor(_ field: WorkflowFieldDefinition, node: WorkflowNode, definition: WorkflowOperationDefinition) -> some View {
        WorkflowFieldEditor(field: field, operationID: node.operationID,
            value: node.parameters[field.id] ?? field.defaultValue,
            readOnly: readOnly || !controller.canEditCanvas,
            modelChoices: controller.modelChoices.filter { $0.kind == definition.modelKind },
            modelPicker: modelPicker(for: definition.modelKind),
            onChange: { controller.setParameter(nodeID: node.id, key: field.id, value: $0) })
    }

    @ViewBuilder
    private func ports(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.ports")) {
            if let definition = controller.registry.definition(for: node, tools: controller.tools) {
                Text(workflowText(languageStore, "workflow.port.inputs"))
                    .font(.subheadline.weight(.semibold))
                if definition.inputs.isEmpty {
                    Text(workflowText(languageStore, "workflow.port.noInputs"))
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
                        Text(WorkflowCanvasPresentation.portSummary(port, language: languageStore))
                            .help(WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                            .font(.caption).foregroundStyle(.secondary)
                        if incoming.isEmpty {
                            Text(port.required
                                 ? workflowText(languageStore, "workflow.port.notConnected")
                                 : workflowText(languageStore, "workflow.port.notProvided"))
                                .font(.caption)
                                .foregroundStyle(port.required ? Color.orange : Color.secondary)
                        }
                        ForEach(incoming) { connection in
                            HStack {
                                Text(WorkflowConnectionPresentation.title(connection, graph: controller.graph, registry: controller.registry, tools: controller.tools, language: languageStore))
                                    .font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Button(workflowText(languageStore, "workflow.action.disconnect"),
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
                Text(workflowText(languageStore, "workflow.port.outputs"))
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                if definition.outputs.isEmpty {
                    Text(workflowText(languageStore, "workflow.port.noOutputs"))
                        .foregroundStyle(.secondary)
                }
                ForEach(definition.outputs) { port in
                    HStack {
                        Text(WorkflowCanvasPresentation.portTitle(
                            operationID: node.operationID, port: port, input: false, language: languageStore
                        ))
                        Spacer()
                        Text(WorkflowCanvasPresentation.portSummary(port, language: languageStore))
                            .help(WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func execution(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.execution")) {

            if let step = exactResult ? resultRecord?.step : controller.presentationStep(nodeID: node.id, runID: resultRunID) {
                HStack {
                    WorkflowStatusBadge(status: step.status, stale: resultRunID == nil ? (controller.presentationStatus(for: node.id)?.stale ?? true) : controller.isStale(step))
                    Spacer()
                    Text(step.node.title).font(.caption).foregroundStyle(.secondary)
                }
                if let error = step.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if step.status == .waiting {
                    if let task = step.humanTask {
                        WorkflowHumanTaskForm(task: task, onSaveDraft: { controller.editHumanDraft(stepID: step.id, value: $0) },
                            onSubmit: { value in Task { await controller.decideHuman(stepID: step.id, value: value, expectedTask: task) } },
                            onReject: { Task { await controller.decideHuman(stepID: step.id, value: nil, reject: true, expectedTask: task) } }).id(step.id).disabled(readOnly)
                    } else {
                        WorkflowWaitingDecision(controller: controller, step: step, readOnly: readOnly, preview: controller.preview).id(step.id)
                    }
                }
                if step.status != .waiting {
                WorkflowStepValues(title: workflowText(languageStore, "workflow.port.outputs"),
                                   values: step.outputs, operationID: node.operationID, portsAreInputs: false,
                                   controller: controller, onReturnText: onReturnText,
                                   allowsReturn: !readOnly, metadata: metadata,
                                   resultScope: resultRunID.flatMap { run in controller.projectID.map { project in
                                       .init(mode: .run, projectID: project, instanceID: controller.projectInstanceID, runID: run, nodeID: step.node.id, stepID: step.id)
                                   } }, scopeDescription: controller.runs.first(where: { $0.id == resultRunID }).map { run in
                                       WorkflowHumanPresentation.run(run, in: controller.runs, language: languageStore) + " · " + step.node.title + " · " + (resultRecord.map { WorkflowHumanPresentation.call($0, in: WorkflowWorkspacePanels.records(in: run), language: languageStore) } ?? "")
                                   })
                }
                WorkflowTechnicalDetails(value: "Run: " + (resultRunID?.uuidString ?? "—") + "\nCall: " + step.id.uuidString + "\nNode: " + step.node.id.uuidString + "\n" + String(describing: resultRecord?.address))
                if step.status == .partial {
                    Button(workflowText(languageStore, "workflow.action.retryFailedCandidates"),
                           systemImage: "arrow.clockwise") {
                        Task { await controller.retryFailedCandidates(stepID: step.id) }
                    }
                    .disabled(readOnly)
                }
                DisclosureGroup(workflowText(languageStore, "workspace.recordedDetails")) {
                WorkflowStepValues(
                                   title: workflowText(languageStore, "workflow.execution.inputSnapshot"),
                                   values: step.inputs, operationID: node.operationID, portsAreInputs: true,
                                   controller: controller, onReturnText: onReturnText,
                                   allowsReturn: false, metadata: metadata)
                    Text(String(describing: step.node.parameters)).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else {
                Text(workflowText(languageStore, "workflow.execution.noRuns"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func history(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.history")) {
            let related = controller.history(for: node.id).filter { resultRunID == nil || $0.id == resultRunID }
            if related.isEmpty {
                Text(workflowText(languageStore, "workflow.history.none"))
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
                    WorkflowTechnicalDetails(value: run.id.uuidString)
                    ForEach(WorkflowWorkspacePanels.records(in: run)) { call in
                        DisclosureGroup(call.step.node.title + " · " + WorkflowCanvasPresentation.statusTitle(call.step.status, language: languageStore)) {
                            if let revealLibrary {
                                Button(workspaceText(languageStore, "locateResults", "", "")) {
                                    revealLibrary(.init(controller: controller, source: .call(.init(address: call.address, stepID: call.id)), name: WorkflowHumanPresentation.run(run, in: controller.runs, language: languageStore) + " · " + WorkflowHumanPresentation.call(call, in: WorkflowWorkspacePanels.records(in: run), language: languageStore)))
                                }
                            }
                            WorkflowTechnicalDetails(value: String(describing: call.address) + "\n" + call.id.uuidString)
                            if controller.canRerunCall(call) {
                                Button(workflowText(languageStore, "workflow.scope.rerunCall")) {
                                    pendingCall = .init(address: call.address, stepID: call.step.id)
                                }.disabled(readOnly)
                            }
                            WorkflowStepValues(title: workflowText(languageStore, "workflow.port.outputs"), values: call.step.outputs, operationID: call.step.node.operationID, portsAreInputs: false, controller: controller, onReturnText: onReturnText, allowsReturn: !readOnly, metadata: metadata)
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
                        WorkflowRunRecoveryButton(controller: controller, run: run, readOnly: readOnly)
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
                Button(workflowText(language, "baseline02.ui.label.572cf45ba436"), systemImage: "chevron.left") { onClose() }
                Text(workflowText(language, "canvas.tool.fixedTitle"))
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text("v\(reference.version)").font(.caption)
            WorkflowTechnicalDetails(value: reference.id.uuidString + "\n" + reference.digest)
            if let tool {
                Text(tool.name).font(.headline)
                WorkbenchScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        WorkflowInspectorSection(workflowText(language, "canvas.tool.interface", fallback: "公开端口")) {
                            if let interface = tool.graph.interface {
                                Text(workflowText(language, "workflow.port.inputs"))
                                    .font(.subheadline.weight(.semibold))
                                ForEach(interface.inputs) { input in
                                    Text(input.name + " · " + String(describing: input.type)
                                        + (input.required ? " · 必选" : " · 可选"))
                                        .font(.callout)
                                }
                                Text(workflowText(language, "workflow.port.outputs"))
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
                                    Text(identity.detail ?? "").font(.caption).foregroundStyle(.secondary)
                                    WorkflowTechnicalDetails(value: node.operationID + "\n" + node.id.uuidString)
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
                                Text(WorkflowConnectionPresentation.title(connection, graph: tool.graph, registry: controller.registry, tools: controller.tools, language: language))
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(workflowText(language, "canvas.tool.copy"), action: onCopy)
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
                    Text(modelChoices.first(where: { $0.id == value.string })?.displayName
                         ?? consistencyText(languageStore, "copy.noModel"))
                        .font(.system(size: 13, weight: .medium))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    WorkbenchMenu(workflowText(languageStore, "workflow.action.chooseModel")) {
                        WorkbenchMenuForEach(modelChoices) { choice in
                            WorkbenchMenuAction(choice.displayName) { onChange(.text(choice.id)) }
                        }
                        if !modelChoices.isEmpty { WorkbenchMenuDivider() }
                        WorkbenchMenuAction(workflowText(languageStore, "workflow.model.import"),
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
                    .workbenchInputSurface()
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
            WorkbenchPicker(title, selection: textBinding) {
                WorkbenchChoiceForEach(choices, id: \.self) { WorkbenchChoice(WorkflowCanvasPresentation.choiceTitle(fieldID: field.id, value: $0, language: languageStore), value:$0) }
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
    let run: WorkflowRun
    let call: WorkflowPlanCallRecord
}
enum WorkflowConnectionPresentation {
    @MainActor static func title(_ connection: WorkflowConnection, graph: WorkflowGraph?, registry: WorkflowRegistry, tools: [WorkflowToolDefinition], language: UILanguageStore?, disambiguateNodeNames: Bool = true) -> String {
        func endpoint(_ id: UUID, _ port: String, input: Bool) -> String {
            guard let node = graph?.nodes.first(where: { $0.id == id }) else { return metadataText(language, "unavailableNode") }
            let definition = registry.definition(for: node, tools: tools)
            let portName = (input ? definition?.inputs : definition?.outputs)?.first(where: { $0.id == port })?.title ?? port
            // Canvas geometry changes must not sort every same-name node per wire.
            // The inspector retains the full collection's disambiguated aliases.
            let nodeName = disambiguateNodeNames
                ? WorkflowHumanPresentation.name(node, in: graph?.nodes ?? [node], language: language)
                : (node.title.isEmpty ? definition.map { WorkflowCanvasPresentation.operationTitle($0, language: language) } ?? node.operationID : node.title)
            return nodeName + " · " + WorkflowCanvasPresentation.portTitle(operationID: node.operationID,
                portID: port, fallback: portName, input: input, language: language)
        }
        return endpoint(connection.sourceNode, connection.sourcePort, input: false) + " → " + endpoint(connection.targetNode, connection.targetPort, input: true)
    }
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
                    operationID: call.step.node.operationID, value: value, run: run, call: call)
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
        DisclosureGroup(workflowText(language, "workflow.connection.inspect")) {
            if let value = WorkflowConnectionPresentation.configuredValue(source: controller.graph?.nodes.first {
                $0.id == connection.sourceNode
            }) {
                WorkflowStepValues(title: workflowText(language, "workflow.connection.configured"),
                    values: [connection.targetPort: value], operationID: "", portsAreInputs: true,
                    controller: controller, onReturnText: { _ in }, allowsReturn: false)
            }
            let snapshots = WorkflowConnectionPresentation.snapshots(connection, graphID: controller.graph?.id ?? UUID(), runs: controller.history(for: connection.targetNode))
            Text(workflowText(language, "workflow.connection.history"))
                .font(.caption).foregroundStyle(.secondary)
            if snapshots.isEmpty {
                Text(workflowText(language, "workflow.connection.noData"))
                    .font(.caption)
            }
            ForEach(snapshots.reversed()) { snapshot in
                DisclosureGroup(WorkflowHumanPresentation.run(snapshot.run, in: controller.runs, language: language) + " · " + WorkflowHumanPresentation.call(snapshot.call, in: WorkflowWorkspacePanels.records(in: snapshot.run), language: language)) {
                    WorkflowTechnicalDetails(value: snapshot.runID.uuidString + "\n" + snapshot.stepID.uuidString + "\n" + snapshot.revision.uuidString + "\n" + String(describing: snapshot.address))
                    WorkflowStepValues(title: snapshot.call.step.node.title, values: [connection.targetPort: snapshot.value],
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
        WorkbenchScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(workflowText(language, "baseline02.ui.label.572cf45ba436"), systemImage: "chevron.left") { onClose() }
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
                    Text(sourceName + " · " + WorkflowCanvasPresentation.portTitle(operationID: source.operationID, portID: connection.sourcePort, fallback: sourceDefinition?.outputs.first(where: { $0.id == connection.sourcePort })?.title ?? connection.sourcePort, input: false, language: language))
                    Image(systemName: "arrow.down").foregroundStyle(.secondary)
                    Text(targetName + " · " + WorkflowCanvasPresentation.portTitle(operationID: target.operationID, portID: connection.targetPort, fallback: targetDefinition?.inputs.first(where: { $0.id == connection.targetPort })?.title ?? connection.targetPort, input: true, language: language))
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
                Button(workflowText(language, "workflow.action.disconnect"),
                       systemImage: "link.badge.minus", role: .destructive) {
                    controller.disconnect(connection.id)
                    onClose()
                }
                .disabled(!controller.canEditCanvas)
                .accessibilityIdentifier("canvas-disconnect-" + connection.id.uuidString)
                WorkflowConnectionInspection(controller: controller, connection: connection)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .workbenchPanel(cornerRadius: 12)
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
    var metadata: SharedLibraryStore? = nil
    var resultScope: SharedLibraryQueryScope? = nil
    var displayTitles: [String: String] = [:]
    var scopeDescription: String? = nil
    @State private var resultQuery = WorkflowResultQueryState()
    @State private var annotationRequest: AssetAnnotationRequest?
    private var references: [WorkflowAssetReference] {
        var seen = Set<WorkflowAssetReference>()
        return values.keys.sorted().flatMap { values[$0].map(savedAssets) ?? [] }.filter { seen.insert($0).inserted }
    }
    private var resultIdentity: WorkflowResultQueryState.Identity { .init(controller: controller, references: references) }
    private func matches(_ reference: WorkflowAssetReference) -> Bool { portsAreInputs || resultQuery.matches(reference, store: metadata) }
    private func visible(_ value: WorkflowValue) -> Bool {
        portsAreInputs || resultQuery.keepsVisible(value, store: metadata)
    }
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if !portsAreInputs, let metadata, !references.isEmpty {
                WorkflowResultQueryControls(state: resultQuery, store: metadata, scope: resultScope, scopeDescription: scopeDescription).workbenchHelp("RESULT-FILTER")
            }
            if values.isEmpty {
                Text(workflowText(languageStore, "workflow.value.none"))
                    .foregroundStyle(.secondary)
            }
            ForEach(values.keys.sorted(), id: \.self) { port in
                if let value = values[port], visible(value) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayTitles[port] ?? WorkflowCanvasPresentation.portTitle(
                            operationID: operationID,
                            portID: port,
                            fallback: port,
                            input: portsAreInputs,
                            language: languageStore
                        )).font(.caption).foregroundStyle(.secondary)
                        switch value {
                        case .asset(let reference):
                            WorkflowAssetPreview(controller: controller, reference: reference)
                            WorkflowAssetIdentity(reference: reference)
                            if reference.kind == .text && allowsReturn {
                                Button(workflowText(languageStore, "workflow.action.returnToText"),
                                       systemImage: "arrowshape.turn.up.backward") {
                                    onReturnText(reference)
                                }
                            }
                        case .collection(let candidates):
                            ForEach(candidates.filter { $0.asset.map(matches) ?? true }) { candidate in
                                WorkflowCandidatePreview(controller: controller, candidate: candidate,
                                                         selected: false, onSelect: nil)
                            }
                        case .data(let value):
                            WorkflowDatumSnapshotView(value: value)
                        case .receipt(let receipt):
                            Text(receipt.names.joined(separator: "、"))
                            WorkflowTechnicalDetails(value: receipt.hashes.joined(separator: "\n"))
                        }
                        ForEach(savedAssets(value).filter(matches), id: \.self) { reference in
                            WorkflowAssetOrganization(controller: controller, reference: reference, metadata: metadata,
                                onQuery: portsAreInputs ? nil : { properties in resultQuery.query.properties = .merging(resultQuery.query.properties, properties) },
                                onEdit: { request in var captured = request; captured.context = scopeDescription; annotationRequest = captured })
                        }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .task(id: resultIdentity) {
            guard !portsAreInputs, metadata != nil, !references.isEmpty else { return }
            await resultQuery.load(identity: resultIdentity) { try await controller.services.store.libraryMetadataSnapshots() }
        }
        .onDisappear { resultQuery.invalidate() }
        .sheet(item: $annotationRequest) { request in
            AssetAnnotationEditor(snapshot: request.snapshot, context: request.context, validate: request.validate, save: request.save) { annotationRequest = nil }
        }
    }
    private func savedAssets(_ value: WorkflowValue) -> [WorkflowAssetReference] {
        WorkflowResultQueryState.references(in: value)
    }

}

/// One preview owns one reader, full reference and request generation. Both
/// success and failure use this path, including readers which ignore cancellation.
@MainActor @Observable final class WorkflowAssetPreviewState {
    struct Identity: Hashable {
        let controller: ObjectIdentifier
        let store: ObjectIdentifier
        let reference: WorkflowAssetReference

        @MainActor init(controller: WorkflowController, reference: WorkflowAssetReference) {
            self.controller = ObjectIdentifier(controller)
            store = ObjectIdentifier(controller.services.store)
            self.reference = reference
        }
    }

    private(set) var identity: Identity?
    private(set) var data: Data?
    private(set) var sourceMetadata: String?
    private(set) var failure: String?
    private var request: UUID?

    func invalidate() {
        request = nil; identity = nil
        data = nil; sourceMetadata = nil; failure = nil
    }

    func load(identity: Identity, preview: () async throws -> Data?, metadata: () async throws -> String) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        self.request = request; self.identity = identity
        data = nil; sourceMetadata = nil; failure = nil
        func isCurrent() -> Bool {
            !Task.isCancelled && self.request == request && self.identity == identity
        }
        do {
            let bytes = try await preview()
            guard isCurrent() else { return }
            let source = try await metadata()
            guard isCurrent() else { return }
            data = bytes; sourceMetadata = source
        } catch {
            guard isCurrent() else { return }
            data = nil; sourceMetadata = nil; failure = error.localizedDescription
        }
    }
}

/// The actual history recovery action distinguishes saving a terminal failure
/// from an explicit calculation retry. Neither decision is inferred from text.
struct WorkflowRunRecoveryButton: View {
    let controller: WorkflowController
    let run: WorkflowRun
    let readOnly: Bool
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        let savingFailure = run.status == .saving && run.planCheckpoint?.records.contains {
            $0.address.path.count == 1 && $0.step.status == .failed
        } == true
        let key = savingFailure ? "workflow.action.saveFailureRecord" : run.status == .failed ? "workflow.action.retryComputation" : run.status == .saving ? "workflow.action.resumeSaving" : "workflow.action.resume"
        let fallback = savingFailure ? "重试保存失败记录" : run.status == .failed ? "重试计算" : run.status == .saving ? "恢复保存并继续流程" : "继续流程"
        Button(workflowText(languageStore, key, fallback: fallback)) {
            Task { await controller.resume(runID: run.id) }
        }
        .disabled(readOnly)
        .accessibilityIdentifier("workflow-run-recovery-" + run.id.uuidString)
        .workbenchHelp(savingFailure ? "RECOVERY-SAVE-FAILURE" : run.status == .failed ? "RECOVERY-RECOMPUTE" : run.status == .saving ? "RECOVERY-SAVE-CONTINUE" : "DECISION-CONTINUE", unavailableReason: readOnly ? canvasHelpReason(controller, readOnly: readOnly, language: languageStore) : nil, target: "run:\(run.id):\(run.graph.id):\(run.status)")
    }
}

struct WorkflowAssetPreview: View {
    let controller: WorkflowController
    let reference: WorkflowAssetReference
    @State var state = WorkflowAssetPreviewState()
    @State private var inspectImage: NSImage?
    @Environment(\.dLanguageStore) private var languageStore
    @Environment(\.workflowViewerModel) private var viewerModel
    @Environment(\.workflowViewerOpenAsset) private var openViewerAsset

    private var identity: WorkflowAssetPreviewState.Identity { .init(controller: controller, reference: reference) }
    private var data: Data? { state.identity == identity ? state.data : nil }
    private var failure: String? { state.identity == identity ? state.failure : nil }
    private var sourceMetadata: String? { state.identity == identity ? state.sourceMetadata : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch reference.kind {
            case .text:
                if let data {
                    if let text = String(data: data, encoding: .utf8) {
                        WorkbenchScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
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
                        Button {
                            if let openViewerAsset { openViewerAsset(reference) }
                            else if let viewerModel,viewerModel.projectSession.workflow === controller {
                                do { try viewerModel.viewers.open(.init(title:controller.availableAssets.first { $0.id == reference.assetID }?.name ?? "D",subtitle:viewerModel.manifest?.name ?? "",value:.asset(reference)),model:viewerModel,language:languageStore) }
                                catch { controller.errorMessage=error.localizedDescription }
                            } else { inspectImage=image }
                        } label: {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                        }.buttonStyle(.plain).help(metadataText(languageStore, "inspectImage"))
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
                    if let openViewerAsset { openViewerAsset(reference) }
                    else { controller.mediaPreviewReference = reference }
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
                    WorkbenchScrollView { Text(sourceMetadata).font(.caption2.monospaced()).textSelection(.enabled) }
                        .frame(maxHeight: 180)
                }
            }
        }
        .sheet(isPresented: Binding(get: { inspectImage != nil }, set: { if !$0 { inspectImage = nil } })) {
            VStack {
                HStack { Button(metadataText(languageStore, "close")) { inspectImage = nil }; Spacer() }
                if let inspectImage { ScrollView([.horizontal, .vertical]) { Image(nsImage: inspectImage).resizable().scaledToFit().frame(maxWidth: 1000, maxHeight: 750) } }
            }.padding(18).frame(minWidth: 600, minHeight: 480)
        }
        .task(id: identity) {
            await state.load(identity: identity, preview: {
                [.audio, .video].contains(reference.kind) ? nil : try await controller.preview(reference)
            }, metadata: { try await controller.metadata(reference) })
        }
        .onDisappear { if state.identity == identity { state.invalidate() } }
    }

    private func previewError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
    }
}

struct WorkflowCandidatePreview: View {
    let controller: WorkflowController
    let candidate: WorkflowCandidate
    let selected: Bool
    let onSelect: (() -> Void)?
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
                if let asset = candidate.asset {
                    WorkflowAssetPreview(controller: controller, reference: asset)
                }
                Button { onSelect?() } label: { HStack {
                    Text(workflowText(
                        languageStore,
                        "workflow.candidate.seed",
                        fallback: "seed {seed}",
                        arguments: ["seed": candidate.seed]
                    )).font(.caption.monospaced())
                    Spacer()
                    if selected {
                        Label(workflowText(languageStore, "workflow.candidate.highlighted"),
                              systemImage: "checkmark.circle.fill")
                    }
                }
                }.buttonStyle(.plain).disabled(onSelect == nil)
                if let error = candidate.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .padding(7)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 8))
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
            Text(workflowText(languageStore, "workflow.decision.title"))
                .font(.headline)
            if interaction == .textReview {
                TextSourcesQuestionEditor(value: draft, editEpoch: 0,
                    isEditable: !readOnly && textReady,
                    accessibilityIdentifier: "workflow-review-text", onEdit: { value in
                        guard !readOnly && textReady else { return }
                        draft = value
                        controller.editReviewText(stepID: step.id, text: value)
                    }, liveValue: Binding(get: {
                        // The controller accepts this exact waiting step synchronously.
                        // Read its accepted draft at native update time so a retained
                        // parent's older value snapshot cannot overwrite local typing.
                        controller.runs.lazy.flatMap { WorkflowWorkspacePanels.records(in: $0) }
                            .first { $0.step.id == step.id && $0.step.node.id == step.node.id }?.step.reviewTextDraft ?? draft
                    }, set: { _ in }))
                    .frame(minHeight: 100)
                    .workbenchInputSurface()
                    .task(id: textReference?.version) { await loadDraft() }
                HStack {
                    Button(workflowText(languageStore, "workflow.action.acceptText")) {
                        decide(accept: true, text: draft, candidateID: nil)
                    }.workbenchHelp("DECISION-ACCEPT")
                        .buttonStyle(WorkbenchPrimaryButtonStyle())
                        .disabled(!textReady)
                    Button(workflowText(languageStore, "workflow.action.reject"), role: .destructive) {
                        decide(accept: false, text: nil, candidateID: nil)
                    }.workbenchHelp("DECISION-REJECT")
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
                    Button(workflowText(languageStore, "workflow.action.acceptHighlighted")) {
                        decide(accept: true, text: nil, candidateID: highlightedCandidateID)
                    }.workbenchHelp("DECISION-ACCEPT")
                    .buttonStyle(WorkbenchPrimaryButtonStyle())
                    .disabled(readOnly || highlightedCandidateID == nil ||
                              (candidates.contains { $0.error != nil } && !acceptPartial))
                    Button(workflowText(languageStore, "workflow.action.reject"), role: .destructive) {
                        decide(accept: false, text: nil, candidateID: nil)
                    }.workbenchHelp("DECISION-REJECT")
                        .disabled(readOnly)
                }
            } else {
                Text(workflowText(
                    languageStore,
                    "workflow.decision.explicit",
                    fallback: "此步骤等待明确决定。"
                )).foregroundStyle(.secondary)
                Button(workflowText(languageStore, "workflow.action.reject"), role: .destructive) {
                    decide(accept: false, text: nil, candidateID: nil)
                }.workbenchHelp("DECISION-REJECT")
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
            Button(workflowText(languageStore, "baseline02.ui.label.572cf45ba436"), systemImage: "chevron.left", action: onCancel)
            Text(preview.only
                 ? workflowText(languageStore, "workflow.plan.rerunTitle")
                 : workflowText(languageStore, "workflow.plan.runTitle"))
                .font(.title2.weight(.semibold))
            Text(workflowText(
                languageStore,
                "workflow.plan.description",
                fallback: "以下计划由运行协调器提供；界面原样显示，不推断或改写执行、复用与等待状态。"
            ))
                .foregroundStyle(.secondary)
            WorkbenchScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let lines = WorkflowCanvasPresentation.planLines(preview.lines)
                    if lines.isEmpty {
                        Text(workflowText(languageStore, "workflow.plan.empty"))
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
                Button(workflowText(languageStore, "workflow.action.cancel"), action: onCancel)
                Button(workflowText(languageStore, "workflow.plan.submit"), action: onRun)
                    .buttonStyle(WorkbenchPrimaryButtonStyle())
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
        .workbenchPanel(cornerRadius: 11)
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
        WorkflowTechnicalDetails(value: "Project: " + reference.projectID.uuidString + "\nAsset: " + reference.assetID.uuidString + "\nVersion: " + reference.version.uuidString + "\nSHA-256: " + reference.sha256)

    }
}

struct WorkflowStatusBadge: View {
    let status: WorkflowStepStatus
    let stale: Bool
    var scale: CGFloat = 1
    @Environment(\.dLanguageStore) private var languageStore
    var body: some View {
        HStack(spacing: 4 * scale) {
            Circle().fill(WorkflowCanvasPresentation.statusColor(status)).frame(width: 7 * scale, height: 7 * scale)
            Text(WorkflowCanvasPresentation.statusTitle(status, language: languageStore))
            if stale {
                Text(workflowText(languageStore, "workflow.status.staleInput"))
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11 * scale, weight: .medium))
        .padding(.horizontal, 7 * scale).padding(.vertical, 4 * scale)
        .background(.quaternary, in: Capsule())
    }
}

private enum WorkflowExampleChoice: String, CaseIterable, Identifiable {
    case text, image, file, template
    var id: String { rawValue }
    @MainActor func title(_ language: UILanguageStore?) -> String {
        switch self {
        case .text: workflowText(language, "workflow.example.text")
        case .image: workflowText(language, "workflow.example.image")
        case .file: workflowText(language, "workflow.example.file")
        case .template: workflowText(language, "workflow.example.template")
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
            && defaults == controller.services.capturedModelDefaults() && controller.canEditCanvas && !controller.isRunning
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

public enum WorkflowCanvasLibraryMode: Hashable {
    case nodes, programs, assets, text, image, video, audio, data, results
    var resourceCategory: WorkflowResourceCategory? {
        switch self { case .assets,.results: .all; case .text: .text; case .image: .image; case .video: .video; case .audio: .audio; case .data: .data; default:nil }
    }
}

enum WorkflowCanvasLayoutPolicy {
    static let minimumVisibleWidth: CGFloat = 760
    static let minimumVisibleHeight: CGFloat = 500
    static let minimumWorkspaceWidth: CGFloat = 760
    static let libraryWidth: CGFloat = WorkbenchSidebarLayout.trailingWidth
    static let inspectorWidth: CGFloat = WorkbenchSidebarLayout.leadingWidth
    static let canvasMinimumWidth: CGFloat = 360
    static let nodeWidth: CGFloat = 240
    static let zoomRange: ClosedRange<CGFloat> = 0.05...4.0

    static func usesHorizontalPanelScroll(width: CGFloat) -> Bool { false }

    static func visiblePanels(width: CGFloat, library: Bool, inspector: Bool,
                              preferLibrary: Bool) -> (library: Bool, inspector: Bool) {
        (library, inspector) // Overlay visibility does not depend on remaining center width.
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

    /// A readable summary only; the full kinds remain the compatibility contract.
    @MainActor static func portSummary(_ port: WorkflowPortDefinition, language: UILanguageStore?) -> String {
        let count = Set(port.kinds).count
        let types: String
        if Set(port.kinds) == Set(WorkflowDataKind.allCases) {
            types = workflowText(language, "workflow.port.anySupported")
        } else if count > 3 {
            types = workflowText(language, "workflow.port.typeCount", arguments: ["count": String(count)])
        } else {
            return portDetail(port, language: language)
        }
        let requirement = workflowText(language, port.required ? "workflow.port.required" : "workflow.port.optional", fallback: port.required ? "必选" : "可选")
        return workflowText(language, "workflow.port.detail", arguments: ["kinds": types, "requirement": requirement])
    }

    static func portDetail(_ port: WorkflowPortDefinition) -> String {
        "\(port.kinds.map { kind($0) }.joined(separator: "/")) · \(port.required ? "必选" : "可选")"
    }

    @MainActor static func portDetail(_ port: WorkflowPortDefinition, language: UILanguageStore?) -> String {
        let kinds = port.kinds.map { kind($0, language: language) }.joined(separator: "/")
        let requirement = port.required
            ? workflowText(language, "workflow.port.required")
            : workflowText(language, "workflow.port.optional")
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
        // A published tool's ports belong to its exact version's interface.
        // Common IDs such as "input" must not overwrite its registered labels.
        if operationID == "d.control.invoke" { return fallback }
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

@MainActor func workflowProgressText(_ message: WorkflowProgressMessage, language: UILanguageStore?) -> String {
    if message.code.hasPrefix("phase.") { return workspaceText(language, message.code) }
    return workflowText(language, "workflow.progress." + message.code, arguments: message.arguments)
}
