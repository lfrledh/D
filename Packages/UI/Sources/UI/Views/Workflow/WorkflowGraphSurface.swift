import AppKit
import CoreTransferable
import DWorkbench
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

private struct WorkflowPrepareNodeKey: EnvironmentKey {
    static let defaultValue: (@MainActor (UUID) -> Void)? = nil
}
private struct WorkflowPreparingModelsKey: EnvironmentKey { static let defaultValue: Set<String> = [] }
extension EnvironmentValues {
    var workflowPrepareNode: (@MainActor (UUID) -> Void)? {
        get { self[WorkflowPrepareNodeKey.self] }
        set { self[WorkflowPrepareNodeKey.self] = newValue }
    }
    var workflowPreparingModels: Set<String> {
        get { self[WorkflowPreparingModelsKey.self] }
        set { self[WorkflowPreparingModelsKey.self] = newValue }
    }
}

struct WorkflowGraphSurface: View {
    @Environment(\.workbenchBackground) private var localBackground
    @Environment(\.chatDisplayPreferences) private var displayPreferences
    @Environment(\.colorScheme) private var colorScheme
    private static let emptyGraph = WorkflowGraph()
    let controller: WorkflowController
    let graph: WorkflowGraph?
    @Binding var zoom: CGFloat
    @Binding var tool: WorkflowCanvasTool
    @State private var scrollPosition = ScrollPosition()
    @Binding var navigationRequest: WorkflowCanvasNavigationRequest?
    @Binding var viewportInteractionLocked: Bool
    let viewContext: WorkflowCanvasViewContext
    @Binding var pendingConnection: WorkflowPendingConnection?
    @Binding var selectedConnectionID: UUID?
    let readOnly: Bool
    var inspectedNodeID: UUID? = nil
    var runTargetNodeID: UUID? = nil
    var planMarks:[UUID:WorkflowPlanMark]=[:]
    let onPlan: (UUID, Bool) -> Void
    var onSetRunTarget: (UUID) -> Void = { _ in }
    var onPlanRange: ((UUID, Int) -> Void)? = nil
    var onViewResults: ((UUID) -> Void)? = nil
    var nodeSizeObserver: ((UUID, CGSize) -> Void)?
    var viewportSizeObserver: ((WorkflowCanvasViewportMeasurement) -> Void)?
    var portCenterObserver: (([WorkflowPortIdentity: CGPoint]) -> Void)?
    var onScrollObservation: (WorkflowCanvasViewContext, WorkflowCanvasScrollObservation) -> Void = { _, _ in }
    var onDropItem: (WorkflowCanvasTransfer, CGPoint) -> Bool = { _, _ in false }
    var onDropCanvasFile: (URL, CGPoint) -> Bool = { _, _ in false }
    var onBindAsset: (UUID, UUID?, UUID, UUID) -> Bool = { _, _, _, _ in false }
    var onInspect: (UUID) -> Void = { _ in }
    var onClearSelection: () -> Void = {}
    var onRequestKeyboardFocus: () -> Void = {}
    @Environment(\.dLanguageStore) private var languageStore
    @GestureState private var gestureScale: CGFloat = 1
    @State private var nodeDrag = WorkflowCanvasNodeDragPresentation()
    @State private var stableOrigin: WorkflowCanvasStableOrigin?
    @State private var retainedExtent: WorkflowCanvasRetainedExtent?
    @State private var pendingConnectionScope: WorkflowCanvasScope?
    @State private var connectionDrag = WorkflowConnectionDragPresentation()
    @State private var measuredPortCenters: [WorkflowPortIdentity: CGPoint] = [:]
    @State private var connectionIssue: WorkflowCanvasConnectionIssue?
    @State private var handPointer = WorkflowCanvasPointerPresentation()
    @State private var scrollTracking = WorkflowCanvasScrollTracking()
    @State private var controlBounds: [CGRect] = []
    @State private var nodeControlBounds: [UUID: [CGRect]] = [:]
    @State private var clipViewportSize: CGSize?
    @State private var resizeAnchorRaw: CGPoint?
    @State private var cardSizes: [UUID: CGSize] = [:]
    @State private var marquee: WorkflowCanvasMarquee?
    @State private var libraryDropPreview = WorkflowLibraryDropPreview()
    @State private var libraryDropIssues = WorkflowLibraryDropIssues()

    var body: some View {
        #if DEBUG
        let _ = WorkflowCanvasUpdateProbe.surfaceBody?()
        #endif
        let graph = self.graph ?? Self.emptyGraph
        Group {
                let scope = WorkflowCanvasScope(
                    rootGraphID: controller.rootGraph?.id ?? graph.id,
                    rootRevision: controller.rootGraph?.revision ?? graph.revision,
                    graphID: graph.id,
                    bodyPath: controller.bodyPath,
                    projectID: controller.projectID, instanceID: controller.projectInstanceID
                )
                let naturalGeometry = WorkflowGraphGeometry(
                    graph: graph, tools: controller.tools, registry: controller.registry
                )
                let retainedOrigin = stableOrigin?.identity == scope.identity
                    ? stableOrigin?.translation : nil
                let activeOrigin = nodeDrag.active?.scope == scope ? nodeDrag.active?.origin : nil
                let origin = WorkflowCanvasOriginPolicy.resolved(
                    natural: naturalGeometry.translation,
                    retained: retainedOrigin,
                    active: activeOrigin
                )
                let geometry = naturalGeometry.reframed(
                    translation: origin,
                    minimumSize: retainedExtent?.size(for: scope.identity, translation: origin) ?? .zero
                )
                GeometryReader { viewport in
                let viewportSize = clipViewportSize ?? viewport.size
                let layout = WorkflowCanvasViewportGeometry(
                    graphSize: geometry.size, viewportSize: viewportSize,
                    zoom: effectiveZoom, translation: geometry.translation
                )
                let renderZoom = effectiveZoom
                let contentSize = layout.unscaledGraphSize
                let edge = layout.unscaledPadding
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        displayPreferences.resolvedAppearance.palette(for: colorScheme).canvasColor.opacity(localBackground == nil ? 1 : 0)
                            .contentShape(Rectangle())
                            .modifier(WorkflowHandPointerStyle(presentation: handPointer, tool: tool))
                            .help(workflowText(
                                languageStore,
                                "workflow.canvas.dropHint",
                                fallback: "将节点或项目素材拖到这里；拖动输出端口可建立连接。"
                            ))
                            .background(viewportInput(geometry: geometry, layout: layout, scope: scope))
                        ZStack(alignment: .topLeading) {
                        ForEach(graph.nodes) { node in
                            let position = geometry.displayPosition(node.id)
                            WorkflowNodeCard(
                                controller: controller,
                                scale: effectiveZoom,
                                graph: graph,
                                scope: scope,
                                node: node,
                                definition: controller.registry.definition(for: node, tools: controller.tools),
                                pendingConnection: $pendingConnection,
                                tool: tool,
                                pointerPresentation: handPointer,
                                pendingConnectionScope: pendingConnectionScope,
                                readOnly: readOnly,
                                selected: controller.selectedNodeID == node.id || controller.selectedNodeIDs.contains(node.id),
                                inspecting: inspectedNodeID == node.id,
                                runTarget: runTargetNodeID == node.id,
                                onPlan: onPlan,
                                onSetRunTarget: onSetRunTarget,
                                onPlanRange: onPlanRange, onViewResults: onViewResults,
                                onBindAsset: onBindAsset,
                                onInspect: onInspect,
                                portVisible: { port, delta in
                                    guard let center = measuredPortCenters[port],
                                          let index = graph.nodes.firstIndex(where: { $0.id == node.id }) else { return false }
                                    let point = CGPoint(x: center.x + delta.x / renderZoom, y: center.y + delta.y / renderZoom)
                                    let frames = WorkflowConnectionGeometry.nodeFrames(geometry: geometry, sizes: cardSizes)
                                    return !graph.nodes.dropFirst(index + 1).contains { other in
                                        frames[other.id].map { WorkflowConnectionGeometry.nodePlate($0).cgPath.contains(point) } ?? false
                                    }
                                },
                                onSelectPort: { port in selectPort(port, scope: scope) },
                                onPortDrag: { port, delta in
                                    guard canConnect(in: scope), let center = measuredPortCenters[port] else { return }
                                    let pending = WorkflowPendingConnection(nodeID: port.nodeID, port: port.port, input: port.input)
                                    if pendingConnection != pending { pendingConnection = pending }
                                    if pendingConnectionScope != scope { pendingConnectionScope = scope }
                                    connectionDrag.point = CGPoint(x: center.x + delta.width / renderZoom, y: center.y + delta.height / renderZoom)
                                    if !viewportInteractionLocked { viewportInteractionLocked = true }
                                    if connectionIssue != nil { connectionIssue = nil }
                                },
                                onPortDragEnd: { target in finishConnection(to: target, scope: scope) }
                            )
                            .overlay { if let mark=planMarks[node.id] { WorkflowPlanBadge(mark:mark,scale:renderZoom).frame(width: WorkflowCanvasLayoutPolicy.width(node.id, in: geometry.graph) * renderZoom) } }
                            .onGeometryChange(for: CGSize.self) { CGSize(width: $0.size.width / renderZoom - 22, height: $0.size.height / renderZoom) } action: { size in
                                cardSizes[node.id] = size
                                nodeSizeObserver?(node.id, size)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            // Keep the full intrinsic event bounds. A short outer frame
                            // would paint ports below it but reject their native hits.
                            .offset(x: (position.x - WorkflowCanvasLayoutPolicy.width(node.id, in: geometry.graph) / 2 - 11) * effectiveZoom,
                                    y: (position.y - WorkflowNodePortLayout.titleHeight / 2) * effectiveZoom)
                            .modifier(WorkflowNodeDragOffset(presentation: nodeDrag,
                                moving: nodeDrag.movingNodeIDs.contains(node.id), scale: effectiveZoom))
                        }
                        if self.graph == nil {
                            ContentUnavailableView(
                                workflowText(languageStore, "workflow.canvas.empty"),
                                systemImage: "point.3.connected.trianglepath.dotted",
                                description: Text(workflowText(languageStore, "workflow.canvas.emptyDescription"))
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .allowsHitTesting(false)
                        }
                        }
                        // Offset-positioned cards keep their intrinsic layout size.
                        // Anchor that stack at the graph origin; centering it would
                        // move the painted cards away from pointer/connection geometry.
                        .frame(width: geometry.size.width * effectiveZoom, height: geometry.size.height * effectiveZoom,
                               alignment: .topLeading)
                        // Main wires and their event receivers belong behind opaque node plates.
                        // Edge ports meet the main wires directly; node plates retain their z-order.
                        .backgroundPreferenceValue(WorkflowPortAnchorPreferenceKey.self) { anchors in
                        GeometryReader { proxy in
                            let centers = anchors.mapValues { CGPoint(x: proxy[$0].x / effectiveZoom, y: proxy[$0].y / effectiveZoom) }
                            WorkflowConnectionLayer(
                                graph: graph,
                                registry: controller.registry,
                                tools: controller.tools,
                                geometry: geometry,
                                dragPresentation: nodeDrag,
                                portCenters: centers,
                                controlBounds: controlBounds,
                                cardSizes: cardSizes,
                                selectedConnectionID: selectedConnectionID,
                                pendingConnection: pendingConnection,
                                dragPoint: connectionDrag,
                                canDisconnect: !readOnly && controller.canEditCanvas,
                                onSelect: { connectionID in
                                    if scope.isCurrent(in: controller) {
                                        controller.selectedNodeID = nil; controller.selectedNodeIDs = []
                                        selectedConnectionID = connectionID
                                    }
                                },
                                onDisconnect: { connection in
                                    guard !readOnly, WorkflowCanvasConnectionEditing.disconnect(connection,
                                        scope: scope, controller: controller) else { return }
                                    if selectedConnectionID == connection.id { selectedConnectionID = nil }
                                }
                            )
                            .scaleEffect(effectiveZoom, anchor: .topLeading)
                            .onAppear { updatePortCenters(centers) }
                            .onChange(of: centers) { _, updated in updatePortCenters(updated) }
                        }
                    }
                    .overlayPreferenceValue(WorkflowNodeControlPreferenceKey.self) { anchors in
                        GeometryReader { proxy in
                            let frames = anchors.map { proxy[$0.anchor].applying(CGAffineTransform(scaleX: 1/effectiveZoom, y: 1/effectiveZoom)) }
                            let owned = Dictionary(grouping: anchors.filter { $0.nodeID != nil }, by: { $0.nodeID! })
                                .mapValues { $0.map { proxy[$0.anchor].applying(CGAffineTransform(scaleX: 1/effectiveZoom, y: 1/effectiveZoom)) } }
                            Color.clear.allowsHitTesting(false)
                                .onAppear { updateControlBounds(frames); nodeControlBounds = owned; nodeDrag.latestOwnedControlBounds = owned }
                                .onChange(of: frames) { _, next in
                                    updateControlBounds(next)
                                    nodeDrag.latestOwnedControlBounds = owned
                                    if nodeDrag.active == nil { nodeControlBounds = owned }
                                }
                                .onChange(of: owned) { _, next in
                                    nodeDrag.latestOwnedControlBounds = next
                                    if nodeDrag.active == nil { nodeControlBounds = next }
                                }
                        }.allowsHitTesting(false)
                    }
                    .offset(x: edge.width * effectiveZoom, y: edge.height * effectiveZoom)
                    if let marquee, marquee.scope == scope {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.13))
                            .frame(width: marquee.rect.width * effectiveZoom, height: marquee.rect.height * effectiveZoom)
                            .position(x: marquee.rect.midX * effectiveZoom, y: marquee.rect.midY * effectiveZoom)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    }
                    .frame(width: (contentSize.width + edge.width * 2) * effectiveZoom,
                           height: (contentSize.height + edge.height * 2) * effectiveZoom)
                    .coordinateSpace(name: WorkflowCanvasCoordinateSpace.name)
                    .contentShape(Rectangle())
                    .onDrop(of: [.workflowCanvasItem, .fileURL], delegate: WorkflowLibrarySurfaceDrop(preview: libraryDropPreview, scope: scope,
                        makeHit: {
                            libraryDropIssues.begin(scope: scope)
                            let map = WorkflowLibraryDropHitMap(graph: graph, geometry: geometry, centers: measuredPortCenters, sizes: cardSizes)
                            return { point in map.hit(CGPoint(x: point.x / renderZoom - edge.width, y: point.y / renderZoom - edge.height)) }
                        },
                        assess: { value, port in WorkflowLibraryPortDrop.admission(value, port: port,
                            scope: scope, controller: controller) }) { providers, location in
                        guard providers.count == 1, let provider = providers.first,
                              !readOnly, let target = controller.canvasInsertionTarget(),
                              let issueToken = libraryDropIssues.token(for: scope) else { return false }
                        let raw = geometry.rawPoint(forDisplayPoint: CGPoint(
                            x: location.x / effectiveZoom - edge.width, y: location.y / effectiveZoom - edge.height))
                        let destination = WorkflowLibraryDropTarget.hit(CGPoint(x: location.x / effectiveZoom - edge.width,
                            y: location.y / effectiveZoom - edge.height), graph: graph, geometry: geometry,
                            centers: measuredPortCenters, sizes: cardSizes)
                        let custom = provider.hasItemConformingToTypeIdentifier(UTType.workflowCanvasItem.identifier)
                        Task { @MainActor in
                            do {
                                let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                                    provider.loadDataRepresentation(forTypeIdentifier: custom ? UTType.workflowCanvasItem.identifier : UTType.fileURL.identifier) { data, error in
                                        if let data { continuation.resume(returning: data) }
                                        else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                                    }
                                }
                                guard controller.isCurrent(target) else { throw WorkflowIssue("Drop target changed.", code: "container.stale") }
                                if custom {
                                    let value = try WorkflowCanvasTransfer.decode(bytes)
                                    if value.libraryPayload != nil, case .port(let port) = destination {
                                        _ = WorkflowLibraryPortDrop.submit(value, port: port, scope: scope, controller: controller, language: languageStore) { message in
                                            libraryDropIssues.report(message.reason, code: message.code, scope: scope, token: issueToken)
                                        }
                                    } else {
                                        if value.libraryPayload != nil, destination == .blocked { throw WorkflowIssue("Drop target does not accept this source.", code: "container.dropTarget") }
                                        _ = acceptSurfaceDrop([value], at: raw, scope: scope)
                                    }
                                }
                                else if let url = URL(dataRepresentation: bytes, relativeTo: nil), url.isFileURL {
                                    guard destination == .canvas else { throw WorkflowIssue("Drop target does not accept this source.", code: "container.dropTarget") }
                                    _ = acceptFileDrop([url], at: raw, scope: scope)
                                } else { throw CocoaError(.fileReadUnsupportedScheme) }
                            } catch {
                                let issue = WorkflowIssue(presenting: error, fallbackCode: "container.issue.actionFailed")
                                controller.reportIssue(issue)
                                libraryDropIssues.report(issue.reason, code: issue.code, scope: scope, token: issueToken)
                            }
                        }
                        return true
                    })
                    .overlay(alignment: .topLeading) { WorkflowLibraryDropFeedback(preview: libraryDropPreview) }
                    .onChange(of: scope) { _, _ in libraryDropPreview.clear() }
                    .onChange(of: scope.identity) { _, _ in libraryDropIssues.clear() }
                    .onChange(of: renderZoom) { _, _ in libraryDropPreview.clear() }
                    .onChange(of: edge) { _, _ in libraryDropPreview.clear() }
                    .onDisappear { libraryDropPreview.clear(); libraryDropIssues.clear() }
                    .frame(width: layout.contentSize.width,
                           height: layout.contentSize.height,
                           alignment: .topLeading)
                }
                .overlay(alignment: .bottom) {
                    if let issue = libraryDropIssues.issue, issue.isVisible(in: scope) {
                        WorkflowLibraryDropIssueView(message: issue.message, code: issue.code) { libraryDropIssues.clear() }
                    }
                }
                .scrollIndicators(.never)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: WorkflowCanvasScrollObservation.self) { scroll in
                    let size = clipViewportSize ?? scroll.containerSize
                    return WorkflowCanvasScrollObservation(contentOffset: scroll.contentOffset,
                        containerSize: size, zoom: effectiveZoom,
                        visibleRawCenter: WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                            viewportSize: size, zoom: effectiveZoom,
                            translation: geometry.translation).visibleRawCenter(offset: scroll.contentOffset))
                } action: { _, observation in
                    scrollTracking.offset = observation.contentOffset
                    if !scrollTracking.isPanning { onScrollObservation(viewContext, observation) }
                }

                .onAppear {
                    retainedExtent = .init(identity: scope.identity, translation: geometry.translation, size: geometry.size)
                    if let navigationRequest {
                        scrollPosition.scrollTo(point: layout.centeredOffset(
                            on: navigationRequest.rawCenter ?? naturalCenter(of: geometry.graph)))
                    } else {
                        scrollPosition.scrollTo(point: layout.centeredOffset(on: naturalCenter(of: geometry.graph)))
                    }
                }
                .onChange(of: navigationRequest) { _, request in
                    guard let request else { return }
                    scrollTracking.wheelZoom.cancel()
                    Task { @MainActor in
                        guard navigationRequest == request else { return }
                        let current = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                            viewportSize: clipViewportSize ?? viewport.size,
                            zoom: zoom, translation: geometry.translation)
                        scrollPosition.scrollTo(point: current.centeredOffset(
                            on: request.rawCenter ?? naturalCenter(of: geometry.graph)))
                    }
                }
                .onChange(of: clipViewportSize) { old, new in
                    guard let new, new.width > 0, new.height > 0 else { return }
                    scrollTracking.wheelZoom.cancel()
                    let previous = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: old ?? viewport.size,
                        zoom: effectiveZoom, translation: geometry.translation)
                    let next = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: new, zoom: effectiveZoom, translation: geometry.translation)
                    let raw = resizeAnchorRaw ?? (old == nil
                        ? navigationRequest?.rawCenter ?? naturalCenter(of: geometry.graph)
                        : previous.visibleRawCenter(offset: scrollTracking.offset))
                    resizeAnchorRaw = nil
                    scrollPosition.scrollTo(point: next.centeredOffset(on: raw))
                }
                .onChange(of: zoom) { old, new in
                    guard old != new, new == zoom, !viewportInteractionLocked else { return }
                    if scrollTracking.wheelZoom.consumeScaleChange(to: new) { return }
                    let previous = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: viewportSize, zoom: old, translation: geometry.translation)
                    let next = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: viewportSize, zoom: new, translation: geometry.translation)
                    let offset = next.centeredOffset(
                        on: previous.visibleRawCenter(offset: scrollTracking.offset))
                    scrollPosition.scrollTo(point: offset)
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($gestureScale) { value, state, _ in state = value }
                        .onChanged { _ in scrollTracking.wheelZoom.cancel() }
                        .onEnded { value in
                            if !viewportInteractionLocked {
                                zoom = WorkflowCanvasLayoutPolicy.clampedInteractiveZoom(zoom * value,
                                                                                         current: zoom)
                            }
                        }
                )
                .onChange(of: scope) { _, next in
                    scrollTracking.wheelZoom.cancel()
                    marquee = nil
                    viewportInteractionLocked = false
                    if nodeDrag.active?.scope != next { nodeDrag.invalidate(); viewportInteractionLocked = false }
                    if stableOrigin?.identity != next.identity { stableOrigin = nil }
                    if pendingConnectionScope != next {
                        pendingConnection = nil
                        pendingConnectionScope = nil
                        connectionDrag.point = nil
                        connectionIssue = nil
                    }
                }
                .onChange(of: tool) { _, next in
                    scrollTracking.wheelZoom.cancel()
                    marquee = nil
                    viewportInteractionLocked = false
                    if next == .hand {
                        pendingConnection = nil
                        pendingConnectionScope = nil
                        connectionDrag.point = nil
                        connectionIssue = nil
                    }
                }
                .onChange(of: WorkflowCanvasRetainedExtent(identity: scope.identity,
                    translation: geometry.translation, size: geometry.size)) { _, value in
                    retainedExtent = value
                }
                .onChange(of: graph.connections) { _, _ in connectionIssue = nil }
                .onChange(of: naturalGeometry.translation) { _, natural in
                    guard nodeDrag.active == nil,
                          let retained = stableOrigin,
                          retained.identity == scope.identity else { return }
                    let reachable = WorkflowCanvasOriginPolicy.resolved(
                        natural: natural,
                        retained: retained.translation,
                        active: nil
                    )
                    if reachable != retained.translation {
                        stableOrigin = WorkflowCanvasStableOrigin(
                            identity: retained.identity,
                            translation: reachable
                        )
                    }
                }
                .onChange(of: readOnly || !controller.canEditCanvas) { _, blocked in
                    if blocked {
                        nodeDrag.invalidate()
                        marquee = nil
                        clearConnection()
                    }
                }
                .onDisappear {
                    scrollTracking.wheelZoom.cancel()
                    nodeDrag.invalidate()
                    marquee = nil
                    clearConnection()
                    viewportInteractionLocked = false
                }
                .overlay(alignment: .topLeading) {
                    if let pendingConnection {
                        HStack(spacing: 8) {
                            Label(workflowText(
                                languageStore,
                                pendingConnection.input ? "workflow.connection.chooseOutput" : "workflow.connection.chooseInput",
                                fallback: pendingConnection.input ? "已选择输入 {port}，请选择来源输出" : "已选择输出 {port}，请选择目标输入",
                                arguments: ["port": pendingConnection.port]
                            ), systemImage: "link")
                            Button(workflowText(languageStore, "workflow.connection.cancel")) {
                                clearConnection()
                            }
                                .buttonStyle(WorkbenchGlassButtonStyle(compact: true))
                .workflowNodeControl()
                        }
                        .font(.caption)
                        .padding(8)
                        .workbenchPanel(cornerRadius: 8)
                        .padding(10)
                    }
                    if let connectionIssue {
                        Text(connectionIssue.message(language: languageStore))
                            .font(.caption).foregroundStyle(.orange)
                            .padding(8).workbenchPanel(cornerRadius: 8)
                            .padding(.top, pendingConnection == nil ? 10 : 48).padding(.leading, 10)
                    }
                }
                }
        }
        .accessibilityIdentifier("workflow-graph-surface")
    }

    private func updatePortCenters(_ centers: [WorkflowPortIdentity: CGPoint]) {
        nodeDrag.latestPortCenters = centers
        if nodeDrag.active == nil, measuredPortCenters != centers { measuredPortCenters = centers }
        portCenterObserver?(centers)
        if let pendingConnection, connectionDrag.point != nil,
           centers[WorkflowPortIdentity(nodeID: pendingConnection.nodeID,
               port: pendingConnection.port, input: pendingConnection.input)] == nil {
            clearConnection()
        }
    }

    private func updateControlBounds(_ frames: [CGRect]) {
        nodeDrag.latestControlBounds = frames
        if nodeDrag.active == nil, controlBounds != frames { controlBounds = frames }
    }

    private func restoreMeasuredHits() {
        measuredPortCenters = nodeDrag.latestPortCenters
        controlBounds = nodeDrag.latestControlBounds
        nodeControlBounds = nodeDrag.latestOwnedControlBounds
    }

    private func canConnect(in scope: WorkflowCanvasScope) -> Bool {
        tool == .pointer && !readOnly && controller.canEditCanvas
            && controller.readOnlyReason == nil && scope.isCurrent(in: controller)
    }

    private func clearConnection() {
        pendingConnection = nil; pendingConnectionScope = nil
        connectionDrag.point = nil; viewportInteractionLocked = false
    }

    private func selectPort(_ port: WorkflowPortIdentity, scope: WorkflowCanvasScope) {
        guard canConnect(in: scope) else { return }
        if let pendingConnection, pendingConnection.input != port.input, pendingConnectionScope == scope {
            finishConnection(to: port, scope: scope)
        } else {
            pendingConnection = WorkflowPendingConnection(nodeID: port.nodeID, port: port.port, input: port.input)
            pendingConnectionScope = scope; connectionIssue = nil
        }
    }

    private func finishConnection(to target: WorkflowPortIdentity?, scope: WorkflowCanvasScope) {
        let start = pendingConnection
        let current = pendingConnectionScope == scope && canConnect(in: scope)
        clearConnection()
        guard current, let start, let target, let graph = controller.graph,
              let ends = WorkflowCanvasConnectionPolicy.directedPorts(
                WorkflowPortIdentity(nodeID: start.nodeID, port: start.port, input: start.input), target) else { return }
        if let issue = WorkflowCanvasConnectionPolicy.issue(graph: graph, registry: controller.registry,
            tools: controller.tools, sourceNodeID: ends.output.nodeID, sourcePort: ends.output.port,
            targetNodeID: ends.input.nodeID, targetPort: ends.input.port) {
            connectionIssue = issue; return
        }
        controller.connect(source: ends.output.nodeID, sourcePort: ends.output.port,
                           target: ends.input.nodeID, targetPort: ends.input.port)
    }

    private func naturalCenter(of graph: WorkflowGraph) -> CGPoint {
        let geometry = WorkflowGraphGeometry(graph: graph, tools: controller.tools, registry: controller.registry)
        return CGPoint(x: geometry.size.width / 2 - geometry.translation.width,
                       y: geometry.size.height / 2 - geometry.translation.height)
    }

    private var effectiveZoom: CGFloat {
        viewportInteractionLocked ? zoom : WorkflowCanvasLayoutPolicy.clampedInteractiveZoom(
            zoom * gestureScale, current: zoom)
    }

    private func viewportInput(geometry: WorkflowGraphGeometry, layout: WorkflowCanvasViewportGeometry,
                               scope: WorkflowCanvasScope)
        -> WorkflowCanvasViewportInput {
        WorkflowCanvasViewportInput(
            tool: tool,
            onHandPressedChanged: { handPointer.pressed = $0 },
            onRequestKeyboardFocus: onRequestKeyboardFocus,
            interactionScope: scope,
            wheelZoom: scrollTracking.wheelZoom,
            navigationID: navigationRequest?.id,
            wheelLayout: { size in
                WorkflowCanvasViewportGeometry(graphSize: geometry.size, viewportSize: size,
                    zoom: effectiveZoom, translation: geometry.translation)
            },
            pointerTarget: { point, offset, _ in
                // Match the layout actually drawn, including the interval between a
                // native clip resize and delivery of its SwiftUI measurement.
                let raw = layout.rawPoint(screenPoint: point, offset: offset)
                let display = CGPoint(x: raw.x + geometry.translation.width,
                                      y: raw.y + geometry.translation.height)
                // Resolve the topmost card before testing wires or controls belonging to
                // covered cards. This matches the drawing stack and avoids invisible hits.
                for node in geometry.graph.nodes.reversed() {
                    let center = geometry.displayPosition(node.id)
                    let size = cardSizes[node.id] ?? CGSize(width: WorkflowCanvasLayoutPolicy.width(node.id, in: geometry.graph), height: 600)
                    let frame = CGRect(x: center.x - size.width / 2, y: center.y - WorkflowNodePortLayout.titleHeight / 2,
                                       width: size.width, height: size.height)
                    if WorkflowConnectionGeometry.nodePlate(frame).cgPath.contains(display) {
                        if nodeControlBounds[node.id]?.contains(where: { $0.contains(display) }) == true { return .control }
                        if tool == .pointer, measuredPortCenters.contains(where: {
                            $0.key.nodeID == node.id && WorkflowNodePortLayout.containsHit(delta: CGPoint(x: display.x - $0.value.x, y: display.y - $0.value.y), collapsed: geometry.graph.layout.first(where: { $0.nodeID == node.id })?.collapsed == true)
                        }) { return .control }
                        return .node(node.id)
                    }
                }
                if geometry.graph.connections.contains(where: {
                    WorkflowConnectionGeometry.hitPath(for: $0, geometry: geometry,
                        portCenters: measuredPortCenters, excluding: controlBounds,
                        nodeFrames: WorkflowConnectionGeometry.nodeFrames(geometry: geometry, sizes: cardSizes))
                        .cgPath.contains(display)
                }) { return .control }
                return .blank
            },
            onPointer: { update in
                guard scope.isCurrent(in: controller) else { return }
                switch update.target {
                case .control: break
                case .node(let id):
                    switch update.phase {
                    case .began:
                        beginDrag(sessionID: update.sessionID, nodeID: id,
                            originalPosition: geometry.rawPosition(id), translation: update.translation,
                            scope: scope, origin: geometry.translation)
                    case .changed:
                        updateDrag(sessionID: update.sessionID, nodeID: id,
                            translation: update.translation, scope: scope)
                    case .ended:
                        finishDrag(sessionID: update.sessionID, nodeID: id,
                            translation: update.translation, scope: scope)
                    case .cancelled:
                        nodeDrag.cancel(sessionID: update.sessionID); restoreMeasuredHits(); viewportInteractionLocked = false
                    case .clicked:
                        let raw = layout.rawPoint(screenPoint: update.startPoint, offset: update.startOffset)
                        let displayY = raw.y + geometry.translation.height
                        let center = geometry.displayPosition(id)
                        if !update.extendingSelection, !readOnly, displayY < center.y + WorkflowNodePortLayout.titleHeight / 2 {
                            controller.toggleCollapsed(id)
                        } else { onInspect(id) }
                    }
                case .blank:
                    let start = CGPoint(x: (update.startPoint.x + update.startOffset.x) / zoom,
                                        y: (update.startPoint.y + update.startOffset.y) / zoom)
                    let current = CGPoint(x: start.x + update.translation.width / zoom,
                                          y: start.y + update.translation.height / zoom)
                    switch update.phase {
                    case .began:
                        marquee = WorkflowCanvasMarquee(scope: scope, start: start, current: current,
                            baseline: update.extendingSelection ? controller.selectedNodeIDs : [])
                        viewportInteractionLocked = true
                    case .changed: marquee?.current = current
                    case .ended:
                        marquee?.current = current
                        if let marquee {
                            controller.selectedNodeIDs = marquee.selectedIDs(geometry: geometry,
                                cardSizes: cardSizes, edge: layout.unscaledPadding,
                                registry: controller.registry, tools: controller.tools)
                        }
                        controller.selectedNodeID = nil; selectedConnectionID = nil
                        marquee = nil; viewportInteractionLocked = false
                    case .cancelled: marquee = nil; viewportInteractionLocked = false
                    case .clicked:
                        controller.selectedNodeID = nil; controller.selectedNodeIDs = []
                        selectedConnectionID = nil
                        onClearSelection()
                    }
                }
            },
            onPan: { [capturedZoom = zoom] active, offset, size in
                scrollTracking.isPanning = active
                viewportInteractionLocked = active
                scrollTracking.offset = offset
                if !active {
                    let layout = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: size, zoom: capturedZoom, translation: geometry.translation)
                    onScrollObservation(viewContext, WorkflowCanvasScrollObservation(contentOffset: offset,
                        containerSize: size, zoom: capturedZoom, isGestureEnd: true,
                        visibleRawCenter: layout.visibleRawCenter(offset: offset)))
                }
            },
            navigationAllowed: {
                WorkflowCanvasViewportNavigationGate.allows(
                    marqueeActive: marquee != nil,
                    interactionLocked: viewportInteractionLocked,
                    nodeDragging: nodeDrag.active != nil,
                    outputDragging: connectionDrag.point != nil)
            },
            allowsEvent: { point, offset, size in
                let current = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                    viewportSize: size, zoom: zoom, translation: geometry.translation)
                let raw = current.rawPoint(screenPoint: point,
                    offset: scrollTracking.wheelZoom.offset(in: current, scope: scope) ?? offset)
                for node in geometry.graph.nodes {
                    let center = geometry.rawPosition(node.id)
                    let height = cardSizes[node.id]?.height ?? 600
                    if abs(raw.x - center.x) <= WorkflowCanvasLayoutPolicy.width(node.id, in: geometry.graph) / 2,
                       raw.y >= center.y - WorkflowNodePortLayout.titleHeight / 2,
                       raw.y <= center.y - WorkflowNodePortLayout.titleHeight / 2 + height { return false }
                }
                return true
            },
            onViewportSize: { measured in
                let size = measured.clip
                let raw = clipViewportSize.map { oldSize in
                    WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: oldSize, zoom: zoom,
                        translation: geometry.translation).visibleRawCenter(offset: scrollTracking.offset)
                }
                Task { @MainActor in
                    if clipViewportSize != size {
                        resizeAnchorRaw = raw
                        clipViewportSize = size
                    }
                    viewportSizeObserver?(measured)
                }
            },
            onWheel: { delta, point, offset, size in
                let old = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                    viewportSize: size, zoom: zoom, translation: geometry.translation)
                zoom = scrollTracking.wheelZoom.request(delta: delta * (displayPreferences.canvasNavigation?.resolvedSpeed ?? 1), mouse: point,
                    nativeOffset: offset, layout: old, scope: scope)
            })
    }

    private func beginDrag(
        sessionID: UUID,
        nodeID: UUID,
        originalPosition: CGPoint,
        translation: CGSize,
        scope: WorkflowCanvasScope,
        origin: CGSize
    ) {
        guard !readOnly, controller.canEditCanvas, controller.readOnlyReason == nil else {
            nodeDrag.invalidate()
            return
        }
        guard let graph = controller.graph,
              let target = controller.canvasInsertionTarget(),
              scope.isCurrent(in: controller) else { return }
        let selected: Set<UUID> = controller.selectedNodeIDs.contains(nodeID)
            ? controller.selectedNodeIDs : [nodeID]
        if !controller.selectedNodeIDs.contains(nodeID) {
            controller.selectedNodeIDs = [nodeID]
            controller.selectedNodeID = nodeID
        }
        let natural = WorkflowGraphGeometry(graph: graph, tools: controller.tools,
                                            registry: controller.registry)
        let positions = Dictionary(uniqueKeysWithValues: graph.nodes
            .filter { selected.contains($0.id) }
            .map { ($0.id, natural.rawPosition($0.id)) })
        let layouts = Dictionary(uniqueKeysWithValues: graph.nodes
            .filter { selected.contains($0.id) }
            .map { node in
                (node.id, graph.layout.first(where: { $0.nodeID == node.id })
                    ?? WorkflowLayout(nodeID: node.id,
                        x: Double(natural.rawPosition(node.id).x),
                        y: Double(natural.rawPosition(node.id).y)))
            })
        let began = nodeDrag.begin(
            WorkflowCanvasNodeDragState(
                sessionID: sessionID,
                scope: scope,
                nodeID: nodeID,
                originalPosition: originalPosition,
                origin: origin,
                originalPositions: positions,
                originalLayouts: layouts,
                target: target
            ),
            screenTranslation: translation,
            zoom: effectiveZoom
        )
        if began {
            stableOrigin = WorkflowCanvasStableOrigin(identity: scope.identity, translation: origin)
            viewportInteractionLocked = true
        }
    }

    private func updateDrag(
        sessionID: UUID,
        nodeID: UUID,
        translation: CGSize,
        scope: WorkflowCanvasScope
    ) {
        guard !readOnly, controller.canEditCanvas, controller.readOnlyReason == nil else {
            nodeDrag.invalidate()
            return
        }
        _ = nodeDrag.update(
            sessionID: sessionID,
            nodeID: nodeID,
            scope: scope,
            screenTranslation: translation,
            zoom: effectiveZoom
        )
    }

    private func finishDrag(
        sessionID: UUID,
        nodeID: UUID,
        translation: CGSize,
        scope: WorkflowCanvasScope
    ) {
        defer { restoreMeasuredHits() }
        viewportInteractionLocked = false
        guard let drag = nodeDrag.finish(
            sessionID: sessionID,
            nodeID: nodeID,
            scope: scope,
            screenTranslation: translation,
            zoom: effectiveZoom
        ) else { return }
        let currentGraph = controller.graph
        let currentScope = currentGraph.map {
            WorkflowCanvasScope(
                rootGraphID: controller.rootGraph?.id ?? $0.id,
                rootRevision: controller.rootGraph?.revision ?? $0.revision,
                graphID: $0.id,
                bodyPath: controller.bodyPath,
                projectID: controller.projectID, instanceID: controller.projectInstanceID
            )
        }
        guard currentScope == scope,
              drag.canCommit(
                currentScope: currentScope,
                graph: currentGraph,
                currentPosition: currentGraph.map {
                    WorkflowGraphGeometry(
                        graph: $0, tools: controller.tools, registry: controller.registry
                    ).rawPosition(nodeID)
                },
                readOnly: readOnly || controller.readOnlyReason != nil,
                isRunning: controller.isRunning && !controller.canEditCanvas
              ),
              let target = drag.target,
              controller.isCurrent(target),
              let currentGraph else { return }
        let currentGeometry = WorkflowGraphGeometry(graph: currentGraph, tools: controller.tools,
                                                    registry: controller.registry)
        guard drag.originalPositions.allSatisfy({ id, point in
            currentGraph.nodes.contains(where: { $0.id == id })
                && currentGeometry.rawPosition(id) == point
        }) else { return }
        stableOrigin = WorkflowCanvasStableOrigin(identity: scope.identity, translation: drag.origin)
        let layouts = drag.previewPositions.compactMap { id, point -> WorkflowLayout? in
            guard var layout = drag.originalLayouts[id] else { return nil }
            layout.x = Double(point.x)
            layout.y = Double(point.y)
            return layout
        }
        guard layouts.count == drag.originalPositions.count else { return }
        controller.moveNodes(layouts, target: target)
    }

    func acceptFileDrop(_ urls: [URL], at rawPoint: CGPoint, scope: WorkflowCanvasScope) -> Bool {
        guard urls.count == 1, let url = urls.first, url.isFileURL,
              !readOnly, controller.canEditCanvas, controller.readOnlyReason == nil,
              controller.graph == nil || scope.isCurrent(in: controller) else { return false }
        if intersectsNode(rawPoint) {
            controller.errorMessage = workflowText(languageStore, "container.dropTarget")
            return true
        }
        return onDropCanvasFile(url, rawPoint)
    }
    private func intersectsNode(_ rawPoint: CGPoint) -> Bool {
        guard let graph = self.graph else { return false }
        let geometry = WorkflowGraphGeometry(graph: graph, tools: controller.tools, registry: controller.registry)
        let point = CGPoint(x: rawPoint.x + geometry.translation.width, y: rawPoint.y + geometry.translation.height)
        return WorkflowConnectionGeometry.nodeFrames(geometry: geometry, sizes: cardSizes).values.contains {
            WorkflowConnectionGeometry.nodePlate($0).cgPath.contains(point)
        }
    }
    func acceptSurfaceDrop(
        _ items: [WorkflowCanvasTransfer],
        at rawPoint: CGPoint,
        scope: WorkflowCanvasScope
    ) -> Bool {
        guard items.count == 1, !readOnly, controller.canEditCanvas,
              controller.readOnlyReason == nil,
              let item = try? items[0].validated() else { return false }
        if controller.graph == nil {
            switch item {
            case .operation, .asset, .assetInstance, .tool, .library, .libraryItems: return onDropItem(item, rawPoint)
            case .output: return false
            }
        }
        guard scope.isCurrent(in: controller) else { return false }
        if item.libraryPayload != nil {
            if intersectsNode(rawPoint) {
                controller.errorMessage = workflowText(languageStore, "container.dropTarget")
                return true
            }
        }
        switch item {
        case .operation, .asset, .assetInstance, .tool, .library, .libraryItems:
            return onDropItem(item, rawPoint)
        case .output:
            return false
        }
    }
}

private enum WorkflowCanvasCoordinateSpace {
    static let name = "workflow-canvas-unscaled"
}

@MainActor
enum WorkflowCanvasConnectionEditing {
    @discardableResult
    static func disconnect(_ connection: WorkflowConnection, scope: WorkflowCanvasScope,
                           controller: WorkflowController) -> Bool {
        guard scope.isCurrent(in: controller), controller.canEditCanvas,
              controller.graph?.connections.contains(connection) == true else { return false }
        controller.disconnect(connection.id)
        return true
    }
}

enum WorkflowCanvasConnectionSubmission {
    @discardableResult
    static func submit(tool: WorkflowCanvasTool, _ action: () -> Void) -> Bool {
        guard tool == .pointer else { return false }
        action()
        return true
    }
}

struct WorkflowCanvasMarquee {
    let scope: WorkflowCanvasScope
    let start: CGPoint
    var current: CGPoint
    let baseline: Set<UUID>

    var rect: CGRect {
        CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
               width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    func selectedIDs(geometry: WorkflowGraphGeometry,
                     cardSizes: [UUID: CGSize], edge: CGSize,
                     registry: WorkflowRegistry = .standard,
                     tools: [WorkflowToolDefinition] = []) -> Set<UUID> {
        var selected = baseline
        for node in geometry.graph.nodes {
            let center = geometry.displayPosition(node.id)
            let definition = registry.definition(for: node, tools: tools)
            let fallbackHeight = geometry.graph.layout.first(where: { $0.nodeID == node.id })?.collapsed == true
                ? WorkflowNodePortLayout.portBottom(inputs: definition?.inputs.count ?? 0, outputs: definition?.outputs.count ?? 0, collapsed: true) : CGFloat(WorkflowLayout.cardHeightBudget(
                    inputs: definition?.inputs.count ?? 1, outputs: definition?.outputs.count ?? 1))
            let height = cardSizes[node.id]?.height ?? fallbackHeight
            let card = CGRect(x: center.x + edge.width - WorkflowCanvasLayoutPolicy.width(node.id, in: geometry.graph) / 2,
                              y: center.y + edge.height - WorkflowNodePortLayout.titleHeight / 2,
                              width: WorkflowCanvasLayoutPolicy.width(node.id, in: geometry.graph), height: height)
            if rect.intersects(card) { selected.insert(node.id) }
        }
        return selected
    }
}

private struct WorkflowConnectionLayer: View {
    @Environment(\.dLanguageStore) private var language
    let graph: WorkflowGraph
    let registry: WorkflowRegistry
    let tools: [WorkflowToolDefinition]
    let geometry: WorkflowGraphGeometry
    let dragPresentation: WorkflowCanvasNodeDragPresentation
    let portCenters: [WorkflowPortIdentity: CGPoint]
    let controlBounds: [CGRect]
    let cardSizes: [UUID: CGSize]
    let selectedConnectionID: UUID?
    let pendingConnection: WorkflowPendingConnection?
    let dragPoint: WorkflowConnectionDragPresentation
    let canDisconnect: Bool
    let onSelect: (UUID) -> Void
    let onDisconnect: (WorkflowConnection) -> Void

    var body: some View {
        let centers = WorkflowConnectionGeometry.movingFallbackCenters(
            graph: graph, geometry: geometry, measured: portCenters,
            moving: dragPresentation.movingNodeIDs, offset: dragPresentation.offset)
        let frames = WorkflowConnectionGeometry.nodeFrames(geometry: geometry, sizes: cardSizes,
            moving: dragPresentation.movingNodeIDs, offset: dragPresentation.offset)
        let paths = graph.connections.map {
            WorkflowConnectionGeometry.path(for: $0, geometry: geometry, portCenters: centers, nodeFrames: frames)
        }
        let drawingBounds = WorkflowConnectionGeometry.drawingBounds(size: geometry.size, paths: paths)
        let drawingOrigin = drawingBounds.origin
        ZStack(alignment: .topLeading) {
            WorkflowConnectionDrawing(strokes: zip(graph.connections, paths).map { connection, path in
                .init(path: path, color: WorkflowPortStyle.color(for: sourcePort(connection)),
                      selected: connection.id == selectedConnectionID)
            }, origin: drawingOrigin)
            // Preserve the full curve coordinate range, but allocate/draw only
            // the visible native child; distant nodes do not create a giant bitmap.
            .frame(width: drawingBounds.width, height: drawingBounds.height)
            .offset(x: drawingOrigin.x, y: drawingOrigin.y)
            .allowsHitTesting(false)

            // The captured node gesture owns the mouse until release/cancel.
            // Rebuild precise native wire hits once afterwards, not for every preview.
            if dragPresentation.movingNodeIDs.isEmpty {
                ForEach(graph.connections) { connection in
                    WorkflowConnectionInteraction(connection: connection, geometry: geometry,
                        portCenters: centers, controlBounds: controlBounds, nodeFrames: frames, canDisconnect: canDisconnect,
                        label: WorkflowConnectionPresentation.title(connection, graph: graph,
                            registry: registry, tools: tools, language: language, disambiguateNodeNames: false),
                        onSelect: { onSelect(connection.id) }, onDisconnect: { onDisconnect(connection) })
                }
            }
            WorkflowPendingConnectionLayer(pending: pendingConnection, drag: dragPoint,
                centers: centers, nodeFrames: frames, color: WorkflowPortStyle.color(for: pendingConnection.flatMap { sourcePort($0) }))

        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    private func sourcePort(_ connection: WorkflowConnection) -> WorkflowPortDefinition? {
        sourcePort(WorkflowPendingConnection(nodeID: connection.sourceNode, port: connection.sourcePort))
    }

    private func sourcePort(_ source: WorkflowPendingConnection) -> WorkflowPortDefinition? {
        guard let node = graph.nodes.first(where: { $0.id == source.nodeID }) else { return nil }
        let definition = registry.definition(for: node, tools: tools)
        return (source.input ? definition?.inputs : definition?.outputs)?.first(where: { $0.id == source.port })
    }
}

@MainActor @Observable
final class WorkflowConnectionDragPresentation {
    var point: CGPoint?
}

private struct WorkflowPendingConnectionLayer: View {
    let pending: WorkflowPendingConnection?
    let drag: WorkflowConnectionDragPresentation
    let centers: [WorkflowPortIdentity: CGPoint]
    let nodeFrames: [UUID: CGRect]
    let color: Color
    var body: some View {
        if let pending, let point = drag.point,
           let dot = centers[.init(nodeID: pending.nodeID, port: pending.port, input: pending.input)] {
            let start = dot
            WorkflowConnectionGeometry.curve(from: pending.input ? point : start,
                to: pending.input ? start : point)
                .stroke(color, lineWidth: 2.5).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// The hover affordance and menu share the same guarded, single-shot edit.
private struct WorkflowConnectionInteraction: View {
    @Environment(\.dLanguageStore) private var language
    let connection: WorkflowConnection
    let geometry: WorkflowGraphGeometry
    let portCenters: [WorkflowPortIdentity: CGPoint]
    let controlBounds: [CGRect]
    let nodeFrames: [UUID: CGRect]
    let canDisconnect: Bool
    let label: String
    let onSelect: () -> Void
    let onDisconnect: () -> Void
    @State private var hitCache = WorkflowConnectionHitCache()
    var body: some View {
        let hit = hitCache.path(for: connection,
            geometry: geometry, portCenters: portCenters, excluding: controlBounds, nodeFrames: nodeFrames)
        let ends = WorkflowConnectionGeometry.endpoints(for: connection,
            geometry: geometry, portCenters: portCenters, nodeFrames: nodeFrames)
        let middle = CGPoint(x: (ends.start.x + ends.end.x) / 2, y: (ends.start.y + ends.end.y) / 2)
        WorkflowConnectionReceiver(path: hit.cgPath, midpoint: middle,
            canDisconnect: canDisconnect,
            cutAvailable: WorkflowConnectionGeometry.canShowCut(at: middle,
                portCenters: Array(portCenters.values), controls: controlBounds + Array(nodeFrames.values)), label: label,
            disconnectTitle: workflowText(language, "workflow.connection.disconnect", fallback: "断开连接"),
            identifier: "workflow-connection-" + connection.id.uuidString,
            onSelect: onSelect, onDisconnect: onDisconnect)
    }
}

private struct WorkflowNodeInspectButtonStyle: ButtonStyle {
    let inspecting: Bool
    var scale: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 22 * scale, height: 22 * scale)
            .foregroundStyle(inspecting || configuration.isPressed ? Color.accentColor : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 5 * scale)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.32 : inspecting ? 0.16 : 0))
            }
            .background { Color.clear.workbenchPanel(cornerRadius: 5 * scale) }
            .contentShape(RoundedRectangle(cornerRadius: 5 * scale))
    }
}

enum WorkflowNodePortLayout {
    static let titleHeight: CGFloat = 36
    static func rowHeight(collapsed: Bool) -> CGFloat { collapsed ? 16 : 24 }
    static func hitHeight(collapsed: Bool) -> CGFloat { collapsed ? 16 : 22 }
    static func firstCenter(collapsed: Bool) -> CGFloat { collapsed ? 44 : 72 }
    static func portBottom(inputs: Int, outputs: Int, collapsed: Bool) -> CGFloat {
        (collapsed ? titleHeight : 60) + CGFloat(max(inputs, outputs)) * rowHeight(collapsed: collapsed) + 8
    }
    static func containsHit(delta: CGPoint, collapsed: Bool) -> Bool {
        pow(delta.x / 11, 2) + pow(delta.y / (hitHeight(collapsed: collapsed) / 2), 2) <= 1
    }
}

private struct WorkflowNodeCard: View {
    @State private var containerPresentation = WorkflowContainerPresentation()
    @State private var resizePreview: CGSize?
    @State private var resizeTarget: WorkflowCanvasInsertionTarget?
    private var isContainer: Bool { WorkflowAssetContainer.isContainer(node.operationID) }
    private var cardWidth: CGFloat { WorkflowCanvasLayoutPolicy.width(node.id, in: graph) }
    private var cardHeight: CGFloat { WorkflowCanvasLayoutPolicy.containerHeight(node.id, in: graph) }
    @Environment(\.workbenchModelReadiness) private var modelReadiness
    @Environment(\.workflowPrepareNode) private var prepareNode
    @Environment(\.workflowPreparingModels) private var preparingModels
    let controller: WorkflowController
    var scale: CGFloat = 1
    let graph: WorkflowGraph
    let scope: WorkflowCanvasScope
    let node: WorkflowNode
    let definition: WorkflowOperationDefinition?
    @Binding var pendingConnection: WorkflowPendingConnection?
    let tool: WorkflowCanvasTool
    let pointerPresentation: WorkflowCanvasPointerPresentation
    let pendingConnectionScope: WorkflowCanvasScope?
    let readOnly: Bool
    let selected: Bool
    let inspecting: Bool
    let runTarget: Bool
    let onPlan: (UUID, Bool) -> Void
    let onSetRunTarget: (UUID) -> Void
    let onPlanRange: ((UUID, Int) -> Void)?
    let onViewResults: ((UUID) -> Void)?
    let onBindAsset: (UUID, UUID?, UUID, UUID) -> Bool
    let onInspect: (UUID) -> Void
    let portVisible: (WorkflowPortIdentity, CGPoint) -> Bool
    let onSelectPort: (WorkflowPortIdentity) -> Void
    let onPortDrag: (WorkflowPortIdentity, CGSize) -> Void
    let onPortDragEnd: (WorkflowPortIdentity?) -> Void
    @Environment(\.dLanguageStore) private var languageStore
    @Environment(\.chatDisplayPreferences) private var displayPreferences
    @Environment(\.colorScheme) private var colorScheme
    private var collapsed: Bool { controller.graph?.layout.first(where: { $0.nodeID == node.id })?.collapsed == true }

    private var modelIdentity: String {
        WorkflowNodeIdentity.modelIdentity(node: node, definition: definition, defaults: controller.services.capturedModelDefaults()) ?? ""
    }
    private var modelNotReady: Bool { definition?.modelKind != nil && modelReadiness[modelIdentity] != .available }
    private var downloadEntry: ModelCatalogEntry? {
        guard node.parameters["modelID"]?.string?.isEmpty == false else { return nil }
        return ModelLibraryModel.nodeDownloadEntry(operationID: node.operationID, identity: modelIdentity,
            catalog: (try? ModelCatalog.entries()) ?? [])
    }
    var body: some View {
        #if DEBUG
        let _ = WorkflowCanvasUpdateProbe.nodeBody?(node.id)
        #endif
        // Share only this render's command tree. Each subsequent body still
        // captures the current owner, scope, language and admission state.
        let actions = nodeActions
        let container = WorkflowAssetContainerView(controller: controller, node: node, scale: scale, height: cardHeight - 96, presentation: containerPresentation)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6 * scale) {
                if isContainer {
                    Button { if scope.isCurrent(in: controller) { controller.toggleCollapsed(node.id) } } label: {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 12 * scale)).frame(width: 28 * scale, height: 28 * scale)
                    }.buttonStyle(.plain).workflowNodeControl(node.id)
                        .accessibilityLabel(workflowText(languageStore, collapsed ? "container.expand" : "container.collapse"))
                } else { Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9 * scale)).allowsHitTesting(false) }
                Text(WorkflowHumanPresentation.name(node, in: graph.nodes, language: languageStore))
                    .font(.system(size: 13 * scale, weight: .semibold)).lineLimit(1)
                    .help(node.title).allowsHitTesting(false)
                Spacer(minLength: 0)
                if let status = controller.presentationStatus(for: node.id) {
                    WorkflowStatusBadge(status: status.status, stale: status.stale, scale: scale)
                        .allowsHitTesting(false)
                }
                if !collapsed {
                    if isContainer {
                        WorkflowAssetContainerView(controller: controller, node: node, scale: scale, presentation: containerPresentation, headerActions: actions)
                    } else {
                        WorkbenchMenu { actions } label: {
                            Text(consistencyText(languageStore, "tabs.properties")).font(.system(size: 11 * scale)).padding(4 * scale)
                        }.buttonStyle(.plain).workflowNodeControl(node.id)
                            .accessibilityIdentifier("workflow-node-menu-" + node.id.uuidString)
                    }
                }
            }.padding(.horizontal, 12 * scale).frame(height: WorkflowNodePortLayout.titleHeight * scale)
            if !collapsed {
                if definition?.modelKind != nil {
                    ModelSpecificationFields(descriptor: modelDescriptor, font: .system(size: 11 * scale))
                        .padding(.horizontal, 12 * scale).padding(.vertical, 4 * scale)
                        .allowsHitTesting(false)
                } else {
                    Text(identitySummary).font(.system(size: 11 * scale, weight: .medium))
                        .lineLimit(1).help(identitySummary).allowsHitTesting(false)
                        .padding(.horizontal, 12 * scale)
                        .frame(height: 22 * scale, alignment: .leading)
                        .modifier(WorkflowContainerControlRegion(nodeID: isContainer ? node.id : nil))
                }
            }
            if let definition {
                if isContainer { portGrid(definition).workflowNodeControl(node.id) } else { portGrid(definition) }
            }
            if isContainer && collapsed {
                Text(containerCollapsedSummary).font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                    .lineLimit(2).padding(.horizontal, 12 * scale).frame(height: 28 * scale).workflowNodeControl(node.id)
            }
            if isContainer && !collapsed {
                container
            }
            if !collapsed {
                VStack(alignment: .leading, spacing: 5 * scale) {
                    if runTarget {
                        Label(workflowText(languageStore, "semantics.nextRunTarget"), systemImage: "flag.fill")
                            .font(.system(size: 10 * scale)).foregroundStyle(.tint).allowsHitTesting(false)
                    }
                    WorkflowNodeActivityView(state: controller.services.activity, nodeID: node.id, graphID: graph.id, scale: scale)
                    WorkflowModelPreparationView(identity: modelIdentity, scale: scale,
                        fallbackReady: modelReadiness[modelIdentity] == .available,
                        onPrepare: !collapsed && downloadEntry != nil && prepareNode != nil ? {
                            guard scope.isCurrent(in: controller) else { return }; prepareNode?(node.id)
                        } : nil, permitsPreparation: !readOnly && controller.canEditCanvas, nodeID: node.id)

                    if definition == nil {
                        Label(workflowText(languageStore, "workflow.node.unknownOperation"), systemImage: "questionmark.diamond")
                            .font(.system(size: 11 * scale)).foregroundStyle(.orange).allowsHitTesting(false)
                    }
                }.padding(.horizontal, 12 * scale).padding(.bottom, 8 * scale)
            }
        }
        .font(.system(size: 11 * scale))
        .frame(width: cardWidth * scale, alignment: .leading)
        // Reserve the entire edge-port hit region inside the hosting bounds.
        // Only the plate paints; this transparent margin is not another panel.
        .padding(.horizontal, 11 * scale)
        .background {
            WorkflowNodePlateReceiver(scale: scale)
                .modifier(WorkflowHandPointerStyle(presentation: pointerPresentation, tool: tool))
                .workbenchPanel(cornerRadius: 13 * scale)
                .frame(width: cardWidth * scale)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13 * scale, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.10 : 0))
                .frame(width: cardWidth * scale)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if let resizePreview {
                RoundedRectangle(cornerRadius: 13 * scale).fill(Color.primary.opacity(0.08))
                    .frame(width: resizePreview.width * scale, height: resizePreview.height * scale)
                    .padding(.leading, 11 * scale).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isContainer && !collapsed && !readOnly {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10 * scale))
                    .frame(width: 20 * scale, height: 20 * scale).contentShape(Rectangle()).padding(.trailing, 12 * scale)
                    .workflowNodeControl(node.id).accessibilityLabel(workflowText(languageStore, "container.resize"))
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        if resizeTarget == nil { resizeTarget = controller.canvasInsertionTarget() }
                        resizePreview = CGSize(width: min(1200, max(300, WorkflowCanvasLayoutPolicy.width(node.id, in: graph) + value.translation.width / scale)),
                            height: min(1000, max(280, WorkflowCanvasLayoutPolicy.containerHeight(node.id, in: graph) + value.translation.height / scale)))
                    }.onEnded { _ in
                        if let resizeTarget, let resizePreview { controller.resizeContainer(id: node.id, width: resizePreview.width, height: resizePreview.height, target: resizeTarget) }
                        resizePreview = nil; resizeTarget = nil
                    })
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 13 * scale, style: .continuous))
        .dropDestination(for: WorkflowCanvasTransfer.self) { (items: [WorkflowCanvasTransfer], _: CGPoint) -> Bool in
            acceptAsset(items)
        }
        .workbenchContextMenu { actions }
        .environment(\.workbenchMenuContext, "node:\(scope.projectID):\(scope.instanceID):\(scope.rootGraphID):\(scope.rootRevision):\(scope.bodyPath):\(scope.graphID):\(node.id)")
        .workbenchSurface(.node, group: "node:\(node.id)")
        .accessibilityActions {
            ForEach(actions.accessibleLeaves, id: \.id) { item in
                Button(item.title) { if item.enabled && item.isCurrent() { item.action?() } }.disabled(!item.enabled)
            }
        }
        .accessibilityIdentifier("workflow-node-\(node.id.uuidString)")
    }

    @WorkbenchMenuBuilder private var nodeActions: WorkbenchMenuRows {
        #if DEBUG
        let _ = WorkflowCanvasUpdateProbe.nodeMenuBuild?(node.id)
        #endif
        WorkbenchMenuAction(consistencyText(languageStore, "menu.node.properties"), id: "node.properties") {
            if scope.isCurrent(in: controller) { onInspect(node.id) }
        }.featureHelp("MENU-NODE-PROPERTIES", language: languageStore)
        WorkbenchMenuAction(consistencyText(languageStore, "menu.node.results"), id: "node.results") {
            if scope.isCurrent(in: controller) { onViewResults?(node.id) }
        }.featureHelp("MENU-NODE-RESULTS", language: languageStore).disabled(onViewResults == nil)
        if let definition, !isContainer {
            WorkbenchSubmenu(workflowText(languageStore, "container.addPreview"), id: "node.previewContainer") {
                WorkbenchMenuForEach(definition.outputs, id: \.id) { port in
                    WorkbenchMenuAction(WorkflowCanvasPresentation.portTitle(operationID: node.operationID, port: port, input: false, language: languageStore)) {
                        guard scope.isCurrent(in: controller), let target = controller.canvasInsertionTarget() else { return }
                        do { try controller.addPreviewContainer(after: node.id, port: port.id, target: target) }
                        catch { controller.errorMessage = error.localizedDescription }
                    }.disabled(readOnly || port.kinds.count != 1 || port.kinds == [.receipt])
                }
            }
        }
        WorkbenchMenuDivider()
        WorkbenchSubmenu(consistencyText(languageStore, "menu.node.scope"), id: "node.scope") {
            WorkbenchMenuAction(consistencyText(languageStore, "menu.node.through"), id: "node.through") { if scope.isCurrent(in: controller) { onPlan(node.id, false) } }.featureHelp("MENU-NODE-THROUGH", language: languageStore).disabled(readOnly || definition == nil)
            WorkbenchMenuAction(consistencyText(languageStore, "menu.node.only"), id: "node.only") { if scope.isCurrent(in: controller) { onPlan(node.id, true) } }.featureHelp("MENU-NODE-ONLY", language: languageStore).disabled(readOnly || definition == nil)
            WorkbenchMenuAction(consistencyText(languageStore, "menu.node.from"), id: "node.from") { if scope.isCurrent(in: controller) { onPlanRange?(node.id, 2) } }.featureHelp("MENU-NODE-FROM", language: languageStore).disabled(readOnly || definition == nil || onPlanRange == nil || !controller.bodyPath.isEmpty)
            WorkbenchMenuAction(consistencyText(languageStore, "menu.node.after"), id: "node.after") { if scope.isCurrent(in: controller) { onPlanRange?(node.id, 3) } }.featureHelp("MENU-NODE-AFTER", language: languageStore).disabled(readOnly || definition == nil || onPlanRange == nil || !controller.bodyPath.isEmpty)
        }.featureHelp("MENU-NODE-SCOPE", language: languageStore)
        WorkbenchMenuAction(workflowText(languageStore, "workflow.run.setTarget"), id: "node.target") {
            if scope.isCurrent(in: controller) { onSetRunTarget(node.id) }
        }.disabled(readOnly || definition == nil)
        WorkbenchMenuAction(workflowText(languageStore, controller.selectedNodeIDs.contains(node.id) ? "workflow.selection.remove" : "workflow.language.selection", fallback: controller.selectedNodeIDs.contains(node.id) ? "移出当前选择" : "加入当前选择"), id: "node.select") {
            guard scope.isCurrent(in: controller) else { return }
            if controller.selectedNodeIDs.contains(node.id) { controller.selectedNodeIDs.remove(node.id) }
            else { controller.selectedNodeIDs.insert(node.id) }
            controller.selectedNodeID = controller.selectedNodeIDs.count == 1 ? controller.selectedNodeIDs.first : nil
        }
        WorkbenchMenuDivider()
        WorkbenchMenuAction(consistencyText(languageStore, "menu.node.delete"), role: .destructive, id: "node.delete") {
            guard scope.isCurrent(in: controller), let target = controller.canvasInsertionTarget() else { return }
            controller.deleteNode(id: node.id, target: target)
        }.featureHelp("MENU-NODE-DELETE", language: languageStore).disabled(readOnly || !controller.canEditCanvas)
    }

    private var modelDescriptor: ModelNodeDescriptor? {
        guard let definition, definition.modelKind != nil else { return nil }
        let choice = controller.modelChoices.first { $0.id == modelIdentity && $0.kind == definition.modelKind }
            ?? WorkflowModelRoutes.draftChoice(operationID: node.operationID, modelID: modelIdentity)
        return choice.flatMap(SharedLibraryProjection.descriptor(for:))
    }

    private var containerCollapsedSummary: String {
        let step = controller.latestStep(for: node.id)
        let value = step?.inputs["input"] ?? step?.outputs["output"]
        let count: Int
        switch value {
        case .collection(let items): count = items.count
        case .data(.list(_, let items)): count = items.count
        case .some: count = 1
        case .none: count = node.librarySources?.count ?? (node.assetReference == nil ? node.dataConfiguration?.items.count ?? 0 : 1)
        }
        let mode = workflowText(languageStore, node.operationID == WorkflowAssetContainer.filterID ? "container.manual" : "container.preview")
        let selected = step?.decision?.selectedItemIDs?.count ?? step?.containerSelectionDraft?.count ?? 0
        return mode + " · \(count) · " + workflowText(languageStore, "container.selected") + " \(selected)"
    }
    private var identitySummary: String {
        return WorkflowNodeIdentity.resolve(node: node, definition: definition,
            modelChoices: controller.modelChoices, assets: controller.availableAssets,
            tools: controller.tools, language: languageStore).detail ?? ""
    }

    private func portGrid(_ definition: WorkflowOperationDefinition) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<max(definition.inputs.count, definition.outputs.count), id: \.self) { index in
                HStack(spacing: 12 * scale) {
                    portCell(index < definition.inputs.count ? definition.inputs[index] : nil, input: true)
                    portCell(index < definition.outputs.count ? definition.outputs[index] : nil, input: false)
                }.frame(height: WorkflowNodePortLayout.rowHeight(collapsed: collapsed) * scale)
            }
        }.padding(.top, collapsed ? 0 : 2 * scale).padding(.bottom, 8 * scale)
    }

    private func portCell(_ port: WorkflowPortDefinition?, input: Bool) -> some View {
        ZStack(alignment: input ? .leading : .trailing) {
            Color.clear
            if let port {
                if !collapsed {
                    Text(WorkflowCanvasPresentation.portTitle(operationID: node.operationID,
                        port: port, input: input, language: languageStore))
                        .font(.system(size: 11 * scale, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: input ? .leading : .trailing)
                        .padding(input ? .leading : .trailing, 13 * scale)
                        .help(WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                        .allowsHitTesting(false)
                }
                portButton(port, input: input).offset(x: (input ? -11 : 11) * scale)
            }
        }.frame(maxWidth: .infinity)
    }

    private func portButton(_ port: WorkflowPortDefinition, input: Bool) -> some View {
        let identity = WorkflowPortIdentity(nodeID: node.id, port: port.id, input: input)
        return Button { onSelectPort(identity) } label: {
            Circle().fill(WorkflowPortStyle.color(for: port)).frame(width: 9 * scale, height: 9 * scale)
                .anchorPreference(key: WorkflowPortAnchorPreferenceKey.self, value: .center) { [identity: $0] }
                .frame(width: 22 * scale, height: WorkflowNodePortLayout.hitHeight(collapsed: collapsed) * scale).contentShape(Ellipse())
        }
        .buttonStyle(.plain)
        .disabled(readOnly || tool == .hand || !controller.canEditCanvas)
        .help(WorkflowCanvasPresentation.portTitle(operationID: node.operationID,
            port: port, input: input, language: languageStore) + " — "
            + WorkflowCanvasPresentation.portDetail(port, language: languageStore))
        .accessibilityLabel(workflowText(languageStore, "workflow.port.accessibility", arguments: [
                "direction": input ? workflowText(languageStore, "workflow.port.input")
                    : workflowText(languageStore, "workflow.port.output"),
                "title": WorkflowCanvasPresentation.portTitle(operationID: node.operationID,
                    port: port, input: input, language: languageStore),
                "detail": WorkflowCanvasPresentation.portSummary(port, language: languageStore)]))
        .overlay {
            WorkflowPortDragReceiver(port: identity, scope: scope,
                enabled: !readOnly && tool == .pointer && controller.canEditCanvas,
                visibleAt: { portVisible(identity, $0) },
                onClick: { onSelectPort(identity) },
                onChange: { onPortDrag(identity, $0) }, onEnd: onPortDragEnd)
        }
    }

    private func acceptAsset(_ items: [WorkflowCanvasTransfer]) -> Bool {
        if items.count == 1, items[0].libraryPayload != nil {
            controller.errorMessage = workflowText(languageStore, "container.dropTarget")
            return true
        }
        guard items.count == 1, !readOnly, controller.canEditCanvas,
              controller.readOnlyReason == nil,
              definition?.interaction == .assetInput,
              scope.isCurrent(in: controller),
              let item = try? items[0].validated(),
              let identity = WorkflowCanvasAssetIdentity.payload(item) else { return false }
        return onBindAsset(identity.project, identity.instance, identity.asset, node.id)
    }
}

struct WorkflowGraphGeometry {
    let graph: WorkflowGraph
    let translation: CGSize
    let size: CGSize
    private let previewPositions: [UUID: CGPoint]
    private let rawMaximum: CGPoint
    let estimatedHeights: [UUID: CGFloat]

    init(
        graph: WorkflowGraph,
        tools: [WorkflowToolDefinition] = [],
        registry: WorkflowRegistry = .standard,
        previewPositions: [UUID: CGPoint] = [:],
        translation requestedTranslation: CGSize? = nil,
        minimumSize: CGSize = .zero
    ) {
        self.graph = graph
        self.previewPositions = previewPositions
        let raw = graph.nodes.enumerated().map { index, node in
            previewPositions[node.id] ?? Self.rawPosition(node.id, index: index, graph: graph)
        }
        let minimumX = zip(raw, graph.nodes).map { $0.x - WorkflowCanvasLayoutPolicy.width($1.id, in: graph) / 2 }.min() ?? 0
        let heights = graph.nodes.map { node -> CGFloat in
            let definition = registry.definition(for: node, tools: tools)
            if graph.layout.first(where: { $0.nodeID == node.id })?.collapsed == true {
                return WorkflowNodePortLayout.portBottom(inputs: definition?.inputs.count ?? 0, outputs: definition?.outputs.count ?? 0, collapsed: true)
                    + (WorkflowAssetContainer.isContainer(node.operationID) ? 28 : 0)
            }
            if WorkflowAssetContainer.isContainer(node.operationID) { return WorkflowCanvasLayoutPolicy.containerHeight(node.id, in: graph) }
            return CGFloat(WorkflowLayout.cardHeightBudget(inputs: definition?.inputs.count ?? 1,
                outputs: definition?.outputs.count ?? 1))
        }
        estimatedHeights = Dictionary(uniqueKeysWithValues: zip(graph.nodes.map(\.id), heights))
        let minimumY = raw.map { $0.y - WorkflowNodePortLayout.titleHeight / 2 }.min() ?? 0
        let naturalTranslation = CGSize(width: max(0, 30 - minimumX), height: max(0, 24 - minimumY))
        translation = requestedTranslation ?? naturalTranslation
        let maximumX = zip(raw, graph.nodes).map { $0.x + WorkflowCanvasLayoutPolicy.width($1.id, in: graph) / 2 - 120 }.max() ?? 0
        let maximumY = zip(raw, heights).map { $0.0.y - WorkflowNodePortLayout.titleHeight / 2 + $0.1 }.max() ?? 0
        rawMaximum = CGPoint(x: maximumX, y: maximumY)
        size = CGSize(width: max(minimumSize.width, max(1_400, maximumX + translation.width + 320)),
                      height: max(minimumSize.height, max(900, maximumY + translation.height + 24)))
    }

    /// Reuse this immutable graph projection when only the retained camera
    /// envelope changes. Keep raw extrema: the minimum canvas size is not an extent.
    func reframed(translation: CGSize, minimumSize: CGSize = .zero) -> Self {
        Self(reframing: self, translation: translation, minimumSize: minimumSize)
    }

    private init(reframing source: Self, translation: CGSize, minimumSize: CGSize) {
        graph = source.graph; previewPositions = source.previewPositions
        estimatedHeights = source.estimatedHeights
        rawMaximum = source.rawMaximum; self.translation = translation
        size = CGSize(width: max(minimumSize.width, max(1_400, rawMaximum.x + translation.width + 320)),
                      height: max(minimumSize.height, max(900, rawMaximum.y + translation.height + 24)))
    }

    func rawPosition(_ nodeID: UUID) -> CGPoint {
        if let preview = previewPositions[nodeID] { return preview }
        let index = graph.nodes.firstIndex { $0.id == nodeID } ?? 0
        return Self.rawPosition(nodeID, index: index, graph: graph)
    }

    func displayPosition(_ nodeID: UUID) -> CGPoint {
        let point = rawPosition(nodeID)
        return CGPoint(x: point.x + translation.width, y: point.y + translation.height)
    }

    func rawPoint(forDisplayPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - translation.width, y: point.y - translation.height)
    }

    private static func rawPosition(_ nodeID: UUID, index: Int, graph: WorkflowGraph) -> CGPoint {
        if let layout = graph.layout.first(where: { $0.nodeID == nodeID }) {
            return CGPoint(x: CGFloat(layout.x), y: CGFloat(layout.y))
        }
        return WorkflowCanvasLayoutPolicy.fallbackPosition(index: index)
    }
}

struct WorkflowCanvasScrollObservation: Equatable {
    let contentOffset: CGPoint
    let containerSize: CGSize
    let zoom: CGFloat
    var isGestureEnd = false
    let visibleRawCenter: CGPoint
}

struct WorkflowCanvasScope: Equatable {
    let rootGraphID: UUID
    let rootRevision: UUID
    let graphID: UUID
    let bodyPath: [WorkflowBodyLocation]
    var projectID: UUID? = nil
    var instanceID: UUID? = nil

    var identity: WorkflowCanvasScopeIdentity {
        WorkflowCanvasScopeIdentity(rootGraphID: rootGraphID, graphID: graphID, bodyPath: bodyPath,
                                    projectID: projectID, instanceID: instanceID)
    }

    @MainActor
    func isCurrent(in controller: WorkflowController) -> Bool {
        guard projectID == controller.projectID, instanceID == controller.projectInstanceID,
              let currentRoot = controller.rootGraph,
              let currentGraph = controller.graph else { return false }
        return matches(
            rootGraphID: currentRoot.id,
            rootRevision: currentRoot.revision,
            graphID: currentGraph.id,
            bodyPath: controller.bodyPath
        )
    }

    func matches(
        rootGraphID: UUID,
        rootRevision: UUID,
        graphID: UUID,
        bodyPath: [WorkflowBodyLocation]
    ) -> Bool {
        self.rootGraphID == rootGraphID
            && self.rootRevision == rootRevision
            && self.graphID == graphID
            && self.bodyPath == bodyPath
    }
}

struct WorkflowCanvasScopeIdentity: Equatable {
    let rootGraphID: UUID
    let graphID: UUID
    let bodyPath: [WorkflowBodyLocation]
    var projectID: UUID? = nil
    var instanceID: UUID? = nil
}

/// Retain reachable raw space while this canvas is mounted. Shrinking a graph
/// must not clamp the native camera; a rebase also moves the old far boundary.
struct WorkflowCanvasRetainedExtent: Equatable {
    let identity: WorkflowCanvasScopeIdentity
    let translation: CGSize
    let size: CGSize
    func size(for identity: WorkflowCanvasScopeIdentity, translation next: CGSize) -> CGSize {
        guard identity == self.identity else { return .zero }
        return CGSize(width: max(0, size.width + next.width - translation.width),
                      height: max(0, size.height + next.height - translation.height))
    }
}

struct WorkflowCanvasStableOrigin: Equatable {
    let identity: WorkflowCanvasScopeIdentity
    let translation: CGSize
}

enum WorkflowCanvasOriginPolicy {
    static func resolved(
        natural: CGSize,
        retained: CGSize?,
        active: CGSize?
    ) -> CGSize {
        if let active { return active }
        guard let retained else { return natural }
        return CGSize(
            width: max(natural.width, retained.width),
            height: max(natural.height, retained.height)
        )
    }
}

struct WorkflowCanvasNodeDragState: Equatable {
    let sessionID: UUID
    let scope: WorkflowCanvasScope
    let nodeID: UUID
    let originalPosition: CGPoint
    let origin: CGSize
    let originalPositions: [UUID: CGPoint]
    let originalLayouts: [UUID: WorkflowLayout]
    let target: WorkflowCanvasInsertionTarget?
    private(set) var previewPosition: CGPoint

    var previewPositions: [UUID: CGPoint] {
        let dx = previewPosition.x - originalPosition.x
        let dy = previewPosition.y - originalPosition.y
        return originalPositions.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    init(
        sessionID: UUID,
        scope: WorkflowCanvasScope,
        nodeID: UUID,
        originalPosition: CGPoint,
        origin: CGSize,
        originalPositions: [UUID: CGPoint] = [:],
        originalLayouts: [UUID: WorkflowLayout] = [:],
        target: WorkflowCanvasInsertionTarget? = nil
    ) {
        self.sessionID = sessionID
        self.scope = scope
        self.nodeID = nodeID
        self.originalPosition = originalPosition
        self.origin = origin
        self.originalPositions = originalPositions.isEmpty ? [nodeID: originalPosition] : originalPositions
        self.originalLayouts = originalLayouts
        self.target = target
        previewPosition = originalPosition
    }

    mutating func update(screenTranslation: CGSize, zoom: CGFloat) {
        previewPosition = WorkflowCanvasDragGeometry.rawPosition(
            original: originalPosition,
            screenTranslation: screenTranslation,
            zoom: zoom
        )
    }

    func canCommit(
        currentScope: WorkflowCanvasScope?,
        graph: WorkflowGraph?,
        currentPosition: CGPoint?,
        readOnly: Bool,
        isRunning: Bool
    ) -> Bool {
        guard !readOnly, !isRunning,
              currentScope == scope,
              graph?.id == scope.graphID,
              graph?.nodes.contains(where: { $0.id == nodeID }) == true,
              currentPosition == originalPosition,
              previewPosition.x.isFinite, previewPosition.y.isFinite else { return false }
        return true
    }
}

enum WorkflowCanvasGestureSessionEvent: Equatable {
    case began(UUID)
    case changed(UUID)
}

struct WorkflowCanvasGestureSessionState: Equatable {
    private(set) var sessionID: UUID?

    mutating func change() -> WorkflowCanvasGestureSessionEvent {
        if let sessionID { return .changed(sessionID) }
        let sessionID = UUID()
        self.sessionID = sessionID
        return .began(sessionID)
    }

    mutating func end() -> UUID? {
        defer { sessionID = nil }
        return sessionID
    }

    mutating func cancel() -> UUID? {
        defer { sessionID = nil }
        return sessionID
    }
}

/// Session snapshots are not view dependencies. Only the moving wrappers and the
/// wire drawing consume offset; the surface observes the start/end node set.
@MainActor @Observable
final class WorkflowCanvasNodeDragPresentation {
    @ObservationIgnored private var coordinator = WorkflowCanvasNodeDragCoordinator()
    @ObservationIgnored private var gestureZoom: CGFloat = 1
    @ObservationIgnored var latestPortCenters: [WorkflowPortIdentity: CGPoint] = [:]
    @ObservationIgnored var latestControlBounds: [CGRect] = []
    @ObservationIgnored var latestOwnedControlBounds: [UUID: [CGRect]] = [:]
    private(set) var movingNodeIDs: Set<UUID> = []
    private(set) var offset = CGSize.zero
    var active: WorkflowCanvasNodeDragState? { coordinator.active }

    @discardableResult
    func begin(_ state: WorkflowCanvasNodeDragState, screenTranslation: CGSize, zoom: CGFloat) -> Bool {
        guard coordinator.begin(state, screenTranslation: screenTranslation, zoom: zoom) else { return false }
        gestureZoom = zoom
        movingNodeIDs = Set(state.originalPositions.keys)
        publishOffset()
        return true
    }

    @discardableResult
    func update(sessionID: UUID, nodeID: UUID, scope: WorkflowCanvasScope,
                screenTranslation: CGSize, zoom: CGFloat) -> Bool {
        guard coordinator.update(sessionID: sessionID, nodeID: nodeID, scope: scope,
            screenTranslation: screenTranslation, zoom: gestureZoom) else { return false }
        publishOffset()
        return true
    }

    func finish(sessionID: UUID, nodeID: UUID, scope: WorkflowCanvasScope,
                screenTranslation: CGSize, zoom: CGFloat) -> WorkflowCanvasNodeDragState? {
        guard let result = coordinator.finish(sessionID: sessionID, nodeID: nodeID, scope: scope,
            screenTranslation: screenTranslation, zoom: gestureZoom) else { return nil }
        clearPresentation()
        return result
    }

    func cancel(sessionID: UUID) {
        coordinator.cancel(sessionID: sessionID)
        if active == nil { clearPresentation() }
    }

    func invalidate() {
        coordinator.invalidate()
        clearPresentation()
    }

    private func publishOffset() {
        guard let active else { return }
        let next = CGSize(width: active.previewPosition.x - active.originalPosition.x,
                          height: active.previewPosition.y - active.originalPosition.y)
        if offset != next { offset = next }
    }

    private func clearPresentation() {
        movingNodeIDs = []
        offset = .zero
    }
}

// Observe cursor feedback at the leaf, not while constructing graph/card content.
private struct WorkflowHandPointerStyle: ViewModifier {
    let presentation: WorkflowCanvasPointerPresentation
    let tool: WorkflowCanvasTool

    func body(content: Content) -> some View {
        let pressed = tool == .hand && presentation.pressed
        #if DEBUG
        let _ = WorkflowCanvasUpdateProbe.handPointerStyle?(tool, pressed)
        #endif
        content.pointerStyle(tool == .hand ? (pressed ? .grabActive : .grabIdle) : nil)
    }
}

private struct WorkflowNodeDragOffset: ViewModifier {
    let presentation: WorkflowCanvasNodeDragPresentation
    let moving: Bool
    var scale: CGFloat = 1
    func body(content: Content) -> some View {
        content.offset(moving ? CGSize(width: presentation.offset.width * scale, height: presentation.offset.height * scale) : .zero)
    }
}

struct WorkflowCanvasNodeDragCoordinator: Equatable {
    private(set) var active: WorkflowCanvasNodeDragState?

    @discardableResult
    mutating func begin(
        _ state: WorkflowCanvasNodeDragState,
        screenTranslation: CGSize,
        zoom: CGFloat
    ) -> Bool {
        guard active == nil else { return false }
        var state = state
        state.update(screenTranslation: screenTranslation, zoom: zoom)
        active = state
        return true
    }

    @discardableResult
    mutating func update(
        sessionID: UUID,
        nodeID: UUID,
        scope: WorkflowCanvasScope,
        screenTranslation: CGSize,
        zoom: CGFloat
    ) -> Bool {
        guard var state = active,
              state.sessionID == sessionID,
              state.nodeID == nodeID,
              state.scope == scope else { return false }
        state.update(screenTranslation: screenTranslation, zoom: zoom)
        active = state
        return true
    }

    mutating func finish(
        sessionID: UUID,
        nodeID: UUID,
        scope: WorkflowCanvasScope,
        screenTranslation: CGSize,
        zoom: CGFloat
    ) -> WorkflowCanvasNodeDragState? {
        guard update(
            sessionID: sessionID,
            nodeID: nodeID,
            scope: scope,
            screenTranslation: screenTranslation,
            zoom: zoom
        ) else { return nil }
        defer { active = nil }
        return active
    }

    mutating func cancel(sessionID: UUID) {
        if active?.sessionID == sessionID { active = nil }
    }

    mutating func invalidate() {
        active = nil
    }
}

enum WorkflowCanvasDragGeometry {
    static func rawPosition(original: CGPoint, screenTranslation: CGSize, zoom: CGFloat) -> CGPoint {
        guard zoom.isFinite, zoom > 0 else { return original }
        let position = CGPoint(
            x: original.x + screenTranslation.width / zoom,
            y: original.y + screenTranslation.height / zoom
        )
        guard position.x.isFinite, position.y.isFinite else { return original }
        return position
    }
}

struct WorkflowPortIdentity: Hashable {
    let nodeID: UUID
    let port: String
    let input: Bool
}

private struct WorkflowNodeControlAnchor { let nodeID: UUID?; let anchor: Anchor<CGRect> }
private struct WorkflowNodeControlPreferenceKey: PreferenceKey {
    static let defaultValue: [WorkflowNodeControlAnchor] = []
    static func reduce(value: inout [WorkflowNodeControlAnchor], nextValue: () -> [WorkflowNodeControlAnchor]) {
        value += nextValue()
    }
}

extension View {
    func workflowNodeControl(_ nodeID: UUID? = nil) -> some View {
        anchorPreference(key: WorkflowNodeControlPreferenceKey.self, value: .bounds) { [.init(nodeID: nodeID, anchor: $0)] }
    }
}

struct WorkflowPortAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [WorkflowPortIdentity: Anchor<CGPoint>] = [:]

    static func reduce(
        value: inout [WorkflowPortIdentity: Anchor<CGPoint>],
        nextValue: () -> [WorkflowPortIdentity: Anchor<CGPoint>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

enum WorkflowConnectionGeometry {
    static func nodePlate(_ rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 13, style: .continuous).path(in: rect)
    }
    static func nodeFrames(geometry: WorkflowGraphGeometry, sizes: [UUID: CGSize],
                           moving: Set<UUID> = [], offset: CGSize = .zero) -> [UUID: CGRect] {
        Dictionary(uniqueKeysWithValues: geometry.graph.nodes.map { node in
            let center = geometry.displayPosition(node.id)
            let size = sizes[node.id] ?? CGSize(width: WorkflowCanvasLayoutPolicy.width(node.id, in: geometry.graph), height: geometry.estimatedHeights[node.id] ?? 180)
            return (node.id, CGRect(x: center.x - size.width / 2 + (moving.contains(node.id) ? offset.width : 0),
                y: center.y - WorkflowNodePortLayout.titleHeight / 2 + (moving.contains(node.id) ? offset.height : 0),
                width: size.width, height: size.height))
        })
    }
    static func edgePoint(_ point: CGPoint, input: Bool, frame: CGRect?) -> CGPoint {
        guard let frame else { return point }
        return CGPoint(x: input ? frame.minX : frame.maxX, y: point.y)
    }

    static func drawingBounds(size: CGSize, paths: [Path]) -> CGRect {
        paths.reduce(CGRect(origin: .zero, size: size)) { bounds, path in
            bounds.union(path.boundingRect.insetBy(dx: -3, dy: -3))
        }
    }

    static func canShowCut(at point: CGPoint, portCenters: [CGPoint], controls: [CGRect]) -> Bool {
        // A crowded midpoint must not cover another affordance. Its wire still has a menu.
        !portCenters.contains { hypot(point.x - $0.x, point.y - $0.y) <= 23 }
            && !controls.contains { $0.insetBy(dx: -11, dy: -11).contains(point) }
    }

    static func hitPath(
        for connection: WorkflowConnection,
        geometry: WorkflowGraphGeometry,
        portCenters: [WorkflowPortIdentity: CGPoint],
        excluding controls: [CGRect] = [],
        nodeFrames: [UUID: CGRect] = [:]
    ) -> Path {
        let ends = endpoints(for: connection, geometry: geometry, portCenters: portCenters, nodeFrames: nodeFrames)
        // Exclude the actual dot hit circles, rather than an arbitrary fraction
        // that either hides a short wire or steals a long wire's endpoint.
        var hit = path(for: connection, geometry: geometry, portCenters: portCenters, nodeFrames: nodeFrames)
            .strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round))
        let bounds = hit.boundingRect
        for point in Array(portCenters.values) + (nodeFrames.isEmpty ? [ends.start, ends.end] : []) {
            let circle = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
            if bounds.intersects(circle) { hit = hit.subtracting(Path(ellipseIn: circle)) }
        }
        for rect in controls where bounds.intersects(rect) { hit = hit.subtracting(Path(rect)) }
        for rect in nodeFrames.values where bounds.intersects(rect) { hit = hit.subtracting(nodePlate(rect)) }
        return hit
    }

    /// Real anchors already include the card transform. Only collapsed/missing
    /// anchors need an explicit offset, otherwise connected dots move twice.
    static func movingFallbackCenters(graph: WorkflowGraph, geometry: WorkflowGraphGeometry,
                                      measured: [WorkflowPortIdentity: CGPoint],
                                      moving: Set<UUID>, offset: CGSize) -> [WorkflowPortIdentity: CGPoint] {
        guard !moving.isEmpty else { return measured }
        var centers = measured
        for connection in graph.connections {
            let ends = endpoints(for: connection, geometry: geometry, portCenters: measured)
            let source = WorkflowPortIdentity(nodeID: connection.sourceNode, port: connection.sourcePort, input: false)
            let target = WorkflowPortIdentity(nodeID: connection.targetNode, port: connection.targetPort, input: true)
            if centers[source] == nil, moving.contains(source.nodeID) {
                centers[source] = CGPoint(x: ends.start.x + offset.width, y: ends.start.y + offset.height)
            }
            if centers[target] == nil, moving.contains(target.nodeID) {
                centers[target] = CGPoint(x: ends.end.x + offset.width, y: ends.end.y + offset.height)
            }
        }
        return centers
    }

    static func endpoints(
        for connection: WorkflowConnection,
        geometry: WorkflowGraphGeometry,
        portCenters: [WorkflowPortIdentity: CGPoint],
        nodeFrames: [UUID: CGRect] = [:]
    ) -> (start: CGPoint, end: CGPoint) {
        let source = WorkflowPortIdentity(
            nodeID: connection.sourceNode, port: connection.sourcePort, input: false
        )
        let target = WorkflowPortIdentity(
            nodeID: connection.targetNode, port: connection.targetPort, input: true
        )
        let sourceCenter = geometry.displayPosition(connection.sourceNode)
        let targetCenter = geometry.displayPosition(connection.targetNode)
        return (
            portCenters[source] ?? CGPoint(x: nodeFrames[connection.sourceNode]?.maxX ?? sourceCenter.x + WorkflowCanvasLayoutPolicy.width(connection.sourceNode, in: geometry.graph) / 2, y: sourceCenter.y),
            portCenters[target] ?? CGPoint(x: nodeFrames[connection.targetNode]?.minX ?? targetCenter.x - WorkflowCanvasLayoutPolicy.width(connection.targetNode, in: geometry.graph) / 2, y: targetCenter.y)
        )
    }

    static func path(
        for connection: WorkflowConnection,
        geometry: WorkflowGraphGeometry,
        portCenters: [WorkflowPortIdentity: CGPoint],
        nodeFrames: [UUID: CGRect] = [:]
    ) -> Path {
        let points = endpoints(for: connection, geometry: geometry, portCenters: portCenters, nodeFrames: nodeFrames)
        return curve(from: points.start, to: points.end)
    }

    static func curve(from start: CGPoint, to end: CGPoint) -> Path {
        let horizontal = max(50, abs(end.x - start.x) * 0.45)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + horizontal, y: start.y),
            control2: CGPoint(x: end.x - horizontal, y: end.y)
        )
        return path
    }
}

enum WorkflowCanvasConnectionIssue: Equatable {
    case staleScope, sameNode, unknownPort, incompatibleKind, occupiedInput, duplicate, cycle

    @MainActor
    func message(language: UILanguageStore?) -> String {
        switch self {
        case .staleScope: workflowText(language, "canvas.connection.staleScope", fallback: "画布已变化，请重新拖动连接。")
        case .sameNode: workflowText(language, "canvas.connection.sameNode", fallback: "不能将节点连到自身。")
        case .unknownPort: workflowText(language, "canvas.connection.unknownPort", fallback: "端口或节点已变化。")
        case .incompatibleKind: workflowText(language, "canvas.connection.incompatible", fallback: "端口数据类型不兼容。")
        case .occupiedInput: workflowText(language, "canvas.connection.occupied", fallback: "输入端口已有连接，请先断开。")
        case .duplicate: workflowText(language, "canvas.connection.duplicate", fallback: "这条连接已存在。")
        case .cycle: workflowText(language, "canvas.connection.cycle", fallback: "该连接会形成无效循环。")
        }
    }
}

enum WorkflowCanvasConnectionPolicy {
    static func directedPorts(_ start: WorkflowPortIdentity, _ end: WorkflowPortIdentity)
        -> (output: WorkflowPortIdentity, input: WorkflowPortIdentity)? {
        guard start.input != end.input else { return nil }
        return start.input ? (end, start) : (start, end)
    }

    static func canConnect(
        graph: WorkflowGraph,
        registry: WorkflowRegistry,
        tools: [WorkflowToolDefinition],
        sourceNodeID: UUID,
        sourcePort: String,
        targetNodeID: UUID,
        targetPort: String
    ) -> Bool {
        issue(graph: graph, registry: registry, tools: tools,
              sourceNodeID: sourceNodeID, sourcePort: sourcePort,
              targetNodeID: targetNodeID, targetPort: targetPort) == nil
    }

    static func issue(
        graph: WorkflowGraph,
        registry: WorkflowRegistry,
        tools: [WorkflowToolDefinition],
        sourceNodeID: UUID,
        sourcePort: String,
        targetNodeID: UUID,
        targetPort: String
    ) -> WorkflowCanvasConnectionIssue? {
        if sourceNodeID == targetNodeID { return .sameNode }
        guard let sourceNode = graph.nodes.first(where: { $0.id == sourceNodeID }),
              let targetNode = graph.nodes.first(where: { $0.id == targetNodeID }),
              let source = registry.definition(for: sourceNode, tools: tools)?.outputs.first(where: {
                  $0.id == sourcePort
              }),
              let target = registry.definition(for: targetNode, tools: tools)?.inputs.first(where: {
                  $0.id == targetPort
              }) else { return .unknownPort }
        if Set(source.kinds).isDisjoint(with: target.kinds) { return .incompatibleKind }
        if graph.connections.contains(where: {
            $0.sourceNode == sourceNodeID && $0.sourcePort == sourcePort
                && $0.targetNode == targetNodeID && $0.targetPort == targetPort
        }) { return .duplicate }
        if graph.connections.contains(where: {
            $0.targetNode == targetNodeID && $0.targetPort == targetPort
        }) { return .occupiedInput }
        if wouldCreateCycle(graph: graph, source: sourceNodeID, target: targetNodeID) { return .cycle }
        return nil
    }

    private static func wouldCreateCycle(
        graph: WorkflowGraph,
        source: UUID,
        target: UUID
    ) -> Bool {
        var pending = [target]
        var visited = Set<UUID>()
        while let node = pending.popLast() {
            if node == source { return true }
            guard visited.insert(node).inserted else { continue }
            pending.append(contentsOf: graph.connections.lazy
                .filter { $0.sourceNode == node }
                .map(\.targetNode))
        }
        return false
    }
}

/// One entry per live wire receiver; discarded with that receiver. Geometry only:
/// exact endpoints and nearby excluded affordances, independent of graph semantics.
@MainActor final class WorkflowConnectionHitCache {
    private struct Key: Equatable {
        let start: CGPoint; let end: CGPoint; let ports: [CGPoint]; let controls: [CGRect]; let nodes: [CGRect]
    }
    private var key: Key?
    private var cached = Path()
    private(set) var builds = 0
    func path(for connection: WorkflowConnection, geometry: WorkflowGraphGeometry,
              portCenters: [WorkflowPortIdentity: CGPoint], excluding controls: [CGRect],
              nodeFrames: [UUID: CGRect] = [:]) -> Path {
        let ends = WorkflowConnectionGeometry.endpoints(for: connection, geometry: geometry, portCenters: portCenters, nodeFrames: nodeFrames)
        let curve = WorkflowConnectionGeometry.curve(from: ends.start, to: ends.end)
        let bounds = curve.boundingRect.insetBy(dx: -6, dy: -6)
        let ports = (Array(portCenters.values) + (nodeFrames.isEmpty ? [ends.start, ends.end] : [])).filter {
            bounds.intersects(CGRect(x: $0.x - 12, y: $0.y - 12, width: 24, height: 24))
        }.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        let nearby = controls.filter { bounds.intersects($0) }
        let nodes = nodeFrames.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value).filter { bounds.intersects($0) }
        let next = Key(start: ends.start, end: ends.end, ports: ports, controls: nearby, nodes: nodes)
        if next != key {
            #if DEBUG
            let start = CFAbsoluteTimeGetCurrent()
            #endif
            var hit = curve.strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round))
            for point in ports { hit = hit.subtracting(Path(ellipseIn:
                CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))) }
            for rect in nearby { hit = hit.subtracting(Path(rect)) }
            for rect in nodes { hit = hit.subtracting(WorkflowConnectionGeometry.nodePlate(rect)) }
            key = next; cached = hit; builds += 1
            #if DEBUG
            WorkflowCanvasUpdateProbe.wireHitBuild?(CFAbsoluteTimeGetCurrent() - start)
            #endif
        }
        return cached
    }
}

private struct WorkflowContainerControlRegion: ViewModifier {
    let nodeID: UUID?
    func body(content: Content) -> some View {
        if let nodeID { content.workflowNodeControl(nodeID) } else { content }
    }
}
