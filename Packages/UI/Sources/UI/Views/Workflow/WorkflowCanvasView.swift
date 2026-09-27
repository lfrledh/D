import AppKit
import DWorkbench
import Foundation
import SwiftUI

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
    private let onDestination: () -> Void
    private let onPublishText: () -> Void
    private let onReturnText: (WorkflowAssetReference) -> Void
    private var nodeSizeObserver: ((UUID, CGSize) -> Void)?

    // Read-only layout observation; never rewrites stored node positions.
    func observingNodeSizes(_ observer: @escaping (UUID, CGSize) -> Void) -> Self {
        var copy = self; copy.nodeSizeObserver = observer; return copy
    }

    @Environment(\.dLanguageStore) private var languageStore

    @State private var showNodes = true
    @State private var showAssets = true
    @State private var showInspector = true
    @State private var zoom: CGFloat = 1
    @State private var pendingConnection: WorkflowPendingConnection?
    @State private var runPreview: WorkflowRunPreview?
    @State private var toolsPresented = false
    @State private var interfacePresented = false

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
        onDropFile: @escaping (URL) -> Bool = { _ in false }
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
                panels(height: proxy.size.height)
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
                    Task { await controller.run(target: preview.nodeID, only: preview.only) }
                }
            )
        }
        .sheet(isPresented: $toolsPresented) { WorkflowToolPanel(controller: controller) }
        .sheet(isPresented: $interfacePresented) {
            if let graph = controller.graph {
                ScrollView { WorkflowGraphInterfaceEditor(graph: Binding(get: { controller.graph?.id == graph.id ? controller.graph! : graph }, set: { controller.updateInterface($0.interface, in: graph.id) }), registry: controller.registry, tools: controller.tools).padding() }
                    .frame(minWidth: 640, minHeight: 500)
            }
        }
        .onChange(of: controller.graph?.id) { _, _ in
            pendingConnection = nil
            runPreview = nil
        }
    }

    private func panels(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            if showNodes {
                WorkflowNodeLibrary(controller: controller, tagStore: nodeTags) { entry in
                    controller.addNode(operationID: entry.operation.id, modelID: entry.model?.id)
                    showInspector = true
                }.frame(width: WorkflowCanvasLayoutPolicy.libraryWidth)
                Divider()
            }
            VStack(spacing: 0) {
                WorkflowGraphSurface(controller: controller, graph: controller.graph, zoom: $zoom,
                    pendingConnection: $pendingConnection, readOnly: !controller.canEditCanvas,
                    onPlan: presentPlan, nodeSizeObserver: nodeSizeObserver,
                    onDropItem: dropItem,
                    onBindAsset: { project, asset, node in
                        guard controller.canEditCanvas, controller.projectID == project,
                              let target = controller.assetBindingTarget(nodeID: node) else { return false }
                        Task { await controller.bindLibraryAsset(projectID: project, assetID: asset, target: target) }
                        return true
                    }, onInspect: { id in
                        guard controller.graph?.nodes.contains(where: { $0.id == id }) == true else { return }
                        controller.selectedNodeID = id; showInspector = true
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Button { showInspector.toggle() } label: {
                        Label(workflowText(languageStore, "canvas.inspector.title", fallback: "节点参数与结果"),
                              systemImage: showInspector ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain).accessibilityIdentifier("canvas-inspector-toggle")
                    Text(controller.selectedNode?.title ?? workflowText(languageStore, "canvas.inspector.hint", fallback: "选中节点后在此编辑"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }.padding(9).background(.bar)
                // Mounted while folded: local form drafts and marked text are not recreated.
                WorkflowNodeInspector(controller: controller, node: controller.selectedNode,
                    readOnly: isReadOnly, onTextModel: guarded(onTextModel), onImageModel: guarded(onImageModel),
                    onAdditionalModel: { kind in guarded { onAdditionalModel(kind) }() },
                    onImport: { id in guard !isReadOnly else { return }; onImport(id) },
                    onRecord: { id in guard !isReadOnly else { return }; onRecord(id) },
                    onReturnText: { ref in guard !isReadOnly else { return }; onReturnText(ref) }, onPlan: presentPlan)
                    .frame(height: showInspector ? min(260, max(150, height * 0.42)) : 0)
                    .clipped().allowsHitTesting(showInspector).accessibilityHidden(!showInspector)
            }.frame(minWidth: WorkflowCanvasLayoutPolicy.canvasMinimumWidth, maxWidth: .infinity)
            if showAssets {
                Divider()
                WorkflowAssetLibrary(controller: controller, onAdd: { project, asset in
                    if controller.graph == nil { controller.addBlankGraph() }
                    guard let target = controller.canvasInsertionTarget() else { return }
                    Task { await controller.addAssetNode(projectID: project, assetID: asset, x: 180, y: 160, target: target) }
                }, onImport: onImportAsset, onDropFile: onDropFile).frame(width: WorkflowCanvasLayoutPolicy.libraryWidth)
            }
        }
    }

    private func dropItem(_ value: WorkflowCanvasTransfer, _ point: CGPoint) -> Bool {
        guard controller.canEditCanvas else { return false }
        switch value {
        case .operation(let id, let model):
            guard controller.registry.operation(id) != nil else { return false }
            controller.addNode(operationID: id, modelID: model, x: point.x, y: point.y)
            showInspector = true; return controller.errorMessage == nil
        case .asset(let project, let asset):
            guard controller.projectID == project, controller.availableAssets.contains(where: { $0.id == asset }) else { return false }
            if controller.graph == nil { controller.addBlankGraph() }
            guard let target = controller.canvasInsertionTarget() else { return false }
            Task { await controller.addAssetNode(projectID: project, assetID: asset, x: point.x, y: point.y, target: target) }
            return true
        case .output: return false
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
                ForEach(WorkflowLanguageExample.allCases, id: \.rawValue) { example in
                    Button(workflowText(languageStore, "workflow.language.example.\(example.rawValue)", fallback:
                        ["data": "数据与控制", "images": "主题与图像批次", "music": "哼唱与和声", "multimodal": "同源四模态"][example.rawValue] ?? example.rawValue)) {
                        controller.addLanguageExample(example)
                    }
                }
                Divider()
                ForEach(WorkflowExampleChoice.allCases) { example in
                    Button(example.title(languageStore)) { controller.addExample(example.rawValue) }
                }
            }
            .disabled(isReadOnly)

            Button(workflowText(languageStore, "canvas.new", fallback: "新流程"), systemImage: "plus") { controller.addBlankGraph() }
                .disabled(!controller.canEditCanvas).accessibilityIdentifier("canvas-new-flow")
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

            if !controller.bodyPath.isEmpty {
                Button(workflowText(languageStore, "workflow.language.control.back", fallback: "返回外层"), systemImage: "arrow.up.backward") { controller.closeBody() }
                Text(controller.graph?.name ?? "").font(.caption)
            }
            Menu(workflowText(languageStore, "canvas.more", fallback: "更多"), systemImage: "ellipsis.circle") {
                Button(workflowText(languageStore, "workflow.language.tools", fallback: "工具与封装")) { toolsPresented = true }
                Button(workflowText(languageStore, "workflow.language.interface", fallback: "公开接口")) { interfacePresented = true }
                    .disabled(controller.graph == nil)
                Divider()
                Button(workflowText(languageStore, "workflow.action.publishText", fallback: "发布文稿")) { guarded(onPublishText)() }
                Button(workflowText(languageStore, "workflow.action.exportDirectory", fallback: "导出目录")) { guarded(onDestination)() }
                Text(controller.destinationDescription)
            }.disabled(isReadOnly)
            Toggle(isOn: $showNodes) { Image(systemName: "sidebar.left") }.toggleStyle(.button)
                .help(workflowText(languageStore, "canvas.library.nodes", fallback: "节点库"))
            Toggle(isOn: $showAssets) { Image(systemName: "sidebar.right") }.toggleStyle(.button)
                .help(workflowText(languageStore, "canvas.assets.title", fallback: "资产库"))

            Spacer(minLength: 8)

            if controller.isRunning {
                Button(workflowText(languageStore, "workflow.language.control.pause", fallback: "安全暂停"), systemImage: "pause") { controller.pause() }
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
            .frame(minWidth: 0)
        }
        // Only the compact toolbar may scroll; sidebars stay inside the window.
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
    @Environment(\.dLanguageStore) private var languageStore
    @State private var scopePresentation: WorkflowScopePresentation?
    @State private var pendingCall: WorkflowCallReference?

    var body: some View {
        ScrollView {
            if let node {
                VStack(alignment: .leading, spacing: 16) {
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
                            if slot == "tool", case .invoke(let reference) = node.control { controller.openToolCopy(reference) }
                            else { controller.openBody(nodeID: node.id, slot: slot) }
                        }).id(node.id).disabled(readOnly)
                    }
                    ports(node)
                    execution(node)
                    if controller.bodyPath.isEmpty {
                        Button(workflowText(languageStore, "workflow.scope.title", fallback: "选择运行范围与历史输入")) {
                            if let graph = controller.rootGraph { scopePresentation = .init(graph: graph, nodeID: node.id) }
                        }
                            .disabled(readOnly)
                    }
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
        .sheet(item: $scopePresentation) { request in
            WorkflowScopePanel(controller: controller, graphID: request.graphID, revision: request.revision, nodeID: request.nodeID)
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
            let related = controller.history(for: node.id)
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
                            if call.step.id != controller.latestStep(for: node.id)?.id, call.step.status == .waiting {
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
}

private struct WorkflowRunPreview: Identifiable {
    let id = UUID()
    let nodeID: UUID
    let only: Bool
    let lines: [String]
}

enum WorkflowCanvasLayoutPolicy {
    static let minimumVisibleWidth: CGFloat = 760
    static let minimumVisibleHeight: CGFloat = 560
    static let minimumWorkspaceWidth: CGFloat = 760
    static let libraryWidth: CGFloat = 220
    static let inspectorWidth: CGFloat = 340
    static let canvasMinimumWidth: CGFloat = 260
    static let nodeWidth: CGFloat = 240
    static let zoomRange: ClosedRange<CGFloat> = 0.5...1.8

    static func usesHorizontalPanelScroll(width: CGFloat) -> Bool { false }

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
