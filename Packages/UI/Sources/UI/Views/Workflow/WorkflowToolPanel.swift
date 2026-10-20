import DWorkbench
import SwiftUI

@MainActor
struct WorkflowToolPanel: View {
    let controller: WorkflowController
    var selectionOnly = false
    @State private var name = ""
    @State private var purpose = ""
    @State private var detail = ""
    @State private var inputLabels: [String: String] = [:]
    @State private var outputLabels: [String: String] = [:]
    @State private var publishing = false
    @State private var publicationError: String?
    @State private var boundary: ToolBoundaryDraft?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(selectionOnly ? t("selectionTitle", "将选区组合为自定义节点") : t("title", "项目工具箱")).font(.title2)
                if !selectionOnly {
                ForEach(controller.tools, id: \.selfReference) { tool in
                    HStack {
                        Text(tool.name + " · v\(tool.version)")
                        Spacer()
                        Button(t("insert", "插入实例")) { controller.addTool(tool); dismiss() }.disabled(!controller.canEditCanvas)
                        Button(t("copy", "展开为编辑副本")) {
                            guard let digest = try? WorkflowPlanCompiler.digest(tool) else { return }
                            controller.openToolCopy(.init(id: tool.id, version: tool.version, digest: digest)); dismiss()
                        }.disabled(!controller.canEditCanvas)
                    }
                }
                Divider()
                TextField(t("name", "新工具名称"), text: $name)
                TextField(t("purpose", "一句话说明用途（必填）"), text: $purpose)
                TextField(t("detail", "详细说明（可选）"), text: $detail, axis: .vertical).lineLimit(2...5)
                if let graph = controller.graph {
                    Button(t(graph.toolSource == nil ? "publishGraph" : "publishVersion", graph.toolSource == nil ? "保存自定义节点" : "发布新定义版本（旧实例不变）")) {
                        publishing = true; publicationError = nil
                        let registration = WorkflowToolRegistration(purpose: purpose, detail: detail.isEmpty ? nil : detail,
                            inputLabels: inputLabels.filter { label in graph.interface?.inputs.contains(where: { $0.name == label.key }) == true },
                            outputLabels: outputLabels.filter { label in graph.interface?.outputs.contains(where: { $0.name == label.key }) == true })
                        Task {
                            defer { publishing = false }
                            do { try await controller.publishGraphTool(name: name, registration: registration, expectedGraphID: graph.id, expectedRevision: graph.revision); dismiss() }
                            catch { publicationError = error.localizedDescription }
                        }
                    }.disabled(!controller.canEditCanvas || purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    DisclosureGroup(t("dependencies", "内部流程与依赖")) { WorkflowDependencySummary(graph: graph, controller: controller) }
                    if let interface = graph.interface {
                        DisclosureGroup(t("publicParameters", "公开参数与默认值")) {
                            ForEach(interface.inputs, id: \.name) { input in
                                TextField(input.name + " · " + String(describing: input.type), text: Binding(get: { inputLabels[input.name] ?? input.name }, set: { inputLabels[input.name] = $0 }))
                            }
                            ForEach(interface.outputs, id: \.name) { output in
                                TextField(output.name + " · " + String(describing: output.schema), text: Binding(get: { outputLabels[output.name] ?? output.name }, set: { outputLabels[output.name] = $0 }))
                            }
                        }
                    }
                }
                Text(t("fixed", "工具实例固定版本与摘要。编辑副本、另存工具和选择新版本都不会静默改变既有实例。")).font(.caption).foregroundStyle(.secondary)
                Button(t("inspect", "检查选区的跨界输入与输出")) {
                    if let graph = controller.graph { boundary = ToolBoundaryDraft(graph: graph, selected: controller.selectedNodeIDs, registry: controller.registry, tools: controller.tools) }
                }
                .disabled(controller.selectedNodeIDs.isEmpty)
                }
                if let error = controller.errorMessage { Text(error).foregroundStyle(.red) }
                if selectionOnly { TextField(t("name", "新工具名称"), text: $name) }
                if selectionOnly && boundary != nil {
                    TextField(t("purpose", "一句话说明用途（必填）"), text: $purpose)
                    TextField(t("detail", "详细说明（可选）"), text: $detail, axis: .vertical).lineLimit(2...5)
                }
                if let publicationError { Text(publicationError).foregroundStyle(.red) }
                if boundary != nil { boundaryEditor }
                Button(selectionOnly ? t("cancel", "取消") : t("done", "完成")) { dismiss() }.disabled(publishing)
            }.padding(20).disabled(publishing)
        }.frame(minWidth: 680, minHeight: 520)
            .onAppear {
                if name.isEmpty, let graph = controller.graph, let source = graph.toolSource,
                   let tool = controller.tools.first(where: { $0.id == source.id && $0.version == source.version }) {
                    name = tool.name; purpose = tool.registration?.purpose ?? ""; detail = tool.registration?.detail ?? ""
                    inputLabels = tool.registration?.inputLabels ?? [:]; outputLabels = tool.registration?.outputLabels ?? [:]
                }
                if selectionOnly, boundary == nil, let graph = controller.graph {
                    boundary = ToolBoundaryDraft(graph: graph, selected: controller.selectedNodeIDs, registry: controller.registry, tools: controller.tools)
                }
            }
    }
    private func dependencyGraph(_ graph: WorkflowGraph, selected: Set<UUID>) -> WorkflowGraph {
        var result = graph; result.nodes.removeAll { !selected.contains($0.id) }; return result
    }
    @ViewBuilder private var boundaryEditor: some View {
        if let value = boundary {
            Text(t("inputs", "跨界输入（请明确选择类型）")).font(.headline)
            ForEach(value.inputs.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    Text(value.inputs[index].sourceNode.uuidString.prefix(8) + " · " + value.inputs[index].sourcePort).font(.caption)
                    TextField(t("publicName", "公开名称"), text: Binding(get: { inputLabels[value.inputs[index].name] ?? value.inputs[index].name }, set: { inputLabels[value.inputs[index].name] = $0 }))
                    Text(value.inputs[index].name).font(.caption.monospaced()).foregroundStyle(.secondary)
                    WorkflowBoundarySchemaPicker(schema: Binding(get: { boundary?.inputs[index].schema ?? .text }, set: { boundary?.inputs[index].schema = $0 }))
                }
            }
            Text(t("outputs", "公开输出（未勾选的端口不作为工具结果）")).font(.headline)
            ForEach(value.outputs.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    Toggle(value.outputs[index].label, isOn: Binding(get: { boundary?.outputs[index].included ?? false }, set: { boundary?.outputs[index].included = $0 }))
                    TextField(t("publicName", "公开名称"), text: Binding(get: { outputLabels[value.outputs[index].value.name] ?? value.outputs[index].value.name }, set: { outputLabels[value.outputs[index].value.name] = $0 }))
                    WorkflowBoundarySchemaPicker(schema: Binding(get: { boundary?.outputs[index].value.schema ?? .text }, set: { boundary?.outputs[index].value.schema = $0 }))
                }
            }
            DisclosureGroup(t("dependencies", "内部流程与依赖")) {
                if let graph = controller.graph {
                    WorkflowDependencySummary(graph: dependencyGraph(graph, selected: value.selected), controller: controller)
                }
                Text(t("parametersFromInputs", "公开参数沿用类型化输入；未映射的内部参数保持冻结。编辑副本可修改内部流程，再发布新定义版本。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(t("extract", "按此接口封装选区")) {
                guard let draft = boundary, controller.selectedNodeIDs == draft.selected else { controller.errorMessage = t("stale", "选区已改变，请重新检查边界。"); return }
                let outputs = draft.outputs.filter(\.included).map(\.value)
                let registration = WorkflowToolRegistration(purpose: purpose, detail: detail.isEmpty ? nil : detail,
                    inputLabels: inputLabels.filter { key, _ in draft.inputs.contains { $0.name == key } },
                    outputLabels: outputLabels.filter { key, _ in outputs.contains { $0.name == key } })
                publishing = true; publicationError = nil
                Task { @MainActor in
                    defer { publishing = false }
                    do {
                        try await controller.publishSelection(name: name, registration: registration,
                            inputs: draft.inputs, outputs: outputs, expectedGraphID: draft.graphID, expectedRevision: draft.revision)
                        boundary = nil; dismiss()
                    } catch { publicationError = error.localizedDescription }
                }
            }.buttonStyle(WorkbenchPrimaryButtonStyle())
                .disabled(!controller.canEditCanvas || purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !value.activeUnconfirmed.isEmpty)
            if !value.activeUnconfirmed.isEmpty {
                Text(t("unknownType", "部分边界的类型未登记。请明确选择并确认类型，不能把文字当成默认契约。"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(value.activeUnconfirmed.sorted(), id: \.self) { id in
                    Toggle(id + " · " + t("confirmType", "我已确认类型"), isOn: Binding(get: { false }, set: { if $0 { boundary?.unconfirmed.remove(id) } }))
                }
            }
        }
    }
    private func t(_ suffix: String, _ fallback: String) -> String { language?.text("workflow.language.tools." + suffix, fallback: fallback) ?? fallback }
}

private extension WorkflowToolDefinition {
    var selfReference: String { id.uuidString + ":" + String(version) }
}
struct ToolBoundaryDraft {
    struct Output { var included: Bool; var label: String; var value: WorkflowNamedOutput }
    let graphID: UUID
    let revision: UUID
    let selected: Set<UUID>
    var inputs: [WorkflowToolInputBinding]
    var outputs: [Output]
    var unconfirmed: Set<String> = []
    var activeUnconfirmed: Set<String> { unconfirmed.intersection(Set(inputs.map(\.name) + outputs.filter(\.included).map { $0.value.name })) }
    init(graph: WorkflowGraph, selected: Set<UUID>, registry: WorkflowRegistry, tools: [WorkflowToolDefinition]) {
        graphID = graph.id; revision = graph.revision; self.selected = selected
        inputs = []; outputs = []
        for edge in graph.connections where !selected.contains(edge.sourceNode) && selected.contains(edge.targetNode) {
            guard !inputs.contains(where: { $0.sourceNode == edge.sourceNode && $0.sourcePort == edge.sourcePort }) else { continue }
            // A visible initial proposal only. Exact schema is explicitly confirmed in this form.
            let node = graph.nodes.first { $0.id == edge.sourceNode }
            let proposed = node.flatMap { WorkflowToolEditing.outputSchemaProposal(for: $0, port: edge.sourcePort, registry: registry, tools: tools) }
            if proposed == nil { unconfirmed.insert("input\(inputs.count + 1)") }
            let schema = proposed ?? .text
            inputs.append(.init(name: "input\(inputs.count + 1)", schema: schema, sourceNode: edge.sourceNode, sourcePort: edge.sourcePort))
        }
        for node in graph.nodes where selected.contains(node.id) {
            for port in registry.definition(for: node, tools: tools)?.outputs ?? [] {
                let required = graph.connections.contains { $0.sourceNode == node.id && $0.sourcePort == port.id && !selected.contains($0.targetNode) } || graph.interface?.outputs.contains { $0.nodeID == node.id && $0.port == port.id } == true
                let proposed = graph.interface?.outputs.first { $0.nodeID == node.id && $0.port == port.id }?.schema ?? WorkflowToolEditing.outputSchemaProposal(for: node, port: port.id, registry: registry, tools: tools) ?? node.dataConfiguration?.value?.schema ?? node.dataConfiguration?.schema
                if proposed == nil { unconfirmed.insert("output\(outputs.count + 1)") }
                let schema = proposed ?? .text
                outputs.append(.init(included: required, label: node.title + " · " + port.title,
                    value: .init(name: "output\(outputs.count + 1)", nodeID: node.id, port: port.id, schema: schema)))
            }
        }
    }
}

/// Schema editing is metadata, never an invented asset reference.
private struct WorkflowBoundarySchemaPicker: View {
    @Binding var schema: WorkflowDataSchema
    @State private var sample: WorkflowDatum?
    @Environment(\.dLanguageStore) private var language
    init(schema: Binding<WorkflowDataSchema>) { _schema = schema; _sample = State(initialValue: WorkflowControlFormSupport.sample(for: schema.wrappedValue)) }
    private func assetTitle(_ kind: WorkflowDataKind) -> String {
        let asset = language?.text("workflow.language.form.type.asset", fallback: "资产") ?? "资产"
        let name = language?.text("workflow.language.form.assetKind." + kind.rawValue, fallback: kind.rawValue) ?? kind.rawValue
        return asset + " (" + name + ")"
    }
    var body: some View {
        VStack(alignment: .leading) {
            WorkbenchMenu(language?.text("workflow.language.tools.type", fallback: "类型 / 媒体引用") ?? "类型 / 媒体引用") {
                WorkbenchMenuAction(language?.text("workflow.language.form.type.text", fallback: "文字") ?? "文字") { schema = .text; sample = .text("") }
                WorkbenchMenuForEach([WorkflowDataKind.text, .image, .audio, .video, .notes, .chords, .tempo, .pitch], id: \.self) { kind in
                    WorkbenchMenuAction(assetTitle(kind)) { schema = .asset(kind); sample = nil }
                }
            }
            if case .asset(let kind) = schema { Text(assetTitle(kind)).font(.caption) }
            else {
                WorkflowDatumEditor(value: Binding(get: { sample }, set: { value in
                    sample = value; if let value { schema = value.schema }
                }))
            }
        }
    }
}
