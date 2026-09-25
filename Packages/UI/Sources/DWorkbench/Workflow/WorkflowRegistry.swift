import CryptoKit
import Foundation

public struct WorkflowRegistry: Sendable {
    private static let maximumNodes = 1_024
    private static let maximumConnections = 8_192
    private static let maximumTextBytes = 1_048_576

    private let orderedOperations: [WorkflowOperation]
    private let operationsByID: [String: WorkflowOperation]

    public init(operations: [WorkflowOperation]) throws {
        var table: [String: WorkflowOperation] = [:]
        for operation in operations {
            let definition = operation.definition
            guard !definition.id.isEmpty else { throw WorkflowIssue("操作 ID 不能为空。") }
            guard table[definition.id] == nil else {
                throw WorkflowIssue("操作 ID 重复：\(definition.id)。")
            }
            try Self.validateSchema(definition)
            table[definition.id] = operation
        }
        orderedOperations = operations
        operationsByID = table
    }

    public static var standard: WorkflowRegistry {
        do { return try WorkflowRegistry(operations: WorkflowBuiltins.operations) }
        catch { preconditionFailure("内置工作流注册无效：\(error.localizedDescription)") }
    }

    public var definitions: [WorkflowOperationDefinition] { orderedOperations.map(\.definition) }

    public func operation(_ id: String) -> WorkflowOperation? { operationsByID[id] }

    public func validate(_ node: WorkflowNode) throws {
        guard let operation = operationsByID[node.operationID] else {
            throw WorkflowIssue("未知操作：\(node.operationID)。", nodeID: node.id)
        }
        let definition = operation.definition
        guard node.definitionVersion == definition.version else {
            throw WorkflowIssue(
                "不支持的操作版本：\(node.operationID) v\(node.definitionVersion)，当前为 v\(definition.version)。",
                nodeID: node.id
            )
        }

        let fields = Dictionary(uniqueKeysWithValues: definition.fields.map { ($0.id, $0) })
        for key in node.parameters.keys where fields[key] == nil {
            throw WorkflowIssue("未知字段：\(key)。", nodeID: node.id)
        }
        for field in definition.fields {
            guard let value = node.parameters[field.id] else {
                throw WorkflowIssue("缺少字段：\(field.id)。", nodeID: node.id)
            }
            try Self.validate(value, for: field, nodeID: node.id)
        }
        try operation.validate(node)
    }

    public func validate(_ graph: WorkflowGraph) throws {
        guard graph.nodes.count <= Self.maximumNodes else {
            throw WorkflowIssue("节点数量超过上限 \(Self.maximumNodes)。")
        }
        guard graph.connections.count <= Self.maximumConnections else {
            throw WorkflowIssue("连接数量超过上限 \(Self.maximumConnections)。")
        }

        let nodeIDs = Set(graph.nodes.map(\.id))
        guard nodeIDs.count == graph.nodes.count else { throw WorkflowIssue("节点身份重复。") }
        let connectionIDs = Set(graph.connections.map(\.id))
        guard connectionIDs.count == graph.connections.count else { throw WorkflowIssue("连接身份重复。") }
        let layoutIDs = Set(graph.layout.map(\.nodeID))
        guard layoutIDs.count == graph.layout.count else { throw WorkflowIssue("节点布局重复。") }
        guard layoutIDs.isSubset(of: nodeIDs) else { throw WorkflowIssue("布局引用了不存在的节点。") }

        for node in graph.nodes { try validate(node) }
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var occupiedInputs = Set<TargetPort>()
        var outgoing: [UUID: [UUID]] = [:]
        var indegree = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, 0) })

        for connection in graph.connections {
            guard let source = nodes[connection.sourceNode] else {
                throw WorkflowIssue("连接来源节点不存在。")
            }
            guard let target = nodes[connection.targetNode] else {
                throw WorkflowIssue("连接目标节点不存在。")
            }
            guard let sourceDefinition = operationsByID[source.operationID]?.definition,
                  let output = sourceDefinition.outputs.first(where: { $0.id == connection.sourcePort }) else {
                throw WorkflowIssue("来源端口不存在。", nodeID: source.id, port: connection.sourcePort)
            }
            guard let targetDefinition = operationsByID[target.operationID]?.definition,
                  let input = targetDefinition.inputs.first(where: { $0.id == connection.targetPort }) else {
                throw WorkflowIssue("目标端口不存在。", nodeID: target.id, port: connection.targetPort)
            }
            guard !Set(output.kinds).isDisjoint(with: input.kinds) else {
                throw WorkflowIssue("连接的数据类型不兼容。", nodeID: target.id, port: input.id)
            }
            guard occupiedInputs.insert(TargetPort(nodeID: target.id, port: input.id)).inserted else {
                throw WorkflowIssue("输入端口不能有多个来源。", nodeID: target.id, port: input.id)
            }
            outgoing[source.id, default: []].append(target.id)
            indegree[target.id, default: 0] += 1
        }

        var ready = indegree.compactMap { $0.value == 0 ? $0.key : nil }.sorted(by: Self.uuidOrder)
        var visited = 0
        while !ready.isEmpty {
            let current = ready.removeFirst()
            visited += 1
            for next in (outgoing[current] ?? []).sorted(by: Self.uuidOrder) {
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 {
                    ready.append(next)
                    ready.sort(by: Self.uuidOrder)
                }
            }
        }
        guard visited == graph.nodes.count else { throw WorkflowIssue("工作流不能包含环。") }
    }

    public func plan(_ graph: WorkflowGraph, target: UUID, only: Bool) throws -> [UUID] {
        try validate(graph)
        guard graph.nodes.contains(where: { $0.id == target }) else {
            throw WorkflowIssue("目标节点不存在。", nodeID: target)
        }
        if only { return [target] }

        var included: Set<UUID> = [target]
        var frontier = [target]
        while let current = frontier.popLast() {
            for connection in graph.connections where connection.targetNode == current {
                if included.insert(connection.sourceNode).inserted { frontier.append(connection.sourceNode) }
            }
        }

        var indegree = Dictionary(uniqueKeysWithValues: included.map { ($0, 0) })
        var outgoing: [UUID: [UUID]] = [:]
        for connection in graph.connections
        where included.contains(connection.sourceNode) && included.contains(connection.targetNode) {
            outgoing[connection.sourceNode, default: []].append(connection.targetNode)
            indegree[connection.targetNode, default: 0] += 1
        }
        var ready = indegree.compactMap { $0.value == 0 ? $0.key : nil }.sorted(by: Self.uuidOrder)
        var result: [UUID] = []
        while !ready.isEmpty {
            let current = ready.removeFirst()
            result.append(current)
            for next in (outgoing[current] ?? []).sorted(by: Self.uuidOrder) {
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 {
                    ready.append(next)
                    ready.sort(by: Self.uuidOrder)
                }
            }
        }
        return result
    }

    public func signature(_ nodeID: UUID, in graph: WorkflowGraph) throws -> String {
        let nodeOrder = try plan(graph, target: nodeID, only: false)
        let included = Set(nodeOrder)
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var canonical = SignatureBytes()
        canonical.append("d.workflow.signature.v1")

        for id in nodeOrder {
            guard let node = nodes[id] else { throw WorkflowIssue("签名节点不存在。", nodeID: id) }
            canonical.append("node")
            canonical.append(Self.uuidString(id))
            canonical.append(node.operationID)
            canonical.append(String(node.definitionVersion))
            for key in node.parameters.keys.sorted() {
                guard let value = node.parameters[key] else { continue }
                canonical.append("field")
                canonical.append(key)
                canonical.append(value)
            }
            if let asset = node.assetReference {
                canonical.append("asset")
                canonical.append(Self.uuidString(asset.projectID))
                canonical.append(Self.uuidString(asset.assetID))
                canonical.append(Self.uuidString(asset.version))
                canonical.append(asset.kind.rawValue)
                canonical.append(asset.sha256)
            } else {
                canonical.append("no-asset")
            }
        }

        let connections = graph.connections
            .filter { included.contains($0.sourceNode) && included.contains($0.targetNode) }
            .sorted(by: Self.connectionOrder)
        for connection in connections {
            canonical.append("connection")
            canonical.append(Self.uuidString(connection.sourceNode))
            canonical.append(connection.sourcePort)
            canonical.append(Self.uuidString(connection.targetNode))
            canonical.append(connection.targetPort)
        }

        return SHA256.hash(data: Data(canonical.bytes)).map { String(format: "%02x", $0) }.joined()
    }

    public func validateInputs(
        _ inputs: [String: WorkflowValue],
        node: WorkflowNode,
        connectedPorts: Set<String>
    ) throws {
        try validate(node)
        guard let definition = operationsByID[node.operationID]?.definition else {
            throw WorkflowIssue("未知操作：\(node.operationID)。", nodeID: node.id)
        }
        let ports = Dictionary(uniqueKeysWithValues: definition.inputs.map { ($0.id, $0) })
        for port in connectedPorts where ports[port] == nil {
            throw WorkflowIssue("已连接端口不存在。", nodeID: node.id, port: port)
        }
        for key in inputs.keys where ports[key] == nil {
            throw WorkflowIssue("收到未知输入。", nodeID: node.id, port: key)
        }
        for port in definition.inputs where port.required || connectedPorts.contains(port.id) {
            guard inputs[port.id] != nil else {
                throw WorkflowIssue("输入尚未就绪。", nodeID: node.id, port: port.id)
            }
        }
        for (key, value) in inputs {
            guard let port = ports[key], port.kinds.contains(value.kind) else {
                throw WorkflowIssue("输入实际类型不兼容。", nodeID: node.id, port: key)
            }
        }
    }

    private static func validateSchema(_ definition: WorkflowOperationDefinition) throws {
        guard definition.version > 0 else { throw WorkflowIssue("操作版本必须为正数：\(definition.id)。") }
        guard Set(definition.inputs.map(\.id)).count == definition.inputs.count,
              Set(definition.outputs.map(\.id)).count == definition.outputs.count,
              Set(definition.fields.map(\.id)).count == definition.fields.count else {
            throw WorkflowIssue("操作定义含重复端口或字段：\(definition.id)。")
        }
        guard definition.inputs.allSatisfy({ !$0.id.isEmpty && !$0.kinds.isEmpty }),
              definition.outputs.allSatisfy({ !$0.id.isEmpty && !$0.kinds.isEmpty }),
              definition.fields.allSatisfy({ !$0.id.isEmpty }) else {
            throw WorkflowIssue("操作定义含空端口、字段或类型：\(definition.id)。")
        }
    }

    private static func validate(_ value: WorkflowScalar, for field: WorkflowFieldDefinition, nodeID: UUID) throws {
        switch (field.kind, value) {
        case (.text, .text(let text)):
            guard text.utf8.count <= maximumTextBytes else {
                throw WorkflowIssue("字段文本超过 \(maximumTextBytes) 字节。", nodeID: nodeID)
            }
        case (.integer, .integer): break
        case (.decimal, .decimal(let number)):
            guard number.isFinite else { throw WorkflowIssue("字段必须是有限小数。", nodeID: nodeID) }
        case (.flag, .flag): break
        case (.choice(let choices), .text(let choice)):
            guard choices.contains(choice) else { throw WorkflowIssue("字段选项无效：\(choice)。", nodeID: nodeID) }
        default:
            throw WorkflowIssue("字段标量类型不符：\(field.id)。", nodeID: nodeID)
        }
    }

    private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool { uuidString(lhs) < uuidString(rhs) }
    private static func uuidString(_ id: UUID) -> String { id.uuidString.lowercased() }
    private static func connectionOrder(_ lhs: WorkflowConnection, _ rhs: WorkflowConnection) -> Bool {
        let left = [uuidString(lhs.sourceNode), lhs.sourcePort, uuidString(lhs.targetNode), lhs.targetPort]
        let right = [uuidString(rhs.sourceNode), rhs.sourcePort, uuidString(rhs.targetNode), rhs.targetPort]
        for (a, b) in zip(left, right) where a != b { return a < b }
        return false
    }
}

private struct TargetPort: Hashable {
    let nodeID: UUID
    let port: String
}

private struct SignatureBytes {
    private(set) var bytes: [UInt8] = []

    mutating func append(_ value: String) {
        let encoded = Array(value.utf8)
        let length = UInt64(encoded.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((length >> shift) & 0xff))
        }
        bytes.append(contentsOf: encoded)
    }

    mutating func append(_ value: WorkflowScalar) {
        switch value {
        case .text(let text): append("text"); append(text)
        case .integer(let integer): append("integer"); append(String(integer))
        case .decimal(let decimal): append("decimal"); append(String(decimal.bitPattern, radix: 16))
        case .flag(let flag): append("flag"); append(flag ? "true" : "false")
        }
    }
}
