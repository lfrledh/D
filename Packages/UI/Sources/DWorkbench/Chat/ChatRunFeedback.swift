import Foundation

/// Only measured backend/application metadata, never byte counts masquerading as tokens.
public struct ChatRunFeedback: Sendable, Equatable {
    public let promptTokens: UInt64?
    public let generationTokens: UInt64?
    public let applicationSeconds: Double?
    public let generationSeconds: Double?
    public let loadingStrategy: String?

    public init(metadata: [String: String]) {
        func count(_ key: String) -> UInt64? {
            guard let value = metadata[key], let parsed = UInt64(value), String(parsed) == value else { return nil }
            return parsed
        }
        func duration(_ key: String) -> Double? {
            guard let value = metadata[key], let parsed = Double(value), parsed.isFinite, parsed >= 0 else { return nil }
            return parsed
        }
        promptTokens = count("promptTokens"); generationTokens = count("generationTokens")
        applicationSeconds = duration("application.stream.seconds")
        generationSeconds = duration("generationSeconds")
        loadingStrategy = ["resident", "ssdLayered"].contains(metadata["loadingStrategy"] ?? "") ? metadata["loadingStrategy"] : nil
    }
}
