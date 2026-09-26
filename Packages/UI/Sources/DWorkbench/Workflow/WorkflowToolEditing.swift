import Foundation

public struct WorkflowToolInputBinding: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var schema: WorkflowDataSchema
    public var sourceNode: UUID
    public var sourcePort: String
    public init(name: String, schema: WorkflowDataSchema, sourceNode: UUID, sourcePort: String) {
        self.name = name; self.schema = schema; self.sourceNode = sourceNode; self.sourcePort = sourcePort
    }
}
public struct WorkflowToolExtraction: Sendable {
    public var graph: WorkflowGraph
    public var tool: WorkflowToolDefinition
    public var invocationID: UUID
}

/// Only transforms editable values. It never executes a node or publishes a media asset.
public enum WorkflowToolEditing {
    public static func extract(_ graph: WorkflowGraph, selected: Set<UUID>, name: String,
                               inputs: [WorkflowToolInputBinding], outputs: [WorkflowNamedOutput],
                               tools: [WorkflowToolDefinition], registry: WorkflowRegistry = .standard) throws -> WorkflowToolExtraction {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 256, !tools.contains(where: { $0.name == title }),
              !selected.isEmpty, selected.isSubset(of: Set(graph.nodes.map(\.id))),
              Set(inputs.map(\.name)).count == inputs.count, Set(outputs.map(\.name)).count == outputs.count,
              !outputs.isEmpty else { throw WorkflowIssue("封装需要不重复的工具名、选区与公开接口。") }
        try registry.validate(graph, tools: tools)
        let incoming = graph.connections.filter { !selected.contains($0.sourceNode) && selected.contains($0.targetNode) }
        let outgoing = graph.connections.filter { selected.contains($0.sourceNode) && !selected.contains($0.targetNode) }
        guard inputs.allSatisfy({ item in incoming.contains { $0.sourceNode == item.sourceNode && $0.sourcePort == item.sourcePort } }),
              incoming.allSatisfy({ edge in inputs.filter { $0.sourceNode == edge.sourceNode && $0.sourcePort == edge.sourcePort }.count == 1 }),
              outputs.allSatisfy({ selected.contains($0.nodeID) }),
              outgoing.allSatisfy({ edge in outputs.contains { $0.nodeID == edge.sourceNode && $0.port == edge.sourcePort } }) else {
            throw WorkflowIssue("所有跨界连接必须在公开接口中明确映射；没有移除或猜测连接。")
        }
        var body = WorkflowGraph(name: title, nodes: graph.nodes.filter { selected.contains($0.id) },
                                 connections: graph.connections.filter { selected.contains($0.sourceNode) && selected.contains($0.targetNode) },
                                 layout: graph.layout.filter { selected.contains($0.nodeID) })
        // A published parameter already inside the selection must first be made an explicit boundary.
        guard !body.nodes.contains(where: { $0.operationID == "d.value.input" && !($0.parameters["publicName"]?.string ?? "").isEmpty }) else {
            throw WorkflowIssue("选区包含已有公开输入；请使用完整流程另存工具，或把该输入留在选区外。")
        }
        let fields = inputs.map { WorkflowRecordField($0.name, $0.schema) }
        try WorkflowDataSchema.record(fields).validateDefinition()
        for item in inputs {
            guard let source = graph.nodes.first(where: { $0.id == item.sourceNode }),
                  let port = registry.definition(for: source, tools: tools)?.outputs.first(where: { $0.id == item.sourcePort }),
                  !Set(port.kinds).isDisjoint(with: item.schema.portKinds),
                  let definition = registry.operation("d.value.input")?.definition else { throw WorkflowIssue("公开输入类型与边界端口不兼容。") }
            var literal = definition.makeNode(); literal.title = item.name
            literal.parameters["publicName"] = .text(item.name); literal.dataConfiguration = .init(schema: item.schema)
            body.nodes.append(literal); body.layout.append(.init(nodeID: literal.id, x: 20, y: Double(body.nodes.count * 100)))
            for edge in incoming where edge.sourceNode == item.sourceNode && edge.sourcePort == item.sourcePort {
                body.connections.append(.init(sourceNode: literal.id, targetNode: edge.targetNode, targetPort: edge.targetPort))
            }
        }
        body.interface = .init(inputs: fields, outputs: outputs)
        let tool = WorkflowToolDefinition(name: title, graph: body)
        let available = tools + [tool]
        _ = try WorkflowPlanCompiler(registry: registry).compile(body, tools: available)
        guard let definition = registry.operation("d.control.invoke")?.definition else { throw WorkflowIssue("工具调用操作未注册。") }
        var call = definition.makeNode(); call.title = title
        call.control = .invoke(.init(id: tool.id, version: tool.version, digest: try WorkflowPlanCompiler.digest(tool)))
        call.dataConfiguration = .init(fields: fields)
        var result = graph; result.revision = UUID()
        result.nodes.removeAll { selected.contains($0.id) }; result.nodes.append(call)
        result.connections.removeAll { selected.contains($0.sourceNode) || selected.contains($0.targetNode) }
        result.layout.removeAll { selected.contains($0.nodeID) }; result.layout.append(.init(nodeID: call.id, x: 120, y: 120))
        for item in inputs { result.connections.append(.init(sourceNode: item.sourceNode, sourcePort: item.sourcePort, targetNode: call.id, targetPort: item.name)) }
        for edge in outgoing {
            guard let output = outputs.first(where: { $0.nodeID == edge.sourceNode && $0.port == edge.sourcePort }) else { throw WorkflowIssue("公开输出映射丢失。") }
            result.connections.append(.init(sourceNode: call.id, sourcePort: output.name, targetNode: edge.targetNode, targetPort: edge.targetPort))
        }
        if var interface = result.interface {
            for index in interface.outputs.indices where selected.contains(interface.outputs[index].nodeID) {
                let original = interface.outputs[index]
                guard let exposed = outputs.first(where: { $0.nodeID == original.nodeID && $0.port == original.port && $0.schema == original.schema }) else { throw WorkflowIssue("原流程公开输出必须保留。") }
                interface.outputs[index].nodeID = call.id; interface.outputs[index].port = exposed.name
            }
            result.interface = interface
        }
        try registry.validate(result, tools: available)
        return .init(graph: result, tool: tool, invocationID: call.id)
    }

    public static func editableCopy(of tool: WorkflowToolDefinition) -> WorkflowGraph {
        var graph = tool.graph; graph.id = UUID(); graph.revision = UUID(); graph.name = tool.name + " · 编辑副本"
        // Graph-local identities do not identify invocation instances; run addresses disambiguate them.
        return graph
    }
}
