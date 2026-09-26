import DInference
import Foundation

/// The formats admitted by the current workflow Store. This is not a decoder registry.
enum WorkflowMediaFormat {
    static let noteType = "application/vnd.d.music-notes+json"
    static let chordType = "application/vnd.d.music-chords+json"
    static let tempoType = "application/vnd.d.music-tempo+json"
    static func descriptor(_ mediaType: String) -> (kind: WorkflowDataKind, suffix: String, maximumBytes: Int)? {
        switch mediaType {
        case "text/plain": (.text, "txt", 1_048_576)
        case "image/png": (.image, "png", 64 * 1_024 * 1_024)
        case "image/jpeg": (.image, "jpg", 64 * 1_024 * 1_024)
        case "audio/wav": (.audio, "wav", AudioLimits.maximumGeneratedBytes)
        case "audio/x-caf": (.audio, "caf", AudioLimits.maximumBytes)
        case "video/mp4": (.video, "mp4", 512 * 1_024 * 1_024)
        case noteType: (.notes, "notes.json", 8 * 1_024 * 1_024)
        case chordType: (.chords, "chords.json", 8 * 1_024 * 1_024)
        case tempoType: (.tempo, "tempo.json", 1_048_576)
        case PitchAnalysisResult.mediaType: (.pitch, "pitch.json", PitchAnalysisResult.maximumJSONBytes)
        default: nil
        }
    }

    static func validateStructure(_ data: Data, mediaType: String) throws -> [WorkflowAssetReference] {
        if mediaType == PitchAnalysisResult.mediaType {
            _ = try PitchResultFile.decode(data)
            return []
        }
        let datum = try JSONDecoder().decode(WorkflowDatum.self, from: data)
        try datum.validate()
        switch mediaType {
        case noteType: return try WorkflowNoteSequence(datum: datum).sources
        case chordType: return try WorkflowChordTrack(datum: datum).sources
        case tempoType: _ = try WorkflowTempoMap(datum: datum); return []
        default: throw WorkflowIssue("不支持此结构化媒体格式。")
        }
    }
}
