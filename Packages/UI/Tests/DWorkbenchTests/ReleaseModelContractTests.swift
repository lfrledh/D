import Foundation
import DInference
import Testing
@testable import DWorkbench

@Suite("Release model shared contracts")
struct ReleaseModelContractTests {
    @Test func releaseContractsUseRealNamesAndOrderedVisualPorts() throws {
        let registry = WorkflowRegistry.standard
        for (id, name) in [(WorkflowModelRoutes.qwen35, "Qwen3.5-9B"), (WorkflowModelRoutes.qwen38, "Qwen3.8-27B")] {
            let definition = try #require(registry.operation(id)?.definition)
            #expect(definition.title == name)
            #expect(definition.inputs.first { $0.id == "images" }?.assetListKind == .image)
            let videoPort = try #require(definition.inputs.first { $0.id == "video" })
            #expect(videoPort.kinds == [.video, .list] && videoPort.assetListKind == .video)
            let single = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .video, sha256: String(repeating: "a", count: 64))
            #expect(try videoPort.resolveAssets(.asset(single)) == [single])
            try registry.validate(definition.makeNode())
        }
        for id in ["d.image.generate", WorkflowModelRoutes.fluxDev] {
            let definition = try #require(registry.operation(id)?.definition)
            #expect(definition.title.hasPrefix("FLUX.2-"))
            #expect(definition.inputs.first { $0.id == "ref" }?.assetListKind == .image)
            try registry.validate(definition.makeNode())
        }
    }
    @Test func descriptiveReleasePortsComeFromExecutableDefinitions() throws {
        for descriptor in ReleaseModelDescriptors.entries {
            let projection = try #require(descriptor.operations.first)
            let definition = try #require(WorkflowRegistry.standard.operation(projection.id)?.definition)
            #expect(projection.inputs.map(\.id) == definition.inputs.map(\.id))
            #expect(projection.outputs.map(\.id) == definition.outputs.map(\.id))
            #expect(projection.parameters.map(\.id) == definition.fields.map(\.id))
            #expect(descriptor.availability == .evaluation)
        }
    }
    @Test func recipesPreserveAllReferencesAndRejectCrossFamilyProfile() throws {
        let refs = ["a", "b"].map { value in ImageReference(url: URL(fileURLWithPath: "/fixture/" + value + ".rgb"),
            sha256: String(repeating: value, count: 64), byteCount: 512 * 512 * 3, width: 512, height: 512) }
        let registry = WorkflowRegistry.standard
        for (id, recipe) in [("d.image.generate", WorkflowImageRecipe.klein(capability: .scalableKlein4B)),
                              (WorkflowModelRoutes.fluxDev, WorkflowImageRecipe.fluxDev(capability: .flux2Dev))] {
            let node = try #require(registry.operation(id)?.definition.makeNode())
            let request = try recipe.request(node: node, prompt: "ordered", seed: 42, references: refs)
            #expect(try request.resolvedReferences() == refs)
            if id == WorkflowModelRoutes.fluxDev {
                #expect(request.guidanceScale == 4 && request.steps == 50)
                let capability = ImageExecutionCapability.flux2Dev
                try capability.validate(request)
                #expect(capability.supportsReferenceImage)
                #expect(capability.contract.inputRoles.contains(.image))
                #expect(registry.operation(id)?.definition.inputs.contains { $0.assetListKind == .image } == true)
            }
        }
        let duplicate = WorkflowDataItem(value: .asset(.init(projectID: UUID(), assetID: UUID(), kind: .image, sha256: String(repeating: "a", count: 64))))
        let port = WorkflowPortDefinition("ref", "", kinds: [.image, .list], assetListKind: .image)
        #expect(throws: WorkflowIssue.self) { try port.resolveAssets(.data(.list(element: .asset(.image), items: [duplicate, duplicate]))) }
    }
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
