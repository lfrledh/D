import Foundation

/// Immutable, profile-specific audio execution facts. This describes an implemented
/// backend envelope; it neither verifies an installation nor makes one deployed.
public struct AudioExecutionCapability: Codable, Equatable, Sendable {
    public let profile: ExecutionProfileReference
    public let contract: ExecutionContractDescription
    public let maximumDurationSeconds: Double
    public let sampleRate: Int
    public let channelCount: Int
    /// An array is intentional: AudioOperation is Equatable but not Hashable.
    public let operations: [AudioOperation]
    public let noteControlFidelity: ExecutionControlFidelity
    /// nil means this profile has no note-condition frame clock, not an unknown limit.
    public let maximumConditionFrames: Int?
    /// nil means this profile has no note-condition note count, not an unknown limit.
    public let maximumNoteCount: Int?
    /// The profile-specific inclusive seed ceiling; nil would mean no declared ceiling.
    public let maximumSeed: UInt64?

    public init(
        profile: ExecutionProfileReference,
        contract: ExecutionContractDescription,
        maximumDurationSeconds: Double,
        sampleRate: Int,
        channelCount: Int,
        operations: [AudioOperation],
        noteControlFidelity: ExecutionControlFidelity,
        maximumConditionFrames: Int? = nil,
        maximumNoteCount: Int? = nil,
        maximumSeed: UInt64? = nil
    ) {
        self.profile = profile
        self.contract = contract
        self.maximumDurationSeconds = maximumDurationSeconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.operations = operations
        self.noteControlFidelity = noteControlFidelity
        self.maximumConditionFrames = maximumConditionFrames
        self.maximumNoteCount = maximumNoteCount
        self.maximumSeed = maximumSeed
    }

    /// Check the deployed profile's duration envelope without loading a model.
    /// Other request constraints and resource admission remain separate checks.
    public func validateDuration(_ seconds: Double) throws {
        guard maximumDurationSeconds.isFinite, maximumDurationSeconds > 0 else {
            throw InferenceFailure.invalidRequest("当前音频配置的时长范围不可用。")
        }
        guard seconds.isFinite, seconds > 0, seconds <= maximumDurationSeconds else {
            throw InferenceFailure.invalidRequest("当前音频配置支持大于 0 且不超过 \(maximumDurationSeconds) 秒；输入保持不变。")
        }
    }
}
