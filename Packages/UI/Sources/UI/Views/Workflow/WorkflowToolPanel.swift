import DWorkbench
import SwiftUI

@MainActor
struct WorkflowToolPanel: View {
    let controller: WorkflowController
    @State private var name = ""
    @State private var boundary: ToolBoundaryDraft?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(t("title", "项目工具箱")).font(.title2)
                ForEach(controller.tools, id: \.selfReference) { tool in
                    HStack {
                        Text(tool.name + " · v\(tool.version)")
                        Spacer()
                        Button(t("insert", "插入实例")) { controller.addTool(tool); dismiss() }
                        Button(t("copy", "展开为编辑副本")) {
                            guard let digest = try? WorkflowPlanCompiler.digest(tool) else { return }
                            controller.openToolCopy(.init(id: tool.id, version: tool.version, digest: digest)); dismiss()
                        }
                    }
                }
                Divider()
                TextField(t("name", "新工具名称"), text: $name)
                Button(t("saveGraph", "按公开接口另存当前流程为工具")) { controller.saveGraphAsTool(name: name) }
                Text(t("fixed", "工具实例固定版本与摘要。编辑副本、另存工具和选择新版本都不会静默改变既有实例。")).font(.caption).foregroundStyle(.secondary)
                Button(t("inspect", "检查选区的跨界输入与输出")) {
                    if let graph = controller.graph { boundary = ToolBoundaryDraft(graph: graph, selected: controller.selectedNodeIDs, registry: controller.registry, tools: controller.tools) }
                }
                .disabled(controller.selectedNodeIDs.isEmpty)
                if let error = controller.errorMessage { Text(error).foregroundStyle(.red) }
                if boundary != nil { boundaryEditor }
                Button(t("done", "完成")) { dismiss() }
            }.padding(20)
        }.frame(minWidth: 680, minHeight: 520)
    }
    @ViewBuilder private var boundaryEditor: some View {
        if let value = boundary {
            Text(t("inputs", "跨界输入（请明确选择类型）")).font(.headline)
            ForEach(value.inputs.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    Text(value.inputs[index].sourceNode.uuidString.prefix(8) + " · " + value.inputs[index].sourcePort).font(.caption)
                    TextField(t("publicName", "公开名称"), text: Binding(get: { boundary?.inputs[index].name ?? "" }, set: { boundary?.inputs[index].name = $0 }))
                    WorkflowBoundarySchemaPicker(schema: Binding(get: { boundary?.inputs[index].schema ?? .text }, set: { boundary?.inputs[index].schema = $0 }))
                }
            }
            Text(t("outputs", "公开输出（未勾选的端口不作为工具结果）")).font(.headline)
            ForEach(value.outputs.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    Toggle(value.outputs[index].label, isOn: Binding(get: { boundary?.outputs[index].included ?? false }, set: { boundary?.outputs[index].included = $0 }))
                    TextField(t("publicName", "公开名称"), text: Binding(get: { boundary?.outputs[index].value.name ?? "" }, set: { boundary?.outputs[index].value.name = $0 }))
                    WorkflowBoundarySchemaPicker(schema: Binding(get: { boundary?.outputs[index].value.schema ?? .text }, set: { boundary?.outputs[index].value.schema = $0 }))
                }
            }
            Button(t("extract", "按此接口封装选区")) {
                guard let draft = boundary, controller.selectedNodeIDs == draft.selected else { controller.errorMessage = t("stale", "选区已改变，请重新检查边界。"); return }
                controller.extractSelection(name: name, inputs: draft.inputs, outputs: draft.outputs.filter(\.included).map(\.value), expectedGraphID: draft.graphID, expectedRevision: draft.revision)
                if controller.errorMessage == nil { boundary = nil; dismiss() }
            }.buttonStyle(.borderedProminent)
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
    init(graph: WorkflowGraph, selected: Set<UUID>, registry: WorkflowRegistry, tools: [WorkflowToolDefinition]) {
        graphID = graph.id; revision = graph.revision; self.selected = selected
        inputs = []; outputs = []
        for edge in graph.connections where !selected.contains(edge.sourceNode) && selected.contains(edge.targetNode) {
            guard !inputs.contains(where: { $0.sourceNode == edge.sourceNode && $0.sourcePort == edge.sourcePort }) else { continue }
            // A visible initial proposal only. Exact schema is explicitly confirmed in this form.
            let node = graph.nodes.first { $0.id == edge.sourceNode }
            let schema = node.flatMap { WorkflowToolEditing.outputSchemaProposal(for: $0, port: edge.sourcePort, registry: registry, tools: tools) } ?? .text
            inputs.append(.init(name: "input\(inputs.count + 1)", schema: schema, sourceNode: edge.sourceNode, sourcePort: edge.sourcePort))
        }
        for node in graph.nodes where selected.contains(node.id) {
            for port in registry.definition(for: node, tools: tools)?.outputs ?? [] {
                let required = graph.connections.contains { $0.sourceNode == node.id && $0.sourcePort == port.id && !selected.contains($0.targetNode) } || graph.interface?.outputs.contains { $0.nodeID == node.id && $0.port == port.id } == true
                let schema = graph.interface?.outputs.first { $0.nodeID == node.id && $0.port == port.id }?.schema ?? WorkflowToolEditing.outputSchemaProposal(for: node, port: port.id, registry: registry, tools: tools) ?? node.dataConfiguration?.value?.schema ?? node.dataConfiguration?.schema ?? .text
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
            Menu(language?.text("workflow.language.tools.type", fallback: "类型 / 媒体引用") ?? "类型 / 媒体引用") {
                Button(language?.text("workflow.language.form.type.text", fallback: "文字") ?? "文字") { schema = .text; sample = .text("") }
                ForEach([WorkflowDataKind.text, .image, .audio, .video, .notes, .chords, .tempo, .pitch], id: \.self) { kind in
                    Button(assetTitle(kind)) { schema = .asset(kind); sample = nil }
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
