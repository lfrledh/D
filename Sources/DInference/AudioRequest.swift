import Foundation

/// Operations are model capabilities, not promises of symbolic or sample-level control.
public enum AudioOperation: String, Codable, Sendable, Equatable {
    case generate, variation, inpaint
}

/// Immutable reference in the source's frame clock. Backends must verify these claims.
public struct AudioSourceReference: Codable, Sendable, Equatable {
    public let url: URL
    public let sha256: String
    public let frameCount: Int64
    public let sampleRate: Int
    public let channels: Int
    public init(url: URL, sha256: String, frameCount: Int64, sampleRate: Int, channels: Int) {
        self.url = url; self.sha256 = sha256; self.frameCount = frameCount
        self.sampleRate = sampleRate; self.channels = channels
    }
}

/// Half-open source-frame interval; it is never a byte or latent offset.
public struct AudioEditRegion: Codable, Sendable, Equatable {
    public let startFrame: Int64
    public let endFrame: Int64
    public init(startFrame: Int64, endFrame: Int64) {
        self.startFrame = startFrame; self.endFrame = endFrame
    }
}

public struct AudioRequest: Codable, Sendable, Equatable {
    public let operation: AudioOperation
    public let prompt: String
    public let durationSeconds: Double
    public let seed: UInt64
    public let parameters: AudioSynthesisParameters
    public let source: AudioSourceReference?
    public let editRegion: AudioEditRegion?

    public init(operation: AudioOperation, prompt: String, durationSeconds: Double,
                seed: UInt64, steps: Int, guidanceScale: Float = 1, strength: Float = 1,
                source: AudioSourceReference? = nil, editRegion: AudioEditRegion? = nil) {
        self.operation = operation; self.prompt = prompt; self.durationSeconds = durationSeconds
        self.seed = seed; self.parameters = .diffusion(.init(steps: steps, guidanceScale: guidanceScale, strength: strength))
        self.source = source; self.editRegion = editRegion
    }

    public init(prompt: String, seed: UInt64, noteSequence: AudioNoteSequence) {
        operation = .generate; self.prompt = prompt; self.seed = seed
        durationSeconds = noteSequence.durationSeconds
        parameters = .mrt2FixedV1(noteSequence); source = nil; editRegion = nil
    }

    public init(operation: AudioOperation, prompt: String, durationSeconds: Double,
                seed: UInt64, ace: ACERequest,
                source: AudioSourceReference? = nil, editRegion: AudioEditRegion? = nil) {
        self.operation = operation; self.prompt = prompt; self.durationSeconds = durationSeconds
        self.seed = seed; self.parameters = .aceStep15(ace)
        self.source = source; self.editRegion = editRegion
    }

    public var diffusion: AudioDiffusionParameters? {
        if case .diffusion(let value) = parameters { return value }; return nil
    }
    public var noteSequence: AudioNoteSequence? {
        if case .mrt2FixedV1(let value) = parameters { return value }; return nil
    }
    public var ace: ACERequest? {
        if case .aceStep15(let value) = parameters { return value }; return nil
    }
    public var outputSampleRate: Int { diffusion == nil ? 48_000 : 44_100 }

    private enum CodingKeys: String, CodingKey {
        case operation, prompt, durationSeconds, seed, steps, guidanceScale, strength, source, editRegion, parameters
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = try c.decode(AudioOperation.self, forKey: .operation)
        prompt = try c.decode(String.self, forKey: .prompt)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        seed = try c.decode(UInt64.self, forKey: .seed)
        source = try c.decodeIfPresent(AudioSourceReference.self, forKey: .source)
        editRegion = try c.decodeIfPresent(AudioEditRegion.self, forKey: .editRegion)
        if c.contains(.parameters) {
            try requireAudioKeys(decoder, allowed: ["operation", "prompt", "durationSeconds", "seed", "source", "editRegion", "parameters"])
            parameters = try c.decode(AudioSynthesisParameters.self, forKey: .parameters)
        } else {
            // Old project snapshots retain their exact flat diffusion representation.
            try requireAudioKeys(decoder, allowed: ["operation", "prompt", "durationSeconds", "seed", "source", "editRegion", "steps", "guidanceScale", "strength"])
            parameters = .diffusion(.init(steps: try c.decode(Int.self, forKey: .steps),
                guidanceScale: try c.decode(Float.self, forKey: .guidanceScale),
                strength: try c.decode(Float.self, forKey: .strength)))
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operation, forKey: .operation); try c.encode(prompt, forKey: .prompt)
        try c.encode(durationSeconds, forKey: .durationSeconds); try c.encode(seed, forKey: .seed)
        try c.encodeIfPresent(source, forKey: .source); try c.encodeIfPresent(editRegion, forKey: .editRegion)
        switch parameters {
        case .diffusion(let value):
            try c.encode(value.steps, forKey: .steps); try c.encode(value.guidanceScale, forKey: .guidanceScale)
            try c.encode(value.strength, forKey: .strength)
        case .mrt2FixedV1, .aceStep15:
            try c.encode(parameters, forKey: .parameters)
        }
    }

    /// Common shape checks only; profile-specific duration, precision, seed and codec limits
    /// are enforced by the selected backend before loading. No hidden conversions here.
    public func validate() throws {
        guard prompt.utf8.count <= 1_048_576, !prompt.contains("\0"),
              durationSeconds.isFinite, durationSeconds > 0 else {
            throw InferenceFailure.invalidRequest("Invalid audio generation parameters.")
        }
        if let sequence = noteSequence {
            try sequence.validate()
            guard operation == .generate, source == nil, editRegion == nil,
                  durationSeconds == sequence.durationSeconds, seed <= UInt64(UInt32.max),
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.utf8.count <= 4096 else {
                throw InferenceFailure.invalidRequest("Invalid MRT2 generation parameters.")
            }
            return
        }
        if let ace {
            try ace.validate()
            guard seed <= UInt32.max else {
                throw InferenceFailure.invalidRequest("ACE seed exceeds UInt32.")
            }
            if let source { try ACERequest.validateReference(source) }
            let frames = durationSeconds * 48_000
            let roundedFrames = frames.rounded()
            guard frames.isFinite, roundedFrames >= 1,
                  roundedFrames < 9_223_372_036_854_775_808.0,
                  abs(roundedFrames - frames) < 0.000_001 else {
                throw InferenceFailure.invalidRequest("ACE duration must identify exact 48 kHz frames.")
            }
            if source == nil {
                let grid = durationSeconds * 10
                guard abs(grid.rounded() - grid) < 0.000_001 else {
                    throw InferenceFailure.invalidRequest("ACE generation requires the official 0.1-second grid.")
                }
            }
            switch operation {
            case .generate:
                guard source == nil, editRegion == nil, ace.editOptions == nil else {
                    throw InferenceFailure.invalidRequest("ACE generation does not accept edit inputs.")
                }
            case .variation:
                guard source != nil, editRegion == nil,
                      ace.editOptions.map({ if case .cover = $0 { return true }; return false }) == true else {
                    throw InferenceFailure.invalidRequest("ACE variation requires source and cover options.")
                }
            case .inpaint:
                guard let source, let region = editRegion, region.startFrame >= 0,
                      region.endFrame > region.startFrame, region.endFrame <= source.frameCount,
                      ace.editOptions.map({ if case .repaint = $0 { return true }; return false }) == true else {
                    throw InferenceFailure.invalidRequest("ACE inpaint requires source, region, and repaint options.")
                }
            }
            if let source {
                guard Int64(roundedFrames) == source.frameCount else {
                    throw InferenceFailure.invalidRequest("ACE edit duration must equal exact source frames.")
                }
            }
            return
        }
        guard let diffusion, diffusion.steps > 0, diffusion.guidanceScale.isFinite,
              diffusion.guidanceScale >= 0, diffusion.strength.isFinite,
              diffusion.strength > 0, diffusion.strength <= 1 else {
            throw InferenceFailure.invalidRequest("Invalid audio diffusion parameters.")
        }
        if let source {
            guard source.url.isFileURL, source.url.path.hasPrefix("/"),
                  source.url.host == nil || source.url.host == "" || source.url.host == "localhost",
                  source.frameCount > 0, source.sampleRate > 0, source.channels > 0,
                  source.sha256.utf8.count == 64,
                  source.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw InferenceFailure.invalidRequest("Invalid audio source reference.")
            }
        }
        switch operation {
        case .generate:
            guard source == nil, editRegion == nil, diffusion.strength == 1 else {
                throw InferenceFailure.invalidRequest("Generation does not accept a source or edit region.")
            }
        case .variation:
            guard source != nil, editRegion == nil else {
                throw InferenceFailure.invalidRequest("Variation requires a source and no edit region.")
            }
        case .inpaint:
            guard let source, let region = editRegion, region.startFrame >= 0,
                  region.endFrame > region.startFrame, region.endFrame <= source.frameCount else {
                throw InferenceFailure.invalidRequest("Inpainting requires a nonempty source-frame region.")
            }
        }
    }
}
