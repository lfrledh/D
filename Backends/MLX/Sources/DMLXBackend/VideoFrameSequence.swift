import Foundation

/// Private, completed frame spool. Pixels are packed, top-to-bottom RGB8, with no alpha.
/// V0 explicitly interprets generated display RGB as full-range Rec.709; this is an
/// output interpretation, not a claim about the training data's color space.
internal struct VideoFrameSequence: Sendable {
    let rawURL: URL
    let width: Int
    let height: Int
    let frameCount: Int
    let fpsNumerator: Int32
    let fpsDenominator: Int32
    let sha256: String

    func validatedByteCounts() throws -> (frame: Int, total: Int64) {
        guard rawURL.isFileURL, rawURL.path.hasPrefix("/"), !rawURL.path.contains("\0"),
              width > 0, height > 0, frameCount > 0,
              fpsNumerator > 0, fpsDenominator > 0,
              sha256.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw VideoMediaError.invalidInput("Invalid frame geometry, time base, local path or SHA-256.")
        }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (frame, frameOverflow) = pixels.multipliedReportingOverflow(by: 3)
        let (total, totalOverflow) = Int64(frame).multipliedReportingOverflow(by: Int64(frameCount))
        let (_, timeOverflow) = Int64(frameCount).multipliedReportingOverflow(by: Int64(fpsDenominator))
        guard !pixelOverflow, !frameOverflow, !totalOverflow, !timeOverflow, frame > 0, total > 0 else {
            throw VideoMediaError.invalidInput("Frame size or timeline exceeds the supported integer representation.")
        }
        return (frame, total)
    }
}

/// Caller-selected resource policy, separate from a model's supported geometry.
internal struct VideoMediaLimits: Sendable {
    let maximumFrameBytes: UInt64
    let maximumOutputBytes: UInt64
    let timeoutSeconds: Double
}

internal struct VideoMediaInspection: Codable, Sendable {
    let width: Int
    let height: Int
    let frameCount: Int
    let fpsNumerator: Int32
    let fpsDenominator: Int32
    let durationNumerator: Int64
    let durationDenominator: Int32
    let byteCount: UInt64
    let sha256: String
    let codec: String
    let colorInterpretation: String
}

internal enum VideoMediaError: Error, LocalizedError {
    case invalidInput(String)
    case io(String)
    case encoding(String)
    case verification(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .io(let message), .encoding(let message), .verification(let message): message
        case .timedOut: "Video media operation exceeded its deadline."
        }
    }
}
