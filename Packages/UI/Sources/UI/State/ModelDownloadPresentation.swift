import Foundation
import DWorkbench

/// Panel-owned, capacity one, matching the library's single transfer slot.
/// A new attempt/generation, pause, hidden panel or byte rollback resets history.
struct ModelDownloadRate {
    struct Identity: Equatable { let task: UUID; let attempt: UUID; let generation: UUID }
    private(set) var identity: Identity?
    private var bytes: UInt64 = 0
    private var instant: ContinuousClock.Instant?
    private(set) var bytesPerSecond: Double?
    mutating func sample(identity next: Identity?, bytes nextBytes: UInt64, now: ContinuousClock.Instant = .now) {
        guard let next else { self = .init(); return }
        guard identity == next, let instant, nextBytes >= bytes else {
            identity = next; bytes = nextBytes; self.instant = now; bytesPerSecond = nil; return
        }
        let duration = instant.duration(to: now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        guard seconds >= 0.5 else { return }
        bytesPerSecond = seconds <= 3 ? Double(nextBytes - bytes) / seconds : nil
        bytes = nextBytes; self.instant = now
    }
}

enum ModelDownloadListFilter {
    static let values = ["all", "downloading", "queued", "paused", "attention", "completed", "stopped"]
    static func includes(_ task: ModelDownloadTask, filter: String) -> Bool {
        switch filter {
        case "downloading": task.state.isActive
        case "queued": task.state == .queued
        case "paused": task.state == .paused
        case "attention": task.state == .failed || task.state == .waitingRetry || task.postActionError != nil
        case "completed": task.state == .completed
        case "stopped": task.state == .cancelled
        // Retain old view-state semantics until the user explicitly changes its filter.
        case "active": !task.state.isTerminal
        case "history": task.state.isTerminal
        default: true
        }
    }
}
