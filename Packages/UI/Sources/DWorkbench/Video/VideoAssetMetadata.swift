import DInference
import Foundation

/// Facts from the complete AAC-to-PCM pass. Time values are exact rational seconds.
public struct VideoAudioTrackMetadata: Codable, Sendable, Equatable {
    public let codec: String
    public let sampleRate: Int
    public let channels: Int
    public let decodedSampleCount: Int64
    public let startNumerator: Int64
    public let startDenominator: Int32
    public let durationNumerator: Int64
    public let durationDenominator: Int32

    public init(codec: String, sampleRate: Int, channels: Int, decodedSampleCount: Int64,
                startNumerator: Int64, startDenominator: Int32,
                durationNumerator: Int64, durationDenominator: Int32) {
        self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
        self.decodedSampleCount = decodedSampleCount
        self.startNumerator = startNumerator; self.startDenominator = startDenominator
        self.durationNumerator = durationNumerator; self.durationDenominator = durationDenominator
    }
}

/// A verified media file description, independent of players, models and project location.
public struct VideoAssetMetadata: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let frameRate: VideoFrameRate
    public let durationNumerator: Int64
    public let durationDenominator: Int32
    public let codec: String
    public let hasAudio: Bool
    public let audioTrack: VideoAudioTrackMetadata?
    public let byteCount: UInt64
    public let contentSHA256: String

    public init(width: Int, height: Int, frameCount: Int, frameRate: VideoFrameRate,
                durationNumerator: Int64, durationDenominator: Int32, codec: String,
                hasAudio: Bool, byteCount: UInt64, contentSHA256: String,
                audioTrack: VideoAudioTrackMetadata? = nil) {
        self.width = width; self.height = height; self.frameCount = frameCount
        self.frameRate = frameRate; self.durationNumerator = durationNumerator
        self.durationDenominator = durationDenominator; self.codec = codec; self.hasAudio = hasAudio
        self.audioTrack = audioTrack
        self.byteCount = byteCount; self.contentSHA256 = contentSHA256
    }

    /// Safe for a Store to call without a generation request. Only the inspector's
    /// full file pass can establish that these recorded facts are true.
    public func validateStoredMedia() throws {
        try frameRate.validate()
        let (duration, overflow) = Int64(frameCount).multipliedReportingOverflow(by: Int64(frameRate.denominator))
        let (_, areaOverflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, frameCount > 0, !overflow, !areaOverflow,
              durationNumerator == duration, durationDenominator == frameRate.numerator,
              codec == "h264", byteCount > 0,
              contentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              hasAudio == (audioTrack != nil) else {
            throw ProjectStoreError.invalidProject("视频元数据的尺寸、时间、音轨或文件摘要无效。")
        }
        guard let audioTrack else { return }
        guard audioTrack.codec == "aac", [32_000, 48_000].contains(audioTrack.sampleRate),
              audioTrack.channels == 2, audioTrack.decodedSampleCount > 0,
              audioTrack.startDenominator > 0,
              audioTrack.durationNumerator == audioTrack.decodedSampleCount,
              audioTrack.durationDenominator == Int32(audioTrack.sampleRate) else {
            throw ProjectStoreError.invalidProject("AAC 解码事实与音轨元数据不一致。")
        }
        let videoSeconds = Double(durationNumerator) / Double(durationDenominator)
        let audioStart = Double(audioTrack.startNumerator) / Double(audioTrack.startDenominator)
        let audioEnd = audioStart + Double(audioTrack.decodedSampleCount) / Double(audioTrack.sampleRate)
        let tolerance = Double(frameRate.denominator) / Double(frameRate.numerator)
            + 2 * 1024 / Double(audioTrack.sampleRate)
        guard videoSeconds.isFinite, audioStart.isFinite, audioEnd.isFinite,
              abs(audioStart) <= tolerance, abs(audioEnd - videoSeconds) <= tolerance else {
            throw ProjectStoreError.invalidProject("音轨与视频时间线未对齐。")
        }
    }

    public func validate(matching expected: VideoRequest) throws {
        let policy = try VideoOutputInspectionPolicy.resolve(for: expected)
        try validateStoredMedia()
        guard width == expected.width, height == expected.height, frameCount == expected.frameCount,
              frameRate == expected.frameRate,
              audioTrack?.sampleRate == policy.requiredAudioSampleRate else {
            throw ProjectStoreError.invalidProject("视频格式、时间基或音轨与生成请求不符。")
        }
    }
}
