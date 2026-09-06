import Foundation

public enum InferenceFailure: Error, Sendable, Codable, Equatable, LocalizedError {
    case invalidRequest(String)
    case unknownBackend(String)
    case unsupportedCapability(InferenceCapability)
    case duplicateRun
    case queueFull
    case runtimeClosed
    case invalidResourceEstimate
    case memoryBudgetExceeded(required: UInt64, limit: UInt64)
    case consumerTooSlow
    case backendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): reason
        case .unknownBackend(let id): "Unknown inference backend: \(id)"
        case .unsupportedCapability(let capability): "Unsupported capability: \(capability.rawValue)"
        case .duplicateRun: "This run ID is already active or queued."
        case .queueFull: "The inference queue is full."
        case .runtimeClosed: "The inference runtime has been shut down."
        case .invalidResourceEstimate: "The backend did not provide a positive memory estimate."
        case .memoryBudgetExceeded(let required, let limit): "Estimated memory \(required) exceeds budget \(limit)."
        case .consumerTooSlow: "Output buffer is full; inference stopped to avoid silently losing output."
        case .backendFailed(let reason): reason
        }
    }
}

public enum RunOutcome: Sendable, Equatable {
    case completed(InferenceResult)
    case cancelled
    case failed(InferenceFailure)
}

/// Single-consumer output stream. Draining it also surfaces buffer overflow/backend errors.
/// outcome() is authoritative: it resolves only after backend cleanup, even on cancellation.
/// Call cancel() when abandoning a run; merely retaining an unconsumed handle does not cancel it.
public struct InferenceRun: Sendable {
    public let id: UUID
    public let events: AsyncThrowingStream<InferenceOutput, Error>
    private let cancelOperation: @Sendable () async -> Void
    private let outcomeOperation: @Sendable () async -> RunOutcome

    public init(id: UUID, events: AsyncThrowingStream<InferenceOutput, Error>,
                cancel: @escaping @Sendable () async -> Void,
                outcome: @escaping @Sendable () async -> RunOutcome) {
        self.id = id
        self.events = events
        self.cancelOperation = cancel
        self.outcomeOperation = outcome
    }

    public func cancel() async { await cancelOperation() }
    public func outcome() async -> RunOutcome { await outcomeOperation() }
}

/// The same entry point can be used by a workbench, headless caller, or future assistant harness.
public protocol InferenceEngine: Sendable {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun
}
