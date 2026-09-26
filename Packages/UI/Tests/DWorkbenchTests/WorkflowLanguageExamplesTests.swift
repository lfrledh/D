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
        #expect(all.filter { $0.operationID == "d.model.language" }.count == 2)
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
        #expect(body.graphInputNames == Set(["item", "notes", "chords", "optimizeStyle"]))
        #expect(all.filter { $0.operationID == "d.control.human" }.count == 2)
        #expect(all.filter { $0.operationID == "d.model.language" }.count == 2)

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

    @Test func e03HarmonyProposalBranchIsLazyAndFallbackPreservesProvidedTrack() async throws {
        let bundle = try WorkflowLanguageExamples.make(.music)
        let branch = try #require(bundle.graph.nodes.first { $0.title == "按开关选择和弦来源" })
        let request = try #require(bundle.graph.nodes.first { $0.title == "组合和弦提案条件" })
        var suppliedTrack = try WorkflowChordTrack(datum: #require(bundle.graph.nodes.first {
            $0.title == "输入明确和弦"
        }?.dataConfiguration?.value))
        suppliedTrack.chords[0].root = 9
        suppliedTrack.chords[0].id = "user-chord"
        suppliedTrack.sources = [fixtureSource()]
        let supplied = try suppliedTrack.datum()
        let defaultFlag = try #require(bundle.graph.nodes.first {
            $0.title == "可选语言模型和弦提案"
        }?.dataConfiguration?.value)
        #expect(defaultFlag == .boolean(false))
        let requestFields = try #require(request.dataConfiguration?.fields)
        let plan = try WorkflowPlanCompiler().compile(
            bundle.graph, tools: bundle.tools, target: branch.id, only: true
        )

        let unavailable = MusicExampleServices(languageAvailable: false)
        let fallback = WorkflowDatum.record(schema: requestFields, fields: [
            "flag": defaultFlag, "chords": supplied,
        ])
        let fallbackResult = try await executeExamplePlan(
            plan, services: unavailable, externalInputs: [branch.id: ["input": .data(fallback)]]
        )
        #expect(fallbackResult.state == .completed)
        #expect(fallbackResult.outputs["output"]?.datum == supplied)
        #expect(unavailable.languageCallCount == 0)

        let available = MusicExampleServices(languageAvailable: true)
        let proposal = WorkflowDatum.record(schema: requestFields, fields: [
            "flag": .boolean(true), "chords": supplied,
        ])
        let proposalResult = try await executeExamplePlan(
            plan, services: available, externalInputs: [branch.id: ["input": .data(proposal)]]
        )
        let proposed = try #require(proposalResult.outputs["output"]?.datum)
        try proposed.validate(as: WorkflowChordTrack.schema)
        let proposedTrack = try WorkflowChordTrack(datum: proposed)
        #expect(proposedTrack.tempo?.beatsPerMinute == 120)
        #expect(proposed != supplied)
        #expect(available.languageCallCount == 1)
    }

    @Test func e03StyleBranchCallsLanguageOnlyWhenSelectedAndNeverChangesConditions() async throws {
        let bundle = try WorkflowLanguageExamples.make(.music)
        let topMap = try #require(bundle.graph.nodes.first { $0.operationID == "d.control.map" })
        guard case .map(let body, _) = topMap.control else {
            Issue.record("E03 should expose its real candidate Map body")
            return
        }
        let plan = try WorkflowPlanCompiler().compile(body, tools: bundle.tools)
        let originalStyle = WorkflowDatum.text("Unchanged editable style")
        var suppliedNotes = try WorkflowNoteSequence(datum: publicValue("notes", in: body))
        suppliedNotes.notes[0].pitch = 81
        suppliedNotes.notes[0].id = "user-note"
        suppliedNotes.sources = [fixtureSource()]
        var suppliedChords = try WorkflowChordTrack(datum: publicValue("chords", in: body))
        suppliedChords.chords[0].root = 9
        suppliedChords.chords[0].id = "user-chord"
        suppliedChords.sources = suppliedNotes.sources
        let notes = try suppliedNotes.datum()
        let chords = try suppliedChords.datum()
        let defaultOptimization = try publicValue("optimizeStyle", in: body)
        #expect(defaultOptimization == .boolean(false))

        let unavailable = MusicExampleServices(languageAvailable: false)
        let plain = try await executeExamplePlan(plan, services: unavailable, arguments: [
            "item": originalStyle,
            "notes": notes,
            "chords": chords,
            "optimizeStyle": defaultOptimization,
        ])
        #expect(plain.state == .completed)
        #expect(unavailable.languageCallCount == 0)
        #expect(unavailable.musicRequests.map(\.prompt) == ["Unchanged editable style"])
        #expect(unavailable.musicInputs.map(\.notes) == [notes])
        #expect(unavailable.musicInputs.map(\.chords) == [chords])

        let available = MusicExampleServices(languageAvailable: true)
        let optimized = try await executeExamplePlan(plan, services: available, arguments: [
            "item": originalStyle,
            "notes": notes,
            "chords": chords,
            "optimizeStyle": .boolean(true),
        ])
        #expect(optimized.state == .completed)
        #expect(available.languageCallCount == 1)
        #expect(available.musicRequests.map(\.prompt) == ["Optimized style: Unchanged editable style"])
        #expect(available.musicInputs.map(\.notes) == [notes])
        #expect(available.musicInputs.map(\.chords) == [chords])
        #expect(available.musicRequests.allSatisfy { $0.noteSequence != nil })
    }

    @Test func harmonyProposalTransmitsAParseableCompleteContract() throws {
        let bundle = try WorkflowLanguageExamples.make(.music)
        let proposal = try #require(allNodes(in: bundle).first { $0.title == "可选和弦结构提案" })
        let task = try #require(proposal.parameters["task"]?.string)
        let exampleLine = try #require(task.split(separator: "\n").first { $0.hasPrefix("{\"format\":") })
        let decoded = try WorkflowStructuredText.parse(String(exampleLine), as: WorkflowChordTrack.schema)
        let track = try WorkflowChordTrack(datum: decoded)
        #expect(track.duration == 8)
        #expect(track.tempo?.beatsPerMinute == 120)
        #expect(track.chords.count == 2)
        #expect(track.sources.isEmpty)
        for quality in WorkflowChordQuality.allCases { #expect(task.contains(quality.rawValue)) }
    }

    private func fixtureSource() -> WorkflowAssetReference {
        .init(projectID: UUID(), assetID: UUID(), version: UUID(), kind: .audio,
              sha256: String(repeating: "a", count: 64))
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

    private func executeExamplePlan(
        _ plan: WorkflowPlan,
        services: any WorkflowOperationServices,
        arguments: [String: WorkflowDatum] = [:],
        externalInputs: [UUID: [String: WorkflowValue]] = [:]
    ) async throws -> WorkflowPlanCheckpoint {
        let registry = WorkflowRegistry.standard
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            guard let operation = registry.operation(context.node.operationID) else {
                throw WorkflowIssue("测试遇到未注册操作。")
            }
            return try await operation.execute(context, services)
        }, save: { _ in })
        var checkpoint = WorkflowPlanCheckpoint(plan: plan, arguments: arguments)
        checkpoint.externalInputs = externalInputs
        return try await executor.execute(checkpoint)
    }

    private func publicValue(_ name: String, in graph: WorkflowGraph) throws -> WorkflowDatum {
        try #require(graph.nodes.first {
            $0.operationID == "d.value.input" && $0.parameters["publicName"]?.string == name
        }?.dataConfiguration?.value)
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

@MainActor private final class MusicExampleServices: WorkflowOperationServices {
    struct MusicInputs {
        var notes: WorkflowDatum?
        var chords: WorkflowDatum?
    }

    let languageAvailable: Bool
    private(set) var languageCallCount = 0
    private(set) var musicRequests: [AudioRequest] = []
    private(set) var musicInputs: [MusicInputs] = []
    private var textByAsset: [UUID: String] = [:]

    init(languageAvailable: Bool) {
        self.languageAvailable = languageAvailable
    }

    func generateLanguage(
        task: String,
        content: String?,
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        languageCallCount += 1
        guard languageAvailable else { throw WorkflowIssue("Text backend must not be consulted on the false branch.") }
        let text: String
        if context.node.parameters["outputMode"] == .text("json") {
            text = """
            {
              "format": "d.music.chords",
              "version": 1,
              "duration": 8,
              "chords": [
                {"id":"1","root":2,"quality":"minor","octave":4,"inversion":0,"start":0,"end":8}
              ],
              "tempo": {
                "format": "d.music.tempo",
                "version": 1,
                "beatsPerMinute": 120,
                "firstBeatSeconds": 0,
                "numerator": 4,
                "denominator": 4
              },
              "sources": []
            }
            """
        } else {
            text = "Optimized style: \(content ?? "")"
        }
        let reference = makeReference(kind: .text)
        textByAsset[reference.assetID] = text
        return reference
    }

    func readText(_ reference: WorkflowAssetReference) async throws -> String {
        guard let text = textByAsset[reference.assetID] else { throw WorkflowIssue("Unknown fake text asset.") }
        return text
    }

    func generateMusic(
        _ request: AudioRequest,
        parents: [WorkflowAssetReference],
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        musicRequests.append(request)
        musicInputs.append(.init(
            notes: context.inputs["notes"]?.datum,
            chords: context.inputs["chords"]?.datum
        ))
        return makeReference(kind: .audio)
    }

    func verifyAsset(_ reference: WorkflowAssetReference) async throws {
        throw WorkflowIssue("Unexpected verifyAsset in music example fixture.")
    }

    func publishText(
        _ text: String,
        parents: [WorkflowAssetReference],
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        throw WorkflowIssue("Unexpected publishText in music example fixture.")
    }

    func rewriteText(
        _ text: String,
        parents: [WorkflowAssetReference],
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        throw WorkflowIssue("Unexpected rewriteText in music example fixture.")
    }

    func generateImages(
        prompt: String,
        reference: WorkflowAssetReference?,
        context: WorkflowExecutionContext
    ) async throws -> [WorkflowCandidate] {
        throw WorkflowIssue("Unexpected generateImages in music example fixture.")
    }

    func transformImage(
        _ reference: WorkflowAssetReference,
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        throw WorkflowIssue("Unexpected transformImage in music example fixture.")
    }

    func export(
        _ value: WorkflowValue,
        context: WorkflowExecutionContext
    ) async throws -> WorkflowExportReceipt {
        throw WorkflowIssue("Unexpected export in music example fixture.")
    }

    private func makeReference(kind: WorkflowDataKind) -> WorkflowAssetReference {
        .init(
            projectID: UUID(), assetID: UUID(), kind: kind,
            sha256: String(repeating: "a", count: 64)
        )
    }
}
