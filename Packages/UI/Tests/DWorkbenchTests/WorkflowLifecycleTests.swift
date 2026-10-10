import CryptoKit
import DInference
import Foundation
import ImageIO
import CoreGraphics
import Testing
import UniformTypeIdentifiers
@testable import DWorkbench

private actor WorkflowSubmitGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var entered = false
    func wait() async { entered = true; if opened { return }; await withCheckedContinuation { waiting = $0 } }
    func open() { opened = true; waiting?.resume(); waiting = nil }
}
@MainActor private final class WorkflowSaveSwitch { var fails = true }

extension WorkflowLifecycleTests {
    @Test func groupMoveIsOneUndoAndDoesNotChangeRequestsOrAcceptStaleTargets() async throws {
        let (_, store, _, c) = try await fixture()
        c.addExample("text")
        let before = try #require(c.graph)
        let nodes = Array(before.nodes.prefix(2)); try #require(nodes.count == 2)
        let target = try #require(c.canvasInsertionTarget())
        let moves = nodes.enumerated().map { WorkflowLayout(nodeID: $0.element.id, x: Double($0.offset * 320 - 100), y: 500) }
        c.moveNodes(moves, target: target)
        let moved = try #require(c.graph)
        #expect(moved.revision == before.revision && moved.nodes == before.nodes && moved.connections == before.connections)
        #expect(moves.allSatisfy { moved.layout.contains($0) })
        c.undo(); #expect(c.graph == before)
        c.redo(); #expect(c.graph == moved)
        c.moveNodes([.init(nodeID: UUID(), x: 3, y: 4)], target: target)
        c.moveNodes([.init(nodeID: nodes[0].id, x: .nan, y: 4)], target: target)
        c.moveNodes([moves[0], moves[0]], target: target)
        #expect(c.graph == moved)
        c.externalOperationBusy = { true }; c.moveNodes([.init(nodeID: nodes[0].id, x: 0, y: 0)], target: target)
        #expect(c.graph == moved); c.externalOperationBusy = { false }
        c.setParameter(nodeID: nodes[0].id, key: "text", value: .text("changed"))
        let changed = c.graph
        c.moveNodes(moves, target: target); #expect(c.graph == changed)
        try await c.saveExplicitEdits()
        let archive = try #require(try await store.workflowState().archive)
        #expect(archive.graphs == c.graphs && archive.runs.isEmpty && archive.assets.isEmpty)
        try await c.close(); try await store.close()
    }

    @Test func cardDeletionUsesIdentityAndScopeAndIsOneUndo() async throws {
        let (_, store, _, c) = try await fixture()
        c.addExample("text")
        let inputID = try #require(c.graph?.nodes.first?.id)
        await c.run(target: inputID, only: false)
        try #require(c.errorMessage == nil && !c.runs.isEmpty && !c.availableAssets.isEmpty)
        let graph = try #require(c.graph)
        let first = try #require(graph.nodes.first)
        let other = try #require(graph.nodes.last)
        c.selectedNodeID = other.id
        c.selectedNodeIDs = [first.id, other.id]
        let target = try #require(c.canvasInsertionTarget())
        let assets = c.availableAssets, runs = c.runs
        #expect(c.deleteNode(id: first.id, target: target))
        #expect(c.selectedNodeID == other.id && c.selectedNodeIDs == [other.id])
        #expect(c.graph?.nodes.contains { $0.id == first.id } == false)
        #expect(c.graph?.connections.contains { $0.sourceNode == first.id || $0.targetNode == first.id } == false)
        #expect(c.graph?.layout.contains { $0.nodeID == first.id } == false)
        #expect(c.availableAssets == assets && c.runs == runs)
        c.undo()
        #expect(c.graph == graph)
        c.externalOperationBusy = { true }
        #expect(!c.deleteNode(id: first.id, target: target))
        #expect(c.graph == graph && c.selectedNodeID == other.id)
        c.externalOperationBusy = { false }
        c.setParameter(nodeID: first.id, key: "text", value: .text("changed"))
        let changed = c.graph
        #expect(!c.deleteNode(id: first.id, target: target))
        #expect(c.graph == changed)
        let fresh = try #require(c.canvasInsertionTarget())
        #expect(!c.deleteNode(id: UUID(), target: fresh))
        #expect(c.graph == changed)
        #expect(c.deleteNode(id: first.id, target: fresh))
        try await c.saveExplicitEdits()
        let archive = try #require(try await store.workflowState().archive)
        #expect(archive.graphs == c.graphs)
        #expect(archive.runs == runs)
    }

    @Test(arguments: [false, true], [false, true])
    func pinnedLegacyWaitingDecidesAfterReopenWithoutUsingCurrentInput(image: Bool, changeAfterWaiting: Bool) async throws {
        let (_, store, engine, c) = try await fixture()
        var input = try #require(WorkflowRegistry.standard.operation("d.text.input")).definition.makeNode()
        input.parameters["text"] = .text("A 原始 👩🏽‍🎨 e\u{301}")
        var generate = try #require(WorkflowRegistry.standard.operation("d.image.generate")).definition.makeNode()
        generate.parameters["count"] = .integer(1)
        let human = try #require(WorkflowRegistry.standard.operation(image ? "d.asset.choose" : "d.text.confirm")).definition.makeNode()
        let graph = WorkflowGraph(nodes: image ? [input, generate, human] : [input, human], connections: image ? [
            .init(sourceNode: input.id, targetNode: generate.id, targetPort: "prompt"),
            .init(sourceNode: generate.id, targetNode: human.id)
        ] : [.init(sourceNode: input.id, targetNode: human.id)])
        let initial = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: initial.revision)
        await c.load(); await c.run(target: image ? generate.id : input.id, only: false)
        try #require(c.errorMessage == nil)
        let source = try #require(c.runs.last)
        let call = try #require(source.planCheckpoint?.records.last)
        c.setParameter(nodeID: input.id, key: "text", value: .text("B current prompt"))
        let edited = try #require(c.graph)
        let pin = WorkflowHistoricalInput(destinationNodeID: human.id, destinationPort: "input",
            sourceCall: .init(address: call.address, stepID: call.id), sourcePort: "output")
        await c.runScoped(.only(human.id), pins: [pin], expectedGraphID: edited.id, expectedRevision: edited.revision)
        try #require(c.errorMessage == nil)
        let waiting = try #require(c.runs.last?.steps.first)
        try #require(waiting.status == .waiting)
        #expect(waiting.inputs["input"] == call.step.outputs["output"])
        let draft = "人工草稿 👩🏽‍🎨 e\u{301}"
        if !image { c.editReviewText(stepID: waiting.id, text: draft) }
        await c.save(); try await c.close(); try await store.close()

        let reopened = try await ProjectStore.open(at: store.rootURL)
        let session = WorkbenchSession(engine: engine, backendID: "fixture.image",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let services = WorkflowServices(store: reopened, session: session, resolveModel: { _, _ in
            throw WorkflowIssue("Deciding a historical wait must not resolve a model")
        })
        let recovered = WorkflowController(services: services); await recovered.load()
        #expect(recovered.runs.first == source)
        #expect(recovered.runs.last?.steps.first?.decision == nil)
        if !image { #expect(recovered.runs.last?.steps.first?.reviewTextDraft == draft) }
        let before = try #require(try await reopened.workflowState().archive)
        if changeAfterWaiting {
            // Both kinds of changes must invalidate the wait, even though its historical pin is valid.
            if image { recovered.disconnect(try #require(recovered.graph?.connections.last?.id)) }
            else { recovered.setParameter(nodeID: input.id, key: "text", value: .text("C changed after waiting")) }
        }
        let candidate = waiting.outputs["preview"]?.candidates.first
        await recovered.decide(stepID: waiting.id, accept: true, text: image ? nil : draft,
            candidateID: candidate?.id, acceptPartial: false)
        #expect(recovered.runs.first == source)
        #expect(await engine.requests.count == (image ? 1 : 0))
        #expect(recovered.runs.count == 2)
        if changeAfterWaiting {
            #expect(recovered.errorMessage?.contains("过期") == true)
            #expect(recovered.runs.last?.steps.first?.decision == nil)
            #expect(try await reopened.workflowState().archive?.assets == before.assets)
        } else {
            try #require(recovered.errorMessage == nil)
            let decided = try #require(recovered.runs.last?.steps.first)
            #expect(decided.status == .completed && decided.decision?.accepted == true)
            #expect(recovered.graph?.nodes.first?.parameters["text"] == .text("B current prompt"))
            if image { #expect(decided.outputs["output"]?.asset == candidate?.asset) }
            else { #expect(try await services.readText(try #require(decided.outputs["output"]?.asset)) == draft) }
            await recovered.decide(stepID: waiting.id, accept: true, text: "duplicate", candidateID: candidate?.id, acceptPartial: false)
            #expect(recovered.runs.last?.steps.first == decided)
        }
        try await recovered.close(); try await reopened.close()
    }

    @Test func retainedDerivativeDoesNotBlockOriginalFailedCallRetry() async throws {
        let (_, store, engine, c) = try await fixture()
        c.addExample("text")
        let target = try #require(c.graph?.nodes.first { $0.operationID == "d.text.rewrite" })
        await engine.configure(failure: .invalidRequest("controlled first failure"))
        await c.run(target: target.id, only: false)
        let original = try #require(c.runs.last)
        let call = try #require(original.planCheckpoint?.records.first { $0.step.node.id == target.id })
        try #require(call.step.status == .failed && call.step.inputsBound == true)
        await engine.configure()
        await c.rerunCall(.init(address: call.address, stepID: call.id))
        try #require(c.errorMessage == nil)
        let derivative = try #require(c.runs.last)
        await c.resume(runID: original.id)
        try #require(c.errorMessage == nil)
        #expect(c.runs.first?.status == .completed)
        #expect(c.runs.last == derivative)
        // Resume may reuse the now-successful matching derivative; it must not deadlock saving provenance.
        #expect(await engine.requests.count == 2)
        #expect(c.runs.first?.steps.last?.outputs == derivative.steps.first?.outputs)
        try await c.close(); try await store.close()
    }

    @Test(arguments: [false, true])
    func nestedAndDerivedHumanCallsCanDecideWithoutResumingOriginal(legacy: Bool) async throws {
        let (_, store, engine, c) = try await fixture()
        var input = try #require(WorkflowRegistry.standard.operation(legacy ? "d.text.input" : "d.value.input")).definition.makeNode()
        if legacy { input.parameters["text"] = .text("original") } else { input.dataConfiguration = .init(value: .text("original")) }
        let human = try #require(WorkflowRegistry.standard.operation(legacy ? "d.text.confirm" : "d.control.human")).definition.makeNode()
        var body = WorkflowGraph(nodes: [input, human], connections: [.init(sourceNode: input.id, targetNode: human.id)])
        body.interface = .init(outputs: [.init(name: "output", nodeID: human.id, schema: legacy ? .asset(.text) : .text)])
        let tool = WorkflowToolDefinition(name: "review tool", graph: body)
        var invoke = try #require(WorkflowRegistry.standard.operation("d.control.invoke")).definition.makeNode()
        invoke.control = .invoke(.init(id: tool.id, version: tool.version, digest: try WorkflowPlanCompiler.digest(tool)))
        let graph = WorkflowGraph(nodes: [invoke])
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: archive.revision, tools: [tool])
        await c.load(); await c.run(target: invoke.id, only: false)
        try #require(c.errorMessage == nil)
        let waiting = try #require(c.runs.last?.planCheckpoint?.records.first { $0.step.node.id == human.id })
        try #require(waiting.step.status == .waiting)
        if legacy {
            c.editReviewText(stepID: waiting.id, text: "approved")
            await c.decide(stepID: waiting.id, accept: true, text: "approved", candidateID: nil, acceptPartial: false)
        } else {
            await c.decideHuman(stepID: waiting.id, value: .text("approved"), expectedTask: try #require(waiting.step.humanTask))
        }
        try #require(c.errorMessage == nil)
        let original = try #require(c.runs.last)
        let completed = try #require(original.planCheckpoint?.records.first { $0.id == waiting.id })
        try #require(completed.step.status == .completed)
        await c.rerunCall(.init(address: completed.address, stepID: completed.id))
        try #require(c.errorMessage == nil)
        let derived = try #require(c.runs.last)
        let newWaiting = try #require(derived.steps.first)
        try #require(newWaiting.status == .waiting && newWaiting.id != waiting.id)
        if legacy {
            c.editReviewText(stepID: newWaiting.id, text: "new decision")
            await c.decide(stepID: newWaiting.id, accept: true, text: "new decision", candidateID: nil, acceptPartial: false)
        } else {
            await c.decideHuman(stepID: newWaiting.id, value: .text("new decision"), expectedTask: try #require(newWaiting.humanTask))
        }
        try #require(c.errorMessage == nil)
        await c.resume(runID: derived.id)
        try #require(c.errorMessage == nil)
        #expect(c.runs.last?.status == .completed && c.runs[0] == original)
        #expect(await engine.requests.isEmpty)
        try await c.close(); try await store.close()
    }

    @Test func explicitHistoricalScopeUsesChosenOldOutputAndSurvivesReopen() async throws {
        let (_, store, engine, c) = try await fixture()
        var input = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        input.dataConfiguration = .init(value: .text("原始 👩🏽‍🎨 e\u{301}"))
        let middle = try #require(WorkflowRegistry.standard.operation("d.value.return")).definition.makeNode()
        let end = try #require(WorkflowRegistry.standard.operation("d.value.return")).definition.makeNode()
        let graph = WorkflowGraph(nodes: [input, middle, end], connections: [
            .init(sourceNode: input.id, targetNode: middle.id), .init(sourceNode: middle.id, targetNode: end.id)])
        let initial = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: initial.revision)
        await c.load()
        await c.runScoped(.through(end.id), pins: [], expectedGraphID: graph.id, expectedRevision: graph.revision)
        try #require(c.errorMessage == nil)
        let old = try #require(c.runs.last)
        let call = try #require(old.planCheckpoint?.records.first { $0.step.node.id == middle.id })
        c.setDataConfiguration(nodeID: input.id, value: .init(value: .text("新内容")))
        let edited = try #require(c.graph)
        let pin = WorkflowHistoricalInput(destinationNodeID: end.id, destinationPort: "input",
            sourceCall: .init(address: call.address, stepID: call.step.id), sourcePort: "output")
        await c.runScoped(.only(end.id), pins: [pin], expectedGraphID: edited.id, expectedRevision: edited.revision)
        try #require(c.errorMessage == nil)
        let result = try #require(c.runs.last)
        #expect(result.steps.count == 1)
        #expect(result.steps[0].outputs["output"] == .data(.text("原始 👩🏽‍🎨 e\u{301}")))
        #expect(c.runs.first == old)
        #expect(c.graph == edited)
        #expect(await engine.requests.isEmpty)
        await c.runScoped(.only(end.id), pins: [pin], expectedGraphID: graph.id, expectedRevision: graph.revision)
        #expect(c.errorMessage != nil && c.runs.count == 2)
        let archive = try #require(try await store.workflowState().archive)
        var forged = result
        forged.steps = []; forged.status = .queued
        forged.planCheckpoint?.records = []; forged.planCheckpoint?.state = .ready
        forged.planCheckpoint?.outputs = [:]
        forged.planCheckpoint?.externalInputs[end.id] = ["input": .data(.text("forged"))]
        await #expect(throws: (any Error).self) {
            _ = try await store.saveWorkflow(graphs: archive.graphs, runs: [old, forged], expectedRevision: archive.revision)
        }
        #expect(try await store.workflowState().archive == archive)
        await #expect(throws: (any Error).self) {
            _ = try await store.saveWorkflow(graphs: archive.graphs, runs: [result], expectedRevision: archive.revision)
        }
        try await c.close(); let url = store.rootURL; try await store.close()
        let reopened = try await ProjectStore.open(at: url)
        #expect(try await reopened.workflowState().archive?.runs == archive.runs)
        try await reopened.close()
    }

    @Test func concreteMapCallCreatesIndependentHistoryWithoutChangingParent() async throws {
        let (_, store, engine, c) = try await fixture()
        c.addLanguageExample(.data)
        let target = try #require(c.graph?.nodes.first { $0.title == "返回数据结果" })
        await c.run(target: target.id, only: false)
        try #require(c.errorMessage == nil)
        let original = try #require(c.runs.last)
        let call = try #require(original.planCheckpoint?.records.first {
            $0.address.path.contains { if case .item = $0 { true } else { false } } && c.canRerunCall($0)
        })
        var fail = true
        c.beforeHistorySave = { if fail { throw WorkflowIssue("controlled derived history failure") } }
        await c.rerunCall(.init(address: call.address, stepID: call.step.id))
        try #require(c.hasPendingSaves)
        let pendingID = try #require(c.runs.last?.id)
        fail = false; await c.save(); await c.resume(runID: pendingID)
        try #require(c.errorMessage == nil)
        let derived = try #require(c.runs.last)
        #expect(c.runs.count == 2 && c.runs[0] == original)
        #expect(derived.id != original.id && derived.steps.count == 1)
        #expect(derived.steps[0].id != call.step.id)
        #expect(derived.steps[0].outputs == call.step.outputs)
        #expect(derived.scope?.originCall == .init(address: call.address, stepID: call.step.id))
        #expect(c.presentationRootGraphID(for: derived.id) == original.graph.id)
        c.selectedGraphID = nil
        #expect(c.revealRunForPresentation(derived.id))
        #expect(c.rootGraph?.id == original.graph.id && c.bodyPath.isEmpty)
        #expect(c.runs == [original, derived])
        #expect(c.presentationStep(nodeID: call.step.node.id, runID: derived.id)?.id == derived.steps[0].id)
        #expect(c.presentationStep(nodeID: call.step.node.id, runID: original.id)?.id == original.planCheckpoint?.records.last(where: { $0.step.node.id == call.step.node.id })?.step.id)
        #expect(await engine.requests.isEmpty)
        try await c.close(); let url = store.rootURL; try await store.close()
        let reopened = try await ProjectStore.open(at: url)
        #expect(try await reopened.workflowState().archive?.runs == [original, derived])
        try await reopened.close()
    }
}

private actor WorkflowFixtureEngine: InferenceEngine {
    let directory: URL
    var requests: [InferenceRequest] = []
    var failSecondImage = false
    var gate: WorkflowSubmitGate?
    var submitAction: (@MainActor @Sendable () async throws -> Void)?
    var terminalFailure: InferenceFailure?
    func configure(action: (@MainActor @Sendable () async throws -> Void)? = nil, failure: InferenceFailure? = nil) {
        submitAction = action; terminalFailure = failure
    }
    init(directory: URL) { self.directory = directory }
    func failSecond() { failSecondImage = true }
    func suspend(using gate: WorkflowSubmitGate) { self.gate = gate }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        try await submitAction?()
        if let terminalFailure {
            return InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { .failed(terminalFailure) })
        }
        if let gate { await gate.wait() }
        let result: InferenceResult
        let outputs: [InferenceOutput]
        switch request.input {
        case .text:
            outputs = [.textDelta("清晨的花园 👩🏽‍🎨 e\u{301}")]; result = .init(metadata: ["fixture":"CPU"])
        case .image(let input):
            let images = requests.filter { if case .image = $0.input { true } else { false } }
            if failSecondImage && images.count == 2 { throw WorkflowIssue("controlled candidate failure") }
            let folder = directory.appendingPathComponent(request.id.uuidString + "-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("image.png")
            try workflowFixturePNG(width: input.width, height: input.height).write(to: url)
            let artifact = ArtifactReference(url: url, mediaType: "image/png")
            outputs = [.artifact(artifact)]; result = .init(artifacts: [artifact], metadata: ["fixture":"CPU"])
        default: throw WorkflowIssue("fixture unsupported")
        }
        return InferenceRun(id: request.id, events: AsyncThrowingStream { c in outputs.forEach { c.yield($0) }; c.finish() },
                            cancel: {}, outcome: { .completed(result) })
    }
}
private func workflowFixturePNG(width: Int = 16, height: Int = 12) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5)); context.fill(.init(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage()); let data = NSMutableData()
    let target = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(target, image, nil); #expect(CGImageDestinationFinalize(target)); return data as Data
}

@Suite("M0 workflow durable lifecycle", .serialized) @MainActor
struct WorkflowLifecycleTests {
    @Test func extractedTextAssetsExecuteAndPersistWithoutChangingOldTools() async throws {
        let (_, store, engine, controller) = try await fixture()
        var results: [(WorkflowAssetReference, String)] = []
        for (index, text) in ["", "原件 e\u{301} 👩🏽‍🎨"].enumerated() {
            let oldTools = controller.tools
            controller.addBlankGraph(name: "Text boundary \(index)")
            controller.addNode(operationID: "d.text.input")
            let input = try #require(controller.selectedNode)
            controller.setParameter(nodeID: input.id, key: "text", value: .text(text))
            let graph = try #require(controller.graph)
            let schema = try #require(WorkflowToolEditing.outputSchemaProposal(for: input, port: "output", registry: controller.registry, tools: controller.tools))
            #expect(schema == .asset(.text))
            controller.selectedNodeIDs = [input.id]
            controller.extractSelection(name: "Asset tool \(index)", inputs: [],
                outputs: [.init(name: "answer", nodeID: input.id, schema: schema)],
                expectedGraphID: graph.id, expectedRevision: graph.revision)
            #expect(controller.errorMessage == nil)
            let invocation = try #require(controller.selectedNodeID)
            await controller.run(target: invocation, only: false)
            let run = try #require(controller.runs.last)
            #expect(run.status == .completed)
            let asset = try #require(run.steps.first { $0.node.id == invocation }?.outputs["answer"]?.asset)
            #expect(try await controller.services.readText(asset) == text)
            results.append((asset, text))
            #expect(Array(controller.tools.prefix(oldTools.count)) == oldTools)
            try await controller.saveExplicitEdits()
        }
        let savedTools = controller.tools, savedRuns = controller.runs
        try await controller.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let archive = try #require(try await reopened.workflowState().archive)
        #expect(archive.tools == savedTools)
        #expect(archive.runs == savedRuns)
        for (asset, text) in results { #expect(try await reopened.workflowText(asset) == text) }
        #expect(await engine.requests.isEmpty)
        try await reopened.close()
    }

    @Test func controllerExtractionPersistsBoundaryMappingsAcrossStoreReopen() async throws {
        let (_, store, engine, controller) = try await fixture()
        controller.addBlankGraph(name: "Boundary fixture")
        controller.addNode(operationID: "d.value.input")
        let input = try #require(controller.selectedNode)
        controller.setDataConfiguration(nodeID: input.id, value: .init(value: .text("原件 e\u{301} 👩🏽‍🎨")))
        controller.addNode(operationID: "d.value.return")
        let middle = try #require(controller.selectedNode)
        controller.addNode(operationID: "d.value.return")
        let output = try #require(controller.selectedNode)
        controller.connect(source: input.id, sourcePort: "output", target: middle.id, targetPort: "input")
        controller.connect(source: middle.id, sourcePort: "output", target: output.id, targetPort: "input")
        try await controller.saveExplicitEdits()
        let original = try #require(controller.graph)
        let oldPointer = try #require(await store.snapshot().workflowSnapshot)
        let oldFile = store.rootURL.appendingPathComponent(oldPointer.relativePath)
        let originalBytes = try Data(contentsOf: oldFile)
        controller.selectedNodeIDs = [middle.id]
        controller.extractSelection(name: "Round trip tool", inputs: [.init(name: "content", schema: .text,
            sourceNode: input.id, sourcePort: "output")], outputs: [.init(name: "answer", nodeID: middle.id, schema: .text)],
            expectedGraphID: original.id, expectedRevision: original.revision)
        #expect(controller.errorMessage == nil)
        let extracted = try #require(controller.graph), tool = try #require(controller.tools.last)
        let invocation = try #require(controller.selectedNodeID)
        try await controller.saveExplicitEdits()
        try await controller.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let archive = try #require(try await reopened.workflowState().archive)
        #expect(archive.graphs.first { $0.id == extracted.id } == extracted)
        #expect(archive.tools?.last == tool)
        #expect(tool.graph.nodes.contains { $0.id == middle.id && $0.parameters == middle.parameters })
        let plan = try WorkflowPlanCompiler().compile(extracted, tools: archive.tools ?? [], target: output.id)
        guard case .invoke(let reference, let body) = plan.steps.first(where: { $0.id == invocation })?.kind else {
            Issue.record("Reopened invocation not compiled"); try await reopened.close(); return
        }
        #expect(reference.digest == (try WorkflowPlanCompiler.digest(tool)))
        #expect(body.interface.inputs.map(\.name) == ["content"])
        #expect(body.interface.outputs.map(\.name) == ["answer"])
        #expect(try Data(contentsOf: oldFile) == originalBytes)
        #expect(await engine.requests.isEmpty)
        try await reopened.close()
    }

    @Test func devLoadingChoiceReachesEngineFromQuickAndCanvasAndReopens() async throws {
        let (root, store, engine, original) = try await fixture()
        try await original.close() // Retire the empty fixture owner before a new Canvas owns this Store.
        let session = WorkbenchSession(engine: engine, backendID: "fixture.dev",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        func services(for owner: ProjectStore) -> WorkflowServices {
            WorkflowServices(store: owner, session: session, resolveModel: { kind, identity in
                #expect(kind == .image && identity == "image:dev")
                return .init(identity: identity, reference: .init(directory: root, revision: "dev-fixture"),
                    backendID: "fixture.dev", operationID: WorkflowModelRoutes.fluxDev,
                    imageRecipe: .fluxDev(capability: .flux2Dev))
            })
        }
        let quick = QuickGenerationController(store: store) { services(for: store) }
        await quick.load(); quick.select(operationID: WorkflowModelRoutes.fluxDev, modelID: "image:dev")
        let draftID = try #require(quick.draft?.id)
        let canvas = WorkflowController(services: services(for: store)); await canvas.load()
        canvas.addNode(operationID: WorkflowModelRoutes.fluxDev)
        let nodeID = try #require(canvas.selectedNodeID)
        let parameters: [String: WorkflowScalar] = ["modelID": .text("image:dev"),
            "promptText": .text("Unchanged full Dev prompt"), "width": .integer(256), "height": .integer(256),
            "steps": .integer(50), "guidance": .decimal(4), "seed": .text("42"),
            "count": .integer(1), "memoryBudgetGiB": .integer(2)]
        for (key, value) in parameters {
            quick.setParameter(key, value: value, draftID: draftID)
            canvas.setParameter(nodeID: nodeID, key: key, value: value)
        }
        for (index, strategy) in [ImageLoadingStrategy.staged, .ssdLayered].enumerated() {
            quick.setParameter("loadingStrategy", value: .text(strategy.rawValue), draftID: draftID)
            canvas.setParameter(nodeID: nodeID, key: "loadingStrategy", value: .text(strategy.rawValue))
            #expect(quick.definition?.fields.first { $0.id == "loadingStrategy" }?.kind == .choice(["staged", "ssdLayered"]))
            #expect(quick.canStart)
            quick.start(); await quick.waitForCompletion()
            await canvas.run(target: nodeID, only: false)
            let requests = await engine.requests
            #expect(requests.count == (index + 1) * 2)
            for request in requests.suffix(2) {
                guard case .image(let image) = request.input else { Issue.record("Expected image request"); continue }
                #expect(image.loadingStrategy == strategy && image.executionProfile == ImageExecutionCapability.flux2Dev.profile)
                #expect(image.prompt == "Unchanged full Dev prompt" && image.steps == 50 && image.guidanceScale == 4 && image.seed == 42)
                #expect(request.model.revision == "dev-fixture" && request.memoryBudgetBytes == 2 * 1_024 * 1_024 * 1_024)
            }
            #expect(quick.state.runs.last?.status == .completed)
            #expect(canvas.runs.last?.status == .completed)
        }
        let graphID = try #require(canvas.graph?.id)
        try await quick.prepareForTermination(); try await canvas.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let restored = QuickGenerationController(store: reopened) { services(for: reopened) }
        await restored.load()
        #expect(restored.draft?.node.parameters["loadingStrategy"] == .text("ssdLayered"))
        let restoredCanvas = WorkflowController(services: services(for: reopened)); await restoredCanvas.load()
        #expect(restoredCanvas.graphs.first { $0.id == graphID }?.nodes.first?.parameters["loadingStrategy"] == .text("ssdLayered"))
        #expect(await engine.requests.count == 4) // Reload does not submit another request.
        try await restored.prepareForTermination(); try await restoredCanvas.close(); try await reopened.close()
    }

    private func fixture(release: @escaping @MainActor () async -> Void = {}, prepare: @escaping @MainActor () async -> Void = {}) async throws -> (URL, ProjectStore, WorkflowFixtureEngine, WorkflowController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("M0-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("测试.dproject"), name: "测试")
        let engine = WorkflowFixtureEngine(directory: store.artifactDirectory)
        let session = WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text", imageCapability: .scalableKlein4B)
        let services = WorkflowServices(store: store, session: session, defaultIdentity: { $0 == .text ? "text:fixture" : "image:fixture" },
            resolveText: { await prepare(); return .init(identity: "text:fixture", reference: .init(directory: root, revision: "fixture"), backendID: "fixture.text", release: release) },
            resolveImage: { .init(identity: "image:fixture", reference: .init(directory: root, revision: "fixture"), backendID: "fixture.image") })
        let controller = WorkflowController(services: services); await controller.load()
        return (root, store, engine, controller)
    }

    @Test func cancelledAfterPublicationRetainsOutputAndResumeDoesNotRegenerate() async throws {
        let release = WorkflowSubmitGate()
        let (_, store, engine, c) = try await fixture(release: { await release.wait() })
        c.addExample("text"); let target = try #require(c.graph?.nodes[1].id)
        let work = Task { await c.run(target: target, only: false) }
        for _ in 0..<2000 { if await release.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await release.entered)
        await c.cancel(); await release.open(); await work.value
        #expect(c.runs.last?.status == .cancelled)
        #expect(c.runs.last?.steps.last?.outputs["output"]?.asset != nil)
        #expect(c.runs.last?.steps.last?.status == .completed)
        #expect(await engine.requests.count == 1)
        await c.resume(runID: try #require(c.runs.last?.id))
        #expect(c.runs.last?.status == .completed)
        #expect(await engine.requests.count == 1)
        try await c.close(); try await store.close()
    }

    @Test func onlyRetryIntentSurvivesInitialSaveFailure() async throws {
        let (_, store, engine, c) = try await fixture()
        c.addExample("text"); let target = try #require(c.graph?.nodes[1].id)
        await c.run(target: target, only: false)
        #expect(await engine.requests.count == 1)
        var fail = true
        c.beforeHistorySave = { if fail { throw WorkflowIssue("initial history unavailable") } }
        await c.run(target: target, only: true)
        #expect(c.runs.last?.planCheckpoint?.records.last?.step.repeatRequested == true)
        fail = false; await c.save()
        await c.resume(runID: try #require(c.runs.last?.id))
        #expect(c.errorMessage == nil); #expect(await engine.requests.count == 2)
        try await c.close(); try await store.close()
    }

    @Test func textWaitReopensIdempotentDecisionAndNoSilentRun() async throws {
        let (_, store, engine, c) = try await fixture()
        c.addExample("text"); let graph = try #require(c.graph); let target = try #require(graph.nodes.last?.id)
        await c.run(target: target, only: false)
        #expect(c.errorMessage == nil); #expect(c.runs.last?.status == .waiting)
        #expect(await engine.requests.count == 1)
        let step = try #require(c.runs.last?.steps.last)
        let before = await store.snapshot(); #expect(before.draft.prompt == "")
        await c.decide(stepID: step.id, accept: true, text: "人工确认 🇯🇵 e\u{301}", candidateID: nil, acceptPartial: false)
        #expect(c.errorMessage == nil)
        let assets = await store.snapshot().assets.count
        await c.decide(stepID: step.id, accept: true, text: "不同重复请求", candidateID: nil, acceptPartial: false)
        #expect(await store.snapshot().assets.count == assets)
        #expect(await engine.requests.count == 1)
        await c.resume(runID: try #require(c.runs.last?.id)); #expect(c.runs.last?.status == .completed)
        let archive = try #require(try await store.workflowState().archive)
        #expect(archive.runs.last?.steps.last?.decision?.accepted == true)
        try await c.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let restored = try #require(try await reopened.workflowState().archive)
        #expect(restored.runs == archive.runs); #expect(restored.graphs == archive.graphs)
        try await reopened.close()
    }

    @Test func editsAndGraphSwitchDuringSubmittedModelRunKeepOriginalSnapshot() async throws {
        let (_, store, engine, c) = try await fixture()
        let gate = WorkflowSubmitGate(); await engine.suspend(using: gate)
        c.addExample("text"); let original = try #require(c.graph)
        let operation = Task { await c.run(target: original.nodes[1].id, only: false) }
        for _ in 0..<2000 {
            if await !engine.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let submitted = try #require(await engine.requests.first)
        c.setParameter(nodeID: original.nodes[0].id, key: "text", value: .text("new unsent input"))
        c.addExample("template"); let other = try #require(c.graph)
        let active = try #require(c.activePresentationRun)
        #expect(active.graph.id == original.id && active.targetNodeID == original.nodes[1].id)
        #expect(c.canPausePresentation)
        #expect(c.revealRunForPresentation(active.id))
        #expect(c.graph?.id == original.id && c.bodyPath.isEmpty)
        c.selectedGraphID = other.id
        await gate.open(); await operation.value
        #expect(c.activePresentationRun == nil && !c.canPausePresentation)
        #expect(c.errorMessage == nil)
        #expect(c.graph == other)
        let run = try #require(c.runs.last)
        #expect(run.graph.id == original.id)
        #expect(run.graph.nodes[0].parameters["text"] == original.nodes[0].parameters["text"])
        #expect(await engine.requests == [submitted])
        #expect(c.graphs.first { $0.id == original.id }?.nodes[0].parameters["text"] == .text("new unsent input"))
        try await c.close(); try await store.close()
    }

    @Test(arguments: [false, true])
    func cancellationPresentationWaitsForReleaseAndPreservesSaveFailure(failHistory: Bool) async throws {
        let release = WorkflowSubmitGate(), prepare = WorkflowSubmitGate()
        var pausePreparation = false
        let (_, store, engine, c) = try await fixture(release: { await release.wait() }, prepare: {
            if pausePreparation { await prepare.wait() }
        })
        let submit = WorkflowSubmitGate(); await engine.suspend(using: submit)
        c.addExample("text"); let target = try #require(c.graph?.nodes[1].id)
        c.beforeHistorySave = {
            if failHistory && c.runs.last?.status == .cancelled { throw WorkflowIssue("cancel history unavailable") }
        }
        let work = Task { await c.run(target: target, only: false) }
        for _ in 0..<2000 {
            if await submit.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await submit.entered)
        let cancellation = Task { await c.cancel() }
        for _ in 0..<2000 {
            if c.runs.last?.status == .cancelling { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(c.runs.last?.status == .cancelling)
        await submit.open()
        for _ in 0..<2000 {
            if await release.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await release.entered)
        #expect(c.isRunning)
        #expect(!c.progressMessage.contains("已停止并释放"))
        await release.open(); await cancellation.value; await work.value
        #expect(!c.isRunning)
        if failHistory {
            #expect(c.hasPendingSaves)
            #expect(c.runs.last?.status == .saving)
            #expect(c.errorMessage?.contains("cancel history unavailable") == true)
            #expect(!c.progressMessage.contains("已停止并释放"))
            c.beforeHistorySave = {}
            await c.save()
        } else {
            #expect(c.runs.last?.status == .cancelled)
            #expect(c.errorMessage == nil)
            #expect(c.progressMessage == "已取消，计算已停止并释放资源。")
            #expect(c.runs.last?.steps.last?.error == nil)
            let runID = try #require(c.runs.last?.id)
            pausePreparation = true
            let resuming = Task { await c.resume(runID: runID) }
            for _ in 0..<2000 {
                if await prepare.entered { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await prepare.entered)
            await c.cancel() // No active backend yet; preparation still must observe cancellation.
            await prepare.open(); await resuming.value
            #expect(c.runs.last?.status == .cancelled)
            #expect(c.errorMessage == nil)
            #expect(c.progressMessage == "已取消，计算已停止并释放资源。")
            #expect(await engine.requests.count == 1)
            pausePreparation = false
            await c.resume(runID: runID)
            #expect(c.runs.last?.status == .completed)
            #expect(c.errorMessage == nil)
        }
        try await c.close(); try await store.close()
    }

    @Test func productionProjectSessionBridgePublishesSnapshotAndReturnsFreshDocument() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("M0-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "D.M0.Bridge." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let subject = ProjectSession(sessionFactory: { directory in
            let engine = WorkflowFixtureEngine(directory: directory)
            return WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text",
                validateTextModel: { .init(directory: $0, revision: "fixture") })
        }, settings: settings)
        let url = root.appendingPathComponent("bridge.dproject")
        await subject.createProject(at: url); await subject.createTextDocument(name: "原文")
        let original = try #require(subject.text?.editor.document.id)
        subject.editText("已发布中文 👩🏽‍🎨", documentID: original); await subject.saveText()
        await subject.publishTextToWorkflow()
        let controller = try #require(subject.workflow)
        let ref = try #require(controller.graph?.nodes.last?.assetReference)
        subject.editText("聊天继续；不得改变流程快照", documentID: original); await subject.saveText()
        #expect(try await controller.services.readText(ref) == "已发布中文 👩🏽‍🎨")
        #expect(controller.runs.isEmpty)
        await subject.returnWorkflowText(ref)
        #expect(subject.errorMessage == nil)
        #expect(subject.text?.editor.document.id != original)
        #expect(subject.text?.editor.document.text == "已发布中文 👩🏽‍🎨")
        #expect(await subject.requestClose())
        #expect(subject.workflow == nil)
        let before = controller.graphs; controller.addExample("text"); #expect(controller.graphs == before)
        await subject.openProject(at: url); await subject.openWorkflow()
        #expect(subject.workflow?.graphs == before)
        #expect(await subject.requestClose())
    }

    @Test func documentAndGraphRewriteShareRequestsAndDurableProvenanceWithoutHiddenGraph() async throws {
        let (root, unused, engine, _) = try await fixture(); try await unused.close()
        let suite = "D.M0.Rewrite." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite)); defer { settings.removePersistentDomain(forName: suite) }
        let model = ModelReference(directory: root, revision: "fixture")
        let subject = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text", validateTextModel: { _ in model })
        }, settings: settings)
        let url = root.appendingPathComponent("shared-rewrite.dproject")
        await subject.createProject(at: url); await subject.createTextDocument(name: "独立会话")
        let editor = try #require(subject.text); let id = editor.editor.document.id
        let input = "清晨 👩🏽‍🎨 e\u{301}"; let instruction = "Polish this text."
        subject.editText(input, documentID: id); await subject.saveText()
        subject.selectText(.init(location: 0, length: input.utf16.count), documentID: id)
        editor.instruction = instruction; await subject.registerTextModel(at: root)
        #expect(subject.canRewriteText); await subject.rewriteText()
        let candidate = try #require(editor.editor.candidate)
        #expect(editor.canAccept); #expect(subject.workflow == nil)
        subject.acceptTextRewrite(); await subject.saveText()
        #expect(await subject.requestClose()); await subject.openProject(at: url); await subject.openWorkflow()
        let c = try #require(subject.workflow)
        let archive = try #require(try await c.services.store.workflowState().archive)
        #expect(archive.graphs.isEmpty && archive.runs.isEmpty) // a shared asset is not a hidden graph
        let record = try #require(archive.assets.first { $0.reference.assetID == candidate.runID })
        #expect(record.request == candidate.request)
        #expect(record.metadata == candidate.executionDetails())
        #expect(try await c.services.readText(record.reference) == candidate.replacement)
        c.addExample("text"); let graph = try #require(c.graph)
        c.setParameter(nodeID: graph.nodes[0].id, key: "text", value: .text(input))
        c.setParameter(nodeID: graph.nodes[1].id, key: "instruction", value: .text(instruction))
        c.setParameter(nodeID: graph.nodes[1].id, key: "maximumOutputTokens", value: .integer(editor.editor.document.generationSettings.maximumOutputTokens))
        c.setParameter(nodeID: graph.nodes[1].id, key: "maximumPromptTokens", value: .integer(editor.editor.document.generationSettings.maximumPromptTokens))
        await c.run(target: graph.nodes[1].id, only: false)
        #expect(c.errorMessage == nil)
        let output = try #require(c.runs.last?.steps.last?.outputs["output"]?.asset)
        let graphRecord = try #require(try await c.services.store.workflowState().archive?.assets.first { $0.reference == output })
        #expect(graphRecord.request?.model == record.request?.model)
        #expect(graphRecord.request?.input == record.request?.input)
        #expect(graphRecord.metadata["backend"] == record.metadata["backend"])
        #expect(graphRecord.metadata["operation"] == record.metadata["operation"])
        #expect(graphRecord.metadata["runID"] != record.metadata["runID"])
        #expect(await engine.requests.count == 2)
        #expect(await subject.requestClose())
    }

    @Test func failedDocumentRewriteRecordRetriesSavingWithoutRepeatingInferenceOrChangingOriginal() async throws {
        let (root, store, engine, _) = try await fixture()
        let failure = WorkflowSaveSwitch()
        let document = try TextDraftDocument(text: "原文 e\u{301}")
        let editor = ProjectTextController(document: document, engine: engine, backendID: "fixture.text",
            recordRewrite: { candidate in
                if failure.fails { throw WorkflowIssue("controlled unavailable output") }
                _ = try await store.publishWorkflowAsset(data: Data(candidate.replacement.utf8), mediaType: "text/plain",
                    name: "candidate", operationID: "d.text.rewrite", request: candidate.request,
                    details: candidate.executionDetails(), assetID: candidate.runID)
            }, persist: { _, _ in })
        editor.select(.init(location: 0, length: document.text.utf16.count), documentID: document.id)
        editor.instruction = "Polish"; await editor.rewrite(using: .init(directory: root))
        #expect(editor.editor.document == document && !editor.canAccept)
        #expect(editor.editor.candidate != nil && editor.errorMessage != nil)
        failure.fails = false; try await editor.flush()
        #expect(editor.canAccept); #expect(await engine.requests.count == 1)
        editor.accept(); try await editor.flush()
        #expect(editor.editor.document.text != document.text)
        #expect(try await store.workflowState().archive?.assets.count == 1)
        editor.rebind(engine: engine, backendID: "fixture.rebound")
        editor.select(.init(location: 0, length: editor.editor.document.text.utf16.count), documentID: document.id)
        await editor.rewrite(using: .init(directory: root))
        let rebound = try #require(editor.editor.candidate)
        #expect(rebound.backendID == "fixture.rebound")
        let reboundRecord = try #require(try await store.workflowState().archive?.assets.first { $0.reference.assetID == rebound.runID })
        #expect(reboundRecord.metadata["backend"] == "fixture.rebound")
        editor.reject()
        try await store.close()
    }

    @Test func switchingProjectsWaitsForAdmittedGraphAndNeverWritesIntoNewProject() async throws {
        let (root, unused, engine, _) = try await fixture(); try await unused.close()
        let suite = "D.M0.Switch." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite)); defer { settings.removePersistentDomain(forName: suite) }
        let subject = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text",
                validateTextModel: { .init(directory: $0, revision: "fixture") })
        }, settings: settings, closeDecision: { .wait })
        let bURL = root.appendingPathComponent("B.dproject")
        let b = try await ProjectStore.create(at: bURL, name: "B"); let bID = await b.snapshot().id; try await b.close()
        let aURL = root.appendingPathComponent("A.dproject")
        await subject.createProject(at: aURL); await subject.registerTextModel(at: root); await subject.openWorkflow()
        let c = try #require(subject.workflow); c.addExample("text"); let graph = try #require(c.graph)
        let gate = WorkflowSubmitGate(); await engine.suspend(using: gate)
        let run = Task { await c.run(target: graph.nodes[1].id, only: false) }
        for _ in 0..<2000 {
            if await !engine.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await engine.requests.count == 1)
        c.setParameter(nodeID: graph.nodes[0].id, key: "text", value: .text("A edited after submission"))
        let switchProject = Task { await subject.openProject(at: bURL) }
        for _ in 0..<2000 {
            if subject.isChangingProject { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(subject.manifest?.id != bID && subject.isChangingProject)
        await gate.open(); await run.value; await switchProject.value
        #expect(subject.manifest?.id == bID)
        #expect(subject.manifest?.assets.isEmpty == true)
        #expect(subject.manifest?.workflowSnapshot == nil)
        let old = try await ProjectStore.open(at: aURL)
        let history = try #require(try await old.workflowState().archive)
        #expect(history.runs.last?.status == .completed)
        #expect(history.runs.last?.graph.nodes[0].parameters["text"] == graph.nodes[0].parameters["text"])
        #expect(history.graphs[0].nodes[0].parameters["text"] == .text("A edited after submission"))
        #expect(history.assets.allSatisfy { $0.reference.projectID != bID })
        try await old.close(); #expect(await subject.requestClose())
    }

    @Test func pendingWaitSurvivesCloseAndStaleConfirmationCannotPublish() async throws {
        let (_, store, _, c) = try await fixture()
        c.addExample("template"); let g = try #require(c.graph)
        await c.run(target: try #require(g.nodes.last?.id), only: false)
        let waiting = try #require(c.runs.last?.steps.last)
        #expect(waiting.status == .waiting)
        let original = try #require(try await store.workflowState().archive)
        c.setParameter(nodeID: g.nodes[0].id, key: "text", value: .text("new original"))
        await c.decide(stepID: waiting.id, accept: true, text: "stale", candidateID: nil, acceptPartial: false)
        #expect(c.errorMessage?.contains("过期") == true)
        #expect(try await store.workflowState().archive?.assets == original.assets)
        c.undo(); c.errorMessage = nil
        await c.save(); try await c.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.workflowState().archive?.runs.last?.status == .waiting)
        try await reopened.close()
    }

    @Test func unacceptedReviewDraftSurvivesReopenAndNeverPublishesOrRuns() async throws {
        let (_, store, engine, c) = try await fixture()
        c.addExample("template"); let target = try #require(c.graph?.nodes.last?.id)
        await c.run(target: target, only: false)
        let run = try #require(c.runs.last); let step = try #require(run.steps.last)
        let original = await store.snapshot().assets
        let draft = "未接受 👩🏽‍🎨 e\u{301}"
        c.editReviewText(stepID: step.id, text: draft)
        #expect(c.runs.last?.steps.last?.decision == nil)
        #expect(await store.snapshot().assets == original)
        #expect(await engine.requests.isEmpty)
        c.addExample("text")
        c.editReviewText(stepID: step.id, text: "wrong selected graph")
        #expect(c.runs.last?.steps.last?.reviewTextDraft == draft)
        await c.save(); try await c.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let restored = try #require(try await reopened.workflowState().archive)
        #expect(restored.runs.last?.steps.last?.reviewTextDraft == draft)
        #expect(restored.runs.last?.status == .waiting)
        #expect(restored.runs.last?.steps.last?.decision == nil)
        #expect(await reopened.snapshot().assets == original)
        c.editReviewText(stepID: step.id, text: "late callback")
        #expect(c.runs.last?.steps.last?.reviewTextDraft == draft)
        try await reopened.close()
    }

    @Test func fullGraphPartialRetryAndSelectionAreExplicit() async throws {
        let (_, store, engine, c) = try await fixture()
        await engine.failSecond(); c.addExample("image")
        let g = try #require(c.graph); let target = try #require(g.nodes.last?.id)
        await c.run(target: target, only: false)
        #expect(c.runs.last?.status == .waiting)
        #expect(await engine.requests.count == 1) // no image before text confirmation
        let confirm = try #require(c.runs.last?.steps.last(where: { $0.status == .waiting }))
        await c.decide(stepID: confirm.id, accept: true, text: "A quiet garden", candidateID: nil, acceptPartial: false)
        #expect(await engine.requests.count == 1)
        await c.resume(runID: try #require(c.runs.last?.id))
        #expect(c.errorMessage == nil)
        let generation = try #require(c.runs.last?.steps.first(where: { $0.node.operationID == "d.image.generate" }))
        #expect(generation.status == .partial)
        let candidates = try #require(generation.outputs["output"]?.candidates)
        #expect(candidates.filter { $0.asset != nil }.count == 2)
        let choose = try #require(c.runs.last?.steps.first(where: { $0.node.operationID == "d.asset.choose" }))
        await c.decide(stepID: choose.id, accept: true, text: nil, candidateID: candidates[0].id, acceptPartial: false)
        #expect(c.errorMessage != nil); #expect(c.runs.last?.steps.first { $0.id == choose.id }?.decision == nil)
        c.errorMessage = nil
        await c.retryFailedCandidates(stepID: generation.id)
        #expect(c.errorMessage == nil)
        let retry = try #require(c.runs.last?.steps.last?.outputs["output"]?.candidates)
        #expect(retry.allSatisfy { $0.asset != nil }); #expect(retry[0].asset == candidates[0].asset); #expect(retry[2].asset == candidates[2].asset)
        #expect(await engine.requests.count == 5) // one text, three initial images, only one retry
        try await store.close()
    }

    @Test func noModelFileFlowExportAndLayoutDoNotExecuteAgain() async throws {
        let (root, store, engine, c) = try await fixture()
        let file = root.appendingPathComponent("有 空格.png"); try workflowFixturePNG().write(to: file)
        c.addExample("file"); let g = try #require(c.graph)
        await c.importFile(file, nodeID: g.nodes[0].id)
        c.setParameter(nodeID: g.nodes[2].id, key: "format", value: .text("jpeg"))
        c.setDestination(root)
        await c.run(target: g.nodes[3].id, only: false)
        #expect(c.errorMessage == nil); #expect(c.runs.last?.status == .completed); #expect(await engine.requests.isEmpty)
        let receipt = try #require(c.runs.last?.steps.last?.outputs["output"])
        guard case .receipt(let r) = receipt else { Issue.record("expected receipt"); return }
        #expect(r.names.contains("1.jpg")); #expect(r.names.contains("recipe.json"))
        let step = try #require(c.latestStep(for: g.nodes[1].id))
        c.moveNode(id: g.nodes[1].id, x: 400, y: 600); #expect(!c.isStale(step))
        await c.run(target: g.nodes[3].id, only: false); #expect(c.errorMessage == nil); #expect(await engine.requests.isEmpty)
        // Import was a copy. Mutating source cannot rewrite the authoritative imported asset.
        try Data("not a png anymore".utf8).write(to: file)
        let ref = try #require(c.graph?.nodes.first?.assetReference)
        #expect(try await store.workflowData(ref).starts(with: [137,80,78,71]))
        let record = try #require(await store.snapshot().assets.first { $0.id == ref.id })
        try Data("tampered".utf8).write(to: store.rootURL.appendingPathComponent(record.relativePath))
        await #expect(throws: (any Error).self) { _ = try await store.workflowData(ref) }
        try await store.close()
    }

    @Test func failedPublicationPreservesManifestAndRetryUsesSameAssetIdentity() async throws {
        let (_, store, _, _) = try await fixture()
        let oldBytes = try Data(contentsOf: store.rootURL.appendingPathComponent("project.json"))
        let id = UUID(), text = Data("原文".utf8)
        await #expect(throws: (any Error).self) {
            _ = try await store.publishWorkflowAsset(data: text, mediaType: "text/plain", metadata: .init(), name: "原文", parents: [],
                operationID: "d.text.input", stepID: nil, request: nil, details: [:], assetID: id,
                checkpoint: { if case .beforeManifest = $0 { throw WorkflowIssue("simulated disk full") } })
        }
        #expect(try Data(contentsOf: store.rootURL.appendingPathComponent("project.json")) == oldBytes)
        #expect(await store.snapshot().assets.isEmpty)
        let result = try await store.publishWorkflowAsset(data: text, mediaType: "text/plain", name: "原文", operationID: "d.text.input", assetID: id)
        #expect(result.asset.id == id); #expect(try await store.workflowData(result.record.reference) == text)
        _ = try await store.publishWorkflowAsset(data: text, mediaType: "text/plain", name: "原文", operationID: "d.text.input", assetID: id)
        #expect(await store.snapshot().assets.count == 1); try await store.close()
    }

    @Test func futureWorkflowAndUnknownNodePreserveRawBytes() async throws {
        for variant in 0..<4 {
            let (_, store, _, c) = try await fixture()
            c.addExample("text")
            if variant == 2 { await c.run(target: try #require(c.graph?.nodes[0].id), only: false) }
            await c.save(); let saved = await store.snapshot(); try await store.close()
            let pointer = try #require(saved.workflowSnapshot)
            let url = store.rootURL.appendingPathComponent(pointer.relativePath)
            var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            if variant == 1 {
                var graphs = try #require(raw["graphs"] as? [[String: Any]])
                var nodes = try #require(graphs[0]["nodes"] as? [[String: Any]])
                nodes[0]["operationID"] = "future.module"; nodes[0]["parameters"] = ["opaque": ["newShape": [1, 2, 3]]]
                graphs[0]["nodes"] = nodes; raw["graphs"] = graphs
            } else if variant == 2 {
                var runs = try #require(raw["runs"] as? [[String: Any]])
                var steps = try #require(runs[0]["steps"] as? [[String: Any]])
                var node = try #require(steps[0]["node"] as? [String: Any])
                node["definitionVersion"] = 999; node["opaque"] = ["must":"survive"]
                steps[0]["node"] = node; runs[0]["steps"] = steps; raw["runs"] = runs
            } else if variant == 3 {
                raw["futureMetadata"] = ["must":"survive"]
            } else { raw["version"] = 999; raw["extra"] = ["must":"survive"] }
            let bytes = try JSONSerialization.data(withJSONObject: raw, options: .sortedKeys); try bytes.write(to: url)
            var manifest = saved; manifest.workflowSnapshot = .init(generation: pointer.generation, byteCount: bytes.count,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            try JSONEncoder().encode(manifest).write(to: store.rootURL.appendingPathComponent("project.json"))
            let reopened = try await ProjectStore.open(at: store.rootURL)
            let state = try await reopened.workflowState(); #expect(state.archive == nil); #expect(state.originalBytes == bytes)
            let second = try await reopened.workflowState(); #expect(second.archive == nil); #expect(second.originalBytes == bytes)
            await #expect(throws: (any Error).self) { _ = try await reopened.saveWorkflow(graphs: [], runs: [], expectedRevision: UUID()) }
            #expect(try Data(contentsOf: url) == bytes); try await reopened.close()
        }
    }

    @Test func sourceTwelveMigrationPreservesExactBackupAndCandidateSchemasRejected() async throws {
        let (_, store, _, _) = try await fixture(); var old = await store.snapshot(); try await store.close()
        old.schemaVersion = 12; let original = try JSONEncoder().encode(old)
        try original.write(to: store.rootURL.appendingPathComponent("project.json"))
        let migrated = try await ProjectStore.open(at: store.rootURL)
        #expect(await migrated.snapshot().schemaVersion == ProjectManifest.currentSchemaVersion)
        #expect(try Data(contentsOf: store.rootURL.appendingPathComponent("project.v12.backup.json")) == original)
        try await migrated.close()
        #expect(!ProjectManifest.readableSchemaVersions.contains(13)); #expect(!ProjectManifest.readableSchemaVersions.contains(14)); #expect(!ProjectManifest.readableSchemaVersions.contains(15))
    }

    @Test func deliveredResultHistoryFailureDoesNotRepeatInference() async throws {
        let (_, store, engine, c) = try await fixture()
        c.addExample("text"); let rewrite = try #require(c.graph?.nodes[1].id)
        var fail = true
        c.beforeHistorySave = {
            if fail && c.runs.last?.steps.last(where: { $0.node.operationID == "d.text.rewrite" })?.status == .completed { throw WorkflowIssue("history volume unavailable") }
        }
        await c.run(target: rewrite, only: false)
        #expect(c.runs.last?.status == .saving); #expect(c.runs.last?.steps.last?.status == .completed)
        #expect(await engine.requests.count == 1)
        fail = false; await c.save(); c.errorMessage = nil
        await c.resume(runID: try #require(c.runs.last?.id))
        #expect(c.errorMessage == nil); #expect(c.runs.last?.status == .completed)
        #expect(await engine.requests.count == 1)
        try await c.close(); try await store.close()
    }

    @Test func retryHistoryFailureRetainsOriginalSuccessfulCandidates() async throws {
        let (_, store, engine, c) = try await fixture(); await engine.failSecond()
        c.addExample("image"); let g = try #require(c.graph)
        await c.run(target: g.nodes[2].id, only: false)
        let waiting = try #require(c.runs.last?.steps.last)
        await c.decide(stepID: waiting.id, accept: true, text: "studio", candidateID: nil, acceptPartial: false)
        await c.run(target: g.nodes[3].id, only: false)
        let generated = try #require(c.runs.last?.steps.last)
        let original = try #require(generated.outputs["output"]?.candidates)
        #expect(original.filter { $0.asset != nil }.count == 2)
        var fail = true
        c.beforeHistorySave = { if fail { throw WorkflowIssue("retry manifest failure") } }
        await c.retryFailedCandidates(stepID: generated.id)
        #expect(c.runs.last?.steps.last?.outputs["output"]?.candidates == original)
        #expect(await engine.requests.count == 4)
        fail = false; await c.save(); c.errorMessage = nil
        let retryID = try #require(c.runs.last?.id)
        // Cold recovery after interruption, with a new upstream asset under the same configuration.
        let newer = try await store.publishWorkflowAsset(data: Data("different prompt v2".utf8), mediaType: "text/plain",
            name: "new confirmation", operationID: "d.text.confirm")
        var archive = try #require(try await store.workflowState().archive)
        let confirmNode = g.nodes[2]
        let newerStep = WorkflowStepRun(node: confirmNode, signature: try c.registry.signature(confirmNode.id, in: try #require(c.graph)),
            outputs: ["output": .asset(newer.record.reference)], status: .completed)
        archive.runs[archive.runs.count - 1].status = .interrupted
        archive.runs[archive.runs.count - 1].steps[0].status = .interrupted
        // The checkpoint is authoritative in v2; cold-process interruption must
        // update its matching projection as the production loader does.
        archive.runs[archive.runs.count - 1].planCheckpoint?.state = .interrupted
        archive.runs[archive.runs.count - 1].planCheckpoint?.records[0].step.status = .interrupted
        archive.runs.append(.init(graph: try #require(c.graph), targetNodeID: confirmNode.id, steps: [newerStep], status: .completed))
        _ = try await store.saveWorkflow(graphs: archive.graphs, runs: archive.runs, expectedRevision: archive.revision)
        c.deactivateAfterClose()
        let recovered = WorkflowController(services: c.services); await recovered.load()
        await recovered.resume(runID: retryID)
        #expect(recovered.errorMessage == nil)
        let request = try #require(await engine.requests.last)
        if case .image(let input) = request.input { #expect(input.prompt == "studio") }
        else { Issue.record("expected image retry") }
        let recoveredRun = try #require(recovered.runs.first { $0.id == retryID })
        let retried = try #require(recoveredRun.steps.last?.outputs["output"]?.candidates)
        #expect(await engine.requests.count == 5)
        #expect(retried[0].asset == original[0].asset && retried[2].asset == original[2].asset)
        #expect(retried.allSatisfy { $0.asset != nil })
        try await recovered.close(); try await store.close()
    }

    @Test func pinExistingRegisteredOriginalRejectsChangedBytes() async throws {
        let (root, store, _, c) = try await fixture()
        let file = root.appendingPathComponent("reference.png"); try workflowFixturePNG(width: 512, height: 512).write(to: file)
        let documentID = try #require(await store.snapshot().documents.first?.id)
        let manifest = try await store.importImageReference(at: file, name: "reference", documentID: documentID)
        let original = try #require(manifest.assets.first)
        let before = try Data(contentsOf: store.rootURL.appendingPathComponent("project.json"))
        try workflowFixturePNG(width: 544, height: 512).write(to: store.rootURL.appendingPathComponent(original.relativePath))
        await #expect(throws: (any Error).self) { _ = try await store.pinWorkflowAsset(original.id) }
        #expect(try Data(contentsOf: store.rootURL.appendingPathComponent("project.json")) == before)
        #expect(try await store.workflowState().archive?.assets.isEmpty == true)
        try await c.close(); try await store.close()
    }

    @Test func displaySnapshotReusesLayoutAndTracksConfigurationAndNewHistory() async throws {
        let (_, store, _, c) = try await fixture(); c.addExample("template")
        let graph = try #require(c.graph)
        for node in graph.nodes { #expect(c.presentationStatus(for: node.id) == nil) }
        #expect(c.displayAnalysisCount == 0)
        await c.run(target: graph.nodes[3].id, only: false)
        func compare() {
            for node in graph.nodes {
                let display = c.presentationStatus(for: node.id)
                let step = c.latestStep(for: node.id)
                #expect(display?.status == step?.status)
                if let step { #expect(display?.stale == c.isStale(step)) }
            }
        }
        compare()
        let analyses = c.displayAnalysisCount, histories = c.displayHistoryCount
        let clock = ContinuousClock()
        let warm = clock.measure { for _ in 0..<100 { for node in graph.nodes { _ = c.presentationStatus(for: node.id) } } }
        let old = clock.measure { for _ in 0..<100 { for node in graph.nodes { if let step = c.latestStep(for: node.id) { _ = c.isStale(step) } } } }
        print("R15_GRAPH nodes=\(graph.nodes.count) queries=100 warm=\(warm) authoritative=\(old) analysis=\(c.displayAnalysisCount - analyses)")
        #expect(c.displayAnalysisCount == analyses && c.displayHistoryCount == histories)
        c.selectedNodeID = graph.nodes[1].id
        c.toggleCollapsed(graph.nodes[0].id); compare()
        c.undo(); compare(); c.redo(); compare()
        #expect(c.displayAnalysisCount == analyses)
        c.setParameter(nodeID: graph.nodes[0].id, key: "text", value: .text("changed")); compare()
        #expect(c.displayAnalysisCount == analyses + 1)
        c.undo(); compare()
        await c.run(target: graph.nodes[0].id, only: true); compare()
        #expect(c.presentationStatus(for: graph.nodes[3].id)?.stale == true)
        try await c.close(); try await store.close()
    }

    @Test func sameConfigurationNewUpstreamVersionInvalidatesDescendants() async throws {
        let (_, store, _, c) = try await fixture(); c.addExample("template")
        let g = try #require(c.graph)
        await c.run(target: g.nodes[3].id, only: false)
        let waiting = try #require(c.runs.last?.steps.last)
        #expect(!c.isStale(waiting))
        await c.run(target: g.nodes[0].id, only: true)
        #expect(c.isStale(waiting))
        await c.decide(stepID: waiting.id, accept: true, text: "stale", candidateID: nil, acceptPartial: false)
        #expect(c.errorMessage?.contains("过期") == true)
        try await c.close(); try await store.close()
    }

    @Test func concurrentDecisionIsOneDurablePublicationAndCloseDisablesEdits() async throws {
        let (_, store, _, c) = try await fixture(); c.addExample("template")
        await c.run(target: try #require(c.graph?.nodes.last?.id), only: false)
        let waiting = try #require(c.runs.last?.steps.last)
        let before = await store.snapshot().assets.count
        let first = Task { await c.decide(stepID: waiting.id, accept: true, text: "one", candidateID: nil, acceptPartial: false) }
        await Task.yield()
        await c.decide(stepID: waiting.id, accept: false, text: nil, candidateID: nil, acceptPartial: false)
        await first.value
        let decision = try #require(c.runs.last?.steps.last?.decision)
        #expect(await store.snapshot().assets.count == before + (decision.accepted ? 1 : 0))
        try await c.close(); let graphs = c.graphs
        c.undo(); c.redo(); c.addExample("text")
        #expect(c.graphs == graphs); try await store.close()
    }

    @Test func smallProgramExtensionUsesRealStoreWithoutControllerSpecialCase() async throws {
        let (_, store, engine, c) = try await fixture(); c.addExample("text")
        let input = try #require(c.graph?.nodes[0].id)
        c.setParameter(nodeID: input, key: "text", value: .text("\n  中文 👩🏽‍🎨\r\n \t\n e\u{301}\n"))
        c.addNode(operationID: "d.text.remove-blank-lines")
        let target = try #require(c.selectedNodeID)
        c.connect(source: input, sourcePort: "output", target: target, targetPort: "input")
        await c.run(target: target, only: false)
        #expect(c.errorMessage == nil); #expect(await engine.requests.isEmpty)
        let result = try #require(c.runs.last?.steps.last?.outputs["output"]?.asset)
        #expect(try await c.services.readText(result) == "  中文 👩🏽‍🎨\n e\u{301}")
        try await c.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.workflowState().archive?.runs.last?.status == .completed)
        try await reopened.close()
    }

    @Test func samePortContractTwoImplementationsPublishDistinctSourceAndRejectWithoutFallback() async throws {
        let (_, store, engine, c) = try await fixture()
        let parent = try await store.publishWorkflowAsset(data: Data("hello".utf8), mediaType: "text/plain",
            name: "input", operationID: "d.text.input").record.reference
        func implementation(_ id: String, maximum: Int) -> WorkflowOperation {
            WorkflowOperation(definition: .init(id: id, title: id, detail: "fixture",
                inputs: [.init("input", "text", kinds: [.text])], outputs: [.init("output", "text", kinds: [.text])]),
                execute: { context, services in
                    let input = try #require(context.inputs["input"]?.asset)
                    let value = try await services.readText(input)
                    guard value.count <= maximum else { throw WorkflowIssue("fixture capacity") }
                    return .outputs(["output": .asset(try await services.publishText(id + ":" + value, parents: [input], context: context))])
                })
        }
        let first = implementation("fixture.program.first", maximum: 4)
        let second = implementation("fixture.program.second", maximum: 10)
        let registry = try WorkflowRegistry(operations: [first, second])
        let chosen = try #require(registry.operation(second.definition.id))
        let input: [String: WorkflowValue] = ["input": .asset(parent)]
        let context = WorkflowExecutionContext(node: chosen.definition.makeNode(), stepID: UUID(), inputs: input)
        try registry.validateInputs(input, node: context.node, connectedPorts: ["input"])
        let result = try await chosen.execute(context, c.services)
        guard case .outputs(let outputs) = result else { Issue.record("Expected typed text output"); return }
        let output = try #require(outputs["output"]?.asset)
        #expect(try await c.services.readText(output) == "fixture.program.second:hello")
        let record = try #require(try await store.workflowState().archive?.assets.first { $0.reference == output })
        #expect(record.operationID == second.definition.id && record.parents == [parent])
        await #expect(throws: WorkflowIssue.self) {
            _ = try await first.execute(.init(node: first.definition.makeNode(), stepID: UUID(), inputs: input), c.services)
        }
        #expect(try await store.workflowState().archive?.assets.count == 2)
        #expect(await engine.requests.isEmpty); #expect(registry.operation("fixture.missing") == nil)
        try await store.close()
    }

    @Test func exportDerivedRecipeKeepsAncestryWithoutPrivatePathsAndWillNotOverwrite() async throws {
        let (root, store, _, c) = try await fixture()
        let request = InferenceRequest(model: .init(directory: root.appendingPathComponent("secret-model"), revision: "fixed-revision"),
            input: .image(.init(prompt: "actual prompt", width: 16, height: 12, steps: 4, guidanceScale: 1, seed: UInt64.max)))
        let original = try await store.publishWorkflowAsset(data: workflowFixturePNG(), mediaType: "image/png",
            metadata: .init(width: 16, height: 12), name: "source", operationID: "d.image.generate", request: request,
            details: ["privatePath": root.path])
        var node = try #require(c.registry.operation("d.image.convert")).definition.makeNode()
        node.parameters["format"] = .text("jpeg")
        let ref = try await c.services.transformImage(original.record.reference,
            context: .init(node: node, stepID: UUID(), inputs: ["input": .asset(original.record.reference)]))
        let id = UUID()
        let receipt = try await store.exportWorkflowAssets([ref], name: "recipe", exportID: id, directory: root)
        let directory = root.appendingPathComponent("recipe-" + id.uuidString + ".dexport")
        let bytes = try Data(contentsOf: directory.appendingPathComponent("recipe.json"))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains(root.path)); #expect(text.contains("fixed-revision")); #expect(text.contains(String(UInt64.max)))
        #expect(!text.contains("actual prompt")); #expect(text.contains("withheld"))
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let history = try #require(json["provenance"] as? [[String: Any]])
        #expect(history.count == 2)
        #expect(history.last?["input"] == nil) // conversion is not falsely attributed to the generation request
        #expect((history.last?["processing"] as? [String: String])?["backgroundPolicy"] == "white")
        #expect(try await store.exportWorkflowAssets([ref], name: "recipe", exportID: id, directory: root) == receipt)
        let target = directory.appendingPathComponent("1.jpg"); let unrelated = Data("existing user file".utf8)
        try unrelated.write(to: target)
        await #expect(throws: (any Error).self) { _ = try await store.exportWorkflowAssets([ref], name: "recipe", exportID: id, directory: root) }
        #expect(try Data(contentsOf: target) == unrelated)
        try await c.close(); try await store.close()
    }
}


extension WorkflowLifecycleTests {
    @Test func perNodeModelsDoNotFollowCurrentDefaultAndReleaseAfterPreparationFailure() async throws {
        let (root, store, engine, old) = try await fixture()
        defer { _ = old }
        let session = WorkbenchSession(engine: engine, backendID: "image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "text")
        var released: [String] = [], resolved: [String] = []
        var defaultID = "text:B"
        let services = WorkflowServices(store: store, session: session, defaultIdentity: { _ in defaultID }) { kind, id in
            #expect(kind == .text); resolved.append(id)
            guard ["text:A", "text:B"].contains(id) else { throw WorkflowIssue("missing") }
            return .init(identity: id, reference: .init(directory: root, revision: id), backendID: "fixture." + id,
                         release: { released.append(id) })
        }
        let operation = try #require(WorkflowRegistry.standard.operation("d.text.rewrite"))
        var nodes = (0..<3).map { _ in operation.definition.makeNode() }
        for i in nodes.indices { nodes[i].parameters["modelID"] = .text(i == 1 ? "text:B" : "text:A") }
        var graph = WorkflowGraph(name: "independent", nodes: nodes)
        let prepared = try await services.prepare(graph, nodes: nodes.map(\.id))
        defaultID = "text:OTHER"
        for node in prepared.nodes {
            _ = try await services.rewriteText("source", parents: [], context: .init(node: node, stepID: UUID(), inputs: [:]))
        }
        #expect(await engine.requests.map { $0.model.revision } == ["text:A", "text:B", "text:A"])
        #expect(resolved == ["text:A", "text:B", "text:A"])
        #expect(released.isEmpty)
        await services.finish(); #expect(released.count == 3)
        graph.nodes[1].parameters["modelID"] = .text("text:missing")
        do { _ = try await services.prepare(graph, nodes: nodes.map(\.id)); Issue.record("missing model accepted") } catch {}
        #expect(released.count == 4); #expect(await engine.requests.count == 3)
        await services.finish(); #expect(released.count == 4)
        try await store.close()
    }

    @Test func modelChooserTargetNeverFollowsLaterSelectionOrChangedBinding() async throws {
        let (_, store, _, c) = try await fixture()
        c.addExample("text"); let a = try #require(c.graph?.nodes[1])
        c.selectedNodeID = a.id; let target = try #require(c.modelSelectionTarget())
        c.addNode(operationID: "d.text.rewrite"); let b = try #require(c.selectedNode)
        c.bindModel("text:A", to: target)
        #expect(c.graph?.nodes.first { $0.id == a.id }?.parameters["modelID"] == .text("text:A"))
        #expect(c.graph?.nodes.first { $0.id == b.id }?.parameters["modelID"] == .text(""))
        c.bindModel("text:LATE", to: target)
        #expect(c.graph?.nodes.first { $0.id == a.id }?.parameters["modelID"] == .text("text:A"))
        c.selectedNodeID = b.id; let other = try #require(c.modelSelectionTarget())
        c.deleteSelected(); c.bindModel("text:B", to: other)
        #expect(c.graph?.nodes.contains { $0.id == b.id } == false)
        c.addExample("template"); c.bindModel("text:wrong-graph", to: target)
        #expect(c.graph?.nodes.allSatisfy { $0.parameters["modelID"] == nil } == true)
        try await c.close(); try await store.close()
    }

    @Test func modelBookmarksKeepBothAndCorruptionDoesNotOverwriteOriginal() throws {
        let name = "D.boundary." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let book = WorkflowModelBookmarks(settings: defaults)
        try book.remember(identity: "text:A", kind: .text, name: "甲", bookmark: Data([1]))
        try book.remember(identity: "text:B", kind: .text, name: "乙", bookmark: Data([2]))
        let reopened = WorkflowModelBookmarks(settings: defaults)
        #expect(try reopened.entries().map(\.identity) == ["text:A", "text:B"])
        defaults.set("corrupt", forKey: WorkflowModelBookmarks.key)
        #expect(throws: (any Error).self) { try reopened.remember(identity: "text:C", kind: .text, name: "丙", bookmark: Data([3])) }
        #expect(defaults.string(forKey: WorkflowModelBookmarks.key) == "corrupt")
    }
}

extension WorkflowLifecycleTests {
    @Test func projectReopenResolvesEarlierTextModelAfterAnotherDefaultWasRegistered() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("model-reopen-" + UUID().uuidString)
        let a = base.appendingPathComponent("A"), b = base.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let suite = "D.ModelBindings." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = WorkflowFixtureEngine(directory: base)
        let factory: @Sendable (URL) async throws -> WorkbenchSession = { _ in
            WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text",
                validateTextModel: { url in .init(directory: url, revision: url.lastPathComponent) })
        }
        let project = base.appendingPathComponent("多模型.dproject")
        let owner = ProjectSession(sessionFactory: factory, settings: settings)
        await owner.createProject(at: project)
        #expect(owner.errorMessage == nil)
        await owner.registerTextModel(at: a)
        await owner.registerTextModel(at: b)
        await owner.openWorkflow()
        let first = try #require(owner.workflow)
        first.addExample("text")
        let id = try #require(first.graph?.nodes[1].id)
        first.setParameter(nodeID: id, key: "modelID", value: .text("text:A"))
        await owner.closeProject(); #expect(owner.manifest == nil)
        let reopened = ProjectSession(sessionFactory: factory, settings: settings)
        await reopened.openProject(at: project); await reopened.openWorkflow()
        let c = try #require(reopened.workflow)
        c.selectedGraphID = c.graphs.first?.id
        await c.run(target: id, only: false)
        #expect(c.errorMessage == nil)
        #expect(await engine.requests.last?.model.revision == "A")
        #expect(c.modelChoices.contains { $0.id == "text:A" })
        #expect(c.modelChoices.contains { $0.id == "text:B" })
        await reopened.closeProject(); #expect(reopened.manifest == nil)
    }
}

extension WorkflowLifecycleTests {
    @Test func cancelledModelPreparationReleasesLateLeaseWithoutSubmitting() async throws {
        let (root, store, engine, _) = try await fixture()
        let session = WorkbenchSession(engine: engine, backendID: "image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        let gate = WorkflowSubmitGate(); var released = 0
        let services = WorkflowServices(store: store, session: session) { _, id in
            await gate.wait()
            return .init(identity: id, reference: .init(directory: root), backendID: "fixture", release: { released += 1 })
        }
        var node = try #require(WorkflowRegistry.standard.operation("d.text.rewrite")).definition.makeNode()
        node.parameters["modelID"] = .text("text:A")
        let graph = WorkflowGraph(nodes: [node])
        let work = Task { try await services.prepare(graph, nodes: [node.id]) }
        for _ in 0..<1000 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.entered)
        await services.cancel(); await gate.open()
        do { _ = try await work.value; Issue.record("cancelled preparation accepted") } catch is CancellationError {} catch { Issue.record("unexpected failure") }
        #expect(released == 1); #expect(await engine.requests.isEmpty)
        await services.finish(); #expect(released == 1)
        try await store.close()
    }
    @Test func wrongResolverIdentityAndMissingRecipeDoNotLeakOrFallback() async throws {
        let (root, store, engine, _) = try await fixture()
        let session = WorkbenchSession(engine: engine, backendID: "image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        var released = 0
        let services = WorkflowServices(store: store, session: session) { _, _ in
            .init(identity: "wrong", reference: .init(directory: root), backendID: "fixture", release: { released += 1 })
        }
        var node = try #require(WorkflowRegistry.standard.operation("d.text.rewrite")).definition.makeNode()
        node.parameters["modelID"] = .text("text:A")
        do { _ = try await services.prepare(.init(nodes: [node]), nodes: [node.id]); Issue.record("wrong identity accepted") } catch {}
        #expect(released == 1)
        let image = try #require(WorkflowRegistry.standard.operation("d.image.generate")).definition.makeNode()
        do { _ = try await services.prepare(.init(nodes: [image]), nodes: [image.id]); Issue.record("missing image recipe accepted") } catch {}
        #expect(released == 2); #expect(await engine.requests.isEmpty)
        try await store.close()
    }
}

private actor WorkflowValidationControl {
    var armed = false
    let gate = WorkflowSubmitGate()
    func arm() { armed = true }
    func validate(_ url: URL) async -> ModelReference {
        if armed { await gate.wait() }
        return .init(directory: url, revision: url.lastPathComponent)
    }
}

extension WorkflowLifecycleTests {
    @Test func closeWithWaitDoesNotRejectSecondModelDuringPreparation() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("model-wait-" + UUID().uuidString)
        let a = base.appendingPathComponent("A"), b = base.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let suite = "D.ModelWait." + UUID().uuidString, settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = WorkflowFixtureEngine(directory: base), validation = WorkflowValidationControl()
        let owner = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "text",
                validateTextModel: { url in await validation.validate(url) })
        }, settings: settings)
        await owner.createProject(at: base.appendingPathComponent("test.dproject"))
        await owner.registerTextModel(at: a); await owner.registerTextModel(at: b); await owner.openWorkflow()
        let c = try #require(owner.workflow); c.addExample("text")
        let first = try #require(c.graph?.nodes[1].id)
        c.setParameter(nodeID: first, key: "modelID", value: .text("text:A"))
        c.addNode(operationID: "d.text.rewrite"); let second = try #require(c.selectedNodeID)
        c.setParameter(nodeID: second, key: "modelID", value: .text("text:B"))
        c.connect(source: first, sourcePort: "output", target: second, targetPort: "input")
        await validation.arm()
        let run = Task { await c.run(target: second, only: false) }
        for _ in 0..<1000 { if await validation.gate.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await validation.gate.entered)
        let close = Task { await owner.requestClose(decision: .wait) }
        for _ in 0..<1000 { if owner.isChangingProject { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(owner.isChangingProject)
        await validation.gate.open(); await run.value
        #expect(await close.value)
        #expect(await engine.requests.map { $0.model.revision } == ["A", "B"])
        #expect(c.errorMessage == nil)
    }

    @Test func explicitReplacementCopySurvivesRefreshOfOldDefault() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("model-copy-" + UUID().uuidString)
        let a = base.appendingPathComponent("old-copy"), b = base.appendingPathComponent("new-copy")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let suite = "D.ModelCopy." + UUID().uuidString, settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = WorkflowFixtureEngine(directory: base)
        let owner = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "text",
                validateTextModel: { url in .init(directory: url, revision: "same") })
        }, settings: settings)
        await owner.createProject(at: base.appendingPathComponent("test.dproject"))
        await owner.registerTextModel(at: a); await owner.openWorkflow()
        let c = try #require(owner.workflow); c.addExample("text"); c.selectedNodeID = c.graph?.nodes[1].id
        let target = try #require(c.modelSelectionTarget())
        await owner.registerWorkflowModel(at: b, target: target, controller: c)
        owner.refreshWorkflowModels()
        await c.run(target: target.nodeID, only: false)
        #expect(c.errorMessage == nil)
        let actual = try #require(await engine.requests.last?.model.directory)
        print("BOUNDARY_RELOCATED_MODEL=\(actual.absoluteString), expected=\(b.absoluteString)")
        #expect(actual.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path)
        #expect(actual.resolvingSymlinksInPath().path != a.resolvingSymlinksInPath().path)
        await owner.closeProject()
    }
}

@Suite("Language model Call uses the existing runtime and Store", .serialized) @MainActor
struct WorkflowLanguageServicesTests {
    private let operation = WorkflowOperation(definition: .init(id: "test.language.call", title: "Language", detail: "CPU fixture",
        inputs: [], outputs: [.init("output", "Text", kinds: [.text])], fields: [
            .init("modelID", "Model", .text(multiline: false), .text(""))], modelKind: .text), execute: { c, s in
            let ref = try await s.generateLanguage(task: "Write a short garden idea.", content: nil, context: c)
            return .outputs(["output": .asset(ref)])
        })
    private func root() -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("language-" + UUID().uuidString + ".dproject")
    }
    @Test func freezesWithoutLeasingThenGeneratesWithoutRewriteDraftAndReleases() async throws {
        let store = try await ProjectStore.create(at: root(), name: "language")
        let before = await store.snapshot().draft
        let engine = WorkflowFixtureEngine(directory: store.artifactDirectory)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "text")
        var acquired = 0, released = 0
        let registry = try WorkflowRegistry(operations: [operation])
        let service = WorkflowServices(store: store, session: session, registry: registry, defaultIdentity: { _ in "text:chosen" }) { kind, identity in
            #expect(kind == .text); #expect(identity == "text:chosen"); acquired += 1
            return .init(identity: identity, reference: .init(directory: store.rootURL), backendID: "text", release: { released += 1 })
        }
        let graph = service.freezeModels(in: .init(nodes: [operation.definition.makeNode()]))
        #expect(acquired == 0)
        try service.beginPlan()
        let result = try await service.executeCall(.init(node: graph.nodes[0], stepID: UUID(), inputs: [:]))
        guard case .outputs(let outputs) = result, let ref = outputs["output"]?.asset else { Issue.record("Missing text"); return }
        #expect(try await service.readText(ref).contains("花园"))
        #expect(acquired == 1 && released == 1)
        #expect(await store.snapshot().draft == before)
        let request = try #require(await engine.requests.first)
        guard case .text(let text) = request.input else { Issue.record("wrong modality"); return }
        #expect(text.prompt == "Write a short garden idea.")
        #expect(try await store.workflowState().archive?.assets.first?.request == request)
        try await store.close()
    }
    @Test func publicationRetryDoesNotResolveUnavailableModelOrRegenerate() async throws {
        let store = try await ProjectStore.create(at: root(), name: "save retry")
        let engine = WorkflowFixtureEngine(directory: store.artifactDirectory)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        var acquired = 0
        let service = WorkflowServices(store: store, session: session, registry: try .init(operations: [operation])) { _, identity in
            acquired += 1
            guard acquired == 1 else { throw WorkflowIssue("Model volume is unavailable on retry") }
            return .init(identity: identity, reference: .init(directory: store.rootURL), backendID: "text")
        }
        let moved = store.rootURL.appendingPathExtension("temporarily-unavailable")
        await engine.configure(action: { try FileManager.default.moveItem(at: store.rootURL, to: moved) })
        var node = operation.definition.makeNode(); node.parameters["modelID"] = .text("text:frozen")
        let context = WorkflowExecutionContext(node: node, stepID: UUID(), inputs: [:])
        try service.beginPlan()
        do { _ = try await service.executeCall(context); Issue.record("Expected save failure") }
        catch { #expect(error is WorkflowSaveFailure) }
        #expect(service.hasPendingSaves)
        try FileManager.default.moveItem(at: moved, to: store.rootURL)
        try service.beginPlan()
        _ = try await service.executeCall(context)
        #expect(!service.hasPendingSaves)
        #expect(acquired == 1)
        #expect(await engine.requests.count == 1)
        #expect(await store.snapshot().assets.count == 1)
        try await store.close()
    }
    @Test func verifiedIntegrityFailureIsNotHiddenByConcurrentCancellation() async throws {
        let store = try await ProjectStore.create(at: root(), name: "integrity")
        let engine = WorkflowFixtureEngine(directory: store.artifactDirectory)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        var released = 0
        let service = WorkflowServices(store: store, session: session, registry: try .init(operations: [operation])) { _, identity in
            .init(identity: identity, reference: .init(directory: store.rootURL), backendID: "text", release: { released += 1 })
        }
        await engine.configure(action: { await service.cancel() }, failure: .inputIntegrityChanged("controlled protected input change"))
        var node = operation.definition.makeNode(); node.parameters["modelID"] = .text("text:frozen")
        try service.beginPlan()
        do { _ = try await service.executeCall(.init(node: node, stepID: UUID(), inputs: [:])); Issue.record("Integrity lost") }
        catch { #expect(error as? InferenceFailure == .inputIntegrityChanged("controlled protected input change")) }
        #expect(released == 1)
        #expect(await store.snapshot().assets.isEmpty)
        try await store.close()
    }
    @Test func unconfirmedCleanupIsNotHiddenByConcurrentCancellation() async throws {
        let store = try await ProjectStore.create(at: root(), name: "integrity")
        let engine = WorkflowFixtureEngine(directory: store.artifactDirectory)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        var released = 0
        let service = WorkflowServices(store: store, session: session, registry: try .init(operations: [operation])) { _, identity in
            .init(identity: identity, reference: .init(directory: store.rootURL), backendID: "text", release: { released += 1 })
        }
        await engine.configure(action: { await service.cancel() }, failure: .resourceCleanupUnconfirmed("controlled process group uncertainty"))
        var node = operation.definition.makeNode(); node.parameters["modelID"] = .text("text:frozen")
        try service.beginPlan()
        do { _ = try await service.executeCall(.init(node: node, stepID: UUID(), inputs: [:])); Issue.record("Cleanup uncertainty hidden") }
        catch { #expect(error as? InferenceFailure == .resourceCleanupUnconfirmed("controlled process group uncertainty")) }
        #expect(released == 1)
        #expect(await store.snapshot().assets.isEmpty)
        try await store.close()
    }
    @Test func explicitValueExportFormatsUseActualServiceRoute() async throws {
        let store = try await ProjectStore.create(at: root(), name: "export formats")
        let engine = WorkflowFixtureEngine(directory: store.artifactDirectory)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let service = WorkflowServices(store: store, session: session) { _, _ in throw WorkflowIssue("No model needed") }
        service.destination = store.rootURL.deletingLastPathComponent()
        let ref = try await store.publishWorkflowAsset(data: workflowFixturePNG(), mediaType: "image/png", metadata: .init(width: 16, height: 12), name: "image", operationID: "fixture").record.reference
        var node = try #require(WorkflowRegistry.standard.operation("d.value.export")).definition.makeNode()
        node.parameters["format"] = .text("midi")
        for value in [WorkflowValue.asset(ref), .data(.asset(ref))] {
            do { _ = try await service.executeCall(.init(node: node, stepID: UUID(), inputs: ["input": value])); Issue.record("PNG became MIDI") } catch {}
        }
        node.parameters["format"] = .text("json")
        for value in [WorkflowValue.asset(ref), .data(.asset(ref))] {
            let result = try await service.executeCall(.init(node: node, stepID: UUID(), inputs: ["input": value]))
            guard case .outputs(let outputs) = result, case .receipt(let receipt)? = outputs["output"] else { Issue.record("No receipt"); continue }
            #expect(receipt.names.contains("1.json")); #expect(!receipt.names.contains("1.png"))
        }
        #expect(await engine.requests.isEmpty)
        try await store.close()
    }
    @Test func corruptAudioPublicationIsTerminalNotSaveRetry() async throws {
        let store = try await ProjectStore.create(at: root(), name: "corrupt audio")
        let engine = WorkflowFixtureEngine(directory: store.artifactDirectory)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        let service = WorkflowServices(store: store, session: session) { _, _ in throw WorkflowIssue("No model needed") }
        let node = WorkflowNode(operationID: "d.music.render", title: "corrupt")
        do {
            _ = try await service.publishMedia(Data("bad wave".utf8), mediaType: "audio/wav", parents: [],
                context: .init(node: node, stepID: UUID(), inputs: [:]))
            Issue.record("Corrupt media published")
        } catch { #expect(!(error is WorkflowSaveFailure)) }
        #expect(!service.hasPendingSaves)
        #expect(await store.snapshot().assets.isEmpty)
        try await store.close()
    }
    @Test func wrongModelIdentityAndCancellationAfterResolveReleaseWithoutSubmitting() async throws {
        for mismatch in [false, true] {
            let store = try await ProjectStore.create(at: root(), name: "model guard")
            let engine = WorkflowFixtureEngine(directory: store.artifactDirectory), gate = WorkflowSubmitGate()
            let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
            var released = 0
            let service = WorkflowServices(store: store, session: session, registry: try .init(operations: [operation])) { _, identity in
                if !mismatch { await gate.wait() }
                return .init(identity: mismatch ? "other" : identity, reference: .init(directory: store.rootURL), backendID: "text", release: { released += 1 })
            }
            var node = operation.definition.makeNode(); node.parameters["modelID"] = .text("text:frozen")
            try service.beginPlan()
            let work = Task { try await service.executeCall(.init(node: node, stepID: UUID(), inputs: [:])) }
            if !mismatch {
                for _ in 0..<1000 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
                #expect(await gate.entered)
                await service.cancel(); await gate.open()
            }
            do { _ = try await work.value; Issue.record("Invalid admission succeeded") } catch {}
            #expect(released == 1)
            #expect(await engine.requests.isEmpty)
            #expect(await store.snapshot().assets.isEmpty)
            try await store.close()
        }
    }
}

extension WorkflowLifecycleTests {
    @Test func canvasInsertionSelectionVersionTagsAndUndoAreSafe() async throws {
        let (_, store, engine, c) = try await fixture()
        let published = try await store.publishWorkflowAsset(data: Data("原始素材 👩🏽‍🎨".utf8), mediaType: "text/plain", name: "参考", operationID: "test.input")
        await c.load(); c.addBlankGraph(name: "A")
        let project = try #require(c.projectID)
        let old = try #require(c.canvasInsertionTarget())
        c.addBlankGraph(name: "B")
        await c.addAssetNode(projectID: project, assetID: published.asset.id, x: 30, y: 40, target: old)
        #expect(c.graph?.nodes.isEmpty == true)
        let target = try #require(c.canvasInsertionTarget())
        await c.addAssetNode(projectID: UUID(), assetID: published.asset.id, x: 30, y: 40, target: target)
        #expect(c.graph?.nodes.isEmpty == true)
        await c.addAssetNode(projectID: project, assetID: published.asset.id, x: 30, y: 40, target: target)
        let node = try #require(c.selectedNode)
        #expect(node.assetReference == published.record.reference)
        let revision = try #require(c.rootGraph?.revision)
        c.moveNode(id: node.id, x: -150, y: -120)
        #expect(c.graph?.layout.first?.x == -150)
        #expect(c.graph?.layout.first?.y == -120)
        #expect(c.rootGraph?.revision == revision)
        c.undo(); #expect(c.graph?.layout.first?.x == 30)
        c.redo(); #expect(c.graph?.layout.first?.x == -150)
        try await c.setAssetTags(id: published.asset.id, tags: [" 灵感 ", "👩🏽‍🎨"])
        #expect(c.availableAssets.first?.tags == ["灵感", "👩🏽‍🎨"])
        #expect(try await c.preview(published.record.reference) == Data("原始素材 👩🏽‍🎨".utf8))
        await c.save(); try await c.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(await reopened.snapshot().assets.first?.tags == ["灵感", "👩🏽‍🎨"])
        #expect(try await reopened.workflowState().archive?.graphs.last?.layout.first?.x == -150)
        #expect(await engine.requests.isEmpty)
        try await reopened.close()
    }

    @Test func canvasModelShortcutRejectsWrongKindAndDoesNotRun() async throws {
        let (_, store, engine, c) = try await fixture()
        c.modelChoices = [.init(id: "text:test", kind: .text, displayName: "test")]
        c.addNode(operationID: "d.image.generate", modelID: "text:test")
        #expect(c.graphs.isEmpty)
        c.addNode(operationID: "d.model.language", modelID: "text:test", x: 101, y: 120)
        let node = try #require(c.selectedNode)
        #expect(node.parameters["modelID"]?.string == "text:test")
        #expect(c.graph?.layout.first?.x == 101)
        c.undo(); #expect(c.graphs.isEmpty); c.redo()
        c.externalOperationBusy = { true }
        let before = c.graphs; c.addNode(operationID: "d.text.input"); c.moveNode(id: node.id, x: 1, y: 2)
        #expect(c.graphs == before)
        #expect(await engine.requests.isEmpty)
        c.externalOperationBusy = { false }; try await c.close(); try await store.close()
    }
}
