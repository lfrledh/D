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
    @Environment(\.dLanguageStore) private var languageStore
    @GestureState private var gestureScale: CGFloat = 1

    var body: some View {
        Group {
            if let graph {
                let geometry = WorkflowGraphGeometry(graph: graph, tools: controller.tools, registry: controller.registry)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Color(nsColor: .textBackgroundColor)
                            .contentShape(Rectangle())
                            .onTapGesture { controller.selectedNodeID = nil }
                        WorkflowConnectionLayer(graph: graph, geometry: geometry)
                        ForEach(graph.nodes) { node in
                            WorkflowNodeCard(
                                controller: controller,
                                node: node,
                                rawPosition: geometry.rawPosition(node.id),
                                definition: controller.registry.definition(for: node, tools: controller.tools),
                                zoom: effectiveZoom,
                                pendingConnection: $pendingConnection,
                                readOnly: readOnly,
                                selected: controller.selectedNodeID == node.id,
                                onPlan: onPlan
                            )
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                nodeSizeObserver?(node.id, size)
                            }
                            .position(geometry.displayPosition(node.id))
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
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
}

private struct WorkflowConnectionLayer: View {
    let graph: WorkflowGraph
    let geometry: WorkflowGraphGeometry

    var body: some View {
        Canvas { context, _ in
            for connection in graph.connections {
                let start = geometry.displayPosition(connection.sourceNode)
                let end = geometry.displayPosition(connection.targetNode)
                let horizontal = max(50, abs(end.x - start.x) * 0.45)
                var path = Path()
                path.move(to: CGPoint(x: start.x + 110, y: start.y))
                path.addCurve(
                    to: CGPoint(x: end.x - 110, y: end.y),
                    control1: CGPoint(x: start.x + 110 + horizontal, y: start.y),
                    control2: CGPoint(x: end.x - 110 - horizontal, y: end.y)
                )
                context.stroke(path, with: .color(.accentColor.opacity(0.75)), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkflowNodeCard: View {
    let controller: WorkflowController
    let node: WorkflowNode
    let rawPosition: CGPoint
    let definition: WorkflowOperationDefinition?
    let zoom: CGFloat
    @Binding var pendingConnection: WorkflowPendingConnection?
    let readOnly: Bool
    let selected: Bool
    let onPlan: (UUID, Bool) -> Void
    @Environment(\.dLanguageStore) private var languageStore
    @GestureState private var translation = CGSize.zero
    private var collapsed: Bool { controller.graph?.layout.first(where: { $0.nodeID == node.id })?.collapsed == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.headline).lineLimit(2)
                    Text(node.operationID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).help(node.operationID)
                }
                Spacer(minLength: 6)
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
        .offset(x: translation.width / max(zoom, 0.01),
                y: translation.height / max(zoom, 0.01))
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture { controller.selectedNodeID = node.id }
        .gesture(
            DragGesture(minimumDistance: 5)
                .updating($translation) { value, state, _ in
                    guard !readOnly else { return }
                    state = value.translation
                }
                .onEnded { value in
                    guard !readOnly else { return }
                    controller.moveNode(
                        id: node.id,
                        x: Double(rawPosition.x + value.translation.width / max(zoom, 0.01)),
                        y: Double(rawPosition.y + value.translation.height / max(zoom, 0.01))
                    )
                }
        )
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
                Button {
                    if input {
                        connect(to: port)
                    } else {
                        pendingConnection = WorkflowPendingConnection(nodeID: node.id, port: port.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if input { portDot(input: true) }
                        VStack(alignment: input ? .leading : .trailing, spacing: 1) {
                            Text(WorkflowCanvasPresentation.portTitle(
                                operationID: node.operationID, port: port, input: input, language: languageStore
                            )).font(.caption.weight(.medium)).lineLimit(1)
                            Text(WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: input ? .leading : .trailing)
                        if !input { portDot(input: false) }
                    }
                }
                .buttonStyle(.plain)
                .help(WorkflowCanvasPresentation.portTitle(operationID: node.operationID,
                    port: port, input: input, language: languageStore) + " — "
                    + WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                .disabled(readOnly || (input && pendingConnection == nil))
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
            }
        }
    }

    private func portDot(input: Bool) -> some View {
        Circle().fill(input ? Color.orange : Color.accentColor).frame(width: 9, height: 9)
    }

    private func connect(to port: WorkflowPortDefinition) {
        guard !readOnly, let source = pendingConnection else { return }
        controller.connect(source: source.nodeID, sourcePort: source.port,
                           target: node.id, targetPort: port.id)
        pendingConnection = nil
    }
}

struct WorkflowGraphGeometry {
    let graph: WorkflowGraph
    let translation: CGSize
    let size: CGSize

    init(graph: WorkflowGraph, tools: [WorkflowToolDefinition] = [], registry: WorkflowRegistry = .standard) {
        self.graph = graph
        let raw = graph.nodes.enumerated().map { index, node in
            Self.rawPosition(node.id, index: index, graph: graph)
        }
        let minimumX = raw.map(\.x).min() ?? 0
        let halfHeights = graph.nodes.map { node -> CGFloat in
            if graph.layout.first(where: { $0.nodeID == node.id })?.collapsed == true { return 90 }
            let definition = registry.definition(for: node, tools: tools)
            return CGFloat(WorkflowLayout.cardHeightBudget(inputs: definition?.inputs.count ?? 1,
                outputs: definition?.outputs.count ?? 1)) / 2
        }
        let minimumY = zip(raw, halfHeights).map { $0.0.y - $0.1 }.min() ?? 0
        translation = CGSize(width: max(0, 150 - minimumX), height: max(0, 24 - minimumY))
        let maximumX = raw.map(\.x).max() ?? 0
        let maximumY = zip(raw, halfHeights).map { $0.0.y + $0.1 }.max() ?? 0
        size = CGSize(width: max(1_400, maximumX + translation.width + 320),
                      height: max(900, maximumY + translation.height + 24))
    }

    func rawPosition(_ nodeID: UUID) -> CGPoint {
        let index = graph.nodes.firstIndex { $0.id == nodeID } ?? 0
        return Self.rawPosition(nodeID, index: index, graph: graph)
    }

    func displayPosition(_ nodeID: UUID) -> CGPoint {
        let point = rawPosition(nodeID)
        return CGPoint(x: point.x + translation.width, y: point.y + translation.height)
    }

    private static func rawPosition(_ nodeID: UUID, index: Int, graph: WorkflowGraph) -> CGPoint {
        if let layout = graph.layout.first(where: { $0.nodeID == nodeID }) {
            return CGPoint(x: CGFloat(layout.x), y: CGFloat(layout.y))
        }
        return WorkflowCanvasLayoutPolicy.fallbackPosition(index: index)
    }
}

