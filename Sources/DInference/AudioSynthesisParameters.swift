import Foundation

public struct AudioDiffusionParameters: Codable, Sendable, Equatable {
    public let steps: Int
    public let guidanceScale: Float
    public let strength: Float
    public init(steps: Int, guidanceScale: Float = 1, strength: Float = 1) {
        self.steps = steps; self.guidanceScale = guidanceScale; self.strength = strength
    }
    private enum CodingKeys: String, CodingKey { case steps, guidanceScale, strength }
    public init(from decoder: Decoder) throws {
        try requireAudioKeys(decoder, allowed: ["steps", "guidanceScale", "strength"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decode(Int.self, forKey: .steps)
        guidanceScale = try c.decode(Float.self, forKey: .guidanceScale)
        strength = try c.decode(Float.self, forKey: .strength)
    }
}

/// A note uses the condition clock, never the waveform's sample clock.
public struct AudioNoteEvent: Codable, Sendable, Equatable {
    public let pitch: Int
    public let startFrame: Int
    public let endFrame: Int
    public init(pitch: Int, startFrame: Int, endFrame: Int) {
        self.pitch = pitch; self.startFrame = startFrame; self.endFrame = endFrame
    }
    private enum CodingKeys: String, CodingKey { case pitch, startFrame, endFrame }
    public init(from decoder: Decoder) throws {
        try requireAudioKeys(decoder, allowed: ["pitch", "startFrame", "endFrame"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pitch = try c.decode(Int.self, forKey: .pitch)
        startFrame = try c.decode(Int.self, forKey: .startFrame)
        endFrame = try c.decode(Int.self, forKey: .endFrame)
    }
}

/// Fixed MRT2-small exported-profile conditioning. Limits belong to this profile,
/// not to all audio models or the memory capacity of the current Mac.
public struct AudioNoteSequence: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let frameRate: Int
    public let durationFrames: Int
    /// nil means absent conditioning; [] means explicit all-zero conditioning, not silence.
    public let notes: [AudioNoteEvent]?
    public init(schemaVersion: Int = 1, frameRate: Int = 25, durationFrames: Int,
                notes: [AudioNoteEvent]?) {
        self.schemaVersion = schemaVersion; self.frameRate = frameRate
        self.durationFrames = durationFrames; self.notes = notes
    }
    public var durationSeconds: Double { Double(durationFrames) / Double(frameRate) }
    public var canonicalNotes: [AudioNoteEvent]? {
        notes?.sorted {
            if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
            if $0.startFrame != $1.startFrame { return $0.startFrame < $1.startFrame }
            return $0.endFrame < $1.endFrame
        }
    }
    public func validate() throws {
        guard schemaVersion == 1, frameRate == 25, (1...400).contains(durationFrames),
              (notes?.count ?? 0) <= 512 else {
            throw InferenceFailure.invalidRequest("Unsupported MRT2 note-condition version, clock, duration or count.")
        }
        var ends: [Int: Int] = [:]
        for note in canonicalNotes ?? [] {
            guard (0...127).contains(note.pitch), note.startFrame >= 0,
                  note.endFrame > note.startFrame, note.endFrame <= durationFrames,
                  note.startFrame >= (ends[note.pitch] ?? 0) else {
                throw InferenceFailure.invalidRequest("Notes require MIDI pitches and non-overlapping half-open intervals per pitch.")
            }
            ends[note.pitch] = note.endFrame
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, frameRate, durationFrames, notes }
    public init(from decoder: Decoder) throws {
        try requireAudioKeys(decoder, allowed: ["schemaVersion", "frameRate", "durationFrames", "notes"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        frameRate = try c.decode(Int.self, forKey: .frameRate)
        durationFrames = try c.decode(Int.self, forKey: .durationFrames)
        notes = c.contains(.notes) ? try c.decode([AudioNoteEvent].self, forKey: .notes) : nil
        try validate()
    }
}

/// A typed parameter family prevents diffusion-only fields from silently reaching MRT2.
public enum AudioSynthesisParameters: Codable, Sendable, Equatable {
    case diffusion(AudioDiffusionParameters)
    case mrt2FixedV1(AudioNoteSequence)

    private enum CodingKeys: String, CodingKey { case kind, diffusion, sequence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "diffusion":
            try requireAudioKeys(decoder, allowed: ["kind", "diffusion"])
            self = .diffusion(try c.decode(AudioDiffusionParameters.self, forKey: .diffusion))
        case "mrt2FixedV1":
            try requireAudioKeys(decoder, allowed: ["kind", "sequence"])
            self = .mrt2FixedV1(try c.decode(AudioNoteSequence.self, forKey: .sequence))
        default: throw InferenceFailure.invalidRequest("Unsupported audio parameter family.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .diffusion(let value):
            try c.encode("diffusion", forKey: .kind); try c.encode(value, forKey: .diffusion)
        case .mrt2FixedV1(let value):
            try c.encode("mrt2FixedV1", forKey: .kind); try c.encode(value, forKey: .sequence)
        }
    }
}

private struct AudioAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func requireAudioKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: AudioAnyCodingKey.self)
    guard Set(c.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw InferenceFailure.invalidRequest("Unknown audio condition or parameter field.")
    }
}
