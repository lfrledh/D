import Foundation
import Observation

public struct WorkflowCallActivity: Equatable, Sendable {
    public let graphID: UUID?
    public let address: WorkflowExecutionAddress?
    public let stepID: UUID
    public let nodeID: UUID
    public let modelIdentity: String?
    public var requestID: UUID?
    public var phase: String
    public var progress: String?
    public var elapsedSeconds: Double
    public var finished: Bool
}
/// One service-owned presentation leaf. No checkpoint writes, history revisions,
/// model leases or per-card clocks. Lifetime and clearing follow the service.
@MainActor @Observable public final class WorkflowCallActivityState {
    public private(set) var current: WorkflowCallActivity?
    @ObservationIgnored private var started: ContinuousClock.Instant?
    func begin(_ context: WorkflowExecutionContext) {
        started = .now
        current = .init(graphID: context.graphID, address: context.address, stepID: context.stepID,
            nodeID: context.node.id, modelIdentity: context.node.parameters["modelID"]?.string,
            phase: "preparing", elapsedSeconds: 0, finished: false)
    }
    func update(requestID: UUID? = nil, phase: String? = nil, progress: String? = nil) {
        guard var value = current, !value.finished else { return }
        if let requestID { value.requestID = requestID }
        if let phase { value.phase = phase }
        if let progress { value.progress = progress }
        if let started {
            let elapsed = started.duration(to: .now).components
            value.elapsedSeconds = (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * 10
            value.elapsedSeconds = value.elapsedSeconds.rounded(.down) / 10
        }
        if value != current { current = value }
    }
    func end(phase: String) { update(phase: phase); current?.finished = true; started = nil }
}
