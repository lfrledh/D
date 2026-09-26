import Foundation

/// An editor location, not a run address. Running a body requires a concrete call record.
public struct WorkflowBodyLocation: Sendable, Equatable, Identifiable {
    public var id: UUID { nodeID }
    public var nodeID: UUID
    public var slot: String
    public init(nodeID: UUID, slot: String) { self.nodeID = nodeID; self.slot = slot }
}

public enum WorkflowGraphEditing {
    public static func body(in graph: WorkflowGraph, path: [WorkflowBodyLocation]) throws -> WorkflowGraph {
        guard path.count <= 16 else { throw WorkflowIssue("编辑位置超过层级限制。") }
        var result = graph
        for entry in path { result = try child(in: result, at: entry) }
        return result
    }
    public static func replacingBody(in graph: WorkflowGraph, path: [WorkflowBodyLocation], with value: WorkflowGraph) throws -> WorkflowGraph {
        guard path.count <= 16 else { throw WorkflowIssue("编辑位置超过层级限制。") }
        guard let first = path.first else {
            guard value.id == graph.id else { throw WorkflowIssue("局部流程身份已改变。") }
            return value
        }
        var result = graph
        guard let index = result.nodes.firstIndex(where: { $0.id == first.nodeID }) else { throw WorkflowIssue("局部流程已删除。") }
        let replacement = try replacingBody(in: child(in: graph, at: first), path: Array(path.dropFirst()), with: value)
        switch (result.nodes[index].control, first.slot) {
        case (.branch(let predicate, _, let no), "then"): result.nodes[index].control = .branch(predicate: predicate, then: replacement, otherwise: no)
        case (.branch(let predicate, let yes, _), "otherwise"): result.nodes[index].control = .branch(predicate: predicate, then: yes, otherwise: replacement)
        case (.map(_, let continuing), "body"): result.nodes[index].control = .map(body: replacement, continueOnFailure: continuing)
        case (.loop(_, let schema, let limit, let rule), "body"): result.nodes[index].control = .loop(body: replacement, stateSchema: schema, maximumIterations: limit, until: rule)
        default: throw WorkflowIssue("此入口不是可编辑的局部流程；固定工具请先另存。")
        }
        result.revision = UUID()
        return result
    }
    private static func child(in graph: WorkflowGraph, at location: WorkflowBodyLocation) throws -> WorkflowGraph {
        guard let node = graph.nodes.first(where: { $0.id == location.nodeID }) else { throw WorkflowIssue("局部节点已不存在。") }
        switch (node.control, location.slot) {
        case (.branch(_, let yes, _), "then"): return yes
        case (.branch(_, _, let no), "otherwise"): return no
        case (.map(let body, _), "body"), (.loop(let body, _, _, _), "body"): return body
        default: throw WorkflowIssue("无法进入指定的局部流程。")
        }
    }
}
