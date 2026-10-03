import DInference
import Foundation

/// Owns authoritative deltas away from MainActor. The display pulls a cumulative
/// snapshot, never a lossy token stream; only one latest snapshot is retained.
actor WorkflowEventCollector {
    struct Snapshot: Sendable {
        let revision: Int
        let text: String
        let progress: String?
        let deltaCount: Int
        let byteCount: Int
    }
    private let maximumBytes: Int
    private var text = ""
    private var byteCount = 0
    private var deltaCount = 0
    private var revision = 0
    private var progress: String?

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func consume(_ run: InferenceRun) async -> (any Error)? {
        do {
            for try await event in run.events {
                switch event {
                case .textDelta(let delta):
                    let bytes = delta.utf8.count
                    guard bytes <= maximumBytes - byteCount else {
                        throw WorkflowIssue("文字输出超过应用接收预算。")
                    }
                    byteCount += bytes; deltaCount += 1
                    text += delta; revision += 1
                case .progress(let completed, let total):
                    progress = "\(completed)/\(total)"; revision += 1
                default: break
                }
            }
            return nil
        } catch {
            await run.cancel()
            return error
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(revision: revision, text: text, progress: progress,
                 deltaCount: deltaCount, byteCount: byteCount)
    }
}
