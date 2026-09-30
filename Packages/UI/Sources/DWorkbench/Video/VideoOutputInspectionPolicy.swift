import DInference

/// The media contract follows the exact, validated execution recipe, never the
/// dimensions or the apparent contents of a file.
public enum VideoOutputInspectionPolicy: Sendable, Equatable {
    case wanSilent
    case h3FL2VA
    case ltx23BF16
    case ltx23Q8GemmaQ4
    case ltx25BF16

    public static func resolve(for request: VideoRequest) throws -> Self {
        if request.executionProfile == VideoExecutionCapability.wan21.profile {
            try VideoExecutionCapability.wan21.validate(request)
            return .wanSilent
        }
        guard let external = ExternalVideoExecutionProfile(rawValue: request.executionProfile.identifier) else {
            throw VideoInspectionError.invalid("未知视频执行配方")
        }
        try external.validate(request) // Includes the exact revision and typed adapter options.
        switch external {
        case .h3BF16Full: return .h3FL2VA
        case .ltx23BF16Full: return .ltx23BF16
        case .ltx23Q8GemmaQ4: return .ltx23Q8GemmaQ4
        case .ltx25BF16Full: return .ltx25BF16
        }
    }

    public var requiredAudioSampleRate: Int? {
        switch self {
        case .wanSilent: nil
        case .h3FL2VA: 32_000
        case .ltx23BF16, .ltx23Q8GemmaQ4, .ltx25BF16: 48_000
        }
    }
}
