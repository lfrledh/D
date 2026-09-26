import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow run scopes r1") @MainActor
struct WorkflowRunScopeTests {
    @Test func downstreamFindsDiamondBypassBoundariesAndRejectsEmptyRanges() throws {
        let fixture = try ScopeFixture()
        let graph = try fixture.diamond()

        let excluding = try WorkflowScopePlanner.select(
            graph: graph.graph,
            selection: .downstream(graph.left.id, includingAnchor: false),
            registry: fixture.registry
        )
        #expect(excluding.plan.steps.map(\.node.id) == [graph.sink.id])
        #expect(boundaryDescriptions(excluding.boundaries) == Set([
            "\(graph.left.id):output>\(graph.sink.id):left",
            "\(graph.right.id):output>\(graph.sink.id):right",
        ]))

        let including = try WorkflowScopePlanner.select(
            graph: graph.graph,
            selection: .downstream(graph.left.id, includingAnchor: true),
            registry: fixture.registry
        )
        #expect(Set(including.plan.steps.map(\.node.id)) == Set([graph.left.id, graph.sink.id]))
        #expect(boundaryDescriptions(including.boundaries) == Set([
            "\(graph.source.id):output>\(graph.left.id):input",
            "\(graph.right.id):output>\(graph.sink.id):right",
        ]))

        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.select(
                graph: graph.graph,
                selection: .downstream(graph.sink.id, includingAnchor: false),
                registry: fixture.registry
            )
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.select(
                graph: graph.graph,
                selection: .downstream(UUID(), includingAnchor: true),
                registry: fixture.registry
            )
        }
    }

    @Test func throughAndOnlyRetainCompilerSignaturesAndProjectInterfaces() throws {
        let fixture = try ScopeFixture()
        var input = try fixture.node("d.value.input", title: "input")
        input.parameters["publicName"] = .text("prompt")
        input.dataConfiguration = .init(value: .text("default"))
        let echo = try fixture.node("fixture.echo", title: "echo")
        var graph = WorkflowGraph(nodes: [input, echo], connections: [
            .init(sourceNode: input.id, targetNode: echo.id),
        ])
        graph.interface = .init(
            inputs: [.init("prompt", .text)],
            outputs: [.init(name: "result", nodeID: echo.id, schema: .text)]
        )

        let through = try WorkflowScopePlanner.select(
            graph: graph, selection: .through(echo.id), registry: fixture.registry
        )
        #expect(through.plan.steps.map(\.node.id) == [input.id, echo.id])
        #expect(through.plan.interface.inputs.map(\.name) == ["prompt"])
        #expect(through.plan.interface.outputs.map(\.name) == ["result"])
        #expect(through.boundaries.isEmpty)

        let only = try WorkflowScopePlanner.select(
            graph: graph, selection: .only(echo.id), registry: fixture.registry
        )
        #expect(only.plan.steps.map(\.node.id) == [echo.id])
        #expect(only.plan.interface.inputs.isEmpty)
        #expect(only.plan.interface.outputs.map(\.name) == ["result"])
        #expect(only.plan.steps[0].sourceSignature == through.plan.steps[1].sourceSignature)
        #expect(only.boundaries == [
            .init(destinationNodeID: echo.id, destinationPort: "input", sourceNodeID: input.id, sourcePort: "output"),
        ])

        let toolBody = WorkflowGraph(nodes: [try fixture.node("fixture.source", title: "tool")])
        let tool = WorkflowToolDefinition(name: "fixed", graph: toolBody)
        var invoke = try fixture.node("d.control.invoke", title: "invoke")
        invoke.control = .invoke(.init(id: tool.id, version: tool.version, digest: "bad"))
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.select(
                graph: .init(nodes: [invoke]),
                selection: .only(invoke.id),
                tools: [tool],
                registry: fixture.registry
            )
        }
    }

    @Test func historicalPinsUseExactOldRunOutputsAndRejectMissingDuplicateOrForgedSources() async throws {
        let fixture = try ScopeFixture()
        let original = try fixture.diamond()
        let old = try await fixture.execute(
            graph: original.graph,
            selection: .through(original.sink.id)
        )
        let source = WorkflowScopeSource(
            graph: original.graph,
            selection: .through(original.sink.id),
            checkpoint: old
        )

        var editedGraph = original.graph
        let editedSourceIndex = try #require(editedGraph.nodes.firstIndex { $0.id == original.source.id })
        editedGraph.nodes[editedSourceIndex].operationID = "fixture.new-source"
        editedGraph.nodes[editedSourceIndex].title = "new-source"
        let destinationPlan = try WorkflowScopePlanner.rebuild(
            graph: editedGraph,
            selection: .only(original.sink.id),
            modelDefaults: [:],
            registry: fixture.registry
        )
        var destinationCheckpoint = WorkflowPlanCheckpoint(plan: destinationPlan)
        destinationCheckpoint.modelDefaults = [:]
        let destination = WorkflowScopeSource(
            graph: editedGraph,
            selection: .only(original.sink.id),
            checkpoint: destinationCheckpoint
        )
        let leftRecord = try #require(old.records.first { $0.step.node.id == original.left.id })
        let rightRecord = try #require(old.records.first { $0.step.node.id == original.right.id })
        let pins = [
            WorkflowHistoricalInput(
                destinationNodeID: original.sink.id,
                destinationPort: "left",
                sourceCall: .init(address: leftRecord.address, stepID: leftRecord.step.id),
                sourcePort: "output"
            ),
            WorkflowHistoricalInput(
                destinationNodeID: original.sink.id,
                destinationPort: "right",
                sourceCall: .init(address: rightRecord.address, stepID: rightRecord.step.id),
                sourcePort: "output"
            ),
        ]

        let resolved = try WorkflowScopePlanner.resolveHistoricalInputs(
            pins,
            destination: destination,
            sources: [source],
            registry: fixture.registry
        )
        #expect(resolved[original.sink.id]?["left"] == .data(.text("old-source")))
        #expect(resolved[original.sink.id]?["right"] == .data(.text("old-source")))
        var rerun = WorkflowPlanCheckpoint(plan: destinationPlan)
        rerun.modelDefaults = [:]
        rerun.externalInputs = resolved
        let rerunResult = try await fixture.executor().execute(rerun)
        #expect(rerunResult.outputs["output"] == .data(.text("old-sourceold-source")))

        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                Array(pins.dropLast()), destination: destination, sources: [source], registry: fixture.registry
            )
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                [pins[0], pins[0]], destination: destination, sources: [source], registry: fixture.registry
            )
        }
        var internalPin = pins[0]
        internalPin.destinationNodeID = original.left.id
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                [internalPin, pins[1]], destination: destination, sources: [source], registry: fixture.registry
            )
        }
        var wrongStep = pins
        wrongStep[0].sourceCall.stepID = UUID()
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                wrongStep, destination: destination, sources: [source], registry: fixture.registry
            )
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                pins, destination: destination, sources: [source, source], registry: fixture.registry
            )
        }

        var forgedCheckpoint = old
        forgedCheckpoint.plan.graphRevision = UUID()
        let forged = WorkflowScopeSource(
            graph: original.graph,
            selection: .through(original.sink.id),
            checkpoint: forgedCheckpoint
        )
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                pins, destination: destination, sources: [forged], registry: fixture.registry
            )
        }
        var forgedInputsCheckpoint = old
        let forgedInputIndex = try #require(
            forgedInputsCheckpoint.records.firstIndex { $0.step.node.id == original.left.id }
        )
        forgedInputsCheckpoint.records[forgedInputIndex].step.inputs["input"] = .data(.text("forged"))
        let forgedInputs = WorkflowScopeSource(
            graph: original.graph,
            selection: .through(original.sink.id),
            checkpoint: forgedInputsCheckpoint
        )
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                pins, destination: destination, sources: [forgedInputs], registry: fixture.registry
            )
        }
    }

    @Test func nestedMapCallBecomesRootOnlyAndUsesRuntimePublicInput() async throws {
        let fixture = try ScopeFixture()
        var item = try fixture.node("d.value.input", title: "body-input")
        item.parameters["publicName"] = .text("item")
        item.dataConfiguration = .init(value: .text("template-default"))
        var body = WorkflowGraph(name: "map-body", nodes: [item])
        body.interface = .init(
            inputs: [.init("item", .text)],
            outputs: [.init(name: "output", nodeID: item.id, schema: .text)]
        )
        var map = try fixture.node("d.control.map", title: "map")
        map.control = .map(body: body, continueOnFailure: false)
        let graph = WorkflowGraph(nodes: [map])
        let plan = try WorkflowScopePlanner.rebuild(
            graph: graph, selection: .through(map.id), modelDefaults: [:], registry: fixture.registry
        )
        let input = WorkflowDatum.list(element: .text, items: [
            .init(id: "first", value: .text("alpha")),
            .init(id: "second", value: .text("beta")),
        ])
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.modelDefaults = [:]
        checkpoint.externalInputs = [map.id: ["input": .data(input)]]
        checkpoint = try await fixture.executor().execute(checkpoint)
        let records = checkpoint.records.filter { $0.step.node.id == item.id }
        #expect(records.count == 2)
        let second = try #require(records.first { record in
            record.address.path.contains { component in
                if case .item("second") = component { return true }
                return false
            }
        })
        let reference = WorkflowCallReference(address: second.address, stepID: second.step.id)
        let resolved = try WorkflowScopePlanner.resolveCall(
            reference,
            source: .init(graph: graph, selection: .through(map.id), checkpoint: checkpoint),
            registry: fixture.registry
        )

        #expect(resolved.graph.id == body.id)
        #expect(resolved.plan.steps.map(\.node.id) == [item.id])
        #expect(resolved.arguments == ["item": .text("beta")])
        #expect(resolved.externalInputs == [item.id: [:]])
        #expect(resolved.originCall == reference)
        #expect(resolved.plan.steps[0].sourceSignature == second.step.signature)
        var derivedCheckpoint = WorkflowPlanCheckpoint(plan: resolved.plan, arguments: resolved.arguments)
        derivedCheckpoint.modelDefaults = resolved.modelDefaults
        derivedCheckpoint.externalInputs = resolved.externalInputs
        var calledNodeIDs: [UUID] = []
        let derivedExecutor = WorkflowPlanExecutor(registry: fixture.registry, executeCall: { context in
            calledNodeIDs.append(context.node.id)
            guard context.node.operationID == "d.value.input",
                  let value = context.node.dataConfiguration?.value else {
                throw ScopeFixtureError.unexpectedOperation
            }
            return .outputs(["output": .data(value)])
        }, save: { _ in })
        let derivedResult = try await derivedExecutor.execute(derivedCheckpoint)
        #expect(calledNodeIDs == [item.id])
        #expect(derivedResult.records.map(\.step.node.id) == [item.id])
        #expect(derivedResult.outputs["output"] == .data(.text("beta")))

        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveCall(
                .init(address: second.address, stepID: UUID()),
                source: .init(graph: graph, selection: .through(map.id), checkpoint: checkpoint),
                registry: fixture.registry
            )
        }
        var waiting = checkpoint
        let index = try #require(waiting.records.firstIndex(where: { $0.step.id == second.step.id }))
        waiting.records[index].step.status = .waiting
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveCall(
                reference,
                source: .init(graph: graph, selection: .through(map.id), checkpoint: waiting),
                registry: fixture.registry
            )
        }
    }

    @Test func historicalPinsResolveContainingGraphAndInvokeCallsRemainDerivable() async throws {
        let fixture = try ScopeFixture()
        let collisionID = UUID()
        var rootSource = try fixture.node("fixture.source", title: "root-collision")
        rootSource.id = collisionID
        var toolSource = try fixture.node("fixture.source", title: "tool-collision")
        toolSource.id = collisionID
        var toolGraph = WorkflowGraph(name: "collision-tool", nodes: [toolSource])
        toolGraph.interface = .init(outputs: [
            .init(name: "output", nodeID: toolSource.id, schema: .text),
        ])
        let tool = WorkflowToolDefinition(name: "collision-tool", graph: toolGraph)
        let reference = WorkflowToolReference(
            id: tool.id,
            version: tool.version,
            digest: try WorkflowPlanCompiler.digest(tool)
        )
        var invoke = try fixture.node("d.control.invoke", title: "invoke")
        invoke.control = .invoke(reference)
        invoke.dataConfiguration = .init(fields: [])
        let rootSink = try fixture.node("fixture.echo", title: "root-sink")
        let invokeSink = try fixture.node("fixture.echo", title: "invoke-sink")
        let join = try fixture.node("fixture.join", title: "join")
        let graph = WorkflowGraph(nodes: [rootSource, invoke, rootSink, invokeSink, join], connections: [
            .init(sourceNode: rootSource.id, targetNode: rootSink.id),
            .init(sourceNode: invoke.id, targetNode: invokeSink.id),
            .init(sourceNode: rootSink.id, targetNode: join.id, targetPort: "left"),
            .init(sourceNode: invokeSink.id, targetNode: join.id, targetPort: "right"),
        ])
        let history = try await fixture.execute(
            graph: graph,
            selection: .through(join.id),
            tools: [tool]
        )
        let source = WorkflowScopeSource(
            graph: graph,
            selection: .through(join.id),
            checkpoint: history
        )
        let rootRecord = try #require(history.records.first {
            $0.address.path == [.node(rootSource.id)]
        })
        let toolRecord = try #require(history.records.first { record in
            record.step.node.id == collisionID && record.address.path.contains { component in
                if case .tool(let selected) = component { return selected == reference }
                return false
            }
        })
        let invokeRecord = try #require(history.records.first {
            $0.address.path == [.node(invoke.id)]
        })

        var destinationGraph = graph
        destinationGraph.revision = UUID()
        let rootDestinationPlan = try WorkflowScopePlanner.rebuild(
            graph: destinationGraph,
            selection: .only(rootSink.id),
            modelDefaults: [:],
            tools: [tool],
            registry: fixture.registry
        )
        var rootDestinationCheckpoint = WorkflowPlanCheckpoint(plan: rootDestinationPlan)
        rootDestinationCheckpoint.modelDefaults = [:]
        let rootDestination = WorkflowScopeSource(
            graph: destinationGraph,
            selection: .only(rootSink.id),
            checkpoint: rootDestinationCheckpoint
        )
        let rootPin = WorkflowHistoricalInput(
            destinationNodeID: rootSink.id,
            destinationPort: "input",
            sourceCall: .init(address: rootRecord.address, stepID: rootRecord.step.id),
            sourcePort: "output"
        )
        let rootResolved = try WorkflowScopePlanner.resolveHistoricalInputs(
            [rootPin],
            destination: rootDestination,
            sources: [source],
            tools: [tool],
            registry: fixture.registry
        )
        #expect(rootResolved[rootSink.id]?["input"] == .data(.text("root-collision")))

        let collidingToolPin = WorkflowHistoricalInput(
            destinationNodeID: rootSink.id,
            destinationPort: "input",
            sourceCall: .init(address: toolRecord.address, stepID: toolRecord.step.id),
            sourcePort: "output"
        )
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                [collidingToolPin],
                destination: rootDestination,
                sources: [source],
                tools: [tool],
                registry: fixture.registry
            )
        }

        let invokeDestinationPlan = try WorkflowScopePlanner.rebuild(
            graph: destinationGraph,
            selection: .only(invokeSink.id),
            modelDefaults: [:],
            tools: [tool],
            registry: fixture.registry
        )
        var invokeDestinationCheckpoint = WorkflowPlanCheckpoint(plan: invokeDestinationPlan)
        invokeDestinationCheckpoint.modelDefaults = [:]
        let controlPin = WorkflowHistoricalInput(
            destinationNodeID: invokeSink.id,
            destinationPort: "input",
            sourceCall: .init(address: invokeRecord.address, stepID: invokeRecord.step.id),
            sourcePort: "output"
        )
        let controlResolved = try WorkflowScopePlanner.resolveHistoricalInputs(
            [controlPin],
            destination: .init(
                graph: destinationGraph,
                selection: .only(invokeSink.id),
                checkpoint: invokeDestinationCheckpoint
            ),
            sources: [source],
            tools: [tool],
            registry: fixture.registry
        )
        #expect(controlResolved[invokeSink.id]?["input"] == .data(.text("tool-collision")))

        let derived = try WorkflowScopePlanner.resolveCall(
            .init(address: toolRecord.address, stepID: toolRecord.step.id),
            source: source,
            tools: [tool],
            registry: fixture.registry
        )
        #expect(derived.graph.id == toolGraph.id)
        #expect(derived.plan.steps.map(\.node.id) == [toolSource.id])
        #expect(derived.externalInputs == [toolSource.id: [:]])
    }

    @Test func historicalPinsValidateStructuredUnitsAtDestination() async throws {
        let fixture = try ScopeFixture()
        let sourceNode = try fixture.node("fixture.number-source", title: "seconds")
        var sink = try fixture.node("fixture.number-sink", title: "milliseconds")
        sink.dataConfiguration = .init(fields: [.init("input", .number(unit: "ms"))])
        let graph = WorkflowGraph(nodes: [sourceNode, sink], connections: [
            .init(sourceNode: sourceNode.id, targetNode: sink.id),
        ])
        let sourceCheckpoint = try await fixture.execute(graph: graph, selection: .only(sourceNode.id))
        let destinationPlan = try WorkflowScopePlanner.rebuild(
            graph: graph, selection: .only(sink.id), modelDefaults: [:], registry: fixture.registry
        )
        var destinationCheckpoint = WorkflowPlanCheckpoint(plan: destinationPlan)
        destinationCheckpoint.modelDefaults = [:]
        let record = try #require(sourceCheckpoint.records.first)
        let pin = WorkflowHistoricalInput(
            destinationNodeID: sink.id,
            destinationPort: "input",
            sourceCall: .init(address: record.address, stepID: record.step.id),
            sourcePort: "output"
        )
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                [pin],
                destination: .init(graph: graph, selection: .only(sink.id), checkpoint: destinationCheckpoint),
                sources: [
                    .init(graph: graph, selection: .only(sourceNode.id), checkpoint: sourceCheckpoint),
                ],
                registry: fixture.registry
            )
        }
    }

    @Test func historicalPinsValidateLoopStateSchemaBeforeExecution() async throws {
        let fixture = try ScopeFixture()
        let sourceNode = try fixture.node("fixture.number-source", title: "seconds")
        var state = try fixture.node("d.value.input", title: "beat-state")
        state.parameters["publicName"] = .text("state")
        state.dataConfiguration = .init(value: .number(0, unit: "beat"))
        var body = WorkflowGraph(name: "beat-loop-body", nodes: [state])
        body.interface = .init(
            inputs: [.init("state", .number(unit: "beat"))],
            outputs: [.init(name: "state", nodeID: state.id, schema: .number(unit: "beat"))]
        )
        var loop = try fixture.node("d.control.loop", title: "beat-loop")
        loop.control = .loop(
            body: body,
            stateSchema: .number(unit: "beat"),
            maximumIterations: 2,
            until: .init(comparison: .equals, value: .number(99, unit: "beat"))
        )
        let graph = WorkflowGraph(nodes: [sourceNode, loop], connections: [
            .init(sourceNode: sourceNode.id, targetNode: loop.id),
        ])
        let sourceCheckpoint = try await fixture.execute(graph: graph, selection: .only(sourceNode.id))
        let destinationPlan = try WorkflowScopePlanner.rebuild(
            graph: graph, selection: .only(loop.id), modelDefaults: [:], registry: fixture.registry
        )
        var destinationCheckpoint = WorkflowPlanCheckpoint(plan: destinationPlan)
        destinationCheckpoint.modelDefaults = [:]
        let record = try #require(sourceCheckpoint.records.first)
        let pin = WorkflowHistoricalInput(
            destinationNodeID: loop.id,
            destinationPort: "input",
            sourceCall: .init(address: record.address, stepID: record.step.id),
            sourcePort: "output"
        )
        #expect(throws: WorkflowIssue.self) {
            try WorkflowScopePlanner.resolveHistoricalInputs(
                [pin],
                destination: .init(graph: graph, selection: .only(loop.id), checkpoint: destinationCheckpoint),
                sources: [
                    .init(graph: graph, selection: .only(sourceNode.id), checkpoint: sourceCheckpoint),
                ],
                registry: fixture.registry
            )
        }
    }

    @Test func nestedLoopIterationsResolveByFullAddressWithoutNestedInjectionKeys() async throws {
        let fixture = try ScopeFixture()
        var state = try fixture.node("d.value.input", title: "loop-state")
        state.parameters["publicName"] = .text("state")
        state.dataConfiguration = .init(value: .number(0, unit: nil))
        var body = WorkflowGraph(name: "loop-body", nodes: [state])
        body.interface = .init(
            inputs: [.init("state", .number(unit: nil))],
            outputs: [.init(name: "state", nodeID: state.id, schema: .number(unit: nil))]
        )
        var loop = try fixture.node("d.control.loop", title: "loop")
        loop.control = .loop(
            body: body,
            stateSchema: .number(unit: nil),
            maximumIterations: 2,
            until: .init(comparison: .equals, value: .number(99, unit: nil))
        )
        let graph = WorkflowGraph(nodes: [loop])
        let plan = try WorkflowScopePlanner.rebuild(
            graph: graph, selection: .only(loop.id), modelDefaults: [:], registry: fixture.registry
        )
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.modelDefaults = [:]
        checkpoint.externalInputs = [loop.id: ["input": .data(.number(7, unit: nil))]]
        checkpoint = try await fixture.executor().execute(checkpoint)
        let iteration = try #require(checkpoint.records.first { record in
            record.step.node.id == state.id && record.address.path.contains { component in
                if case .iteration(2) = component { return true }
                return false
            }
        })
        let reference = WorkflowCallReference(address: iteration.address, stepID: iteration.step.id)
        let resolved = try WorkflowScopePlanner.resolveCall(
            reference,
            source: .init(graph: graph, selection: .only(loop.id), checkpoint: checkpoint),
            registry: fixture.registry
        )
        #expect(resolved.arguments == ["state": .number(7, unit: nil)])
        #expect(resolved.externalInputs == [state.id: [:]])
        #expect(resolved.plan.steps.map(\.node.id) == [state.id])
    }

    @Test func runScopeRoundTripsSelectionPinsAndOrigin() throws {
        let call = WorkflowCallReference(
            address: .init(runID: UUID(), path: [.node(UUID()), .item("stable"), .node(UUID())]),
            stepID: UUID()
        )
        let value = WorkflowRunScope(
            selection: .downstream(UUID(), includingAnchor: true),
            originCall: call,
            historicalInputs: [
                .init(destinationNodeID: UUID(), destinationPort: "input", sourceCall: call, sourcePort: "output"),
            ],
            recomputeSelected: true
        )
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(WorkflowRunScope.self, from: data) == value)
    }

    private func boundaryDescriptions(_ boundaries: [WorkflowScopeBoundary]) -> Set<String> {
        Set(boundaries.map {
            "\($0.sourceNodeID):\($0.sourcePort)>\($0.destinationNodeID):\($0.destinationPort)"
        })
    }
}

@MainActor private struct ScopeFixture {
    let registry: WorkflowRegistry

    init() throws {
        func operation(
            _ id: String,
            inputs: [WorkflowPortDefinition] = [],
            outputs: [WorkflowPortDefinition] = [.init("output", "Output", kinds: [.text])],
            fields: [WorkflowFieldDefinition] = []
        ) -> WorkflowOperation {
            WorkflowOperation(
                definition: .init(
                    id: id, title: id, detail: "scope fixture",
                    inputs: inputs, outputs: outputs, fields: fields
                ),
                execute: { _, _ in throw ScopeFixtureError.unexpectedOperation }
            )
        }
        registry = try WorkflowRegistry(operations: [
            operation("fixture.source"),
            operation("fixture.new-source"),
            operation(
                "fixture.number-source",
                outputs: [.init("output", "Output", kinds: [.number])]
            ),
            operation(
                "fixture.number-sink",
                inputs: [.init("input", "Input", kinds: [.number])],
                outputs: [.init("output", "Output", kinds: [.number])]
            ),
            operation("fixture.echo", inputs: [.init("input", "Input", kinds: [.text])]),
            operation(
                "fixture.join",
                inputs: [
                    .init("left", "Left", kinds: [.text]),
                    .init("right", "Right", kinds: [.text]),
                ]
            ),
            operation(
                "d.value.input",
                outputs: [.init("output", "Output", kinds: WorkflowDataKind.allCases)],
                fields: [.init("publicName", "Public name", .text(multiline: false), .text(""))]
            ),
            operation(
                "d.control.map",
                inputs: [
                    .init("input", "Input", kinds: [.list]),
                    .init("shared", "Shared", kinds: [.record], required: false),
                ],
                outputs: [.init("output", "Output", kinds: [.list])]
            ),
            operation(
                "d.control.loop",
                inputs: [
                    .init("input", "Input", kinds: [.number]),
                    .init("shared", "Shared", kinds: [.record], required: false),
                ],
                outputs: [
                    .init("output", "Output", kinds: [.number]),
                    .init("exitReason", "Exit reason", kinds: [.enumeration]),
                ]
            ),
            operation("d.control.invoke"),
        ])
    }

    func node(_ operationID: String, title: String) throws -> WorkflowNode {
        guard let operation = registry.operation(operationID) else { throw ScopeFixtureError.missingOperation }
        var node = operation.definition.makeNode()
        node.title = title
        return node
    }

    func diamond() throws -> DiamondFixture {
        let source = try node("fixture.source", title: "old-source")
        let left = try node("fixture.echo", title: "left")
        let right = try node("fixture.echo", title: "right")
        let sink = try node("fixture.join", title: "sink")
        let graph = WorkflowGraph(nodes: [sink, right, source, left], connections: [
            .init(sourceNode: source.id, targetNode: left.id),
            .init(sourceNode: source.id, targetNode: right.id),
            .init(sourceNode: left.id, targetNode: sink.id, targetPort: "left"),
            .init(sourceNode: right.id, targetNode: sink.id, targetPort: "right"),
        ])
        return .init(graph: graph, source: source, left: left, right: right, sink: sink)
    }

    func execute(
        graph: WorkflowGraph,
        selection: WorkflowGraphSelection,
        tools: [WorkflowToolDefinition] = []
    ) async throws -> WorkflowPlanCheckpoint {
        let plan = try WorkflowScopePlanner.rebuild(
            graph: graph, selection: selection, modelDefaults: [:], tools: tools, registry: registry
        )
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.modelDefaults = [:]
        return try await executor().execute(checkpoint)
    }

    func executor() -> WorkflowPlanExecutor {
        WorkflowPlanExecutor(registry: registry, executeCall: { context in
            switch context.node.operationID {
            case "fixture.source":
                return .outputs(["output": .data(.text(context.node.title))])
            case "fixture.new-source":
                return .outputs(["output": .data(.text("new-output"))])
            case "fixture.number-source":
                return .outputs(["output": .data(.number(1, unit: "s"))])
            case "fixture.number-sink":
                guard let input = context.inputs["input"] else { throw ScopeFixtureError.missingInput }
                return .outputs(["output": input])
            case "fixture.echo":
                guard let input = context.inputs["input"] else { throw ScopeFixtureError.missingInput }
                return .outputs(["output": input])
            case "fixture.join":
                guard let left = context.inputs["left"]?.datum?.text,
                      let right = context.inputs["right"]?.datum?.text else {
                    throw ScopeFixtureError.missingInput
                }
                return .outputs(["output": .data(.text(left + right))])
            case "d.value.input":
                guard let value = context.node.dataConfiguration?.value else {
                    throw ScopeFixtureError.missingInput
                }
                return .outputs(["output": .data(value)])
            default:
                throw ScopeFixtureError.unexpectedOperation
            }
        }, save: { _ in })
    }
}

private struct DiamondFixture {
    let graph: WorkflowGraph
    let source: WorkflowNode
    let left: WorkflowNode
    let right: WorkflowNode
    let sink: WorkflowNode
}

private enum ScopeFixtureError: Error {
    case missingOperation
    case missingInput
    case unexpectedOperation
}
