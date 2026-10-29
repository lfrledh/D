import AppKit
import DWorkbench
import Foundation
import Observation
import SwiftUI

/// Per-mounted-canvas camera. Only the surface and zoom control observe zoom;
/// navigation bookkeeping does not invalidate the libraries or workspace shell.
@MainActor @Observable
private final class WorkflowCanvasCameraPresentation {
    var zoom: CGFloat = 1
    @ObservationIgnored var visibleCenter = CGPoint(x: 550, y: 426)
    @ObservationIgnored var insertionPoint = CGPoint(x: 170, y: 130)
    @ObservationIgnored var context: WorkflowCanvasViewContext?
    @ObservationIgnored var owner: ObjectIdentifier?
    @ObservationIgnored var restoredOwner: ObjectIdentifier?
    @ObservationIgnored var restoringCenter: CGPoint?

    init(context: WorkflowCanvasViewContext? = nil, owner: ObjectIdentifier? = nil) {
        self.context = context; self.owner = owner
    }
}

/// Construct the binding while evaluating a camera-only child, not the workspace
/// GeometryReader (Binding construction may read its initial value).
private struct WorkflowCanvasCameraScope<Content: View>: View {
    let camera: WorkflowCanvasCameraPresentation
    let controller: WorkflowController
    let context: WorkflowCanvasViewContext
    let changed: () -> Void
    @ViewBuilder let content: (Binding<CGFloat>) -> Content

    var body: some View {
        content(Binding(get: { camera.zoom }, set: { value in
            let current = WorkflowCanvasViewContext(projectID: controller.projectID,
                rootGraphID: controller.rootGraph?.id,
                bodyPath: controller.bodyPath.map(WorkflowCanvasBodyLocation.init), instanceID: controller.projectInstanceID)
            guard camera.owner == ObjectIdentifier(controller),
                  camera.context == context, current == context else { return }
            camera.restoringCenter = nil // A new user zoom supersedes a pending restoration.
            camera.zoom = value
            changed()
        }))
    }
}

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
    @Environment(\.workbenchSaveAction) private var sharedSaveCommand
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
    private let onDropCanvasFile: (URL, CGPoint) -> Bool
    private let onQuickUse: ((WorkflowNode) -> Void)?
    private let libraryContent: ((WorkflowCanvasLibraryMode, @escaping () -> CGPoint?, @escaping () -> Void) -> AnyView)?
    private let libraryHeaderContent: ((WorkflowCanvasLibraryMode) -> AnyView)?
    private let libraryProjectName: String
    private let onSharedAssetDrop: ((UUID, UUID?, UUID, CGPoint, WorkflowCanvasInsertionTarget) -> Bool)?
    private let acceptsLegacyAsset: ((UUID, UUID) -> Bool)?
    private let onDestination: () -> Void
    private let onPublishText: () -> Void
    private let publishDocumentDescription: String?
    private var onExpandLibrary: ((WorkflowCanvasLibraryMode, WorkflowLibraryContext?, @escaping () -> Void, WorkflowContainerNavigation) -> Void)? = nil
    private let destinationEnabled: Bool
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
        var copy = self; copy._panelsState = State(initialValue: panels); copy._activityVisible = State(initialValue: panels.runID != nil); copy._recordsDetail = State(initialValue: panels.runID != nil); return copy
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

    @Environment(\.workbenchContentVisible) private var contentVisible
    @Environment(\.dLanguageStore) private var languageStore

    @Environment(\.chatDisplayPreferences) private var displayPreferences
    @State private var commandScope = WorkbenchCommandScope()
    @State private var narrowLibrary = false
    @State private var requestedPanelWidths = WorkbenchPanelWidths(leading: 320, trailing: 320)
    @State private var runSettingsVisible = false
    @State private var runOptions = WorkflowWorkspaceRunOptions()
    @State private var recordsDetail = false
    @State private var visitedRecords = false
    @State private var visitedRecordsDetail = false
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
    @State private var camera = WorkflowCanvasCameraPresentation()
    @State private var canvasTool: WorkflowCanvasTool = .pointer
    @State private var canvasViewport: WorkflowCanvasViewportMeasurement?
    @State private var measuredCardSizes: [UUID: CGSize] = [:]
    @State private var navigationRequest: WorkflowCanvasNavigationRequest?
    @State private var viewportInteractionLocked = false
    @FocusState private var workspaceKeyboardFocused: Bool
    @State private var localViewStates = WorkflowCanvasViewStateStore()
    private var persistedViewStates: WorkflowCanvasViewStateStore?
    private var viewStates: WorkflowCanvasViewStateStore { persistedViewStates ?? localViewStates }
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
        onDropCanvasFile: @escaping (URL, CGPoint) -> Bool = { _, _ in false },
        onQuickUse: ((WorkflowNode) -> Void)? = nil,
        libraryContent: ((WorkflowCanvasLibraryMode, @escaping () -> CGPoint?, @escaping () -> Void) -> AnyView)? = nil,
        libraryHeaderContent: ((WorkflowCanvasLibraryMode) -> AnyView)? = nil,
        libraryProjectName: String = "",
        onSharedAssetDrop: ((UUID, UUID?, UUID, CGPoint, WorkflowCanvasInsertionTarget) -> Bool)? = nil,
        acceptsLegacyAsset: ((UUID, UUID) -> Bool)? = nil,
        captureControls: AnyView = AnyView(EmptyView()),
        publishDocumentDescription: String? = nil,
        destinationEnabled: Bool = true
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
        self.onDropCanvasFile = onDropCanvasFile
        self.onSharedAssetDrop = onSharedAssetDrop
        self.acceptsLegacyAsset = acceptsLegacyAsset
        self.onQuickUse = onQuickUse; self.libraryContent = libraryContent
        self.libraryHeaderContent = libraryHeaderContent
        self.libraryProjectName = libraryProjectName
        self.onDestination = onDestination
        self.onPublishText = onPublishText
        self.publishDocumentDescription = publishDocumentDescription; self.destinationEnabled = destinationEnabled
        self.onReturnText = onReturnText
        _camera = State(initialValue: WorkflowCanvasCameraPresentation(context: WorkflowCanvasViewContext(projectID: controller.projectID,
            rootGraphID: controller.rootGraph?.id,
            bodyPath: controller.bodyPath.map(WorkflowCanvasBodyLocation.init), instanceID: controller.projectInstanceID), owner: ObjectIdentifier(controller)))
    }

    func rememberingCanvas(in store: WorkflowCanvasViewStateStore) -> Self {
        var copy = self; copy.persistedViewStates = store; return copy
    }
    func expandingLibrary(_ action: ((WorkflowCanvasLibraryMode, WorkflowLibraryContext?, @escaping () -> Void, WorkflowContainerNavigation) -> Void)?) -> Self {
        var copy = self; copy.onExpandLibrary = action; return copy
    }
    private var containerNavigation: WorkflowContainerNavigation {
        WorkflowContainerNavigation(reveal: revealLibrary, source: { call in
            guard let run = controller.runs.first(where: { $0.id == call.address.runID }),
                  let record = WorkflowWorkspacePanels.records(in: run).first(where: { $0.id == call.stepID && $0.address == call.address }) else { return }
            panelsState.selectRun(run.id); panelsState.selectResult(node: record.step.node.id, call: call)
            activityVisible = true; recordsDetail = true; workspaceDraft = nil; runSettingsVisible = false
        })
    }
    public var body: some View {
        #if DEBUG
        let _ = WorkflowCanvasUpdateProbe.canvasBody?()
        let _ = WorkflowCanvasUpdateProbe.workspace?(.init(draftTarget:workspaceDraft?.target,open:{id,mode in setRunTarget(id);runRange=mode;presentWorkspacePlan(id,mode:mode)},target:setRunTarget,range:setRunRange))
        #endif
        canvasContent
        .environment(\.workflowContainerNavigation, containerNavigation)
        .environment(\.workbenchMenuContext, canvasMenuContext)
        .workbenchConfirmation(text("workflow.scope.rerunCall","重新运行具体调用"),isPresented:Binding(get:{pendingHistoryRetry != nil},set:{if !$0 { pendingHistoryRetry=nil }})) {
            Button(workspaceText(languageStore, "retryFrozen")) {
                if let call=pendingHistoryRetry { pendingHistoryRetry=nil;Task { await controller.rerunCall(call) } }
            }.keyboardShortcut(.defaultAction)
            Button(workspaceText(languageStore, "cancel"),role:.cancel) { pendingHistoryRetry=nil }.keyboardShortcut(.cancelAction)
        } message: { Text(workspaceText(languageStore, "retryHistoryExplanation")) }
        .workbenchSheet(isPresented: $toolsPresented, title: workflowText(languageStore, "childPanel.name.tools")) {
            VStack(alignment: .leading) {
                WorkbenchRequestCloseButton(title: workflowText(languageStore, "childPanel.close"), fallback: { toolsPresented = false }).padding([.top, .leading])
                WorkflowToolPanel(controller: controller, selectionOnly: extractSelection)
            }.workbenchPresentation()
        }
        .workbenchSheet(isPresented: $interfacePresented, title: workflowText(languageStore, "childPanel.name.interface")) {
            if let graph = controller.graph {
                VStack(alignment: .leading) {
                    Button(workflowText(languageStore, "baseline02.ui.label.572cf45ba436"), systemImage: "chevron.left") { interfacePresented = false }.padding([.top, .leading])
                    WorkbenchScrollView { WorkflowGraphInterfaceEditor(graph: Binding(get: { controller.graph?.id == graph.id ? controller.graph! : graph }, set: { controller.updateInterface($0.interface, in: graph.id) }), registry: controller.registry, tools: controller.tools).padding() }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).workbenchPresentation()
            }
        }
        .onChange(of: controller.graph?.id) { _, _ in
            pendingConnection = nil
            selectedConnectionID = nil
            runPreview = nil
        }
        .onChange(of: runContext) { _, _ in
            runTarget = nil; runPreview = nil; scopePresentation = nil; runOptions.choices = [:]
        }
        .onChange(of: ObjectIdentifier(controller)) { _, _ in
            panelsState = .init(); workspaceDraft=nil;runOptions = .init();runSettingsVisible=false;recordsDetail=false;visitedRecords=false;visitedRecordsDetail=false;resourceContext=nil;returnResourceCategory=nil
            camera.owner = ObjectIdentifier(controller)
            restoreInitialViewContext()
        }
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
        .onAppear { restoreInitialViewContext() }
        .onDisappear {
            viewStates.flush()
            if camera.owner == ObjectIdentifier(controller) { camera.owner = nil; camera.context = nil }
        }
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

    private var canvasContent: some View {
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
        // Keyboard focus belongs to the workspace boundary. Inferring its ring
        // from changing node/glass pixels rasterizes the whole workspace during
        // interaction; an explicit focus-only shape leaves child focus and hits intact.
        .contentShape(.focusEffect, Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($workspaceKeyboardFocused)
        .onChange(of: contentVisible) { _, visible in
            if !visible { workspaceKeyboardFocused = false }
        }
        .workflowKeyboardCommands(performKeyboardCommand)
        .background(WorkbenchCommandWindow(scope: commandScope))
        .focusedSceneValue(\.workbenchCanvas, contentVisible ? canvasCommands : nil)
        .workbenchPopover(isPresented: $portLegendPresented, title: workflowText(languageStore, "childPanel.name.legend")) { portLegend }

    }
    private var canvasMenuContext: String {
        ["canvas", String(describing: ObjectIdentifier(controller)), String(describing: controller.projectID),
         String(describing: controller.projectInstanceID), String(describing: controller.bodyPath),
         controller.rootGraph?.revision.uuidString ?? "none", controller.rootGraph?.id.uuidString ?? "none",
         controller.graph?.id.uuidString ?? "none", controller.graph?.revision.uuidString ?? "none"].joined(separator: ":")
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
        case .activity: panelsState.output = .overview; activityVisible = true; recordsDetail = false; workspaceDraft = nil; runSettingsVisible = false
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

    @Environment(\.workbenchModeSize) private var modeSize
    @Environment(\.workbenchWindowControlSize) private var windowControlSize
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
                WorkflowCanvasCameraScope(camera: camera, controller: controller,
                    context: viewContext, changed: rememberViewContext) { zoom in
                let measuredContext = viewContext
                WorkflowGraphSurface(controller: controller, graph: controller.graph, zoom: zoom,
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
                        guard camera.owner == ObjectIdentifier(controller),
                              camera.context == measuredContext, viewContext == measuredContext else { return }
                        measuredCardSizes[id] = size
                        nodeSizeObserver?(id, size)
                    },
                    viewportSizeObserver: { canvasViewport = $0 },
                    portCenterObserver: portCenterObserver,
                    onScrollObservation: { context, observation in
                        guard camera.owner == ObjectIdentifier(controller),
                              camera.restoredOwner == ObjectIdentifier(controller) else { return }
                        if observation.isGestureEnd {
                            // An interrupted pan may finish after another graph has mounted.
                            // Save its captured context without moving the new graph's insertion point.
                            viewStates.capture(zoom: observation.zoom, rawVisibleCenter: observation.visibleRawCenter,
                                selectedNodeID: viewStates.state(for: context)?.selectedNodeID, for: context, makeCurrent: false)
                        }
                        guard context == viewContext, camera.context == context else { return }
                        if observation.isGestureEnd { camera.restoringCenter = nil }
                        if let target = camera.restoringCenter {
                            guard abs(observation.zoom - camera.zoom) < 0.0001,
                                  observation.hasReachedRestoredCenter(target) else { return }
                            camera.restoringCenter = nil
                        }
                        camera.visibleCenter = observation.visibleRawCenter
                        camera.insertionPoint = observation.visibleRawCenter
                        rememberViewContext()
                        scrollObserver?(context, observation)
                    },
                    onDropItem: dropItem,
                    onDropCanvasFile: onDropCanvasFile,
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
                    }, onClearSelection: { panelsState.clearSelection() },
                    onRequestKeyboardFocus: {
                        if contentVisible { workspaceKeyboardFocused = true }
                    })

                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                }.frame(width: targetCanvasWidth)
                    .workbenchMeasureLayout("workflow-center")
                .transaction { $0.animation = nil }
                    .frame(maxWidth: .infinity).clipped()
                WorkbenchSidebar(leading: true, expanded: shown.inspector,
                    title: workspaceText(languageStore, "operations"), identifier: "canvas-inspector-toggle",
                    hostIdentifier: "canvas-inspector-host", toggle: {
                        showInspector = !shown.inspector; narrowLibrary = false
                    }, actions: { AnyView(preparationActions) }) { preparationPanel }
                    .overlay(alignment: .trailing) { if shown.inspector { panelResizeHandle(leading: true) } }
                    .frame(width: shown.inspector ? panelWidths.leading : 48, alignment: .leading)
                    // The sidebar clips its own content; this layout slot must
                    // neither crop the glass shadow nor animate across the button.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.bottom, 72)
                WorkbenchSidebar(leading: false, expanded: shown.library,
                    title: layoutText(languageStore, "assetLibrary"), identifier: "canvas-library-toggle",
                    hostIdentifier: "canvas-library-host", toggle: {
                        showLibrary = !shown.library; narrowLibrary = true
                    }, actions: { AnyView(resourceActions) }) { resourcePanel }
                    .overlay(alignment: .leading) { if shown.library { panelResizeHandle(leading: false) } }
                    .frame(width: shown.library ? panelWidths.trailing : 48, alignment: .trailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .padding(.horizontal, 16)
            VStack(spacing: 0) {
                secondaryRunSurface(width: width, height: height)
                    .padding(.bottom, workspaceDraft != nil || runSettingsVisible || activityVisible ? 8 : 0)
                runDock(width: width)
            }.padding(.bottom, 16)
            let toolFrame = WorkbenchFloatingLayout.canvasTools(viewport: .init(width: width, height: height),
                rightPanelWidth: shown.library ? panelWidths.trailing : nil, mode: modeSize,
                runPanelHeight: workspaceDraft != nil || runSettingsVisible || activityVisible ? WorkbenchFloatingLayout.runPanelHeight(available: height) : 0)
            cornerTools(fitReady: fitReady, targetWidth: targetCanvasWidth)
                .frame(width: 88, height: 40).position(x: toolFrame.midX, y: toolFrame.midY)
                .workbenchMorph(value: toolFrame)
        }.overlay(alignment: .top) { captureControls.padding(.top, 8) }
        .padding(.top, 8).environment(\.workbenchPanelWidths, panelWidths)
    }

    private func secondaryRunSurface(width: CGFloat, height: CGFloat) -> some View {
        let opened = workspaceDraft != nil || runSettingsVisible || activityVisible
        let panelHeight = WorkbenchFloatingLayout.runPanelHeight(available: height)
        return ZStack(alignment: .bottom) {
            if visitedRecords || activityVisible {
                retained(recordsPanel, visible: activityVisible && workspaceDraft == nil && !runSettingsVisible, id: "workflow-records-retained")
                    .frame(width: min(440, width - 32), height: panelHeight)
                    .background {
                        if activityVisible && workspaceDraft == nil && !runSettingsVisible { Color.clear.workbenchPanel(cornerRadius: 18) }
                    }
            }
            if let draft = workspaceDraft {
                WorkflowWorkspaceRunPlan(controller: controller, draft: draft, close: { workspaceDraft = nil },
                    inputsChanged: { planInputLabels = $0 }, preview: { value, call, title, port in openValue(value, call, title, port: port) },
                    options: $runOptions, settings: { workspaceDraft = nil; runSettingsVisible = true })
                    .frame(width: min(440, width - 32), height: panelHeight).workbenchPanel(cornerRadius: 18)
            } else if runSettingsVisible {
                runSettings.frame(width: min(360, width - 32), height: panelHeight).workbenchPanel(cornerRadius: 18)
            }
        }.frame(height: opened ? panelHeight : 0, alignment: .bottom)
            .onChange(of: activityVisible, initial: true) { _, visible in if visible { visitedRecords = true } }
    }

    private func panelResizeHandle(leading: Bool) -> some View {
        WorkflowPanelResizeHandle(width: Binding(
            get: { leading ? requestedPanelWidths.leading : requestedPanelWidths.trailing },
            set: { if leading { requestedPanelWidths.leading = $0 } else { requestedPanelWidths.trailing = $0 } }), leading: leading)
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
                }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 16)
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
                    libraryContent(tab == .programs ? .programs : .nodes, libraryInsertionPoint, { showInspector = false })
                } else if tab == .models {
                    WorkflowNodeLibrary(controller: controller, tagStore: nodeTags, metadata: metadata) { entry in
                        controller.addNode(operationID: entry.operation.id, modelID: entry.model?.id,
                            x: camera.insertionPoint.x, y: camera.insertionPoint.y)
                    }
                } else {
                    WorkflowNodeLibrary(controller:controller,tagStore:nodeTags,metadata:metadata) { entry in
                        controller.addNode(operationID:entry.operation.id,modelID:entry.model?.id,x:camera.insertionPoint.x,y:camera.insertionPoint.y)
                    }
                }
            }
        }
    }
    private func manageCustomNodes() { extractSelection = false; toolsPresented = true }
    @ViewBuilder private var preparationActions: some View {
        HStack(spacing: 8) {
        if panelsState.preparation != .configuration {
            if panelsState.preparation == .programs {
                WorkbenchMenu {
                    WorkbenchMenuAction(layoutText(languageStore, "manageNodes"), action: manageCustomNodes).featureHelp("MENU-FLOW-CUSTOM", language: languageStore)
                } label: { Image(systemName: "ellipsis") }
                    .help(layoutText(languageStore, "manageNodes")).accessibilityLabel(layoutText(languageStore, "manageNodes"))
                    .accessibilityIdentifier("workflow-program-actions")
            }
            Button { onExpandLibrary?(panelsState.preparation == .programs ? .programs : .nodes, nil, {}, containerNavigation) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .disabled(onExpandLibrary == nil).help(layoutText(languageStore, "expandNodes")).accessibilityLabel(layoutText(languageStore, "expandNodes"))
                .accessibilityIdentifier("workflow-expand-nodes")
        }
        }
    }
    private var resourceActions: some View {
        HStack(spacing: 8) {
            Button(action: onImportAsset) { Image(systemName: "square.and.arrow.down") }
                .disabled(!controller.canEditCanvas).help(layoutText(languageStore, "importAsset")).accessibilityLabel(layoutText(languageStore, "importAsset"))
                .accessibilityIdentifier("workflow-import-asset")
            Button {
                let captured = resourceContext
                onExpandLibrary?(resourceCategory.mode, captured, { if resourceContext == captured { clearLibraryLocation() } }, containerNavigation)
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .disabled(onExpandLibrary == nil).help(layoutText(languageStore, "expandAssets")).accessibilityLabel(layoutText(languageStore, "expandAssets"))
                .accessibilityIdentifier("workflow-expand-assets")
            if let libraryHeaderContent { libraryHeaderContent(resourceCategory.mode).environment(\.workflowLibraryContext, resourceContext) }
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
            if !libraryProjectName.isEmpty { Text(libraryProjectName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12) }
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
                            retained(libraryContent(tab.mode,libraryInsertionPoint,{showLibrary=false})
                                .environment(\.workflowLibraryContext,resourceContext),visible:resourceCategory == tab,id:"workflow-resource-"+tab.rawValue)
                        } else {
                            retained(WorkflowAssetLibrary(controller:controller,metadata:metadata,onAdd:{project,asset in
                                if controller.graph == nil { controller.addBlankGraph() }
                                guard let target=controller.canvasInsertionTarget() else { return }
                                let point = camera.insertionPoint
                                Task { await controller.addAssetNode(projectID:project,assetID:asset,x:point.x,y:point.y,target:target) }
                            },onImport:onImportAsset,onDropFile:onDropFile),visible:resourceCategory == tab,id:"workflow-resource-"+tab.rawValue)
                        }
                    }
                }
            }
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
                (.batches, workspaceText(languageStore, "batches"))], helpPrefix: "TAB-WORKFLOW-RIGHT-", paintsPlate: false)
            WorkbenchPicker(text("workspace.selectedRun", "所选运行"), selection: Binding(get: { panelsState.runID }, set: { panelsState.selectRun($0) })) {
                WorkbenchChoice(text("workspace.chooseRun", "选择运行记录"), value:UUID?.none)
                WorkbenchChoiceForEach(controller.runs.reversed()) { run in
                    WorkbenchChoice(WorkflowHumanPresentation.run(run, in: controller.runs, stages: controller.batchStages, language: languageStore), value:Optional(run.id))
                }
            }.padding(.horizontal, 10).accessibilityIdentifier("workflow-result-run").workbenchHelp("RESULT-RUN")
            ZStack {
                if visitedOutput.contains(.node) || panelsState.output == .node {
                    retained(resultsPanel.buttonStyle(WorkbenchGlassButtonStyle()).textFieldStyle(WorkbenchGlassTextFieldStyle()), visible: panelsState.output == .node, id: "workflow-results-host")
                }
                retained(runOverview.buttonStyle(WorkbenchGlassButtonStyle()).textFieldStyle(WorkbenchGlassTextFieldStyle()), visible: panelsState.output == .overview, id: "workflow-overview-host")
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
                        HStack { Text(record.step.node.title).font(.headline);Spacer();WorkflowStatusBadge(status:record.step.status,comparison:.matching) }
                        if let error=record.step.error { WorkbenchIssueText(raw: error, key: record.step.errorCode).foregroundStyle(.red).textSelection(.enabled) }
                        if record.step.status == .waiting,let run=selectedResultRun {
                            Button(workspaceText(languageStore, "viewReadonly"),systemImage:"arrow.up.right.square") { openCall(run,record:record) }
                                .disabled(viewerModel == nil)
                            if let task = record.step.humanTask {
                                WorkflowHumanTaskForm(task: task,
                                    onSaveDraft: { controller.editHumanDraft(stepID: record.id, value: $0) },
                                    onSubmit: { value in Task { await controller.decideHuman(stepID: record.id, value: value, expectedTask: task) } },
                                    onReject: { Task { await controller.decideHuman(stepID: record.id, value: nil, reject: true, expectedTask: task) } }, flatControls: true)
                                    .id(record.id).disabled(controller.isRunning || isReadOnly)
                            } else {
                                WorkflowWaitingDecision(controller: controller, step: record.step, readOnly: isReadOnly,
                                    preview: controller.preview, flatControls: true).id(record.id).disabled(controller.isRunning)
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
                        revealLibrary(.init(controller: controller, source: .run(run.id), name: WorkflowHumanPresentation.run(run, in: controller.runs, stages: controller.batchStages, language: languageStore)))
                    }.accessibilityIdentifier("run-locate-results")
                    Text(run.graph.name).font(.headline)
                    Text(WorkflowHumanPresentation.runStatus(run, language: languageStore)).font(.title3)
                    Text(run.graph.nodes.first(where: { $0.id == run.targetNodeID })?.title ?? text("workspace.unavailableTarget", "目标已不可访问")).font(.callout)
                    if let issue = run.planCheckpoint?.error {
                        let ended = [.cancelled, .rejected].contains(run.status) && run.planCheckpoint?.state == .cancelled && run.planCheckpoint?.records.contains { $0.step.humanTask?.rejected == true } == true
                        WorkbenchIssueText(raw: issue, key: ended ? "workflow.human.ended" : nil).foregroundStyle(.red)
                    }
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
                                WorkflowStatusBadge(status: record.step.status, comparison: .matching)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).padding(8)
                            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
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
        case .library, .libraryItems:
            guard let payload = value.libraryPayload, let target = controller.canvasInsertionTarget(), controller.assetLibraryOwner == payload.owner else { return false }
            Task {
                do {
                    let sources = try await controller.resolveLibraryDrop(payload.items, owner: payload.owner, target: target)
                    try await controller.insertLibrarySources(sources, owner: payload.owner, target: target, x: point.x, y: point.y) }
                catch { controller.reportIssue(.init(presenting: error, fallbackCode: "container.issue.actionFailed")) }
            }
            return true
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
        let commands = canvasCommands
        return HStack(spacing: 12) {
            if !controller.bodyPath.isEmpty {
                Button(text("workflow.language.control.back", "返回上一级"), systemImage: "arrow.up.backward") {
                    rememberViewContext(); controller.closeBody()
                }.frame(height: 32)
            }
            WorkbenchMenu {
                WorkbenchSubmenu(text("workflow.management.switch", "切换工作流")) {
                    WorkbenchMenuForEach(Array(commands.workflowChoices.indices), id: \.self) { i in
                        let item = commands.workflowChoices[i]
                        WorkbenchMenuAction(item.command.title, systemImage: item.selected ? "checkmark" : nil, action: item.command.action).disabled(!item.command.isEnabled)
                    }
                }
                WorkbenchMenuDivider()
                if let new = commands.workflow.first { WorkbenchMenuAction(new.title, action: new.action).disabled(!new.isEnabled) }
                WorkbenchSubmenu(consistencyText(languageStore, "menu.flow.templates")) {
                    WorkbenchMenuForEach(Array(commands.templates.indices), id: \.self) { i in
                        let item = commands.templates[i]
                        WorkbenchMenuAction(item.title, action: item.action).disabled(!item.isEnabled)
                    }
                }
                WorkbenchMenuDivider()
                if let save = commands.save { WorkbenchMenuAction(save.title, action: save.action).keyboardShortcut("s").disabled(!save.isEnabled) }
                WorkbenchMenuForEach(Array(commands.workflow.dropFirst().indices), id: \.self) { i in
                    let item = commands.workflow[i]
                    WorkbenchMenuAction(item.title, action: item.action).disabled(!item.isEnabled)
                        .help(i == 1 ? text("workflow.management.interfaceHelp", "设置这个工作流对外提供的输入和输出。") : i == 2 ? layoutText(languageStore, "exportHelp") : publishDocumentDescription ?? layoutText(languageStore, "noDocument"))
                }
            } label: {
                HStack(spacing: 4) {
                    Text(text("semantics.flowPrefix", "工作流：") + (controller.rootGraph?.name ?? text("workflow.toolbar.noGraph", "选择工作流"))).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption)
                }
            }.frame(height: 32).accessibilityIdentifier("workflow-management-menu")
                .help(controller.rootGraph?.name ?? text("workflow.toolbar.noGraph", "选择工作流"))
            if !controller.bodyPath.isEmpty { Text(bodyBreadcrumb).foregroundStyle(.secondary).lineLimit(1) }
            Text(text("workflow.management." + controller.savePresentation, "")).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("workflow-save-status")
            if let retry = commands.retrySave { Button(retry.title, action: retry.action).disabled(!retry.isEnabled) }
            if controller.presentationEditingOriginalID == controller.rootGraph?.id {
                Label(consistencyText(languageStore, "copy.runningWorkflow"), systemImage: "lock").help(consistencyText(languageStore, "copy.copyOnEdit")).font(.caption).foregroundStyle(.secondary)
            } else if controller.presentationCopySourceID != nil { Text(text("workspace.editingCopy", "编辑副本")).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
        }.buttonStyle(WorkbenchGlassButtonStyle()).padding(.leading, max(128, 16 + windowControlSize.width + 12)).padding(.trailing, 18).padding(.vertical, 10).padding(.top, 6)
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
        runPreview = nil;workspaceDraft=nil;planInputLabels=[:];runOptions.choices=[:]
    }
    private func setRunRange(_ value:Int) {
        runRange=value;runPreview=nil;workspaceDraft=nil;planInputLabels=[:];runOptions.choices=[:]
    }
    private var recoveryRuns: [WorkflowRun] {
        controller.runs.reversed().filter { WorkflowCanvasPresentation.canResume($0.status) }
    }
    private var recoveryRun: WorkflowRun? {
        if let selectedResultRun, WorkflowCanvasPresentation.canResume(selectedResultRun.status) { return selectedResultRun }
        return recoveryRuns.count == 1 ? recoveryRuns.first : nil
    }
    private var canvasCommands: WorkbenchCanvasCommands {
        let context = runContext
        func action(_ key: String, enabled: Bool = true, editing: Bool = false, _ perform: @escaping () -> Void) -> WorkbenchGenerationCommand {
            .init(title: workflowText(languageStore, key), isEnabled: enabled && contentVisible && !toolsPresented && !interfacePresented) {
                guard commandScope.permitsCommands, contentVisible, context == runContext, !toolsPresented, !interfacePresented,
                      NSApp.keyWindow?.attachedSheet == nil, !editing || !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
                perform()
            }
        }
        var commands = WorkbenchCanvasCommands(edit: [
            action("workflow.action.undo", enabled: controller.canEditCanvas && controller.canUndo, editing: true) { controller.undo() },
            action("workflow.action.redo", enabled: controller.canEditCanvas && controller.canRedo, editing: true) { controller.redo() },
            action("workflow.selection.all", editing: true) { controller.selectedNodeID = nil; selectedConnectionID = nil; controller.selectedNodeIDs = Set(controller.graph?.nodes.map(\.id) ?? []) },
            action("workflow.selection.clear", editing: true) { controller.selectedNodeID = nil; controller.selectedNodeIDs = []; selectedConnectionID = nil },
            action("refinement.workflow.extractSelection", enabled: controller.canEditCanvas && !selectedNodes.isEmpty, editing: true) {
                if let node = selectedNodes.first, selectedNodes.count == 1 { controller.selectedNodeIDs = [node.id] }
                extractSelection = true; toolsPresented = true
            }
        ], legend: action("refinement.workflow.typeLegend") { portLegendPresented = true })
        commands.scope = commandScope
        commands.sidebars = [action("systemMenu." + (showInspector ? "hideLeft" : "showLeft")) { showInspector.toggle() },
                             action("systemMenu." + (showLibrary ? "hideRight" : "showRight")) { showLibrary.toggle() }]
        // Do not read the observable zoom here: this provider is on the retained
        // page, while only the camera leaf subscribes to continuous zoom updates.
        commands.zoom = [action("systemMenu.zoomIn", enabled: !viewportInteractionLocked) { changeMenuZoom(multiplier: 1.2) },
                         action("systemMenu.zoomOut", enabled: !viewportInteractionLocked) { changeMenuZoom(multiplier: 1 / 1.2) },
                         action("systemMenu.actualSize", enabled: !viewportInteractionLocked) { changeMenuZoom(actual: true) },
                         action("systemMenu.fit", enabled: !viewportInteractionLocked && canvasViewport != nil) { if let canvasViewport { fitAllNodes(targetWidth: canvasViewport.clip.width) } }]
        commands.run = action("workflow.dock.run", enabled: !controller.isRunning && !controller.hasPendingSaves && validRunTarget != nil && controller.canEditCanvas && controller.bodyPath.isEmpty) {
            if let target = validRunTarget { presentWorkspacePlan(target.id, mode: runRange) }
        }
        commands.settings = action("systemMenu.runSettings", enabled: !controller.isRunning && !controller.hasPendingSaves) { toggleRunSettings() }
        let activeRun = controller.activePresentationRun?.id
        commands.pause = action(controller.activeBatchID != nil ? "metadata.panel.workspace.batchPauseReview" : "systemMenu.pause", enabled: controller.isRunning && controller.canPausePresentation && controller.activePresentationRun?.status != .cancelling) { if let activeRun, controller.activePresentationRun?.id == activeRun, controller.isRunning && controller.canPausePresentation && controller.activePresentationRun?.status != .cancelling { controller.pause() } }
        let recovery = WorkflowDockRecovery.capture(controller)
        let batchRecovery = recovery.soleTarget.map { if case .stage = $0 { return true }; return false } ?? false
        commands.resume = action(batchRecovery ? "metadata.panel.workspace.resumeQueue" : "systemMenu.resume", enabled: !isReadOnly && !controller.isRunning && !controller.hasPendingSaves && !recovery.targets.isEmpty) {
            WorkflowDockRecovery.perform(recovery, stopping: false, controller: controller, showRecords: showRecoveryRecords)
        }
        commands.stop = action(controller.activeBatchID != nil ? "metadata.panel.workspace.batchCancel" : batchRecovery ? "workflow.dock.stopRemaining" : "systemMenu.stop", enabled: !controller.isSaving && controller.activePresentationRun?.status != .cancelling && (controller.isRunning || (!isReadOnly && !recovery.targets.isEmpty))) {
            if let activeRun {
                Task { if controller.isRunning && controller.activePresentationRun?.id == activeRun && context == runContext { await controller.cancel() } }
            } else { WorkflowDockRecovery.perform(recovery, stopping: true, controller: controller, showRecords: showRecoveryRecords) }
        }
        if controller.hasPendingSaves {
            let pending = pendingSavingTargets
            commands.retrySave = action("systemMenu.retrySave", enabled: !controller.isRunning && !controller.isSaving) {
                if pending.isEmpty { Task { guard context == runContext else { return }; await controller.save() } }
                else { retryPendingSaving(pending, context: context) }
            }
        }
        commands.workflow = [action("systemMenu.blankFlow", enabled: controller.canEditCanvas) { controller.addBlankGraph() },
            action("workflow.language.interface", enabled: controller.graph != nil && controller.canEditCanvas) { interfacePresented = true },
            action("layoutInteraction.exportLocation", enabled: destinationEnabled && controller.readOnlyReason == nil && !controller.isSaving, guarded(onDestination)),
            action("layoutInteraction.addDocument", enabled: controller.canEditCanvas && publishDocumentDescription != nil, guarded(onPublishText))]
        commands.manageNodes = action("layoutInteraction.manageNodes", manageCustomNodes)
        commands.workflowChoices = controller.graphs.map { graph in
            let change = action("workflow.management.switch") {
                guard controller.graphs.contains(where: { $0.id == graph.id }) else { return }
                rememberViewContext(); controller.selectedGraphID = graph.id
            }
            return .init(.init(title: graph.name, isEnabled: change.isEnabled, action: change.action), selected: controller.selectedGraphID == graph.id)
        }
        commands.save = sharedSaveCommand ?? action("layoutInteraction.save", enabled: !isReadOnly && !controller.isSaving) { Task { await controller.save() } }
        commands.templates = WorkflowLanguageExample.allCases.map { example in action("workflow.language.example." + example.rawValue, enabled: controller.canEditCanvas) { controller.addLanguageExample(example) } }
            + WorkflowExampleChoice.allCases.map { example in
                let command = action("systemMenu.templates", enabled: controller.canEditCanvas) { controller.addExample(example.rawValue) }
                return .init(title: example.title(languageStore), isEnabled: command.isEnabled, action: command.action)
            }
        return commands
    }
    private func changeMenuZoom(multiplier: CGFloat = 1, actual: Bool = false) {
        guard camera.owner == ObjectIdentifier(controller), camera.context == viewContext else { return }
        camera.restoringCenter = nil
        camera.zoom = actual ? 1 : WorkflowCanvasLayoutPolicy.restoredZoom(camera.zoom * multiplier)
        rememberViewContext()
    }
    private func toggleRunSettings() { runSettingsVisible.toggle(); workspaceDraft = nil; activityVisible = false }
    private func showRecoveryRecords() { activityVisible = true; recordsDetail = false; workspaceDraft = nil; runSettingsVisible = false }
    private struct SavingTarget: Hashable { let run: UUID; let stage: UUID? }
    private var pendingSavingTargets: Set<SavingTarget> {
        Set(controller.runs.filter { $0.status == .saving || $0.id == controller.pendingPausedStopRunID }.map { run in
            SavingTarget(run: run.id, stage: controller.batchStages.first { $0.attempts.contains { $0.runID == run.id } }?.id)
        })
    }
    private func retryPendingSaving(_ expected: Set<SavingTarget>, context: WorkflowRunTarget.Context) {
        guard context == runContext, !controller.isRunning, !controller.isSaving else { return }
        guard expected == pendingSavingTargets, expected.count == 1, let target = expected.first else { showRecoveryRecords(); return }
        Task {
            guard context == runContext, expected == pendingSavingTargets, !controller.isRunning, !controller.isSaving else { return }
            if let stage = target.stage { await controller.retryBatchSaving(stage) }
            else { await controller.retryRunSaving(runID: target.run) }
        }
    }
    private var portLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(WorkflowPortStyle.legend.indices, id: \.self) { index in
                let entry = WorkflowPortStyle.legend[index]
                HStack(spacing: 8) {
                    Circle().fill(WorkflowPortStyle.color(for: entry.port)).frame(width: 10, height: 10)
                    Text(workflowText(languageStore, "refinement.workflow.legend." + entry.key, fallback: entry.fallback))
                }
            }
        }.padding(14)
    }
    private func dockText(_ key: String) -> String { text("workflow.dock." + key, "") }
    private var pendingCalls: [WorkflowPlanCallRecord] {
        controller.runs.flatMap(WorkflowWorkspacePanels.records).filter { $0.step.status == .waiting }
    }
    private var dockSummary: String {
        if controller.activePresentationRun?.status == .cancelling { return dockText("cancelling") }
        if let pending = controller.pausePendingPresentation {
            return workflowProgressText(.init(pending), language: languageStore)
        }
        if controller.isRunning {
            return controller.progressPresentation.map { workflowProgressText($0, language: languageStore) }
                ?? (controller.progressMessage.isEmpty ? dockText("running") : workflowRecoveryProgressText(controller.progressMessage, language: languageStore))
        }
        if controller.hasPendingSaves { return controller.hasSaveFailure ? workflowText(languageStore, "workflow.save.failed") : dockText("savePending") }
        let pausedQueues = WorkflowDockRecovery.pausedQueues(controller)
        if let stage = pausedQueues.first {
            return dockText("paused") + " · " + (pausedQueues.count == 1 ? WorkflowHumanPresentation.stage(stage, language: languageStore) : String(pausedQueues.count))
        }
        if !pendingCalls.isEmpty { return dockText("waiting") + " · \(pendingCalls.count)" }
        if let run = recoveryRun, run.planCheckpoint?.state == .paused { return dockText("paused") + " · " + run.graph.name }
        if let progress = controller.progressPresentation, progress.code == "runSaved" {
            return workflowProgressText(progress, language: languageStore)
        }
        guard let target = validRunTarget else { return dockText("chooseTarget") }
        return dockText("range." + String(runRange)) + " · " + target.title
    }
    private func openRecords() {
        activityVisible.toggle(); recordsDetail = false; workspaceDraft = nil; runSettingsVisible = false
    }
    private func inspectRun(_ run: WorkflowRun) {
        panelsState.selectRun(run.id); panelsState.output = .overview
        recordsDetail = true; activityVisible = true; workspaceDraft = nil; runSettingsVisible = false
    }
    private func runDock(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(dockSummary).font(.caption).lineLimit(1).help(dockSummary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("workflow-run-summary")
            dockMainAction.frame(width: 112, height: 32)
            Button { openRecords() } label: {
                Text(dockText("records") + (pendingCalls.isEmpty ? "" : " · \(pendingCalls.count)"))
                    .lineLimit(1).frame(width: 72, height: 32)
            }.accessibilityIdentifier("workflow-records")
        }.buttonStyle(WorkflowDockButtonStyle()).padding(.horizontal, 9)
            .frame(width: WorkflowDockLayout.width(available: width), height: 48)
            .workbenchPanel(in: Capsule()).accessibilityIdentifier("workflow-run-dock")
    }
    @ViewBuilder private var dockMainAction: some View {
        if controller.isRunning {
            let stopping = controller.activePresentationRun?.status == .cancelling
            HStack(spacing: 0) {
                Button(controller.activeBatchID != nil ? workspaceText(languageStore, "batchPauseReview") : dockText("pause")) { controller.pause() }
                    .help(controller.activeBatchID != nil ? workspaceText(languageStore, "batchPauseReview.help") : workflowText(languageStore, "workflow.run.pauseHelp"))
                    .disabled(stopping || !controller.canPausePresentation)
                Button(controller.activeBatchID != nil ? workspaceText(languageStore, "batchCancel") : dockText("stop")) { Task { await controller.cancel() } }
                    .help(controller.activeBatchID != nil ? workspaceText(languageStore, "batchCancel.help") : dockText("stop"))
                    .disabled(stopping || controller.isSaving)
                    .accessibilityIdentifier("workflow-cancel")
            }.frame(maxWidth: .infinity).buttonStyle(WorkflowDockButtonStyle(expand: true))
        } else if controller.hasPendingSaves {
            let pending = pendingSavingTargets, context = runContext
            Button(dockText("retrySave")) { retryPendingSaving(pending, context: context) }.buttonStyle(WorkflowDockButtonStyle(expand: true))
                .help(workspaceText(languageStore, "saveOnly.help"))
        } else if !WorkflowDockRecovery.capture(controller).targets.isEmpty {
            WorkflowPausedBatchControls(controller: controller) {
                activityVisible = true; recordsDetail = false; workspaceDraft = nil; runSettingsVisible = false
            }.disabled(isReadOnly)
        } else if !pendingCalls.isEmpty {
            let assetsOnly = pendingCalls.allSatisfy { WorkflowBatchPanel.reviewActionKey(for: $0.step, registry: controller.registry) == "reviewGate" }
            Button(dockText(assetsOnly ? "reviewAssets" : "reviewHuman")) {
                activityVisible = true; recordsDetail = false; workspaceDraft = nil; runSettingsVisible = false
            }.buttonStyle(WorkflowDockButtonStyle(expand: true))
        } else {
            HStack(spacing: 0) {
                Button { if let target = validRunTarget { presentWorkspacePlan(target.id, mode: runRange) } } label: {
                    Text(dockText("run")).frame(width: 84, height: 32)
                }.disabled(validRunTarget == nil || !controller.canEditCanvas || !controller.bodyPath.isEmpty)
                    .accessibilityIdentifier("workflow-run")
                Button {
                    toggleRunSettings()
                } label: { Image(systemName: "chevron.down").frame(width: 28, height: 32) }
                    .accessibilityLabel(dockText("settings")).accessibilityIdentifier("workflow-run-settings")
            }
        }
    }
    private var runSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dockText("settings")).font(.headline)
            WorkbenchScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    WorkbenchPicker(dockText("target"), selection: Binding(get: { validRunTarget?.id }, set: { id in
                        if let id { setRunTarget(id) } else { runTarget = nil; workspaceDraft = nil; runOptions.choices = [:] }
                    })) {
                        WorkbenchChoice(dockText("chooseTarget"), value: UUID?.none)
                        WorkbenchChoiceForEach(controller.graph?.nodes ?? []) { node in
                            WorkbenchChoice(WorkflowHumanPresentation.name(node, in: controller.graph?.nodes ?? [], language: languageStore), value: Optional(node.id))
                        }
                    }.accessibilityIdentifier("workflow-run-target")
                    Picker(dockText("range"), selection: Binding(get: { runRange }, set: setRunRange)) {
                        ForEach(0..<4) { mode in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dockText("range." + String(mode)))
                                Text(dockText("rangeHelp." + String(mode))).font(.caption).foregroundStyle(.secondary)
                            }.tag(mode)
                        }
                    }.pickerStyle(.radioGroup).labelsHidden().accessibilityIdentifier("workflow-run-range")
                    Divider()
                    Toggle(workspaceText(languageStore, "batchGenerate"), isOn: $runOptions.batch)
                    if runOptions.batch {
                        Stepper(workspaceText(languageStore, "stageCount") + " \(runOptions.repetitions)", value: $runOptions.repetitions, in: 1...64)
                    }
                    DisclosureGroup(workspaceText(languageStore, "seedStrategy")) {
                        Picker(workspaceText(languageStore, "seedStrategy"), selection: $runOptions.seedStrategy) {
                            Text(workspaceText(languageStore, "seedFixed")).tag(WorkflowBatchSeedStrategy.fixed)
                            Text(workspaceText(languageStore, "seedAutomatic")).tag(WorkflowBatchSeedStrategy.automatic)
                        }.pickerStyle(.radioGroup).labelsHidden().disabled(!runOptions.batch || !seedSupported)
                        Text(workspaceText(languageStore, "seedEffect")).font(.caption)
                        if !runOptions.batch || !seedSupported {
                            Text(dockText(!runOptions.batch ? "seedBatchOnly" : "seedUnsupported")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(dockText("close")) { runSettingsVisible = false }
                Spacer()
                Button(dockText("viewPlan")) { if let target = validRunTarget { presentWorkspacePlan(target.id, mode: runRange) } }
                    .disabled(validRunTarget == nil || !controller.canEditCanvas || !controller.bodyPath.isEmpty)
            }
        }.buttonStyle(WorkbenchGlassButtonStyle()).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 16)
    }
    private var seedSupported: Bool {
        guard let target = validRunTarget, let draft = try? WorkflowWorkspaceRunDraft(controller: controller, target: target.id, mode: runRange) else { return false }
        return WorkflowBatchSeedSchedule.supportedNodeCount(in: draft.slice.plan, registry: controller.registry) > 0
    }
    private func isBatchRun(_ id: UUID) -> Bool { controller.batchStages.contains { $0.attempts.contains { $0.runID == id } } }
    private var recordsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if recordsDetail { Button(dockText("backToRecords")) { recordsDetail = false } }
                else { Text(dockText("records")).font(.headline) }
                Spacer()
                Button(dockText("close")) { activityVisible = false }
            }
            ZStack {
            if visitedRecordsDetail || recordsDetail { retained(outputPanel.buttonStyle(WorkbenchGlassButtonStyle()).textFieldStyle(WorkbenchGlassTextFieldStyle()), visible: recordsDetail, id: "workflow-record-details-retained") }
            if !recordsDetail {
                WorkbenchScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if controller.errorMessage != nil || controller.readOnlyReason != nil { statusStrip }
                        if controller.hasPendingSaves {
                            Button(dockText("saveRecord")) { Task { await controller.save() } }
                                .disabled(controller.isRunning || controller.isSaving)
                        }
                        if !controller.batchStages.isEmpty {
                            Button(workspaceText(languageStore, "batches")) { panelsState.output = .batches; recordsDetail = true }
                        }
                        ForEach(controller.runs.reversed()) { run in
                            VStack(alignment: .leading, spacing: 5) {
                                Button { inspectRun(run) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(WorkflowHumanPresentation.run(run, in: controller.runs, stages: controller.batchStages, language: languageStore)).font(.subheadline)
                                        Text(WorkflowHumanPresentation.runStatus(run, language: languageStore) + " · " + run.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                        if let seconds = controller.batchStages.lazy.flatMap(\.attempts).first(where: { $0.runID == run.id })?.activeSeconds {
                                            Text(workspaceText(languageStore, "activeTime") + String(format: " %.2f s", seconds)).font(.caption)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                HStack {
                                    Button(workspaceText(languageStore, "locateResults"), systemImage: "tray.full") {
                                        revealLibrary(.init(controller: controller, source: .run(run.id), name: WorkflowHumanPresentation.run(run, in: controller.runs, stages: controller.batchStages, language: languageStore)))
                                    }
                                    if isBatchRun(run.id) {
                                        Button(workspaceText(languageStore, "batches")) { panelsState.selectRun(run.id); panelsState.output = .batches; recordsDetail = true }
                                    } else if run.id == controller.pendingPausedStopRunID {
                                        Button(dockText("retrySave")) { Task { await controller.retryRunSaving(runID: run.id) } }
                                            .help(workspaceText(languageStore, "saveOnly.help"))
                                    } else if WorkflowCanvasPresentation.canResume(run.status) { recoveryActions(run) }
                                }
                            }.padding(8).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if controller.runs.isEmpty { Text(dockText("noRecords")).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            }
        }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 16).buttonStyle(WorkbenchGlassButtonStyle()).textFieldStyle(WorkbenchGlassTextFieldStyle())
            .onChange(of: recordsDetail, initial: true) { _, visible in if visible { visitedRecordsDetail = true } }
    }

    private func cornerTools(fitReady: Bool, targetWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button {
                canvasTool = canvasTool == .hand ? .pointer : .hand
            } label: {
                Image(systemName: "hand.draw").foregroundStyle(canvasTool == .hand ? Color.accentColor : .primary)
                    .background { Circle().fill(Color.primary.opacity(canvasTool == .hand ? 0.10 : 0)).frame(width: 36, height: 36) }
            }.buttonStyle(WorkbenchIconButtonStyle(diameter: 40, panel: true))
                .disabled(viewportInteractionLocked).accessibilityLabel(text("refinement.workflow.hand", "手形"))
                .accessibilityAddTraits(canvasTool == .hand ? .isSelected : [])
                .accessibilityIdentifier("workflow-canvas-hand")
            WorkflowCanvasCameraScope(camera: camera, controller: controller, context: viewContext, changed: rememberViewContext) { zoom in
                WorkflowCanvasCornerZoom(zoom: zoom, locked: viewportInteractionLocked, canFit: fitReady) {
                    fitAllNodes(targetWidth: targetWidth)
                }
            }
        }
    }

    @ViewBuilder private func recoveryActions(_ run: WorkflowRun) -> some View {
        let waiting = WorkflowWorkspacePanels.records(in: run).filter { $0.step.status == .waiting }
        if WorkflowHumanPresentation.opensPendingDecision(run) {
            WorkbenchMenu(text("semantics.pending", "处理待确认内容")) {
                WorkbenchMenuForEach(waiting) { call in
                    WorkbenchMenuAction(WorkflowHumanPresentation.name(call.step.node, in: WorkflowHumanPresentation.nodes(in: run), language: languageStore) + " · " + WorkflowHumanPresentation.call(call, in: WorkflowWorkspacePanels.records(in: run), language: languageStore)) {
                        inspectPending(run, call: call)
                    }
                }
            }.accessibilityIdentifier("workflow-open-pending-" + run.id.uuidString)
        } else {
            WorkflowRunRecoveryButton(controller: controller, run: run, readOnly: isReadOnly || controller.isRunning)
            if run.planCheckpoint?.state == .paused && !isBatchRun(run.id) {
                Button(dockText("stop")) { Task { await controller.stopPausedRun(runID: run.id) } }
                    .disabled(isReadOnly || controller.isRunning || controller.hasPendingSaves)
            }
        }
    }

    private func inspectPending(_ run: WorkflowRun, call: WorkflowPlanCallRecord) {
        guard controller.runs.contains(where: { $0.id == run.id }),
              controller.callRecords(runID: run.id).contains(where: { $0.id == call.id && $0.address == call.address }) else { return }
        panelsState.selectRun(run.id)
        panelsState.selectResult(node: call.step.node.id, call: .init(address: call.address, stepID: call.id))
        recordsDetail = true; activityVisible = true; workspaceDraft = nil; runSettingsVisible = false
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
                Text(controller.pausePendingPresentation.map { workflowProgressText(.init($0), language: languageStore) } ?? (controller.progressMessage.isEmpty && controller.progressPresentation == nil
                     ? workflowText(languageStore, "workflow.status.runningNow")
                     : controller.progressPresentation.map { workflowProgressText($0, language: languageStore) } ?? workflowRecoveryProgressText(controller.progressMessage, language: languageStore)))
            } else if !controller.progressMessage.isEmpty || controller.progressPresentation != nil {
                Text(controller.progressPresentation.map { workflowProgressText($0, language: languageStore) } ?? workflowRecoveryProgressText(controller.progressMessage, language: languageStore)).foregroundStyle(.secondary)
            }
            Spacer()
            if let rawError = controller.errorMessage {
                let error = controller.errorCode.map { workflowText(languageStore, $0, fallback: rawError) }
                    ?? WorkbenchOwnedIssue.summary(rawError, language: languageStore)
                    ?? workflowRecoveryErrorText(rawError, runs: controller.runs, language: languageStore)
                VStack(alignment: .leading, spacing: 4) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").lineLimit(2)
                    if controller.errorCode != nil {
                        DisclosureGroup(consistencyText(languageStore, "error.original")) { Text(rawError).textSelection(.enabled) }
                    }
                }.foregroundStyle(.red).help(error).accessibilityIdentifier("workflow-error")
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
            bodyPath: controller.bodyPath.map(WorkflowCanvasBodyLocation.init), instanceID: controller.projectInstanceID)
    }

    private func rememberViewContext() {
        guard camera.owner == ObjectIdentifier(controller), camera.context == viewContext,
              camera.restoredOwner == ObjectIdentifier(controller), camera.restoringCenter == nil else { return }
        viewStates.capture(zoom: camera.zoom, rawVisibleCenter: camera.visibleCenter,
            selectedNodeID: controller.selectedNodeID, for: viewContext)
    }

    private var libraryInsertionPoint: () -> CGPoint? {
        let context = viewContext
        let camera = camera
        let controller = controller
        return {
            let current = WorkflowCanvasViewContext(projectID: controller.projectID,
                rootGraphID: controller.rootGraph?.id,
                bodyPath: controller.bodyPath.map(WorkflowCanvasBodyLocation.init), instanceID: controller.projectInstanceID)
            guard camera.owner == ObjectIdentifier(controller), camera.context == context,
                  current == context else { return nil }
            return camera.insertionPoint
        }
    }

    private func fitAllNodes(targetWidth: CGFloat) {
        guard camera.owner == ObjectIdentifier(controller),
              !viewportInteractionLocked, camera.context == viewContext,
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
                                        y: point.y - WorkflowNodePortLayout.titleHeight / 2,
                                        width: WorkflowCanvasLayoutPolicy.nodeWidth, height: height))
        }
        guard let fitted = WorkflowCanvasFit.view(for: bounds, viewport: canvasViewport.clip) else { return }
        camera.restoringCenter = nil
        camera.zoom = fitted.zoom
        rememberViewContext()
        navigationRequest = WorkflowCanvasNavigationRequest(rawCenter: fitted.center)
    }

    private func restoreInitialViewContext() {
        camera.owner = ObjectIdentifier(controller)
        if camera.restoredOwner != ObjectIdentifier(controller),
           let last = viewStates.lastContext(projectID: controller.projectID, instanceID: controller.projectInstanceID),
           let root = controller.graphs.first(where: { $0.id == last.rootGraphID }) {
            controller.selectedGraphID = root.id
            let path = last.bodyPath.map { WorkflowBodyLocation(nodeID: $0.nodeID, slot: $0.slot) }
            // A removed body is not another body with the same label. Fall back
            // to this root without showing a stale navigation error or editing it.
            if (try? WorkflowGraphEditing.body(in: root, path: path)) != nil {
                for location in path { controller.openBody(nodeID: location.nodeID, slot: location.slot) }
            }
        }
        camera.restoredOwner = ObjectIdentifier(controller)
        restoreViewContext(viewContext)
    }

    private func restoreViewContext(_ context: WorkflowCanvasViewContext) {
        camera.context = nil
        camera.restoringCenter = nil
        if let saved = viewStates.state(for: context) {
            camera.zoom = WorkflowCanvasLayoutPolicy.restoredZoom(saved.zoom)
            camera.visibleCenter = saved.rawVisibleCenter
            camera.restoringCenter = saved.rawVisibleCenter
            navigationRequest = WorkflowCanvasNavigationRequest(rawCenter: saved.rawVisibleCenter)
            controller.selectedNodeID = controller.graph?.nodes.contains(where: { $0.id == saved.selectedNodeID }) == true
                ? saved.selectedNodeID : nil
        } else {
            camera.zoom = 1
            if let graph = controller.graph {
                let geometry = WorkflowGraphGeometry(graph: graph, tools: controller.tools,
                    registry: controller.registry)
                camera.visibleCenter = CGPoint(
                    x: geometry.size.width / 2 - geometry.translation.width,
                    y: geometry.size.height / 2 - geometry.translation.height)
            }
            navigationRequest = WorkflowCanvasNavigationRequest(rawCenter: nil)
        }
        camera.insertionPoint = camera.visibleCenter
        camera.context = context
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
        return draft.marks(batch: runOptions.batch).mapValues { $0 }.reduce(into:[:]) { result,item in
            var mark=item.value;mark.historicalLabel=planInputLabels[item.key];result[item.key]=mark
        }
    }
    private func presentWorkspacePlan(_ node:UUID,mode:Int) {
        guard !isReadOnly else { return }
        do { planInputLabels=[:];workspaceDraft=try .init(controller:controller,target:node,mode:mode);activityVisible=false;runSettingsVisible=false }
        catch { controller.errorMessage=error.localizedDescription; workspaceDraft=nil; activityVisible=true; recordsDetail=false; runSettingsVisible=false }
    }
    private func openValue(_ value:WorkflowValue,_ call:WorkflowCallReference,_ title:String, port: String? = nil, side: WorkflowViewerValueSide = .output) {
        guard let viewerModel,viewerModel.projectSession.workflow === controller else { return }
        do { try viewerModel.viewers.open(.init(title:title,subtitle:controller.runs.first { $0.id == call.address.runID }.map { WorkflowHumanPresentation.run($0,in:controller.runs,stages:controller.batchStages,language:languageStore) } ?? "",value:value,call:call,port:port,side:side,usesCallTitle: true),model:viewerModel,language:languageStore) }
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
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 16)
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
        .workbenchSheet(item: $scopePresentation, title: workflowText(languageStore, "childPanel.name.scope")) { request in
            WorkflowScopePanel(controller: controller, graphID: request.graphID, revision: request.revision, nodeID: request.nodeID, initialMode: request.mode).workbenchPresentation()
        }
        .workbenchSheet(item: $fixedToolPresentation, title: workflowText(languageStore, "childPanel.name.tools")) { request in
            WorkflowFixedToolSheet(controller: controller, reference: request.reference,
                onClose: { fixedToolPresentation = nil },
                onCopy: {
                    fixedToolPresentation = nil
                    onOpenTool(request.reference)
                })
        }
        .workbenchConfirmation(workflowText(languageStore, "workflow.scope.rerunCall"),
               isPresented: Binding(get: { pendingCall != nil }, set: { if !$0 { pendingCall = nil } })) {
            Button(workspaceText(languageStore, "retryFrozen")) {
                if let reference = pendingCall { Task { await controller.rerunCall(reference) } }
                pendingCall = nil
            }.keyboardShortcut(.defaultAction)
            Button(workflowText(languageStore, "workflow.scope.cancel"), role: .cancel) { pendingCall = nil }.keyboardShortcut(.cancelAction)
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
                    change: nil,
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
            modelIdentity: node.parameters["modelID"]?.string,
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
                let comparison = resultRunID.map { controller.outputComparison(step, runID: $0) } ?? controller.presentationStatus(for: node.id)?.comparison ?? .matching
                HStack {
                    WorkflowStatusBadge(status: step.status, comparison: comparison)
                    Spacer()
                    Text(step.node.title).font(.caption).foregroundStyle(.secondary)
                }
                if case .unavailable(let diagnostic) = comparison { WorkflowTechnicalDetails(value: diagnostic) }
                if let error = step.error {
                    WorkbenchIssueText(raw: error, key: step.errorCode)
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
                                       WorkflowHumanPresentation.run(run, in: controller.runs, stages: controller.batchStages, language: languageStore) + " · " + step.node.title + " · " + (resultRecord.map { WorkflowHumanPresentation.call($0, in: WorkflowWorkspacePanels.records(in: run), language: languageStore) } ?? "")
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
                        Text(WorkflowHumanPresentation.runStatus(run, language: languageStore))
                            .foregroundStyle(.secondary)
                    }
                    WorkflowTechnicalDetails(value: run.id.uuidString)
                    ForEach(WorkflowWorkspacePanels.records(in: run)) { call in
                        DisclosureGroup(call.step.node.title + " · " + WorkflowCanvasPresentation.statusTitle(call.step.status, language: languageStore)) {
                            if let revealLibrary {
                                Button(workspaceText(languageStore, "locateResults", "", "")) {
                                    revealLibrary(.init(controller: controller, source: .call(.init(address: call.address, stepID: call.id)), name: WorkflowHumanPresentation.run(run, in: controller.runs, stages: controller.batchStages, language: languageStore) + " · " + WorkflowHumanPresentation.call(call, in: WorkflowWorkspacePanels.records(in: run), language: languageStore)))
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
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let modelIdentity: String?
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
                WorkbenchChoiceForEach(choices, id: \.self) { option in
                    WorkbenchChoice(WorkflowCanvasPresentation.choiceTitle(fieldID: field.id, value: option, language: languageStore), value: option)
                        .disabled(field.id == "loadingStrategy" && WorkflowModelRoutes.rejectsTextLoading(modelIdentity: modelIdentity, strategy: option))
                }
            }
            .labelsHidden()
            .disabled(readOnly)
            if field.id == "loadingStrategy", WorkflowModelRoutes.rejectsTextLoading(modelIdentity: modelIdentity, strategy: "ssdLayered") {
                Text(workflowText(languageStore, "workflow.loading.quantizedRestriction"))
                    .font(.caption).foregroundStyle(value.string == "ssdLayered" ? .orange : .secondary)
            }
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
                DisclosureGroup(WorkflowHumanPresentation.run(snapshot.run, in: controller.runs, stages: controller.batchStages, language: language) + " · " + WorkflowHumanPresentation.call(snapshot.call, in: WorkflowWorkspacePanels.records(in: snapshot.run), language: language)) {
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
                        Text(controller.presentationStatus(for: source.id).map {
                            $0.comparison == .matching ? workflowText(language, "canvas.connection.saved")
                                : WorkflowOutputComparisonText.title($0.comparison, language: language)
                        } ?? workflowText(language, "canvas.connection.saved"))
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
            }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
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
        .workbenchSheet(item: $annotationRequest, title: workflowText(languageStore, "childPanel.name.metadata")) { request in
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
        let key = savingFailure ? "workflow.action.saveFailureRecord" : run.status == .failed ? "workflow.action.retryComputation" : run.status == .saving ? "workflow.dock.retrySave" : "workflow.action.resume"
        let fallback = savingFailure ? "重试保存失败记录" : run.status == .failed ? "重试计算" : run.status == .saving ? "重试保存" : "继续流程"
        Button(workflowText(languageStore, key, fallback: fallback)) {
            Task {
                if run.status == .saving { await controller.retryRunSaving(runID: run.id) }
                else { await controller.resume(runID: run.id) }
            }
        }
        .disabled(readOnly)
        .accessibilityIdentifier("workflow-run-recovery-" + run.id.uuidString)
        .help(run.status == .saving ? workspaceText(languageStore, "saveOnly.help") : "")
        .workbenchHelp(savingFailure ? "RECOVERY-SAVE-FAILURE" : run.status == .failed ? "RECOVERY-RECOMPUTE" : run.status == .saving ? nil : "DECISION-CONTINUE", unavailableReason: readOnly ? canvasHelpReason(controller, readOnly: readOnly, language: languageStore) : nil, target: "run:\(run.id):\(run.graph.id):\(run.status)")
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
        .workbenchSheet(isPresented: Binding(get: { inspectImage != nil }, set: { if !$0 { inspectImage = nil } }), title: workflowText(languageStore, "childPanel.name.preview")) {
            VStack {
                HStack { Button(metadataText(languageStore, "close")) { inspectImage = nil }; Spacer() }
                if let inspectImage { ScrollView([.horizontal, .vertical]) { Image(nsImage: inspectImage).resizable().scaledToFit().frame(maxWidth: 1000, maxHeight: 750) } }
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
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
    var flatControls = false
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
        if interaction == .containerReview {
            WorkflowAssetContainerView(controller: controller, node: step.node, forcedStepID: step.id, height: 340)
        } else { legacyBody }
    }
    private var legacyBody: some View {
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
                        .modifier(WorkflowDecisionPrimaryStyle(flat: flatControls))
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
                    .modifier(WorkflowDecisionPrimaryStyle(flat: flatControls))
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
    let comparison: WorkflowOutputComparison
    var scale: CGFloat = 1
    @Environment(\.dLanguageStore) private var languageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(spacing: 4 * scale) {
                Circle().fill(WorkflowCanvasPresentation.statusColor(status)).frame(width: 7 * scale, height: 7 * scale)
                Text(WorkflowCanvasPresentation.statusTitle(status, language: languageStore)).lineLimit(1)
            }
            if comparison != .matching {
                Text(WorkflowOutputComparisonText.title(comparison, language: languageStore))
                    .foregroundStyle(.orange)
                    .help(WorkflowOutputComparisonText.help(comparison, language: languageStore))
            }
        }
        .font(.system(size: 11 * scale, weight: .medium))
        .padding(.horizontal, 7 * scale).padding(.vertical, 4 * scale)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
    }
}

private enum WorkflowExampleChoice: String, CaseIterable, Identifiable {
    case container, containerImages, text, image, file, template
    var id: String { rawValue }
    @MainActor func title(_ language: UILanguageStore?) -> String {
        switch self {
        case .container: workflowText(language, "container.example")
        case .containerImages: workflowText(language, "container.imageExample")
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
    static func width(_ id: UUID, in graph: WorkflowGraph) -> CGFloat {
        guard let node = graph.nodes.first(where: { $0.id == id }), WorkflowAssetContainer.isContainer(node.operationID) else { return nodeWidth }
        return CGFloat(min(1200, max(300, graph.layout.first(where: { $0.nodeID == id })?.width ?? 360)))
    }
    static func containerHeight(_ id: UUID, in graph: WorkflowGraph) -> CGFloat {
        CGFloat(min(1000, max(280, graph.layout.first(where: { $0.nodeID == id })?.height ?? 360)))
    }
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
