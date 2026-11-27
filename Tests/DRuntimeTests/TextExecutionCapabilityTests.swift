import DInference
import Foundation
import Testing

@Suite("Text execution capability")
struct TextExecutionCapabilityTests {
    private let capability = TextExecutionCapability(maximumPromptTokens: 2048,
                                                     maximumOutputTokens: 256)

    @Test func samplingRoundTripAndMissingFieldsPreserveLegacyMeaning() throws {
        let old = Data(#"{"prompt":"legacy","maxTokens":256,"temperature":0.7,"topP":0.95}"#.utf8)
        let legacy = try JSONDecoder().decode(TextRequest.self, from: old)
        #expect(legacy.topK == nil && legacy.minP == nil && legacy.presencePenalty == nil && legacy.repetitionPenalty == nil)
        let configured = TextRequest(prompt: "same model", maxTokens: 32768, temperature: 1,
            topP: 0.95, seed: 42, topK: 20, minP: 0, presencePenalty: 1.5, repetitionPenalty: 1)
        #expect(try JSONDecoder().decode(TextRequest.self, from: JSONEncoder().encode(configured)) == configured)
        try configured.validateSampling()
        for invalid in [TextRequest(prompt: "", topK: -1), TextRequest(prompt: "", minP: 1.1),
                        TextRequest(prompt: "", presencePenalty: 2.1), TextRequest(prompt: "", repetitionPenalty: 0)] {
            #expect(throws: (any Error).self) { try invalid.validateSampling() }
            #expect(throws: (any Error).self) {
                try InferenceRequest(model: .init(directory: URL(fileURLWithPath: "/fixture/model")), input: .text(invalid)).validate()
            }
        }
    }

    @Test func identityContractAndLegacyResolutionAreStable() throws {
        #expect(TextExecutionCapability.qwen2Profile
            == ExecutionProfileReference(identifier: "qwen2-text", revision: 1))
        #expect(capability.profile == TextExecutionCapability.qwen2Profile)
        #expect(capability.contract.operationID == "text.generate")
        #expect(capability.contract.inputRoles == [.prompt])
        #expect(capability.contract.outputRole == .text)
        #expect(capability.contract.controlFidelity == .approximate)
        #expect(capability.contract.cancellation == .drainBeforeRelease)

        let legacy = TextRequest(prompt: "legacy", maxTokens: 256)
        #expect(try capability.resolvedPromptTokens(for: legacy) == 2048)
        try capability.validate(legacy)
    }

    @Test func legacyQwenProfileAdmitsImplementedLayeredSelection() throws {
        try capability.validate(TextRequest(prompt: "old", loadingStrategy: .resident))
        try capability.validate(TextRequest(prompt: "same Q4 model", loadingStrategy: .ssdLayered))
        let vlm = TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 256,
            profile: TextExecutionCapability.qwen35VLMProfile)
        try vlm.validate(TextRequest(prompt: "new", loadingStrategy: .ssdLayered))
    }

    @Test func selectedPromptBudgetResolvesWithoutChangingOutputBudget() throws {
        let request = TextRequest(
            prompt: "selected",
            maxTokens: 17,
            execution: TextExecutionSelection(profile: TextExecutionCapability.qwen2Profile,
                                              maximumPromptTokens: 512))
        #expect(try capability.resolvedPromptTokens(for: request) == 512)
        #expect(request.maxTokens == 17)
        try capability.validate(request)
    }

    @Test(arguments: [0, 2049])
    func invalidSelectedPromptBoundsAreRejected(_ maximumPromptTokens: Int) {
        let request = TextRequest(
            prompt: "invalid",
            execution: TextExecutionSelection(profile: TextExecutionCapability.qwen2Profile,
                                              maximumPromptTokens: maximumPromptTokens))
        #expect(throws: (any Error).self) { try capability.validate(request) }
        #expect(throws: (any Error).self) { try capability.resolvedPromptTokens(for: request) }
    }

    @Test func unknownProfileAndOversizedOutputAreRejected() {
        let unknown = TextRequest(
            prompt: "history-visible",
            execution: TextExecutionSelection(
                profile: ExecutionProfileReference(identifier: "future-text", revision: 9),
                maximumPromptTokens: 512))
        #expect(throws: (any Error).self) { try capability.validate(unknown) }

        let oversized = TextRequest(prompt: "too much output", maxTokens: 257)
        #expect(throws: (any Error).self) { try capability.validate(oversized) }
    }

    @Test func invalidCapabilityLimitsCannotAdmitRequests() {
        let invalidPrompt = TextExecutionCapability(maximumPromptTokens: 0, maximumOutputTokens: 256)
        let invalidOutput = TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 0)
        let unadaptedPrompt = TextExecutionCapability(maximumPromptTokens: 32769, maximumOutputTokens: 256)
        let unadaptedOutput = TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 8193)
        #expect(throws: (any Error).self) { try invalidPrompt.validate(TextRequest(prompt: "x")) }
        #expect(throws: (any Error).self) { try invalidOutput.validate(TextRequest(prompt: "x")) }
        #expect(throws: (any Error).self) { try unadaptedPrompt.validate(TextRequest(prompt: "x")) }
        #expect(throws: (any Error).self) { try unadaptedOutput.resolvedPromptTokens(for: TextRequest(prompt: "x")) }
    }

    @Test func promptFidelityDoesNotClaimExactCreativeAdherence() {
        #expect(capability.contract.controlFidelity == .approximate)
        #expect(capability.maximumPromptTokens == 2048)
        #expect(capability.maximumOutputTokens == 256)
    }
}
