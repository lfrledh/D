import Foundation

/// Conditions supported by the pinned ACE-Step 1.5 XL SFT profile.
public enum ACEVocalCondition: Codable, Sendable, Equatable {
    case instrumental
    case lyrics(text: String, language: String)

    private enum Keys: String, CodingKey { case kind, text, language }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "instrumental":
            try requireAudioKeys(decoder, allowed: ["kind"])
            self = .instrumental
        case "lyrics":
            try requireAudioKeys(decoder, allowed: ["kind", "text", "language"])
            self = .lyrics(text: try c.decode(String.self, forKey: .text),
                           language: try c.decode(String.self, forKey: .language))
        default: throw InferenceFailure.invalidRequest("Unknown ACE vocal condition.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .instrumental: try c.encode("instrumental", forKey: .kind)
        case .lyrics(let text, let language):
            try c.encode("lyrics", forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(language, forKey: .language)
        }
    }
}

/// Official condition uses a meter string; no denominator is inferred by the host.
public enum ACETimeSignature: String, Codable, Sendable, Equatable {
    case two = "2", three = "3", four = "4", six = "6"
}

public enum ACEEditOptions: Codable, Sendable, Equatable {
    case cover(audioCoverStrength: Float, noiseStrength: Float)
    case repaint(strength: Float)

    private enum Keys: String, CodingKey {
        case kind, audioCoverStrength, noiseStrength, strength
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "cover":
            try requireAudioKeys(decoder, allowed: ["kind", "audioCoverStrength", "noiseStrength"])
            self = .cover(audioCoverStrength: try c.decode(Float.self, forKey: .audioCoverStrength),
                          noiseStrength: try c.decode(Float.self, forKey: .noiseStrength))
        case "repaint":
            try requireAudioKeys(decoder, allowed: ["kind", "strength"])
            self = .repaint(strength: try c.decode(Float.self, forKey: .strength))
        default: throw InferenceFailure.invalidRequest("Unknown ACE edit option.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .cover(let cover, let noise):
            try c.encode("cover", forKey: .kind)
            try c.encode(cover, forKey: .audioCoverStrength)
            try c.encode(noise, forKey: .noiseStrength)
        case .repaint(let strength):
            try c.encode("repaint", forKey: .kind)
            try c.encode(strength, forKey: .strength)
        }
    }
}

public struct ACERequest: Codable, Sendable, Equatable {
    public static let fixedProfile = "ace-step-1.5-xl-sft-mlx-f32-v1"
    public let executionProfile: String
    public let vocal: ACEVocalCondition
    public let bpm: Int?
    public let keyScale: String?
    public let timeSignature: ACETimeSignature?
    public let steps: Int
    public let guidanceScale: Float
    public let referenceAudio: AudioSourceReference?
    public let editOptions: ACEEditOptions?

    public init(executionProfile: String = ACERequest.fixedProfile,
                vocal: ACEVocalCondition = .instrumental, bpm: Int? = nil,
                keyScale: String? = nil, timeSignature: ACETimeSignature? = nil,
                steps: Int = 50, guidanceScale: Float = 7,
                referenceAudio: AudioSourceReference? = nil,
                editOptions: ACEEditOptions? = nil) {
        self.executionProfile = executionProfile; self.vocal = vocal
        self.bpm = bpm; self.keyScale = keyScale; self.timeSignature = timeSignature
        self.steps = steps; self.guidanceScale = guidanceScale
        self.referenceAudio = referenceAudio; self.editOptions = editOptions
    }

    private enum Keys: String, CodingKey {
        case executionProfile, vocal, bpm, keyScale, timeSignature, steps,
             guidanceScale, referenceAudio, editOptions
    }
    public init(from decoder: Decoder) throws {
        try requireAudioKeys(decoder, allowed: ["executionProfile", "vocal", "bpm", "keyScale",
                                                "timeSignature", "steps", "guidanceScale",
                                                "referenceAudio", "editOptions"])
        let c = try decoder.container(keyedBy: Keys.self)
        executionProfile = try c.decode(String.self, forKey: .executionProfile)
        vocal = try c.decode(ACEVocalCondition.self, forKey: .vocal)
        bpm = try c.decodeIfPresent(Int.self, forKey: .bpm)
        keyScale = try c.decodeIfPresent(String.self, forKey: .keyScale)
        timeSignature = try c.decodeIfPresent(ACETimeSignature.self, forKey: .timeSignature)
        steps = try c.decode(Int.self, forKey: .steps)
        guidanceScale = try c.decode(Float.self, forKey: .guidanceScale)
        referenceAudio = try c.decodeIfPresent(AudioSourceReference.self, forKey: .referenceAudio)
        editOptions = try c.decodeIfPresent(ACEEditOptions.self, forKey: .editOptions)
        try validate()
    }

    public func validate() throws {
        guard executionProfile == Self.fixedProfile, steps > 0,
              guidanceScale.isFinite, guidanceScale >= 0,
              bpm.map({ $0 > 0 }) ?? true,
              keyScale.map({ $0.utf8.count <= 128 && !$0.contains("\0") }) ?? true else {
            throw InferenceFailure.invalidRequest("Invalid ACE profile or music condition.")
        }
        switch vocal {
        case .instrumental: break
        case .lyrics(let text, let language):
            guard !text.contains("\0"), text.utf8.count <= 1_048_576,
                  !language.isEmpty, !language.contains("\0"), language.utf8.count <= 64 else {
                throw InferenceFailure.invalidRequest("Invalid ACE lyrics or language.")
            }
        }
        if let referenceAudio { try Self.validateReference(referenceAudio) }
        if let editOptions {
            switch editOptions {
            case .cover(let cover, let noise):
                guard cover.isFinite, (0...1).contains(cover), noise.isFinite,
                      (0...1).contains(noise) else {
                    throw InferenceFailure.invalidRequest("Invalid ACE cover strengths.")
                }
            case .repaint(let strength):
                guard strength.isFinite, (0...1).contains(strength) else {
                    throw InferenceFailure.invalidRequest("Invalid ACE repaint strength.")
                }
            }
        }
    }

    static func validateReference(_ source: AudioSourceReference) throws {
        guard source.url.isFileURL, source.url.path.hasPrefix("/"),
              source.url.host == nil || source.url.host == "" || source.url.host == "localhost",
              source.frameCount > 0, source.sampleRate == 48_000, source.channels == 2,
              source.sha256.utf8.count == 64,
              source.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw InferenceFailure.invalidRequest("ACE requires an immutable stereo 48 kHz WAV reference.")
        }
    }
}
