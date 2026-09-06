import Foundation

public struct BackendDescriptor: Sendable, Codable, Equatable {
    public let id: String
    public let version: String
    public let capabilities: Set<InferenceCapability>

    public init(id: String, version: String, capabilities: Set<InferenceCapability>) {
        self.id = id
        self.version = version
        self.capabilities = capabilities
    }
}

public struct ResourceEstimate: Sendable, Codable, Equatable {
    public enum Confidence: String, Sendable, Codable { case estimated, measured }
    public let peakBytes: UInt64
    public let confidence: Confidence

    public init(peakBytes: UInt64, confidence: Confidence = .estimated) {
        self.peakBytes = peakBytes
        self.confidence = confidence
    }
}

/// A file reference avoids copying full-resolution media through the control/event plane.
/// The host owns artifact persistence; the backend must not delete returned artifacts in release().
public struct ArtifactReference: Sendable, Codable, Equatable {
    public let url: URL
    public let mediaType: String

    public init(url: URL, mediaType: String) {
        self.url = url
        self.mediaType = mediaType
    }
}

public enum InferenceOutput: Sendable, Equatable {
    case textDelta(String)
    case progress(completed: Int, total: Int)
    case preview(ArtifactReference)
    case artifact(ArtifactReference)
}

public struct InferenceResult: Sendable, Codable, Equatable {
    public let artifacts: [ArtifactReference]
    public let metadata: [String: String]

    public init(artifacts: [ArtifactReference] = [], metadata: [String: String] = [:]) {
        self.artifacts = artifacts
        self.metadata = metadata
    }
}

/// All calls for one submitted run are serialized by the runtime, including cleanup.
/// A backend instance belongs to ONE runtime; sharing it between runtimes needs its own exclusion.
public protocol InferenceBackend: Sendable {
    var descriptor: BackendDescriptor { get }

    /// Must not load model weights or begin inference. Include weights, workspace and cache in peakBytes.
    func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate

    /// Return only when ALL inference work has stopped, including internal tasks and GPU work.
    /// Propagate cancellation into any owned unstructured tasks and await their termination.
    /// Await emit, propagate its errors, and never retain or call it after execute returns.
    func execute(
        _ request: InferenceRequest,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async throws -> InferenceResult

    /// Idempotent cleanup, including partial load/error/cancel. Must complete despite task cancellation.
    /// First version releases per-run resources instead of keeping an unbudgeted model cache.
    func release() async
}
