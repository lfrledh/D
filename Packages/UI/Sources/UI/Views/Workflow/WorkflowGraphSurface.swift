import AppKit
import DWorkbench
import Foundation
import SwiftUI

struct WorkflowGraphSurface: View {
    let controller: WorkflowController
    let graph: WorkflowGraph?
    @Binding var zoom: CGFloat
    @Binding var scrollPosition: ScrollPosition
    let viewContext: WorkflowCanvasViewContext
    @Binding var pendingConnection: WorkflowPendingConnection?
    @Binding var selectedConnectionID: UUID?
    let readOnly: Bool
    let onPlan: (UUID, Bool) -> Void
    var nodeSizeObserver: ((UUID, CGSize) -> Void)?
    var onScrollObservation: (WorkflowCanvasViewContext, WorkflowCanvasScrollObservation) -> Void = { _, _ in }
    var onDropItem: (WorkflowCanvasTransfer, CGPoint) -> Bool = { _, _ in false }
    var onBindAsset: (UUID, UUID, UUID) -> Bool = { _, _, _ in false }
    var onInspect: (UUID) -> Void = { _ in }
    @Environment(\.dLanguageStore) private var languageStore
    @GestureState private var gestureScale: CGFloat = 1
    @State private var nodeDrag = WorkflowCanvasNodeDragCoordinator()
    @State private var stableOrigin: WorkflowCanvasStableOrigin?
    @State private var pendingConnectionScope: WorkflowCanvasScope?
    @State private var pendingDragPoint: CGPoint?
    @State private var connectionIssue: WorkflowCanvasConnectionIssue?

    var body: some View {
        Group {
            if let graph {
                let scope = WorkflowCanvasScope(
                    rootGraphID: controller.rootGraph?.id ?? graph.id,
                    rootRevision: controller.rootGraph?.revision ?? graph.revision,
                    graphID: graph.id,
                    bodyPath: controller.bodyPath
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
                let previews = nodeDrag.active?.scope == scope
                    ? [nodeDrag.active!.nodeID: nodeDrag.active!.previewPosition] : [:]
                let geometry = WorkflowGraphGeometry(
                    graph: graph,
                    tools: controller.tools,
                    registry: controller.registry,
                    previewPositions: previews,
                    translation: origin
                )
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Color(nsColor: .textBackgroundColor)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                controller.selectedNodeID = nil
                                selectedConnectionID = nil
                            }
                            .help(workflowText(
                                languageStore,
                                "workflow.canvas.dropHint",
                                fallback: "将节点或项目素材拖到这里；拖动输出端口可建立连接。"
                            ))
                        ZStack(alignment: .topLeading) {
                        ForEach(graph.nodes) { node in
                            WorkflowNodeCard(
                                controller: controller,
                                graph: graph,
                                scope: scope,
                                node: node,
                                definition: controller.registry.definition(for: node, tools: controller.tools),
                                pendingConnection: $pendingConnection,
                                pendingConnectionScope: pendingConnectionScope,
                                readOnly: readOnly,
                                selected: controller.selectedNodeID == node.id,
                                onPlan: onPlan,
                                onBindAsset: onBindAsset,
                                onInspect: onInspect,
                                onSelectOutput: { connection in
                                    pendingConnection = connection
                                    pendingConnectionScope = scope
                                    connectionIssue = nil
                                },
                                onClearOutput: {
                                    pendingConnection = nil
                                    pendingConnectionScope = nil
                                    pendingDragPoint = nil
                                },
                                onOutputDrag: { source, point in
                                    pendingConnection = source
                                    pendingConnectionScope = scope
                                    pendingDragPoint = point
                                    connectionIssue = nil
                                },
                                onOutputDragEnd: {
                                    pendingDragPoint = nil
                                    if pendingConnectionScope == scope {
                                        pendingConnection = nil
                                        pendingConnectionScope = nil
                                    }
                                },
                                onConnectionIssue: { connectionIssue = $0 },
                                onDragBegan: { sessionID, translation in
                                    beginDrag(
                                        sessionID: sessionID,
                                        nodeID: node.id,
                                        originalPosition: naturalGeometry.rawPosition(node.id),
                                        translation: translation,
                                        scope: scope,
                                        origin: origin
                                    )
                                },
                                onDragChanged: { sessionID, translation in
                                    updateDrag(
                                        sessionID: sessionID,
                                        nodeID: node.id,
                                        translation: translation,
                                        scope: scope
                                    )
                                },
                                onDragEnded: { sessionID, translation in
                                    finishDrag(
                                        sessionID: sessionID,
                                        nodeID: node.id,
                                        translation: translation,
                                        scope: scope
                                    )
                                },
                                onDragCancelled: { sessionID in nodeDrag.cancel(sessionID: sessionID) }
                            )
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                nodeSizeObserver?(node.id, size)
                            }
                            .position(geometry.displayPosition(node.id))
                        }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        // Lines remain behind cards and port buttons, including at intersections.
                        .backgroundPreferenceValue(WorkflowPortAnchorPreferenceKey.self) { anchors in
                        GeometryReader { proxy in
                            WorkflowConnectionLayer(
                                graph: graph,
                                geometry: geometry,
                                portCenters: anchors.mapValues { proxy[$0] },
                                selectedConnectionID: selectedConnectionID,
                                pendingConnection: pendingConnection,
                                pendingDragPoint: pendingDragPoint,
                                onSelect: { connectionID in
                                    selectedConnectionID = connectionID
                                }
                            )
                        }
                    }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .coordinateSpace(name: WorkflowCanvasCoordinateSpace.name)
                    .dropDestination(for: WorkflowCanvasTransfer.self) { items, location in
                        acceptSurfaceDrop(items, at: geometry.rawPoint(forDisplayPoint: location), scope: scope)
                    }
                    .scaleEffect(effectiveZoom, anchor: .topLeading)
                    .frame(width: geometry.size.width * effectiveZoom,
                           height: geometry.size.height * effectiveZoom,
                           alignment: .topLeading)
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: WorkflowCanvasScrollObservation.self) { scroll in
                    WorkflowCanvasScrollObservation(contentOffset: scroll.contentOffset,
                        visibleRawCenter: WorkflowCanvasViewport.visibleRawCenter(
                            contentOffset: scroll.contentOffset, containerSize: scroll.containerSize,
                            zoom: effectiveZoom, translation: geometry.translation))
                } action: { _, observation in
                    onScrollObservation(viewContext, observation)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($gestureScale) { value, state, _ in state = value }
                        .onEnded { value in
                            zoom = WorkflowCanvasLayoutPolicy.clampedZoom(zoom * value)
                        }
                )
                .onChange(of: scope) { _, next in
                    if nodeDrag.active?.scope != next { nodeDrag.invalidate() }
                    if stableOrigin?.identity != next.identity { stableOrigin = nil }
                    if pendingConnectionScope != next {
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
                        pendingDragPoint = nil
                    }
                }
                .onDisappear {
                    nodeDrag.invalidate()
                    pendingDragPoint = nil
                }
                .overlay(alignment: .topLeading) {
                    if let pendingConnection {
                        HStack(spacing: 8) {
                            Label(workflowText(
                                languageStore,
                                "workflow.connection.chooseInput",
                                fallback: "已选择输出 {port}，请选择目标输入",
                                arguments: ["port": pendingConnection.port]
                            ), systemImage: "link")
                            Button(workflowText(languageStore, "workflow.connection.cancel", fallback: "取消连接")) {
                                self.pendingConnection = nil
                                pendingConnectionScope = nil
                                pendingDragPoint = nil
                            }
                                .buttonStyle(.borderless)
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
            } else {
                ContentUnavailableView(
                    workflowText(languageStore, "workflow.canvas.empty", fallback: "选择或添加流程"),
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(workflowText(
                        languageStore,
                        "workflow.canvas.emptyDescription",
                        fallback: "流程只会在明确保存或运行时提交。"
                    ))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .dropDestination(for: WorkflowCanvasTransfer.self) { items, location in
                    guard items.count == 1, controller.graph == nil, controller.canEditCanvas,
                          let item = items.first, (try? item.validated()) != nil else { return false }
                    switch item {
                    case .operation, .asset: return onDropItem(item, location)
                    case .output: return false
                    }
                }
            }
        }
        .accessibilityIdentifier("workflow-graph-surface")
    }

    private var effectiveZoom: CGFloat {
        WorkflowCanvasLayoutPolicy.clampedZoom(zoom * gestureScale)
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
        let began = nodeDrag.begin(
            WorkflowCanvasNodeDragState(
                sessionID: sessionID,
                scope: scope,
                nodeID: nodeID,
                originalPosition: originalPosition,
                origin: origin
            ),
            screenTranslation: translation,
            zoom: effectiveZoom
        )
        if began {
            stableOrigin = WorkflowCanvasStableOrigin(identity: scope.identity, translation: origin)
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
                bodyPath: controller.bodyPath
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
              ) else { return }
        stableOrigin = WorkflowCanvasStableOrigin(identity: scope.identity, translation: drag.origin)
        controller.moveNode(id: nodeID, x: Double(drag.previewPosition.x), y: Double(drag.previewPosition.y))
    }

    private func acceptSurfaceDrop(
        _ items: [WorkflowCanvasTransfer],
        at rawPoint: CGPoint,
        scope: WorkflowCanvasScope
    ) -> Bool {
        guard items.count == 1, !readOnly, !controller.isRunning,
              controller.readOnlyReason == nil,
              scope.isCurrent(in: controller),
              let item = try? items[0].validated() else { return false }
        switch item {
        case .operation, .asset:
            return onDropItem(item, rawPoint)
        case .output:
            return false
        }
    }
}

private enum WorkflowCanvasCoordinateSpace {
    static let name = "workflow-canvas-unscaled"
}

private struct WorkflowConnectionLayer: View {
    let graph: WorkflowGraph
    let geometry: WorkflowGraphGeometry
    let portCenters: [WorkflowPortIdentity: CGPoint]
    let selectedConnectionID: UUID?
    let pendingConnection: WorkflowPendingConnection?
    let pendingDragPoint: CGPoint?
    let onSelect: (UUID) -> Void

    var body: some View {
        Canvas { context, _ in
            for connection in graph.connections {
                context.stroke(
                    WorkflowConnectionGeometry.path(
                        for: connection, geometry: geometry, portCenters: portCenters
                    ),
                    with: .color(connection.id == selectedConnectionID ? .orange : .accentColor.opacity(0.75)),
                    lineWidth: connection.id == selectedConnectionID ? 3 : 2
                )
            }
        }
        .overlay {
            ForEach(graph.connections) { connection in
                let hitPath = WorkflowConnectionGeometry.hitPath(
                    for: connection, geometry: geometry, portCenters: portCenters
                )
                hitPath.fill(Color.clear)
                    .contentShape(hitPath)
                    .onTapGesture { onSelect(connection.id) }
                    .accessibilityLabel("连接 \(connection.sourcePort) 到 \(connection.targetPort)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onSelect(connection.id) }
                    .accessibilityIdentifier("workflow-connection-" + connection.id.uuidString)
            }
        }
        .overlay {
            if let pendingConnection, let pendingDragPoint {
                let source = WorkflowPortIdentity(nodeID: pendingConnection.nodeID,
                    port: pendingConnection.port, input: false)
                if let start = portCenters[source] {
                    Path { path in
                        path.move(to: start)
                        path.addLine(to: pendingDragPoint)
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
    }
}

private struct WorkflowNodeCard: View {
    let controller: WorkflowController
    let graph: WorkflowGraph
    let scope: WorkflowCanvasScope
    let node: WorkflowNode
    let definition: WorkflowOperationDefinition?
    @Binding var pendingConnection: WorkflowPendingConnection?
    let pendingConnectionScope: WorkflowCanvasScope?
    let readOnly: Bool
    let selected: Bool
    let onPlan: (UUID, Bool) -> Void
    let onBindAsset: (UUID, UUID, UUID) -> Bool
    let onInspect: (UUID) -> Void
    let onSelectOutput: (WorkflowPendingConnection) -> Void
    let onClearOutput: () -> Void
    let onOutputDrag: (WorkflowPendingConnection, CGPoint) -> Void
    let onOutputDragEnd: () -> Void
    let onConnectionIssue: (WorkflowCanvasConnectionIssue) -> Void
    let onDragBegan: (UUID, CGSize) -> Void
    let onDragChanged: (UUID, CGSize) -> Void
    let onDragEnded: (UUID, CGSize) -> Void
    let onDragCancelled: (UUID) -> Void
    @Environment(\.dLanguageStore) private var languageStore
    @GestureState private var headerDragActive = false
    @GestureState private var outputDragActive = false
    @State private var dragGestureSession = WorkflowCanvasGestureSessionState()
    private var collapsed: Bool { controller.graph?.layout.first(where: { $0.nodeID == node.id })?.collapsed == true }

    var body: some View {
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
                        fallback: "拖动标题移动；双击编辑"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .help(node.operationID)
                Spacer(minLength: 6)
                Button { onInspect(node.id) } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help(workflowText(languageStore, "workflow.node.edit", fallback: "编辑节点"))
                Button { controller.toggleCollapsed(node.id) } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .help(collapsed
                      ? workflowText(languageStore, "workflow.node.expand", fallback: "展开节点")
                      : workflowText(languageStore, "workflow.node.collapse", fallback: "折叠节点"))
                .disabled(readOnly)
                if let step = controller.latestStep(for: node.id) {
                    WorkflowStatusBadge(status: step.status, stale: controller.isStale(step))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onInspect(node.id) }
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .global)
                    .updating($headerDragActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard !readOnly else { return }
                        switch dragGestureSession.change() {
                        case .began(let sessionID):
                            onDragBegan(sessionID, value.translation)
                        case .changed(let sessionID):
                            onDragChanged(sessionID, value.translation)
                        }
                    }
                    .onEnded { value in
                        guard !readOnly, let sessionID = dragGestureSession.end() else { return }
                        onDragEnded(sessionID, value.translation)
                    }
            )
            .onChange(of: headerDragActive) { wasActive, isActive in
                if wasActive, !isActive, let sessionID = dragGestureSession.cancel() {
                    onDragCancelled(sessionID)
                }
            }

            if collapsed {
                Text(workflowText(
                    languageStore,
                    "workflow.node.collapsedDescription",
                    fallback: "端口与参数保留；展开后连接"
                )).font(.caption).foregroundStyle(.secondary)
            } else if let definition {
                portRows(definition.inputs, input: true)
                Divider()
                portRows(definition.outputs, input: false)
            } else {
                Label(workflowText(
                    languageStore,
                    "workflow.node.unknownOperation",
                    fallback: "未知操作或版本；流程保持只读"
                ), systemImage: "questionmark.diamond")
                    .font(.caption).foregroundStyle(.orange)
            }

            Toggle(workflowText(languageStore, "workflow.language.selection", fallback: "加入封装选区"), isOn: Binding(get: { controller.selectedNodeIDs.contains(node.id) }, set: { checked in
                if checked { controller.selectedNodeIDs.insert(node.id) } else { controller.selectedNodeIDs.remove(node.id) }
            })).toggleStyle(.checkbox).disabled(readOnly)
            HStack(spacing: 6) {
                Button(workflowText(languageStore, "workflow.action.runToHere", fallback: "运行到这里")) {
                    onPlan(node.id, false)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(workflowText(languageStore, "workflow.action.rerunOnly", fallback: "仅重跑本步")) {
                    onPlan(node.id, true)
                }
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
            .disabled(readOnly || definition == nil)
        }
        .padding(12)
        .frame(width: WorkflowCanvasLayoutPolicy.nodeWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: selected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture { onInspect(node.id) }
        .dropDestination(for: WorkflowCanvasTransfer.self) { items, _ in
            acceptAsset(items)
        }
        .onChange(of: outputDragActive) { wasActive, isActive in
            if wasActive && !isActive { onOutputDragEnd() }
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
        } else {
            ForEach(ports) { port in
                portRow(port, input: input)
            }
        }
    }

    @ViewBuilder
    private func portRow(_ port: WorkflowPortDefinition, input: Bool) -> some View {
        let row = Button {
            if input {
                connect(to: port)
            } else {
                onSelectOutput(WorkflowPendingConnection(nodeID: node.id, port: port.id))
            }
        } label: {
            HStack(spacing: 6) {
                if input { portDot(port: port, input: true) }
                VStack(alignment: input ? .leading : .trailing, spacing: 1) {
                    Text(WorkflowCanvasPresentation.portTitle(
                        operationID: node.operationID, port: port, input: input, language: languageStore
                    )).font(.caption.weight(.medium)).lineLimit(1)
                    Text(WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: input ? .leading : .trailing)
                if !input { portDot(port: port, input: false) }
            }
        }
        .buttonStyle(.plain)
        .help(WorkflowCanvasPresentation.portTitle(operationID: node.operationID,
            port: port, input: input, language: languageStore) + " — "
            + WorkflowCanvasPresentation.portDetail(port, language: languageStore) + " — "
            + (input
                ? workflowText(
                    languageStore,
                    "workflow.port.dropOutputHint",
                    fallback: "可将兼容输出拖到这里"
                )
                : workflowText(
                    languageStore,
                    "workflow.port.dragOutputHint",
                    fallback: "拖到兼容输入端口以连接"
                )))
        .disabled(readOnly)
        .accessibilityLabel(workflowText(
            languageStore,
            "workflow.port.accessibility",
            fallback: "{direction}端口，{title}，{detail}",
            arguments: [
                "direction": input
                    ? workflowText(languageStore, "workflow.port.input", fallback: "输入")
                    : workflowText(languageStore, "workflow.port.output", fallback: "输出"),
                "title": WorkflowCanvasPresentation.portTitle(
                    operationID: node.operationID, port: port, input: input, language: languageStore
                ),
                "detail": WorkflowCanvasPresentation.portDetail(port, language: languageStore),
            ]
        ))

        if input {
            row.dropDestination(for: WorkflowCanvasTransfer.self) { items, _ in
                acceptOutput(items, targetPort: port)
            }
        } else if !readOnly {
            row.draggable(WorkflowCanvasTransfer.output(
                rootGraphID: scope.rootGraphID,
                bodyPath: scope.bodyPath.map(WorkflowCanvasBodyLocation.init),
                graphID: graph.id,
                revision: scope.rootRevision,
                nodeID: node.id,
                port: port.id
            ))
            .simultaneousGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(WorkflowCanvasCoordinateSpace.name))
                    .updating($outputDragActive) { _, active, _ in active = true }
                    .onChanged { value in
                        onOutputDrag(WorkflowPendingConnection(nodeID: node.id, port: port.id), value.location)
                    }
                    .onEnded { _ in onOutputDragEnd() }
            )
        } else {
            row
        }
    }

    private func portDot(port: WorkflowPortDefinition, input: Bool) -> some View {
        Circle()
            .fill(input ? Color.orange : Color.accentColor)
            .frame(width: 9, height: 9)
            .anchorPreference(key: WorkflowPortAnchorPreferenceKey.self, value: .center) {
                [WorkflowPortIdentity(nodeID: node.id, port: port.id, input: input): $0]
            }
    }

    private func connect(to port: WorkflowPortDefinition) {
        guard !readOnly, !controller.isRunning, controller.readOnlyReason == nil,
              scope.isCurrent(in: controller),
              pendingConnectionScope == scope,
              let source = pendingConnection else { return }
        if let issue = WorkflowCanvasConnectionPolicy.issue(
            graph: graph,
            registry: controller.registry,
            tools: controller.tools,
            sourceNodeID: source.nodeID,
            sourcePort: source.port,
            targetNodeID: node.id,
            targetPort: port.id
        ) {
            onConnectionIssue(issue)
            return
        }
        controller.connect(source: source.nodeID, sourcePort: source.port,
                           target: node.id, targetPort: port.id)
        onClearOutput()
    }

    private func acceptOutput(
        _ items: [WorkflowCanvasTransfer],
        targetPort: WorkflowPortDefinition
    ) -> Bool {
        guard items.count == 1, !readOnly, !controller.isRunning,
              controller.readOnlyReason == nil,
              let item = try? items[0].validated(),
              case .output(_, _, _, _, let sourceNodeID, let sourcePort) = item,
              item.matchesOutputScope(scope),
              scope.isCurrent(in: controller) else {
            onConnectionIssue(.staleScope)
            return false
        }
        if let issue = WorkflowCanvasConnectionPolicy.issue(
            graph: graph, registry: controller.registry, tools: controller.tools,
            sourceNodeID: sourceNodeID, sourcePort: sourcePort,
            targetNodeID: node.id, targetPort: targetPort.id
        ) {
            onConnectionIssue(issue)
            return false
        }
        controller.connect(
            source: sourceNodeID,
            sourcePort: sourcePort,
            target: node.id,
            targetPort: targetPort.id
        )
        return true
    }

    private func acceptAsset(_ items: [WorkflowCanvasTransfer]) -> Bool {
        guard items.count == 1, !readOnly, !controller.isRunning,
              controller.readOnlyReason == nil,
              definition?.interaction == .assetInput,
              scope.isCurrent(in: controller),
              let item = try? items[0].validated(),
              case .asset(let projectID, let assetID) = item else { return false }
        return onBindAsset(projectID, assetID, node.id)
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

enum WorkflowCanvasViewport {
    static func visibleRawCenter(contentOffset: CGPoint, containerSize: CGSize,
                                 zoom: CGFloat, translation: CGSize) -> CGPoint {
        let scale = max(zoom, 0.01)
        return CGPoint(
            x: (contentOffset.x + containerSize.width / 2) / scale - translation.width,
            y: (contentOffset.y + containerSize.height / 2) / scale - translation.height
        )
    }
}

struct WorkflowCanvasScrollObservation: Equatable {
    let contentOffset: CGPoint
    let visibleRawCenter: CGPoint
}

struct WorkflowCanvasScope: Equatable {
    let rootGraphID: UUID
    let rootRevision: UUID
    let graphID: UUID
    let bodyPath: [WorkflowBodyLocation]

    var identity: WorkflowCanvasScopeIdentity {
        WorkflowCanvasScopeIdentity(rootGraphID: rootGraphID, graphID: graphID, bodyPath: bodyPath)
    }

    @MainActor
    func isCurrent(in controller: WorkflowController) -> Bool {
        guard let currentRoot = controller.rootGraph,
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
    private(set) var previewPosition: CGPoint

    init(
        sessionID: UUID,
        scope: WorkflowCanvasScope,
        nodeID: UUID,
        originalPosition: CGPoint,
        origin: CGSize
    ) {
        self.sessionID = sessionID
        self.scope = scope
        self.nodeID = nodeID
        self.originalPosition = originalPosition
        self.origin = origin
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
        let scale = max(zoom, 0.01)
        return CGPoint(
            x: original.x + screenTranslation.width / scale,
            y: original.y + screenTranslation.height / scale
        )
    }
}

struct WorkflowPortIdentity: Hashable {
    let nodeID: UUID
    let port: String
    let input: Bool
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
    static func hitPath(
        for connection: WorkflowConnection,
        geometry: WorkflowGraphGeometry,
        portCenters: [WorkflowPortIdentity: CGPoint]
    ) -> Path {
        path(for: connection, geometry: geometry, portCenters: portCenters)
            .trimmedPath(from: 0.12, to: 0.88)
            .strokedPath(StrokeStyle(lineWidth: 16))
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
        let horizontal = max(50, abs(points.end.x - points.start.x) * 0.45)
        var path = Path()
        path.move(to: points.start)
        path.addCurve(
            to: points.end,
            control1: CGPoint(x: points.start.x + horizontal, y: points.start.y),
            control2: CGPoint(x: points.end.x - horizontal, y: points.end.y)
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
