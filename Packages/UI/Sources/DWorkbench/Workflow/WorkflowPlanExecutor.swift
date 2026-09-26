import Foundation

@MainActor public final class WorkflowPlanExecutor {
    public private(set) var checkpoint: WorkflowPlanCheckpoint?

    private let registry: WorkflowRegistry
    private let executeCall: @MainActor (WorkflowExecutionContext) async throws -> WorkflowOperationResult
    private let save: @MainActor (WorkflowPlanCheckpoint) async throws -> Void
    private var pauseRequested = false
    private var stopRequested = false
    private var executing = false

    public init(
        registry: WorkflowRegistry = .standard,
        executeCall: @escaping @MainActor (WorkflowExecutionContext) async throws -> WorkflowOperationResult,
        save: @escaping @MainActor (WorkflowPlanCheckpoint) async throws -> Void
    ) {
        self.registry = registry
        self.executeCall = executeCall
        self.save = save
    }

    public func requestPause() { pauseRequested = true }
    public func requestStop() { stopRequested = true }

    public func execute(_ supplied: WorkflowPlanCheckpoint) async throws -> WorkflowPlanCheckpoint {
        guard !executing else { throw WorkflowIssue("结构化计划已有一次执行正在进行。") }
        executing = true
        defer { executing = false }
        if let held = checkpoint, held.state == .saving {
            guard held.runID == supplied.runID else {
                throw WorkflowIssue("另一运行仍有结果等待保存；必须先保存或由所有者明确放弃。")
            }
            guard held == supplied else {
                throw WorkflowIssue("收到旧的保存恢复点；请使用 executor.checkpoint 重试保存。")
            }
            checkpoint = held
            try await retrySavingCheckpoint()
        } else {
            if let held = checkpoint, held.runID == supplied.runID {
                guard held.plan == supplied.plan,
                      held.arguments == supplied.arguments,
                      held.externalInputs == supplied.externalInputs else {
                    throw WorkflowIssue("运行开始后的计划、参数和外部输入不可变。")
                }
                try validateResumeCheckpoint(held: held, supplied: supplied)
            }
            checkpoint = supplied
            if supplied.state == .saving { try await retrySavingCheckpoint() }
        }

        pauseRequested = false
        stopRequested = false
        try validateCheckpoint()
        try validateExternalInputs()
        try validateSubmittedWaitingDecisions()
        guard var value = checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
        if value.state == .completed || value.state == .cancelled || value.state == .failed { return value }
        value.state = .running
        value.error = nil
        checkpoint = value
        try await persist()

        do {
            let base = WorkflowExecutionAddress(runID: value.runID)
            let outputs = try await executePlan(value.plan, arguments: value.arguments, base: base, allowExtraArguments: false)
            guard var completed = checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
            completed.outputs = outputs
            completed.state = .completed
            completed.error = nil
            checkpoint = completed
            try await persist()
            return try currentCheckpoint()
        } catch PlanSuspension.waiting {
            return try currentCheckpoint()
        } catch PlanSuspension.paused {
            return try currentCheckpoint()
        } catch PlanSuspension.stopped {
            return try currentCheckpoint()
        } catch is CancellationError {
            if checkpoint?.state == .saving { throw CancellationError() }
            if var cancelled = checkpoint {
                cancelled.state = .cancelled
                cancelled.error = nil
                checkpoint = cancelled
                try await persist()
            }
            return try currentCheckpoint()
        } catch {
            if checkpoint?.state == .saving { throw error }
            if var failed = checkpoint {
                failed.state = failed.records.contains(where: { $0.step.status == .waiting }) ? .waiting : .failed
                failed.error = error.localizedDescription
                checkpoint = failed
                try await persist()
            }
            throw error
        }
    }

    /// Settle exactly one explicit human decision, never continue another step.
    public func settleWaiting(_ supplied: WorkflowPlanCheckpoint, stepID: UUID) async throws -> WorkflowPlanCheckpoint {
        guard !executing else { throw WorkflowIssue("运行中不能提交另一等待决定。") }
        checkpoint = supplied
        try validateCheckpoint(); try validateSubmittedWaitingDecisions()
        guard let record = supplied.records.first(where: { $0.step.id == stepID }), record.step.status == .waiting else { throw WorkflowIssue("等待点不存在。") }
        func find(_ plan: WorkflowPlan, path: ArraySlice<WorkflowAddressComponent>) -> WorkflowPlannedStep? {
            guard case .node(let id) = path.first, let step = plan.steps.first(where: { $0.id == id }) else { return nil }
            if path.count == 1 { return step }
            let rest = path.dropFirst()
            switch (step.kind, rest.first) {
            case (.branch(_, let yes, let no), .branch(let value)): return find(value ? yes : no, path: rest.dropFirst())
            case (.map(let body, _), .item): return find(body, path: rest.dropFirst())
            case (.loop(let body, _, _, _), .iteration): return find(body, path: rest.dropFirst())
            case (.invoke(let reference, let body), .tool(let selected)) where reference == selected: return find(body, path: rest.dropFirst())
            default: return nil
            }
        }
        guard let planned = find(supplied.plan, path: record.address.path[...]) else { throw WorkflowIssue("等待地址不属于计划。") }
        do { _ = try await resumeWaiting(at: record.address, planned: planned) }
        catch PlanSuspension.stopped { }
        catch PlanSuspension.waiting { }
        return try currentCheckpoint()
    }

    /// Called only by the current Call's owner; keeps partial candidate evidence durable.
    public func updateCandidates(stepID: UUID, candidates: [WorkflowCandidate]) async throws {
        guard executing, let index = checkpoint?.records.firstIndex(where: { $0.step.id == stepID }),
              checkpoint?.records[index].step.node.operationID == "d.image.generate" else { throw WorkflowIssue("候选进度不属于当前图像调用。") }
        checkpoint?.records[index].step.outputs["output"] = .collection(candidates)
        try await persist()
    }

    /// An explicit retry reuses bound inputs and successful candidates; rejection is never revived.
    public static func preparingRetry(_ supplied: WorkflowPlanCheckpoint) throws -> WorkflowPlanCheckpoint {
        guard !supplied.records.contains(where: { $0.step.status == .rejected || $0.step.humanTask?.rejected == true || $0.step.decision?.accepted == false }) else {
            throw WorkflowIssue("人工拒绝的运行不能恢复。")
        }
        var result = supplied
        if result.state == .saving { return result }
        // A settled control owns its complete trace, including failures it explicitly
        // collected. Retrying a later step must not rewrite that historical evidence.
        let settled = result.records.filter { [.completed, .partial].contains($0.step.status) }.map(\.address.path)
        for i in result.records.indices where [.failed, .cancelled, .interrupted, .cancelling, .running].contains(result.records[i].step.status) {
            let path = result.records[i].address.path
            if settled.contains(where: { $0.count < path.count && path.starts(with: $0) }) { continue }
            result.records[i].step.status = .queued
            result.records[i].step.error = nil
            result.records[i].loopExit = nil
        }
        if result.state != .completed { result.state = .ready; result.error = nil }
        return result
    }

    private func executePlan(
        _ plan: WorkflowPlan,
        arguments: [String: WorkflowDatum],
        base: WorkflowExecutionAddress,
        allowExtraArguments: Bool
    ) async throws -> [String: WorkflowValue] {
        try validateArguments(arguments, plan: plan, base: base, allowExtra: allowExtraArguments)
        for step in plan.steps {
            try await honorRequests()
            _ = try await executeStep(step, plan: plan, arguments: arguments, base: base)
        }
        return try collectOutputs(plan, base: base)
    }

    private func executeStep(
        _ planned: WorkflowPlannedStep,
        plan: WorkflowPlan,
        arguments: [String: WorkflowDatum],
        base: WorkflowExecutionAddress
    ) async throws -> [String: WorkflowValue] {
        let address = base.appending(.node(planned.node.id))
        if let record = record(at: address) {
            switch record.step.status {
            case .completed, .partial:
                try validateOutputs(record.step.outputs, for: planned)
                return record.step.outputs
            case .waiting:
                return try await resumeWaiting(at: address, planned: planned)
            case .failed, .cancelled, .rejected, .interrupted:
                throw WorkflowIssue(record.step.error ?? "已有步骤没有成功完成。", nodeID: planned.node.id)
            default:
                break
            }
        }

        let runtimeNode = try nodeForArguments(planned.node, arguments: arguments, interface: plan.interface)
        if record(at: address) == nil {
            let signature = planned.sourceSignature ?? "\(plan.graphID.uuidString.lowercased()):\(plan.graphRevision.uuidString.lowercased())"
            let run = WorkflowStepRun(node: runtimeNode, signature: signature)
            appendRecord(.init(address: address, step: run))
            try await persist()
        }

        do {
            let inputs: [String: WorkflowValue]
            if record(at: address)?.step.inputsBound == true {
                inputs = record(at: address)?.step.inputs ?? [:]
            } else {
                inputs = try bindInputs(for: planned, runtimeNode: runtimeNode, plan: plan, base: base)
                try updateRecord(at: address) { record in
                    record.step.node = runtimeNode
                    record.step.inputs = inputs
                    record.step.inputsBound = true
                    record.step.status = .running
                }
                try await persist()
            }
            do {
                try await honorRequests()
            } catch PlanSuspension.stopped {
                if case .loop = planned.kind {
                    try updateRecord(at: address) { record in
                        record.loopExit = .cancelled
                        record.step.status = .cancelled
                    }
                    try await persist()
                }
                throw PlanSuspension.stopped
            }

            switch planned.kind {
            case .call:
                return try await executeCallStep(planned, node: runtimeNode, inputs: inputs, address: address, graphID: plan.graphID)
            case .branch(let predicate, let thenPlan, let otherwisePlan):
                let input = try requiredDatum(inputs["input"], node: runtimeNode, port: "input")
                let selected = try predicate.matches(input)
                let childArguments: [String: WorkflowDatum]
                if case .record(_, let fields) = input { childArguments = fields }
                else { childArguments = ["input": input] }
                let child = selected ? thenPlan : otherwisePlan
                let result = try await executePlan(
                    child,
                    arguments: childArguments,
                    base: address.appending(.branch(selected)),
                    allowExtraArguments: true
                )
                let definition = try bodyOutput(child.interface, purpose: "Branch")
                guard let output = result[definition.name] else {
                    throw WorkflowIssue("Branch 子图没有返回约定输出。", nodeID: runtimeNode.id)
                }
                return try await finish(planned, outputs: ["output": output], address: address)
            case .map(let body, let continueOnFailure):
                let outputs = try await executeMap(
                    planned, body: body, continueOnFailure: continueOnFailure,
                    inputs: inputs, address: address
                )
                return try await finish(planned, outputs: outputs, address: address)
            case .loop(let body, let stateSchema, let maximumIterations, let until):
                let outputs = try await executeLoop(
                    planned, body: body, stateSchema: stateSchema,
                    maximumIterations: maximumIterations, until: until,
                    inputs: inputs, address: address
                )
                return try await finish(planned, outputs: outputs, address: address)
            case .invoke(let reference, let body):
                var childArguments: [String: WorkflowDatum] = [:]
                for field in body.interface.inputs {
                    guard let value = inputs[field.name]?.datum else {
                        if field.required {
                            throw WorkflowIssue(
                                "Invoke 缺少必填输入；地址 \(describe(address))。",
                                nodeID: runtimeNode.id, port: field.name
                            )
                        }
                        continue
                    }
                    try value.validate(as: field.type)
                    childArguments[field.name] = value
                }
                let outputs = try await executePlan(
                    body,
                    arguments: childArguments,
                    base: address.appending(.tool(reference)),
                    allowExtraArguments: false
                )
                return try await finish(planned, outputs: outputs, address: address)
            }
        } catch let suspension as PlanSuspension {
            throw suspension
        } catch is CancellationError {
            try updateRecord(at: address) { record in record.step.status = .cancelled }
            try await persist()
            throw CancellationError()
        } catch let error as WorkflowSaveFailure {
            if checkpoint?.state == .saving { throw error }
            // The service retains computed bytes; retry this same call only to publish them.
            try updateRecord(at: address) { record in
                record.step.status = .saving; record.step.error = error.localizedDescription
            }
            if var value = checkpoint { value.state = .saving; value.error = error.localizedDescription; checkpoint = value }
            try await persist()
            throw error
        } catch {
            if checkpoint?.state == .saving { throw error }
            if checkpoint?.records.contains(where: { $0.step.status == .waiting }) == true { throw error }
            try updateRecord(at: address) { record in
                record.step.status = .failed
                record.step.error = error.localizedDescription
                if let failure = error as? WorkflowOutputValidationFailure { record.step.outputs["raw"] = .asset(failure.raw) }
            }
            try await persist()
            throw error
        }
    }

    private func executeCallStep(
        _ planned: WorkflowPlannedStep,
        node: WorkflowNode,
        inputs: [String: WorkflowValue],
        address: WorkflowExecutionAddress,
        graphID: UUID
    ) async throws -> [String: WorkflowValue] {
        guard let current = record(at: address) else { throw WorkflowIssue("调用记录不存在。", nodeID: node.id) }
        let context = WorkflowExecutionContext(
            node: node,
            stepID: current.step.id,
            inputs: inputs,
            retryCandidates: current.step.outputs["output"]?.candidates,
            address: address, graphID: graphID
        )
        let result = try await executeCall(context)
        switch result {
        case .outputs(let outputs):
            return try await finish(planned, outputs: outputs, address: address)
        case .reviewText(let reference):
            try updateRecord(at: address) { record in
                record.step.outputs = ["preview": .asset(reference)]
                record.step.status = .waiting
            }
            try await wait()
        case .choose(let candidates):
            try updateRecord(at: address) { record in
                record.step.outputs = ["preview": .collection(candidates)]
                record.step.status = .waiting
            }
            try await wait()
        case .humanTask(let task):
            guard task.id == current.step.id else {
                throw WorkflowIssue("人工任务身份必须等于本次实际 stepID。", nodeID: node.id)
            }
            try validateDataSchema(task.resultSchema, path: "humanTask.resultSchema")
            try task.materials.validate()
            try updateRecord(at: address) { record in
                record.step.humanTask = task
                record.step.status = .waiting
            }
            try await wait()
        }
    }

    private func resumeWaiting(
        at address: WorkflowExecutionAddress,
        planned: WorkflowPlannedStep
    ) async throws -> [String: WorkflowValue] {
        guard let current = record(at: address) else { throw WorkflowIssue("等待记录不存在。") }
        if let task = current.step.humanTask {
            if task.rejected {
                let reason = "Human task rejected: \(task.id.uuidString)"
                try updateRecord(at: address) { record in
                    record.step.status = .cancelled
                    record.step.error = reason
                    record.step.humanTask = task
                }
                try await cancelPlan(reason: reason)
            }
            guard let decision = task.decision else { try await wait() }
            try decision.validate(as: task.resultSchema)
            let outputs: [String: WorkflowValue] = ["output": .data(decision)]
            try validateOutputs(outputs, for: planned)
            try updateRecord(at: address) { record in
                record.step.outputs = outputs
                record.step.status = .completed
                record.step.error = nil
                record.step.humanTask = task
            }
            try await persist()
            try await honorRequests()
            return outputs
        }

        guard let decision = current.step.decision else { try await wait() }
        guard decision.accepted, let output = decision.output else {
            try updateRecord(at: address) { record in
                record.step.status = .rejected
                record.step.error = "Workflow decision rejected: \(decision.id.uuidString)"
            }
            try await cancelPlan(reason: "Workflow decision rejected: \(decision.id.uuidString)")
        }
        let outputs: [String: WorkflowValue] = ["output": .asset(output)]
        try validateOutputs(outputs, for: planned)
        try updateRecord(at: address) { record in
            record.step.outputs = outputs
            record.step.status = .completed
            record.step.error = nil
        }
        try await persist()
        try await honorRequests()
        return outputs
    }

    private func executeMap(
        _ planned: WorkflowPlannedStep,
        body: WorkflowPlan,
        continueOnFailure: Bool,
        inputs: [String: WorkflowValue],
        address: WorkflowExecutionAddress
    ) async throws -> [String: WorkflowValue] {
        let input = try requiredDatum(inputs["input"], node: planned.node, port: "input")
        guard case .list(_, let items) = input else {
            throw WorkflowIssue("Map input 必须是列表。", nodeID: planned.node.id, port: "input")
        }
        guard items.count <= 4_096 else { throw WorkflowIssue("Map 输入超过 4096 项。", nodeID: planned.node.id) }
        let shared = try sharedFields(inputs["shared"], node: planned.node)
        let outputDefinition = try bodyOutput(body.interface, purpose: "Map")
        var results: [WorkflowDataItem] = []
        results.reserveCapacity(items.count)

        for (offset, item) in items.enumerated() {
            try await honorRequests()
            let reserved: [String: WorkflowDatum] = [
                "item": item.value,
                "value": item.value,
                "index": .number(Double(offset + 1), unit: nil),
            ]
            guard Set(shared.keys).isDisjoint(with: reserved.keys) else {
                throw WorkflowIssue("Map shared 字段与 item/value/index 冲突。", nodeID: planned.node.id)
            }
            let arguments = shared.merging(reserved) { current, _ in current }
            do {
                let outputs = try await executePlan(
                    body,
                    arguments: arguments,
                    base: address.appending(.item(item.id)),
                    allowExtraArguments: true
                )
                guard let value = outputs[outputDefinition.name]?.datum else {
                    throw WorkflowIssue("Map body 没有返回可验证的数据：\(outputDefinition.name)。")
                }
                try value.validate(as: outputDefinition.schema)
                let result = WorkflowDataResult(status: .success, expected: outputDefinition.schema, value: value)
                results.append(.init(id: item.id, value: .result(result)))
            } catch let suspension as PlanSuspension {
                throw suspension
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if checkpoint?.state == .saving { throw error }
                if checkpoint?.records.contains(where: { $0.step.status == .waiting }) == true { throw error }
                let result = WorkflowDataResult(
                    status: .failed,
                    expected: outputDefinition.schema,
                    issues: [error.localizedDescription]
                )
                results.append(.init(id: item.id, value: .result(result)))
                try await saveMapProgress(results, schema: outputDefinition.schema, address: address)
                if !continueOnFailure { throw error }
                continue
            }
            try await saveMapProgress(results, schema: outputDefinition.schema, address: address)
        }
        let list = WorkflowDatum.list(element: .result(outputDefinition.schema), items: results)
        try list.validate()
        return ["output": .data(list)]
    }

    private func saveMapProgress(
        _ items: [WorkflowDataItem], schema: WorkflowDataSchema, address: WorkflowExecutionAddress
    ) async throws {
        let value = WorkflowDatum.list(element: .result(schema), items: items)
        try updateRecord(at: address) { record in record.step.outputs = ["output": .data(value)] }
        try await persist()
    }

    private func executeLoop(
        _ planned: WorkflowPlannedStep,
        body: WorkflowPlan,
        stateSchema: WorkflowDataSchema,
        maximumIterations: Int,
        until: WorkflowDataRule,
        inputs: [String: WorkflowValue],
        address: WorkflowExecutionAddress
    ) async throws -> [String: WorkflowValue] {
        var state = try requiredDatum(inputs["input"], node: planned.node, port: "input")
        try state.validate(as: stateSchema)
        let shared = try sharedFields(inputs["shared"], node: planned.node)
        guard shared["state"] == nil, shared["iteration"] == nil else {
            throw WorkflowIssue("Loop shared 不能覆盖 state/iteration。", nodeID: planned.node.id)
        }
        let outputDefinition = try loopBodyOutput(body.interface)
        let exitChoices = ["conditionMet", "iterationLimit", "failed", "cancelled"]

        do {
            for iteration in 1...maximumIterations {
                try await honorRequests()
                if try until.matches(state) {
                    try setLoopExit(.conditionMet, at: address)
                    return [
                        "output": .data(state),
                        "exitReason": .data(.enumeration("conditionMet", choices: exitChoices)),
                    ]
                }
                let arguments = shared.merging(["state": state, "iteration": .number(Double(iteration), unit: nil)]) { current, _ in current }
                let outputs = try await executePlan(
                    body,
                    arguments: arguments,
                    base: address.appending(.iteration(iteration)),
                    allowExtraArguments: true
                )
                guard let next = outputs[outputDefinition.name]?.datum else {
                    throw WorkflowIssue("Loop body 没有返回 state。", nodeID: planned.node.id)
                }
                try next.validate(as: stateSchema)
                state = next
                try updateRecord(at: address) { record in record.step.outputs = ["output": .data(state)] }
                try await persist()
            }
            try await honorRequests()
            if try until.matches(state) {
                try setLoopExit(.conditionMet, at: address)
                return [
                    "output": .data(state),
                    "exitReason": .data(.enumeration("conditionMet", choices: exitChoices)),
                ]
            }
            try setLoopExit(.iterationLimit, at: address)
            return [
                "output": .data(state),
                "exitReason": .data(.enumeration("iterationLimit", choices: exitChoices)),
            ]
        } catch PlanSuspension.stopped {
            try updateRecord(at: address) { record in
                record.loopExit = .cancelled
                record.step.status = .cancelled
            }
            try await persist()
            throw PlanSuspension.stopped
        } catch let suspension as PlanSuspension {
            throw suspension
        } catch is CancellationError {
            try updateRecord(at: address) { record in
                record.loopExit = .cancelled
                record.step.status = .cancelled
            }
            try await persist()
            throw CancellationError()
        } catch {
            if checkpoint?.state == .saving { throw error }
            if checkpoint?.records.contains(where: { $0.step.status == .waiting }) == true { throw error }
            try setLoopExit(.failed, at: address)
            try await persist()
            throw error
        }
    }

    private func finish(
        _ planned: WorkflowPlannedStep,
        outputs: [String: WorkflowValue],
        address: WorkflowExecutionAddress
    ) async throws -> [String: WorkflowValue] {
        try validateOutputs(outputs, for: planned)
        let partial = outputs.values.contains { value in
            guard case .collection(let candidates) = value else { return false }
            return candidates.contains { $0.asset == nil }
        }
        try updateRecord(at: address) { record in
            record.step.outputs = outputs
            record.step.status = partial ? .partial : .completed
            record.step.error = nil
        }
        try await persist()
        try await honorRequests()
        return outputs
    }

    private func validateOutputs(_ outputs: [String: WorkflowValue], for step: WorkflowPlannedStep) throws {
        let ports = try outputPorts(for: step)
        for key in outputs.keys where ports[key] == nil {
            throw WorkflowIssue("调用返回未知输出。", nodeID: step.node.id, port: key)
        }
        for (name, port) in ports where port.required && outputs[name] == nil {
            throw WorkflowIssue("调用缺少必需输出。", nodeID: step.node.id, port: name)
        }
        for (name, value) in outputs {
            guard let port = ports[name], port.kinds.contains(value.kind) else {
                throw WorkflowIssue("调用输出类型不兼容。", nodeID: step.node.id, port: name)
            }
            if case .data(let datum) = value {
                try datum.validate()
                if step.node.operationID == "d.value.field", name == "output",
                   let schema = step.node.dataConfiguration?.schema {
                    try datum.validate(as: schema)
                }
                if let schema = port.schema { try datum.validate(as: schema) }
            }
        }
    }

    private func bindInputs(
        for step: WorkflowPlannedStep,
        runtimeNode: WorkflowNode,
        plan: WorkflowPlan,
        base: WorkflowExecutionAddress
    ) throws -> [String: WorkflowValue] {
        let ports = try inputPorts(for: step)
        let plannedNodeIDs = Set(plan.steps.map { $0.node.id })
        let external = checkpoint?.externalInputs[runtimeNode.id] ?? [:]
        var result: [String: WorkflowValue] = [:]

        for input in step.inputs {
            if plannedNodeIDs.contains(input.sourceNode) {
                guard external[input.port] == nil else {
                    throw WorkflowIssue("已规划连接与 externalInputs 同时绑定同一端口。", nodeID: runtimeNode.id, port: input.port)
                }
                let sourceAddress = base.appending(.node(input.sourceNode))
                guard let source = record(at: sourceAddress), [.completed, .partial].contains(source.step.status),
                      let value = source.step.outputs[input.sourcePort] else {
                    throw WorkflowIssue(
                        "已规划的上游输出尚未完成；地址 \(describe(base.appending(.node(runtimeNode.id))))。",
                        nodeID: runtimeNode.id, port: input.port
                    )
                }
                result[input.port] = value
            } else {
                guard let value = external[input.port] else {
                    throw WorkflowIssue(
                        "计划边界外的输入必须由 externalInputs 明确提供；地址 \(describe(base.appending(.node(runtimeNode.id))))。",
                        nodeID: runtimeNode.id, port: input.port
                    )
                }
                result[input.port] = value
            }
        }
        for (name, value) in external where result[name] == nil { result[name] = value }
        try validatePortValues(
            result, ports: ports, nodeID: runtimeNode.id, requireAll: true,
            address: base.appending(.node(runtimeNode.id))
        )
        return result
    }

    private func validateExternalInputs() throws {
        guard let checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
        let steps = Dictionary(uniqueKeysWithValues: checkpoint.plan.steps.map { ($0.node.id, $0) })
        let selected = Set(steps.keys)
        for (nodeID, values) in checkpoint.externalInputs {
            guard let step = steps[nodeID] else { throw WorkflowIssue("externalInputs 引用了未知计划节点。", nodeID: nodeID) }
            let ports = try inputPorts(for: step)
            for (name, value) in values {
                guard let port = ports[name] else {
                    throw WorkflowIssue("externalInputs 引用了未知端口。", nodeID: nodeID, port: name)
                }
                if step.inputs.contains(where: { $0.port == name && selected.contains($0.sourceNode) }) {
                    throw WorkflowIssue("externalInputs 与计划内连接重复。", nodeID: nodeID, port: name)
                }
                try validateValue(value, port: port, nodeID: nodeID, name: name)
            }
        }
    }

    private func validateCheckpoint() throws {
        guard let checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
        guard checkpoint.plan.version == 1 else { throw WorkflowIssue("不支持的结构化计划版本。") }
        guard Set(checkpoint.plan.steps.map(\.node.id)).count == checkpoint.plan.steps.count else {
            throw WorkflowIssue("顶层计划节点身份重复。")
        }
        guard checkpoint.records.allSatisfy({ $0.address.runID == checkpoint.runID }) else {
            throw WorkflowIssue("调用记录引用了不同的 runID。")
        }
        guard Set(checkpoint.records.map(\.address)).count == checkpoint.records.count else {
            throw WorkflowIssue("调用记录地址重复。")
        }
        guard Set(checkpoint.records.map(\.step.id)).count == checkpoint.records.count else {
            throw WorkflowIssue("调用记录 stepID 重复。")
        }
    }

    private func validateSubmittedWaitingDecisions() throws {
        guard let checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
        for record in checkpoint.records where record.step.status == .waiting {
            guard let task = record.step.humanTask else { continue }
            guard task.id == record.step.id else {
                throw WorkflowIssue("人工任务身份与实际 stepID 不一致。", nodeID: record.step.node.id)
            }
            if !task.rejected, let decision = task.decision {
                try decision.validate(as: task.resultSchema)
            }
        }
    }

    private func validateResumeCheckpoint(
        held: WorkflowPlanCheckpoint,
        supplied: WorkflowPlanCheckpoint
    ) throws {
        guard held.state == supplied.state,
              held.outputs == supplied.outputs,
              held.error == supplied.error,
              held.records.count == supplied.records.count else {
            throw WorkflowIssue("收到过期或被改写的恢复点。")
        }
        for (old, new) in zip(held.records, supplied.records) {
            guard old.address == new.address, old.loopExit == new.loopExit else {
                throw WorkflowIssue("恢复点调用地址或循环状态被改写。")
            }
            if old.step.status != .waiting {
                guard old.step == new.step else { throw WorkflowIssue("非等待步骤的快照不可改写。") }
                continue
            }
            var oldStep = old.step
            var newStep = new.step
            oldStep.decision = nil
            newStep.decision = nil
            oldStep.reviewTextDraft = nil
            newStep.reviewTextDraft = nil
            if var oldTask = oldStep.humanTask, var newTask = newStep.humanTask {
                oldTask.draft = nil
                oldTask.decision = nil
                oldTask.rejected = false
                newTask.draft = nil
                newTask.decision = nil
                newTask.rejected = false
                oldStep.humanTask = oldTask
                newStep.humanTask = newTask
            }
            guard oldStep == newStep else {
                throw WorkflowIssue("等待步骤只能更新草稿或明确决定。")
            }
        }
    }

    private func inputPorts(for step: WorkflowPlannedStep) throws -> [String: RuntimePort] {
        if case .invoke(_, let body) = step.kind {
            return Dictionary(uniqueKeysWithValues: body.interface.inputs.map {
                ($0.name, RuntimePort(kinds: $0.type.portKinds, required: $0.required, schema: $0.type))
            })
        }
        guard let definition = registry.definition(for: step.node) else {
            throw WorkflowIssue("未知操作。", nodeID: step.node.id)
        }
        return Dictionary(uniqueKeysWithValues: definition.inputs.map {
            ($0.id, RuntimePort(kinds: $0.kinds, required: $0.required, schema: nil))
        })
    }

    private func outputPorts(for step: WorkflowPlannedStep) throws -> [String: RuntimePort] {
        if case .invoke(_, let body) = step.kind {
            return Dictionary(uniqueKeysWithValues: body.interface.outputs.map {
                ($0.name, RuntimePort(kinds: $0.schema.portKinds, required: true, schema: $0.schema))
            })
        }
        guard let definition = registry.definition(for: step.node) else {
            throw WorkflowIssue("未知操作。", nodeID: step.node.id)
        }
        return Dictionary(uniqueKeysWithValues: definition.outputs.map { port in
            let required: Bool
            switch step.kind {
            case .branch, .map:
                required = port.id == "output"
            default:
                required = port.required
            }
            return (port.id, RuntimePort(kinds: port.kinds, required: required, schema: nil))
        })
    }

    private func validatePortValues(
        _ values: [String: WorkflowValue],
        ports: [String: RuntimePort],
        nodeID: UUID,
        requireAll: Bool,
        address: WorkflowExecutionAddress? = nil
    ) throws {
        for name in values.keys where ports[name] == nil {
            throw WorkflowIssue("收到未知输入。", nodeID: nodeID, port: name)
        }
        if requireAll {
            for (name, port) in ports where port.required && values[name] == nil {
                let location = address.map { "；地址 \(describe($0))" } ?? ""
                throw WorkflowIssue("输入尚未就绪\(location)。", nodeID: nodeID, port: name)
            }
        }
        for (name, value) in values {
            try validateValue(value, port: ports[name]!, nodeID: nodeID, name: name)
        }
    }

    private func validateValue(_ value: WorkflowValue, port: RuntimePort, nodeID: UUID, name: String) throws {
        guard port.kinds.contains(value.kind) else {
            throw WorkflowIssue("输入实际类型不兼容。", nodeID: nodeID, port: name)
        }
        if case .data(let datum) = value {
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

    private func validateArguments(
        _ arguments: [String: WorkflowDatum],
        plan: WorkflowPlan,
        base: WorkflowExecutionAddress,
        allowExtra: Bool
    ) throws {
        let interface = plan.interface
        let fields = Dictionary(uniqueKeysWithValues: interface.inputs.map { ($0.name, $0) })
        if !allowExtra {
            for name in arguments.keys where fields[name] == nil {
                throw WorkflowIssue("收到未声明的流程参数：\(name)。")
            }
        }
        for (name, field) in fields {
            guard let value = arguments[name] else {
                if field.required {
                    let nodeID = plan.steps.first {
                        $0.node.operationID == "d.value.input" && $0.node.parameters["publicName"]?.string == name
                    }?.node.id
                    let address = nodeID.map { base.appending(.node($0)) } ?? base
                    throw WorkflowIssue(
                        "缺少必填流程参数；地址 \(describe(address))。",
                        nodeID: nodeID, port: name
                    )
                }
                continue
            }
            try value.validate(as: field.type)
        }
    }

    private func collectOutputs(_ plan: WorkflowPlan, base: WorkflowExecutionAddress) throws -> [String: WorkflowValue] {
        if !plan.interface.outputs.isEmpty {
            var result: [String: WorkflowValue] = [:]
            for output in plan.interface.outputs {
                let address = base.appending(.node(output.nodeID))
                guard let value = record(at: address)?.step.outputs[output.port], let datum = value.datum else {
                    throw WorkflowIssue("流程命名输出尚未产生。", nodeID: output.nodeID, port: output.port)
                }
                try datum.validate(as: output.schema)
                result[output.name] = value
            }
            return result
        }
        guard let last = plan.steps.last else { return [:] }
        return record(at: base.appending(.node(last.node.id)))?.step.outputs ?? [:]
    }

    private func requiredDatum(_ value: WorkflowValue?, node: WorkflowNode, port: String) throws -> WorkflowDatum {
        guard let datum = value?.datum else { throw WorkflowIssue("控制输入必须是结构化数据。", nodeID: node.id, port: port) }
        try datum.validate()
        return datum
    }

    private func sharedFields(_ value: WorkflowValue?, node: WorkflowNode) throws -> [String: WorkflowDatum] {
        guard let value else { return [:] }
        let datum = try requiredDatum(value, node: node, port: "shared")
        guard case .record(_, let fields) = datum else {
            throw WorkflowIssue("shared 必须是记录。", nodeID: node.id, port: "shared")
        }
        return fields
    }

    private func bodyOutput(_ interface: WorkflowGraphInterface, purpose: String) throws -> WorkflowNamedOutput {
        if let output = interface.outputs.first(where: { $0.name == "output" }) { return output }
        guard interface.outputs.count == 1, let output = interface.outputs.first else {
            throw WorkflowIssue("\(purpose) body 必须声明 output 或唯一命名输出。")
        }
        return output
    }

    private func loopBodyOutput(_ interface: WorkflowGraphInterface) throws -> WorkflowNamedOutput {
        if let output = interface.outputs.first(where: { $0.name == "state" }) { return output }
        return try bodyOutput(interface, purpose: "Loop")
    }

    private func setLoopExit(_ value: WorkflowLoopExit, at address: WorkflowExecutionAddress) throws {
        try updateRecord(at: address) { $0.loopExit = value }
    }

    private func honorRequests() async throws {
        if stopRequested {
            guard var value = checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
            value.state = .cancelled
            value.error = nil
            for index in value.records.indices where value.records[index].step.status == .running {
                value.records[index].step.status = .cancelled
            }
            checkpoint = value
            try await persist()
            throw PlanSuspension.stopped
        }
        if pauseRequested {
            guard var value = checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
            value.state = .paused
            value.error = nil
            checkpoint = value
            try await persist()
            throw PlanSuspension.paused
        }
    }

    private func wait() async throws -> Never {
        guard var value = checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
        value.state = .waiting
        value.error = nil
        checkpoint = value
        try await persist()
        throw PlanSuspension.waiting
    }

    private func cancelPlan(reason: String) async throws -> Never {
        guard var value = checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
        value.state = .cancelled
        value.error = reason
        checkpoint = value
        try await persist()
        throw PlanSuspension.stopped
    }

    private func persist() async throws {
        guard var value = checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
        do {
            try await save(value)
        } catch {
            value.state = .saving
            value.error = "Save failed: \(error.localizedDescription)"
            checkpoint = value
            throw error
        }
    }

    private func retrySavingCheckpoint() async throws {
        guard let saving = checkpoint, saving.state == .saving else { return }
        do {
            try await save(saving)
        } catch {
            checkpoint = saving
            throw error
        }
        let resumedState = derivedState(saving)
        var resumedOutputs = saving.outputs
        if resumedState == .completed {
            let base = WorkflowExecutionAddress(runID: saving.runID)
            resumedOutputs = try collectOutputs(saving.plan, base: base)
        }
        var resumed = saving
        resumed.outputs = resumedOutputs
        resumed.state = resumedState
        resumed.error = derivedError(saving, state: resumedState)
        checkpoint = resumed
        try await persist()
    }

    private func derivedState(_ value: WorkflowPlanCheckpoint) -> WorkflowPlanState {
        if value.records.contains(where: { $0.step.status == .waiting }) { return .waiting }
        let top = value.plan.steps.map { step in
            value.records.first { $0.address == WorkflowExecutionAddress(runID: value.runID, path: [.node(step.node.id)]) }
        }
        if !top.isEmpty && top.allSatisfy({ record in
            guard let record else { return false }
            return [.completed, .partial].contains(record.step.status)
        }) { return .completed }
        if top.contains(where: { $0?.step.status == .failed }) { return .failed }
        if top.contains(where: { record in
            guard let status = record?.step.status else { return false }
            return [.cancelled, .rejected].contains(status)
        }) { return .cancelled }
        return .running
    }

    private func derivedError(_ value: WorkflowPlanCheckpoint, state: WorkflowPlanState) -> String? {
        switch state {
        case .failed, .cancelled:
            return value.records.last(where: { $0.step.error != nil })?.step.error
        default:
            return nil
        }
    }

    private func appendRecord(_ record: WorkflowPlanCallRecord) {
        guard var value = checkpoint else { return }
        value.records.append(record)
        checkpoint = value
    }

    private func record(at address: WorkflowExecutionAddress) -> WorkflowPlanCallRecord? {
        checkpoint?.records.first { $0.address == address }
    }

    private func updateRecord(
        at address: WorkflowExecutionAddress,
        _ update: (inout WorkflowPlanCallRecord) throws -> Void
    ) throws {
        guard var value = checkpoint,
              let index = value.records.firstIndex(where: { $0.address == address }) else {
            throw WorkflowIssue("计划调用记录不存在。")
        }
        try update(&value.records[index])
        checkpoint = value
    }

    private func currentCheckpoint() throws -> WorkflowPlanCheckpoint {
        guard let checkpoint else { throw WorkflowIssue("计划恢复点不存在。") }
        return checkpoint
    }

    private func validateDataSchema(_ schema: WorkflowDataSchema, path: String, depth: Int = 0) throws {
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
            guard fields.count <= 256, Set(fields.map(\.name)).count == fields.count else {
                throw WorkflowIssue("\(path)：记录字段无效或重复。")
            }
            for field in fields {
                try validateDataSchema(field.type, path: path + "." + field.name, depth: depth + 1)
            }
        case .list(let item), .optional(let item), .result(let item):
            try validateDataSchema(item, path: path, depth: depth + 1)
        }
    }

    private func describe(_ address: WorkflowExecutionAddress) -> String {
        let path = address.path.map { component -> String in
            switch component {
            case .node(let id): return "node:\(id.uuidString)"
            case .branch(let selected): return "branch:\(selected ? "then" : "otherwise")"
            case .item(let id): return "item:\(id)"
            case .iteration(let value): return "iteration:\(value)"
            case .tool(let reference): return "tool:\(reference.id.uuidString)@\(reference.version)"
            }
        }.joined(separator: "/")
        return path.isEmpty ? address.runID.uuidString : address.runID.uuidString + "/" + path
    }
}

private enum PlanSuspension: Error {
    case waiting
    case paused
    case stopped
}

private struct RuntimePort {
    let kinds: [WorkflowDataKind]
    let required: Bool
    let schema: WorkflowDataSchema?
}
