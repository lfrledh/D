import Foundation

/// HUM1: original media and frame-based editing data, independent of inference and views.
public enum AudioContainer: String, Codable, Sendable { case wav, caf }
public enum AudioOrigin: String, Codable, Sendable { case importedFile, microphone, modelGenerated }
public enum AudioInspectionPolicy: Sendable { case original, generated }
public enum AudioLimits {
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumSeconds: Double = 120
    public static let maximumGeneratedBytes = 256 * 1024 * 1024
    public static let maximumGeneratedSeconds: Double = 380
    public static let maximumWaveformBuckets = 1024
    public static let maximumClips = 64
    public static let maximumNameBytes = 256
    public static let maximumNoteBytes = 16 * 1024
}

extension AudioInspectionPolicy {
    var maximumBytes: Int {
        switch self {
        case .original: AudioLimits.maximumBytes
        case .generated: AudioLimits.maximumGeneratedBytes
        }
    }

    var maximumSeconds: Double {
        switch self {
        case .original: AudioLimits.maximumSeconds
        case .generated: AudioLimits.maximumGeneratedSeconds
        }
    }
}
public struct AudioFormatInfo: Codable, Sendable, Equatable {
    public let container: AudioContainer
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int64
    public let bitDepth: Int
    public let floatingPoint: Bool
    public init(container: AudioContainer, sampleRate: Double, channelCount: Int,
                frameCount: Int64, bitDepth: Int, floatingPoint: Bool) {
        self.container = container; self.sampleRate = sampleRate; self.channelCount = channelCount
        self.frameCount = frameCount; self.bitDepth = bitDepth; self.floatingPoint = floatingPoint
    }
}
public struct AudioAssetMetadata: Codable, Sendable, Equatable {
    public let format: AudioFormatInfo
    public let contentSHA256: String
    public let origin: AudioOrigin
    public init(format: AudioFormatInfo, contentSHA256: String, origin: AudioOrigin) {
        self.format = format; self.contentSHA256 = contentSHA256; self.origin = origin
    }
}
/// Half-open original-frame coordinates. Validation belongs to media/store admission.
public struct AudioFrameRange: Codable, Sendable, Equatable {
    public var startFrame: Int64
    public var endFrame: Int64
    public init(startFrame: Int64, endFrame: Int64) {
        self.startFrame = startFrame; self.endFrame = endFrame
    }
}
public struct AudioClip: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var range: AudioFrameRange
    public var note: String
    public init(id: UUID = UUID(), name: String, range: AudioFrameRange, note: String = "") {
        self.id = id; self.name = name; self.range = range; self.note = note
    }
}
public struct AudioDraftDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var revision: UInt64
    public var assetID: UUID
    public var clips: [AudioClip]
    public var selectedClipID: UUID?
    public var note: String
    public init(id: UUID, revision: UInt64 = 0, assetID: UUID, clips: [AudioClip] = [],
                selectedClipID: UUID? = nil, note: String = "") {
        self.id = id; self.revision = revision; self.assetID = assetID; self.clips = clips
        self.selectedClipID = selectedClipID; self.note = note
    }
}
public struct AudioCaptureReservation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let relativePath: String
    public let name: String
    public let createdAt: Date
    public init(id: UUID, relativePath: String, name: String, createdAt: Date = Date()) {
        self.id = id; self.relativePath = relativePath; self.name = name; self.createdAt = createdAt
    }
}
/// Display-only extrema; do not modify or normalize the underlying recording.
public struct AudioPeak: Sendable, Equatable {
    public let minimum: Float
    public let maximum: Float
    public init(minimum: Float, maximum: Float) { self.minimum = minimum; self.maximum = maximum }
}
public struct AudioInspection: Sendable {
    public let format: AudioFormatInfo
    public let contentSHA256: String
    public let waveform: [AudioPeak]
    public init(format: AudioFormatInfo, contentSHA256: String, waveform: [AudioPeak]) {
        self.format = format; self.contentSHA256 = contentSHA256; self.waveform = waveform
    }
}
public enum AudioMediaError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedFormat, limitExceeded, invalidMedia(String), invalidRange, unavailable(String), io(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "暂不支持此音频；请选择 WAV 或 CAF 的 PCM 音频。"
        case .limitExceeded: "音频超出当前片段的容量、时长或格式限制。"
        case .invalidMedia(let reason): "音频无法完整读取：\(reason)"
        case .invalidRange: "片段范围超出原音频，原件未改变。"
        case .unavailable(let reason): "音频设备或操作不可用：\(reason)"
        case .io(let reason): "音频文件操作失败：\(reason)"
        }
    }
}
