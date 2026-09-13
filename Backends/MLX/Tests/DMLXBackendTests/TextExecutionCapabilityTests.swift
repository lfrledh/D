import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("MLX text execution capability")
struct TextExecutionCapabilityTests {
    @Test func backendPublishesItsImmutableConfiguredLimits() throws {
        let backend = try MLXTextBackend(configuration: .init(
            maximumPromptTokens: 4096, maximumOutputTokens: 512))
        #expect(backend.executionCapability.profile == TextExecutionCapability.qwen2Profile)
        #expect(backend.executionCapability.maximumPromptTokens == 4096)
        #expect(backend.executionCapability.maximumOutputTokens == 512)
    }

    @Test func estimateUsesTheSelectedPromptBudgetAndRejectsUnknownProfiles() async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        let backend = try MLXTextBackend(configuration: .init(
            maximumPromptTokens: 2048, maximumOutputTokens: 256))

        let legacy = mlxRequest(directory: fixture.url, maxTokens: 16)
        let selected = InferenceRequest(
            model: legacy.model,
            input: .text(TextRequest(
                prompt: "selected",
                maxTokens: 16,
                execution: TextExecutionSelection(profile: TextExecutionCapability.qwen2Profile,
                                                  maximumPromptTokens: 32))))
        let legacyEstimate = try await backend.estimate(legacy)
        let selectedEstimate = try await backend.estimate(selected)
        #expect(selectedEstimate.peakBytes < legacyEstimate.peakBytes)

        let unknown = InferenceRequest(
            model: legacy.model,
            input: .text(TextRequest(
                prompt: "unknown",
                maxTokens: 16,
                execution: TextExecutionSelection(
                    profile: ExecutionProfileReference(identifier: "unknown-text", revision: 1),
                    maximumPromptTokens: 32))))
        await #expect(throws: (any Error).self) { try await backend.estimate(unknown) }
    }

    @Test func legacyAndSelectedOutputLimitsShareCapabilityValidation() async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        let backend = try MLXTextBackend(configuration: .init(maximumOutputTokens: 32))
        let request = InferenceRequest(
            model: ModelReference(directory: fixture.url),
            input: .text(TextRequest(
                prompt: "too many",
                maxTokens: 33,
                execution: TextExecutionSelection(profile: TextExecutionCapability.qwen2Profile,
                                                  maximumPromptTokens: 128))))
        await #expect(throws: (any Error).self) { try await backend.estimate(request) }
    }

    @Test func originalInventoryEntryPointUsesCapabilityResolution() throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        let request = InferenceRequest(
            model: ModelReference(directory: fixture.url),
            input: .text(TextRequest(
                prompt: "selected",
                maxTokens: 16,
                execution: TextExecutionSelection(profile: TextExecutionCapability.qwen2Profile,
                                                  maximumPromptTokens: 64))))
        let inventory = try LocalModelInventory.inspect(
            request,
            limits: .init(maximumPromptTokens: 2048, maximumOutputTokens: 256))
        #expect(inventory.profile == TextExecutionCapability.qwen2Profile)
        #expect(inventory.maximumPromptTokens == 64)
    }

    @Test func directInventoryCallersCannotBypassConfiguredBounds() {
        let request = InferenceRequest(
            model: ModelReference(directory: URL(fileURLWithPath: "/must-not-be-read")),
            input: .text(TextRequest(prompt: "bounds")))
        let invalidConfigurations: [MLXBackendConfiguration] = [
            .init(maximumPromptTokens: 0),
            .init(maximumPromptTokens: 32769),
            .init(maximumOutputTokens: 0),
            .init(maximumOutputTokens: 8193),
            .init(cacheLimitBytes: -1),
            .init(cacheLimitBytes: Int.max),
        ]
        for limits in invalidConfigurations {
            #expect(throws: (any Error).self) {
                try LocalModelInventory.inspect(request, limits: limits)
            }
        }
        #expect(throws: (any Error).self) {
            try LocalModelInventory.inspect(
                request,
                capability: TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 256),
                cacheLimitBytes: Int.max)
        }
    }
}
