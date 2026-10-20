import DWorkbench
import SwiftUI

struct WorkflowRegistrationView: View {
    let node: WorkflowNode
    let controller: WorkflowController
    @Environment(\.dLanguageStore) private var language

    var body: some View {
        if let value = WorkflowNodeRegistration(node: node, registry: controller.registry, tools: controller.tools) {
            DisclosureGroup(workspaceText(language, "registration", "登记信息", "Registration")) {
                VStack(alignment: .leading, spacing: 8) {
                    if let purpose = value.purpose, !purpose.isEmpty { Text(purpose).textSelection(.enabled) }
                    if let detail = value.tool?.registration?.detail { Text(detail).font(.caption).textSelection(.enabled) }
                    Text(workspaceText(language, "registeredInputs", "公开输入", "Public inputs")).font(.headline)
                    ForEach(value.inputs) { port in
                        Text((value.tool?.registration?.inputLabels[port.id] ?? port.title)
                            + " · " + port.kinds.map(\.rawValue).joined(separator: " / ")
                            + (port.required ? " · " + workspaceText(language, "required", "必选", "Required") : ""))
                    }
                    Text(workspaceText(language, "registeredOutputs", "公开输出", "Public outputs")).font(.headline)
                    ForEach(value.outputs) { port in
                        Text((value.tool?.registration?.outputLabels[port.id] ?? port.title)
                            + " · " + port.kinds.map(\.rawValue).joined(separator: " / "))
                    }
                    if let definition = controller.registry.definition(for: node, tools: controller.tools), !definition.fields.isEmpty {
                        DisclosureGroup(workspaceText(language, "registeredParameters", "参数与当前配置", "Parameters and current values")) {
                            ForEach(definition.fields) { field in
                                Text(field.title + " · " + String(describing: field.kind) + " · " + String(describing: node.parameters[field.id] ?? field.defaultValue))
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    if let tool = value.tool {
                        if let interface = tool.graph.interface {
                            DisclosureGroup(workspaceText(language, "fullContract", "完整类型与映射", "Full types and mappings")) {
                                ForEach(interface.inputs, id: \.name) { input in
                                    Text(input.name + " · " + String(describing: input.type) + (input.required ? " *" : ""))
                                }
                                ForEach(interface.outputs, id: \.name) { output in
                                    Text(output.name + " · " + String(describing: output.schema) + " ← " + output.nodeID.uuidString.prefix(8) + "." + output.port)
                                }
                            }.font(.caption.monospaced())
                        }
                        Text(workspaceText(language, "registeredGraph", "内部流程", "Internal workflow") + " · \(tool.graph.nodes.count)")
                        WorkflowDependencySummary(graph: tool.graph, controller: controller)
                    }
                    DisclosureGroup(workspaceText(language, "identity", "精确身份", "Exact identity")) {
                        Text(value.definitionID + " · v\(value.version)").textSelection(.enabled)
                        Text(value.instanceID.uuidString).textSelection(.enabled)
                    }.font(.caption.monospaced())
                }.font(.callout).padding(.top, 8)
            }
        }
    }
}

/// One cached projection per immutable definition/input graph; never recomputed by drag ticks.
struct WorkflowDependencySummary: View {
    let graph: WorkflowGraph
    let controller: WorkflowController
    @Environment(\.dLanguageStore) private var language
    @State private var rows: [WorkflowDefinitionDependency] = []
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    if row.requiresModel {
                        let model = controller.modelChoices.first(where: { $0.id == row.modelID })
                        Text(model?.displayName ?? row.modelID.flatMap { $0.isEmpty ? nil : $0 }
                            ?? workspaceText(language, "modelAtSubmit", "提交时固定当前默认模型；当前定义未绑定", "Freeze the current default model at submission; this definition is unbound"))
                    }
                    if row.effect == .human { Text(workspaceText(language, "needsReview", "需要人工处理，保存决定后才可继续", "Requires a saved human decision before continuing")) }
                    if row.effect == .externalExport { Text(workspaceText(language, "needsExport", "写入外部目标，需要明确目标授权", "Writes to an explicitly authorized external destination")) }
                    if row.effect == .assetPublication { Text(workspaceText(language, "publishesAsset", "在项目中保存新成果", "Saves a new project asset")) }
                }.font(.caption).textSelection(.enabled)
            }
            if let issue { Text(issue).foregroundStyle(.orange) }
        }.task(id: graph.revision.uuidString + graph.nodes.map { $0.id.uuidString }.joined()) {
            do { rows = try WorkflowDefinitionDependency.inspect(graph, tools: controller.tools, registry: controller.registry); issue = nil }
            catch { rows = []; issue = error.localizedDescription }
        }
    }
}
