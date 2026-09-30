import Foundation
import Testing
@testable import DWorkbench

@Suite("Release model shared contracts")
struct ReleaseModelContractTests {
    @Test func orderedAssetPortChecksActualMembersAndPreservesOrder() throws {
        let port = WorkflowPortDefinition("references", "参考图", kinds: [.image, .list], required: false, assetListKind: .image)
        let project = UUID()
        let a = WorkflowAssetReference(projectID: project, assetID: UUID(), kind: .image, sha256: String(repeating: "a", count: 64))
        let b = WorkflowAssetReference(projectID: project, assetID: UUID(), kind: .image, sha256: String(repeating: "b", count: 64))
        #expect(try port.resolveAssets(.asset(a)) == [a])
        let ordered = WorkflowValue.data(.list(element: .asset(.image), items: [.init(value: .asset(b)), .init(value: .asset(a))]))
        #expect(try port.resolveAssets(ordered) == [b, a])
        let invalid: [WorkflowValue] = [
            .data(.list(element: .asset(.image), items: [])),
            .data(.list(element: .text, items: [.init(value: .text("not an image"))])),
            .data(.list(element: .asset(.image), items: [.init(value: .text("false declaration"))]))
        ]
        let operation = WorkflowOperation(definition: .init(id: "fixture.asset-list", title: "Fixture", detail: "CPU", inputs: [port], outputs: []), execute: { _, _ in .outputs([:]) })
        let registry = try WorkflowRegistry(operations: [operation])
        let node = operation.definition.makeNode()
        try registry.validateInputs(["references": ordered], node: node, connectedPorts: [])
        for value in invalid {
            #expect(throws: WorkflowIssue.self) { try registry.validateInputs(["references": value], node: node, connectedPorts: []) }
        }
    }
}
