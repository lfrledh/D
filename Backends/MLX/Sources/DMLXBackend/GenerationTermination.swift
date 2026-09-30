import DInference
import MLXLMCommon

enum GenerationTermination {
    /// LM 3.31.4 counts the consumed iterator correctly. Its cancelled result is no
    /// longer normalized to length (the workaround was specific to LM 2.30.6).
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
            throw CancellationError()
        }
    }
}
