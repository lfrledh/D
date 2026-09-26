import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow language examples r1") @MainActor
struct WorkflowLanguageExamplesTests {
    @Test func everyExampleCompilesWithUniqueEditableIdentities() throws {
        for example in WorkflowLanguageExample.allCases {
            let bundle = try WorkflowLanguageExamples.make(example)
            _ = try WorkflowPlanCompiler().compile(bundle.graph, tools: bundle.tools)

            let nodes = allNodes(in: bundle)
            let minimumNodes: Int = switch example {
            case .data: 20
            case .images: 14
            case .music: 24
            case .multimodal: 10
            }
            #expect(nodes.count >= minimumNodes)
            #expect(Set(nodes.map(\.id)).count == nodes.count)
            #expect(Set(bundle.tools.map(\.id)).count == bundle.tools.count)
            #expect(bundle.graph.nodes.allSatisfy { !$0.title.isEmpty })
            #expect(nodes.filter { modelOperations.contains($0.operationID) }
                .allSatisfy { $0.parameters["modelID"] == .text("") })
        }
    }

    @Test func toolsHaveFixedDigestsInterfacesAndCanBeInvokedAgain() throws {
        for example in [WorkflowLanguageExample.images, .music] {
            let bundle = try WorkflowLanguageExamples.make(example)
            let invokes = allNodes(in: bundle).compactMap { node -> (WorkflowNode, WorkflowToolReference)? in
                guard case .invoke(let reference) = node.control else { return nil }
                return (node, reference)
            }
            #expect(!bundle.tools.isEmpty)
            #expect(!invokes.isEmpty)
            for (_, reference) in invokes {
                let tool = try #require(bundle.tools.first { $0.id == reference.id && $0.version == reference.version })
                #expect(reference.digest == (try WorkflowPlanCompiler.digest(tool)))
                #expect(!(tool.graph.interface?.inputs.isEmpty ?? true))
                #expect(!(tool.graph.interface?.outputs.isEmpty ?? true))
            }

            let tool = try #require(bundle.tools.first)
            let reference = WorkflowToolReference(
                id: tool.id, version: tool.version, digest: try WorkflowPlanCompiler.digest(tool)
            )
            var first = try registeredNode("d.control.invoke", title: "复用一")
            first.control = .invoke(reference)
            first.dataConfiguration = .init(fields: tool.graph.interface?.inputs ?? [])
            var second = try registeredNode("d.control.invoke", title: "复用二")
            second.control = .invoke(reference)
            second.dataConfiguration = .init(fields: tool.graph.interface?.inputs ?? [])
            _ = try WorkflowPlanCompiler().compile(
                WorkflowGraph(name: "同工具双调用", nodes: [first, second]), tools: [tool]
            )
        }
    }

    @Test func e01CoversDataNodesAndExecutesDynamicMapAndLoopWithoutServices() async throws {
        let bundle = try WorkflowLanguageExamples.make(.data)
        let ids = Set(bundle.graph.nodes.map(\.operationID))
        for expected in [
            "d.value.input", "d.value.record", "d.value.field", "d.value.list", "d.value.filter",
            "d.value.select", "d.value.pair", "d.value.validate", "d.control.branch",
            "d.control.map", "d.control.loop", "d.value.return", "d.value.export",
        ] {
            #expect(ids.contains(expected))
        }

        let target = try #require(bundle.graph.nodes.first { $0.title == "返回数据结果" })
        let plan = try WorkflowPlanCompiler().compile(bundle.graph, tools: bundle.tools, target: target.id)
        #expect(!plan.steps.contains { $0.node.operationID == "d.value.export" })
        let (completed, services) = try await executeDataExample(bundle)
        #expect(completed.state == .completed)
        #expect(services.callCount == 0)

        guard case .data(.record(_, let fields))? = completed.outputs["output"] else {
            Issue.record("E01 should return its typed summary record")
            return
        }
        #expect(fields["approved"] == .boolean(true))
        #expect(fields["loopState"] == .number(3, unit: nil))
        #expect(fields["mapped"]?.items?.count == 2)
        #expect(fields["pairs"]?.items?.count == 2)
        guard case .list(_, let mapped)? = fields["mapped"] else {
            Issue.record("E01 should retain mapped item identities")
            return
        }
        #expect(mapped.map(\.id) == ["featured", "item-1"])
        #expect(mapped.compactMap(successfulText) == ["重点版本", "基础版本"])
    }

    @Test func e01EditableBadItemFailsOnlyItsMapPosition() async throws {
        var bundle = try WorkflowLanguageExamples.make(.data)
        let listIndex = try #require(bundle.graph.nodes.firstIndex { $0.operationID == "d.value.list" })
        var configuration = try #require(bundle.graph.nodes[listIndex].dataConfiguration)
        let badIndex = try #require(configuration.items.firstIndex { $0.id == "item-3" })
        guard case .record(let schema, var fields) = configuration.items[badIndex].value else {
            Issue.record("E01 bad fixture should remain a valid same-schema record")
            return
        }
        fields["keep"] = .boolean(true)
        configuration.items[badIndex].value = .record(schema: schema, fields: fields)
        bundle.graph.nodes[listIndex].dataConfiguration = configuration

        let (completed, services) = try await executeDataExample(bundle)
        #expect(completed.state == .completed)
        #expect(services.callCount == 0)
        guard case .data(.record(_, let summary))? = completed.outputs["output"],
              case .list(_, let mapped)? = summary["mapped"] else {
            Issue.record("E01 should return Map results after one controlled item failure")
            return
        }
        #expect(mapped.map(\.id) == ["item-3", "featured", "item-1"])
        let statuses = mapped.compactMap { item -> WorkflowDataOutcome? in
            guard case .result(let result) = item.value else { return nil }
            return result.status
        }
        #expect(statuses == [.failed, .success, .success])
        guard case .result(let failed) = mapped[0].value else {
            Issue.record("First mapped item should be the controlled failure")
            return
        }
        #expect(failed.value == nil)
        #expect(failed.issues.count == 1)
        #expect(mapped.compactMap(successfulText) == ["重点版本", "基础版本"])
    }

    @Test func e02PlansOnceGeneratesThreeAndPreservesEveryCandidateBeforeProcessingSuccesses() throws {
        let bundle = try WorkflowLanguageExamples.make(.images)
        let all = allNodes(in: bundle)
        #expect(all.filter { $0.operationID == "d.model.language" }.count == 1)
        #expect(all.filter { $0.operationID == "d.image.generate" }.count == 1)
        #expect(all.first { $0.operationID == "d.image.generate" }?.parameters["count"] == .integer(3))
        #expect(bundle.graph.nodes.contains { $0.operationID == "d.control.map" })
        #expect(!containsDefaultHuman(in: bundle))

        let tool = try #require(bundle.tools.first)
        let bridge = try #require(tool.graph.nodes.first { $0.operationID == "d.value.candidates" })
        let processingMap = try #require(tool.graph.nodes.first { $0.operationID == "d.control.map" })
        let record = try #require(tool.graph.nodes.first { $0.operationID == "d.value.record" })
        #expect(tool.graph.connections.contains {
            $0.sourceNode == bridge.id && $0.sourcePort == "output" &&
            $0.targetNode == record.id && $0.targetPort == "candidates"
        })
        #expect(tool.graph.connections.contains {
            $0.sourceNode == bridge.id && $0.sourcePort == "successful" &&
            $0.targetNode == processingMap.id && $0.targetPort == "input"
        })
        guard case .map(let processingBody, _) = processingMap.control else {
            Issue.record("E02 successful candidates must enter a real Map")
            return
        }
        #expect(processingBody.nodes.contains { $0.operationID == "d.image.resize" })
        #expect(processingBody.nodes.contains { $0.operationID == "d.image.convert" })
    }

    @Test func e03HasOnlyIntentionalHumanEditsAndWiresRealNotesAndChordsIntoMRT2() throws {
        let bundle = try WorkflowLanguageExamples.make(.music)
        let all = allNodes(in: bundle)
        let humans = all.filter { $0.operationID == "d.control.human" }
        #expect(humans.count == 2)
        #expect(humans.allSatisfy { $0.parameters["kind"] == .text("editMusic") })
        #expect(!all.contains { ["d.asset.choose", "d.text.confirm"].contains($0.operationID) })
        #expect(all.contains { $0.operationID == "d.audio.trim" })
        #expect(all.contains { $0.operationID == "d.audio.convert" })
        #expect(all.contains { $0.operationID == "d.music.pitch" })
        #expect(all.contains { $0.operationID == "d.music.align" })
        #expect(all.contains { $0.operationID == "d.music.keys" })
        #expect(all.contains { $0.operationID == "d.music.chords" })
        #expect(all.contains { $0.operationID == "d.music.render" })

        let tool = try #require(bundle.tools.first)
        let generator = try #require(tool.graph.nodes.first { $0.operationID == "d.music.generate" })
        let incoming = tool.graph.connections.filter { $0.targetNode == generator.id }
        #expect(Set(incoming.map(\.targetPort)) == Set(["prompt", "notes", "chords"]))
        #expect(generator.parameters["modelID"] == .text(""))

        let topMap = try #require(bundle.graph.nodes.first { $0.operationID == "d.control.map" })
        guard case .map(let body, _) = topMap.control else {
            Issue.record("E03 needs a real Map for three editable candidate intentions")
            return
        }
        #expect(body.graphInputNames == Set(["item", "notes", "chords"]))

        let target = try #require(bundle.graph.nodes.first { $0.title == "返回音乐候选" })
        let targetPlan = try WorkflowPlanCompiler().compile(bundle.graph, tools: bundle.tools, target: target.id)
        let plannedIDs = Set(targetPlan.steps.map { $0.node.operationID })
        #expect(plannedIDs.contains("d.music.keys"))
        #expect(plannedIDs.contains("d.music.chords"))
        #expect(plannedIDs.contains("d.music.render"))
        let delivery = try #require(bundle.graph.nodes.first { $0.title == "组合候选、调性与试听版本" })
        #expect(Set(bundle.graph.connections.filter { $0.targetNode == delivery.id }.map(\.targetPort)) == Set([
            "candidates", "keySuggestions", "referenceAudio", "melody", "chords",
        ]))
    }

    @Test func e04ReturnsFullTypedCandidatesAndKeepsVideoTextOnly() throws {
        let bundle = try WorkflowLanguageExamples.make(.multimodal)
        let graph = bundle.graph
        #expect(!containsDefaultHuman(in: bundle))
        for modelID in ["d.model.language", "d.image.generate", "d.music.generate", "d.video.generate"] {
            #expect(graph.nodes.contains { $0.operationID == modelID })
        }

        let bridge = try #require(graph.nodes.first { $0.operationID == "d.value.candidates" })
        let record = try #require(graph.nodes.first { $0.operationID == "d.value.record" })
        #expect(graph.connections.contains {
            $0.sourceNode == bridge.id && $0.sourcePort == "output" &&
            $0.targetNode == record.id && $0.targetPort == "imageCandidates"
        })

        let video = try #require(graph.nodes.first { $0.operationID == "d.video.generate" })
        let videoInputs = graph.connections.filter { $0.targetNode == video.id }
        #expect(videoInputs.map(\.targetPort) == ["prompt"])
        let sourceIDs = Set(videoInputs.map(\.sourceNode))
        #expect(graph.nodes.filter { sourceIDs.contains($0.id) }.allSatisfy { $0.operationID != "d.image.generate" })
    }

    private let modelOperations = Set([
        "d.model.language", "d.image.generate", "d.music.pitch", "d.music.generate", "d.video.generate",
    ])

    private func containsDefaultHuman(in bundle: WorkflowLanguageExampleBundle) -> Bool {
        allNodes(in: bundle).contains {
            ["d.control.human", "d.asset.choose", "d.text.confirm"].contains($0.operationID)
        }
    }

    private func allNodes(in bundle: WorkflowLanguageExampleBundle) -> [WorkflowNode] {
        recursiveNodes(in: bundle.graph) + bundle.tools.flatMap { recursiveNodes(in: $0.graph) }
    }

    private func recursiveNodes(in graph: WorkflowGraph) -> [WorkflowNode] {
        graph.nodes + graph.nodes.flatMap { node -> [WorkflowNode] in
            switch node.control {
            case .branch(_, let yes, let no): recursiveNodes(in: yes) + recursiveNodes(in: no)
            case .map(let body, _), .loop(let body, _, _, _): recursiveNodes(in: body)
            case .invoke, nil: []
            }
        }
    }

    @Test(arguments: [false, true]) func rootExternalInputsNeverLeakIntoSameIDInsideTool(wired: Bool) async throws {
        let registry = WorkflowRegistry.standard, sharedID = UUID()
        let fields: [WorkflowRecordField] = [.init("v", .text)]
        let localFields: [WorkflowRecordField] = [.init("v", .text, required: false)]
        var argument = try registeredNode("d.value.input", title: "Public argument")
        argument.parameters["publicName"] = .text("v"); argument.dataConfiguration = .init(value: .text("template"))
        var inner = try registeredNode("d.value.input", title: "Inner")
        inner.dataConfiguration = .init(value: .text("inner"))
        var record = try registeredNode("d.value.record", title: "Local record")
        record.id = sharedID
        record.dataConfiguration = .init(value: .record(schema: localFields, fields: ["v": .text("inner")]), fields: localFields)
        var body = WorkflowGraph(nodes: [argument, inner, record], connections: wired ? [.init(sourceNode: inner.id, targetNode: record.id, targetPort: "v")] : [])
        body.interface = .init(inputs: fields, outputs: [.init(name: "output", nodeID: record.id, schema: .record(localFields))])
        let tool = WorkflowToolDefinition(name: "Overlapping local ID", graph: body)
        var invocation = try registeredNode("d.control.invoke", title: "Root invocation")
        invocation.id = sharedID; invocation.dataConfiguration = .init(fields: fields)
        invocation.control = .invoke(.init(id: tool.id, version: 1, digest: try WorkflowPlanCompiler.digest(tool)))
        let plan = try WorkflowPlanCompiler().compile(.init(nodes: [invocation]), tools: [tool], target: invocation.id, only: true)
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.externalInputs[sharedID] = ["v": .data(.text("outer"))]
        let services = RejectingExampleServices()
        let executor = WorkflowPlanExecutor(executeCall: { context in
            try await #require(registry.operation(context.node.operationID)).execute(context, services)
        }, save: { snapshot in try WorkflowCheckpointValidation.validate(snapshot, expected: plan) })
        let result = try await executor.execute(checkpoint)
        #expect(result.state == .completed && services.callCount == 0)
        let root = try #require(result.records.first { $0.address.path.count == 1 })
        let nested = try #require(result.records.first { $0.address.path.count > 1 && $0.step.node.id == sharedID })
        #expect(root.step.inputs["v"] == .data(.text("outer")))
        #expect(nested.step.inputs == (wired ? ["v": .data(.text("inner"))] : [:]))
        #expect(nested.step.outputs["output"]?.datum == .record(schema: localFields, fields: ["v": .text("inner")]))
    }


    private func registeredNode(_ operationID: String, title: String) throws -> WorkflowNode {
        guard let operation = WorkflowRegistry.standard.operation(operationID) else {
            throw WorkflowIssue("Missing registered operation \(operationID)")
        }
        var node = operation.definition.makeNode()
        node.title = title
        return node
    }

    private func executeDataExample(
        _ bundle: WorkflowLanguageExampleBundle
    ) async throws -> (WorkflowPlanCheckpoint, RejectingExampleServices) {
        let target = try #require(bundle.graph.nodes.first { $0.title == "返回数据结果" })
        let plan = try WorkflowPlanCompiler().compile(bundle.graph, tools: bundle.tools, target: target.id)
        let services = RejectingExampleServices()
        let registry = WorkflowRegistry.standard
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            guard let operation = registry.operation(context.node.operationID) else {
                throw WorkflowIssue("测试遇到未注册操作。")
            }
            return try await operation.execute(context, services)
        }, save: { _ in })
        return (try await executor.execute(.init(plan: plan)), services)
    }

    private func successfulText(_ item: WorkflowDataItem) -> String? {
        guard case .result(let result) = item.value,
              result.status == .success,
              case .text(let value)? = result.value else { return nil }
        return value
    }
}

private extension WorkflowGraph {
    var graphInputNames: Set<String> { Set(interface?.inputs.map(\.name) ?? []) }
}

@MainActor private final class RejectingExampleServices: WorkflowOperationServices {
    private(set) var callCount = 0

    private func unexpected<T>(_ name: String) throws -> T {
        callCount += 1
        throw WorkflowIssue("E01 unexpectedly called \(name).")
    }

    func readText(_ reference: WorkflowAssetReference) async throws -> String { try unexpected("readText") }
    func verifyAsset(_ reference: WorkflowAssetReference) async throws { try unexpected("verifyAsset") as Void }
    func publishText(
        _ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference { try unexpected("publishText") }
    func rewriteText(
        _ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference { try unexpected("rewriteText") }
    func generateImages(
        prompt: String, reference: WorkflowAssetReference?, context: WorkflowExecutionContext
    ) async throws -> [WorkflowCandidate] { try unexpected("generateImages") }
    func transformImage(
        _ reference: WorkflowAssetReference, context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference { try unexpected("transformImage") }
    func export(
        _ value: WorkflowValue, context: WorkflowExecutionContext
    ) async throws -> WorkflowExportReceipt { try unexpected("export") }
}
