import DInference
import Foundation
import Testing

@Suite("Text execution capability")
struct TextExecutionCapabilityTests {
    private let capability = TextExecutionCapability(maximumPromptTokens: 2048,
                                                     maximumOutputTokens: 256)

    @Test func identityContractAndLegacyResolutionAreStable() throws {
        #expect(TextExecutionCapability.qwen2Profile
            == ExecutionProfileReference(identifier: "qwen2-text", revision: 1))
        #expect(capability.profile == TextExecutionCapability.qwen2Profile)
        #expect(capability.contract.operationID == "text.generate")
        #expect(capability.contract.inputRoles == [.prompt])
        #expect(capability.contract.outputRole == .text)
        #expect(capability.contract.controlFidelity == .exact)
        #expect(capability.contract.cancellation == .drainBeforeRelease)

        let legacy = TextRequest(prompt: "legacy", maxTokens: 256)
        #expect(try capability.resolvedPromptTokens(for: legacy) == 2048)
        try capability.validate(legacy)
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
        #expect(throws: (any Error).self) { try invalidPrompt.validate(TextRequest(prompt: "x")) }
        #expect(throws: (any Error).self) { try invalidOutput.validate(TextRequest(prompt: "x")) }
    }
}
