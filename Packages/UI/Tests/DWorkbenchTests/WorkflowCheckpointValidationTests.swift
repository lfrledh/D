import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow checkpoint validation r1") @MainActor
struct WorkflowCheckpointValidationTests {
    @Test func validatesRealCompilerAndExecutorSnapshots() async throws {
        let fixture = try Fixture()

        let simpleNode = try fixture.node("fixture.source", title: "simple")
        let simplePlan = try fixture.compiler.compile(.init(nodes: [simpleNode]))
        let simple = try await fixture.execute(simplePlan)
        try WorkflowCheckpointValidation.validate(simple, expected: simplePlan, registry: fixture.registry)

        let yes = try fixture.outputGraph(title: "yes", outputName: "output")
        let no = try fixture.outputGraph(title: "no", outputName: "output")
        var branchNode = try fixture.node("d.control.branch")
        branchNode.control = .branch(
            predicate: .init(comparison: .equals, value: .boolean(true)),
            then: yes,
            otherwise: no
        )
        let branchPlan = try fixture.compiler.compile(.init(nodes: [branchNode]))
        let branch = try await fixture.execute(
            branchPlan,
            externalInputs: [branchNode.id: ["input": .data(.boolean(true))]]
        )
        try WorkflowCheckpointValidation.validate(branch, expected: branchPlan, registry: fixture.registry)

        let mapBody = try fixture.outputGraph(title: "map-body", outputName: "output")
        var mapNode = try fixture.node("d.control.map")
        mapNode.control = .map(body: mapBody, continueOnFailure: false)
        let mapPlan = try fixture.compiler.compile(.init(nodes: [mapNode]))
        let mapInput = WorkflowDatum.list(element: .text, items: [
            .init(id: "one", value: .text("a")),
            .init(id: "two", value: .text("b")),
        ])
        let map = try await fixture.execute(
            mapPlan,
            externalInputs: [mapNode.id: ["input": .data(mapInput)]]
        )
        try WorkflowCheckpointValidation.validate(map, expected: mapPlan, registry: fixture.registry)

        let loopBody = try fixture.outputGraph(title: "loop-body", outputName: "state")
        var loopNode = try fixture.node("d.control.loop")
        loopNode.control = .loop(
            body: loopBody,
            stateSchema: .number(unit: nil),
            maximumIterations: 3,
            until: .init(comparison: .equals, value: .number(2, unit: nil))
        )
        let loopPlan = try fixture.compiler.compile(.init(nodes: [loopNode]))
        let loop = try await fixture.execute(
            loopPlan,
            externalInputs: [loopNode.id: ["input": .data(.number(0, unit: nil))]]
        )
        try WorkflowCheckpointValidation.validate(loop, expected: loopPlan, registry: fixture.registry)

        let toolGraph = try fixture.outputGraph(title: "tool-body", outputName: "answer")
        let tool = WorkflowToolDefinition(name: "fixture-tool", graph: toolGraph)
        let reference = WorkflowToolReference(
            id: tool.id,
            version: tool.version,
            digest: try WorkflowPlanCompiler.digest(tool)
        )
        var invokeNode = try fixture.node("d.control.invoke")
        invokeNode.control = .invoke(reference)
        invokeNode.dataConfiguration = .init(fields: toolGraph.interface?.inputs ?? [])
        let invokePlan = try fixture.compiler.compile(.init(nodes: [invokeNode]), tools: [tool])
        let invoke = try await fixture.execute(invokePlan)
        try WorkflowCheckpointValidation.validate(invoke, expected: invokePlan, registry: fixture.registry)

        var humanNode = try fixture.node("d.control.human")
        humanNode.dataConfiguration = .init(schema: .boolean)
        let humanPlan = try fixture.compiler.compile(.init(nodes: [humanNode]))
        let human = try await fixture.execute(
            humanPlan,
            externalInputs: [humanNode.id: ["input": .data(.text("review material"))]]
        )
        #expect(human.state == .waiting)
        try WorkflowCheckpointValidation.validate(human, expected: humanPlan, registry: fixture.registry)
    }

    @Test func rejectsIdentityRecordAndBoundaryMutations() async throws {
        let fixture = try Fixture()
        let source = try fixture.node("fixture.source")
        let sink = try fixture.node("fixture.echo")
        let graph = WorkflowGraph(nodes: [source, sink], connections: [
            .init(sourceNode: source.id, targetNode: sink.id),
        ])
        let plan = try fixture.compiler.compile(graph)
        let completed = try await fixture.execute(plan)
        try WorkflowCheckpointValidation.validate(completed, expected: plan, registry: fixture.registry)

        var wrongRun = completed
        wrongRun.records[0].address.runID = UUID()
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(wrongRun, expected: plan, registry: fixture.registry)
        }

        var wrongPlan = completed
        wrongPlan.plan.graphRevision = UUID()
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(wrongPlan, expected: plan, registry: fixture.registry)
        }

        var duplicateAddress = completed
        duplicateAddress.records[1].address = duplicateAddress.records[0].address
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(duplicateAddress, expected: plan, registry: fixture.registry)
        }

        var duplicateStepID = completed
        duplicateStepID.records[1].step.id = duplicateStepID.records[0].step.id
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(duplicateStepID, expected: plan, registry: fixture.registry)
        }

        var replacedNode = completed
        replacedNode.records[0].step.node.title = "substituted"
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(replacedNode, expected: plan, registry: fixture.registry)
        }

        var wrongParameters = completed
        wrongParameters.records[0].step.node.parameters["unexpected"] = .flag(true)
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(wrongParameters, expected: plan, registry: fixture.registry)
        }

        var externalOverride = completed
        externalOverride.externalInputs[sink.id] = ["input": .data(.number(99, unit: nil))]
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(externalOverride, expected: plan, registry: fixture.registry)
        }

        var invalidDatum = completed
        invalidDatum.records[0].step.outputs["output"] = .data(.number(.nan, unit: nil))
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(invalidDatum, expected: plan, registry: fixture.registry)
        }

        var duplicateInterface = completed
        duplicateInterface.plan.interface.outputs = [
            .init(name: "same", nodeID: sink.id, schema: .number(unit: nil)),
            .init(name: "same", nodeID: sink.id, schema: .number(unit: nil)),
        ]
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(
                duplicateInterface,
                expected: duplicateInterface.plan,
                registry: fixture.registry
            )
        }
    }

    @Test func rejectsImpossibleControlAddressesAndToolDigest() async throws {
        let fixture = try Fixture()

        let yes = try fixture.outputGraph(title: "yes", outputName: "output")
        let no = try fixture.outputGraph(title: "no", outputName: "output")
        var branchNode = try fixture.node("d.control.branch")
        branchNode.control = .branch(
            predicate: .init(comparison: .equals, value: .boolean(true)),
            then: yes,
            otherwise: no
        )
        let branchPlan = try fixture.compiler.compile(.init(nodes: [branchNode]))
        let branch = try await fixture.execute(
            branchPlan,
            externalInputs: [branchNode.id: ["input": .data(.boolean(true))]]
        )
        var wrongBranch = branch
        let branchIndex = try #require(wrongBranch.records.firstIndex(where: {
            $0.address.path.contains { if case .branch = $0 { true } else { false } }
        }))
        wrongBranch.records[branchIndex].address.path = wrongBranch.records[branchIndex].address.path.map {
            if case .branch = $0 { return .branch(false) }
            return $0
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(wrongBranch, expected: branchPlan, registry: fixture.registry)
        }

        let mapBody = try fixture.outputGraph(title: "map-body", outputName: "output")
        var mapNode = try fixture.node("d.control.map")
        mapNode.control = .map(body: mapBody, continueOnFailure: false)
        let mapPlan = try fixture.compiler.compile(.init(nodes: [mapNode]))
        let mapInput = WorkflowDatum.list(element: .text, items: [.init(id: "actual", value: .text("a"))])
        let map = try await fixture.execute(
            mapPlan,
            externalInputs: [mapNode.id: ["input": .data(mapInput)]]
        )
        var wrongItem = map
        let itemIndex = try #require(wrongItem.records.firstIndex(where: {
            $0.address.path.contains { if case .item = $0 { true } else { false } }
        }))
        wrongItem.records[itemIndex].address.path = wrongItem.records[itemIndex].address.path.map {
            if case .item = $0 { return .item("unknown") }
            return $0
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(wrongItem, expected: mapPlan, registry: fixture.registry)
        }

        let loopBody = try fixture.outputGraph(title: "loop-body", outputName: "state")
        var loopNode = try fixture.node("d.control.loop")
        loopNode.control = .loop(
            body: loopBody,
            stateSchema: .number(unit: nil),
            maximumIterations: 3,
            until: .init(comparison: .equals, value: .number(2, unit: nil))
        )
        let loopPlan = try fixture.compiler.compile(.init(nodes: [loopNode]))
        let loop = try await fixture.execute(
            loopPlan,
            externalInputs: [loopNode.id: ["input": .data(.number(0, unit: nil))]]
        )
        var wrongIteration = loop
        let iterationIndex = try #require(wrongIteration.records.firstIndex(where: {
            $0.address.path.contains { if case .iteration = $0 { true } else { false } }
        }))
        wrongIteration.records[iterationIndex].address.path = wrongIteration.records[iterationIndex].address.path.map {
            if case .iteration = $0 { return .iteration(0) }
            return $0
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(wrongIteration, expected: loopPlan, registry: fixture.registry)
        }

        let toolGraph = try fixture.outputGraph(title: "tool-body", outputName: "answer")
        let tool = WorkflowToolDefinition(name: "fixture-tool", graph: toolGraph)
        let reference = WorkflowToolReference(
            id: tool.id,
            version: tool.version,
            digest: try WorkflowPlanCompiler.digest(tool)
        )
        var invokeNode = try fixture.node("d.control.invoke")
        invokeNode.control = .invoke(reference)
        invokeNode.dataConfiguration = .init(fields: toolGraph.interface?.inputs ?? [])
        let invokePlan = try fixture.compiler.compile(.init(nodes: [invokeNode]), tools: [tool])
        let invoke = try await fixture.execute(invokePlan)
        var wrongTool = invoke
        let toolIndex = try #require(wrongTool.records.firstIndex(where: {
            $0.address.path.contains { if case .tool = $0 { true } else { false } }
        }))
        let altered = WorkflowToolReference(id: reference.id, version: reference.version, digest: String(repeating: "0", count: 64))
        wrongTool.records[toolIndex].address.path = wrongTool.records[toolIndex].address.path.map {
            if case .tool = $0 { return .tool(altered) }
            return $0
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(wrongTool, expected: invokePlan, registry: fixture.registry)
        }
    }

    @Test func validatesPublicInputSubstitutionAndRejectsHumanMutations() async throws {
        let fixture = try Fixture()
        var input = try fixture.node("d.value.input")
        input.parameters["publicName"] = .text("value")
        input.dataConfiguration = .init(value: .number(1, unit: nil))
        var graph = WorkflowGraph(nodes: [input])
        graph.interface = .init(
            inputs: [.init("value", .number(unit: nil))],
            outputs: [.init(name: "output", nodeID: input.id, schema: .number(unit: nil))]
        )
        let plan = try fixture.compiler.compile(graph)
        let checkpoint = try await fixture.execute(plan, arguments: ["value": .number(9, unit: nil)])
        try WorkflowCheckpointValidation.validate(checkpoint, expected: plan, registry: fixture.registry)
        #expect(checkpoint.records.first?.step.node.dataConfiguration?.value == .number(9, unit: nil))

        var humanNode = try fixture.node("d.control.human")
        humanNode.dataConfiguration = .init(schema: .boolean)
        let humanPlan = try fixture.compiler.compile(.init(nodes: [humanNode]))
        let waiting = try await fixture.execute(
            humanPlan,
            externalInputs: [humanNode.id: ["input": .data(.text("review"))]]
        )

        var wrongTask = waiting
        wrongTask.records[0].step.humanTask?.id = UUID()
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(wrongTask, expected: humanPlan, registry: fixture.registry)
        }

        var wrongDecision = waiting
        wrongDecision.records[0].step.humanTask?.decision = .text("not a boolean")
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(wrongDecision, expected: humanPlan, registry: fixture.registry)
        }

        var rejectedAndDecided = waiting
        rejectedAndDecided.records[0].step.humanTask?.rejected = true
        rejectedAndDecided.records[0].step.humanTask?.decision = .boolean(false)
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(rejectedAndDecided, expected: humanPlan, registry: fixture.registry)
        }
    }

    @Test func collectsDeepAndMusicRecordAssetReferencesWithoutIO() throws {
        let fixture = try Fixture()
        let direct = fixture.asset(kind: .audio, byte: "a")
        let music = fixture.asset(kind: .pitch, byte: "b")
        var node = try fixture.node("fixture.source")
        node.assetReference = direct
        let plan = try fixture.compiler.compile(.init(nodes: [node]))

        let sourceFields: [WorkflowRecordField] = [
            .init("projectID", .text),
            .init("assetID", .text),
            .init("version", .text),
            .init("kind", .text),
            .init("sha256", .text),
        ]
        let sourceItem = WorkflowDatum.record(schema: sourceFields, fields: [
            "projectID": .text(music.projectID.uuidString),
            "assetID": .text(music.assetID.uuidString),
            "version": .text(music.version.uuidString),
            "kind": .text(music.kind.rawValue),
            "sha256": .text(music.sha256),
        ])
        let sourceList = WorkflowDatum.list(
            element: .record(sourceFields),
            items: [.init(id: "\(music.assetID.uuidString):\(music.version.uuidString)", value: sourceItem)]
        )
        let outerFields: [WorkflowRecordField] = [.init("sources", sourceList.schema)]
        let nestedMusic = WorkflowDatum.record(
            schema: outerFields,
            fields: ["sources": sourceList]
        )
        var checkpoint = WorkflowPlanCheckpoint(plan: plan, arguments: ["music": nestedMusic])
        checkpoint.outputs = ["output": .asset(direct)]

        let references = try WorkflowCheckpointValidation.assetReferences(in: checkpoint)
        #expect(Set(references) == Set([direct, music]))
    }
}

@MainActor private struct Fixture {
    let registry: WorkflowRegistry
    var compiler: WorkflowPlanCompiler { WorkflowPlanCompiler(registry: registry) }

    init() throws {
        let all = WorkflowDataKind.allCases
        func operation(
            _ id: String,
            inputs: [WorkflowPortDefinition] = [],
            outputs: [WorkflowPortDefinition] = [.init("output", "Output", kinds: WorkflowDataKind.allCases)],
            fields: [WorkflowFieldDefinition] = []
        ) -> WorkflowOperation {
            WorkflowOperation(
                definition: .init(
                    id: id,
                    title: id,
                    detail: "checkpoint fixture",
                    inputs: inputs,
                    outputs: outputs,
                    fields: fields
                ),
                execute: { _, _ in throw FixtureFailure.unexpectedOperation }
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
                    .init("exitReason", "Exit reason", kinds: [.enumeration]),
                ]
            )
        }
        registry = try WorkflowRegistry(operations: [
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

    func node(_ id: String, title: String? = nil) throws -> WorkflowNode {
        guard let operation = registry.operation(id) else { throw FixtureFailure.missingOperation }
        var result = operation.definition.makeNode()
        if let title { result.title = title }
        return result
    }

    func outputGraph(title: String, outputName: String) throws -> WorkflowGraph {
        let source = try node("fixture.source", title: title)
        var graph = WorkflowGraph(name: title, nodes: [source])
        graph.interface = .init(outputs: [
            .init(name: outputName, nodeID: source.id, schema: .number(unit: nil)),
        ])
        return graph
    }

    func execute(
        _ plan: WorkflowPlan,
        arguments: [String: WorkflowDatum] = [:],
        externalInputs: [UUID: [String: WorkflowValue]] = [:]
    ) async throws -> WorkflowPlanCheckpoint {
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            switch context.node.operationID {
            case "fixture.source":
                let iteration = context.address?.path.compactMap { component -> Int? in
                    if case .iteration(let value) = component { return value }
                    return nil
                }.last
                return .outputs(["output": .data(.number(Double(iteration ?? 7), unit: nil))])
            case "fixture.echo":
                guard let value = context.inputs["input"] else { throw FixtureFailure.missingInput }
                return .outputs(["output": value])
            case "d.value.input":
                guard let value = context.node.dataConfiguration?.value else { throw FixtureFailure.missingInput }
                return .outputs(["output": .data(value)])
            case "d.control.human":
                guard let material = context.inputs["input"]?.datum else { throw FixtureFailure.missingInput }
                return .humanTask(.init(
                    id: context.stepID,
                    kind: .approve,
                    title: "Approve",
                    materials: material,
                    resultSchema: context.node.dataConfiguration?.schema ?? .boolean
                ))
            default:
                throw FixtureFailure.unexpectedOperation
            }
        }, save: { _ in })
        var checkpoint = WorkflowPlanCheckpoint(plan: plan, arguments: arguments)
        checkpoint.externalInputs = externalInputs
        return try await executor.execute(checkpoint)
    }

    func asset(kind: WorkflowDataKind, byte: Character) -> WorkflowAssetReference {
        .init(
            projectID: UUID(),
            assetID: UUID(),
            version: UUID(),
            kind: kind,
            sha256: String(repeating: String(byte), count: 64)
        )
    }
}

private enum FixtureFailure: Error {
    case missingOperation
    case missingInput
    case unexpectedOperation
}
