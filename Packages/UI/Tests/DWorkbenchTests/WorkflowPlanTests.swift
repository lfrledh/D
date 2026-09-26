import Foundation
import Testing
@testable import DWorkbench

@Suite("Structured workflow plan r1") @MainActor
struct WorkflowPlanTests {
    @Test func compilerSelectsTargetsAndRejectsOnlyWithoutTarget() throws {
        let registry = try makeRegistry()
        let source = try makeNode("fixture.source", registry: registry)
        let other = try makeNode("fixture.source", registry: registry)
        let sink = try makeNode("fixture.echo", registry: registry)
        let graph = WorkflowGraph(nodes: [sink, other, source], connections: [
            .init(sourceNode: source.id, targetNode: sink.id),
        ])
        let compiler = WorkflowPlanCompiler(registry: registry)

        #expect(try compiler.compile(graph).steps.count == 3)
        #expect(try compiler.compile(graph, target: sink.id).steps.map(\.node.id) == [source.id, sink.id])
        #expect(try compiler.compile(graph, target: sink.id, only: true).steps.map(\.node.id) == [sink.id])
        #expect(throws: WorkflowIssue.self) { try compiler.compile(graph, only: true) }
    }

    @Test func compilerUsesToolInterfacesForNamedInvokePortsAndRejectsBadIdentity() throws {
        let registry = try makeRegistry()
        var input = try makeNode("d.value.input", registry: registry)
        input.parameters["publicName"] = .text("value")
        input.dataConfiguration = .init(value: .number(1, unit: nil))
        var body = WorkflowGraph(name: "number tool", nodes: [input])
        body.interface = .init(
            inputs: [.init("value", .number(unit: nil))],
            outputs: [.init(name: "answer", nodeID: input.id, schema: .number(unit: nil))]
        )
        let tool = WorkflowToolDefinition(name: "number-tool", graph: body)
        let digest = try WorkflowPlanCompiler.digest(tool)
        var invoke = try makeNode("d.control.invoke", registry: registry)
        invoke.control = .invoke(.init(id: tool.id, version: tool.version, digest: digest))
        invoke.dataConfiguration = .init(fields: body.interface!.inputs)
        var graph = WorkflowGraph(nodes: [invoke])
        graph.interface = .init(outputs: [
            .init(name: "answer", nodeID: invoke.id, port: "answer", schema: .number(unit: nil)),
        ])

        let plan = try WorkflowPlanCompiler(registry: registry).compile(graph, tools: [tool])
        #expect(plan.steps.count == 1)
        guard case .invoke(let reference, let compiledBody) = plan.steps[0].kind else {
            Issue.record("Expected a compiled invoke")
            return
        }
        #expect(reference.digest == digest)
        #expect(compiledBody.interface.outputs.first?.name == "answer")

        invoke.control = .invoke(.init(id: tool.id, version: tool.version, digest: "bad"))
        #expect(throws: WorkflowIssue.self) {
            try WorkflowPlanCompiler(registry: registry).compile(WorkflowGraph(nodes: [invoke]), tools: [tool])
        }
    }

    @Test func compilerRejectsRecursiveToolsBeforeExpansion() throws {
        let registry = try makeRegistry()
        let id = UUID()
        var invoke = try makeNode("d.control.invoke", registry: registry)
        invoke.control = .invoke(.init(id: id, version: 1, digest: "self-reference"))
        let tool = WorkflowToolDefinition(id: id, name: "recursive", graph: WorkflowGraph(nodes: [invoke]))
        #expect(throws: WorkflowIssue.self) {
            try WorkflowPlanCompiler(registry: registry).compile(WorkflowGraph(), tools: [tool])
        }
    }

    @Test func branchDoesNotExecuteUnselectedSide() async throws {
        let registry = try makeRegistry()
        let yes = try makeNode("fixture.source", title: "yes", registry: registry)
        let no = try makeNode("fixture.source", title: "no", registry: registry)
        let yesPlan = namedPlan(node: yes, schema: .number(unit: nil))
        let noPlan = namedPlan(node: no, schema: .number(unit: nil))
        var branch = try makeNode("d.control.branch", registry: registry)
        branch.control = .branch(
            predicate: .init(comparison: .equals, value: .boolean(true)),
            then: WorkflowGraph(), otherwise: WorkflowGraph()
        )
        let step = WorkflowPlannedStep(
            node: branch,
            inputs: [],
            kind: .branch(predicate: .init(comparison: .equals, value: .boolean(true)), then: yesPlan, otherwise: noPlan),
            effect: .pure
        )
        let plan = WorkflowPlan(graphID: UUID(), graphRevision: UUID(), steps: [step])
        var calls: [String] = []
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            calls.append(context.node.title)
            return .outputs(["output": .data(.number(context.node.title == "yes" ? 1 : 2, unit: nil))])
        }, save: { _ in })
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.externalInputs[branch.id] = ["input": .data(.boolean(true))]

        let completed = try await executor.execute(checkpoint)
        #expect(completed.state == .completed)
        #expect(calls == ["yes"])
    }

    @Test func mapPreservesItemIdentityAndFailurePosition() async throws {
        let registry = try makeRegistry()
        let call = try makeNode("fixture.source", registry: registry)
        let body = namedPlan(node: call, schema: .number(unit: nil))
        var map = try makeNode("d.control.map", registry: registry)
        map.control = .map(body: WorkflowGraph(), continueOnFailure: true)
        let step = WorkflowPlannedStep(node: map, inputs: [], kind: .map(body: body, continueOnFailure: true), effect: .pure)
        let plan = WorkflowPlan(graphID: UUID(), graphRevision: UUID(), steps: [step])
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            if context.address?.path.contains(where: { component in
                if case .item("bad") = component { return true }
                return false
            }) == true { throw FixtureError.failed }
            return .outputs(["output": .data(.number(7, unit: nil))])
        }, save: { _ in })
        let list = WorkflowDatum.list(element: .text, items: [
            .init(id: "good", value: .text("a")),
            .init(id: "bad", value: .text("b")),
            .init(id: "last", value: .text("c")),
        ])
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.externalInputs[map.id] = ["input": .data(list)]

        let completed = try await executor.execute(checkpoint)
        guard case .data(.list(_, let items))? = completed.outputs["output"] else {
            Issue.record("Expected map result list")
            return
        }
        #expect(items.map(\.id) == ["good", "bad", "last"])
        guard case .result(let failed) = items[1].value else {
            Issue.record("Expected failed result at original position")
            return
        }
        #expect(failed.status == .failed)
        #expect(failed.value == nil)
    }

    @Test func loopDistinguishesZeroIterationAndLimit() async throws {
        let registry = try makeRegistry()
        let call = try makeNode("fixture.source", registry: registry)
        let body = namedPlan(node: call, schema: .number(unit: nil), outputName: "state")
        var loop = try makeNode("d.control.loop", registry: registry)
        loop.control = .loop(
            body: WorkflowGraph(), stateSchema: .number(unit: nil), maximumIterations: 2,
            until: .init(comparison: .equals, value: .number(2, unit: nil))
        )
        let kind = WorkflowPlanStepKind.loop(
            body: body, stateSchema: .number(unit: nil), maximumIterations: 2,
            until: .init(comparison: .equals, value: .number(2, unit: nil))
        )
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: loop, inputs: [], kind: kind, effect: .pure)]
        )
        var calls = 0
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in
            calls += 1
            return .outputs(["output": .data(.number(1, unit: nil))])
        }, save: { _ in })
        var zero = WorkflowPlanCheckpoint(plan: plan)
        zero.externalInputs[loop.id] = ["input": .data(.number(2, unit: nil))]
        let zeroResult = try await executor.execute(zero)
        #expect(calls == 0)
        #expect(zeroResult.records.first?.loopExit == .conditionMet)

        let secondExecutor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in
            calls += 1
            return .outputs(["output": .data(.number(1, unit: nil))])
        }, save: { _ in })
        var limited = WorkflowPlanCheckpoint(plan: plan)
        limited.externalInputs[loop.id] = ["input": .data(.number(0, unit: nil))]
        let limitedResult = try await secondExecutor.execute(limited)
        #expect(calls == 2)
        #expect(limitedResult.records.first?.loopExit == .iterationLimit)
    }

    @Test func repeatedNestedToolCallsKeepIndependentAddressesAndStepIDs() async throws {
        let registry = try makeRegistry()
        let call = try makeNode("fixture.source", registry: registry)
        let innerBody = namedPlan(node: call, schema: .number(unit: nil))
        let innerReference = WorkflowToolReference(id: UUID(), version: 1, digest: "inner")
        var innerInvoke = try makeNode("d.control.invoke", registry: registry)
        innerInvoke.control = .invoke(innerReference)
        let outerBody = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: innerInvoke, inputs: [], kind: .invoke(reference: innerReference, body: innerBody), effect: .pure)],
            interface: .init(outputs: [
                .init(name: "output", nodeID: innerInvoke.id, schema: .number(unit: nil)),
            ])
        )
        let outerReference = WorkflowToolReference(id: UUID(), version: 1, digest: "outer")
        var first = try makeNode("d.control.invoke", title: "first", registry: registry)
        first.control = .invoke(outerReference)
        var second = try makeNode("d.control.invoke", title: "second", registry: registry)
        second.control = .invoke(outerReference)
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [
                .init(node: first, inputs: [], kind: .invoke(reference: outerReference, body: outerBody), effect: .pure),
                .init(node: second, inputs: [], kind: .invoke(reference: outerReference, body: outerBody), effect: .pure),
            ]
        )
        var calls = 0
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in
            calls += 1
            return .outputs(["output": .data(.number(Double(calls), unit: nil))])
        }, save: { _ in })

        let completed = try await executor.execute(.init(plan: plan))
        #expect(completed.state == .completed)
        #expect(calls == 2)
        #expect(Set(completed.records.map(\.address)).count == completed.records.count)
        #expect(Set(completed.records.map(\.step.id)).count == completed.records.count)
    }

    @Test func stopDuringLoopMarksCancelledExitAfterCurrentCallReturns() async throws {
        let registry = try makeRegistry()
        let call = try makeNode("fixture.source", registry: registry)
        let body = namedPlan(node: call, schema: .boolean, outputName: "state")
        var loop = try makeNode("d.control.loop", registry: registry)
        loop.control = .loop(
            body: WorkflowGraph(), stateSchema: .boolean, maximumIterations: 10,
            until: .init(comparison: .equals, value: .boolean(true))
        )
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(
                node: loop,
                inputs: [],
                kind: .loop(
                    body: body, stateSchema: .boolean, maximumIterations: 10,
                    until: .init(comparison: .equals, value: .boolean(true))
                ),
                effect: .pure
            )]
        )
        var calls = 0
        var executor: WorkflowPlanExecutor!
        executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in
            calls += 1
            executor.requestStop()
            return .outputs(["output": .data(.boolean(false))])
        }, save: { _ in })
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.externalInputs[loop.id] = ["input": .data(.boolean(false))]

        let stopped = try await executor.execute(checkpoint)
        #expect(stopped.state == .cancelled)
        #expect(calls == 1)
        #expect(stopped.records.first(where: { $0.step.node.id == loop.id })?.loopExit == .cancelled)
    }

    @Test func savingRetryUsesLatestCheckpointAndDoesNotRepeatCall() async throws {
        let registry = try makeRegistry()
        let call = try makeNode("fixture.source", registry: registry)
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: call, inputs: [], effect: .pure)]
        )
        var calls = 0
        var failSave = false
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in
            calls += 1
            failSave = true
            return .outputs(["output": .data(.number(1, unit: nil))])
        }, save: { _ in
            if failSave { throw FixtureError.save }
        })

        do {
            _ = try await executor.execute(.init(plan: plan))
            Issue.record("Expected save failure")
        } catch FixtureError.save {}
        #expect(calls == 1)
        let saving = try #require(executor.checkpoint)
        #expect(saving.state == .saving)

        var stale = saving
        stale.error = "stale"
        await #expect(throws: WorkflowIssue.self) { try await executor.execute(stale) }
        failSave = false
        let completed = try await executor.execute(saving)
        #expect(completed.state == .completed)
        #expect(calls == 1)
        #expect(completed.outputs["output"] == .data(.number(1, unit: nil)))
    }

    @Test func savingRetryDoesNotCompleteWhenCachedOutputViolatesPlanSchema() async throws {
        let registry = try makeRegistry()
        let call = try makeNode("fixture.source", registry: registry)
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: call, inputs: [], effect: .pure)],
            interface: .init(outputs: [
                .init(name: "output", nodeID: call.id, schema: .number(unit: "BPM")),
            ])
        )
        var calls = 0
        var failedSave = false
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in
            calls += 1
            return .outputs(["output": .data(.number(1, unit: "s"))])
        }, save: { checkpoint in
            if !failedSave,
               checkpoint.records.contains(where: { $0.step.status == .completed }) {
                failedSave = true
                throw FixtureError.save
            }
        })

        do {
            _ = try await executor.execute(.init(plan: plan))
            Issue.record("Expected save failure")
        } catch FixtureError.save {}
        let firstSaving = try #require(executor.checkpoint)
        #expect(firstSaving.state == .saving)
        #expect(calls == 1)

        await #expect(throws: WorkflowIssue.self) {
            try await executor.execute(firstSaving)
        }
        let secondSaving = try #require(executor.checkpoint)
        #expect(secondSaving.state == .saving)
        #expect(secondSaving.plan == plan)
        #expect(secondSaving.outputs.isEmpty)
        #expect(calls == 1)

        await #expect(throws: WorkflowIssue.self) {
            try await executor.execute(secondSaving)
        }
        let stillSaving = try #require(executor.checkpoint)
        #expect(stillSaving.state == .saving)
        #expect(stillSaving.plan == plan)
        #expect(stillSaving.outputs.isEmpty)
        #expect(stillSaving.records.first?.step.outputs["output"] == .data(.number(1, unit: "s")))
        #expect(calls == 1)
    }

    @Test func mapSaveFailureStopsImmediatelyAndRetryUsesCachedFirstItem() async throws {
        let registry = try makeRegistry()
        let call = try makeNode("fixture.source", registry: registry)
        let body = namedPlan(node: call, schema: .number(unit: nil))
        var map = try makeNode("d.control.map", registry: registry)
        map.control = .map(body: WorkflowGraph(), continueOnFailure: true)
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: map, inputs: [], kind: .map(body: body, continueOnFailure: true), effect: .pure)]
        )
        var calls: [String: Int] = [:]
        var failedSave = false
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            let item = try #require(context.address?.path.compactMap { component -> String? in
                if case .item(let id) = component { return id }
                return nil
            }.last)
            calls[item, default: 0] += 1
            return .outputs(["output": .data(.number(item == "first" ? 1 : 2, unit: nil))])
        }, save: { checkpoint in
            if !failedSave, checkpoint.records.contains(where: { record in
                record.step.node.id == call.id && record.step.status == .completed &&
                    record.address.path.contains(where: { component in
                        if case .item("first") = component { return true }
                        return false
                    })
            }) {
                failedSave = true
                throw FixtureError.save
            }
        })
        let list = WorkflowDatum.list(element: .text, items: [
            .init(id: "first", value: .text("a")),
            .init(id: "second", value: .text("b")),
        ])
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.externalInputs[map.id] = ["input": .data(list)]

        do {
            _ = try await executor.execute(checkpoint)
            Issue.record("Expected first item save failure")
        } catch FixtureError.save {}
        let saving = try #require(executor.checkpoint)
        #expect(saving.state == .saving)
        #expect(calls["first"] == 1)
        #expect(calls["second"] == nil)

        let completed = try await executor.execute(saving)
        #expect(completed.state == .completed)
        #expect(calls["first"] == 1)
        #expect(calls["second"] == 1)
        guard case .data(.list(_, let items))? = completed.outputs["output"] else {
            Issue.record("Expected completed map output")
            return
        }
        #expect(items.map(\.id) == ["first", "second"])
        #expect(items.allSatisfy { if case .result(let result) = $0.value { result.status == .success } else { false } })
    }

    @Test func loopSaveFailureDoesNotBecomeFailedExitAndRetryUsesCachedIteration() async throws {
        let registry = try makeRegistry()
        let call = try makeNode("fixture.source", registry: registry)
        let body = namedPlan(node: call, schema: .number(unit: nil), outputName: "state")
        var loop = try makeNode("d.control.loop", registry: registry)
        loop.control = .loop(
            body: WorkflowGraph(), stateSchema: .number(unit: nil), maximumIterations: 3,
            until: .init(comparison: .equals, value: .number(2, unit: nil))
        )
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(
                node: loop,
                inputs: [],
                kind: .loop(
                    body: body, stateSchema: .number(unit: nil), maximumIterations: 3,
                    until: .init(comparison: .equals, value: .number(2, unit: nil))
                ),
                effect: .pure
            )]
        )
        var calls: [Int: Int] = [:]
        var failedSave = false
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            let iteration = try #require(context.address?.path.compactMap { component -> Int? in
                if case .iteration(let value) = component { return value }
                return nil
            }.last)
            calls[iteration, default: 0] += 1
            return .outputs(["output": .data(.number(Double(iteration), unit: nil))])
        }, save: { checkpoint in
            if !failedSave, checkpoint.records.contains(where: { record in
                record.step.node.id == call.id && record.step.status == .completed &&
                    record.address.path.contains(where: { component in
                        if case .iteration(1) = component { return true }
                        return false
                    })
            }) {
                failedSave = true
                throw FixtureError.save
            }
        })
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.externalInputs[loop.id] = ["input": .data(.number(0, unit: nil))]

        do {
            _ = try await executor.execute(checkpoint)
            Issue.record("Expected first iteration save failure")
        } catch FixtureError.save {}
        let saving = try #require(executor.checkpoint)
        #expect(saving.state == .saving)
        #expect(saving.records.first(where: { $0.step.node.id == loop.id })?.loopExit == nil)
        #expect(calls[1] == 1)
        #expect(calls[2] == nil)

        let completed = try await executor.execute(saving)
        #expect(completed.state == .completed)
        #expect(calls[1] == 1)
        #expect(calls[2] == 1)
        #expect(completed.records.first(where: { $0.step.node.id == loop.id })?.loopExit == .conditionMet)
        #expect(completed.outputs["output"] == .data(.number(2, unit: nil)))
    }

    @Test func invalidNestedHumanDecisionKeepsBranchWaitingUntilCorrected() async throws {
        let registry = try makeRegistry()
        let pipeline = try humanPipeline(registry: registry)
        let unused = try makeNode("fixture.source", title: "unused", registry: registry)
        let unusedPlan = namedPlan(node: unused, schema: .boolean)
        var branch = try makeNode("d.control.branch", registry: registry)
        branch.control = .branch(
            predicate: .init(comparison: .equals, value: .boolean(true)),
            then: WorkflowGraph(), otherwise: WorkflowGraph()
        )
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(
                node: branch,
                inputs: [],
                kind: .branch(
                    predicate: .init(comparison: .equals, value: .boolean(true)),
                    then: pipeline.plan, otherwise: unusedPlan
                ),
                effect: .pure
            )]
        )
        let counter = PlanCallCounter()
        let executor = humanExecutor(registry: registry, counter: counter)
        var initial = WorkflowPlanCheckpoint(plan: plan)
        initial.externalInputs[branch.id] = ["input": .data(.boolean(true))]
        var waiting = try await executor.execute(initial)
        #expect(waiting.state == .waiting)
        let humanIndex = try #require(waiting.records.firstIndex(where: { $0.step.node.id == pipeline.human.id }))
        let taskID = try #require(waiting.records[humanIndex].step.humanTask?.id)
        waiting.records[humanIndex].step.humanTask?.draft = .text("kept draft")
        waiting.records[humanIndex].step.humanTask?.decision = .text("wrong type")

        await #expect(throws: WorkflowIssue.self) { try await executor.execute(waiting) }
        let stillWaiting = try #require(executor.checkpoint)
        #expect(stillWaiting.state == .waiting)
        #expect(stillWaiting.records.first(where: { $0.step.node.id == branch.id })?.step.status == .running)
        #expect(counter.downstream == 0)
        let preserved = try #require(stillWaiting.records.first(where: { $0.step.node.id == pipeline.human.id })?.step.humanTask)
        #expect(preserved.id == taskID)
        #expect(preserved.draft == .text("kept draft"))

        var corrected = stillWaiting
        let correctedIndex = try #require(corrected.records.firstIndex(where: { $0.step.node.id == pipeline.human.id }))
        corrected.records[correctedIndex].step.humanTask?.decision = .boolean(true)
        let completed = try await executor.execute(corrected)
        #expect(completed.state == .completed)
        #expect(completed.outputs["output"] == .data(.boolean(true)))
        #expect(counter.downstream == 1)

        let rejectionCounter = PlanCallCounter()
        let rejectionExecutor = humanExecutor(registry: registry, counter: rejectionCounter)
        var rejectionWaiting = try await rejectionExecutor.execute(initial)
        let rejectionIndex = try #require(rejectionWaiting.records.firstIndex(where: { $0.step.node.id == pipeline.human.id }))
        let rejectionTaskID = try #require(rejectionWaiting.records[rejectionIndex].step.humanTask?.id)
        rejectionWaiting.records[rejectionIndex].step.humanTask?.draft = .text("rejected draft")
        rejectionWaiting.records[rejectionIndex].step.humanTask?.rejected = true
        let rejected = try await rejectionExecutor.execute(rejectionWaiting)
        #expect(rejected.state == .cancelled)
        #expect(rejected.error == "Human task rejected: \(rejectionTaskID.uuidString)")
        #expect(rejected.records.first(where: { $0.step.node.id == branch.id })?.step.status != .failed)
        #expect(rejectionCounter.downstream == 0)
    }

    @Test func invalidNestedHumanDecisionIsNotAMapItemFailure() async throws {
        let registry = try makeRegistry()
        let pipeline = try humanPipeline(registry: registry)
        var map = try makeNode("d.control.map", registry: registry)
        map.control = .map(body: WorkflowGraph(), continueOnFailure: true)
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: map, inputs: [], kind: .map(body: pipeline.plan, continueOnFailure: true), effect: .pure)]
        )
        let counter = PlanCallCounter()
        let executor = humanExecutor(registry: registry, counter: counter)
        let list = WorkflowDatum.list(element: .text, items: [.init(id: "only", value: .text("item"))])
        var initial = WorkflowPlanCheckpoint(plan: plan)
        initial.externalInputs[map.id] = ["input": .data(list)]
        var waiting = try await executor.execute(initial)
        let humanIndex = try #require(waiting.records.firstIndex(where: { $0.step.node.id == pipeline.human.id }))
        let taskID = try #require(waiting.records[humanIndex].step.humanTask?.id)
        waiting.records[humanIndex].step.humanTask?.draft = .text("map draft")
        waiting.records[humanIndex].step.humanTask?.decision = .text("wrong type")

        await #expect(throws: WorkflowIssue.self) { try await executor.execute(waiting) }
        let stillWaiting = try #require(executor.checkpoint)
        #expect(stillWaiting.state == .waiting)
        #expect(stillWaiting.records.first(where: { $0.step.node.id == map.id })?.step.status == .running)
        #expect(counter.downstream == 0)
        let preserved = try #require(stillWaiting.records.first(where: { $0.step.node.id == pipeline.human.id })?.step.humanTask)
        #expect(preserved.id == taskID)
        #expect(preserved.draft == .text("map draft"))

        var corrected = stillWaiting
        let correctedIndex = try #require(corrected.records.firstIndex(where: { $0.step.node.id == pipeline.human.id }))
        corrected.records[correctedIndex].step.humanTask?.decision = .boolean(true)
        let completed = try await executor.execute(corrected)
        #expect(completed.state == .completed)
        #expect(counter.downstream == 1)
        guard case .data(.list(_, let items))? = completed.outputs["output"],
              let first = items.first,
              case .result(let result) = first.value else {
            Issue.record("Expected successful Map result after corrected decision")
            return
        }
        #expect(result.status == .success)
        #expect(result.value == .boolean(true))
    }

    @Test func pauseWaitsForCallAndResumeDoesNotRepeatIt() async throws {
        let registry = try makeRegistry()
        let call = try makeNode("fixture.source", registry: registry)
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: call, inputs: [], effect: .pure)]
        )
        var calls = 0
        var executor: WorkflowPlanExecutor!
        executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in
            calls += 1
            executor.requestPause()
            return .outputs(["output": .data(.number(1, unit: nil))])
        }, save: { _ in })

        let paused = try await executor.execute(.init(plan: plan))
        #expect(paused.state == .paused)
        #expect(calls == 1)
        let completed = try await executor.execute(paused)
        #expect(completed.state == .completed)
        #expect(calls == 1)
    }

    @Test func typedHumanWaitsThenRejectsWithoutFakeOutput() async throws {
        let registry = try makeRegistry()
        let human = try makeNode("d.control.human", registry: registry)
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: human, inputs: [], effect: .human)]
        )
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            .humanTask(.init(
                id: context.stepID,
                kind: .approve,
                title: "Approve",
                materials: .text("draft"),
                resultSchema: .boolean
            ))
        }, save: { _ in })
        var initial = WorkflowPlanCheckpoint(plan: plan)
        initial.externalInputs[human.id] = ["input": .data(.text("draft"))]
        let waiting = try await executor.execute(initial)
        #expect(waiting.state == .waiting)

        var rejected = waiting
        var task = try #require(rejected.records[0].step.humanTask)
        task.rejected = true
        rejected.records[0].step.humanTask = task
        let stopped = try await executor.execute(rejected)
        #expect(stopped.state == .cancelled)
        #expect(stopped.error == "Human task rejected: \(task.id.uuidString)")
        #expect(stopped.outputs.isEmpty)
        #expect(stopped.records[0].step.outputs.isEmpty)
    }

    @Test func typedHumanDecisionResumesWithValidatedData() async throws {
        let registry = try makeRegistry()
        let human = try makeNode("d.control.human", registry: registry)
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: human, inputs: [], effect: .human)]
        )
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            .humanTask(.init(
                id: context.stepID,
                kind: .approve,
                title: "Approve",
                materials: .text("draft"),
                resultSchema: .boolean
            ))
        }, save: { _ in })
        var initial = WorkflowPlanCheckpoint(plan: plan)
        initial.externalInputs[human.id] = ["input": .data(.text("draft"))]
        var waiting = try await executor.execute(initial)
        var task = try #require(waiting.records[0].step.humanTask)
        task.decision = .boolean(true)
        waiting.records[0].step.humanTask = task

        let completed = try await executor.execute(waiting)
        #expect(completed.state == .completed)
        #expect(completed.outputs["output"] == .data(.boolean(true)))
    }

    private func humanPipeline(
        registry: WorkflowRegistry
    ) throws -> (plan: WorkflowPlan, human: WorkflowNode) {
        let source = try makeNode("fixture.source", title: "materials", registry: registry)
        let human = try makeNode("d.control.human", title: "human", registry: registry)
        let downstream = try makeNode("fixture.echo", title: "downstream", registry: registry)
        let plan = WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [
                .init(node: source, inputs: [], effect: .pure),
                .init(
                    node: human,
                    inputs: [.init(port: "input", sourceNode: source.id)],
                    effect: .human
                ),
                .init(
                    node: downstream,
                    inputs: [.init(port: "input", sourceNode: human.id)],
                    effect: .pure
                ),
            ],
            interface: .init(outputs: [
                .init(name: "output", nodeID: downstream.id, schema: .boolean),
            ])
        )
        return (plan, human)
    }

    private func humanExecutor(
        registry: WorkflowRegistry,
        counter: PlanCallCounter
    ) -> WorkflowPlanExecutor {
        WorkflowPlanExecutor(registry: registry, executeCall: { context in
            switch context.node.operationID {
            case "fixture.source":
                return .outputs(["output": .data(.text("draft"))])
            case "d.control.human":
                return .humanTask(.init(
                    id: context.stepID,
                    kind: .approve,
                    title: "Approve",
                    materials: try #require(context.inputs["input"]?.datum),
                    resultSchema: .boolean
                ))
            case "fixture.echo":
                counter.downstream += 1
                return .outputs(["output": try #require(context.inputs["input"])])
            default:
                throw FixtureError.unexpectedService
            }
        }, save: { _ in })
    }

    private func namedPlan(
        node: WorkflowNode,
        schema: WorkflowDataSchema,
        outputName: String = "output"
    ) -> WorkflowPlan {
        WorkflowPlan(
            graphID: UUID(), graphRevision: UUID(),
            steps: [.init(node: node, inputs: [], effect: .pure)],
            interface: .init(outputs: [
                .init(name: outputName, nodeID: node.id, schema: schema),
            ])
        )
    }

    private func makeRegistry() throws -> WorkflowRegistry {
        let all = WorkflowDataKind.allCases
        func operation(
            _ id: String,
            inputs: [WorkflowPortDefinition] = [],
            outputs: [WorkflowPortDefinition] = [.init("output", "Output", kinds: WorkflowDataKind.allCases)],
            fields: [WorkflowFieldDefinition] = [],
            interaction: WorkflowInteraction = .none
        ) -> WorkflowOperation {
            WorkflowOperation(
                definition: .init(
                    id: id, title: id, detail: "fixture", inputs: inputs,
                    outputs: outputs, fields: fields, interaction: interaction
                ),
                execute: { _, _ in throw FixtureError.unexpectedService }
            )
        }
        func control(_ id: String) -> WorkflowOperation {
            operation(
                id,
                inputs: [
                    .init("input", "Input", kinds: all),
                    .init("shared", "Shared", kinds: [.record], required: false),
                ],
                outputs: [
                    .init("output", "Output", kinds: all),
                    .init("exitReason", "Exit", kinds: [.enumeration]),
                ]
            )
        }
        return try WorkflowRegistry(operations: [
            operation("fixture.source"),
            operation("fixture.echo", inputs: [.init("input", "Input", kinds: all)]),
            operation(
                "d.value.input",
                fields: [.init("publicName", "Public name", .text(multiline: false), .text(""))]
            ),
            control("d.control.branch"),
            control("d.control.map"),
            control("d.control.loop"),
            control("d.control.invoke"),
            operation("d.control.human", inputs: [.init("input", "Input", kinds: all)]),
        ])
    }

    private func makeNode(
        _ id: String,
        title: String? = nil,
        registry: WorkflowRegistry
    ) throws -> WorkflowNode {
        guard let operation = registry.operation(id) else { throw FixtureError.missingOperation }
        var node = operation.definition.makeNode()
        if let title { node.title = title }
        return node
    }
}

private enum FixtureError: Error {
    case failed
    case save
    case unexpectedService
    case missingOperation
}

@MainActor private final class PlanCallCounter {
    var downstream = 0
}
