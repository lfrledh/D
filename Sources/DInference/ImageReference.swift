import Foundation

/// A frozen local, row-major RGB8 sRGB payload. No header, alpha, orientation or
/// resizing is implicit. The host owns original media and prepares this derivative.
public struct ImageReference: Codable, Equatable, Sendable {
    public let url: URL
    public let sha256: String
    public let byteCount: UInt64
    public let width: Int
    public let height: Int
    public let encoding: String

    public init(url: URL, sha256: String, byteCount: UInt64, width: Int, height: Int,
                encoding: String = "rgb8-srgb-v1") {
        self.url = url; self.sha256 = sha256; self.byteCount = byteCount
        self.width = width; self.height = height; self.encoding = encoding
    }

    public func validate() throws {
        guard url.isFileURL, url.path.hasPrefix("/"), encoding == "rgb8-srgb-v1",
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (256...2048).contains(width), (256...2048).contains(height),
              width.isMultiple(of: 32), height.isMultiple(of: 32),
              byteCount == UInt64(width * height * 3) else {
            throw InferenceFailure.invalidRequest("Invalid frozen image reference: RGB8 sRGB, SHA-256 and 256...2048 dimensions in multiples of 32 are required.")
        }
    }
}
