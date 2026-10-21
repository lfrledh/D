import DWorkbench
import SwiftUI

struct WorkflowRegistrationView: View {
    let node: WorkflowNode
    let controller: WorkflowController
    @Environment(\.dLanguageStore) private var language

    var body: some View {
        if let value = WorkflowNodeRegistration(node: node, registry: controller.registry, tools: controller.tools) {
            DisclosureGroup(workspaceText(language, "registration")) {
                VStack(alignment: .leading, spacing: 8) {
                    if let purpose = value.purpose, !purpose.isEmpty { Text(value.tool == nil ? controller.registry.definition(for: node).map { WorkflowCanvasPresentation.operationDetail($0, language: language) } ?? purpose : purpose).textSelection(.enabled) }
                    if let detail = value.tool?.registration?.detail { Text(detail).font(.caption).textSelection(.enabled) }
                    Text(workspaceText(language, "registeredInputs")).font(.headline)
                    ForEach(value.inputs) { port in
                        Text((value.tool?.registration?.inputLabels[port.id] ?? WorkflowCanvasPresentation.portTitle(operationID: node.operationID, port: port, input: true, language: language))
                            + " · " + port.kinds.map { workflowText(language, "workflow.kind." + $0.rawValue, fallback: $0.rawValue) }.joined(separator: " / ")
                            + (port.required ? " · " + workspaceText(language, "required") : ""))
                    }
                    Text(workspaceText(language, "registeredOutputs")).font(.headline)
                    ForEach(value.outputs) { port in
                        Text((value.tool?.registration?.outputLabels[port.id] ?? WorkflowCanvasPresentation.portTitle(operationID: node.operationID, port: port, input: false, language: language))
                            + " · " + port.kinds.map { workflowText(language, "workflow.kind." + $0.rawValue, fallback: $0.rawValue) }.joined(separator: " / "))
                    }
                    if let definition = controller.registry.definition(for: node, tools: controller.tools), !definition.fields.isEmpty {
                        DisclosureGroup(workspaceText(language, "registeredParameters")) {
                            ForEach(definition.fields) { field in
                                Text(WorkflowCanvasPresentation.fieldTitle(operationID: node.operationID, field: field, language: language) + " · " + String(describing: node.parameters[field.id] ?? field.defaultValue))
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    if let tool = value.tool {
                        if let interface = tool.graph.interface {
                            DisclosureGroup(workspaceText(language, "fullContract")) {
                                ForEach(interface.inputs, id: \.name) { input in
                                    Text(input.name + " · " + String(describing: input.type) + (input.required ? " *" : ""))
                                }
                                ForEach(interface.outputs, id: \.name) { output in
                                    Text(output.name + " · " + String(describing: output.schema) + " ← " + output.nodeID.uuidString.prefix(8) + "." + output.port)
                                }
                            }.font(.caption.monospaced())
                        }
                        Text(workspaceText(language, "registeredGraph") + " · \(tool.graph.nodes.count)")
                        WorkflowDependencySummary(graph: tool.graph, controller: controller)
                    }
                    DisclosureGroup(workspaceText(language, "identity")) {
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
                            ?? workspaceText(language, "modelAtSubmit"))
                    }
                    if row.effect == .human { Text(workspaceText(language, "needsReview")) }
                    if row.effect == .externalExport { Text(workspaceText(language, "needsExport")) }
                    if row.effect == .assetPublication { Text(workspaceText(language, "publishesAsset")) }
                }.font(.caption).textSelection(.enabled)
            }
            if let issue { Text(issue).foregroundStyle(.orange) }
        }.task(id: graph.revision.uuidString + graph.nodes.map { $0.id.uuidString }.joined()) {
            do { rows = try WorkflowDefinitionDependency.inspect(graph, tools: controller.tools, registry: controller.registry); issue = nil }
            catch { rows = []; issue = error.localizedDescription }
        }
    }
}
