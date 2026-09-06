import DInference
import Foundation

/// A bounded FIFO scheduler. Actor reentrancy alone does not serialize whole async jobs;
/// activeRunID is an explicit lease retained through estimate, execute, drain, and release.
public actor InferenceRuntime: InferenceEngine {
    private struct Entry {
        let token: UUID
        let request: InferenceRequest
        let backend: any InferenceBackend
        let continuation: AsyncThrowingStream<InferenceOutput, Error>.Continuation
        let completion: RunCompletion
        var cancellationRequested = false
    }

    private let configuration: RuntimeConfiguration
    private let backends: [String: any InferenceBackend]
    private var entries: [UUID: Entry] = [:]
    private var queue: [UUID] = []
    private var activeRunID: UUID?
    private var phase: RuntimeSnapshot.Phase?
    private var reservedBytes: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var isClosed = false

    public init(backends: [any InferenceBackend], configuration: RuntimeConfiguration) throws {
        var registry: [String: any InferenceBackend] = [:]
        for backend in backends {
            let id = backend.descriptor.id
            guard !id.isEmpty, registry[id] == nil else {
                throw InferenceFailure.invalidRequest("Backend IDs must be unique and nonempty.")
            }
            registry[id] = backend
        }
        self.backends = registry
        self.configuration = configuration
    }

    public func submit(_ request: InferenceRequest, backendID: String) throws -> InferenceRun {
        try Task.checkCancellation()
        guard !isClosed else { throw InferenceFailure.runtimeClosed }
        try request.validate()
        guard let backend = backends[backendID] else { throw InferenceFailure.unknownBackend(backendID) }
        guard backend.descriptor.capabilities.contains(request.input.capability) else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        guard entries[request.id] == nil else { throw InferenceFailure.duplicateRun }
        guard activeRunID == nil || queue.count < configuration.maximumQueuedRuns else {
            throw InferenceFailure.queueFull
        }
        let (stream, continuation) = AsyncThrowingStream<InferenceOutput, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(configuration.eventBufferCapacity)
        )
        let completion = RunCompletion()
        let id = request.id
        let token = UUID()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.cancel(id, token: token) }
            }
        }
        entries[id] = Entry(token: token, request: request, backend: backend,
                            continuation: continuation, completion: completion)
        queue.append(id)
        startNextIfIdle()
        return InferenceRun(id: id, events: stream,
                            cancel: { [weak self] in await self?.cancel(id, token: token) },
                            outcome: { await completion.wait() })
    }

    public func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(activeRunID: activeRunID, phase: phase,
                        queuedRunIDs: queue, reservedBytes: reservedBytes)
    }

    /// Requests cancellation. The active slot remains occupied until the backend actually drains.
    public func cancel(_ id: UUID) async {
        guard var entry = entries[id] else { return }
        entry.cancellationRequested = true
        entries[id] = entry
        if activeRunID == id {
            phase = .cancelling
            worker?.cancel()
        } else {
            queue.removeAll { $0 == id }
            entries.removeValue(forKey: id)
            entry.continuation.finish(throwing: CancellationError())
            await entry.completion.resolve(.cancelled)
        }
    }

    // A stale run handle must never cancel a newer submission that reused the same public ID.
    private func cancel(_ id: UUID, token: UUID) async {
        guard entries[id]?.token == token else { return }
        await cancel(id)
    }

    /// Cancels the current batch. Later submissions remain allowed; use shutdown() for teardown.
    public func cancelAllAndWait() async {
        let batch = entries
        let activeAtCancellation = activeRunID
        queue.removeAll()
        // Mark the whole batch before the first await, so a queued run cannot slip into execution.
        for (id, var entry) in batch {
            entry.cancellationRequested = true
            if activeAtCancellation == id {
                entries[id] = entry
                phase = .cancelling
            } else {
                entries.removeValue(forKey: id)
                entry.continuation.finish(throwing: CancellationError())
            }
        }
        worker?.cancel()
        for (id, entry) in batch where id != activeAtCancellation {
            await entry.completion.resolve(.cancelled)
        }
        for entry in batch.values { _ = await entry.completion.wait() }
    }

    /// Permanently closes admission, then waits for this runtime's work to drain.
    /// Cooperative cancellation cannot forcibly stop an unresponsive in-process backend.
    public func shutdown() async {
        isClosed = true
        await cancelAllAndWait()
    }

    private func startNextIfIdle() {
        guard activeRunID == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        activeRunID = id
        phase = .preparing
        worker = Task { await self.perform(id) }
    }

    private func perform(_ id: UUID) async {
        guard let entry = entries[id] else { return }
        var outcome: RunOutcome
        do {
            try checkCancellation(id)
            let estimate = try await entry.backend.estimate(entry.request)
            try checkCancellation(id)
            guard estimate.peakBytes > 0 else { throw InferenceFailure.invalidResourceEstimate }
            guard estimate.peakBytes <= configuration.memoryBudgetBytes else {
                throw InferenceFailure.memoryBudgetExceeded(
                    required: estimate.peakBytes, limit: configuration.memoryBudgetBytes)
            }
            reservedBytes = estimate.peakBytes
            phase = .running
            let result = try await entry.backend.execute(entry.request) { output in
                try await self.emit(output, for: id, token: entry.token)
            }
            try checkCancellation(id)
            outcome = .completed(result)
        } catch is CancellationError {
            outcome = .cancelled
        } catch let failure as InferenceFailure {
            outcome = .failed(failure)
        } catch {
            outcome = .failed(.backendFailed(error.localizedDescription))
        }

        // No next run may start while cleanup is suspended, even if cancellation arrives again.
        phase = .releasing
        await entry.backend.release()
        if entries[id]?.cancellationRequested == true { outcome = .cancelled }
        switch outcome {
        case .completed: entry.continuation.finish()
        case .cancelled: entry.continuation.finish(throwing: CancellationError())
        case .failed(let failure): entry.continuation.finish(throwing: failure)
        }
        // Commit all scheduler state together before the completion actor can suspend
        // us. Otherwise a resubmission can reuse id while activeRunID still identifies
        // the preceding run, and batch cancellation can strand that new queued entry.
        entries.removeValue(forKey: id)
        reservedBytes = 0
        activeRunID = nil
        phase = nil
        worker = nil
        // release has finished. A reentrant submission may start the FIFO head during
        // this await; after resuming, never clear or replace that newer run's state.
        await entry.completion.resolve(outcome)
        startNextIfIdle()
    }

    private func checkCancellation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard entries[id]?.cancellationRequested == false else { throw CancellationError() }
    }

    private func emit(_ output: InferenceOutput, for id: UUID, token: UUID) throws {
        guard entries[id]?.token == token else { throw CancellationError() }
        try checkCancellation(id)
        guard activeRunID == id, let entry = entries[id] else { throw CancellationError() }
        switch entry.continuation.yield(output) {
        case .enqueued: break
        case .dropped: throw InferenceFailure.consumerTooSlow
        case .terminated: throw CancellationError()
        @unknown default: throw InferenceFailure.consumerTooSlow
        }
    }
}
