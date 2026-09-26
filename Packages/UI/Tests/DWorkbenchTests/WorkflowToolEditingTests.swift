import Foundation
import Testing
@testable import DWorkbench

struct WorkflowToolEditingTests {
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
        let copy = WorkflowToolEditing.editableCopy(of: extracted.tool)
        #expect(copy.id != extracted.tool.graph.id); #expect(copy.nodes == extracted.tool.graph.nodes)
        #expect(throws: WorkflowIssue.self) { try WorkflowToolEditing.extract(graph, selected: [middle.id], name: "bad", inputs: [], outputs: [.init(name: "answer", nodeID: middle.id, schema: .text)], tools: []) }
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
