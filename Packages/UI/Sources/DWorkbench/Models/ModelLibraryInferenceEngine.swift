import DInference
import Foundation

/// Application admission for exact known resource copies, including old URL caches.
/// Unknown explicit references keep their existing adapter validation path.
public struct ModelLibraryInferenceEngine: InferenceEngine {
    private let base: any InferenceEngine
    private let library: ModelLibrary
    public init(base: any InferenceEngine, library: ModelLibrary) { self.base = base; self.library = library }
    public func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        guard let lease = try await library.acquireKnownResource(request.model) else {
            return try await base.submit(request, backendID: backendID)
        }
        do {
            let run = try await base.submit(request, backendID: backendID)
            let cursor = ModelLibraryEventCursor(run.events)
            let completion = Task {
                let result = await run.outcome()
                if case .failed(.resourceCleanupUnconfirmed) = result { return result }
                await library.release(lease)
                return result
            }
            return .init(id: run.id, nextEvent: { try await cursor.next() },
                cancel: { await run.cancel() }, outcome: { await completion.value },
                executionRecord: { await run.executionRecord() })
        } catch { await library.release(lease); throw error }
    }
}
private actor ModelLibraryEventCursor {
    private var iterator: InferenceEvents.AsyncIterator?
    init(_ events: InferenceEvents) { iterator = events.makeAsyncIterator() }
    func next() async throws -> InferenceOutput? {
        guard var current = iterator else { throw InferenceFailure.invalidRequest("Model event stream has one consumer.") }
        iterator = nil
        defer { iterator = current }
        return try await current.next(isolation: self)
    }
}
