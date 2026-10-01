import DInference
import Foundation

/// Separates Qwen's token channels while exposing only safe final-body prefixes.
/// Tool content stays buffered until QwenTextResponse validates each complete block.
struct QwenResponseStream {
    private let openID: Int
    private let closeID: Int
    private let tools: [TextToolDefinition]
    private var inReasoning: Bool
    private var endedReasoning: Bool
    private var malformedChannel = false
    private var thoughtTokens = [Int]()
    private var finalTokens = [Int]()
    private var decoder = IncrementalTextDecoder()
    private var pending = ""
    private var blocked = false
    private var toolBlock: String?
    private var delivered = ""

    init(openID: Int, closeID: Int, thinking: Bool, tools: [TextToolDefinition]? = nil) {
        self.openID = openID
        self.closeID = closeID
        self.tools = tools ?? []
        inReasoning = thinking
        endedReasoning = !thinking
    }

    mutating func accept(_ token: Int, decode: ([Int]) -> String) throws -> String? {
        // Once the channel order is invalid, no later token can make its body safe
        // to publish. The caller still retains every token for the raw response.
        guard !malformedChannel else { return nil }
        if token == openID {
            if !inReasoning && !finalTokens.isEmpty { malformedChannel = true }
            inReasoning = true
            endedReasoning = false
            return nil
        }
        if token == closeID {
            if !inReasoning { malformedChannel = true }
            inReasoning = false
            endedReasoning = true
            return nil
        }
        if inReasoning {
            thoughtTokens.append(token)
            return nil
        }
        finalTokens.append(token)
        guard let delta = try decoder.consume(decode(finalTokens)) else { return nil }
        return scan(delta)
    }

    mutating func finish(raw: String, stopped: String, tools: [TextToolDefinition]?, runID: UUID?,
                         decode: ([Int]) -> String) throws -> (response: TextResponse, delta: String?) {
        let final = inReasoning || malformedChannel || !endedReasoning ? nil : decode(finalTokens)
        let reasoning = thoughtTokens.isEmpty ? nil : decode(thoughtTokens)
        let response = QwenTextResponse.assemble(raw: raw, reasoning: reasoning, final: final,
                                                  stopped: stopped, tools: tools, runID: runID)
        guard let complete = response.finalText else { return (response, nil) }
        // The authoritative parser has now accepted the entire body. It can
        // release ordinary text held as a possible delimiter stem, including
        // text buffered by the incremental decoder, without exposing tool XML.
        let completeBytes = Array(complete.utf8)
        let deliveredBytes = Array(delivered.utf8)
        guard completeBytes.starts(with: deliveredBytes),
              let suffix = String(bytes: completeBytes.dropFirst(deliveredBytes.count), encoding: .utf8) else {
            throw InferenceFailure.backendFailed("Qwen final body disagrees with delivered text.")
        }
        delivered += suffix
        return (response, suffix.isEmpty ? nil : suffix)
    }

    private mutating func scan(_ delta: String) -> String? {
        guard !blocked else { return nil }
        pending += delta
        var safe = ""
        // A complete, validated tool block can be skipped and ordinary body text
        // after it can stream. An incomplete or invalid block stays private.
        let stems = ["<tool", "</tool", "<function", "</function", "<parameter", "</parameter",
                     "<think", "</think"]
        while !pending.isEmpty {
            if let block = toolBlock {
                let combined = block + pending
                guard let close = combined.range(of: "</tool_call>") else {
                    toolBlock = combined
                    pending = ""
                    break
                }
                let candidate = String(combined[..<close.upperBound])
                let parsed = QwenTextResponse.parseFinal(candidate, tools: tools)
                guard parsed.error == nil, parsed.calls.count == 1, parsed.text.isEmpty else {
                    blocked = true
                    pending = ""
                    break
                }
                toolBlock = nil
                pending = String(combined[close.upperBound...])
                continue
            }
            guard let angle = pending.firstIndex(of: "<") else {
                safe += pending
                pending = ""
                break
            }
            safe += pending[..<angle]
            pending = String(pending[angle...])
            if stems.contains(where: { pending.hasPrefix($0) }) {
                if pending.hasPrefix("<tool_call>") {
                    toolBlock = ""
                    continue
                }
                if "<tool_call>".hasPrefix(pending) { break }
                blocked = true
                pending = ""
                break
            }
            if stems.contains(where: { $0.hasPrefix(pending) }) { break }
            safe += "<"
            pending.removeFirst()
        }
        delivered += safe
        return safe.isEmpty ? nil : safe
    }
}
