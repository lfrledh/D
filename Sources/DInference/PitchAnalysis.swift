import Foundation

/// Original media identity is separate from the disposable mono analysis input.
public struct PitchSourceIdentity: Sendable, Codable, Equatable {
    public let assetID: UUID
    public let documentID: UUID
    public let documentRevision: UInt64
    public let contentSHA256: String
    public let sampleRate: Double
    public let frameCount: Int64
    public let startFrame: Int64
    public let endFrame: Int64
    public init(assetID: UUID, documentID: UUID, documentRevision: UInt64,
                contentSHA256: String, sampleRate: Double, frameCount: Int64,
                startFrame: Int64, endFrame: Int64) {
        self.assetID = assetID; self.documentID = documentID; self.documentRevision = documentRevision
        self.contentSHA256 = contentSHA256; self.sampleRate = sampleRate; self.frameCount = frameCount
        self.startFrame = startFrame; self.endFrame = endFrame
    }
    public func validate() throws {
        guard Self.isDigest(contentSHA256), sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 192000,
              frameCount > 0, startFrame >= 0, startFrame < endFrame, endFrame <= frameCount else {
            throw InferenceFailure.invalidRequest("Invalid original audio identity or half-open range.")
        }
    }
    public static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct PitchAnalysisRequest: Sendable, Codable, Equatable {
    public static let profile = "swift-f0-0.1.2-cpu-v1"
    public static let preprocessing = "avconverter-mono16k-prime-normal-v1"
    public static let modelSHA256 = "fa91bb45512b90339cf4b00a599ba8fe3a253c46419fcfe6b46df77a8a8336a5"
    public let source: PitchSourceIdentity
    /// Host-owned derived raw little-endian mono float32, exactly 16000 samples/sec.
    public let inputURL: URL
    public let inputSHA256: String
    public let sampleCount: Int
    public init(source: PitchSourceIdentity, inputURL: URL, inputSHA256: String, sampleCount: Int) {
        self.source = source; self.inputURL = inputURL; self.inputSHA256 = inputSHA256
        self.sampleCount = sampleCount
    }
    public func validate() throws {
        try source.validate()
        let expected = Double(source.endFrame - source.startFrame) * 16000 / source.sampleRate
        guard inputURL.isFileURL, inputURL.path.hasPrefix("/"), !inputURL.path.contains("\0"),
              PitchSourceIdentity.isDigest(inputSHA256), sampleCount >= 256, sampleCount <= 1_920_000,
              expected >= 256, expected <= 1_920_000, abs(Double(sampleCount) - expected) <= 1 else {
            throw InferenceFailure.invalidRequest("Invalid mono 16 kHz analysis input; this profile accepts 16 ms through 120 seconds.")
        }
    }
}

/// One model frame centered at (256 * index + 127.5) / 16000 seconds within the selection.
/// Confidence is the model score, not a calibrated probability. Unvoiced pitch is unknown.
public struct PitchFrame: Sendable, Codable, Equatable {
    public let pitchHz: Double?
    public let confidence: Double
    public let voiced: Bool
    public init(pitchHz: Double?, confidence: Double, voiced: Bool) {
        self.pitchHz = pitchHz; self.confidence = confidence; self.voiced = voiced
    }
    private enum CodingKeys: String, CodingKey { case pitchHz, confidence, voiced }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let pitchHz { try values.encode(pitchHz, forKey: .pitchHz) }
        else { try values.encodeNil(forKey: .pitchHz) }
        try values.encode(confidence, forKey: .confidence)
        try values.encode(voiced, forKey: .voiced)
    }
}

public struct PitchAnalysisResult: Sendable, Codable, Equatable {
    public static let mediaType = "application/vnd.d.pitch-analysis+json"
    public static let maximumJSONBytes = 2 * 1024 * 1024
    public let schemaVersion: Int
    public let runID: UUID
    public let source: PitchSourceIdentity
    public let profile: String
    public let preprocessing: String
    public let modelSHA256: String
    public let inputSHA256: String
    public let sampleCount: Int
    public let frames: [PitchFrame]
    public init(runID: UUID, source: PitchSourceIdentity, inputSHA256: String, sampleCount: Int,
                frames: [PitchFrame], schemaVersion: Int = 1,
                profile: String = PitchAnalysisRequest.profile,
                preprocessing: String = PitchAnalysisRequest.preprocessing,
                modelSHA256: String = PitchAnalysisRequest.modelSHA256) {
        self.schemaVersion = schemaVersion; self.runID = runID; self.source = source
        self.profile = profile; self.preprocessing = preprocessing; self.modelSHA256 = modelSHA256
        self.inputSHA256 = inputSHA256; self.sampleCount = sampleCount; self.frames = frames
    }
    public var hasVoicedPitch: Bool { frames.contains { $0.voiced } }
    public func originalFramePosition(for index: Int) -> Double {
        Double(source.startFrame) + (Double(index) * 256 + 127.5) * source.sampleRate / 16000
    }
    public func validate() throws {
        try source.validate()
        let expected = Double(source.endFrame - source.startFrame) * 16000 / source.sampleRate
        guard schemaVersion == 1, profile == PitchAnalysisRequest.profile,
              preprocessing == PitchAnalysisRequest.preprocessing,
              modelSHA256 == PitchAnalysisRequest.modelSHA256,
              PitchSourceIdentity.isDigest(inputSHA256), sampleCount >= 256, sampleCount <= 1_920_000,
              expected >= 256, expected <= 1_920_000, abs(Double(sampleCount) - expected) <= 1, frames.count == sampleCount / 256 else {
            throw InferenceFailure.invalidRequest("Unsupported or inconsistent pitch analysis result.")
        }
        for frame in frames {
            guard frame.confidence.isFinite, (0...1).contains(frame.confidence) else {
                throw InferenceFailure.invalidRequest("Invalid pitch confidence.")
            }
            if frame.voiced {
                guard let hz = frame.pitchHz, hz.isFinite, (46.875...2093.75).contains(hz), frame.confidence > 0.9 else {
                    throw InferenceFailure.invalidRequest("Invalid voiced pitch.")
                }
            } else if frame.pitchHz != nil {
                throw InferenceFailure.invalidRequest("Unvoiced pitch must be unknown.")
            }
        }
    }
}
