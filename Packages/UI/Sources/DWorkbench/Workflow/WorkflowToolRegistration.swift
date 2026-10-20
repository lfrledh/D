import Foundation

/// Authored descriptions belong to a published definition version. Executable
/// ports, defaults, dependencies and live state continue to come from the graph.
public struct WorkflowToolRegistration: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var purpose: String
    public var detail: String?
    public var inputLabels: [String: String]
    public var outputLabels: [String: String]

    public init(purpose: String, detail: String? = nil,
                inputLabels: [String: String] = [:], outputLabels: [String: String] = [:]) {
        self.purpose = purpose; self.detail = detail
        self.inputLabels = inputLabels; self.outputLabels = outputLabels
    }

    public func validate(interface: WorkflowGraphInterface) throws {
        guard version == 1, !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              purpose.utf8.count <= 512, (detail?.utf8.count ?? 0) <= 8192,
              Set(inputLabels.keys).isSubset(of: Set(interface.inputs.map(\.name))),
              Set(outputLabels.keys).isSubset(of: Set(interface.outputs.map(\.name))),
              (Array(inputLabels.values) + Array(outputLabels.values)).allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
              }) else { throw WorkflowIssue("登记信息版本、用途或公开端口名称无效；执行端口身份不会被改写。") }
    }

    /// Used only at an edit-history boundary, never during canvas presentation.
    static func referencedTools(in graphs: [WorkflowGraph], tools: [WorkflowToolDefinition]) -> [WorkflowToolDefinition] {
        var retained: [WorkflowToolDefinition] = []
        var visited = Set<String>()
        func retain(_ reference: WorkflowToolReference) {
            let key = "\(reference.id):\(reference.version)"
            guard visited.insert(key).inserted,
                  let tool = tools.first(where: { $0.id == reference.id && $0.version == reference.version }) else { return }
            retained.append(tool); visit(tool.graph)
        }
        func visit(_ graph: WorkflowGraph) {
            if let source = graph.toolSource { retain(source) }
            for node in graph.nodes {
                switch node.control {
                case .invoke(let reference):
                    retain(reference)
                case .branch(_, let yes, let no): visit(yes); visit(no)
                case .map(let body, _), .loop(let body, _, _, _): visit(body)
                case nil: break
                }
            }
        }
        graphs.forEach(visit)
        return retained
    }
}

/// A read-only registration projection. Instance and definition identity are
/// separate, and no running status or guessed model specifications are stored.
public struct WorkflowNodeRegistration: Sendable {
    public let instanceID: UUID
    public let name: String
    public let purpose: String?
    public let definitionID: String
    public let version: Int
    public let inputs: [WorkflowPortDefinition]
    public let outputs: [WorkflowPortDefinition]
    public let tool: WorkflowToolDefinition?

    public init?(node: WorkflowNode, registry: WorkflowRegistry, tools: [WorkflowToolDefinition]) {
        guard let definition = registry.definition(for: node, tools: tools) else { return nil }
        instanceID = node.id; name = node.title
        inputs = definition.inputs; outputs = definition.outputs
        if case .invoke(let reference) = node.control {
            guard let exact = tools.first(where: { $0.id == reference.id && $0.version == reference.version }),
                  (try? WorkflowPlanCompiler.digest(exact)) == reference.digest else { return nil }
            tool = exact; definitionID = exact.id.uuidString; version = exact.version
            purpose = exact.registration?.purpose
        } else {
            tool = nil; definitionID = definition.id; version = definition.version
            purpose = definition.detail
        }
    }
}

/// Bounded definition inspection; no execution, model preparation or plan rebuilding.
public struct WorkflowDefinitionDependency: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let operationID: String
    public let modelID: String?
    public let requiresModel: Bool
    public let effect: WorkflowEffect
    public static func inspect(_ graph: WorkflowGraph, tools: [WorkflowToolDefinition], registry: WorkflowRegistry = .standard) throws -> [Self] {
        var rows: [Self] = []
        func visit(_ graph: WorkflowGraph, path: String, depth: Int, stack: Set<WorkflowToolReference>) throws {
            guard depth <= 16 else { throw WorkflowIssue("登记依赖超过 16 层。") }
            for node in graph.nodes {
                guard rows.count < 4096, let definition = registry.definition(for: node, tools: tools) else { throw WorkflowIssue("登记依赖缺失或超过预算。") }
                let key = path + "/" + node.id.uuidString
                rows.append(.init(id: key, title: node.title, operationID: node.operationID,
                    modelID: node.parameters["modelID"]?.string, requiresModel: definition.modelKind != nil,
                    effect: node.control == nil ? try WorkflowPlanCompiler.registeredEffect(for: node, registry: registry) : .pure))
                switch node.control {
                case .branch(_, let yes, let no):
                    try visit(yes, path: key + "/then", depth: depth + 1, stack: stack)
                    try visit(no, path: key + "/else", depth: depth + 1, stack: stack)
                case .map(let body, _), .loop(let body, _, _, _):
                    try visit(body, path: key + "/body", depth: depth + 1, stack: stack)
                case .invoke(let ref):
                    guard !stack.contains(ref), let exact = tools.first(where: { $0.id == ref.id && $0.version == ref.version }),
                          try WorkflowPlanCompiler.digest(exact) == ref.digest else { throw WorkflowIssue("嵌套工具版本、摘要无效或形成递归。") }
                    try visit(exact.graph, path: key + "/tool", depth: depth + 1, stack: stack.union([ref]))
                case nil: break
                }
            }
        }
        try visit(graph, path: graph.id.uuidString, depth: 0, stack: [])
        return rows
    }
}
