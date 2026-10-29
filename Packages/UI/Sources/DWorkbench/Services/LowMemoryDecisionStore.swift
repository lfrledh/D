import DInference
import Foundation
import Observation
import Synchronization

/// App-owned decision for the runtime's one active request. It owns no model,
/// queue or execution task and survives workspace/selection changes.
@MainActor @Observable public final class LowMemoryDecisionStore {
    public enum Preference: String, CaseIterable, Sendable { case ask, allow, deny }
    public static let preferenceKey = "D.lowMemoryExecutionPreference.v1"
    public private(set) var preference: Preference
    public private(set) var pending: LowMemoryProposal?
    @ObservationIgnored private let settings: UserDefaults
    private final class Ticket: Sendable {
        enum State { case pending, decided, cancelled }
        let state = Mutex(State.pending)
        func cancel() { state.withLock { if $0 == .pending { $0 = .cancelled } } }
        func claim() -> Bool { state.withLock { guard $0 == .pending else { return false }; $0 = .decided; return true } }
    }
    @ObservationIgnored private var ticket: Ticket?
    @ObservationIgnored private var continuation: CheckedContinuation<LowMemoryDecision, Error>?

    public init(settings: UserDefaults = .standard) {
        self.settings = settings
        preference = settings.string(forKey: Self.preferenceKey).flatMap(Preference.init(rawValue:)) ?? .ask
    }
    public func setPreference(_ value: Preference) {
        preference = value
        settings.set(value.rawValue, forKey: Self.preferenceKey)
    }
    public func decide(_ proposal: LowMemoryProposal) async throws -> LowMemoryDecision {
        try Task.checkCancellation()
        switch preference {
        case .allow: return .allowedByPreference
        case .deny: return .denyByPreference
        case .ask: break
        }
        guard pending == nil, continuation == nil else {
            throw InferenceFailure.invalidRequest("A low-memory decision is already pending.")
        }
        let ticket = Ticket()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { reply in
                guard !Task.isCancelled else { reply.resume(throwing: CancellationError()); return }
                pending = proposal
                self.ticket = ticket
                continuation = reply
            }
        } onCancel: { [weak self] in
            ticket.cancel()
            Task { @MainActor in self?.cancel(proposalID: proposal.id, entryToken: proposal.entryToken) }
        }
    }
    /// Only a deliberate affirmative action can persist allow. Stale UI is inert.
    @discardableResult public func resolve(proposalID: UUID, entryToken: UUID,
                                           allow: Bool, remember: Bool = false) -> Bool {
        guard pending?.id == proposalID, pending?.entryToken == entryToken, let reply = continuation else { return false }
        guard ticket?.claim() == true else {
            cancel(proposalID: proposalID, entryToken: entryToken)
            return false
        }
        pending = nil; continuation = nil; ticket = nil
        if allow && remember { setPreference(.allow) }
        reply.resume(returning: allow ? .allowOnce : .userStopped)
        return true
    }
    private func cancel(proposalID: UUID, entryToken: UUID) {
        guard pending?.id == proposalID, pending?.entryToken == entryToken, let reply = continuation else { return }
        ticket?.cancel()
        pending = nil; continuation = nil; ticket = nil
        reply.resume(throwing: CancellationError())
    }
}

/// Presentation derives from the saved decision; old cancellation diagnostics stay intact.
public enum LowMemoryExecutionPresentation {
    public static func nonExecutionCode(_ records: [InferenceExecutionRecord]?) -> String? {
        guard let record = records?.last, record.executionStarted == false, record.state == .stopped else { return nil }
        switch record.decision {
        case .userStopped: return "memory.stopped"
        case .denyByPreference: return "memory.denied"
        default: return nil
        }
    }
}
