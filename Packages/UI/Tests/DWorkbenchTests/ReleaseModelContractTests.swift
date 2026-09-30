import Foundation
import DInference
import Testing
@testable import DWorkbench

@Suite("Release model shared contracts")
struct ReleaseModelContractTests {
    @Test func assetListSchemaRejectsContradictorySingleKindAndUnsupportedOutputAnnotation() throws {
        let contradictory = WorkflowPortDefinition("input", "Input", kinds: [.audio, .list], assetListKind: .image)
        let typed = WorkflowPortDefinition("output", "Output", kinds: [.list], assetListKind: .image)
        for definition in [
            WorkflowOperationDefinition(id: "fixture.bad-kind", title: "Fixture", detail: "CPU", inputs: [contradictory], outputs: []),
            WorkflowOperationDefinition(id: "fixture.output", title: "Fixture", detail: "CPU", inputs: [], outputs: [typed])
        ] {
            #expect(throws: WorkflowIssue.self) { try WorkflowRegistry(operations: [
                WorkflowOperation(definition: definition, execute: { _, _ in .outputs([:]) })]) }
        }
    }
    @Test func videoFramePortsAndRecipePreserveIndependentConditions() throws {
        let registry = WorkflowRegistry.standard
        let frame = VideoFrameReference(url: URL(fileURLWithPath: "/isolated/first.png"), width: 64, height: 64,
            byteCount: 123, contentSHA256: String(repeating: "a", count: 64))
        for profile in ExternalVideoExecutionProfile.allCases {
            let recipe = WorkflowVideoRecipe(profile: profile)
            let definition = try #require(registry.operation(recipe.operationID)?.definition)
            #expect(definition.inputs.contains { $0.id == "firstFrame" && !$0.required })
            #expect(definition.inputs.contains { $0.id == "lastFrame" } == (profile == .h3BF16Full))
            let node = definition.makeNode()
            let request = try recipe.request(node: node, prompt: "Unchanged prompt", seed: 42, firstFrame: frame)
            #expect(request.firstFrame == frame)
            #expect(request.lastFrame == nil)
            if profile == .h3BF16Full {
                #expect(try recipe.request(node: node, prompt: "Unchanged prompt", seed: 42, lastFrame: frame).lastFrame == frame)
            } else {
                #expect(throws: (any Error).self) { try recipe.request(node: node, prompt: "Unchanged prompt", seed: 42, lastFrame: frame) }
            }
        }
        #expect(!registry.operation("d.video.generate")!.definition.inputs.contains { $0.kinds.contains(.image) })
    }
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
