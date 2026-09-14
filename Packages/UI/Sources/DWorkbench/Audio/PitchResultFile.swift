import DInference
import Foundation

/// File boundary validation is independent of the provider transport's validation.
enum PitchResultFile {
    static func decode(_ data: Data) throws -> PitchAnalysisResult {
        guard data.count <= PitchAnalysisResult.maximumJSONBytes,
              let text = String(data: data, encoding: .utf8) else { throw invalid() }
        var parser = StrictAudioJSON(text)
        guard case .object(let object) = try parser.parse() else { throw invalid() }
        try keys(object, ["schemaVersion", "runID", "source", "profile", "preprocessing", "modelSHA256", "inputSHA256", "sampleCount", "frames"])
        guard case .object(let source) = object["source"], case .array(let frames) = object["frames"],
              frames.count <= 7500 else { throw invalid() }
        try keys(source, ["assetID", "documentID", "documentRevision", "contentSHA256", "sampleRate", "frameCount", "startFrame", "endFrame"])
        for frame in frames {
            guard case .object(let fields) = frame else { throw invalid() }
            try keys(fields, ["pitchHz", "confidence", "voiced"])
        }
        let value = try JSONDecoder().decode(PitchAnalysisResult.self, from: data)
        try value.validate()
        return value
    }
    private static func keys(_ object: [String: StrictAudioJSON.Value], _ expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw invalid() }
    }
    private static func invalid() -> InferenceFailure { .invalidRequest("音高文件字段、编码或大小无效；原声保持不变。") }
}

/// Maps analysis blocks back to free-time source coordinates, clipping the rounding tail.
public struct PitchSourceNote: Codable, Sendable, Equatable {
    public let startFramePosition: Double
    public let endFramePosition: Double
    public let midiNote: Int
    public let meanConfidence: Double
    public static func map(_ result: PitchAnalysisResult) throws -> [PitchSourceNote] {
        try PitchInterpretation(result: result).notes.map { note in
            let source = result.source
            let start = Double(source.startFrame) + Double(note.startSample) * source.sampleRate / 16000
            let end = min(Double(source.endFrame), Double(source.startFrame) + Double(note.endSample) * source.sampleRate / 16000)
            return .init(startFramePosition: start, endFramePosition: end, midiNote: note.midiNote, meanConfidence: note.meanConfidence)
        }
    }
}
