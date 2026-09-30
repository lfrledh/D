import Foundation

/// Frozen, encoded source media. The backend verifies bytes and format before decoding.
public struct TextImageReference: Codable, Equatable, Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let byteCount: UInt64
    public let contentSHA256: String

    public init(url: URL, width: Int, height: Int, byteCount: UInt64, contentSHA256: String) {
        self.url = url; self.width = width; self.height = height
        self.byteCount = byteCount; self.contentSHA256 = contentSHA256
    }

    public func validate() throws {
        guard Self.local(url), ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
              width > 0, height > 0, width <= 131_072, height <= 131_072,
              !width.multipliedReportingOverflow(by: height).overflow,
              (1...128 * 1024 * 1024).contains(byteCount), Self.digest(contentSHA256) else {
            throw InferenceFailure.invalidRequest("Invalid encoded image reference.")
        }
    }
}

public struct TextVideoReference: Codable, Equatable, Sendable {
    public let url: URL
    public let byteCount: UInt64
    public let contentSHA256: String
    public let durationSeconds: Double

    public init(url: URL, byteCount: UInt64, contentSHA256: String, durationSeconds: Double) {
        self.url = url; self.byteCount = byteCount; self.contentSHA256 = contentSHA256
        self.durationSeconds = durationSeconds
    }

    public func validate() throws {
        guard TextImageReference.local(url), url.pathExtension.lowercased() == "mp4",
              (1...2 * 1024 * 1024 * 1024).contains(byteCount),
              TextImageReference.digest(contentSHA256),
              durationSeconds.isFinite, durationSeconds > 0 else {
            throw InferenceFailure.invalidRequest("Invalid MP4 video reference.")
        }
    }
}

public struct TextVisualProcessing: Codable, Equatable, Sendable {
    public let minimumPixels: Int?
    public let maximumPixels: Int?
    public let maximumVideoFrames: Int
    public let videoSamplingFPS: Int

    public init(minimumPixels: Int? = nil, maximumPixels: Int? = nil,
                maximumVideoFrames: Int = 64, videoSamplingFPS: Int = 2) {
        self.minimumPixels = minimumPixels; self.maximumPixels = maximumPixels
        self.maximumVideoFrames = maximumVideoFrames; self.videoSamplingFPS = videoSamplingFPS
    }

    public func validate() throws {
        guard minimumPixels.map({ $0 > 0 }) ?? true,
              maximumPixels.map({ $0 > 0 }) ?? true,
              maximumPixels.map({ $0 <= Int.max / 64 }) ?? true,
              (minimumPixels ?? 1) <= (maximumPixels ?? Int.max),
              maximumVideoFrames > 0, videoSamplingFPS == 2 else {
            throw InferenceFailure.invalidRequest("Invalid Qwen3.5 visual processing budget.")
        }
    }
}

extension TextImageReference {
    static func local(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.pathComponents.contains("..") &&
        (url.host == nil || url.host == "" || url.host == "localhost")
    }

    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
