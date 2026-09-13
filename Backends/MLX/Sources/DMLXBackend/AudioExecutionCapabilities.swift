import DInference

enum AudioExecutionCapabilities {
    static func sa3(profile: AudioBackendProfile) -> AudioExecutionCapability {
        let maximumDurationSeconds: Double = profile == .medium ? 380 : 120
        return AudioExecutionCapability(
            profile: .init(identifier: profile.rawValue),
            contract: .init(
                operationID: "audio.sa3.diffusion",
                inputRoles: [.prompt, .referenceAudio],
                outputRole: .audio,
                controlFidelity: .approximate),
            maximumDurationSeconds: maximumDurationSeconds,
            sampleRate: 44_100,
            channelCount: 2,
            operations: [.generate, .variation, .inpaint],
            noteControlFidelity: .unsupported,
            maximumSeed: UInt64(UInt32.max - 1))
    }

    static let mrt2 = AudioExecutionCapability(
        profile: .init(identifier: MRT2ModelInventory.profile),
        contract: .init(
            operationID: "audio.mrt2.note-conditioned",
            inputRoles: [.prompt, .noteSequence],
            outputRole: .audio,
            controlFidelity: .approximate),
        maximumDurationSeconds: 16,
        sampleRate: 48_000,
        channelCount: 2,
        operations: [.generate],
        noteControlFidelity: .approximate,
        maximumConditionFrames: 400,
        maximumNoteCount: 512,
        maximumSeed: UInt64(UInt32.max))
}
