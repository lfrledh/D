import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow checkpoint validation r1") @MainActor
struct WorkflowCheckpointValidationTests {
    @Test func validatesRealCompilerAndExecutorSnapshots() async throws {
        let fixture = try Fixture()

        let simpleNode = try fixture.node("fixture.source", title: "simple")
        let simplePlan = try fixture.compiler.compile(.init(nodes: [simpleNode]))
        #expect(simplePlan.steps[0].sourceSignature != nil)
        let simpleRun = try await fixture.executeCapturing(simplePlan)
        try fixture.validateEverySnapshot(simpleRun, expected: simplePlan)

        var fallbackPlan = simplePlan
        fallbackPlan.steps[0].sourceSignature = nil
        let fallbackRun = try await fixture.executeCapturing(fallbackPlan)
        try fixture.validateEverySnapshot(fallbackRun, expected: fallbackPlan)

        let yes = try fixture.outputGraph(title: "yes", outputName: "output")
        let no = try fixture.outputGraph(title: "no", outputName: "output")
        var branchNode = try fixture.node("d.control.branch")
        branchNode.control = .branch(
            predicate: .init(comparison: .equals, value: .boolean(true)),
            then: yes,
            otherwise: no
        )
        let branchPlan = try fixture.compiler.compile(.init(nodes: [branchNode]))
        let branchRun = try await fixture.executeCapturing(
            branchPlan,
            externalInputs: [branchNode.id: ["input": .data(.boolean(true))]]
        )
        try fixture.validateEverySnapshot(branchRun, expected: branchPlan)

        let mapBody = try fixture.outputGraph(title: "map-body", outputName: "output")
        var mapNode = try fixture.node("d.control.map")
        mapNode.control = .map(body: mapBody, continueOnFailure: false)
        let mapPlan = try fixture.compiler.compile(.init(nodes: [mapNode]))
        let mapInput = WorkflowDatum.list(element: .text, items: [
            .init(id: "one", value: .text("a")),
            .init(id: "two", value: .text("b")),
        ])
        let mapRun = try await fixture.executeCapturing(
            mapPlan,
            externalInputs: [mapNode.id: ["input": .data(mapInput)]]
        )
        try fixture.validateEverySnapshot(mapRun, expected: mapPlan)

        let emptyMapRun = try await fixture.executeCapturing(
            mapPlan,
            externalInputs: [mapNode.id: [
                "input": .data(.list(element: .text, items: [])),
            ]]
        )
        try fixture.validateEverySnapshot(emptyMapRun, expected: mapPlan)

        mapNode.control = .map(body: mapBody, continueOnFailure: true)
        let continuingMapPlan = try fixture.compiler.compile(.init(nodes: [mapNode]))
        let continuingMapRun = try await fixture.executeCapturing(
            continuingMapPlan,
            externalInputs: [mapNode.id: ["input": .data(mapInput)]],
            failingItemID: "two"
        )
        try fixture.validateEverySnapshot(continuingMapRun, expected: continuingMapPlan)

        let loopBody = try fixture.outputGraph(title: "loop-body", outputName: "state")
        var loopNode = try fixture.node("d.control.loop")
        loopNode.control = .loop(
            body: loopBody,
            stateSchema: .number(unit: nil),
            maximumIterations: 3,
            until: .init(comparison: .equals, value: .number(2, unit: nil))
        )
        let loopPlan = try fixture.compiler.compile(.init(nodes: [loopNode]))
        let loopRun = try await fixture.executeCapturing(
            loopPlan,
            externalInputs: [loopNode.id: ["input": .data(.number(0, unit: nil))]]
        )
        try fixture.validateEverySnapshot(loopRun, expected: loopPlan)

        let zeroIterationLoopRun = try await fixture.executeCapturing(
            loopPlan,
            externalInputs: [loopNode.id: ["input": .data(.number(2, unit: nil))]]
        )
        try fixture.validateEverySnapshot(zeroIterationLoopRun, expected: loopPlan)

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
        let invokeRun = try await fixture.executeCapturing(invokePlan)
        try fixture.validateEverySnapshot(invokeRun, expected: invokePlan)

        var humanNode = try fixture.node("d.control.human")
        humanNode.dataConfiguration = .init(schema: .boolean)
        let humanPlan = try fixture.compiler.compile(.init(nodes: [humanNode]))
        let humanRun = try await fixture.executeCapturing(
            humanPlan,
            externalInputs: [humanNode.id: ["input": .data(.text("review material"))]]
        )
        let human = humanRun.final
        #expect(human.state == .waiting)
        try fixture.validateEverySnapshot(humanRun, expected: humanPlan)
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

    @Test func rejectsCompletedControlsWithoutConcreteChildEvidence() async throws {
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
        var branch = try await fixture.execute(
            branchPlan,
            externalInputs: [branchNode.id: ["input": .data(.boolean(true))]]
        )
        branch.records.removeAll { record in
            record.address.path.contains { if case .branch = $0 { true } else { false } }
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(branch, expected: branchPlan, registry: fixture.registry)
        }

        let mapBody = try fixture.outputGraph(title: "map-body", outputName: "output")
        var mapNode = try fixture.node("d.control.map")
        mapNode.control = .map(body: mapBody, continueOnFailure: false)
        let mapPlan = try fixture.compiler.compile(.init(nodes: [mapNode]))
        let list = WorkflowDatum.list(element: .text, items: [
            .init(id: "one", value: .text("a")),
            .init(id: "two", value: .text("b")),
        ])
        var map = try await fixture.execute(
            mapPlan,
            externalInputs: [mapNode.id: ["input": .data(list)]]
        )
        map.records.removeAll { record in
            record.address.path.contains { if case .item("one") = $0 { true } else { false } }
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(map, expected: mapPlan, registry: fixture.registry)
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
        var loop = try await fixture.execute(
            loopPlan,
            externalInputs: [loopNode.id: ["input": .data(.number(0, unit: nil))]]
        )
        loop.records.removeAll { record in
            record.address.path.contains { if case .iteration = $0 { true } else { false } }
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(loop, expected: loopPlan, registry: fixture.registry)
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
        var invoke = try await fixture.execute(invokePlan)
        invoke.records.removeAll { record in
            record.address.path.contains { if case .tool = $0 { true } else { false } }
        }
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(invoke, expected: invokePlan, registry: fixture.registry)
        }
    }

    @Test func validatesPublicInputSubstitutionAndRejectsHumanMutations() async throws {
        let fixture = try Fixture()
        var input = try fixture.node("d.value.input")
        input.parameters["publicName"] = .text("value")
        input.dataConfiguration = .init(value: .text("template fallback"))
        var graph = WorkflowGraph(nodes: [input])
        graph.interface = .init(
            inputs: [.init("value", .number(unit: nil))]
        )
        let plan = try fixture.compiler.compile(graph)
        let checkpoint = try await fixture.execute(plan, arguments: ["value": .number(9, unit: nil)])
        try WorkflowCheckpointValidation.validate(checkpoint, expected: plan, registry: fixture.registry)
        #expect(checkpoint.records.first?.step.node.dataConfiguration?.value == .number(9, unit: nil))

        var forgedProjection = checkpoint
        forgedProjection.records[0].step.outputs = ["output": .data(.number(10, unit: nil))]
        forgedProjection.outputs = ["output": .data(.number(10, unit: nil))]
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(forgedProjection, expected: plan, registry: fixture.registry)
        }

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

    @Test func decisionsPreviewsRawFailuresAndSavingStatesMatchExecutorEvidence() async throws {
        let fixture = try Fixture()

        var humanNode = try fixture.node("d.control.human")
        humanNode.dataConfiguration = .init(schema: .boolean)
        let humanPlan = try fixture.compiler.compile(.init(nodes: [humanNode]))
        var humanSaved: [WorkflowPlanCheckpoint] = []
        let humanExecutor = WorkflowPlanExecutor(registry: fixture.registry, executeCall: { context in
            .humanTask(.init(
                id: context.stepID,
                kind: .approve,
                title: "Approve",
                materials: try #require(context.inputs["input"]?.datum),
                resultSchema: .boolean
            ))
        }, save: { humanSaved.append($0) })
        var humanInitial = WorkflowPlanCheckpoint(plan: humanPlan)
        humanInitial.externalInputs[humanNode.id] = ["input": .data(.text("review"))]
        var humanWaiting = try await humanExecutor.execute(humanInitial)
        humanWaiting.records[0].step.humanTask?.decision = .boolean(false)
        let humanCompleted = try await humanExecutor.execute(humanWaiting)
        for checkpoint in humanSaved + [humanCompleted] {
            try WorkflowCheckpointValidation.validate(checkpoint, expected: humanPlan, registry: fixture.registry)
        }
        var forgedHuman = humanCompleted
        forgedHuman.records[0].step.outputs = ["output": .data(.boolean(true))]
        forgedHuman.outputs = ["output": .data(.boolean(true))]
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(forgedHuman, expected: humanPlan, registry: fixture.registry)
        }

        let reviewNode = try fixture.node("fixture.review.text")
        let reviewPlan = try fixture.compiler.compile(.init(nodes: [reviewNode]))
        let acceptedReference = fixture.asset(kind: .text, byte: "c")
        let forgedReference = fixture.asset(kind: .text, byte: "d")
        var reviewSaved: [WorkflowPlanCheckpoint] = []
        let reviewExecutor = WorkflowPlanExecutor(registry: fixture.registry, executeCall: { _ in
            .reviewText(acceptedReference)
        }, save: { reviewSaved.append($0) })
        var reviewWaiting = try await reviewExecutor.execute(.init(plan: reviewPlan))
        let reviewStepID = try #require(reviewWaiting.records.first?.step.id)
        reviewWaiting.records[0].step.decision = .init(
            waitingStepID: reviewStepID,
            accepted: true,
            output: acceptedReference
        )
        let reviewCompleted = try await reviewExecutor.execute(reviewWaiting)
        for checkpoint in reviewSaved + [reviewCompleted] {
            try WorkflowCheckpointValidation.validate(checkpoint, expected: reviewPlan, registry: fixture.registry)
        }
        var forgedReview = reviewCompleted
        forgedReview.records[0].step.outputs = ["output": .asset(forgedReference)]
        forgedReview.outputs = ["output": .asset(forgedReference)]
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(forgedReview, expected: reviewPlan, registry: fixture.registry)
        }

        let rejectedReference = fixture.asset(kind: .text, byte: "e")
        var rejectedSaved: [WorkflowPlanCheckpoint] = []
        let rejectedExecutor = WorkflowPlanExecutor(registry: fixture.registry, executeCall: { _ in
            .reviewText(rejectedReference)
        }, save: { rejectedSaved.append($0) })
        var rejected = try await rejectedExecutor.execute(.init(plan: reviewPlan))
        let rejectedStepID = try #require(rejected.records.first?.step.id)
        rejected.records[0].step.decision = .init(waitingStepID: rejectedStepID, accepted: false)
        let rejectedFinal = try await rejectedExecutor.execute(rejected)
        #expect(rejectedFinal.records[0].step.status == .rejected)
        #expect(rejectedFinal.records[0].step.outputs["preview"] == .asset(rejectedReference))
        for checkpoint in rejectedSaved + [rejectedFinal] {
            try WorkflowCheckpointValidation.validate(checkpoint, expected: reviewPlan, registry: fixture.registry)
        }

        let chooseNode = try fixture.node("fixture.review.choose")
        let choosePlan = try fixture.compiler.compile(.init(nodes: [chooseNode]))
        let image = fixture.asset(kind: .image, byte: "1")
        let candidate = WorkflowCandidate(asset: image, seed: "7")
        var chooseSaved: [WorkflowPlanCheckpoint] = []
        let chooseExecutor = WorkflowPlanExecutor(registry: fixture.registry, executeCall: { _ in
            .choose([candidate])
        }, save: { chooseSaved.append($0) })
        var chooseRejected = try await chooseExecutor.execute(.init(plan: choosePlan))
        let chooseStepID = try #require(chooseRejected.records.first?.step.id)
        chooseRejected.records[0].step.decision = .init(waitingStepID: chooseStepID, accepted: false)
        let chooseFinal = try await chooseExecutor.execute(chooseRejected)
        #expect(chooseFinal.records[0].step.outputs["preview"] == .collection([candidate]))
        for checkpoint in chooseSaved + [chooseFinal] {
            try WorkflowCheckpointValidation.validate(checkpoint, expected: choosePlan, registry: fixture.registry)
        }

        var cachedSaved: [WorkflowPlanCheckpoint] = []
        let cachedExecutor = WorkflowPlanExecutor(registry: fixture.registry, executeCall: { _ in
            .outputs(["output": .asset(acceptedReference)])
        }, save: { cachedSaved.append($0) })
        let cached = try await cachedExecutor.execute(.init(plan: reviewPlan))
        #expect(cached.records[0].step.decision == nil)
        for checkpoint in cachedSaved + [cached] {
            try WorkflowCheckpointValidation.validate(checkpoint, expected: reviewPlan, registry: fixture.registry)
        }

        let previewSource = try fixture.node("fixture.source")
        let previewPlan = try fixture.compiler.compile(.init(nodes: [previewSource]))
        var forgedPreview = try await fixture.execute(previewPlan)
        forgedPreview.state = .waiting
        forgedPreview.outputs = [:]
        forgedPreview.records[0].step.status = .waiting
        forgedPreview.records[0].step.outputs = ["preview": .asset(acceptedReference)]
        #expect(throws: WorkflowIssue.self) {
            try WorkflowCheckpointValidation.validate(
                forgedPreview,
                expected: previewPlan,
                registry: fixture.registry
            )
        }

        let languageNode = try fixture.node("fixture.language")
        let languagePlan = try fixture.compiler.compile(.init(nodes: [languageNode]))
        let raw = fixture.asset(kind: .text, byte: "f")
        var languageSaved: [WorkflowPlanCheckpoint] = []
        let languageExecutor = WorkflowPlanExecutor(registry: fixture.registry, executeCall: { _ in
            throw WorkflowOutputValidationFailure(raw: raw, reason: "fixture invalid structured output")
        }, save: { languageSaved.append($0) })
        do {
            _ = try await languageExecutor.execute(.init(plan: languagePlan))
            Issue.record("Expected structured-output failure")
        } catch is WorkflowOutputValidationFailure {}
        let failedLanguage = try #require(languageExecutor.checkpoint)
        for checkpoint in languageSaved + [failedLanguage] {
            try WorkflowCheckpointValidation.validate(checkpoint, expected: languagePlan, registry: fixture.registry)
        }
        #expect(failedLanguage.records[0].step.outputs["raw"] == .asset(raw))

        let source = try fixture.node("fixture.source")
        let savingPlan = try fixture.compiler.compile(.init(nodes: [source]))
        var pausedSaved: [WorkflowPlanCheckpoint] = []
        var pausedExecutor: WorkflowPlanExecutor!
        pausedExecutor = WorkflowPlanExecutor(registry: fixture.registry, executeCall: { _ in
            pausedExecutor.requestPause()
            return .outputs(["output": .data(.number(1, unit: nil))])
        }, save: { pausedSaved.append($0) })
        let paused = try await pausedExecutor.execute(.init(plan: savingPlan))
        #expect(paused.state == .paused)
        for checkpoint in pausedSaved + [paused] {
            try WorkflowCheckpointValidation.validate(checkpoint, expected: savingPlan, registry: fixture.registry)
        }

        var failSave = false
        var savingCallbacks: [WorkflowPlanCheckpoint] = []
        let savingExecutor = WorkflowPlanExecutor(registry: fixture.registry, executeCall: { _ in
            failSave = true
            return .outputs(["output": .data(.number(1, unit: nil))])
        }, save: { checkpoint in
            savingCallbacks.append(checkpoint)
            if failSave { throw WorkflowSaveFailure(reason: "fixture save failure") }
        })
        do {
            _ = try await savingExecutor.execute(.init(plan: savingPlan))
            Issue.record("Expected save failure")
        } catch is WorkflowSaveFailure {}
        let saving = try #require(savingExecutor.checkpoint)
        #expect(saving.state == .saving)
        for checkpoint in savingCallbacks + [saving] {
            try WorkflowCheckpointValidation.validate(checkpoint, expected: savingPlan, registry: fixture.registry)
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
            fields: [WorkflowFieldDefinition] = [],
            interaction: WorkflowInteraction = .none
        ) -> WorkflowOperation {
            WorkflowOperation(
                definition: .init(
                    id: id,
                    title: id,
                    detail: "checkpoint fixture",
                    inputs: inputs,
                    outputs: outputs,
                    fields: fields,
                    interaction: interaction
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
            operation(
                "fixture.review.text",
                outputs: [.init("output", "Output", kinds: [.text])],
                interaction: .textReview
            ),
            operation(
                "fixture.review.choose",
                outputs: [.init("output", "Output", kinds: [.image])],
                interaction: .candidateReview
            ),
            operation(
                "fixture.language",
                outputs: [
                    .init("output", "Output", kinds: all),
                    .init("raw", "Raw", kinds: [.text]),
                ]
            ),
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
        let captured = try await executeCapturing(
            plan,
            arguments: arguments,
            externalInputs: externalInputs
        )
        return captured.final
    }

    func executeCapturing(
        _ plan: WorkflowPlan,
        arguments: [String: WorkflowDatum] = [:],
        externalInputs: [UUID: [String: WorkflowValue]] = [:],
        failingItemID: String? = nil
    ) async throws -> CapturedExecution {
        var saved: [WorkflowPlanCheckpoint] = []
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            switch context.node.operationID {
            case "fixture.source":
                let itemID = context.address?.path.compactMap { component -> String? in
                    if case .item(let value) = component { return value }
                    return nil
                }.last
                if itemID == failingItemID { throw FixtureFailure.mapItem }
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
        }, save: { saved.append($0) })
        var checkpoint = WorkflowPlanCheckpoint(plan: plan, arguments: arguments)
        checkpoint.externalInputs = externalInputs
        let final = try await executor.execute(checkpoint)
        return .init(final: final, saved: saved)
    }

    func validateEverySnapshot(
        _ execution: CapturedExecution,
        expected: WorkflowPlan
    ) throws {
        for checkpoint in execution.saved + [execution.final] {
            try WorkflowCheckpointValidation.validate(
                checkpoint,
                expected: expected,
                registry: registry
            )
        }
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

private struct CapturedExecution {
    let final: WorkflowPlanCheckpoint
    let saved: [WorkflowPlanCheckpoint]
}

private enum FixtureFailure: Error {
    case missingOperation
    case missingInput
    case unexpectedOperation
    case mapItem
}
