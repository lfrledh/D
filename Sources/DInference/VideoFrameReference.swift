import Foundation

/// A reference to frozen PNG encoded bytes supplied as a video condition.
/// The byte limit bounds parsing; it is not a model image size limit.
public struct VideoFrameReference: Sendable, Codable, Equatable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let byteCount: UInt64
    public let contentSHA256: String

    public init(url: URL, width: Int, height: Int, byteCount: UInt64, contentSHA256: String) {
        self.url = url
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.contentSHA256 = contentSHA256
    }

    public func validate() throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              !url.pathComponents.contains(".."),
              url.host == nil || url.host == "" || url.host == "localhost",
              width > 0, height > 0,
              !width.multipliedReportingOverflow(by: height).overflow,
              byteCount > 0, byteCount <= 64 * 1_048_576,
              contentSHA256.utf8.count == 64,
              contentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw InferenceFailure.invalidRequest("Invalid PNG frame reference or parser byte budget.")
        }
    }
}
