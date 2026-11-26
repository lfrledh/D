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
        let partialResponse: TextResponse?
    }
    private let maximumBytes: Int
    private var text = ""
    private var byteCount = 0
    private var deltaCount = 0
    private var revision = 0
    private var progress: String?
    private var raw = ""
    private var reasoning = ""
    private var hasPartial = false
    private var retainedChannelBytes = 0

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func consume(_ run: InferenceRun) async -> (any Error)? {
        do {
            for try await event in run.events {
                switch event {
                case .textDelta(let delta):
                    let bytes = delta.utf8.count
                    guard bytes <= maximumBytes - retainedChannelBytes - byteCount else {
                        throw WorkflowIssue("文字输出超过应用接收预算。")
                    }
                    byteCount += bytes; deltaCount += 1
                    text += delta; revision += 1
                case .textPartial(let rawDelta, let thoughtDelta, let bodyDelta):
                    // Validate the whole event before changing any channel. Only
                    // deltas are queued; no cumulative copies accumulate in flight.
                    let bytes = rawDelta.utf8.count + thoughtDelta.utf8.count + bodyDelta.utf8.count
                    guard bytes <= maximumBytes - retainedChannelBytes - byteCount else {
                        throw WorkflowIssue("文字输出超过应用接收预算。")
                    }
                    raw += rawDelta; reasoning += thoughtDelta; text += bodyDelta
                    retainedChannelBytes += rawDelta.utf8.count + thoughtDelta.utf8.count
                    byteCount += bodyDelta.utf8.count
                    hasPartial = true
                    if !bodyDelta.isEmpty { deltaCount += 1; revision += 1 }
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
                 deltaCount: deltaCount, byteCount: byteCount,
                 partialResponse: hasPartial ? .init(rawText: raw,
                     reasoningText: reasoning.isEmpty ? nil : reasoning,
                     finalText: text.isEmpty ? nil : text, finishReason: .incomplete) : nil)
    }
}
