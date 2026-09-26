import Foundation

public enum WorkflowGraphSelection: Codable, Sendable, Equatable {
    case through(UUID)
    case only(UUID)
    case downstream(UUID, includingAnchor: Bool)
}

public struct WorkflowCallReference: Codable, Sendable, Equatable {
    public var address: WorkflowExecutionAddress
    public var stepID: UUID

    public init(address: WorkflowExecutionAddress, stepID: UUID) {
        self.address = address
        self.stepID = stepID
    }
}

public struct WorkflowHistoricalInput: Codable, Sendable, Equatable {
    public var destinationNodeID: UUID
    public var destinationPort: String
    public var sourceCall: WorkflowCallReference
    public var sourcePort: String

    public init(
        destinationNodeID: UUID,
        destinationPort: String,
        sourceCall: WorkflowCallReference,
        sourcePort: String
    ) {
        self.destinationNodeID = destinationNodeID
        self.destinationPort = destinationPort
        self.sourceCall = sourceCall
        self.sourcePort = sourcePort
    }
}

public struct WorkflowRunScope: Codable, Sendable, Equatable {
    public var version: Int
    public var selection: WorkflowGraphSelection
    public var originCall: WorkflowCallReference?
    public var historicalInputs: [WorkflowHistoricalInput]
    public var recomputeSelected: Bool

    public init(
        version: Int = 1,
        selection: WorkflowGraphSelection,
        originCall: WorkflowCallReference? = nil,
        historicalInputs: [WorkflowHistoricalInput] = [],
        recomputeSelected: Bool = false
    ) {
        self.version = version
        self.selection = selection
        self.originCall = originCall
        self.historicalInputs = historicalInputs
        self.recomputeSelected = recomputeSelected
    }
}

public struct WorkflowScopeBoundary: Sendable, Equatable {
    public var destinationNodeID: UUID
    public var destinationPort: String
    public var sourceNodeID: UUID
    public var sourcePort: String

    public init(destinationNodeID: UUID, destinationPort: String, sourceNodeID: UUID, sourcePort: String) {
        self.destinationNodeID = destinationNodeID
        self.destinationPort = destinationPort
        self.sourceNodeID = sourceNodeID
        self.sourcePort = sourcePort
    }
}

public struct WorkflowScopeSlice: Sendable, Equatable {
    public var plan: WorkflowPlan
    public var boundaries: [WorkflowScopeBoundary]

    public init(plan: WorkflowPlan, boundaries: [WorkflowScopeBoundary]) {
        self.plan = plan
        self.boundaries = boundaries
    }
}

public struct WorkflowScopeSource: Sendable, Equatable {
    public var graph: WorkflowGraph
    public var selection: WorkflowGraphSelection
    public var checkpoint: WorkflowPlanCheckpoint

    public init(graph: WorkflowGraph, selection: WorkflowGraphSelection, checkpoint: WorkflowPlanCheckpoint) {
        self.graph = graph
        self.selection = selection
        self.checkpoint = checkpoint
    }
}

public struct WorkflowResolvedCall: Sendable, Equatable {
    public var graph: WorkflowGraph
    public var plan: WorkflowPlan
    public var arguments: [String: WorkflowDatum]
    public var externalInputs: [UUID: [String: WorkflowValue]]
    public var modelDefaults: [String: String]
    public var originCall: WorkflowCallReference

    public init(
        graph: WorkflowGraph,
        plan: WorkflowPlan,
        arguments: [String: WorkflowDatum],
        externalInputs: [UUID: [String: WorkflowValue]],
        modelDefaults: [String: String],
        originCall: WorkflowCallReference
    ) {
        self.graph = graph
        self.plan = plan
        self.arguments = arguments
        self.externalInputs = externalInputs
        self.modelDefaults = modelDefaults
        self.originCall = originCall
    }
}

public enum WorkflowScopePlanner {
    public static func select(
        graph: WorkflowGraph,
        selection: WorkflowGraphSelection,
        tools: [WorkflowToolDefinition] = [],
        registry: WorkflowRegistry = .standard
    ) throws -> WorkflowScopeSlice {
        let compiler = WorkflowPlanCompiler(registry: registry)
        let plan: WorkflowPlan

        switch selection {
        case .through(let target):
            plan = try compiler.compile(graph, tools: tools, target: target)
        case .only(let target):
            plan = try compiler.compile(graph, tools: tools, target: target, only: true)
        case .downstream(let anchor, let includingAnchor):
            let complete = try compiler.compile(graph, tools: tools)
            guard graph.nodes.contains(where: { $0.id == anchor }) else {
                throw WorkflowIssue("局部运行锚点不存在。", nodeID: anchor)
            }
            var selected = Set<UUID>()
            var frontier = [anchor]
            if includingAnchor { selected.insert(anchor) }
            while let current = frontier.popLast() {
                for connection in graph.connections where connection.sourceNode == current {
                    if selected.insert(connection.targetNode).inserted {
                        frontier.append(connection.targetNode)
                    }
                }
            }
            guard !selected.isEmpty else {
                throw WorkflowIssue("局部运行范围为空。", nodeID: anchor)
            }
            plan = project(complete, graph: graph, selected: selected)
        }

        let selected = Set(plan.steps.map(\.node.id))
        guard !selected.isEmpty else { throw WorkflowIssue("局部运行范围为空。") }
        let boundaries = graph.connections.compactMap { connection -> WorkflowScopeBoundary? in
            guard selected.contains(connection.targetNode), !selected.contains(connection.sourceNode) else {
                return nil
            }
            return WorkflowScopeBoundary(
                destinationNodeID: connection.targetNode,
                destinationPort: connection.targetPort,
                sourceNodeID: connection.sourceNode,
                sourcePort: connection.sourcePort
            )
        }.sorted(by: boundaryOrder)
        return WorkflowScopeSlice(plan: plan, boundaries: boundaries)
    }

    public static func rebuild(
        graph: WorkflowGraph,
        selection: WorkflowGraphSelection,
        modelDefaults: [String: String],
        tools: [WorkflowToolDefinition] = [],
        registry: WorkflowRegistry = .standard
    ) throws -> WorkflowPlan {
        let selected = try select(graph: graph, selection: selection, tools: tools, registry: registry)
        return try WorkflowPlanBinding.freeze(selected.plan, defaults: modelDefaults, registry: registry)
    }

    public static func resolveCall(
        _ reference: WorkflowCallReference,
        source: WorkflowScopeSource,
        tools: [WorkflowToolDefinition] = [],
        registry: WorkflowRegistry = .standard
    ) throws -> WorkflowResolvedCall {
        try resolveCall(reference, source: source, tools: tools, registry: registry, requireTerminal: true)
    }

    /// Durable provenance stays valid while the original bound Call is explicitly retried.
    /// This internal path is not admission to create a new derivative from a live Call.
    static func resolveRetainedCall(_ reference: WorkflowCallReference, source: WorkflowScopeSource,
                                    tools: [WorkflowToolDefinition], registry: WorkflowRegistry) throws -> WorkflowResolvedCall {
        try resolveCall(reference, source: source, tools: tools, registry: registry, requireTerminal: false)
    }

    private static func resolveCall(_ reference: WorkflowCallReference, source: WorkflowScopeSource,
                                    tools: [WorkflowToolDefinition], registry: WorkflowRegistry,
                                    requireTerminal: Bool) throws -> WorkflowResolvedCall {
        let defaults = source.checkpoint.modelDefaults ?? [:]
        let trusted = try rebuild(
            graph: source.graph,
            selection: source.selection,
            modelDefaults: defaults,
            tools: tools,
            registry: registry
        )
        try WorkflowCheckpointValidation.validate(source.checkpoint, expected: trusted, registry: registry)
        guard reference.address.runID == source.checkpoint.runID else {
            throw WorkflowIssue("派生调用引用了其他运行。")
        }
        guard let record = source.checkpoint.records.first(where: { $0.address == reference.address }),
              record.step.id == reference.stepID else {
            throw WorkflowIssue("找不到完整地址和 stepID 同时匹配的调用记录。")
        }
        guard !requireTerminal || [.completed, .partial, .failed, .cancelled].contains(record.step.status) else {
            throw WorkflowIssue("此调用状态不能派生为新的运行。", nodeID: record.step.node.id)
        }
        guard record.step.inputsBound == true else {
            throw WorkflowIssue("调用尚未绑定输入，不能派生为新的运行。", nodeID: record.step.node.id)
        }

        let located = try locateCall(
            address: reference.address,
            rootGraph: source.graph,
            rootPlan: trusted,
            tools: tools
        )
        guard case .call = located.step.kind else {
            throw WorkflowIssue("只有具体 Call 记录可以派生运行。", nodeID: located.node.id)
        }
        guard record.step.node.id == located.node.id else {
            throw WorkflowIssue("调用记录的节点身份与完整地址不一致。", nodeID: located.node.id)
        }

        let derivedPlan = try rebuild(
            graph: located.graph,
            selection: .only(located.node.id),
            modelDefaults: defaults,
            tools: tools,
            registry: registry
        )
        guard derivedPlan.steps.count == 1, let derivedStep = derivedPlan.steps.first,
              derivedStep.sourceSignature == record.step.signature else {
            throw WorkflowIssue("派生调用的独立重建签名与历史记录不一致。", nodeID: located.node.id)
        }
        let arguments = try projectedArguments(plan: derivedPlan, runtimeNode: record.step.node)
        return WorkflowResolvedCall(
            graph: located.graph,
            plan: derivedPlan,
            arguments: arguments,
            externalInputs: [located.node.id: record.step.inputs],
            modelDefaults: defaults,
            originCall: reference
        )
    }

    public static func resolveHistoricalInputs(
        _ pins: [WorkflowHistoricalInput],
        destination: WorkflowScopeSource,
        sources: [WorkflowScopeSource],
        tools: [WorkflowToolDefinition] = [],
        registry: WorkflowRegistry = .standard
    ) throws -> [UUID: [String: WorkflowValue]] {
        let destinationDefaults = destination.checkpoint.modelDefaults ?? [:]
        let destinationSlice = try select(
            graph: destination.graph,
            selection: destination.selection,
            tools: tools,
            registry: registry
        )
        let destinationPlan = try WorkflowPlanBinding.freeze(
            destinationSlice.plan,
            defaults: destinationDefaults,
            registry: registry
        )
        try WorkflowCheckpointValidation.validate(
            destination.checkpoint,
            expected: destinationPlan,
            registry: registry
        )

        var sourcesByRunID: [UUID: WorkflowScopeSource] = [:]
        var trustedSourcePlans: [UUID: WorkflowPlan] = [:]
        for source in sources {
            guard sourcesByRunID[source.checkpoint.runID] == nil else {
                throw WorkflowIssue("历史来源 runID 重复。")
            }
            let expected = try rebuild(
                graph: source.graph,
                selection: source.selection,
                modelDefaults: source.checkpoint.modelDefaults ?? [:],
                tools: tools,
                registry: registry
            )
            try WorkflowCheckpointValidation.validate(source.checkpoint, expected: expected, registry: registry)
            sourcesByRunID[source.checkpoint.runID] = source
            trustedSourcePlans[source.checkpoint.runID] = expected
        }

        let boundaries = Dictionary(grouping: destinationSlice.boundaries) { BoundaryKey($0) }
        guard boundaries.values.allSatisfy({ $0.count == 1 }) else {
            throw WorkflowIssue("局部计划边界包含重复目标端口。")
        }
        guard pins.count == destinationSlice.boundaries.count else {
            throw WorkflowIssue("历史输入必须一对一覆盖全部局部计划边界。")
        }
        var pinsByBoundary: [BoundaryKey: WorkflowHistoricalInput] = [:]
        for pin in pins {
            let key = BoundaryKey(nodeID: pin.destinationNodeID, port: pin.destinationPort)
            guard boundaries[key] != nil else {
                throw WorkflowIssue("历史输入覆盖了非边界或未知输入。", nodeID: pin.destinationNodeID, port: pin.destinationPort)
            }
            guard pinsByBoundary[key] == nil else {
                throw WorkflowIssue("同一边界输入不能重复固定。", nodeID: pin.destinationNodeID, port: pin.destinationPort)
            }
            pinsByBoundary[key] = pin
        }

        var result: [UUID: [String: WorkflowValue]] = [:]
        for boundary in destinationSlice.boundaries {
            let key = BoundaryKey(boundary)
            guard let pin = pinsByBoundary[key] else {
                throw WorkflowIssue("局部计划边界缺少历史输入。", nodeID: boundary.destinationNodeID, port: boundary.destinationPort)
            }
            guard pin.sourcePort == boundary.sourcePort else {
                throw WorkflowIssue("历史输入端口不是原连接的来源端口。", nodeID: boundary.sourceNodeID, port: pin.sourcePort)
            }
            let runID = pin.sourceCall.address.runID
            guard let source = sourcesByRunID[runID], let sourcePlan = trustedSourcePlans[runID] else {
                throw WorkflowIssue("历史输入引用了未提供的精确运行。")
            }
            guard let record = source.checkpoint.records.first(where: { $0.address == pin.sourceCall.address }),
                  record.step.id == pin.sourceCall.stepID else {
                throw WorkflowIssue("历史输入找不到完整地址和 stepID 同时匹配的调用。")
            }
            let located = try locateCall(
                address: pin.sourceCall.address,
                rootGraph: source.graph,
                rootPlan: sourcePlan,
                tools: tools
            )
            guard located.graph.id == destination.graph.id else {
                throw WorkflowIssue("历史输入来源不属于目标工作流图。", nodeID: boundary.sourceNodeID, port: boundary.sourcePort)
            }
            guard located.node.id == boundary.sourceNodeID,
                  record.step.node.id == boundary.sourceNodeID else {
                throw WorkflowIssue("历史输入不是原连接的来源节点。", nodeID: boundary.sourceNodeID, port: boundary.sourcePort)
            }
            guard [.completed, .partial].contains(record.step.status),
                  let value = record.step.outputs[boundary.sourcePort] else {
                throw WorkflowIssue("历史来源没有可固定的 completed/partial 真实输出。", nodeID: boundary.sourceNodeID, port: boundary.sourcePort)
            }
            try validate(
                value,
                forDestinationNode: boundary.destinationNodeID,
                port: boundary.destinationPort,
                in: destinationPlan,
                tools: tools,
                registry: registry
            )
            guard result[boundary.destinationNodeID]?[boundary.destinationPort] == nil else {
                throw WorkflowIssue("历史输入重复覆盖目标端口。", nodeID: boundary.destinationNodeID, port: boundary.destinationPort)
            }
            result[boundary.destinationNodeID, default: [:]][boundary.destinationPort] = value
        }
        return result
    }

    private static func project(
        _ plan: WorkflowPlan,
        graph: WorkflowGraph,
        selected: Set<UUID>
    ) -> WorkflowPlan {
        let publicNames = Set(graph.nodes.compactMap { node -> String? in
            guard selected.contains(node.id), node.operationID == "d.value.input",
                  let name = node.parameters["publicName"]?.string, !name.isEmpty else { return nil }
            return name
        })
        var result = plan
        result.steps = plan.steps.filter { selected.contains($0.node.id) }
        result.interface = .init(
            inputs: plan.interface.inputs.filter { publicNames.contains($0.name) },
            outputs: plan.interface.outputs.filter { selected.contains($0.nodeID) }
        )
        return result
    }

    private static func projectedArguments(
        plan: WorkflowPlan,
        runtimeNode: WorkflowNode
    ) throws -> [String: WorkflowDatum] {
        guard !plan.interface.inputs.isEmpty else { return [:] }
        guard plan.steps.count == 1, plan.steps[0].node.id == runtimeNode.id,
              runtimeNode.operationID == "d.value.input",
              let publicName = runtimeNode.parameters["publicName"]?.string,
              let value = runtimeNode.dataConfiguration?.value else {
            throw WorkflowIssue("派生调用无法从已验证运行节点恢复公开输入。", nodeID: runtimeNode.id)
        }
        guard let field = plan.interface.inputs.first(where: { $0.name == publicName }),
              plan.interface.inputs.count == 1 else {
            throw WorkflowIssue("派生调用的公开输入投影与运行节点不一致。", nodeID: runtimeNode.id)
        }
        try value.validate(as: field.type)
        return [publicName: value]
    }

    private static func locateCall(
        address: WorkflowExecutionAddress,
        rootGraph: WorkflowGraph,
        rootPlan: WorkflowPlan,
        tools: [WorkflowToolDefinition]
    ) throws -> LocatedCall {
        var graph = rootGraph
        var plan = rootPlan
        var offset = 0
        while true {
            guard offset < address.path.count,
                  case .node(let nodeID) = address.path[offset],
                  let node = graph.nodes.first(where: { $0.id == nodeID }),
                  let step = plan.steps.first(where: { $0.node.id == nodeID }) else {
                throw WorkflowIssue("调用完整地址不属于独立重建的图和计划。")
            }
            if offset == address.path.count - 1 {
                return LocatedCall(graph: graph, node: node, step: step)
            }
            guard offset + 1 < address.path.count else {
                throw WorkflowIssue("调用完整地址缺少控制选择器。", nodeID: nodeID)
            }
            let selector = address.path[offset + 1]
            switch (node.control, step.kind, selector) {
            case let (.branch(_, yesGraph, noGraph), .branch(_, yesPlan, noPlan), .branch(selected)):
                graph = selected ? yesGraph : noGraph
                plan = selected ? yesPlan : noPlan
            case let (.map(bodyGraph, _), .map(bodyPlan, _), .item):
                graph = bodyGraph
                plan = bodyPlan
            case let (.loop(bodyGraph, _, _, _), .loop(bodyPlan, _, _, _), .iteration):
                graph = bodyGraph
                plan = bodyPlan
            case let (.invoke(nodeReference), .invoke(planReference, bodyPlan), .tool(addressReference)):
                guard nodeReference == planReference, planReference == addressReference,
                      let tool = tools.first(where: { $0.id == planReference.id && $0.version == planReference.version }),
                      try WorkflowPlanCompiler.digest(tool) == planReference.digest else {
                    throw WorkflowIssue("调用地址中的工具身份、版本或摘要不匹配。", nodeID: nodeID)
                }
                graph = tool.graph
                plan = bodyPlan
            default:
                throw WorkflowIssue("调用地址选择器与冻结控制结构不匹配。", nodeID: nodeID)
            }
            offset += 2
        }
    }

    private static func validate(
        _ value: WorkflowValue,
        forDestinationNode nodeID: UUID,
        port: String,
        in plan: WorkflowPlan,
        tools: [WorkflowToolDefinition],
        registry: WorkflowRegistry
    ) throws {
        guard let step = plan.steps.first(where: { $0.node.id == nodeID }) else {
            throw WorkflowIssue("历史输入目标不在局部计划中。", nodeID: nodeID, port: port)
        }
        let kinds: [WorkflowDataKind]
        let schema: WorkflowDataSchema?
        if case .invoke(_, let body) = step.kind,
           let field = body.interface.inputs.first(where: { $0.name == port }) {
            kinds = field.type.portKinds
            schema = field.type
        } else {
            guard let definition = registry.definition(for: step.node, tools: tools),
                  let input = definition.inputs.first(where: { $0.id == port }) else {
                throw WorkflowIssue("历史输入目标端口不存在。", nodeID: nodeID, port: port)
            }
            kinds = input.kinds
            if case .loop(_, let stateSchema, _, _) = step.kind, port == "input" {
                schema = stateSchema
            } else {
                schema = step.node.dataConfiguration?.fields.first(where: { $0.name == port })?.type
            }
        }
        guard kinds.contains(value.kind) else {
            throw WorkflowIssue("历史输入类型与目标端口不兼容。", nodeID: nodeID, port: port)
        }
        if let schema {
            guard let datum = value.datum else {
                throw WorkflowIssue("历史输入不能表示为目标端口要求的数据结构。", nodeID: nodeID, port: port)
            }
            try datum.validate(as: schema)
        }
        switch value {
        case .data(let datum):
            try datum.validate()
        case .asset(let reference):
            guard reference.sha256.count == 64, reference.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw WorkflowIssue("历史资产摘要无效。", nodeID: nodeID, port: port)
            }
        case .collection(let candidates):
            guard Set(candidates.map(\.id)).count == candidates.count else {
                throw WorkflowIssue("历史候选身份重复。", nodeID: nodeID, port: port)
            }
        case .receipt(let receipt):
            guard receipt.names.count == receipt.hashes.count else {
                throw WorkflowIssue("历史导出回执结构无效。", nodeID: nodeID, port: port)
            }
        }
    }

    private static func boundaryOrder(_ lhs: WorkflowScopeBoundary, _ rhs: WorkflowScopeBoundary) -> Bool {
        let left = [lhs.destinationNodeID.uuidString.lowercased(), lhs.destinationPort,
                    lhs.sourceNodeID.uuidString.lowercased(), lhs.sourcePort]
        let right = [rhs.destinationNodeID.uuidString.lowercased(), rhs.destinationPort,
                     rhs.sourceNodeID.uuidString.lowercased(), rhs.sourcePort]
        return left.lexicographicallyPrecedes(right)
    }
}

private struct BoundaryKey: Hashable {
    let nodeID: UUID
    let port: String

    init(nodeID: UUID, port: String) {
        self.nodeID = nodeID
        self.port = port
    }

    init(_ boundary: WorkflowScopeBoundary) {
        self.init(nodeID: boundary.destinationNodeID, port: boundary.destinationPort)
    }
}

private struct LocatedCall {
    let graph: WorkflowGraph
    let node: WorkflowNode
    let step: WorkflowPlannedStep
}
