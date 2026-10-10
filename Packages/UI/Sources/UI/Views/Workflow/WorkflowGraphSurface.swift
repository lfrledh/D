import AppKit
import DWorkbench
import Foundation
import Observation
import SwiftUI

struct WorkflowGraphSurface: View {
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
    let onPlan: (UUID, Bool) -> Void
    var nodeSizeObserver: ((UUID, CGSize) -> Void)?
    var viewportSizeObserver: ((WorkflowCanvasViewportMeasurement) -> Void)?
    var portCenterObserver: (([WorkflowPortIdentity: CGPoint]) -> Void)?
    var onScrollObservation: (WorkflowCanvasViewContext, WorkflowCanvasScrollObservation) -> Void = { _, _ in }
    var onDropItem: (WorkflowCanvasTransfer, CGPoint) -> Bool = { _, _ in false }
    var onBindAsset: (UUID, UUID?, UUID, UUID) -> Bool = { _, _, _, _ in false }
    var onInspect: (UUID) -> Void = { _ in }
    @Environment(\.dLanguageStore) private var languageStore
    @GestureState private var gestureScale: CGFloat = 1
    @State private var nodeDrag = WorkflowCanvasNodeDragPresentation()
    @State private var stableOrigin: WorkflowCanvasStableOrigin?
    @State private var pendingConnectionScope: WorkflowCanvasScope?
    @State private var pendingDragPoint: CGPoint?
    @State private var measuredPortCenters: [WorkflowPortIdentity: CGPoint] = [:]
    @State private var connectionIssue: WorkflowCanvasConnectionIssue?
    @State private var scrollTracking = WorkflowCanvasScrollTracking()
    @State private var controlBounds: [CGRect] = []
    @State private var clipViewportSize: CGSize?
    @State private var resizeAnchorRaw: CGPoint?
    @State private var pendingZoomOffset: CGPoint?
    @State private var cardSizes: [UUID: CGSize] = [:]
    @State private var marquee: WorkflowCanvasMarquee?

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
                let geometry = WorkflowGraphGeometry(
                    graph: graph,
                    tools: controller.tools,
                    registry: controller.registry,
                    translation: origin
                )
                GeometryReader { viewport in
                let viewportSize = clipViewportSize ?? viewport.size
                let layout = WorkflowCanvasViewportGeometry(
                    graphSize: geometry.size, viewportSize: viewportSize,
                    zoom: effectiveZoom, translation: geometry.translation
                )
                let contentSize = layout.unscaledGraphSize
                let edge = layout.unscaledPadding
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        displayPreferences.resolvedAppearance.palette(for: colorScheme).canvasColor
                            .contentShape(Rectangle())
                            .help(workflowText(
                                languageStore,
                                "workflow.canvas.dropHint",
                                fallback: "将节点或项目素材拖到这里；拖动输出端口可建立连接。"
                            ))
                            .background(viewportInput(geometry: geometry, scope: scope))
                        ZStack(alignment: .topLeading) {
                        ForEach(graph.nodes) { node in
                            WorkflowNodeCard(
                                controller: controller,
                                graph: graph,
                                scope: scope,
                                node: node,
                                definition: controller.registry.definition(for: node, tools: controller.tools),
                                pendingConnection: $pendingConnection,
                                tool: tool,
                                pendingConnectionScope: pendingConnectionScope,
                                readOnly: readOnly,
                                selected: controller.selectedNodeID == node.id || controller.selectedNodeIDs.contains(node.id),
                                onPlan: onPlan,
                                onBindAsset: onBindAsset,
                                onInspect: onInspect,
                                onSelectPort: { port in selectPort(port, scope: scope) },
                                onPortDrag: { port, delta in
                                    guard canConnect(in: scope), let center = measuredPortCenters[port] else { return }
                                    pendingConnection = WorkflowPendingConnection(nodeID: port.nodeID, port: port.port, input: port.input)
                                    pendingConnectionScope = scope
                                    pendingDragPoint = CGPoint(x: center.x + delta.width, y: center.y + delta.height)
                                    viewportInteractionLocked = true
                                    connectionIssue = nil
                                },
                                onPortDragEnd: { target in finishConnection(to: target, scope: scope) }
                            )
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                cardSizes[node.id] = size
                                nodeSizeObserver?(node.id, size)
                            }
                            .position(geometry.displayPosition(node.id))
                            .modifier(WorkflowNodeDragOffset(presentation: nodeDrag,
                                moving: nodeDrag.movingNodeIDs.contains(node.id)))
                        }
                        if self.graph == nil {
                            ContentUnavailableView(
                                workflowText(languageStore, "workflow.canvas.empty", fallback: "选择或添加流程"),
                                systemImage: "point.3.connected.trianglepath.dotted",
                                description: Text(workflowText(languageStore,
                                    "workflow.canvas.emptyDescription",
                                    fallback: "流程只会在明确保存或运行时提交。"))
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .allowsHitTesting(false)
                        }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        // The wires are foreground strokes, including the segment inside a card.
                        // Only their narrow hit paths receive events; drawing has no hit surface.
                        .overlayPreferenceValue(WorkflowPortAnchorPreferenceKey.self) { anchors in
                        GeometryReader { proxy in
                            let centers = anchors.mapValues { proxy[$0] }
                            WorkflowConnectionLayer(
                                graph: graph,
                                registry: controller.registry,
                                tools: controller.tools,
                                geometry: geometry,
                                dragPresentation: nodeDrag,
                                portCenters: centers,
                                controlBounds: controlBounds,
                                selectedConnectionID: selectedConnectionID,
                                pendingConnection: pendingConnection,
                                pendingDragPoint: pendingDragPoint,
                                canDisconnect: !readOnly && controller.canEditCanvas,
                                onSelect: { connectionID in
                                    if scope.isCurrent(in: controller) { selectedConnectionID = connectionID }
                                },
                                onDisconnect: { connection in
                                    guard !readOnly, WorkflowCanvasConnectionEditing.disconnect(connection,
                                        scope: scope, controller: controller) else { return }
                                    if selectedConnectionID == connection.id { selectedConnectionID = nil }
                                }
                            )
                            .onAppear { updatePortCenters(centers) }
                            .onChange(of: centers) { _, updated in updatePortCenters(updated) }
                        }
                    }
                    .overlayPreferenceValue(WorkflowNodeControlPreferenceKey.self) { anchors in
                        GeometryReader { proxy in
                            let frames = anchors.map { proxy[$0] }
                            Color.clear.allowsHitTesting(false)
                                .onAppear { updateControlBounds(frames) }
                                .onChange(of: frames) { _, next in updateControlBounds(next) }
                        }.allowsHitTesting(false)
                    }
                    .offset(x: edge.width, y: edge.height)
                    if let marquee, marquee.scope == scope {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.13))
                            .overlay {
                                Rectangle().stroke(Color.accentColor,
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            }
                            .frame(width: marquee.rect.width, height: marquee.rect.height)
                            .position(x: marquee.rect.midX, y: marquee.rect.midY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    }
                    .frame(width: contentSize.width + edge.width * 2,
                           height: contentSize.height + edge.height * 2)
                    .coordinateSpace(name: WorkflowCanvasCoordinateSpace.name)
                    .contentShape(Rectangle())
                    .dropDestination(for: WorkflowCanvasTransfer.self, action: { items, location in
                        return acceptSurfaceDrop(items, at: geometry.rawPoint(forDisplayPoint: CGPoint(
                            x: location.x - edge.width, y: location.y - edge.height)), scope: scope)
                    })
                    .scaleEffect(effectiveZoom, anchor: .topLeading)
                    .frame(width: layout.contentSize.width,
                           height: layout.contentSize.height,
                           alignment: .topLeading)
                }
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
                .background(displayPreferences.resolvedAppearance.palette(for: displayPreferences.preferredColorScheme ?? colorScheme).canvasColor)
                .onAppear {
                    if let navigationRequest {
                        scrollPosition.scrollTo(point: layout.centeredOffset(
                            on: navigationRequest.rawCenter ?? layout.centerRawPoint))
                    } else {
                        scrollPosition.scrollTo(point: layout.centeredOffset(on: layout.centerRawPoint))
                    }
                }
                .onChange(of: navigationRequest) { _, request in
                    guard let request else { return }
                    Task { @MainActor in
                        guard navigationRequest == request else { return }
                        let current = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                            viewportSize: clipViewportSize ?? viewport.size,
                            zoom: zoom, translation: geometry.translation)
                        scrollPosition.scrollTo(point: current.centeredOffset(
                            on: request.rawCenter ?? current.centerRawPoint))
                    }
                }
                .onChange(of: clipViewportSize) { old, new in
                    guard let new, new.width > 0, new.height > 0 else { return }
                    let previous = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: old ?? viewport.size,
                        zoom: effectiveZoom, translation: geometry.translation)
                    let next = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: new, zoom: effectiveZoom, translation: geometry.translation)
                    let raw = resizeAnchorRaw ?? (old == nil
                        ? navigationRequest?.rawCenter ?? next.centerRawPoint
                        : previous.visibleRawCenter(offset: scrollTracking.offset))
                    resizeAnchorRaw = nil
                    scrollPosition.scrollTo(point: next.centeredOffset(on: raw))
                }
                .onChange(of: zoom) { old, new in
                    guard old != new, !viewportInteractionLocked else { return }
                    let previous = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: viewportSize, zoom: old, translation: geometry.translation)
                    let next = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: viewportSize, zoom: new, translation: geometry.translation)
                    let offset = pendingZoomOffset ?? next.centeredOffset(
                        on: previous.visibleRawCenter(offset: scrollTracking.offset))
                    pendingZoomOffset = nil
                    scrollPosition.scrollTo(point: offset)
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($gestureScale) { value, state, _ in state = value }
                        .onEnded { value in
                            if !viewportInteractionLocked {
                                zoom = WorkflowCanvasLayoutPolicy.clampedInteractiveZoom(zoom * value,
                                                                                         current: zoom)
                            }
                        }
                )
                .onChange(of: scope) { _, next in
                    marquee = nil
                    viewportInteractionLocked = false
                    if nodeDrag.active?.scope != next { nodeDrag.invalidate(); viewportInteractionLocked = false }
                    if stableOrigin?.identity != next.identity { stableOrigin = nil }
                    if pendingConnectionScope != next {
                        pendingConnection = nil
                        pendingConnectionScope = nil
                        pendingDragPoint = nil
                        connectionIssue = nil
                    }
                }
                .onChange(of: tool) { _, next in
                    marquee = nil
                    viewportInteractionLocked = false
                    if next == .hand {
                        pendingConnection = nil
                        pendingConnectionScope = nil
                        pendingDragPoint = nil
                        connectionIssue = nil
                    }
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
                .onChange(of: readOnly || controller.isRunning) { _, blocked in
                    if blocked {
                        nodeDrag.invalidate()
                        marquee = nil
                        clearConnection()
                    }
                }
                .onDisappear {
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
                            Button(workflowText(languageStore, "workflow.connection.cancel", fallback: "取消连接")) {
                                clearConnection()
                            }
                                .buttonStyle(.borderless)
                .workflowNodeControl()
                        }
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                    }
                    if let connectionIssue {
                        Text(connectionIssue.message(language: languageStore))
                            .font(.caption).foregroundStyle(.orange)
                            .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
        if let pendingConnection, pendingDragPoint != nil,
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
    }

    private func canConnect(in scope: WorkflowCanvasScope) -> Bool {
        tool == .pointer && !readOnly && !controller.isRunning
            && controller.readOnlyReason == nil && scope.isCurrent(in: controller)
    }

    private func clearConnection() {
        pendingConnection = nil; pendingConnectionScope = nil
        pendingDragPoint = nil; viewportInteractionLocked = false
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

    private var effectiveZoom: CGFloat {
        viewportInteractionLocked ? zoom : WorkflowCanvasLayoutPolicy.clampedInteractiveZoom(
            zoom * gestureScale, current: zoom)
    }

    private func viewportInput(geometry: WorkflowGraphGeometry, scope: WorkflowCanvasScope)
        -> WorkflowCanvasViewportInput {
        WorkflowCanvasViewportInput(
            tool: tool,
            interactionScope: scope,
            pointerTarget: { point, offset, size in
                let layout = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                    viewportSize: size, zoom: zoom, translation: geometry.translation)
                let raw = layout.rawPoint(screenPoint: point, offset: offset)
                let display = CGPoint(x: raw.x + geometry.translation.width,
                                      y: raw.y + geometry.translation.height)
                if controlBounds.contains(where: { $0.contains(display) }) { return .control }
                if tool == .pointer, measuredPortCenters.values.contains(where: {
                    hypot(display.x - $0.x, display.y - $0.y) <= 11
                }) { return .control }
                if geometry.graph.connections.contains(where: {
                    WorkflowConnectionGeometry.hitPath(for: $0, geometry: geometry,
                        portCenters: measuredPortCenters, excluding: controlBounds).cgPath.contains(display)
                }) { return .control }
                for node in geometry.graph.nodes.reversed() {
                    let center = geometry.rawPosition(node.id)
                    let height = cardSizes[node.id]?.height ?? 600
                    let frame = CGRect(x: center.x - WorkflowCanvasLayoutPolicy.nodeWidth / 2,
                        y: center.y - height / 2, width: WorkflowCanvasLayoutPolicy.nodeWidth, height: height)
                    if frame.contains(raw) { return .node(node.id) }
                }
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
                    case .clicked: onInspect(id)
                    }
                case .blank:
                    let layout = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                        viewportSize: update.viewport, zoom: zoom, translation: geometry.translation)
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
                    outputDragging: pendingDragPoint != nil)
            },
            allowsEvent: { point, offset, size in
                let current = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                    viewportSize: size, zoom: zoom, translation: geometry.translation)
                let raw = current.rawPoint(screenPoint: point, offset: offset)
                for node in geometry.graph.nodes {
                    let center = geometry.rawPosition(node.id)
                    let halfHeight = (cardSizes[node.id]?.height ?? 600) / 2
                    if abs(raw.x - center.x) <= WorkflowCanvasLayoutPolicy.nodeWidth / 2,
                       abs(raw.y - center.y) <= halfHeight { return false }
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
                let requested = zoom * CGFloat(exp(Double(delta) * 0.015))
                let next = old.anchoredZoom(toward: requested, mouse: point, offset: offset)
                guard next.zoom != zoom else { return }
                pendingZoomOffset = next.offset
                zoom = next.zoom
            },
            onMiddleClick: { size in
                let current = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
                    viewportSize: size, zoom: zoom, translation: geometry.translation)
                scrollPosition.scrollTo(point: current.centeredOffset(on: current.centerRawPoint))
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
        guard !readOnly, !controller.isRunning, controller.readOnlyReason == nil else {
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
        guard !readOnly, !controller.isRunning, controller.readOnlyReason == nil else {
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
                isRunning: controller.isRunning
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

    private func acceptSurfaceDrop(
        _ items: [WorkflowCanvasTransfer],
        at rawPoint: CGPoint,
        scope: WorkflowCanvasScope
    ) -> Bool {
        guard items.count == 1, !readOnly, !controller.isRunning,
              controller.readOnlyReason == nil,
              let item = try? items[0].validated() else { return false }
        if controller.graph == nil {
            switch item {
            case .operation, .asset, .assetInstance, .tool: return onDropItem(item, rawPoint)
            case .output: return false
            }
        }
        guard scope.isCurrent(in: controller) else { return false }
        switch item {
        case .operation, .asset, .assetInstance, .tool:
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
                ? 180 : CGFloat(WorkflowLayout.cardHeightBudget(
                    inputs: definition?.inputs.count ?? 1, outputs: definition?.outputs.count ?? 1))
            let height = cardSizes[node.id]?.height ?? fallbackHeight
            let card = CGRect(x: center.x + edge.width - WorkflowCanvasLayoutPolicy.nodeWidth / 2,
                              y: center.y + edge.height - height / 2,
                              width: WorkflowCanvasLayoutPolicy.nodeWidth, height: height)
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
    let selectedConnectionID: UUID?
    let pendingConnection: WorkflowPendingConnection?
    let pendingDragPoint: CGPoint?
    let canDisconnect: Bool
    let onSelect: (UUID) -> Void
    let onDisconnect: (WorkflowConnection) -> Void

    var body: some View {
        let centers = WorkflowConnectionGeometry.movingFallbackCenters(
            graph: graph, geometry: geometry, measured: portCenters,
            moving: dragPresentation.movingNodeIDs, offset: dragPresentation.offset)
        let paths = graph.connections.map {
            WorkflowConnectionGeometry.path(for: $0, geometry: geometry, portCenters: centers)
        }
        let drawingBounds = WorkflowConnectionGeometry.drawingBounds(size: geometry.size, paths: paths)
        let drawingOrigin = drawingBounds.origin
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.translateBy(x: -drawingOrigin.x, y: -drawingOrigin.y)
                for (connection, path) in zip(graph.connections, paths) {
                    if connection.id == selectedConnectionID {
                        context.stroke(path, with: .color(.primary.opacity(0.75)), lineWidth: 6)
                    }
                    context.stroke(path, with: .color(WorkflowPortStyle.color(for: sourcePort(connection))),
                                   lineWidth: 2.5)
                }
            }
            // Reverse curves can bow beyond both endpoints. Include their actual
            // bounds without resizing the scroll document or drawing its whole padding.
            .frame(width: drawingBounds.width, height: drawingBounds.height)
            .offset(x: drawingOrigin.x, y: drawingOrigin.y)
            .allowsHitTesting(false)

            // The captured node gesture owns the mouse until release/cancel.
            // Rebuild precise native wire hits once afterwards, not for every preview.
            if dragPresentation.movingNodeIDs.isEmpty {
                ForEach(graph.connections) { connection in
                    WorkflowConnectionInteraction(connection: connection, geometry: geometry,
                        portCenters: centers, controlBounds: controlBounds, canDisconnect: canDisconnect,
                        label: workflowText(language, "refinement.canvas.connectionLabel", fallback: "{type} connection from {source} to {target}",
                            arguments: ["type": WorkflowPortStyle.label(for: sourcePort(connection), language: language),
                                        "source": connection.sourcePort, "target": connection.targetPort]),
                        onSelect: { onSelect(connection.id) }, onDisconnect: { onDisconnect(connection) })
                }
            }
            if let pendingConnection, let pendingDragPoint {
                let source = WorkflowPortIdentity(nodeID: pendingConnection.nodeID,
                    port: pendingConnection.port, input: pendingConnection.input)
                if let start = centers[source] {
                    WorkflowConnectionGeometry.curve(
                        from: pendingConnection.input ? pendingDragPoint : start,
                        to: pendingConnection.input ? start : pendingDragPoint)
                    .stroke(WorkflowPortStyle.color(for: sourcePort(pendingConnection)), lineWidth: 2.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
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

/// The hover affordance and menu share the same guarded, single-shot edit.
private struct WorkflowConnectionInteraction: View {
    @Environment(\.dLanguageStore) private var language
    let connection: WorkflowConnection
    let geometry: WorkflowGraphGeometry
    let portCenters: [WorkflowPortIdentity: CGPoint]
    let controlBounds: [CGRect]
    let canDisconnect: Bool
    let label: String
    let onSelect: () -> Void
    let onDisconnect: () -> Void
    var body: some View {
        #if DEBUG
        let hitStart = CFAbsoluteTimeGetCurrent()
        #endif
        let hit = WorkflowConnectionGeometry.hitPath(for: connection,
            geometry: geometry, portCenters: portCenters, excluding: controlBounds)
        #if DEBUG
        let _ = WorkflowCanvasUpdateProbe.wireHitBuild?(CFAbsoluteTimeGetCurrent() - hitStart)
        #endif
        let ends = WorkflowConnectionGeometry.endpoints(for: connection,
            geometry: geometry, portCenters: portCenters)
        let middle = CGPoint(x: (ends.start.x + ends.end.x) / 2, y: (ends.start.y + ends.end.y) / 2)
        WorkflowConnectionReceiver(path: hit.cgPath, midpoint: middle,
            canDisconnect: canDisconnect,
            cutAvailable: WorkflowConnectionGeometry.canShowCut(at: middle,
                portCenters: Array(portCenters.values), controls: controlBounds), label: label,
            disconnectTitle: workflowText(language, "workflow.connection.disconnect", fallback: "断开连接"),
            identifier: "workflow-connection-" + connection.id.uuidString,
            onSelect: onSelect, onDisconnect: onDisconnect)
    }
}

private struct WorkflowNodeCard: View {
    let controller: WorkflowController
    let graph: WorkflowGraph
    let scope: WorkflowCanvasScope
    let node: WorkflowNode
    let definition: WorkflowOperationDefinition?
    @Binding var pendingConnection: WorkflowPendingConnection?
    let tool: WorkflowCanvasTool
    let pendingConnectionScope: WorkflowCanvasScope?
    let readOnly: Bool
    let selected: Bool
    let onPlan: (UUID, Bool) -> Void
    let onBindAsset: (UUID, UUID?, UUID, UUID) -> Bool
    let onInspect: (UUID) -> Void
    let onSelectPort: (WorkflowPortIdentity) -> Void
    let onPortDrag: (WorkflowPortIdentity, CGSize) -> Void
    let onPortDragEnd: (WorkflowPortIdentity?) -> Void
    @Environment(\.dLanguageStore) private var languageStore
    private var collapsed: Bool { controller.graph?.layout.first(where: { $0.nodeID == node.id })?.collapsed == true }

    var body: some View {
        #if DEBUG
        let _ = WorkflowCanvasUpdateProbe.nodeBody?(node.id)
        #endif
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    let identity = WorkflowNodeIdentity.resolve(node: node, definition: definition,
                        modelChoices: controller.modelChoices, assets: controller.availableAssets,
                        tools: controller.tools, language: languageStore)
                    Text(identity.title).font(.headline).lineLimit(2)
                    if let detail = identity.detail {
                        Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let annotation = identity.annotation, annotation != identity.title {
                        Text(annotation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(workflowText(
                        languageStore,
                        "workflow.node.dragHint",
                        fallback: "拖动卡片空白或说明移动；控件独立操作"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
                Spacer(minLength: 6)
                Button { onInspect(node.id) } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .workflowNodeControl()
                .help(workflowText(languageStore, "workflow.node.edit", fallback: "编辑节点"))
                Button { controller.toggleCollapsed(node.id) } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .workflowNodeControl()
                .help(collapsed
                      ? workflowText(languageStore, "workflow.node.expand", fallback: "展开节点")
                      : workflowText(languageStore, "workflow.node.collapse", fallback: "折叠节点"))
                .disabled(readOnly)
                Button {
                    guard scope.isCurrent(in: controller), let target = controller.canvasInsertionTarget() else { return }
                    controller.deleteNode(id: node.id, target: target)
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .workflowNodeControl()
                .help(workflowText(languageStore, "workflow.node.delete", fallback: "删除节点"))
                .accessibilityLabel(workflowText(languageStore, "workflow.node.delete", fallback: "删除节点"))
                .accessibilityIdentifier("workflow-node-delete-\(node.id.uuidString)")
                .disabled(readOnly || !controller.canEditCanvas)
                if let step = controller.latestStep(for: node.id) {
                    WorkflowStatusBadge(status: step.status, stale: controller.isStale(step))
                        .allowsHitTesting(false)
                }
            }
            if collapsed {
                Text(workflowText(
                    languageStore,
                    "workflow.node.collapsedDescription",
                    fallback: "端口与参数保留；展开后连接"
                )).font(.caption).foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            } else if let definition {
                portRows(definition.inputs, input: true)
                Divider().allowsHitTesting(false)
                portRows(definition.outputs, input: false)
            } else {
                Label(workflowText(
                    languageStore,
                    "workflow.node.unknownOperation",
                    fallback: "未知操作或版本；流程保持只读"
                ), systemImage: "questionmark.diamond")
                    .font(.caption).foregroundStyle(.orange)
                    .allowsHitTesting(false)
            }

            Toggle(workflowText(languageStore, "workflow.language.selection", fallback: "加入封装选区"), isOn: Binding(get: { controller.selectedNodeIDs.contains(node.id) }, set: { checked in
                if checked { controller.selectedNodeIDs.insert(node.id) } else { controller.selectedNodeIDs.remove(node.id) }
            })).toggleStyle(.checkbox).disabled(readOnly)
                .workflowNodeControl()
            HStack(spacing: 6) {
                Button(workflowText(languageStore, "workflow.action.runToHere", fallback: "运行到这里")) {
                    onPlan(node.id, false)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .workflowNodeControl()
                Button(workflowText(languageStore, "workflow.action.rerunOnly", fallback: "仅重跑本步")) {
                    onPlan(node.id, true)
                }
                    .controlSize(.small)
                    .workflowNodeControl()
                Spacer(minLength: 0)
            }
            .disabled(readOnly || definition == nil)
        }
        .padding(12)
        .frame(width: WorkflowCanvasLayoutPolicy.nodeWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 13)
                .fill(Color.clear).workbenchPanel(cornerRadius: 13)
                .contentShape(RoundedRectangle(cornerRadius: 13))
                .help(node.operationID)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: selected ? 3 : 1)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .dropDestination(for: WorkflowCanvasTransfer.self) { (items: [WorkflowCanvasTransfer], _: CGPoint) -> Bool in
            acceptAsset(items)
        }
        .accessibilityIdentifier("workflow-node-\(node.id.uuidString)")
    }

    @ViewBuilder
    private func portRows(_ ports: [WorkflowPortDefinition], input: Bool) -> some View {
        if ports.isEmpty {
            Text(input
                 ? workflowText(languageStore, "workflow.port.noInputs", fallback: "无输入")
                 : workflowText(languageStore, "workflow.port.noOutputs", fallback: "无输出"))
                .font(.caption).foregroundStyle(.tertiary)
                .allowsHitTesting(false)
        } else {
            ForEach(ports) { port in
                portRow(port, input: input)
            }
        }
    }

    private func portRow(_ port: WorkflowPortDefinition, input: Bool) -> some View {
        HStack(spacing: 3) {
            if input { portButton(port, input: true) }
            VStack(alignment: input ? .leading : .trailing, spacing: 1) {
                Text(WorkflowCanvasPresentation.portTitle(
                    operationID: node.operationID, port: port, input: input, language: languageStore
                )).font(.caption.weight(.medium)).lineLimit(1)
                Text(WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: input ? .leading : .trailing)
            .allowsHitTesting(false)
            if !input { portButton(port, input: false) }
        }
    }

    private func portButton(_ port: WorkflowPortDefinition, input: Bool) -> some View {
        let identity = WorkflowPortIdentity(nodeID: node.id, port: port.id, input: input)
        return Button { onSelectPort(identity) } label: {
            Circle().fill(WorkflowPortStyle.color(for: port)).frame(width: 9, height: 9)
                .anchorPreference(key: WorkflowPortAnchorPreferenceKey.self, value: .center) { [identity: $0] }
                .frame(width: 22, height: 22).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(readOnly || tool == .hand || !controller.canEditCanvas)
        .help(WorkflowCanvasPresentation.portTitle(operationID: node.operationID,
            port: port, input: input, language: languageStore) + " — "
            + WorkflowCanvasPresentation.portDetail(port, language: languageStore))
        .accessibilityLabel(workflowText(languageStore, "workflow.port.accessibility",
            fallback: "{direction}端口，{title}，{detail}", arguments: [
                "direction": input ? workflowText(languageStore, "workflow.port.input", fallback: "输入")
                    : workflowText(languageStore, "workflow.port.output", fallback: "输出"),
                "title": WorkflowCanvasPresentation.portTitle(operationID: node.operationID,
                    port: port, input: input, language: languageStore),
                "detail": WorkflowCanvasPresentation.portDetail(port, language: languageStore)]))
        .overlay {
            WorkflowPortDragReceiver(port: identity, scope: scope,
                enabled: !readOnly && tool == .pointer && controller.canEditCanvas,
                onClick: { onSelectPort(identity) },
                onChange: { onPortDrag(identity, $0) }, onEnd: onPortDragEnd)
        }
    }

    private func acceptAsset(_ items: [WorkflowCanvasTransfer]) -> Bool {
        guard items.count == 1, !readOnly, !controller.isRunning,
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

    init(
        graph: WorkflowGraph,
        tools: [WorkflowToolDefinition] = [],
        registry: WorkflowRegistry = .standard,
        previewPositions: [UUID: CGPoint] = [:],
        translation requestedTranslation: CGSize? = nil
    ) {
        self.graph = graph
        self.previewPositions = previewPositions
        let raw = graph.nodes.enumerated().map { index, node in
            previewPositions[node.id] ?? Self.rawPosition(node.id, index: index, graph: graph)
        }
        let minimumX = raw.map(\.x).min() ?? 0
        let halfHeights = graph.nodes.map { node -> CGFloat in
            if graph.layout.first(where: { $0.nodeID == node.id })?.collapsed == true { return 90 }
            let definition = registry.definition(for: node, tools: tools)
            return CGFloat(WorkflowLayout.cardHeightBudget(inputs: definition?.inputs.count ?? 1,
                outputs: definition?.outputs.count ?? 1)) / 2
        }
        let minimumY = zip(raw, halfHeights).map { $0.0.y - $0.1 }.min() ?? 0
        let naturalTranslation = CGSize(width: max(0, 150 - minimumX), height: max(0, 24 - minimumY))
        translation = requestedTranslation ?? naturalTranslation
        let maximumX = raw.map(\.x).max() ?? 0
        let maximumY = zip(raw, halfHeights).map { $0.0.y + $0.1 }.max() ?? 0
        size = CGSize(width: max(1_400, maximumX + translation.width + 320),
                      height: max(900, maximumY + translation.height + 24))
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
        WorkflowCanvasScopeIdentity(rootGraphID: rootGraphID, graphID: graphID, bodyPath: bodyPath)
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

private struct WorkflowNodeDragOffset: ViewModifier {
    let presentation: WorkflowCanvasNodeDragPresentation
    let moving: Bool
    func body(content: Content) -> some View {
        content.offset(moving ? presentation.offset : .zero)
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

private struct WorkflowNodeControlPreferenceKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

private extension View {
    func workflowNodeControl() -> some View {
        anchorPreference(key: WorkflowNodeControlPreferenceKey.self, value: .bounds) { [$0] }
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
        excluding controls: [CGRect] = []
    ) -> Path {
        let ends = endpoints(for: connection, geometry: geometry, portCenters: portCenters)
        // Exclude the actual dot hit circles, rather than an arbitrary fraction
        // that either hides a short wire or steals a long wire's endpoint.
        var hit = path(for: connection, geometry: geometry, portCenters: portCenters)
            .strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round))
        for point in Array(portCenters.values) + [ends.start, ends.end] {
            hit = hit.subtracting(Path(ellipseIn: CGRect(x: point.x - 12, y: point.y - 12,
                                                         width: 24, height: 24)))
        }
        for rect in controls { hit = hit.subtracting(Path(rect)) }
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
        portCenters: [WorkflowPortIdentity: CGPoint]
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
            portCenters[source] ?? CGPoint(
                x: sourceCenter.x + WorkflowCanvasLayoutPolicy.nodeWidth / 2,
                y: sourceCenter.y
            ),
            portCenters[target] ?? CGPoint(
                x: targetCenter.x - WorkflowCanvasLayoutPolicy.nodeWidth / 2,
                y: targetCenter.y
            )
        )
    }

    static func path(
        for connection: WorkflowConnection,
        geometry: WorkflowGraphGeometry,
        portCenters: [WorkflowPortIdentity: CGPoint]
    ) -> Path {
        let points = endpoints(for: connection, geometry: geometry, portCenters: portCenters)
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
