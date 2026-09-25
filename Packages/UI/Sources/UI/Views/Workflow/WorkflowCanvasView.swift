import AppKit
import DWorkbench
import Foundation
import SwiftUI

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
        VStack(spacing: 0) {
            toolbar
            Divider()
            statusStrip
            Divider()
            GeometryReader { proxy in
                let narrow = WorkflowCanvasLayoutPolicy.usesHorizontalPanelScroll(width: proxy.size.width)
                Group {
                    if narrow {
                        ScrollView(.horizontal) {
                            panels
                                .frame(width: WorkflowCanvasLayoutPolicy.minimumWorkspaceWidth,
                                       height: proxy.size.height)
                        }
                    } else {
                        panels
                    }
                }
                .accessibilityIdentifier("workflow-canvas-workspace")
            }
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
            Picker("流程", selection: graphSelection) {
                Text("未选择流程").tag(Optional<UUID>.none)
                ForEach(controller.graphs) { graph in
                    Text(graph.name).tag(Optional(graph.id))
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .accessibilityLabel("流程")
            .accessibilityIdentifier("workflow-graph-picker")

            Menu("添加样例", systemImage: "square.grid.2x2") {
                ForEach(WorkflowExampleChoice.allCases) { example in
                    Button(example.title) { controller.addExample(example.rawValue) }
                }
            }
            .disabled(isReadOnly)

            Button("保存", systemImage: "square.and.arrow.down") {
                Task { await controller.save() }
            }
            .disabled(isReadOnly || controller.isSaving)
            .accessibilityIdentifier("workflow-save")

            Button("撤销", systemImage: "arrow.uturn.backward") { controller.undo() }
                .labelStyle(.iconOnly)
                .disabled(isReadOnly || !controller.canUndo)
                .accessibilityIdentifier("workflow-undo")
            Button("重做", systemImage: "arrow.uturn.forward") { controller.redo() }
                .labelStyle(.iconOnly)
                .disabled(isReadOnly || !controller.canRedo)
                .accessibilityIdentifier("workflow-redo")

            Divider().frame(height: 20)

            Menu("模型", systemImage: "cube") {
                Button("选择文字模型") { guarded(onTextModel)() }
                    .disabled(isReadOnly)
                Text(controller.textModelDescription)
                Divider()
                Button("选择图像模型") { guarded(onImageModel)() }
                    .disabled(isReadOnly)
                Text(controller.imageModelDescription)
            }

            Button("发布文稿", systemImage: "text.badge.checkmark") { guarded(onPublishText)() }
                .disabled(isReadOnly)
                .accessibilityIdentifier("workflow-publish-text")

            Button("导出目录", systemImage: "folder.badge.plus") { guarded(onDestination)() }
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
                Button("取消", systemImage: "stop.fill", role: .destructive) {
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
                    .accessibilityLabel("画布缩放")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: WorkflowCanvasLayoutPolicy.minimumWorkspaceWidth)
        }
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
                Text("正在保存")
            } else if controller.isRunning {
                ProgressView().controlSize(.small)
                Text(controller.progressMessage.isEmpty ? "正在运行" : controller.progressMessage)
            } else if !controller.progressMessage.isEmpty {
                Text(controller.progressMessage).foregroundStyle(.secondary)
            }
            Spacer()
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityIdentifier("workflow-error")
                Button("关闭", systemImage: "xmark") { controller.errorMessage = nil }
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

    private var definitions: [WorkflowOperationDefinition] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return registry.definitions
            .filter { needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle) ||
                $0.id.localizedCaseInsensitiveContains(needle) || $0.detail.localizedCaseInsensitiveContains(needle) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("操作").font(.headline)
            TextField("搜索操作", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workflow-operation-search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if definitions.isEmpty {
                        ContentUnavailableView("没有匹配的操作", systemImage: "magnifyingglass")
                            .padding(.vertical, 20)
                    }
                    ForEach(definitions) { definition in
                        Button {
                            onAdd(definition.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(definition.title).font(.callout.weight(.semibold))
                                    Spacer(minLength: 4)
                                    Image(systemName: "plus.circle")
                                }
                                Text(definition.detail)
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
                            Label("已选择输出 \(pendingConnection.port)，请选择目标输入", systemImage: "link")
                            Button("取消连接") { self.pendingConnection = nil }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                    }
                }
            } else {
                ContentUnavailableView("选择或添加流程", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("流程只会在明确保存或运行时提交。"))
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
    @GestureState private var translation = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.headline).lineLimit(2)
                    Text(node.operationID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let step = controller.latestStep(for: node.id) {
                    WorkflowStatusBadge(status: step.status, stale: controller.isStale(step))
                }
            }

            if let definition {
                portRows(definition.inputs, input: true)
                Divider()
                portRows(definition.outputs, input: false)
            } else {
                Label("未知操作或版本；流程保持只读", systemImage: "questionmark.diamond")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 6) {
                Button("运行到这里") { onPlan(node.id, false) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("仅重跑本步") { onPlan(node.id, true) }
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
            Text(input ? "无输入" : "无输出")
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
                            Text(port.title).font(.caption.weight(.medium))
                            Text(WorkflowCanvasPresentation.portDetail(port))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: input ? .leading : .trailing)
                        if !input { portDot(input: false) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(readOnly || (input && pendingConnection == nil))
                .accessibilityLabel("\(input ? "输入" : "输出")端口，\(port.title)，\(WorkflowCanvasPresentation.portDetail(port))")
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
                ContentUnavailableView("选择节点", systemImage: "sidebar.right",
                                       description: Text("检查参数、端口、输入身份、结果和运行历史。"))
                    .padding(.top, 36)
            }
        }
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("workflow-inspector")
    }

    @ViewBuilder
    private func identity(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection("节点") {
            Text(node.title).font(.title3.weight(.semibold))
            WorkflowMetadataRow("操作", node.operationID)
            WorkflowMetadataRow("定义版本", String(node.definitionVersion))
            HStack {
                Button("复制", systemImage: "doc.on.doc") { controller.copySelected() }
                Button("删除", systemImage: "trash", role: .destructive) { controller.deleteSelected() }
            }
            .disabled(readOnly)
            if node.operationID == "d.asset.reference" {
                Button("选择导入资产", systemImage: "square.and.arrow.down") { onImport(node.id) }
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
        WorkflowInspectorSection("参数") {
            if let definition = controller.registry.operation(node.operationID)?.definition {
                if definition.fields.isEmpty {
                    Text("此操作没有参数。").foregroundStyle(.secondary)
                }
                ForEach(definition.fields) { field in
                    WorkflowFieldEditor(
                        field: field,
                        value: node.parameters[field.id] ?? field.defaultValue,
                        readOnly: readOnly,
                        modelPicker: modelPicker(for: node.operationID),
                        onChange: { controller.setParameter(nodeID: node.id, key: field.id, value: $0) }
                    )
                }
            } else {
                Text("未知操作或定义版本，参数保持原样且不可编辑。")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func ports(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection("输入与输出") {
            if let definition = controller.registry.operation(node.operationID)?.definition {
                Text("输入").font(.subheadline.weight(.semibold))
                if definition.inputs.isEmpty { Text("无输入").foregroundStyle(.secondary) }
                ForEach(definition.inputs) { port in
                    let incoming = controller.graph?.connections.filter {
                        $0.targetNode == node.id && $0.targetPort == port.id
                    } ?? []
                    VStack(alignment: .leading, spacing: 5) {
                        Text(port.title).font(.callout.weight(.medium))
                        Text(WorkflowCanvasPresentation.portDetail(port))
                            .font(.caption).foregroundStyle(.secondary)
                        if incoming.isEmpty {
                            Text(port.required ? "尚未连接" : "未提供")
                                .font(.caption)
                                .foregroundStyle(port.required ? Color.orange : Color.secondary)
                        }
                        ForEach(incoming) { connection in
                            HStack {
                                Text(WorkflowCanvasPresentation.connectionIdentity(connection))
                                    .font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Button("断开", systemImage: "link.badge.minus") {
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
                Text("输出").font(.subheadline.weight(.semibold)).padding(.top, 4)
                if definition.outputs.isEmpty { Text("无输出").foregroundStyle(.secondary) }
                ForEach(definition.outputs) { port in
                    HStack {
                        Text(port.title)
                        Spacer()
                        Text(WorkflowCanvasPresentation.portDetail(port))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func execution(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection("运行与结果") {
            HStack {
                Button("运行到这里") { onPlan(node.id, false) }.buttonStyle(.borderedProminent)
                Button("仅重跑本步") { onPlan(node.id, true) }
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
                WorkflowStepValues(title: "输入快照", values: step.inputs,
                                   controller: controller, onReturnText: onReturnText,
                                   allowsReturn: false)
                WorkflowStepValues(title: "输出", values: step.outputs,
                                   controller: controller, onReturnText: onReturnText,
                                   allowsReturn: !readOnly)
                if step.status == .waiting {
                    WorkflowWaitingDecision(controller: controller, step: step, readOnly: readOnly)
                }
                if step.status == .partial {
                    Button("重试失败候选", systemImage: "arrow.clockwise") {
                        Task { await controller.retryFailedCandidates(stepID: step.id) }
                    }
                    .disabled(readOnly)
                }
            } else {
                Text("此节点尚无运行记录。").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func history(_ node: WorkflowNode) -> some View {
        WorkflowInspectorSection("运行历史") {
            let related = controller.runs.filter { run in run.steps.contains { $0.node.id == node.id } }
            if related.isEmpty {
                Text("没有历史运行。" ).foregroundStyle(.secondary)
            }
            ForEach(related.reversed()) { run in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                        Spacer()
                        Text(run.status.title).foregroundStyle(.secondary)
                    }
                    Text(run.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    if WorkflowCanvasPresentation.canResume(run.status) {
                        Button("恢复") { Task { await controller.resume(runID: run.id) } }
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
    let value: WorkflowScalar
    let readOnly: Bool
    let modelPicker: () -> Void
    let onChange: (WorkflowScalar) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(field.title).font(.callout.weight(.medium))
            if field.id == "modelID" {
                HStack {
                    Text(value.string.flatMap { $0.isEmpty ? nil : $0 } ?? "尚未绑定")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择模型", action: modelPicker).disabled(readOnly)
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
                TextField(field.title, text: textBinding).disabled(readOnly)
            }
        case .integer:
            TextField(field.title, value: integerBinding, format: .number).disabled(readOnly)
        case .decimal:
            TextField(field.title, value: decimalBinding, format: .number).disabled(readOnly)
        case .flag:
            Toggle(field.title, isOn: flagBinding).labelsHidden().disabled(readOnly)
        case .choice(let choices):
            Picker(field.title, selection: textBinding) {
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
    let controller: WorkflowController
    let onReturnText: (WorkflowAssetReference) -> Void
    let allowsReturn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if values.isEmpty { Text("无").foregroundStyle(.secondary) }
            ForEach(values.keys.sorted(), id: \.self) { port in
                if let value = values[port] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(port).font(.caption.monospaced()).foregroundStyle(.secondary)
                        switch value {
                        case .asset(let reference):
                            WorkflowAssetPreview(controller: controller, reference: reference)
                            WorkflowAssetIdentity(reference: reference)
                            if reference.kind == .text && allowsReturn {
                                Button("回到文稿", systemImage: "arrowshape.turn.up.backward") {
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

    var body: some View {
        Group {
            switch reference.kind {
            case .text:
                if let data {
                    if let text = String(data: data, encoding: .utf8) {
                        ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 150)
                    } else {
                        previewError("文字预览不是有效的 UTF-8。")
                    }
                } else if let failure { previewError(failure) } else { ProgressView() }
            case .image:
                if let data {
                    if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                    } else {
                        previewError("图像预览无法解码。")
                    }
                } else if let failure { previewError(failure) } else { ProgressView() }
            case .images, .receipt:
                Text("此引用不能作为单项预览。" ).foregroundStyle(.secondary)
            }
        }
        .task(id: reference.version) {
            data = nil
            failure = nil
            do {
                data = try await controller.preview(reference)
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

    var body: some View {
        Button {
            onSelect?()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let asset = candidate.asset {
                    WorkflowAssetPreview(controller: controller, reference: asset)
                }
                HStack {
                    Text("seed \(candidate.seed)").font(.caption.monospaced())
                    Spacer()
                    if selected { Label("已高亮", systemImage: "checkmark.circle.fill") }
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

private struct WorkflowWaitingDecision: View {
    let controller: WorkflowController
    let step: WorkflowStepRun
    let readOnly: Bool
    @State private var draft = ""
    @State private var highlightedCandidateID: UUID?
    @State private var acceptPartial = false
    @State private var loadedReference: WorkflowAssetReference?

    private var candidates: [WorkflowCandidate] {
        step.outputs.values.flatMap(\.candidates)
    }

    private var textReference: WorkflowAssetReference? {
        step.outputs.values.compactMap(\.asset).first { $0.kind == .text }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("等待人工决定").font(.headline)
            if step.node.operationID == "d.text.confirm" {
                TextEditor(text: $draft)
                    .frame(minHeight: 100)
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                    .disabled(readOnly)
                    .task(id: textReference?.version) { await loadDraft() }
                HStack {
                    Button("接受文字") { decide(accept: true, text: draft, candidateID: nil) }
                        .buttonStyle(.borderedProminent)
                    Button("拒绝", role: .destructive) { decide(accept: false, text: nil, candidateID: nil) }
                }
                .disabled(readOnly)
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
                    Toggle("接受部分成功的候选", isOn: $acceptPartial).disabled(readOnly)
                }
                HStack {
                    Button("采用高亮候选") {
                        decide(accept: true, text: nil, candidateID: highlightedCandidateID)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(readOnly || highlightedCandidateID == nil ||
                              (candidates.contains { $0.error != nil } && !acceptPartial))
                    Button("拒绝", role: .destructive) { decide(accept: false, text: nil, candidateID: nil) }
                        .disabled(readOnly)
                }
            } else {
                Text("此步骤等待明确决定。" ).foregroundStyle(.secondary)
                Button("拒绝", role: .destructive) { decide(accept: false, text: nil, candidateID: nil) }
                    .disabled(readOnly)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func loadDraft() async {
        guard let reference = textReference, loadedReference != reference else { return }
        do {
            let data = try await controller.preview(reference)
            draft = String(data: data, encoding: .utf8) ?? ""
            loadedReference = reference
        } catch {
            controller.errorMessage = error.localizedDescription
        }
    }

    private func decide(accept: Bool, text: String?, candidateID: UUID?) {
        guard !readOnly else { return }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preview.only ? "确认仅重跑本步" : "确认运行到这里").font(.title2.weight(.semibold))
            Text("以下计划由运行协调器提供；界面原样显示，不推断或改写执行、复用与等待状态。")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let lines = WorkflowCanvasPresentation.planLines(preview.lines)
                    if lines.isEmpty { Text("计划为空").foregroundStyle(.secondary) }
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
                Button("取消", action: onCancel)
                Button("明确提交运行", action: onRun)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WorkflowMetadataRow("类型", WorkflowCanvasPresentation.kind(reference.kind))
            WorkflowMetadataRow("资产", reference.assetID.uuidString)
            WorkflowMetadataRow("版本", reference.version.uuidString)
            WorkflowMetadataRow("SHA-256", reference.sha256)
        }
    }
}

private struct WorkflowStatusBadge: View {
    let status: WorkflowStepStatus
    let stale: Bool
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(WorkflowCanvasPresentation.statusColor(status)).frame(width: 7, height: 7)
            Text(status.title)
            if stale { Text("旧输入").foregroundStyle(.orange) }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

private enum WorkflowExampleChoice: String, CaseIterable, Identifiable {
    case text, image, file, template
    var id: String { rawValue }
    var title: String {
        switch self { case .text: "文字"; case .image: "图文"; case .file: "文件"; case .template: "模板" }
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

    static func portDetail(_ port: WorkflowPortDefinition) -> String {
        "\(port.kinds.map { kind($0) }.joined(separator: "/")) · \(port.required ? "必选" : "可选")"
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
