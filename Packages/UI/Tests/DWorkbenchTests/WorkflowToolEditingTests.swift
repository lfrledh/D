import Foundation
import Testing
@testable import DWorkbench

struct WorkflowToolEditingTests {
    @Test func extractionFailureCodesDescribeActualSelectionAndPortIdentity() throws {
        let registry = WorkflowRegistry.standard
        var input = try #require(registry.operation("d.value.input")).definition.makeNode()
        input.dataConfiguration = .init(value: .text("kept"))
        let node = try #require(registry.operation("d.value.return")).definition.makeNode()
        let graph = WorkflowGraph(nodes: [input, node], connections: [.init(sourceNode: input.id, targetNode: node.id)])
        let output = WorkflowNamedOutput(name: "same", nodeID: node.id, schema: .text)
        let binding = WorkflowToolInputBinding(name: "same", schema: .text, sourceNode: input.id, sourcePort: "output")
        let checks: [(Set<UUID>, [WorkflowToolInputBinding], [WorkflowNamedOutput], String)] = [
            ([], [], [output], "noSelection"),
            ([UUID()], [], [output], "selectionChanged"),
            ([node.id], [binding], [], "noOutputs"),
            ([node.id], [binding, binding], [output], "portConflict"),
            ([node.id], [binding], [output, output], "portConflict")
        ]
        for (selected, inputs, outputs, reason) in checks {
            do {
                _ = try WorkflowToolEditing.extract(graph, selected: selected, name: "Tool", inputs: inputs, outputs: outputs, tools: [])
                Issue.record("Invalid boundary accepted")
            } catch { #expect((error as? WorkflowIssue)?.code == "workflow.language.tools." + reason) }
            #expect(graph.nodes == [input, node] && graph.connections.count == 1)
        }
        let result = try WorkflowToolEditing.extract(graph, selected: [node.id], name: "Tool",
            inputs: [binding], outputs: [output], tools: [],
            registration: .init(purpose: "Purpose", inputLabels: ["same": "Identical label"], outputLabels: ["same": "Identical label"]))
        #expect(result.tool.graph.interface?.inputs.first?.name == "same")
        #expect(result.tool.graph.interface?.outputs.first?.name == "same")
    }
    @Test func selectionBecomesRealFixedToolWithBoundaryMappings() throws {
        let registry = WorkflowRegistry.standard
        var input = try #require(registry.operation("d.value.input")).definition.makeNode(); input.dataConfiguration = .init(value: .text("hello"))
        let middle = try #require(registry.operation("d.value.return")).definition.makeNode()
        let output = try #require(registry.operation("d.value.return")).definition.makeNode()
        let graph = WorkflowGraph(nodes: [input, middle, output], connections: [.init(sourceNode: input.id, targetNode: middle.id), .init(sourceNode: middle.id, targetNode: output.id)])
        let extracted = try WorkflowToolEditing.extract(graph, selected: [middle.id], name: "可编辑", inputs: [.init(name: "content", schema: .text, sourceNode: input.id, sourcePort: "output")], outputs: [.init(name: "answer", nodeID: middle.id, schema: .text)], tools: [])
        let plan = try WorkflowPlanCompiler().compile(extracted.graph, tools: [extracted.tool], target: output.id)
        guard case .invoke(let reference, let body) = plan.steps.first(where: { $0.id == extracted.invocationID })?.kind else { Issue.record("Not a real invoke"); return }
        #expect(reference.digest == (try WorkflowPlanCompiler.digest(extracted.tool)))
        #expect(body.interface.inputs.map(\.name) == ["content"])
        #expect(body.interface.outputs.map(\.name) == ["answer"])
        #expect(graph.nodes.count == 3); #expect(extracted.graph.nodes.count == 3)
        #expect(throws: WorkflowIssue.self) {
            try WorkflowToolEditing.extract(graph, selected: [middle.id], name: "Wrong type",
                inputs: [.init(name: "content", schema: .asset(.text), sourceNode: input.id, sourcePort: "output")],
                outputs: [.init(name: "answer", nodeID: middle.id, schema: .text)], tools: [])
        }
        let copy = WorkflowToolEditing.editableCopy(of: extracted.tool, suffix: "· Editable copy")
        #expect(copy.name == extracted.tool.name + " · Editable copy")
        #expect(copy.id != extracted.tool.graph.id); #expect(copy.nodes == extracted.tool.graph.nodes)
        #expect(throws: WorkflowIssue.self) { try WorkflowToolEditing.extract(graph, selected: [middle.id], name: "bad", inputs: [], outputs: [.init(name: "answer", nodeID: middle.id, schema: .text)], tools: []) }
    }
    @Test func containerPublicationKeepsExactConfiguredOutput() throws {
        let registry = WorkflowRegistry.standard
        var node = try #require(registry.operation(WorkflowAssetContainer.previewID)).definition.makeNode()
        node.dataConfiguration = .init(schema: .asset(.text))
        #expect(WorkflowToolEditing.outputSchemaProposal(for: node, port: "output", registry: registry, tools: []) == .asset(.text))
        let graph = WorkflowGraph(nodes: [node])
        #expect(throws: WorkflowIssue.self) {
            try WorkflowToolEditing.extract(graph, selected: [node.id], name: "Container", inputs: [],
                                            outputs: [.init(name: "item", nodeID: node.id, schema: .text)], tools: [])
        }
    }

    @Test func registrationPreservesOldEncodingAndRejectsInventedPortLabels() throws {
        var graph = WorkflowGraph(name: "old"); graph.interface = .init()
        let original = WorkflowToolDefinition(name: "old", graph: graph)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["registration"] == nil)
        let decoded = try JSONDecoder().decode(WorkflowToolDefinition.self, from: bytes)
        #expect(try WorkflowPlanCompiler.digest(decoded) == WorkflowPlanCompiler.digest(original))
        let invalid = WorkflowToolRegistration(purpose: "Purpose", inputLabels: ["invented": "Name"])
        #expect(throws: WorkflowIssue.self) { try invalid.validate(interface: .init()) }
        var future = WorkflowToolRegistration(purpose: "Purpose"); future.version = 2
        #expect(throws: WorkflowIssue.self) { try future.validate(interface: .init()) }
    }

    @Test func candidateAdapterKeepsFailuresAndExactLargeSeed() throws {
        let asset = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .image, sha256: String(repeating: "a", count: 64))
        let first = WorkflowCandidate(asset: asset, seed: String(UInt64.max)), failure = WorkflowCandidate(error: "controlled failure", seed: "0")
        let converted = try WorkflowCandidateList.convert([first, failure])
        #expect(converted["output"]?.datum?.items?.count == 2)
        #expect(converted["successful"]?.datum?.items?.map(\.id) == [first.id.uuidString])
        #expect(try converted["output"]?.datum?.items?.first?.value.value(at: ["seed"]).text == String(UInt64.max))
        #expect(try WorkflowCandidateList.convert([])["successful"]?.datum?.items?.isEmpty == true)
        #expect(throws: WorkflowIssue.self) { try WorkflowCandidateList.convert([first, first]) }
    }
}
