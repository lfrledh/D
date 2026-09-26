import CryptoKit
import Foundation

public struct WorkflowPlanCompiler {
    fileprivate static let maximumNodes = 1_024
    fileprivate static let maximumConnections = 8_192
    fileprivate static let maximumDepth = 16
    fileprivate static let maximumSteps = 4_096

    private let registry: WorkflowRegistry

    public init(registry: WorkflowRegistry = .standard) {
        self.registry = registry
    }

    public static func digest(_ tool: WorkflowToolDefinition) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(tool))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func compile(
        _ graph: WorkflowGraph,
        tools: [WorkflowToolDefinition] = [],
        target: UUID? = nil,
        only: Bool = false
    ) throws -> WorkflowPlan {
        guard target != nil || !only else {
            throw WorkflowIssue("only=true 必须指定目标节点。")
        }
        var state = try CompilerState(registry: registry, tools: tools)
        return try state.compile(graph, target: target, only: only, depth: 0, toolStack: [])
    }
}

private struct WorkflowToolKey: Hashable {
    let id: UUID
    let version: Int
}

private struct CompilerState {
    let registry: WorkflowRegistry
    let tools: [WorkflowToolKey: WorkflowToolDefinition]
    var stepCount = 0

    init(registry: WorkflowRegistry, tools supplied: [WorkflowToolDefinition]) throws {
        self.registry = registry
        var table: [WorkflowToolKey: WorkflowToolDefinition] = [:]
        var names = Set<String>()
        for tool in supplied {
            guard tool.version > 0 else { throw WorkflowIssue("工具版本必须为正数：\(tool.name)。") }
            guard !tool.name.isEmpty else { throw WorkflowIssue("工具名称不能为空。") }
            guard names.insert(tool.name).inserted else { throw WorkflowIssue("工具名称重复：\(tool.name)。") }
            let key = WorkflowToolKey(id: tool.id, version: tool.version)
            guard table[key] == nil else { throw WorkflowIssue("工具身份和版本重复：\(tool.id) v\(tool.version)。") }
            try Self.validateInterface(tool.graph.interface ?? .init(), graph: tool.graph)
            table[key] = tool
        }
        try Self.validateToolRecursion(table)
        tools = table
        for tool in supplied {
            var verifier = self
            verifier.stepCount = 0
            let key = WorkflowToolKey(id: tool.id, version: tool.version)
            _ = try verifier.compile(tool.graph, target: nil, only: false, depth: 0, toolStack: [key])
        }
    }

    mutating func compile(
        _ graph: WorkflowGraph,
        target: UUID?,
        only: Bool,
        depth: Int,
        toolStack: [WorkflowToolKey]
    ) throws -> WorkflowPlan {
        guard depth <= WorkflowPlanCompiler.maximumDepth else {
            throw WorkflowIssue("结构化计划嵌套深度超过上限 \(WorkflowPlanCompiler.maximumDepth)。")
        }
        let validation = try validateGraph(graph)
        let order = try selectedOrder(validation: validation, graph: graph, target: target, only: only)
        let selected = Set(order)
        for node in graph.nodes where !selected.contains(node.id) && node.control != nil {
            var verifier = self
            verifier.stepCount = 0
            try verifier.validateControlExpansion(node, depth: depth, toolStack: toolStack)
        }
        var steps: [WorkflowPlannedStep] = []
        steps.reserveCapacity(order.count)

        for nodeID in order {
            guard let node = validation.nodes[nodeID] else {
                throw WorkflowIssue("计划节点不存在。", nodeID: nodeID)
            }
            stepCount += 1
            guard stepCount <= WorkflowPlanCompiler.maximumSteps else {
                throw WorkflowIssue("展开后的计划步骤超过上限 \(WorkflowPlanCompiler.maximumSteps)。")
            }
            let inputs = graph.connections
                .filter { $0.targetNode == nodeID }
                .sorted(by: Self.connectionOrder)
                .map { WorkflowPlanInput(port: $0.targetPort, sourceNode: $0.sourceNode, sourcePort: $0.sourcePort) }
            let kind: WorkflowPlanStepKind
            let stepEffect: WorkflowEffect

            switch node.control {
            case .branch(let predicate, let thenGraph, let otherwiseGraph):
                guard node.operationID == "d.control.branch" else {
                    throw WorkflowIssue("Branch 控制结构与操作 ID 不一致。", nodeID: node.id)
                }
                let yes = try compile(thenGraph, target: nil, only: false, depth: depth + 1, toolStack: toolStack)
                let no = try compile(otherwiseGraph, target: nil, only: false, depth: depth + 1, toolStack: toolStack)
                let yesOutput = try Self.singleBodyOutput(yes.interface, purpose: "Branch then")
                let noOutput = try Self.singleBodyOutput(no.interface, purpose: "Branch otherwise")
                guard yesOutput.schema == noOutput.schema else {
                    throw WorkflowIssue("Branch 两侧输出结构必须一致。", nodeID: node.id)
                }
                kind = .branch(predicate: predicate, then: yes, otherwise: no)
                stepEffect = .pure
            case .map(let body, let continueOnFailure):
                guard node.operationID == "d.control.map" else {
                    throw WorkflowIssue("Map 控制结构与操作 ID 不一致。", nodeID: node.id)
                }
                let compiled = try compile(body, target: nil, only: false, depth: depth + 1, toolStack: toolStack)
                _ = try Self.singleBodyOutput(compiled.interface, purpose: "Map")
                kind = .map(body: compiled, continueOnFailure: continueOnFailure)
                stepEffect = .pure
            case .loop(let body, let stateSchema, let maximumIterations, let until):
                guard node.operationID == "d.control.loop" else {
                    throw WorkflowIssue("Loop 控制结构与操作 ID 不一致。", nodeID: node.id)
                }
                guard (1...1_000).contains(maximumIterations) else {
                    throw WorkflowIssue("Loop 次数必须在 1...1000。", nodeID: node.id)
                }
                try Self.validateSchema(stateSchema, path: "Loop.stateSchema")
                let compiled = try compile(body, target: nil, only: false, depth: depth + 1, toolStack: toolStack)
                let output = try Self.loopBodyOutput(compiled.interface)
                guard output.schema == stateSchema else {
                    throw WorkflowIssue("Loop body 的 state 输出结构与 stateSchema 不一致。", nodeID: node.id)
                }
                kind = .loop(body: compiled, stateSchema: stateSchema, maximumIterations: maximumIterations, until: until)
                stepEffect = .pure
            case .invoke(let reference):
                guard node.operationID == "d.control.invoke" else {
                    throw WorkflowIssue("Invoke 控制结构与操作 ID 不一致。", nodeID: node.id)
                }
                let key = WorkflowToolKey(id: reference.id, version: reference.version)
                guard let tool = tools[key] else {
                    throw WorkflowIssue("找不到固定版本工具：\(reference.id) v\(reference.version)。", nodeID: node.id)
                }
                guard try WorkflowPlanCompiler.digest(tool) == reference.digest else {
                    throw WorkflowIssue("工具摘要不匹配：\(tool.name)。", nodeID: node.id)
                }
                guard !toolStack.contains(key) else {
                    throw WorkflowIssue("工具递归调用被拒绝：\(tool.name)。", nodeID: node.id)
                }
                let body = try compile(tool.graph, target: nil, only: false, depth: depth + 1, toolStack: toolStack + [key])
                kind = .invoke(reference: reference, body: body)
                stepEffect = .pure
            case nil:
                guard !Self.structuredControlIDs.contains(node.operationID) else {
                    throw WorkflowIssue("结构化控制节点缺少对应 control。", nodeID: node.id)
                }
                kind = .call
                stepEffect = try effect(for: node)
            }
            steps.append(.init(node: node, inputs: inputs, kind: kind, effect: stepEffect))
        }

        let completeInterface = graph.interface ?? .init()
        try Self.validateInterface(completeInterface, graph: graph, effectivePorts: validation.ports)
        let interface = Self.projectInterface(completeInterface, graph: graph, selected: Set(order), target: target)
        return WorkflowPlan(graphID: graph.id, graphRevision: graph.revision, steps: steps, interface: interface)
    }

    private mutating func validateGraph(_ graph: WorkflowGraph) throws -> GraphValidation {
        guard graph.nodes.count <= WorkflowPlanCompiler.maximumNodes else {
            throw WorkflowIssue("节点数量超过上限 \(WorkflowPlanCompiler.maximumNodes)。")
        }
        guard graph.connections.count <= WorkflowPlanCompiler.maximumConnections else {
            throw WorkflowIssue("连接数量超过上限 \(WorkflowPlanCompiler.maximumConnections)。")
        }
        let nodeIDs = Set(graph.nodes.map(\.id))
        guard nodeIDs.count == graph.nodes.count else { throw WorkflowIssue("节点身份重复。") }
        let connectionIDs = Set(graph.connections.map(\.id))
        guard connectionIDs.count == graph.connections.count else { throw WorkflowIssue("连接身份重复。") }
        let layoutIDs = Set(graph.layout.map(\.nodeID))
        guard layoutIDs.count == graph.layout.count else { throw WorkflowIssue("节点布局重复。") }
        guard layoutIDs.isSubset(of: nodeIDs) else { throw WorkflowIssue("布局引用了不存在的节点。") }

        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var ports: [UUID: EffectivePorts] = [:]
        for node in graph.nodes {
            try registry.validate(node)
            try Self.validateControlShape(node)
            ports[node.id] = try effectivePorts(for: node)
        }

        var occupied = Set<TargetPort>()
        var outgoing: [UUID: [UUID]] = [:]
        var indegree = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, 0) })
        for connection in graph.connections {
            guard nodes[connection.sourceNode] != nil else { throw WorkflowIssue("连接来源节点不存在。") }
            guard nodes[connection.targetNode] != nil else { throw WorkflowIssue("连接目标节点不存在。") }
            guard let output = ports[connection.sourceNode]?.outputs[connection.sourcePort] else {
                throw WorkflowIssue("来源端口不存在。", nodeID: connection.sourceNode, port: connection.sourcePort)
            }
            guard let input = ports[connection.targetNode]?.inputs[connection.targetPort] else {
                throw WorkflowIssue("目标端口不存在。", nodeID: connection.targetNode, port: connection.targetPort)
            }
            guard !Set(output.kinds).isDisjoint(with: input.kinds) else {
                throw WorkflowIssue("连接的数据类型不兼容。", nodeID: connection.targetNode, port: connection.targetPort)
            }
            guard occupied.insert(.init(nodeID: connection.targetNode, port: connection.targetPort)).inserted else {
                throw WorkflowIssue("输入端口不能有多个来源。", nodeID: connection.targetNode, port: connection.targetPort)
            }
            outgoing[connection.sourceNode, default: []].append(connection.targetNode)
            indegree[connection.targetNode, default: 0] += 1
        }
        let order = try Self.topologicalOrder(nodes: nodeIDs, outgoing: outgoing, indegree: indegree)
        return GraphValidation(nodes: nodes, ports: ports, order: order)
    }

    private func effectivePorts(for node: WorkflowNode) throws -> EffectivePorts {
        if case .invoke(let reference) = node.control {
            let key = WorkflowToolKey(id: reference.id, version: reference.version)
            guard let tool = tools[key] else {
                throw WorkflowIssue("找不到固定版本工具。", nodeID: node.id)
            }
            guard try WorkflowPlanCompiler.digest(tool) == reference.digest else {
                throw WorkflowIssue("工具摘要不匹配。", nodeID: node.id)
            }
            let interface = tool.graph.interface ?? .init()
            try Self.validateInterface(interface, graph: tool.graph)
            if let configuration = node.dataConfiguration {
                guard configuration.fields == interface.inputs else {
                    throw WorkflowIssue("Invoke 配置字段必须与固定工具输入完全一致。", nodeID: node.id)
                }
            }
            return EffectivePorts(
                inputs: Dictionary(uniqueKeysWithValues: interface.inputs.map {
                    ($0.name, EffectivePort(kinds: $0.type.portKinds, required: $0.required, schema: $0.type))
                }),
                outputs: Dictionary(uniqueKeysWithValues: interface.outputs.map {
                    ($0.name, EffectivePort(kinds: $0.schema.portKinds, required: true, schema: $0.schema))
                })
            )
        }
        guard let definition = registry.definition(for: node) else {
            throw WorkflowIssue("未知操作：\(node.operationID)。", nodeID: node.id)
        }
        return EffectivePorts(
            inputs: Dictionary(uniqueKeysWithValues: definition.inputs.map {
                ($0.id, EffectivePort(kinds: $0.kinds, required: $0.required, schema: nil))
            }),
            outputs: Dictionary(uniqueKeysWithValues: definition.outputs.map {
                ($0.id, EffectivePort(kinds: $0.kinds, required: $0.required, schema: nil))
            })
        )
    }

    private func selectedOrder(
        validation: GraphValidation, graph: WorkflowGraph, target: UUID?, only: Bool
    ) throws -> [UUID] {
        guard let target else { return validation.order }
        guard validation.nodes[target] != nil else { throw WorkflowIssue("目标节点不存在。", nodeID: target) }
        if only { return [target] }
        var included: Set<UUID> = [target]
        var frontier = [target]
        while let current = frontier.popLast() {
            for connection in graph.connections where connection.targetNode == current {
                if included.insert(connection.sourceNode).inserted { frontier.append(connection.sourceNode) }
            }
        }
        return validation.order.filter { included.contains($0) }
    }

    private func effect(for node: WorkflowNode) throws -> WorkflowEffect {
        guard let definition = registry.definition(for: node) else {
            throw WorkflowIssue("未知操作：\(node.operationID)。", nodeID: node.id)
        }
        if node.operationID == "d.asset.export" { return .externalExport }
        if definition.interaction != .none { return .human }
        if definition.modelKind != nil { return .inference }
        if Self.assetPublicationIDs.contains(node.operationID) { return .assetPublication }
        if node.operationID == "d.control.human" { return .human }
        return .pure
    }

    private mutating func validateControlExpansion(
        _ node: WorkflowNode,
        depth: Int,
        toolStack: [WorkflowToolKey]
    ) throws {
        switch node.control {
        case .branch(_, let yes, let no):
            let yesPlan = try compile(yes, target: nil, only: false, depth: depth + 1, toolStack: toolStack)
            let noPlan = try compile(no, target: nil, only: false, depth: depth + 1, toolStack: toolStack)
            let yesOutput = try Self.singleBodyOutput(yesPlan.interface, purpose: "Branch then")
            let noOutput = try Self.singleBodyOutput(noPlan.interface, purpose: "Branch otherwise")
            guard yesOutput.schema == noOutput.schema else {
                throw WorkflowIssue("Branch 两侧输出结构必须一致。", nodeID: node.id)
            }
        case .map(let body, _):
            let plan = try compile(body, target: nil, only: false, depth: depth + 1, toolStack: toolStack)
            _ = try Self.singleBodyOutput(plan.interface, purpose: "Map")
        case .loop(let body, let stateSchema, let maximumIterations, _):
            guard (1...1_000).contains(maximumIterations) else {
                throw WorkflowIssue("Loop 次数必须在 1...1000。", nodeID: node.id)
            }
            try Self.validateSchema(stateSchema, path: "Loop.stateSchema")
            let plan = try compile(body, target: nil, only: false, depth: depth + 1, toolStack: toolStack)
            guard try Self.loopBodyOutput(plan.interface).schema == stateSchema else {
                throw WorkflowIssue("Loop body 的 state 输出结构与 stateSchema 不一致。", nodeID: node.id)
            }
        case .invoke(let reference):
            let key = WorkflowToolKey(id: reference.id, version: reference.version)
            guard let tool = tools[key], try WorkflowPlanCompiler.digest(tool) == reference.digest else {
                throw WorkflowIssue("Invoke 工具身份或摘要无效。", nodeID: node.id)
            }
            guard !toolStack.contains(key) else {
                throw WorkflowIssue("工具递归调用被拒绝：\(tool.name)。", nodeID: node.id)
            }
            _ = try compile(tool.graph, target: nil, only: false, depth: depth + 1, toolStack: toolStack + [key])
        case nil:
            break
        }
    }

    private static func validateControlShape(_ node: WorkflowNode) throws {
        switch (node.operationID, node.control) {
        case ("d.control.branch", .branch), ("d.control.map", .map), ("d.control.loop", .loop), ("d.control.invoke", .invoke):
            break
        case let (id, nil) where structuredControlIDs.contains(id):
            throw WorkflowIssue("结构化控制节点缺少对应 control。", nodeID: node.id)
        case let (id, nil) where !structuredControlIDs.contains(id):
            break
        case let (id, control?) where !structuredControlIDs.contains(id):
            _ = control
            throw WorkflowIssue("普通节点不能携带结构化 control。", nodeID: node.id)
        default:
            throw WorkflowIssue("控制结构与操作 ID 不一致。", nodeID: node.id)
        }
    }

    private static func validateInterface(
        _ interface: WorkflowGraphInterface,
        graph: WorkflowGraph,
        effectivePorts: [UUID: EffectivePorts]? = nil
    ) throws {
        guard Set(interface.inputs.map(\.name)).count == interface.inputs.count,
              Set(interface.outputs.map(\.name)).count == interface.outputs.count else {
            throw WorkflowIssue("流程接口名称重复。")
        }
        for field in interface.inputs {
            guard !field.name.isEmpty else { throw WorkflowIssue("流程输入名称不能为空。") }
            try validateSchema(field.type, path: "interface.inputs.\(field.name)")
        }
        for output in interface.outputs {
            guard !output.name.isEmpty, !output.port.isEmpty else { throw WorkflowIssue("流程输出名称或端口不能为空。") }
            try validateSchema(output.schema, path: "interface.outputs.\(output.name)")
            guard graph.nodes.contains(where: { $0.id == output.nodeID }) else {
                throw WorkflowIssue("流程输出引用了不存在的节点。", nodeID: output.nodeID, port: output.port)
            }
            if let effectivePorts {
                guard let port = effectivePorts[output.nodeID]?.outputs[output.port] else {
                    throw WorkflowIssue("流程输出引用了不存在的端口。", nodeID: output.nodeID, port: output.port)
                }
                guard !Set(port.kinds).isDisjoint(with: output.schema.portKinds) else {
                    throw WorkflowIssue("流程输出结构与端口类型不兼容。", nodeID: output.nodeID, port: output.port)
                }
            }
        }
        let declared = Dictionary(uniqueKeysWithValues: interface.inputs.map { ($0.name, $0) })
        var publicNames = Set<String>()
        for node in graph.nodes where node.operationID == "d.value.input" {
            let name = node.parameters["publicName"]?.string ?? ""
            if name.isEmpty { continue }
            guard publicNames.insert(name).inserted else {
                throw WorkflowIssue("公开输入名称重复：\(name)。", nodeID: node.id)
            }
            guard declared[name] != nil else {
                throw WorkflowIssue("公开输入未在流程接口声明：\(name)。", nodeID: node.id)
            }
        }
        for field in interface.inputs where !publicNames.contains(field.name) {
            throw WorkflowIssue("流程接口输入没有对应的 d.value.input：\(field.name)。")
        }
    }

    static func validateSchema(_ schema: WorkflowDataSchema, path: String, depth: Int = 0) throws {
        guard depth <= 24 else { throw WorkflowIssue("\(path)：结构层级超过上限。") }
        switch schema {
        case .text, .boolean, .asset:
            break
        case .number(let unit):
            if let unit, unit.utf8.count > 256 { throw WorkflowIssue("\(path)：单位名称过长。") }
        case .enumeration(let choices):
            guard !choices.isEmpty, Set(choices).count == choices.count,
                  choices.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                throw WorkflowIssue("\(path)：枚举选项无效或重复。")
            }
        case .record(let fields):
            guard fields.count <= 256, Set(fields.map(\.name)).count == fields.count,
                  fields.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 256 }) else {
                throw WorkflowIssue("\(path)：记录字段无效或重复。")
            }
            for field in fields { try validateSchema(field.type, path: path + "." + field.name, depth: depth + 1) }
        case .list(let item), .optional(let item), .result(let item):
            try validateSchema(item, path: path, depth: depth + 1)
        }
    }

    static func singleBodyOutput(_ interface: WorkflowGraphInterface, purpose: String) throws -> WorkflowNamedOutput {
        if let named = interface.outputs.first(where: { $0.name == "output" }) { return named }
        guard interface.outputs.count == 1, let only = interface.outputs.first else {
            throw WorkflowIssue("\(purpose) body 必须声明 output 或唯一命名输出。")
        }
        return only
    }

    static func loopBodyOutput(_ interface: WorkflowGraphInterface) throws -> WorkflowNamedOutput {
        if let state = interface.outputs.first(where: { $0.name == "state" }) { return state }
        return try singleBodyOutput(interface, purpose: "Loop")
    }

    private static func topologicalOrder(
        nodes: Set<UUID>, outgoing: [UUID: [UUID]], indegree original: [UUID: Int]
    ) throws -> [UUID] {
        var indegree = original
        var ready = indegree.compactMap { $0.value == 0 ? $0.key : nil }.sorted(by: uuidOrder)
        var result: [UUID] = []
        while !ready.isEmpty {
            let current = ready.removeFirst()
            result.append(current)
            for next in (outgoing[current] ?? []).sorted(by: uuidOrder) {
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 {
                    ready.append(next)
                    ready.sort(by: uuidOrder)
                }
            }
        }
        guard result.count == nodes.count else { throw WorkflowIssue("工作流不能包含环。") }
        return result
    }

    private static func validateToolRecursion(_ tools: [WorkflowToolKey: WorkflowToolDefinition]) throws {
        var visiting = Set<WorkflowToolKey>()
        var visited = Set<WorkflowToolKey>()

        func references(in graph: WorkflowGraph) -> [WorkflowToolKey] {
            var result: [WorkflowToolKey] = []
            for node in graph.nodes {
                switch node.control {
                case .invoke(let reference):
                    result.append(.init(id: reference.id, version: reference.version))
                case .branch(_, let yes, let no):
                    result += references(in: yes)
                    result += references(in: no)
                case .map(let body, _), .loop(let body, _, _, _):
                    result += references(in: body)
                case nil:
                    break
                }
            }
            return result
        }

        func visit(_ key: WorkflowToolKey) throws {
            if visiting.contains(key) {
                throw WorkflowIssue("工具递归调用被拒绝：\(tools[key]?.name ?? key.id.uuidString)。")
            }
            if visited.contains(key) { return }
            guard let tool = tools[key] else { return }
            visiting.insert(key)
            for dependency in references(in: tool.graph) {
                guard tools[dependency] != nil else {
                    throw WorkflowIssue("工具引用了未提供的固定版本：\(dependency.id) v\(dependency.version)。")
                }
                try visit(dependency)
            }
            visiting.remove(key)
            visited.insert(key)
        }

        for key in tools.keys { try visit(key) }
    }

    private static func projectInterface(
        _ interface: WorkflowGraphInterface,
        graph: WorkflowGraph,
        selected: Set<UUID>,
        target: UUID?
    ) -> WorkflowGraphInterface {
        guard target != nil else { return interface }
        let publicNames = Set(graph.nodes.compactMap { node -> String? in
            guard selected.contains(node.id), node.operationID == "d.value.input",
                  let name = node.parameters["publicName"]?.string, !name.isEmpty else { return nil }
            return name
        })
        return .init(
            inputs: interface.inputs.filter { publicNames.contains($0.name) },
            outputs: interface.outputs.filter { selected.contains($0.nodeID) }
        )
    }

    private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    private static func connectionOrder(_ lhs: WorkflowConnection, _ rhs: WorkflowConnection) -> Bool {
        let left = [lhs.sourceNode.uuidString.lowercased(), lhs.sourcePort, lhs.targetPort]
        let right = [rhs.sourceNode.uuidString.lowercased(), rhs.sourcePort, rhs.targetPort]
        return left.lexicographicallyPrecedes(right)
    }

    private static let structuredControlIDs: Set<String> = [
        "d.control.branch", "d.control.map", "d.control.loop", "d.control.invoke",
    ]
    private static let assetPublicationIDs: Set<String> = [
        "d.text.input", "d.text.template", "d.text.removeBlankLines", "d.image.resize",
        "d.image.convert", "d.asset.reference",
    ]
}

private struct GraphValidation {
    let nodes: [UUID: WorkflowNode]
    let ports: [UUID: EffectivePorts]
    let order: [UUID]
}

private struct EffectivePorts {
    let inputs: [String: EffectivePort]
    let outputs: [String: EffectivePort]
}

private struct EffectivePort {
    let kinds: [WorkflowDataKind]
    let required: Bool
    let schema: WorkflowDataSchema?
}

private struct TargetPort: Hashable {
    let nodeID: UUID
    let port: String
}
