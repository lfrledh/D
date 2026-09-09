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
    public let steps: Int
    public let guidanceScale: Float
    public let strength: Float
    public let source: AudioSourceReference?
    public let editRegion: AudioEditRegion?

    public init(operation: AudioOperation, prompt: String, durationSeconds: Double,
                seed: UInt64, steps: Int, guidanceScale: Float = 1, strength: Float = 1,
                source: AudioSourceReference? = nil, editRegion: AudioEditRegion? = nil) {
        self.operation = operation; self.prompt = prompt; self.durationSeconds = durationSeconds
        self.seed = seed; self.steps = steps; self.guidanceScale = guidanceScale; self.strength = strength
        self.source = source; self.editRegion = editRegion
    }

    /// Common shape checks only; profile-specific duration, precision, seed and codec limits
    /// are enforced by the selected backend before loading. No hidden conversions here.
    public func validate() throws {
        guard prompt.utf8.count <= 1_048_576, !prompt.contains("\0"),
              durationSeconds.isFinite, durationSeconds > 0, steps > 0,
              guidanceScale.isFinite, guidanceScale >= 0,
              strength.isFinite, strength > 0, strength <= 1 else {
            throw InferenceFailure.invalidRequest("Invalid audio generation parameters.")
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
            guard source == nil, editRegion == nil, strength == 1 else {
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
