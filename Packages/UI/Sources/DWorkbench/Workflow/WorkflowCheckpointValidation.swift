import Foundation

/// Pure structural validation for durable workflow checkpoints.
///
/// This proves that a checkpoint is internally consistent with a separately trusted,
/// frozen plan. It is not a signature check and never executes operations or resolves assets.
public enum WorkflowCheckpointValidation {
    public static func validate(
        _ checkpoint: WorkflowPlanCheckpoint,
        expected: WorkflowPlan,
        registry: WorkflowRegistry = .standard
    ) throws {
        guard checkpoint.plan == expected else {
            throw WorkflowIssue("Checkpoint plan does not match the trusted expected plan.")
        }
        var validator = CheckpointValidator(checkpoint: checkpoint, registry: registry)
        try validator.validate()
    }

    /// Returns every explicit published-asset reference carried by the checkpoint.
    /// The references are de-duplicated in first-seen order; no URL or file is accessed.
    public static func assetReferences(
        in checkpoint: WorkflowPlanCheckpoint
    ) throws -> [WorkflowAssetReference] {
        var collector = CheckpointAssetCollector()
        try collector.collect(checkpoint)
        return collector.references
    }
    /// Drafts may be incomplete, so collect references without compiling them.
    public static func assetReferences(in graph: WorkflowGraph) throws -> [WorkflowAssetReference] {
        var collector = CheckpointAssetCollector()
        try collector.collect(graph: graph, depth: 0)
        return collector.references
    }
}

private struct CheckpointValidator {
    private static let maximumStaticSteps = 4_096
    private static let maximumRecords = 65_536
    private static let maximumPlanDepth = 16
    private static let maximumAddressComponents = maximumPlanDepth * 2 + 1
    private static let maximumTextBytes = 1_048_576

    let checkpoint: WorkflowPlanCheckpoint
    let registry: WorkflowRegistry
    private var recordsByAddress: [WorkflowExecutionAddress: WorkflowPlanCallRecord] = [:]

    init(checkpoint: WorkflowPlanCheckpoint, registry: WorkflowRegistry) {
        self.checkpoint = checkpoint
        self.registry = registry
    }

    mutating func validate() throws {
        guard checkpoint.records.count <= Self.maximumRecords else {
            throw WorkflowIssue("Checkpoint call records exceed the 65536-record limit.")
        }
        try validateText(checkpoint.error, purpose: "checkpoint error")

        var staticStepCount = 0
        try validatePlan(checkpoint.plan, depth: 0, staticStepCount: &staticStepCount)
        try validateArguments(checkpoint.arguments, for: checkpoint.plan, allowExtra: false)
        try validateExternalInputs()

        var stepIDs = Set<UUID>()
        for record in checkpoint.records {
            guard record.address.runID == checkpoint.runID else {
                throw WorkflowIssue("A call record refers to a different runID.")
            }
            guard !record.address.path.isEmpty,
                  record.address.path.count <= Self.maximumAddressComponents else {
                throw WorkflowIssue("A call-record address is empty or exceeds the nesting limit.")
            }
            guard recordsByAddress[record.address] == nil else {
                throw WorkflowIssue("Call-record addresses must be unique.")
            }
            guard stepIDs.insert(record.step.id).inserted else {
                throw WorkflowIssue("Call-record stepID values must be unique.")
            }
            recordsByAddress[record.address] = record
        }

        for record in checkpoint.records {
            let resolved = try resolve(record.address)
            try validate(record, resolved: resolved)
        }
        try validateCheckpointOutputs()

        // This also validates record-shaped music source references which are not
        // represented by WorkflowDatum.asset.
        _ = try WorkflowCheckpointValidation.assetReferences(in: checkpoint)
    }

    private func validatePlan(
        _ plan: WorkflowPlan,
        depth: Int,
        staticStepCount: inout Int
    ) throws {
        guard plan.version == 1 else { throw WorkflowIssue("Unsupported structured plan version.") }
        guard depth <= Self.maximumPlanDepth else {
            throw WorkflowIssue("Structured plan nesting exceeds 16 levels.")
        }
        staticStepCount += plan.steps.count
        guard staticStepCount <= Self.maximumStaticSteps else {
            throw WorkflowIssue("Expanded structured plan exceeds 4096 static steps.")
        }
        guard Set(plan.steps.map(\.node.id)).count == plan.steps.count else {
            throw WorkflowIssue("A plan contains duplicate node identities.")
        }
        try validateInterface(plan.interface, plan: plan)

        var stepIndexes: [UUID: Int] = [:]
        for (index, step) in plan.steps.enumerated() { stepIndexes[step.node.id] = index }

        for (index, step) in plan.steps.enumerated() {
            try validateNode(step.node)
            try validateKind(step, depth: depth, staticStepCount: &staticStepCount)

            guard step.inputs.count <= 256,
                  Set(step.inputs.map(\.port)).count == step.inputs.count,
                  step.inputs.allSatisfy({ !$0.port.isEmpty && $0.port.utf8.count <= 256 &&
                      !$0.sourcePort.isEmpty && $0.sourcePort.utf8.count <= 256 }) else {
                throw WorkflowIssue("A planned node has duplicate or invalid input bindings.", nodeID: step.node.id)
            }
            let targetPorts = try inputPorts(for: step, node: step.node)
            for input in step.inputs {
                guard let target = targetPorts[input.port] else {
                    throw WorkflowIssue("A planned input refers to an unknown target port.", nodeID: step.node.id, port: input.port)
                }
                if let sourceIndex = stepIndexes[input.sourceNode] {
                    guard sourceIndex < index else {
                        throw WorkflowIssue("A planned input does not refer to an earlier node.", nodeID: step.node.id, port: input.port)
                    }
                    let source = plan.steps[sourceIndex]
                    let sourcePorts = try outputPorts(for: source, node: source.node)
                    guard let output = sourcePorts[input.sourcePort] else {
                        throw WorkflowIssue("A planned input refers to an unknown source port.", nodeID: input.sourceNode, port: input.sourcePort)
                    }
                    guard !Set(target.kinds).isDisjoint(with: output.kinds) else {
                        throw WorkflowIssue("A planned connection has incompatible port types.", nodeID: step.node.id, port: input.port)
                    }
                }
            }
        }
    }

    private func validateKind(
        _ step: WorkflowPlannedStep,
        depth: Int,
        staticStepCount: inout Int
    ) throws {
        switch (step.kind, step.node.control) {
        case (.call, nil):
            guard !Self.structuredControlIDs.contains(step.node.operationID) else {
                throw WorkflowIssue("A structured control node was compiled as a plain call.", nodeID: step.node.id)
            }
        case let (.branch(predicate, yes, no), .branch(nodePredicate, _, _)):
            guard step.node.operationID == "d.control.branch", predicate == nodePredicate,
                  step.effect == .pure else {
                throw WorkflowIssue("Branch plan metadata does not match its node.", nodeID: step.node.id)
            }
            try validateRule(predicate, nodeID: step.node.id)
            try validatePlan(yes, depth: depth + 1, staticStepCount: &staticStepCount)
            try validatePlan(no, depth: depth + 1, staticStepCount: &staticStepCount)
            guard try bodyOutput(yes.interface, purpose: "Branch then").schema ==
                    bodyOutput(no.interface, purpose: "Branch otherwise").schema else {
                throw WorkflowIssue("Branch child output schemas differ.", nodeID: step.node.id)
            }
        case let (.map(body, continueOnFailure), .map(_, nodeContinue)):
            guard step.node.operationID == "d.control.map", continueOnFailure == nodeContinue,
                  step.effect == .pure else {
                throw WorkflowIssue("Map plan metadata does not match its node.", nodeID: step.node.id)
            }
            try validatePlan(body, depth: depth + 1, staticStepCount: &staticStepCount)
            _ = try bodyOutput(body.interface, purpose: "Map")
        case let (.loop(body, stateSchema, maximum, until), .loop(_, nodeSchema, nodeMaximum, nodeUntil)):
            guard step.node.operationID == "d.control.loop", stateSchema == nodeSchema,
                  maximum == nodeMaximum, until == nodeUntil, step.effect == .pure,
                  (1...1_000).contains(maximum) else {
                throw WorkflowIssue("Loop plan metadata does not match its node.", nodeID: step.node.id)
            }
            try stateSchema.validateDefinition()
            try validateRule(until, nodeID: step.node.id)
            try validatePlan(body, depth: depth + 1, staticStepCount: &staticStepCount)
            guard try loopBodyOutput(body.interface).schema == stateSchema else {
                throw WorkflowIssue("Loop body output does not match its state schema.", nodeID: step.node.id)
            }
        case let (.invoke(reference, body), .invoke(nodeReference)):
            guard step.node.operationID == "d.control.invoke", reference == nodeReference,
                  step.effect == .pure, reference.version > 0,
                  reference.digest.count == 64,
                  reference.digest.utf8.allSatisfy(Self.isLowercaseHex) else {
                throw WorkflowIssue("Invoke plan metadata or digest does not match its node.", nodeID: step.node.id)
            }
            try validatePlan(body, depth: depth + 1, staticStepCount: &staticStepCount)
            if let fields = step.node.dataConfiguration?.fields {
                guard fields == body.interface.inputs else {
                    throw WorkflowIssue("Invoke configured fields do not match the frozen tool interface.", nodeID: step.node.id)
                }
            }
        default:
            throw WorkflowIssue("A plan-step kind does not correspond to its actual node control.", nodeID: step.node.id)
        }
    }

    private func validateInterface(_ interface: WorkflowGraphInterface, plan: WorkflowPlan) throws {
        guard interface.inputs.count <= 256, interface.outputs.count <= 256,
              Set(interface.inputs.map(\.name)).count == interface.inputs.count,
              Set(interface.outputs.map(\.name)).count == interface.outputs.count else {
            throw WorkflowIssue("A plan interface has duplicate names or exceeds its limit.")
        }
        for field in interface.inputs {
            guard !field.name.isEmpty, field.name.utf8.count <= 256 else {
                throw WorkflowIssue("A plan input name is invalid.")
            }
            try field.type.validateDefinition()
        }

        let steps = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.node.id, $0) })
        for output in interface.outputs {
            guard !output.name.isEmpty, output.name.utf8.count <= 256,
                  !output.port.isEmpty, output.port.utf8.count <= 256,
                  let step = steps[output.nodeID] else {
                throw WorkflowIssue("A named plan output is invalid or refers to an unknown node.", nodeID: output.nodeID, port: output.port)
            }
            try output.schema.validateDefinition()
            let ports = try outputPorts(for: step, node: step.node)
            guard let port = ports[output.port],
                  !Set(port.kinds).isDisjoint(with: output.schema.portKinds) else {
                throw WorkflowIssue("A named plan output has an unknown or incompatible port.", nodeID: output.nodeID, port: output.port)
            }
        }

        let declared = Set(interface.inputs.map(\.name))
        var publicNames = Set<String>()
        for step in plan.steps where step.node.operationID == "d.value.input" {
            let name = step.node.parameters["publicName"]?.string ?? ""
            if name.isEmpty { continue }
            guard name.utf8.count <= 256, publicNames.insert(name).inserted,
                  declared.contains(name) else {
                throw WorkflowIssue("A public input name is duplicate or absent from the plan interface.", nodeID: step.node.id)
            }
        }
        guard publicNames == declared else {
            throw WorkflowIssue("Every plan interface input must have one public data-input node.")
        }
    }

    private func validateNode(_ node: WorkflowNode) throws {
        guard !node.operationID.isEmpty, node.operationID.utf8.count <= 256,
              node.title.utf8.count <= Self.maximumTextBytes else {
            throw WorkflowIssue("A workflow node contains an invalid operation ID or title.", nodeID: node.id)
        }
        if let configuration = node.dataConfiguration {
            try configuration.schema?.validateDefinition()
            try configuration.value?.validate()
            try WorkflowDataSchema.record(configuration.fields).validateDefinition()
            guard configuration.path.count <= 24,
                  configuration.path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
                  configuration.rules.count <= 256,
                  configuration.items.count <= 4_096,
                  Set(configuration.items.map(\.id)).count == configuration.items.count else {
                throw WorkflowIssue("A node data configuration exceeds its bounds.", nodeID: node.id)
            }
            for item in configuration.items {
                guard !item.id.isEmpty, item.id.utf8.count <= 256 else {
                    throw WorkflowIssue("A configured item identity is invalid.", nodeID: node.id)
                }
                try item.value.validate()
            }
            for rule in configuration.rules {
                guard rule.path.count <= 24,
                      rule.path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                    throw WorkflowIssue("A configured rule path is invalid.", nodeID: node.id)
                }
                try rule.value?.validate()
                if rule.comparison != .exists, rule.value == nil {
                    throw WorkflowIssue("A comparison rule is missing its right-hand value.", nodeID: node.id)
                }
            }
            switch node.operationID {
            case "d.value.record":
                if let value = configuration.value {
                    try value.validate(as: .record(configuration.fields))
                }
            case "d.value.list":
                guard let element = configuration.schema else {
                    throw WorkflowIssue("A List node is missing its element schema.", nodeID: node.id)
                }
                for item in configuration.items { try item.value.validate(as: element) }
                let mode = node.parameters["mode"]?.string
                let portSchema: WorkflowDataSchema = mode == "concat" ? .list(element) : element
                guard configuration.fields.allSatisfy({ $0.type == portSchema }) else {
                    throw WorkflowIssue("A List node's configured input schemas do not match its mode.", nodeID: node.id)
                }
            case "d.value.field":
                guard configuration.schema != nil else {
                    throw WorkflowIssue("A Field node is missing its result schema.", nodeID: node.id)
                }
            default:
                break
            }
        }
        if ["d.value.list", "d.value.field"].contains(node.operationID), node.dataConfiguration == nil {
            throw WorkflowIssue("A typed data node is missing its data configuration.", nodeID: node.id)
        }
        if let reference = node.assetReference { try validateAsset(reference) }
        try registry.validate(node)
    }

    private func validateExternalInputs() throws {
        guard checkpoint.externalInputs.count <= checkpoint.plan.steps.count else {
            throw WorkflowIssue("externalInputs contains too many node entries.")
        }
        let steps = Dictionary(uniqueKeysWithValues: checkpoint.plan.steps.map { ($0.node.id, $0) })
        let selected = Set(steps.keys)
        let nestedNodeIDs = nodeIDsInNestedPlans(of: checkpoint.plan)
        for (nodeID, values) in checkpoint.externalInputs {
            guard let step = steps[nodeID] else {
                throw WorkflowIssue("externalInputs refers to a non-top-level plan node.", nodeID: nodeID)
            }
            guard !nestedNodeIDs.contains(nodeID) else {
                throw WorkflowIssue("externalInputs is ambiguous with a nested plan node.", nodeID: nodeID)
            }
            guard values.count <= 256 else {
                throw WorkflowIssue("externalInputs contains too many ports.", nodeID: nodeID)
            }
            let ports = try inputPorts(for: step, node: step.node)
            for (name, value) in values {
                guard let port = ports[name] else {
                    throw WorkflowIssue("externalInputs refers to an unknown port.", nodeID: nodeID, port: name)
                }
                guard !step.inputs.contains(where: { $0.port == name && selected.contains($0.sourceNode) }) else {
                    throw WorkflowIssue("externalInputs overrides a plan-internal connection.", nodeID: nodeID, port: name)
                }
                try validateValue(value, port: port, nodeID: nodeID, name: name)
            }
        }
    }

    private func nodeIDsInNestedPlans(of plan: WorkflowPlan) -> Set<UUID> {
        var result = Set<UUID>()
        func visit(_ child: WorkflowPlan) {
            for step in child.steps {
                result.insert(step.node.id)
                switch step.kind {
                case .call: break
                case .branch(_, let yes, let no): visit(yes); visit(no)
                case .map(let body, _), .loop(let body, _, _, _), .invoke(_, let body): visit(body)
                }
            }
        }
        for step in plan.steps {
            switch step.kind {
            case .call: break
            case .branch(_, let yes, let no): visit(yes); visit(no)
            case .map(let body, _), .loop(let body, _, _, _), .invoke(_, let body): visit(body)
            }
        }
        return result
    }

    private func resolve(_ address: WorkflowExecutionAddress) throws -> ResolvedRecord {
        var plan = checkpoint.plan
        var arguments = checkpoint.arguments
        var basePath: [WorkflowAddressComponent] = []
        var offset = 0
        var nestedDepth = 0

        while true {
            guard offset < address.path.count,
                  case .node(let nodeID) = address.path[offset],
                  let step = plan.steps.first(where: { $0.node.id == nodeID }) else {
                throw WorkflowIssue("A call-record address does not resolve to a planned node.")
            }
            let nodeAddress = WorkflowExecutionAddress(
                runID: checkpoint.runID,
                path: basePath + [.node(nodeID)]
            )
            if offset == address.path.count - 1 {
                return ResolvedRecord(plan: plan, step: step, basePath: basePath, arguments: arguments)
            }

            guard let parent = recordsByAddress[nodeAddress] else {
                throw WorkflowIssue("A nested call record has no parent call record.", nodeID: nodeID)
            }
            guard parent.step.inputsBound == true else {
                throw WorkflowIssue("A nested call record has a parent whose inputs were not bound.", nodeID: nodeID)
            }
            guard offset + 1 < address.path.count else {
                throw WorkflowIssue("A nested call-record address is incomplete.", nodeID: nodeID)
            }
            let selector = address.path[offset + 1]
            let child: WorkflowPlan
            let childArguments: [String: WorkflowDatum]

            switch (step.kind, selector) {
            case let (.branch(predicate, yes, no), .branch(selected)):
                let input = try requiredDatum(parent.step.inputs["input"], nodeID: nodeID, port: "input")
                guard try predicate.matches(input) == selected else {
                    throw WorkflowIssue("A Branch address selects an impossible branch.", nodeID: nodeID)
                }
                child = selected ? yes : no
                if case .record(_, let fields) = input { childArguments = fields }
                else { childArguments = ["input": input] }

            case let (.map(body, _), .item(itemID)):
                let input = try requiredDatum(parent.step.inputs["input"], nodeID: nodeID, port: "input")
                guard case .list(_, let items) = input,
                      let item = items.first(where: { $0.id == itemID }) else {
                    throw WorkflowIssue("A Map address refers to an item outside its bound List.", nodeID: nodeID)
                }
                let shared = try sharedFields(parent.step.inputs["shared"], nodeID: nodeID)
                let reserved: [String: WorkflowDatum] = [
                    "item": item.value,
                    "value": item.value,
                    "index": .number(Double(try itemOffset(itemID, in: items) + 1), unit: nil),
                ]
                guard Set(shared.keys).isDisjoint(with: reserved.keys) else {
                    throw WorkflowIssue("Map shared fields conflict with item/value/index.", nodeID: nodeID)
                }
                child = body
                childArguments = shared.merging(reserved) { current, _ in current }

            case let (.loop(body, stateSchema, maximum, until), .iteration(iteration)):
                guard (1...maximum).contains(iteration) else {
                    throw WorkflowIssue("A Loop address has an out-of-range iteration.", nodeID: nodeID)
                }
                let shared = try sharedFields(parent.step.inputs["shared"], nodeID: nodeID)
                guard shared["state"] == nil, shared["iteration"] == nil else {
                    throw WorkflowIssue("Loop shared fields override state/iteration.", nodeID: nodeID)
                }
                let state: WorkflowDatum
                if iteration == 1 {
                    state = try requiredDatum(parent.step.inputs["input"], nodeID: nodeID, port: "input")
                } else {
                    let output = try loopBodyOutput(body.interface)
                    let priorAddress = WorkflowExecutionAddress(
                        runID: checkpoint.runID,
                        path: basePath + [.node(nodeID), .iteration(iteration - 1), .node(output.nodeID)]
                    )
                    guard let prior = recordsByAddress[priorAddress],
                          [.completed, .partial].contains(prior.step.status),
                          let value = prior.step.outputs[output.port] else {
                        throw WorkflowIssue("A Loop iteration cannot recover the prior state.", nodeID: nodeID)
                    }
                    state = try requiredDatum(value, nodeID: nodeID, port: output.port)
                }
                try state.validate(as: stateSchema)
                guard try until.matches(state) == false else {
                    throw WorkflowIssue("A Loop iteration exists after its exit condition was met.", nodeID: nodeID)
                }
                child = body
                childArguments = shared.merging([
                    "state": state,
                    "iteration": .number(Double(iteration), unit: nil),
                ]) { current, _ in current }

            case let (.invoke(reference, body), .tool(addressReference)):
                guard reference == addressReference else {
                    throw WorkflowIssue("An Invoke address does not match the frozen tool reference.", nodeID: nodeID)
                }
                var converted: [String: WorkflowDatum] = [:]
                for field in body.interface.inputs {
                    guard let value = parent.step.inputs[field.name]?.datum else {
                        if field.required {
                            throw WorkflowIssue("Invoke parent inputs omit a required tool argument.", nodeID: nodeID, port: field.name)
                        }
                        continue
                    }
                    try value.validate(as: field.type)
                    converted[field.name] = value
                }
                child = body
                childArguments = converted

            default:
                throw WorkflowIssue("A call-record address selector does not match its planned control node.", nodeID: nodeID)
            }

            nestedDepth += 1
            guard nestedDepth <= Self.maximumPlanDepth else {
                throw WorkflowIssue("A call-record address exceeds the plan nesting limit.")
            }
            try validateArguments(
                childArguments,
                for: child,
                allowExtra: {
                    switch step.kind { case .invoke: false; default: true }
                }()
            )
            basePath.append(.node(nodeID))
            basePath.append(selector)
            plan = child
            arguments = childArguments
            offset += 2
        }
    }

    private func validate(_ record: WorkflowPlanCallRecord, resolved: ResolvedRecord) throws {
        let step = resolved.step
        let runtimeNode = try nodeForArguments(
            step.node,
            arguments: resolved.arguments,
            interface: resolved.plan.interface
        )
        guard record.step.node == runtimeNode else {
            throw WorkflowIssue("A call record changed static node fields or an invalid public input value.", nodeID: step.node.id)
        }
        try validateNode(record.step.node)
        let signature = step.sourceSignature ??
            "\(resolved.plan.graphID.uuidString.lowercased()):\(resolved.plan.graphRevision.uuidString.lowercased())"
        guard record.step.signature == signature else {
            throw WorkflowIssue("A call record has the wrong plan signature.", nodeID: step.node.id)
        }
        try validateText(record.step.error, purpose: "step error")
        if let draft = record.step.reviewTextDraft { try WorkflowDatum.text(draft).validate() }

        if record.step.inputsBound == true {
            let expectedInputs = try boundInputs(for: resolved, runtimeNode: runtimeNode)
            guard record.step.inputs == expectedInputs else {
                throw WorkflowIssue("A call record's bound inputs do not match the plan.", nodeID: step.node.id)
            }
            let ports = try inputPorts(for: step, node: runtimeNode)
            try validatePortValues(
                record.step.inputs,
                ports: ports,
                nodeID: step.node.id,
                requireAll: true
            )
        } else {
            let mayBeUnbound: [WorkflowStepStatus] = [.queued, .failed, .cancelled, .interrupted]
            guard record.step.inputs.isEmpty, mayBeUnbound.contains(record.step.status) else {
                throw WorkflowIssue("A call record has an impossible unbound-input state.", nodeID: step.node.id)
            }
        }

        try validateRecordOutputs(record, step: step, runtimeNode: runtimeNode)
        try validateHumanState(record.step)
        try validateControlEvidence(record, resolved: resolved)

        switch step.kind {
        case .loop:
            if [.completed, .partial].contains(record.step.status) {
                guard record.loopExit == .conditionMet || record.loopExit == .iterationLimit else {
                    throw WorkflowIssue("A completed Loop record lacks a valid exit reason.", nodeID: step.node.id)
                }
            }
        default:
            guard record.loopExit == nil else {
                throw WorkflowIssue("A non-Loop record carries a Loop exit reason.", nodeID: step.node.id)
            }
        }
    }

    private func validateControlEvidence(
        _ record: WorkflowPlanCallRecord,
        resolved: ResolvedRecord
    ) throws {
        guard record.step.inputsBound == true else {
            guard record.step.outputs.isEmpty else {
                throw WorkflowIssue("An unbound control record cannot contain outputs.", nodeID: resolved.step.node.id)
            }
            return
        }
        let completed = [.completed, .partial].contains(record.step.status)
        switch resolved.step.kind {
        case .call:
            return

        case .branch(let predicate, let yes, let no):
            if completed {
                let input = try requiredDatum(
                    record.step.inputs["input"], nodeID: resolved.step.node.id, port: "input"
                )
                let selected = try predicate.matches(input)
                let body = selected ? yes : no
                let base = record.address.path + [.branch(selected)]
                guard let outputs = try planOutputsIfComplete(body, basePath: base) else {
                    throw WorkflowIssue("A completed Branch has no complete selected-body trace.", nodeID: resolved.step.node.id)
                }
                let output = try bodyOutput(body.interface, purpose: "Branch")
                guard let value = outputs[output.name],
                      record.step.outputs == ["output": value] else {
                    throw WorkflowIssue("A completed Branch output does not equal its selected-body output.", nodeID: resolved.step.node.id)
                }
            } else if !record.step.outputs.isEmpty {
                throw WorkflowIssue("An unfinished Branch cannot contain a forged parent output.", nodeID: resolved.step.node.id)
            }

        case .invoke(let reference, let body):
            if completed {
                let base = record.address.path + [.tool(reference)]
                guard let outputs = try planOutputsIfComplete(body, basePath: base),
                      record.step.outputs == outputs else {
                    throw WorkflowIssue("A completed Invoke output has no matching complete tool trace.", nodeID: resolved.step.node.id)
                }
            } else if !record.step.outputs.isEmpty {
                throw WorkflowIssue("An unfinished Invoke cannot contain a forged parent output.", nodeID: resolved.step.node.id)
            }

        case .map(let body, let continueOnFailure):
            try validateMapEvidence(
                record,
                body: body,
                continueOnFailure: continueOnFailure,
                completed: completed
            )

        case .loop(let body, let stateSchema, let maximumIterations, let until):
            try validateLoopEvidence(
                record,
                body: body,
                stateSchema: stateSchema,
                maximumIterations: maximumIterations,
                until: until,
                completed: completed
            )
        }
    }

    private func validateMapEvidence(
        _ record: WorkflowPlanCallRecord,
        body: WorkflowPlan,
        continueOnFailure: Bool,
        completed: Bool
    ) throws {
        let nodeID = record.step.node.id
        let input = try requiredDatum(record.step.inputs["input"], nodeID: nodeID, port: "input")
        guard case .list(_, let sourceItems) = input else {
            throw WorkflowIssue("A Map trace is not bound to a List.", nodeID: nodeID)
        }
        let shared = try sharedFields(record.step.inputs["shared"], nodeID: nodeID)
        guard Set(shared.keys).isDisjoint(with: Set(["item", "value", "index"])) else {
            throw WorkflowIssue("Map shared fields conflict with item/value/index.", nodeID: nodeID)
        }
        guard Set(record.step.outputs.keys).isSubset(of: Set(["output"])) else {
            throw WorkflowIssue("A Map record contains a non-executor output.", nodeID: nodeID)
        }
        guard let outputValue = record.step.outputs["output"] else {
            if completed {
                throw WorkflowIssue("A completed Map is missing its result List.", nodeID: nodeID)
            }
            return
        }
        guard case .data(.list(_, let resultItems)) = outputValue,
              resultItems.count <= sourceItems.count,
              resultItems.map(\.id) == Array(sourceItems.prefix(resultItems.count)).map(\.id) else {
            throw WorkflowIssue("A Map result does not preserve the bound List prefix and identities.", nodeID: nodeID)
        }
        if completed {
            guard resultItems.count == sourceItems.count else {
                throw WorkflowIssue("A completed Map result does not cover every bound List item.", nodeID: nodeID)
            }
        }

        let output = try bodyOutput(body.interface, purpose: "Map")
        for (offset, resultItem) in resultItems.enumerated() {
            guard case .result(let result) = resultItem.value else {
                throw WorkflowIssue("A Map result item is not a typed Result.", nodeID: nodeID)
            }
            let base = record.address.path + [.item(resultItem.id)]
            switch result.status {
            case .success:
                guard let childOutputs = try planOutputsIfComplete(body, basePath: base),
                      let actual = childOutputs[output.name]?.datum,
                      result.value == actual,
                      result.issues.isEmpty else {
                    throw WorkflowIssue("A successful Map item has no equal complete child output.", nodeID: nodeID)
                }
            case .failed:
                let failures = recordsUnder(base).filter { $0.step.status == .failed }
                let projected = try planOutputsIfComplete(body, basePath: base)?[output.name]
                let invalidCompletedProjection: Bool
                if let projected {
                    if let datum = projected.datum {
                        invalidCompletedProjection = (try? datum.validate(as: output.schema)) == nil
                    } else {
                        invalidCompletedProjection = true
                    }
                } else {
                    invalidCompletedProjection = planRecordsAreComplete(body, basePath: base)
                }
                let matchingFailure = failures.contains(where: { failure in
                          failure.step.error.map { result.issues.contains($0) } ?? true
                      })
                let arguments = shared.merging([
                    "item": sourceItems[offset].value,
                    "value": sourceItems[offset].value,
                    "index": .number(Double(offset + 1), unit: nil),
                ]) { current, _ in current }
                let argumentFailures = mapArgumentFailureIssues(
                    arguments,
                    for: body,
                    basePath: base
                )
                let deterministicArgumentFailure = recordsUnder(base).isEmpty &&
                    result.issues.count == 1 &&
                    argumentFailures.contains(result.issues[0])
                guard result.value == nil, !result.issues.isEmpty,
                      matchingFailure || invalidCompletedProjection || deterministicArgumentFailure,
                      !completed || continueOnFailure else {
                    throw WorkflowIssue("A failed Map item has no matching failed child trace.", nodeID: nodeID)
                }
            case .skipped, .cancelled:
                throw WorkflowIssue("The Executor does not emit skipped/cancelled Map result items.", nodeID: nodeID)
            }
        }
        if completed {
            guard record.step.outputs == ["output": outputValue] else {
                throw WorkflowIssue("A completed Map contains outputs not produced by the Executor.", nodeID: nodeID)
            }
        }
    }

    private func validateLoopEvidence(
        _ record: WorkflowPlanCallRecord,
        body: WorkflowPlan,
        stateSchema: WorkflowDataSchema,
        maximumIterations: Int,
        until: WorkflowDataRule,
        completed: Bool
    ) throws {
        let nodeID = record.step.node.id
        let initial = try requiredDatum(record.step.inputs["input"], nodeID: nodeID, port: "input")
        try initial.validate(as: stateSchema)
        let shared = try sharedFields(record.step.inputs["shared"], nodeID: nodeID)
        guard shared["state"] == nil, shared["iteration"] == nil else {
            throw WorkflowIssue("Loop shared fields override state/iteration.", nodeID: nodeID)
        }
        guard Set(record.step.outputs.keys).isSubset(of: Set(["output", "exitReason"])) else {
            throw WorkflowIssue("A Loop record contains a non-executor output.", nodeID: nodeID)
        }

        let prefix = record.address.path
        let observed = Set(recordsUnder(prefix).compactMap { child -> Int? in
            guard child.address.path.count > prefix.count,
                  case .iteration(let value) = child.address.path[prefix.count] else { return nil }
            return value
        })
        let maximumObserved = observed.max() ?? 0
        let expectedIterations = maximumObserved == 0 ? Set<Int>() : Set(1...maximumObserved)
        guard maximumObserved <= maximumIterations,
              observed == expectedIterations else {
            throw WorkflowIssue("Loop iteration traces are not a contiguous in-range prefix.", nodeID: nodeID)
        }

        let output = try loopBodyOutput(body.interface)
        var states: [WorkflowDatum] = []
        var incompleteIteration: Int?
        if maximumObserved > 0 {
            for iteration in 1...maximumObserved {
                let base = prefix + [.iteration(iteration)]
                if let outputs = try planOutputsIfComplete(body, basePath: base),
                   let state = outputs[output.name]?.datum {
                    try state.validate(as: stateSchema)
                    states.append(state)
                } else {
                    guard iteration == maximumObserved, incompleteIteration == nil else {
                        throw WorkflowIssue("A Loop trace skips an incomplete earlier iteration.", nodeID: nodeID)
                    }
                    incompleteIteration = iteration
                }
            }
        }

        if completed {
            guard incompleteIteration == nil else {
                throw WorkflowIssue("A completed Loop contains an incomplete iteration trace.", nodeID: nodeID)
            }
            let finalState = states.last ?? initial
            let exit: WorkflowLoopExit
            switch record.loopExit {
            case .conditionMet:
                guard try until.matches(finalState) else {
                    throw WorkflowIssue("A conditionMet Loop exit does not satisfy its condition.", nodeID: nodeID)
                }
                exit = .conditionMet
            case .iterationLimit:
                guard states.count == maximumIterations,
                      try until.matches(finalState) == false else {
                    throw WorkflowIssue("An iterationLimit Loop exit has the wrong trace length or state.", nodeID: nodeID)
                }
                exit = .iterationLimit
            default:
                throw WorkflowIssue("A completed Loop has an invalid exit reason.", nodeID: nodeID)
            }
            let choices = ["conditionMet", "iterationLimit", "failed", "cancelled"]
            let expected: [String: WorkflowValue] = [
                "output": .data(finalState),
                "exitReason": .data(.enumeration(exit.rawValue, choices: choices)),
            ]
            guard record.step.outputs == expected else {
                throw WorkflowIssue("A completed Loop output does not equal its traced final state and exit.", nodeID: nodeID)
            }
            return
        }

        guard record.step.outputs["exitReason"] == nil else {
            throw WorkflowIssue("An unfinished Loop cannot contain a final exitReason output.", nodeID: nodeID)
        }
        if let progress = record.step.outputs["output"]?.datum {
            try progress.validate(as: stateSchema)
            let candidates = [initial] + states
            guard candidates.contains(progress) else {
                throw WorkflowIssue("A Loop progress output is not an exact durable traced prefix state.", nodeID: nodeID)
            }
        } else if record.step.outputs["output"] != nil {
            throw WorkflowIssue("A Loop progress output is not structured state data.", nodeID: nodeID)
        }
    }

    private func planOutputsIfComplete(
        _ plan: WorkflowPlan,
        basePath: [WorkflowAddressComponent]
    ) throws -> [String: WorkflowValue]? {
        guard planRecordsAreComplete(plan, basePath: basePath) else { return nil }
        if plan.interface.outputs.isEmpty {
            guard let last = plan.steps.last else { return [:] }
            let address = WorkflowExecutionAddress(
                runID: checkpoint.runID,
                path: basePath + [.node(last.node.id)]
            )
            return recordsByAddress[address]?.step.outputs
        }
        var result: [String: WorkflowValue] = [:]
        for output in plan.interface.outputs {
            let address = WorkflowExecutionAddress(
                runID: checkpoint.runID,
                path: basePath + [.node(output.nodeID)]
            )
            guard let value = recordsByAddress[address]?.step.outputs[output.port] else { return nil }
            result[output.name] = value
        }
        return result
    }

    private func planRecordsAreComplete(
        _ plan: WorkflowPlan,
        basePath: [WorkflowAddressComponent]
    ) -> Bool {
        plan.steps.allSatisfy { step in
            let address = WorkflowExecutionAddress(
                runID: checkpoint.runID,
                path: basePath + [.node(step.node.id)]
            )
            guard let record = recordsByAddress[address] else { return false }
            return [.completed, .partial].contains(record.step.status)
        }
    }

    private func recordsUnder(
        _ prefix: [WorkflowAddressComponent]
    ) -> [WorkflowPlanCallRecord] {
        checkpoint.records.filter { record in
            record.address.path.count > prefix.count &&
                Array(record.address.path.prefix(prefix.count)) == prefix
        }
    }

    private func boundInputs(
        for resolved: ResolvedRecord,
        runtimeNode: WorkflowNode
    ) throws -> [String: WorkflowValue] {
        let step = resolved.step
        let selected = Set(resolved.plan.steps.map(\.node.id))
        var result: [String: WorkflowValue] = [:]

        for input in step.inputs {
            if selected.contains(input.sourceNode) {
                let sourceAddress = WorkflowExecutionAddress(
                    runID: checkpoint.runID,
                    path: resolved.basePath + [.node(input.sourceNode)]
                )
                guard let source = recordsByAddress[sourceAddress],
                      [.completed, .partial].contains(source.step.status),
                      let value = source.step.outputs[input.sourcePort] else {
                    throw WorkflowIssue("A bound input has no completed planned source.", nodeID: step.node.id, port: input.port)
                }
                result[input.port] = value
            } else {
                guard resolved.basePath.isEmpty,
                      let value = checkpoint.externalInputs[runtimeNode.id]?[input.port] else {
                    throw WorkflowIssue("A nested or top-level boundary input has no permitted external value.", nodeID: step.node.id, port: input.port)
                }
                result[input.port] = value
            }
        }
        if resolved.basePath.isEmpty {
            for (name, value) in checkpoint.externalInputs[runtimeNode.id] ?? [:] where result[name] == nil {
                result[name] = value
            }
        }
        return result
    }

    private func validateRecordOutputs(
        _ record: WorkflowPlanCallRecord,
        step: WorkflowPlannedStep,
        runtimeNode: WorkflowNode
    ) throws {
        let ports = try outputPorts(for: step, node: runtimeNode)
        for (name, value) in record.step.outputs {
            if name == "preview", ports[name] == nil {
                guard [.waiting, .rejected].contains(record.step.status),
                      record.step.outputs.count == 1,
                      let interaction = registry.definition(for: runtimeNode)?.interaction else {
                    throw WorkflowIssue("A preview is not in a legitimate review state.", nodeID: step.node.id, port: name)
                }
                switch (interaction, value) {
                case (.textReview, .asset(let reference)) where reference.kind == .text:
                    try validateAsset(reference)
                case (.candidateReview, .collection(let candidates))
                    where candidates.allSatisfy({ $0.asset == nil || $0.asset?.kind == .image }):
                    try validateValue(value, port: .init(kinds: [.images], required: false),
                                      nodeID: step.node.id, name: name)
                default:
                    throw WorkflowIssue("A preview does not match its review operation.", nodeID: step.node.id, port: name)
                }
                continue
            }
            guard let port = ports[name] else {
                throw WorkflowIssue("A call record contains an unknown output.", nodeID: step.node.id, port: name)
            }
            try validateValue(value, port: port, nodeID: step.node.id, name: name)
            if name == "output", let schema = record.step.humanTask?.resultSchema,
               case .data(let datum) = value {
                try datum.validate(as: schema)
            }
            if name == "output", runtimeNode.operationID == "d.value.input",
               let projected = runtimeNode.dataConfiguration?.value {
                guard value == .data(projected) else {
                    throw WorkflowIssue("A public data-input output does not project its actual bound value.",
                                        nodeID: step.node.id, port: name)
                }
            }
        }
        if let interaction = registry.definition(for: runtimeNode)?.interaction,
           [.textReview, .candidateReview].contains(interaction),
           [.waiting, .rejected].contains(record.step.status),
           record.step.outputs["preview"] == nil {
            throw WorkflowIssue("A waiting or rejected review record is missing its preview.", nodeID: step.node.id)
        }
        if [.completed, .partial].contains(record.step.status) {
            for (name, port) in ports where port.required && record.step.outputs[name] == nil {
                throw WorkflowIssue("A completed call record omits a required output.", nodeID: step.node.id, port: name)
            }
        }
    }

    private func validateHumanState(_ step: WorkflowStepRun) throws {
        if let task = step.humanTask {
            guard task.id == step.id else {
                throw WorkflowIssue("A human task identity does not match its actual stepID.", nodeID: step.node.id)
            }
            try validateText(task.title, purpose: "human task title")
            try task.resultSchema.validateDefinition()
            try task.materials.validate()
            try task.draft?.validate()
            if let decision = task.decision { try decision.validate(as: task.resultSchema) }
            guard !(task.rejected && task.decision != nil) else {
                throw WorkflowIssue("A rejected human task cannot also contain a decision.", nodeID: step.node.id)
            }
            if let decision = task.decision, [.completed, .partial].contains(step.status) {
                guard step.outputs == ["output": .data(decision)] else {
                    throw WorkflowIssue("A completed human-task output does not equal its submitted decision.", nodeID: step.node.id)
                }
            }
        }
        if let decision = step.decision {
            guard decision.waitingStepID == step.id else {
                throw WorkflowIssue("A review decision refers to a different waiting stepID.", nodeID: step.node.id)
            }
            if let output = decision.output { try validateAsset(output) }
            if decision.accepted {
                guard decision.output != nil else {
                    throw WorkflowIssue("An accepted review decision has no selected output.", nodeID: step.node.id)
                }
            } else if decision.output != nil {
                throw WorkflowIssue("A rejected review decision cannot contain an output.", nodeID: step.node.id)
            }
            if let selected = decision.selectedCandidateID {
                let candidates = step.outputs["preview"]?.candidates
                guard candidates == nil || candidates?.contains(where: { $0.id == selected }) == true else {
                    throw WorkflowIssue("A review decision selected an unknown candidate.", nodeID: step.node.id)
                }
            }
            if decision.accepted, let output = decision.output,
               [.completed, .partial].contains(step.status) {
                guard step.outputs == ["output": .asset(output)] else {
                    throw WorkflowIssue("A completed review output does not equal its recorded decision.", nodeID: step.node.id)
                }
            }
        }
    }

    private func validateCheckpointOutputs() throws {
        let ports: [String: CheckpointPort]
        if checkpoint.plan.interface.outputs.isEmpty {
            if let last = checkpoint.plan.steps.last {
                let address = WorkflowExecutionAddress(runID: checkpoint.runID, path: [.node(last.node.id)])
                let runtimeNode = recordsByAddress[address]?.step.node ?? last.node
                ports = try outputPorts(for: last, node: runtimeNode)
            } else {
                ports = [:]
            }
        } else {
            var values: [String: CheckpointPort] = [:]
            for output in checkpoint.plan.interface.outputs {
                values[output.name] = .init(
                    kinds: output.schema.portKinds,
                    required: true,
                    schema: output.schema
                )
            }
            ports = values
        }
        for (name, value) in checkpoint.outputs {
            guard let port = ports[name] else {
                throw WorkflowIssue("Checkpoint outputs contains an unknown name.", port: name)
            }
            try validateValue(value, port: port, nodeID: nil, name: name)
        }
        if checkpoint.state == .completed {
            for step in checkpoint.plan.steps {
                let address = WorkflowExecutionAddress(runID: checkpoint.runID, path: [.node(step.node.id)])
                guard let record = recordsByAddress[address],
                      [.completed, .partial].contains(record.step.status) else {
                    throw WorkflowIssue("A completed checkpoint has an unfinished root planned step.", nodeID: step.node.id)
                }
            }
            for (name, port) in ports where port.required && checkpoint.outputs[name] == nil {
                throw WorkflowIssue("A completed checkpoint omits a required output.", port: name)
            }
        }

        let topBase = WorkflowExecutionAddress(runID: checkpoint.runID)
        if checkpoint.plan.interface.outputs.isEmpty {
            guard let last = checkpoint.plan.steps.last else {
                guard checkpoint.outputs.isEmpty else {
                    throw WorkflowIssue("An empty plan cannot have checkpoint outputs.")
                }
                return
            }
            let address = topBase.appending(.node(last.node.id))
            let materialized = recordsByAddress[address]?.step.outputs
            if checkpoint.state == .completed || !checkpoint.outputs.isEmpty {
                guard let materialized, checkpoint.outputs == materialized else {
                    throw WorkflowIssue("Checkpoint outputs do not match the final top-level call record.")
                }
            }
        } else {
            for output in checkpoint.plan.interface.outputs {
                guard let value = checkpoint.outputs[output.name] else { continue }
                let address = topBase.appending(.node(output.nodeID))
                guard recordsByAddress[address]?.step.outputs[output.port] == value else {
                    throw WorkflowIssue("A named checkpoint output does not match its top-level call record.",
                                        nodeID: output.nodeID, port: output.port)
                }
            }
        }
    }

    private func validateArguments(
        _ arguments: [String: WorkflowDatum],
        for plan: WorkflowPlan,
        allowExtra: Bool
    ) throws {
        guard arguments.count <= 4_096 else { throw WorkflowIssue("Plan arguments exceed their limit.") }
        var fields: [String: WorkflowRecordField] = [:]
        for field in plan.interface.inputs { fields[field.name] = field }
        if !allowExtra {
            for name in arguments.keys where fields[name] == nil {
                throw WorkflowIssue("Plan arguments contains an undeclared name: \(name).")
            }
        }
        for (name, field) in fields {
            guard let value = arguments[name] else {
                if field.required { throw WorkflowIssue("Plan arguments omits required input \(name).") }
                continue
            }
            try value.validate(as: field.type)
        }
        for (name, value) in arguments where fields[name] == nil {
            guard !name.isEmpty, name.utf8.count <= 256 else {
                throw WorkflowIssue("A nested plan argument name is invalid.")
            }
            try value.validate()
        }
    }

    private func inputPorts(
        for step: WorkflowPlannedStep,
        node: WorkflowNode
    ) throws -> [String: CheckpointPort] {
        if case .invoke(_, let body) = step.kind {
            var ports: [String: CheckpointPort] = [:]
            for field in body.interface.inputs {
                guard ports[field.name] == nil else { throw WorkflowIssue("Invoke input interface is duplicated.") }
                ports[field.name] = .init(kinds: field.type.portKinds, required: field.required, schema: field.type)
            }
            return ports
        }
        guard let definition = registry.definition(for: node) else {
            throw WorkflowIssue("Unknown operation in checkpoint.", nodeID: node.id)
        }
        var ports: [String: CheckpointPort] = [:]
        for port in definition.inputs {
            guard ports[port.id] == nil else { throw WorkflowIssue("Operation input ports are duplicated.", nodeID: node.id) }
            let schema = node.dataConfiguration?.fields.first(where: { $0.name == port.id })?.type
            ports[port.id] = .init(kinds: port.kinds, required: port.required, schema: schema)
        }
        return ports
    }

    private func outputPorts(
        for step: WorkflowPlannedStep,
        node: WorkflowNode
    ) throws -> [String: CheckpointPort] {
        if case .invoke(_, let body) = step.kind {
            var ports: [String: CheckpointPort] = [:]
            for output in body.interface.outputs {
                guard ports[output.name] == nil else { throw WorkflowIssue("Invoke output interface is duplicated.") }
                ports[output.name] = .init(kinds: output.schema.portKinds, required: true, schema: output.schema)
            }
            return ports
        }
        guard let definition = registry.definition(for: node) else {
            throw WorkflowIssue("Unknown operation in checkpoint.", nodeID: node.id)
        }
        var ports: [String: CheckpointPort] = [:]
        for port in definition.outputs {
            let required: Bool
            switch step.kind {
            case .branch, .map: required = port.id == "output"
            default: required = port.required
            }
            guard ports[port.id] == nil else { throw WorkflowIssue("Operation output ports are duplicated.", nodeID: node.id) }
            let schema: WorkflowDataSchema?
            switch (step.kind, port.id) {
            case let (.branch(_, yes, _), "output"):
                schema = try bodyOutput(yes.interface, purpose: "Branch").schema
            case let (.map(body, _), "output"):
                schema = .list(.result(try bodyOutput(body.interface, purpose: "Map").schema))
            case let (.loop(_, stateSchema, _, _), "output"):
                schema = stateSchema
            case (.loop, "exitReason"):
                schema = .enumeration(["conditionMet", "iterationLimit", "failed", "cancelled"])
            default:
                if port.id == "output" {
                    switch node.operationID {
                    case "d.value.input": schema = node.dataConfiguration?.value?.schema
                    case "d.value.record": schema = .record(node.dataConfiguration?.fields ?? [])
                    case "d.value.list":
                        if let element = node.dataConfiguration?.schema { schema = .list(element) }
                        else { schema = nil }
                    case "d.value.field": schema = node.dataConfiguration?.schema
                    default: schema = nil
                    }
                } else {
                    schema = nil
                }
            }
            ports[port.id] = .init(kinds: port.kinds, required: required, schema: schema)
        }
        return ports
    }

    private func validatePortValues(
        _ values: [String: WorkflowValue],
        ports: [String: CheckpointPort],
        nodeID: UUID,
        requireAll: Bool
    ) throws {
        for (name, value) in values {
            guard let port = ports[name] else {
                throw WorkflowIssue("A call record contains an unknown input.", nodeID: nodeID, port: name)
            }
            try validateValue(value, port: port, nodeID: nodeID, name: name)
        }
        if requireAll {
            for (name, port) in ports where port.required && values[name] == nil {
                throw WorkflowIssue("A call record omits a required input.", nodeID: nodeID, port: name)
            }
        }
    }

    private func validateValue(
        _ value: WorkflowValue,
        port: CheckpointPort,
        nodeID: UUID?,
        name: String
    ) throws {
        guard port.kinds.contains(value.kind) else {
            throw WorkflowIssue("A checkpoint value has an incompatible port type.", nodeID: nodeID, port: name)
        }
        switch value {
        case .asset(let reference):
            try validateAsset(reference)
        case .collection(let candidates):
            guard candidates.count <= 4_096,
                  Set(candidates.map(\.id)).count == candidates.count else {
                throw WorkflowIssue("A candidate collection is duplicated or exceeds its limit.", nodeID: nodeID, port: name)
            }
            for candidate in candidates {
                if let asset = candidate.asset { try validateAsset(asset) }
                try validateText(candidate.error, purpose: "candidate error")
                try validateText(candidate.seed, purpose: "candidate seed")
            }
        case .receipt(let receipt):
            guard receipt.names.count <= 4_096, receipt.hashes.count == receipt.names.count,
                  receipt.names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }),
                  receipt.hashes.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy(Self.isHex) }) else {
                throw WorkflowIssue("An export receipt is malformed.", nodeID: nodeID, port: name)
            }
        case .data(let datum):
            try datum.validate()
            if let schema = port.schema { try datum.validate(as: schema) }
        }
    }

    private func nodeForArguments(
        _ original: WorkflowNode,
        arguments: [String: WorkflowDatum],
        interface: WorkflowGraphInterface
    ) throws -> WorkflowNode {
        guard original.operationID == "d.value.input",
              let name = original.parameters["publicName"]?.string,
              !name.isEmpty,
              let field = interface.inputs.first(where: { $0.name == name }),
              let value = arguments[name] else { return original }
        try value.validate(as: field.type)
        var node = original
        var configuration = node.dataConfiguration ?? .init()
        configuration.value = value
        node.dataConfiguration = configuration
        return node
    }

    private func requiredDatum(
        _ value: WorkflowValue?,
        nodeID: UUID,
        port: String
    ) throws -> WorkflowDatum {
        guard let datum = value?.datum else {
            throw WorkflowIssue("A control input is not structured data.", nodeID: nodeID, port: port)
        }
        try datum.validate()
        return datum
    }

    private func sharedFields(
        _ value: WorkflowValue?,
        nodeID: UUID
    ) throws -> [String: WorkflowDatum] {
        guard let value else { return [:] }
        let datum = try requiredDatum(value, nodeID: nodeID, port: "shared")
        guard case .record(_, let fields) = datum else {
            throw WorkflowIssue("A control shared input is not a record.", nodeID: nodeID, port: "shared")
        }
        return fields
    }

    private func bodyOutput(
        _ interface: WorkflowGraphInterface,
        purpose: String
    ) throws -> WorkflowNamedOutput {
        if let output = interface.outputs.first(where: { $0.name == "output" }) { return output }
        guard interface.outputs.count == 1, let output = interface.outputs.first else {
            throw WorkflowIssue("\(purpose) body must declare output or one unique named output.")
        }
        return output
    }

    private func loopBodyOutput(_ interface: WorkflowGraphInterface) throws -> WorkflowNamedOutput {
        if let output = interface.outputs.first(where: { $0.name == "state" }) { return output }
        return try bodyOutput(interface, purpose: "Loop")
    }

    private func itemOffset(_ id: String, in items: [WorkflowDataItem]) throws -> Int {
        guard let offset = items.firstIndex(where: { $0.id == id }) else {
            throw WorkflowIssue("A Map item identity is not in its bound List.")
        }
        return offset
    }

    private func mapArgumentFailureIssues(
        _ arguments: [String: WorkflowDatum],
        for plan: WorkflowPlan,
        basePath: [WorkflowAddressComponent]
    ) -> Set<String> {
        var issues: Set<String> = []
        for field in plan.interface.inputs {
            guard let value = arguments[field.name] else {
                guard field.required else { continue }
                let nodeID = plan.steps.first {
                    $0.node.operationID == "d.value.input" &&
                        $0.node.parameters["publicName"]?.string == field.name
                }?.node.id
                let path = nodeID.map { basePath + [.node($0)] } ?? basePath
                let address = describeAddress(path)
                issues.insert(WorkflowIssue(
                    "缺少必填流程参数；地址 \(address)。",
                    nodeID: nodeID,
                    port: field.name
                ).localizedDescription)
                continue
            }
            do {
                try value.validate(as: field.type)
            } catch {
                issues.insert(error.localizedDescription)
            }
        }
        return issues
    }

    private func describeAddress(_ path: [WorkflowAddressComponent]) -> String {
        let description = path.map { component -> String in
            switch component {
            case .node(let id): return "node:\(id.uuidString)"
            case .branch(let selected): return "branch:\(selected ? "then" : "otherwise")"
            case .item(let id): return "item:\(id)"
            case .iteration(let value): return "iteration:\(value)"
            case .tool(let reference): return "tool:\(reference.id.uuidString)@\(reference.version)"
            }
        }.joined(separator: "/")
        return description.isEmpty
            ? checkpoint.runID.uuidString
            : checkpoint.runID.uuidString + "/" + description
    }

    private func validateAsset(_ reference: WorkflowAssetReference) throws {
        try WorkflowDatum.asset(reference).validate(as: .asset(reference.kind))
    }

    private func validateRule(_ rule: WorkflowDataRule, nodeID: UUID) throws {
        guard rule.path.count <= 24,
              rule.path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw WorkflowIssue("A control rule path is invalid.", nodeID: nodeID)
        }
        try rule.value?.validate()
        if rule.comparison != .exists, rule.value == nil {
            throw WorkflowIssue("A control comparison is missing its right-hand value.", nodeID: nodeID)
        }
    }

    private func validateText(_ value: String?, purpose: String) throws {
        guard let value else { return }
        guard value.utf8.count <= Self.maximumTextBytes else {
            throw WorkflowIssue("\(purpose) exceeds the 1 MiB text limit.")
        }
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        isLowercaseHex(byte) || (65...70).contains(byte)
    }

    private static let structuredControlIDs: Set<String> = [
        "d.control.branch", "d.control.map", "d.control.loop", "d.control.invoke",
    ]
}

private struct ResolvedRecord {
    let plan: WorkflowPlan
    let step: WorkflowPlannedStep
    let basePath: [WorkflowAddressComponent]
    let arguments: [String: WorkflowDatum]
}

private struct CheckpointPort {
    let kinds: [WorkflowDataKind]
    let required: Bool
    let schema: WorkflowDataSchema?

    init(kinds: [WorkflowDataKind], required: Bool, schema: WorkflowDataSchema? = nil) {
        self.kinds = kinds
        self.required = required
        self.schema = schema
    }
}

private struct CheckpointAssetCollector {
    private static let maximumDepth = 64
    private static let maximumValues = 262_144
    private var seen = Set<WorkflowAssetReference>()
    private var valueCount = 0
    private(set) var references: [WorkflowAssetReference] = []

    mutating func collect(_ checkpoint: WorkflowPlanCheckpoint) throws {
        try collect(plan: checkpoint.plan, depth: 0)
        for name in checkpoint.arguments.keys.sorted() {
            if let value = checkpoint.arguments[name] { try collect(datum: value, depth: 0) }
        }
        for nodeID in checkpoint.externalInputs.keys.sorted(by: uuidOrder) {
            for name in (checkpoint.externalInputs[nodeID] ?? [:]).keys.sorted() {
                if let value = checkpoint.externalInputs[nodeID]?[name] { try collect(value: value, depth: 0) }
            }
        }
        for record in checkpoint.records {
            try collect(node: record.step.node, depth: 0)
            for name in record.step.inputs.keys.sorted() {
                if let value = record.step.inputs[name] { try collect(value: value, depth: 0) }
            }
            for name in record.step.outputs.keys.sorted() {
                if let value = record.step.outputs[name] { try collect(value: value, depth: 0) }
            }
            if let task = record.step.humanTask {
                try collect(datum: task.materials, depth: 0)
                if let draft = task.draft { try collect(datum: draft, depth: 0) }
                if let decision = task.decision { try collect(datum: decision, depth: 0) }
            }
            if let output = record.step.decision?.output { try append(output) }
        }
        for name in checkpoint.outputs.keys.sorted() {
            if let value = checkpoint.outputs[name] { try collect(value: value, depth: 0) }
        }
    }

    private mutating func collect(plan: WorkflowPlan, depth: Int) throws {
        try count(depth)
        for step in plan.steps {
            try collect(node: step.node, depth: depth + 1)
            switch step.kind {
            case .call:
                break
            case .branch(let predicate, let yes, let no):
                if let value = predicate.value { try collect(datum: value, depth: depth + 1) }
                try collect(plan: yes, depth: depth + 1)
                try collect(plan: no, depth: depth + 1)
            case .map(let body, _):
                try collect(plan: body, depth: depth + 1)
            case .loop(let body, _, _, let until):
                if let value = until.value { try collect(datum: value, depth: depth + 1) }
                try collect(plan: body, depth: depth + 1)
            case .invoke(_, let body):
                try collect(plan: body, depth: depth + 1)
            }
        }
    }

    mutating func collect(graph: WorkflowGraph, depth: Int) throws {
        try count(depth)
        for node in graph.nodes { try collect(node: node, depth: depth + 1) }
    }

    private mutating func collect(node: WorkflowNode, depth: Int) throws {
        try count(depth)
        if let reference = node.assetReference { try append(reference) }
        if let configuration = node.dataConfiguration {
            if let value = configuration.value { try collect(datum: value, depth: depth + 1) }
            for item in configuration.items { try collect(datum: item.value, depth: depth + 1) }
            for rule in configuration.rules {
                if let value = rule.value { try collect(datum: value, depth: depth + 1) }
            }
        }
        switch node.control {
        case .branch(let predicate, let yes, let no):
            if let value = predicate.value { try collect(datum: value, depth: depth + 1) }
            try collect(graph: yes, depth: depth + 1)
            try collect(graph: no, depth: depth + 1)
        case .map(let body, _):
            try collect(graph: body, depth: depth + 1)
        case .loop(let body, _, _, let until):
            if let value = until.value { try collect(datum: value, depth: depth + 1) }
            try collect(graph: body, depth: depth + 1)
        case .invoke, nil:
            break
        }
    }

    private mutating func collect(value: WorkflowValue, depth: Int) throws {
        try count(depth)
        switch value {
        case .asset(let reference):
            try append(reference)
        case .collection(let candidates):
            for candidate in candidates {
                if let reference = candidate.asset { try append(reference) }
            }
        case .receipt:
            break
        case .data(let datum):
            try collect(datum: datum, depth: depth + 1)
        }
    }

    private mutating func collect(datum: WorkflowDatum, depth: Int) throws {
        try count(depth)
        switch datum {
        case .asset(let reference):
            try append(reference)
        case .record(_, let fields):
            for name in fields.keys.sorted() {
                guard let value = fields[name] else { continue }
                if name == "sources" { try collectMusicSources(value, depth: depth + 1) }
                try collect(datum: value, depth: depth + 1)
            }
        case .list(_, let items):
            for item in items { try collect(datum: item.value, depth: depth + 1) }
        case .result(let result):
            guard result.issues.allSatisfy({ $0.utf8.count <= 1_048_576 }) else {
                throw WorkflowIssue("A result issue exceeds the 1 MiB text limit.")
            }
            if let value = result.value { try collect(datum: value, depth: depth + 1) }
        default:
            break
        }
    }

    /// Workflow music values intentionally encode their durable source references as
    /// ordinary Record data. Recognize only the exact versioned source-record shape.
    private mutating func collectMusicSources(_ datum: WorkflowDatum, depth: Int) throws {
        guard case .list(let element, let items) = datum,
              case .record(let declarations) = element,
              isMusicSourceSchema(declarations) else { return }
        for item in items {
            guard case .record(let itemSchema, let fields) = item.value,
                  itemSchema == declarations,
                  case .text(let projectText)? = fields["projectID"],
                  case .text(let assetText)? = fields["assetID"],
                  case .text(let versionText)? = fields["version"],
                  case .text(let kindText)? = fields["kind"],
                  case .text(let sha256)? = fields["sha256"],
                  let projectID = UUID(uuidString: projectText),
                  let assetID = UUID(uuidString: assetText),
                  let version = UUID(uuidString: versionText),
                  let kind = WorkflowDataKind(rawValue: kindText),
                  item.id == "\(assetID.uuidString):\(version.uuidString)" else {
                throw WorkflowIssue("A music source Record contains an invalid asset reference.")
            }
            try append(.init(
                projectID: projectID,
                assetID: assetID,
                version: version,
                kind: kind,
                sha256: sha256
            ))
        }
    }

    private func isMusicSourceSchema(_ fields: [WorkflowRecordField]) -> Bool {
        let expected = ["projectID", "assetID", "version", "kind", "sha256"]
        guard fields.map(\.name) == expected else { return false }
        return fields.allSatisfy { field in
            field.required && field.type == .text
        }
    }

    private mutating func append(_ reference: WorkflowAssetReference) throws {
        try WorkflowDatum.asset(reference).validate(as: .asset(reference.kind))
        if seen.insert(reference).inserted { references.append(reference) }
    }

    private mutating func count(_ depth: Int) throws {
        valueCount += 1
        guard depth <= Self.maximumDepth, valueCount <= Self.maximumValues else {
            throw WorkflowIssue("Checkpoint asset traversal exceeds its depth or value limit.")
        }
    }

    private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }
}
