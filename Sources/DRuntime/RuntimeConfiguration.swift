import DInference
import Foundation

public struct RuntimeConfiguration: Sendable {
    public let memoryBudgetBytes: UInt64
    public let maximumQueuedRuns: Int
    public let eventBufferCapacity: Int
    public let allowsRequestBudgetIncrease: Bool

    public init(memoryBudgetBytes: UInt64, maximumQueuedRuns: Int = 8,
                eventBufferCapacity: Int = 256, allowsRequestBudgetIncrease: Bool = false) throws {
        guard memoryBudgetBytes > 0, maximumQueuedRuns >= 0, eventBufferCapacity > 0 else {
            throw InferenceFailure.invalidRequest("Invalid runtime budget or queue/buffer capacity.")
        }
        self.memoryBudgetBytes = memoryBudgetBytes
        self.maximumQueuedRuns = maximumQueuedRuns
        self.eventBufferCapacity = eventBufferCapacity
        self.allowsRequestBudgetIncrease = allowsRequestBudgetIncrease
    }

    func budget(for request: DInference.InferenceRequest) throws -> UInt64 {
        guard let selected = request.memoryBudgetBytes else { return memoryBudgetBytes }
        guard selected <= memoryBudgetBytes || allowsRequestBudgetIncrease else {
            throw InferenceFailure.invalidRequest("This host does not allow requests to increase its memory budget.")
        }
        return selected
    }
}

public struct RuntimeSnapshot: Sendable, Equatable {
    public enum Phase: String, Sendable { case preparing, running, cancelling, releasing }
    public let activeRunID: UUID?
    public let phase: Phase?
    public let queuedRunIDs: [UUID]
    public let reservedBytes: UInt64
}
