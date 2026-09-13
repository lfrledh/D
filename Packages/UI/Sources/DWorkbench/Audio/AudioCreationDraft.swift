import DInference
import Foundation

public enum AudioCreationProfile: String, Codable, Sendable, CaseIterable {
    case stableAudio
    case conditionedMusic
}

/// AW1 editable creation options. Invalid/incomplete numeric input is saved verbatim;
/// submission validation creates a separate immutable AudioRequest.
public struct AudioCreationDraft: Codable, Sendable, Equatable {
    public var profile: AudioCreationProfile
    public var music: MusicCreationDraft?
    public var revision: UUID
    public var prompt: String
    public var operation: AudioOperation
    public var durationText: String
    public var seedText: String
    public var stepsText: String
    public var guidanceText: String
    public var strengthText: String
    public var editRegion: AudioFrameRange?
    public var rejectedAssetIDs: [UUID]

    public init(revision: UUID = UUID(), prompt: String = "", operation: AudioOperation = .generate,
                durationText: String = "6", seedText: String = "42", stepsText: String = "8",
                guidanceText: String = "1", strengthText: String = "0.5",
                editRegion: AudioFrameRange? = nil, rejectedAssetIDs: [UUID] = [],
                profile: AudioCreationProfile = .stableAudio, music: MusicCreationDraft? = nil) {
        self.profile = profile; self.music = music
        self.revision = revision; self.prompt = prompt; self.operation = operation
        self.durationText = durationText; self.seedText = seedText; self.stepsText = stepsText
        self.guidanceText = guidanceText; self.strengthText = strengthText
        self.editRegion = editRegion; self.rejectedAssetIDs = rejectedAssetIDs
    }

    /// Native field focus commits can repeat unchanged input. Compare editing bytes,
    /// not canonical String equality; revision and candidate decisions are host-owned.
    func hasSameEditableRepresentation(as other: Self) -> Bool {
        guard profile == other.profile, operation == other.operation, editRegion == other.editRegion,
              prompt.utf8.elementsEqual(other.prompt.utf8),
              durationText.utf8.elementsEqual(other.durationText.utf8),
              seedText.utf8.elementsEqual(other.seedText.utf8),
              stepsText.utf8.elementsEqual(other.stepsText.utf8),
              guidanceText.utf8.elementsEqual(other.guidanceText.utf8),
              strengthText.utf8.elementsEqual(other.strengthText.utf8) else { return false }
        switch (music, other.music) {
        case (nil, nil): return true
        case let (left?, right?):
            guard left.hasNoteCondition == right.hasNoteCondition,
                  left.notes.count == right.notes.count else { return false }
            return zip(left.notes, right.notes).allSatisfy { a, b in
                a.id == b.id && a.pitchText.utf8.elementsEqual(b.pitchText.utf8)
                    && a.startText.utf8.elementsEqual(b.startText.utf8)
                    && a.durationText.utf8.elementsEqual(b.durationText.utf8)
            }
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case profile, music, revision, prompt, operation, durationText, seedText, stepsText,
             guidanceText, strengthText, editRegion, rejectedAssetIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profile = try values.decodeIfPresent(AudioCreationProfile.self, forKey: .profile) ?? .stableAudio
        music = try values.decodeIfPresent(MusicCreationDraft.self, forKey: .music)
        revision = try values.decode(UUID.self, forKey: .revision)
        prompt = try values.decode(String.self, forKey: .prompt)
        operation = try values.decode(AudioOperation.self, forKey: .operation)
        durationText = try values.decode(String.self, forKey: .durationText)
        seedText = try values.decode(String.self, forKey: .seedText)
        stepsText = try values.decode(String.self, forKey: .stepsText)
        guidanceText = try values.decode(String.self, forKey: .guidanceText)
        strengthText = try values.decode(String.self, forKey: .strengthText)
        editRegion = try values.decodeIfPresent(AudioFrameRange.self, forKey: .editRegion)
        rejectedAssetIDs = try values.decode([UUID].self, forKey: .rejectedAssetIDs)
    }

    public func makeRequest(source: AudioSourceReference?) throws -> AudioRequest {
        if profile == .conditionedMusic {
            guard operation == .generate, source == nil, editRegion == nil, let music else {
                throw InferenceFailure.invalidRequest("旋律条件会生成新的完整片段；不接受参考重绘区间。")
            }
            guard let seed = UInt64(seedText), seed <= UInt64(UInt32.max) else {
                throw InferenceFailure.invalidRequest("音乐 Seed 需要 0 到 4294967295 的整数。")
            }
            let sequence = try music.makeSequence(durationText: durationText)
            let request = AudioRequest(prompt: prompt, seed: seed, noteSequence: sequence)
            try request.validate()
            return request
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceFailure.invalidRequest("Audio prompt must not be blank.")
        }
        guard let seed = UInt64(seedText), seed <= UInt64(UInt32.max) - 1,
              let steps = Int(stepsText), (1...100).contains(steps),
              let guidance = Float(guidanceText), guidance.isFinite, (1...15).contains(guidance) else {
            throw InferenceFailure.invalidRequest("Invalid current audio profile parameters.")
        }

        let duration: Double
        let strength: Float
        let region: AudioEditRegion?
        switch operation {
        case .generate:
            guard source == nil, editRegion == nil else {
                throw InferenceFailure.invalidRequest("Generation does not accept a source or edit region.")
            }
            guard let requestedDuration = Double(durationText), requestedDuration.isFinite,
                  requestedDuration > 0 else {
                throw InferenceFailure.invalidRequest("Invalid generation duration.")
            }
            duration = requestedDuration
            strength = 1
            region = nil
        case .variation:
            guard let source, editRegion == nil else {
                throw InferenceFailure.invalidRequest("Variation requires a source and no edit region.")
            }
            guard let requestedStrength = Float(strengthText), requestedStrength.isFinite,
                  requestedStrength > 0, requestedStrength <= 1 else {
                throw InferenceFailure.invalidRequest("Invalid variation strength.")
            }
            duration = Double(source.frameCount) / Double(source.sampleRate)
            strength = requestedStrength
            region = nil
        case .inpaint:
            guard let source, let editRegion,
                  editRegion.startFrame >= 0, editRegion.startFrame < editRegion.endFrame,
                  editRegion.endFrame <= source.frameCount else {
                throw InferenceFailure.invalidRequest("Inpainting requires a valid half-open source region.")
            }
            guard let requestedStrength = Float(strengthText), requestedStrength.isFinite,
                  requestedStrength > 0, requestedStrength <= 1 else {
                throw InferenceFailure.invalidRequest("Invalid inpaint strength.")
            }
            duration = Double(source.frameCount) / Double(source.sampleRate)
            strength = requestedStrength
            region = AudioEditRegion(startFrame: editRegion.startFrame, endFrame: editRegion.endFrame)
        }
        guard duration.isFinite, duration > 0 else {
            throw InferenceFailure.invalidRequest("Invalid audio duration.")
        }
        let request = AudioRequest(operation: operation, prompt: prompt, durationSeconds: duration,
                                   seed: seed, steps: steps, guidanceScale: guidance,
                                   strength: strength, source: source, editRegion: region)
        try request.validate()
        return request
    }
}
