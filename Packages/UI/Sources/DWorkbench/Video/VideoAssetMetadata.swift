import DInference
import Foundation

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
    public let byteCount: UInt64
    public let contentSHA256: String

    public init(width: Int, height: Int, frameCount: Int, frameRate: VideoFrameRate,
                durationNumerator: Int64, durationDenominator: Int32, codec: String,
                hasAudio: Bool, byteCount: UInt64, contentSHA256: String) {
        self.width = width; self.height = height; self.frameCount = frameCount
        self.frameRate = frameRate; self.durationNumerator = durationNumerator
        self.durationDenominator = durationDenominator; self.codec = codec; self.hasAudio = hasAudio
        self.byteCount = byteCount; self.contentSHA256 = contentSHA256
    }

    public func validate(matching expected: VideoRequest) throws {
        try VideoExecutionCapability.wan21.validate(expected)
        guard width == expected.width, height == expected.height, frameCount == expected.frameCount,
              frameRate == expected.frameRate,
              durationNumerator == Int64(frameCount) * Int64(frameRate.denominator),
              durationDenominator == frameRate.numerator, codec == "h264", !hasAudio, byteCount > 0,
              contentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ProjectStoreError.invalidProject("视频格式、时间基或文件摘要与生成请求不符。")
        }
    }
}
