import Foundation

/// A prepared model pack selects only a code-defined recipe. Executables, paths,
/// device defaults and commands never come from a weight directory's manifest.
public struct ExternalVideoModelManifest: Sendable, Codable, Equatable {
    public static let filename = "D-VIDEO-PACK.json"
    public let schemaVersion: Int
    public let profile: ExternalVideoExecutionProfile
    public let modelRevision: String
    public let textEncoderRevision: String?
    public init(profile: ExternalVideoExecutionProfile) {
        schemaVersion = 1; self.profile = profile
        modelRevision = profile.modelRevision; textEncoderRevision = profile.textEncoderRevision
    }
    public func validate() throws {
        guard schemaVersion == 1, modelRevision == profile.modelRevision,
              textEncoderRevision == profile.textEncoderRevision else {
            throw InferenceFailure.invalidRequest("Video pack identity does not match the pinned recipe.")
        }
    }
}

public extension ExternalVideoExecutionProfile {
    var modelRevision: String {
        switch self {
        case .h3BF16Full: "42ed227ee7df40d41602854ae760620d6eb651fe"
        case .ltx23BF16Full: "cfc837526e56abf8657823a0ae192eec3a40177d"
        case .ltx23Q8GemmaQ4: "6671a7572a530862d1d60ce393b5d93491e3f76b"
        case .ltx25BF16Full: "e378b7e1b50fcb1795fce74219b40bb0b1ede1e2"
        }
    }
    var textEncoderRevision: String? {
        switch self {
        case .ltx23BF16Full: "b8b9b412cb795bd6115fdce8c9a0ef0d1664db3a"
        case .ltx23Q8GemmaQ4: "86cc6a8dedbc456dd0e4af01a9d09f396f77e558"
        case .h3BF16Full, .ltx25BF16Full: nil // Inside the pinned model pack.
        }
    }
    /// Quantization/profile identity remains distinct even if revisions share a family.
    var modelIdentity: String { rawValue + "@" + modelRevision }
    var backendID: String { "local.video." + rawValue }
}
