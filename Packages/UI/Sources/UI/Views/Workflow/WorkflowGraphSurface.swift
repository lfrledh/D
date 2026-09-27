import AppKit
import DWorkbench
import Foundation
import SwiftUI

struct WorkflowGraphSurface: View {
    let controller: WorkflowController
    let graph: WorkflowGraph?
    @Binding var zoom: CGFloat
    @Binding var pendingConnection: WorkflowPendingConnection?
    let readOnly: Bool
    let onPlan: (UUID, Bool) -> Void
    var nodeSizeObserver: ((UUID, CGSize) -> Void)?
    var onDropItem: (WorkflowCanvasTransfer, CGPoint) -> Bool = { _, _ in false }
    var onBindAsset: (UUID, UUID, UUID) -> Bool = { _, _, _ in false }
    var onInspect: (UUID) -> Void = { _ in }
    @Environment(\.dLanguageStore) private var languageStore
    @GestureState private var gestureScale: CGFloat = 1
    @State private var nodeDrag: WorkflowCanvasNodeDragState?
    @State private var stableOrigin: WorkflowCanvasStableOrigin?

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
                let origin = stableOrigin?.identity == scope.identity
                    ? stableOrigin!.translation : naturalGeometry.translation
                let previews = nodeDrag?.scope == scope
                    ? [nodeDrag!.nodeID: nodeDrag!.previewPosition] : [:]
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
                            .onTapGesture { controller.selectedNodeID = nil }
                            .help(workflowText(
                                languageStore,
                                "workflow.canvas.dropHint",
                                fallback: "将节点或项目素材拖到这里；拖动输出端口可建立连接。"
                            ))
                        ForEach(graph.nodes) { node in
                            WorkflowNodeCard(
                                controller: controller,
                                graph: graph,
                                scope: scope,
                                node: node,
                                definition: controller.registry.definition(for: node, tools: controller.tools),
                                pendingConnection: $pendingConnection,
                                readOnly: readOnly,
                                selected: controller.selectedNodeID == node.id,
                                onPlan: onPlan,
                                onBindAsset: onBindAsset,
                                onInspect: onInspect,
                                onDragChanged: { translation in
                                    updateDrag(
                                        nodeID: node.id,
                                        originalPosition: naturalGeometry.rawPosition(node.id),
                                        translation: translation,
                                        scope: scope,
                                        origin: origin
                                    )
                                },
                                onDragEnded: { translation in
                                    updateDrag(
                                        nodeID: node.id,
                                        originalPosition: naturalGeometry.rawPosition(node.id),
                                        translation: translation,
                                        scope: scope,
                                        origin: origin
                                    )
                                    finishDrag(
                                        nodeID: node.id,
                                        translation: translation,
                                        scope: scope
                                    )
                                },
                                onDragCancelled: { nodeDrag = nil }
                            )
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                nodeSizeObserver?(node.id, size)
                            }
                            .position(geometry.displayPosition(node.id))
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .coordinateSpace(name: WorkflowCanvasCoordinateSpace.name)
                    .overlayPreferenceValue(WorkflowPortAnchorPreferenceKey.self) { anchors in
                        GeometryReader { proxy in
                            WorkflowConnectionLayer(
                                graph: graph,
                                geometry: geometry,
                                portCenters: anchors.mapValues { proxy[$0] }
                            )
                        }
                    }
                    .dropDestination(for: WorkflowCanvasTransfer.self) { items, location in
                        acceptSurfaceDrop(items, at: geometry.rawPoint(forDisplayPoint: location), scope: scope)
                    }
                    .scaleEffect(effectiveZoom, anchor: .topLeading)
                    .frame(width: geometry.size.width * effectiveZoom,
                           height: geometry.size.height * effectiveZoom,
                           alignment: .topLeading)
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
                    if nodeDrag?.scope != next { nodeDrag = nil }
                    if stableOrigin?.identity != next.identity { stableOrigin = nil }
                }
                .onChange(of: readOnly || controller.isRunning) { _, blocked in
                    if blocked { nodeDrag = nil }
                }
                .onDisappear { nodeDrag = nil }
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
                            }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
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
            }
        }
        .accessibilityIdentifier("workflow-graph-surface")
    }

    private var effectiveZoom: CGFloat {
        WorkflowCanvasLayoutPolicy.clampedZoom(zoom * gestureScale)
    }

    private func updateDrag(
        nodeID: UUID,
        originalPosition: CGPoint,
        translation: CGSize,
        scope: WorkflowCanvasScope,
        origin: CGSize
    ) {
        guard !readOnly, !controller.isRunning, controller.readOnlyReason == nil else {
            nodeDrag = nil
            return
        }
        if nodeDrag?.scope != scope || nodeDrag?.nodeID != nodeID {
            nodeDrag = WorkflowCanvasNodeDragState(
                scope: scope,
                nodeID: nodeID,
                originalPosition: originalPosition,
                origin: origin
            )
            stableOrigin = WorkflowCanvasStableOrigin(identity: scope.identity, translation: origin)
        }
        nodeDrag?.update(screenTranslation: translation, zoom: effectiveZoom)
    }

    private func finishDrag(
        nodeID: UUID,
        translation: CGSize,
        scope: WorkflowCanvasScope
    ) {
        guard var drag = nodeDrag, drag.nodeID == nodeID else { return }
        drag.update(screenTranslation: translation, zoom: effectiveZoom)
        nodeDrag = nil
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
              controller.graph?.id == scope.graphID,
              controller.rootGraph?.id == scope.rootGraphID,
              controller.rootGraph?.revision == scope.rootRevision,
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

    var body: some View {
        Canvas { context, _ in
            for connection in graph.connections {
                context.stroke(
                    WorkflowConnectionGeometry.path(
                        for: connection, geometry: geometry, portCenters: portCenters
                    ),
                    with: .color(.accentColor.opacity(0.75)),
                    lineWidth: 2
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkflowNodeCard: View {
    let controller: WorkflowController
    let graph: WorkflowGraph
    let scope: WorkflowCanvasScope
    let node: WorkflowNode
    let definition: WorkflowOperationDefinition?
    @Binding var pendingConnection: WorkflowPendingConnection?
    let readOnly: Bool
    let selected: Bool
    let onPlan: (UUID, Bool) -> Void
    let onBindAsset: (UUID, UUID, UUID) -> Bool
    let onInspect: (UUID) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    let onDragCancelled: () -> Void
    @Environment(\.dLanguageStore) private var languageStore
    @GestureState private var headerDragActive = false
    private var collapsed: Bool { controller.graph?.layout.first(where: { $0.nodeID == node.id })?.collapsed == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.headline).lineLimit(2)
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
                        onDragChanged(value.translation)
                    }
                    .onEnded { value in
                        guard !readOnly else { return }
                        onDragEnded(value.translation)
                    }
            )
            .onChange(of: headerDragActive) { wasActive, isActive in
                if wasActive, !isActive { onDragCancelled() }
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
        .onTapGesture { controller.selectedNodeID = node.id }
        .dropDestination(for: WorkflowCanvasTransfer.self) { items, _ in
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
                pendingConnection = WorkflowPendingConnection(nodeID: node.id, port: port.id)
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
                graphID: graph.id,
                revision: scope.rootRevision,
                nodeID: node.id,
                port: port.id
            ))
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
        guard !readOnly, let source = pendingConnection else { return }
        guard WorkflowCanvasConnectionPolicy.canConnect(
            graph: graph,
            registry: controller.registry,
            tools: controller.tools,
            sourceNodeID: source.nodeID,
            sourcePort: source.port,
            targetNodeID: node.id,
            targetPort: port.id
        ) else { return }
        controller.connect(source: source.nodeID, sourcePort: source.port,
                           target: node.id, targetPort: port.id)
        pendingConnection = nil
    }

    private func acceptOutput(
        _ items: [WorkflowCanvasTransfer],
        targetPort: WorkflowPortDefinition
    ) -> Bool {
        guard items.count == 1, !readOnly, !controller.isRunning,
              controller.readOnlyReason == nil,
              let item = try? items[0].validated(),
              case .output(let graphID, let revision, let sourceNodeID, let sourcePort) = item,
              graphID == graph.id,
              revision == scope.rootRevision,
              controller.graph?.id == graph.id,
              controller.rootGraph?.revision == revision,
              WorkflowCanvasConnectionPolicy.canConnect(
                graph: graph,
                registry: controller.registry,
                tools: controller.tools,
                sourceNodeID: sourceNodeID,
                sourcePort: sourcePort,
                targetNodeID: node.id,
                targetPort: targetPort.id
              ) else { return false }
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
              controller.graph?.id == graph.id,
              controller.rootGraph?.revision == scope.rootRevision,
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

struct WorkflowCanvasScope: Equatable {
    let rootGraphID: UUID
    let rootRevision: UUID
    let graphID: UUID
    let bodyPath: [WorkflowBodyLocation]

    var identity: WorkflowCanvasScopeIdentity {
        WorkflowCanvasScopeIdentity(rootGraphID: rootGraphID, graphID: graphID, bodyPath: bodyPath)
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

struct WorkflowCanvasNodeDragState: Equatable {
    let scope: WorkflowCanvasScope
    let nodeID: UUID
    let originalPosition: CGPoint
    let origin: CGSize
    private(set) var previewPosition: CGPoint

    init(
        scope: WorkflowCanvasScope,
        nodeID: UUID,
        originalPosition: CGPoint,
        origin: CGSize
    ) {
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
        guard sourceNodeID != targetNodeID,
              let sourceNode = graph.nodes.first(where: { $0.id == sourceNodeID }),
              let targetNode = graph.nodes.first(where: { $0.id == targetNodeID }),
              let source = registry.definition(for: sourceNode, tools: tools)?.outputs.first(where: {
                $0.id == sourcePort
              }),
              let target = registry.definition(for: targetNode, tools: tools)?.inputs.first(where: {
                $0.id == targetPort
              }),
              !Set(source.kinds).isDisjoint(with: target.kinds),
              !graph.connections.contains(where: {
                $0.targetNode == targetNodeID && $0.targetPort == targetPort
              }),
              !graph.connections.contains(where: {
                $0.sourceNode == sourceNodeID && $0.sourcePort == sourcePort
                    && $0.targetNode == targetNodeID && $0.targetPort == targetPort
              }),
              !wouldCreateCycle(graph: graph, source: sourceNodeID, target: targetNodeID) else { return false }
        return true
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
