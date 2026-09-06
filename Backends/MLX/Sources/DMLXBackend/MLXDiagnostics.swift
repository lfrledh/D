import Foundation
import MLX

/// MLX allocator statistics for this process, not system RSS or an OOM guarantee.
public struct MLXMemorySnapshot: Sendable, Codable, Equatable {
    public let activeBytes: Int
    public let cacheBytes: Int
    public let peakBytes: Int

    public static func capture() -> Self {
        let value = Memory.snapshot()
        return Self(activeBytes: value.activeMemory, cacheBytes: value.cacheMemory,
                    peakBytes: value.peakMemory)
    }
}

public struct MLXLifecycleEvent: Sendable, Codable {
    public enum Phase: String, Sendable, Codable {
        case loading, loaded, generating, drained, released
        case verifying, tokenizing, loadingTextEncoder, textEncoderLoaded, encoding, encoded
        case loadingTransformer, transformerLoaded, denoising, loadingVAE, vaeLoaded
        case decoding, decoded, publishing
    }
    public let runID: UUID
    public let phase: Phase
    public let uptimeSeconds: Double
    public let memory: MLXMemorySnapshot

    init(runID: UUID, phase: Phase) {
        self.runID = runID
        self.phase = phase
        self.uptimeSeconds = ProcessInfo.processInfo.systemUptime
        self.memory = .capture()
    }
}

public struct MLXBackendConfiguration: Sendable {
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let cacheLimitBytes: Int

    public init(maximumPromptTokens: Int = 2048, maximumOutputTokens: Int = 1024,
                cacheLimitBytes: Int = 64 * 1024 * 1024) {
        self.maximumPromptTokens = maximumPromptTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.cacheLimitBytes = cacheLimitBytes
    }
}
