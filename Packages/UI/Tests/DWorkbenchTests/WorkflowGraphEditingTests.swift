import Foundation
import Testing
@testable import DWorkbench

struct WorkflowGraphEditingTests {
    @Test func nestedEditPreservesOtherBranchAndRejectsStaleAddress() throws {
        let input = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        let yes = WorkflowGraph(name: "yes", nodes: [input]), no = WorkflowGraph(name: "no", nodes: [input])
        var branch = try #require(WorkflowRegistry.standard.operation("d.control.branch")).definition.makeNode()
        branch.control = .branch(predicate: .init(comparison: .exists), then: yes, otherwise: no)
        let root = WorkflowGraph(name: "root", nodes: [branch])
        let path = [WorkflowBodyLocation(nodeID: branch.id, slot: "then")]
        var edited = try WorkflowGraphEditing.body(in: root, path: path)
        edited.nodes[0].title = "中文 👩🏽‍🎨"; edited.revision = UUID()
        let result = try WorkflowGraphEditing.replacingBody(in: root, path: path, with: edited)
        #expect(result.id == root.id); #expect(result.revision != root.revision)
        #expect(try WorkflowGraphEditing.body(in: result, path: path).nodes[0].title == "中文 👩🏽‍🎨")
        #expect(try WorkflowGraphEditing.body(in: result, path: [.init(nodeID: branch.id, slot: "otherwise")]) == no)
        #expect(throws: WorkflowIssue.self) { try WorkflowGraphEditing.body(in: root, path: [.init(nodeID: UUID(), slot: "then")]) }
        #expect(throws: WorkflowIssue.self) { try WorkflowGraphEditing.replacingBody(in: root, path: path, with: .init()) }
    }
}
