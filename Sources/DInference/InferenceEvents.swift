import Foundation

/// Single-consumer event sequence with cancellation at the iterator boundary.
/// Unlike AsyncThrowingStream(unfolding:), cancellation before the first pull must
/// still notify the runtime that owns the producer. Existing stream-based engines
/// remain supported by InferenceRun's original initializer.
public struct InferenceEvents: AsyncSequence, Sendable {
    public typealias Element = InferenceOutput
    private let stream: AsyncThrowingStream<InferenceOutput, Error>?
    private let pull: (@Sendable () async throws -> InferenceOutput?)?
    private let cancel: @Sendable () async -> Void

    init(stream: AsyncThrowingStream<InferenceOutput, Error>, cancel: @escaping @Sendable () async -> Void) {
        self.stream = stream; self.pull = nil; self.cancel = cancel
    }
    init(pull: @escaping @Sendable () async throws -> InferenceOutput?, cancel: @escaping @Sendable () async -> Void) {
        self.stream = nil; self.pull = pull; self.cancel = cancel
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream?.makeAsyncIterator(), pull: pull, cancel: cancel)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var iterator: AsyncThrowingStream<InferenceOutput, Error>.AsyncIterator?
        fileprivate let pull: (@Sendable () async throws -> InferenceOutput?)?
        fileprivate let cancel: @Sendable () async -> Void

        public mutating func next() async throws -> InferenceOutput? {
            let cancel = cancel
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if let pull { return try await pull() }
                return try await iterator?.next()
            } onCancel: {
                Task { await cancel() }
            }
        }
    }
}
