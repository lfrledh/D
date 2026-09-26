import AppKit
import DWorkbench
import Foundation
import SwiftUI

@MainActor
private func workflowText(
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
    private let onTextModel: () -> Void
    private let onImageModel: () -> Void
    private let onImport: (UUID) -> Void
    private let onDestination: () -> Void
    private let onPublishText: () -> Void
    private let onReturnText: (WorkflowAssetReference) -> Void

    @Environment(\.dLanguageStore) private var languageStore

    @State private var operationQuery = ""
    @State private var zoom: CGFloat = 1
    @State private var pendingConnection: WorkflowPendingConnection?
    @State private var runPreview: WorkflowRunPreview?

    public init(
        controller: WorkflowController,
        onTextModel: @escaping () -> Void,
        onImageModel: @escaping () -> Void,
        onImport: @escaping (UUID) -> Void,
        onDestination: @escaping () -> Void,
        onPublishText: @escaping () -> Void,
        onReturnText: @escaping (WorkflowAssetReference) -> Void
    ) {
        self.controller = controller
        self.onTextModel = onTextModel
        self.onImageModel = onImageModel
        self.onImport = onImport
        self.onDestination = onDestination
        self.onPublishText = onPublishText
        self.onReturnText = onReturnText
    }

    public var body: some View {
        GeometryReader { viewport in
        VStack(spacing: 0) {
            toolbar.frame(width: viewport.size.width)
            Divider()
            statusStrip
            Divider()
            GeometryReader { proxy in
                // Keep the same editor subtree across window sizes and scroll the viewport.
                ScrollView(.horizontal) {
                    panels.frame(width: max(proxy.size.width, WorkflowCanvasLayoutPolicy.minimumWorkspaceWidth),
                                 height: proxy.size.height)
                }
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
                    Task { await controller.run(target: preview.nodeID, only: preview.only) }
                }
            )
        }
        .onChange(of: controller.graph?.id) { _, _ in
            pendingConnection = nil
            runPreview = nil
        }
    }

    private var panels: some View {
        HStack(spacing: 0) {
            WorkflowOperationLibrary(
                registry: controller.registry,
                query: $operationQuery,
                readOnly: isReadOnly,
                onAdd: { controller.addNode(operationID: $0) }
            )
            .frame(width: WorkflowCanvasLayoutPolicy.libraryWidth)

            Divider()

            WorkflowGraphSurface(
                controller: controller,
                graph: controller.graph,
                zoom: $zoom,
                pendingConnection: $pendingConnection,
                readOnly: isReadOnly,
                onPlan: presentPlan
            )
            .frame(minWidth: WorkflowCanvasLayoutPolicy.canvasMinimumWidth,
                   maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            WorkflowNodeInspector(
                controller: controller,
                node: controller.selectedNode,
                readOnly: isReadOnly,
                onTextModel: guarded(onTextModel),
                onImageModel: guarded(onImageModel),
                onImport: { nodeID in guard !isReadOnly else { return }; onImport(nodeID) },
                onReturnText: { reference in guard !isReadOnly else { return }; onReturnText(reference) },
                onPlan: presentPlan
            )
            .frame(width: WorkflowCanvasLayoutPolicy.inspectorWidth)
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
            Picker(workflowText(languageStore, "workflow.toolbar.graph", fallback: "流程"), selection: graphSelection) {
                Text(workflowText(languageStore, "workflow.toolbar.noGraph", fallback: "未选择流程"))
                    .tag(Optional<UUID>.none)
                ForEach(controller.graphs) { graph in
                    Text(graph.name).tag(Optional(graph.id))
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .accessibilityLabel(workflowText(languageStore, "workflow.toolbar.graph", fallback: "流程"))
            .accessibilityIdentifier("workflow-graph-picker")

            Menu(workflowText(languageStore, "workflow.toolbar.addExample", fallback: "添加样例"),
                 systemImage: "square.grid.2x2") {
                ForEach(WorkflowExampleChoice.allCases) { example in
                    Button(example.title(languageStore)) { controller.addExample(example.rawValue) }
                }
            }
            .disabled(isReadOnly)

            Button(workflowText(languageStore, "workflow.action.save", fallback: "保存"),
                   systemImage: "square.and.arrow.down") {
                Task { await controller.save() }
            }
            .disabled(isReadOnly || controller.isSaving)
            .accessibilityIdentifier("workflow-save")

            Button(workflowText(languageStore, "workflow.action.undo", fallback: "撤销"),
                   systemImage: "arrow.uturn.backward") { controller.undo() }
                .labelStyle(.iconOnly)
                .disabled(isReadOnly || !controller.canUndo)
                .accessibilityIdentifier("workflow-undo")
            Button(workflowText(languageStore, "workflow.action.redo", fallback: "重做"),
                   systemImage: "arrow.uturn.forward") { controller.redo() }
                .labelStyle(.iconOnly)
                .disabled(isReadOnly || !controller.canRedo)
                .accessibilityIdentifier("workflow-redo")

            Divider().frame(height: 20)

            Menu(workflowText(languageStore, "workflow.toolbar.models", fallback: "模型"), systemImage: "cube") {
                Button(workflowText(languageStore, "workflow.action.chooseTextModel", fallback: "选择文字模型")) {
                    guarded(onTextModel)()
                }
                    .disabled(isReadOnly)
                Text(controller.textModelDescription)
                Divider()
                Button(workflowText(languageStore, "workflow.action.chooseImageModel", fallback: "选择图像模型")) {
                    guarded(onImageModel)()
                }
                    .disabled(isReadOnly)
                Text(controller.imageModelDescription)
            }

            Button(workflowText(languageStore, "workflow.action.publishText", fallback: "发布文稿"),
                   systemImage: "text.badge.checkmark") { guarded(onPublishText)() }
                .disabled(isReadOnly)
                .accessibilityIdentifier("workflow-publish-text")

            Button(workflowText(languageStore, "workflow.action.exportDirectory", fallback: "导出目录"),
                   systemImage: "folder.badge.plus") { guarded(onDestination)() }
                .disabled(isReadOnly)
                .accessibilityIdentifier("workflow-destination")
                .help(controller.destinationDescription)
            Text(controller.destinationDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)

            Spacer(minLength: 8)

            if controller.isRunning {
                Button(workflowText(languageStore, "workflow.action.cancel", fallback: "取消"),
                       systemImage: "stop.fill", role: .destructive) {
                    Task { await controller.cancel() }
                }
                .disabled(isReadOnly)
                .accessibilityIdentifier("workflow-cancel")
            }

            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Slider(value: $zoom, in: WorkflowCanvasLayoutPolicy.zoomRange)
                    .frame(width: 90)
                    .accessibilityLabel(workflowText(languageStore, "workflow.toolbar.zoom", fallback: "画布缩放"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: WorkflowCanvasLayoutPolicy.minimumWorkspaceWidth)
        }
        // The content needs 1100 points; the viewport must still accept the window's width.
        .frame(minWidth: 0, maxWidth: .infinity)
        .scrollIndicators(.hidden)
        .background(.bar)
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

    private var graphSelection: Binding<UUID?> {
        Binding(get: { controller.selectedGraphID }, set: { controller.selectedGraphID = $0 })
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
            runPreview = WorkflowRunPreview(nodeID: nodeID, only: only, lines: lines)
        } catch {
            controller.errorMessage = error.localizedDescription
        }
    }
}

private struct WorkflowOperationLibrary: View {
    let registry: WorkflowRegistry
    @Binding var query: String
    let readOnly: Bool
    let onAdd: (String) -> Void
    @Environment(\.dLanguageStore) private var languageStore

    private var definitions: [WorkflowOperationDefinition] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return registry.definitions
            .filter {
                needle.isEmpty ||
                    WorkflowCanvasPresentation.operationTitle($0, language: languageStore)
                        .localizedCaseInsensitiveContains(needle) ||
                    $0.id.localizedCaseInsensitiveContains(needle) ||
                    WorkflowCanvasPresentation.operationDetail($0, language: languageStore)
                        .localizedCaseInsensitiveContains(needle)
            }
            .sorted {
                WorkflowCanvasPresentation.operationTitle($0, language: languageStore)
                    .localizedStandardCompare(WorkflowCanvasPresentation.operationTitle($1, language: languageStore))
                    == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(workflowText(languageStore, "workflow.library.title", fallback: "操作")).font(.headline)
            TextField(workflowText(languageStore, "workflow.library.search", fallback: "搜索操作"), text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workflow-operation-search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if definitions.isEmpty {
                        ContentUnavailableView(
                            workflowText(languageStore, "workflow.library.noMatches", fallback: "没有匹配的操作"),
                            systemImage: "magnifyingglass"
                        )
                            .padding(.vertical, 20)
                    }
                    ForEach(definitions) { definition in
                        Button {
                            onAdd(definition.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(WorkflowCanvasPresentation.operationTitle(definition, language: languageStore))
                                        .font(.callout.weight(.semibold))
                                    Spacer(minLength: 4)
                                    Image(systemName: "plus.circle")
                                }
                                Text(WorkflowCanvasPresentation.operationDetail(definition, language: languageStore))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                Text(definition.id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(readOnly)
                        .accessibilityIdentifier("workflow-add-\(definition.id)")
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }
}

private struct WorkflowGraphSurface: View {
    let controller: WorkflowController
    let graph: WorkflowGraph?
    @Binding var zoom: CGFloat
    @Binding var pendingConnection: WorkflowPendingConnection?
    let readOnly: Bool
    let onPlan: (UUID, Bool) -> Void
    @Environment(\.dLanguageStore) private var languageStore
    @GestureState private var gestureScale: CGFloat = 1

    var body: some View {
        Group {
            if let graph {
                let geometry = WorkflowGraphGeometry(graph: graph)
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
                                definition: controller.registry.operation(node.operationID)?.definition,
                                zoom: effectiveZoom,
                                pendingConnection: $pendingConnection,
                                readOnly: readOnly,
                                selected: controller.selectedNodeID == node.id,
                                onPlan: onPlan
                            )
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
                            )).font(.caption.weight(.medium))
                            Text(WorkflowCanvasPresentation.portDetail(port, language: languageStore))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: input ? .leading : .trailing)
                        if !input { portDot(input: false) }
                    }
                }
                .buttonStyle(.plain)
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

private struct WorkflowNodeInspector: View {
    let controller: WorkflowController
    let node: WorkflowNode?
    let readOnly: Bool
    let onTextModel: () -> Void
    let onImageModel: () -> Void
    let onImport: (UUID) -> Void
    let onReturnText: (WorkflowAssetReference) -> Void
    let onPlan: (UUID, Bool) -> Void
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        ScrollView {
            if let node {
                VStack(alignment: .leading, spacing: 16) {
                    identity(node)
                    parameters(node)
                    ports(node)
                    execution(node)
                    history(node)
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
    }

    @ViewBuilder
    private func identity(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.node", fallback: "节点")) {
            Text(node.title).font(.title3.weight(.semibold))
            WorkflowMetadataRow(workflowText(languageStore, "workflow.metadata.operation", fallback: "操作"),
                                node.operationID)
            WorkflowMetadataRow(workflowText(languageStore, "workflow.metadata.definitionVersion", fallback: "定义版本"),
                                String(node.definitionVersion))
            HStack {
                Button(workflowText(languageStore, "workflow.action.copy", fallback: "复制"),
                       systemImage: "doc.on.doc") { controller.copySelected() }
                Button(workflowText(languageStore, "workflow.action.delete", fallback: "删除"),
                       systemImage: "trash", role: .destructive) { controller.deleteSelected() }
            }
            .disabled(readOnly)
            if node.operationID == "d.asset.reference" {
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
            }
            if let asset = node.assetReference {
                WorkflowAssetIdentity(reference: asset)
            }
        }
    }

    @ViewBuilder
    private func parameters(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection(workflowText(languageStore, "workflow.section.parameters", fallback: "参数")) {
            if let definition = controller.registry.operation(node.operationID)?.definition {
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
                        modelPicker: modelPicker(for: node.operationID),
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
            if let definition = controller.registry.operation(node.operationID)?.definition {
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
            HStack {
                Button(workflowText(languageStore, "workflow.action.runToHere", fallback: "运行到这里")) {
                    onPlan(node.id, false)
                }.buttonStyle(.borderedProminent)
                Button(workflowText(languageStore, "workflow.action.rerunOnly", fallback: "仅重跑本步")) {
                    onPlan(node.id, true)
                }
            }
            .disabled(readOnly)

            if let step = controller.latestStep(for: node.id) {
                HStack {
                    WorkflowStatusBadge(status: step.status, stale: controller.isStale(step))
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
                    WorkflowWaitingDecision(controller: controller, step: step, readOnly: readOnly, preview: controller.preview)
                        .id(step.id)
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
            let related = controller.runs.filter { run in run.steps.contains { $0.node.id == node.id } }
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
                    if WorkflowCanvasPresentation.canResume(run.status) {
                        Button(workflowText(languageStore, "workflow.action.resume", fallback: "恢复")) {
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

    private func modelPicker(for operationID: String) -> () -> Void {
        operationID.hasPrefix("d.image.") ? onImageModel : onTextModel
    }
}

private struct WorkflowFieldEditor: View {
    let field: WorkflowFieldDefinition
    let operationID: String
    let value: WorkflowScalar
    let readOnly: Bool
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
                    Button(workflowText(languageStore, "workflow.action.chooseModel", fallback: "选择模型"),
                           action: modelPicker).disabled(readOnly)
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
                ForEach(choices, id: \.self) { Text($0).tag($0) }
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

private struct WorkflowAssetPreview: View {
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
            case .images, .receipt:
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
                let bytes = try await controller.preview(reference)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(workflowText(languageStore, "workflow.decision.title", fallback: "等待人工决定"))
                .font(.headline)
            if step.node.operationID == "d.text.confirm" {
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
            } else if step.node.operationID == "d.asset.choose" {
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
        guard !decisionDisabled, !accept || step.node.operationID != "d.text.confirm" || textReady else { return }
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

private struct WorkflowStatusBadge: View {
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

private struct WorkflowPendingConnection: Equatable {
    let nodeID: UUID
    let port: String
}

private struct WorkflowRunPreview: Identifiable {
    let id = UUID()
    let nodeID: UUID
    let only: Bool
    let lines: [String]
}

struct WorkflowGraphGeometry {
    let graph: WorkflowGraph
    let translation: CGSize
    let size: CGSize

    init(graph: WorkflowGraph) {
        self.graph = graph
        let raw = graph.nodes.enumerated().map { index, node in
            Self.rawPosition(node.id, index: index, graph: graph)
        }
        let minimumX = raw.map(\.x).min() ?? 0
        let minimumY = raw.map(\.y).min() ?? 0
        translation = CGSize(width: max(0, 150 - minimumX), height: max(0, 110 - minimumY))
        let maximumX = raw.map(\.x).max() ?? 0
        let maximumY = raw.map(\.y).max() ?? 0
        size = CGSize(width: max(1_400, maximumX + translation.width + 320),
                      height: max(900, maximumY + translation.height + 260))
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

enum WorkflowCanvasLayoutPolicy {
    static let minimumVisibleWidth: CGFloat = 760
    static let minimumVisibleHeight: CGFloat = 560
    static let minimumWorkspaceWidth: CGFloat = 1_100
    static let libraryWidth: CGFloat = 220
    static let inspectorWidth: CGFloat = 340
    static let canvasMinimumWidth: CGFloat = 540
    static let nodeWidth: CGFloat = 240
    static let zoomRange: ClosedRange<CGFloat> = 0.5...1.8

    static func usesHorizontalPanelScroll(width: CGFloat) -> Bool { width < minimumWorkspaceWidth }

    static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, value))
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
        switch kind { case .text: "文字"; case .image: "图像"; case .images: "图像集合"; case .receipt: "导出回执" }
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
        workflowText(language, "workflow.operation.\(definition.id).title", fallback: definition.title)
    }

    @MainActor static func operationDetail(
        _ definition: WorkflowOperationDefinition,
        language: UILanguageStore?
    ) -> String {
        workflowText(language, "workflow.operation.\(definition.id).detail", fallback: definition.detail)
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
