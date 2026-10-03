import DInference
import Foundation

/// A single-consumer pull queue. It owns at most `capacity` accepted events.
/// Producers await capacity instead of losing deltas. No forwarding task or second stream buffer.
actor BoundedInferenceEvents {
    struct Snapshot: Sendable {
        let buffered: Int
        let peakBuffered: Int
        let capacityWaits: Int
        let pendingProducers: Int
        let accepted: Int
        let consumed: Int
        let capacityWaitSeconds: Double
    }
    private let capacity: Int
    private var values: [InferenceOutput] = []
    private var reader: (UUID, CheckedContinuation<InferenceOutput?, any Error>)?
    private var producers: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var terminal: Result<Void, any Error>?
    private var productionCancelled = false
    private var peakBuffered = 0
    private var capacityWaits = 0
    private var accepted = 0
    private var consumed = 0
    private var waitDuration: Duration = .zero

    init(capacity: Int) { self.capacity = capacity }

    func send(_ value: InferenceOutput) async throws {
        // A resumed sender can be cancelled before accepting the free slot.
        // Pass that slot on, including when this send throws during resumption.
        defer { resumeProducerIfSpace() }
        while values.count == capacity {
            try checkProduction()
            let id = UUID()
            let started = ContinuousClock.now
            defer { waitDuration += started.duration(to: .now) }
            capacityWaits += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { producers.append((id, continuation)) }
                }
            } onCancel: {
                Task { await self.cancelProducer(id) }
            }
        }
        try checkProduction()
        accepted += 1
        if let waiting = reader {
            reader = nil
            consumed += 1
            waiting.1.resume(returning: value)
        } else {
            values.append(value)
            peakBuffered = max(peakBuffered, values.count)
        }
    }

    func next() async throws -> InferenceOutput? {
        try Task.checkCancellation()
        if !values.isEmpty {
            let value = values.removeFirst()
            consumed += 1
            resumeProducerIfSpace()
            return value
        }
        if let terminal { try terminal.get(); return nil }
        // InferenceRun is explicitly single-consumer; reject accidental parallel iterators.
        guard reader == nil else { throw InferenceFailure.invalidRequest("Inference output has more than one consumer.") }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { reader = (id, continuation) }
            }
        } onCancel: {
            Task { await self.cancelReader(id) }
        }
    }

    /// Stop blocked emit calls immediately, but do not finish output before backend release.
    func cancelProduction() {
        productionCancelled = true
        let pending = producers; producers.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
    }

    /// Already accepted events drain before terminal error/EOF. Called after backend release.
    func finish(_ result: Result<Void, any Error>) {
        guard terminal == nil else { return }
        terminal = result
        cancelProduction()
        if let waiting = reader {
            reader = nil
            switch result {
            case .success: waiting.1.resume(returning: nil)
            case .failure(let error): waiting.1.resume(throwing: error)
            }
        }
    }

    func snapshot() -> Snapshot {
        let components = waitDuration.components
        return Snapshot(buffered: values.count, peakBuffered: peakBuffered,
                 capacityWaits: capacityWaits, pendingProducers: producers.count,
                 accepted: accepted, consumed: consumed,
                 capacityWaitSeconds: Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    private func checkProduction() throws {
        try Task.checkCancellation()
        if productionCancelled || terminal != nil { throw CancellationError() }
    }
    private func cancelProducer(_ id: UUID) {
        guard let index = producers.firstIndex(where: { $0.0 == id }) else { return }
        producers.remove(at: index).1.resume(throwing: CancellationError())
        resumeProducerIfSpace()
    }
    private func resumeProducerIfSpace() {
        if values.count < capacity, !producers.isEmpty { producers.removeFirst().1.resume() }
    }
    private func cancelReader(_ id: UUID) {
        guard reader?.0 == id, let waiting = reader else { return }
        reader = nil
        waiting.1.resume(throwing: CancellationError())
    }
}
