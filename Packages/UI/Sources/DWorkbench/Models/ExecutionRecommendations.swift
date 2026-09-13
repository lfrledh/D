import Foundation

/// Optional starting points, independent of adapter support and runtime admission.
/// These are conservative heuristics, never evidence of validation on that machine.
public struct ExecutionRecommendations: Sendable, Equatable {
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let imageDimension: Int

    public static func forMemory(bytes: UInt64) -> Self? {
        guard bytes > 0 else { return nil }
        let gib = bytes / (1024 * 1024 * 1024)
        switch gib {
        case 128...: return Self(maximumPromptTokens: 32768, maximumOutputTokens: 2048, imageDimension: 2048)
        case 96..<128: return Self(maximumPromptTokens: 16384, maximumOutputTokens: 2048, imageDimension: 1536)
        case 64..<96: return Self(maximumPromptTokens: 8192, maximumOutputTokens: 1024, imageDimension: 1024)
        case 32..<64: return Self(maximumPromptTokens: 4096, maximumOutputTokens: 512, imageDimension: 768)
        default: return Self(maximumPromptTokens: 2048, maximumOutputTokens: 256, imageDimension: 512)
        }
    }
}
