import DInference
import Foundation

/// Registration/each admission verify the already installed approved fixture; never download.
public enum FixedTextModel {
    public static let title = "Qwen2.5 0.5B Instruct · 4-bit"
    public static func verify(at directory: URL) async throws -> ModelReference {
        try await TextModelProfiles.verifyOriginalHalfB(at: directory)
    }

    static func verify(at directory: URL, registration: TextModelRegistration,
                       options: TextModelVerificationOptions = TextModelVerificationOptions()) async throws -> ModelReference {
        try await TextModelProfiles.verifyOriginalHalfB(at: directory, registration: registration, options: options)
    }
}
