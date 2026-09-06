import DInference
import MLXLMCommon

enum GenerationTermination {
    /// Compatibility for pinned LM 2.30.6: generateLoopTask iterates a value-type copy,
    /// then checks the untouched original iterator.tokenCount. A natural token limit can
    /// consequently be labelled cancelled. The emitted completion count is authoritative.
    /// Explicit parent/owned-task cancellation ALWAYS wins, even at exactly the limit.
    static func resolve(_ info: GenerateCompletionInfo, requestedTokens: Int,
                        taskWasCancelled: Bool) throws -> String {
        guard !taskWasCancelled else { throw CancellationError() }
        guard info.generationTokenCount >= 0, info.generationTokenCount <= requestedTokens else {
            throw InferenceFailure.backendFailed("Generation reported an invalid token count.")
        }
        switch info.stopReason {
        case .stop: return "stop"
        case .length:
            guard info.generationTokenCount == requestedTokens else {
                throw InferenceFailure.backendFailed("Generation ended before its declared token limit.")
            }
            return "length"
        case .cancelled:
            if info.generationTokenCount == requestedTokens { return "length" }
            throw CancellationError()
        }
    }
}
