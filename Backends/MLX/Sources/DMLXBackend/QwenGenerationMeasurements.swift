import DInference
import Foundation
import MLXLMCommon

/// Per-request execution facts, using completed-token timestamps from the producer.
/// No prompt/output content or per-token trace is persisted here.
enum QwenGenerationMeasurements {
    static func metadata(completion: GenerateCompletionInfo, input: TextRequest,
                         backendStarted: TimeInterval, loadSeconds: TimeInterval,
                         prepareSeconds: TimeInterval, firstBodyIndex: Int?,
                         firstBodyConsumedUptime: TimeInterval?, consumedUptime: TimeInterval,
                         parsingSeconds: TimeInterval, deliverySeconds: TimeInterval,
                         reasoningTokens: Int, bodyChannelTokens: Int,
                         peakBytes: Int, activeBytes: Int, cacheBytes: Int) -> [String: String] {
        var result: [String: String] = [
            "samplingTopK": String(input.topK ?? 0), "samplingMinP": String(input.minP ?? 0),
            "samplingPresencePenalty": String(input.presencePenalty ?? 0),
            "samplingPresenceScope": "generated-request-only",
            "samplingFilterOrder": (input.topK ?? 0) > 0
                ? "temperature,minP,topK,normalized-topP" : "legacy-mlx-topP,minP,topK,temperature",
            "samplingRepetitionPenalty": String(input.repetitionPenalty ?? 1),
            "backendStartedUptime": String(backendStarted),
            "modelLoadSeconds": String(loadSeconds), "inputPreparationSeconds": String(prepareSeconds),
            "prefillAndFirstTokenSeconds": String(completion.promptTime),
            "prefillAndFirstTokenInputTokensPerSecond": String(completion.promptTokensPerSecond),
            "consumerParsingSeconds": String(parsingSeconds), "consumerDeliverySeconds": String(deliverySeconds),
            "reasoningTokenCount": String(reasoningTokens), "bodyChannelTokenCount": String(bodyChannelTokens),
            "channelControlTokenCount": String(completion.generationTokenCount - reasoningTokens - bodyChannelTokens),
            "mlxPeakBytes": String(peakBytes), "mlxActiveBytesAtCompletion": String(activeBytes),
            "mlxCacheBytesAtCompletion": String(cacheBytes),
            "timingBoundary": "backend-entry; monotonic completed-token production before yield; EOS excluded"
        ]
        guard let timing = completion.tokenTiming else { return result }
        result["terminationTokenID"] = timing.terminationToken.map { String($0) } ?? "none"
        result["terminationTokenKind"] = timing.terminationKind ?? "none"
        result["producerTimingTruncated"] = String(timing.truncated)
        result["producerToConsumerCompletionSeconds"] = String(max(0, consumedUptime - timing.finishedUptime))
        let times = timing.tokenUptimes
        if let first = times.first, let last = times.last {
            result["backendToFirstTokenSeconds"] = String(first - backendStarted)
            result["decodeIntervalSeconds"] = String(last - first)
            result["decodeIntervals"] = String(max(0, times.count - 1))
            result["decodeTokensPerSecond"] = timing.tokensPerSecond(in: 0..<times.count).map { String($0) }
        }
        // This is the production time of the token that made a safe body delta
        // deliverable (or the last token for final-only text), not channel onset.
        if let firstBodyIndex, times.indices.contains(firstBodyIndex) {
            result["backendToFirstSafeBodyDeltaProducerSeconds"] = String(times[firstBodyIndex] - backendStarted)
            result["firstSafeBodyDeltaTokenIndex"] = String(firstBodyIndex)
        }
        if let firstBodyConsumedUptime {
            result["backendToFirstBodyConsumedSeconds"] = String(firstBodyConsumedUptime - backendStarted)
        }
        var windows = [[String: Double]]()
        for lower in stride(from: 0, to: times.count, by: 512) {
            let upper = min(lower + 512, times.count)
            guard let speed = timing.tokensPerSecond(in: lower..<upper) else { continue }
            windows.append(["firstGeneratedIndex": Double(lower), "tokenCount": Double(upper - lower),
                            "intervalCount": Double(upper - lower - 1), "tokensPerSecond": speed,
                            "contextTokensAtEnd": Double(completion.promptTokenCount + upper)])
        }
        if let data = try? JSONSerialization.data(withJSONObject: windows, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { result["decodeWindows512"] = json }
        return result
    }
}
