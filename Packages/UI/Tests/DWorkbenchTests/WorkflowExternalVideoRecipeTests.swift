import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("External video node recipes")
struct WorkflowExternalVideoRecipeTests {
    @Test func registeredNodesFreezeDistinctProfilesAndStreamingDoesNotChangeNumerics() throws {
        let registry = WorkflowRegistry.standard
        var identities = Set<String>()
        for profile in ExternalVideoExecutionProfile.allCases {
            let recipe = WorkflowVideoRecipe(profile: profile)
            let definition = try #require(registry.operation(recipe.operationID)?.definition)
            var node = definition.makeNode()
            try registry.validate(node)
            let prompt = "原文 👩🏽‍🎨 e\u{301} — unchanged"
            let streamed = try recipe.request(node: node, prompt: prompt, seed: 42)
            node.parameters["streamWeights"] = .flag(false)
            let resident = try recipe.request(node: node, prompt: prompt, seed: 42)
            #expect(streamed.prompt == prompt && resident.prompt == prompt)
            #expect(streamed.executionProfile == profile.reference)
            #expect(resident.executionProfile == profile.reference)
            #expect(streamed.width == resident.width && streamed.height == resident.height)
            #expect(streamed.frameCount == resident.frameCount && streamed.steps == resident.steps)
            #expect(streamed.seed == resident.seed && streamed.guidanceScale == resident.guidanceScale)
            #expect(streamed.frameRate == resident.frameRate)
            if profile == .h3BF16Full {
                #expect(streamed.adapterOptions == .h3(streamWeights: true))
                #expect(resident.adapterOptions == .h3(streamWeights: false))
            } else {
                #expect(streamed.adapterOptions == .ltx(streamWeights: true, spatiotemporalGuidance: 0))
                #expect(resident.adapterOptions == .ltx(streamWeights: false, spatiotemporalGuidance: 0))
            }
            #expect(identities.insert(profile.modelIdentity).inserted)
            #expect(definition.fields.contains { $0.id == "streamWeights" })
            #expect(definition.outputs.map(\.kinds) == [[.video]])
        }
    }

    @Test func invalidAndMissingParametersNeverSubstituteDefaults() throws {
        let registry = WorkflowRegistry.standard
        for profile in ExternalVideoExecutionProfile.allCases {
            let recipe = WorkflowVideoRecipe(profile: profile)
            let definition = try #require(registry.operation(recipe.operationID)?.definition)
            var node = definition.makeNode()
            node.parameters["streamWeights"] = nil
            #expect(throws: (any Error).self) { try recipe.request(node: node, prompt: "p", seed: 42) }
            node = definition.makeNode()
            node.parameters["width"] = .integer(257)
            #expect(throws: (any Error).self) { try registry.validate(node) }
            node = definition.makeNode()
            node.parameters["frameCount"] = .integer(2)
            #expect(throws: (any Error).self) { try registry.validate(node) }
        }
    }

    @Test @MainActor func legacyWanBindingRemainsWithoutAnExternalRecipe() throws {
        let binding = WorkflowModelBinding(identity: "video:wan-fixture",
            reference: .init(directory: URL(fileURLWithPath: "/fixture-only/wan")), backendID: "fixture.wan")
        #expect(binding.videoRecipe == nil)
        let old = try #require(WorkflowRegistry.standard.operation("d.video.generate")?.definition).makeNode()
        #expect(old.parameters["streamWeights"] == nil)
        try WorkflowRegistry.standard.validate(old)
    }
}
