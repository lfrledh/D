import DInference
import Foundation
import Testing

@Suite("Audio execution capability contract")
struct AudioCapabilityContractTests {
    @Test(arguments: [16.0, 120.0, 380.0])
    func durationUsesDeclaredProfileLimit(limit: Double) throws {
        let capability = AudioExecutionCapability(profile: .init(identifier: "fixture"),
            contract: .init(operationID: "audio.fixture", inputRoles: [.prompt], outputRole: .audio,
                            controlFidelity: .approximate),
            maximumDurationSeconds: limit, sampleRate: 44_100, channelCount: 2,
            operations: [.generate], noteControlFidelity: .unsupported)
        try capability.validateDuration(limit)
        for invalid in [limit + 1, 0, -1, Double.nan, Double.infinity] {
            #expect(throws: InferenceFailure.self) { try capability.validateDuration(invalid) }
        }
    }

    @Test("Note limits are absent only for profiles without note conditioning")
    func optionalNoteLimitsRetainTheirMeaning() {
        let diffusion = AudioExecutionCapability(
            profile: .init(identifier: "sm-music"),
            contract: .init(operationID: "audio.sa3.diffusion", inputRoles: [.prompt],
                            outputRole: .audio, controlFidelity: .approximate),
            maximumDurationSeconds: 120, sampleRate: 44_100, channelCount: 2,
            operations: [.generate], noteControlFidelity: .unsupported)
        #expect(diffusion.maximumConditionFrames == nil)
        #expect(diffusion.maximumNoteCount == nil)
        #expect(diffusion.noteControlFidelity == .unsupported)
    }

    @Test("Capability values preserve operation ordering without requiring Hashable")
    func operationsAreTypedArray() throws {
        let value = AudioExecutionCapability(
            profile: .init(identifier: "mrt2-small-export-v1"),
            contract: .init(operationID: "audio.mrt2.note-conditioned",
                            inputRoles: [.prompt, .noteSequence], outputRole: .audio,
                            controlFidelity: .approximate),
            maximumDurationSeconds: 16, sampleRate: 48_000, channelCount: 2,
            operations: [.generate], noteControlFidelity: .approximate,
            maximumConditionFrames: 400, maximumNoteCount: 512,
            maximumSeed: UInt64(UInt32.max))
        let decoded = try JSONDecoder().decode(
            AudioExecutionCapability.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }
}
