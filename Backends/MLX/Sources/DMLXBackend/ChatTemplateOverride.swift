import DInference
import Foundation
import Hub
import Jinja

/// The installed template is trusted model data. Edits use a deliberately finite Jinja subset.
enum ChatTemplateOverride {
    private static let maximumSource = 65_536
    private static let maximumExpansion = 8_388_608
    private static let maximumNodes = 1_024

    static func validate(_ source: String, source installed: String,
                         messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                         additionalContext: [String: any Sendable]?) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= maximumSource else {
            throw InferenceFailure.invalidRequest("Chat template override must contain text and be at most 64 KiB UTF-8.")
        }
        // Reusing the installed source preserves its full, model-authored Jinja behavior.
        if source == installed { return }
        for value in messages + (tools ?? []) {
            guard (try JSONSerialization.data(withJSONObject: value)).count <= 8_192 else {
                throw unsupported("each message and tool must be at most 8 KiB for an editable template")
            }
        }
        let tokens: [Token]
        do { tokens = try Lexer.tokenize(source) }
        catch { throw unsupported("Jinja lexer error: \(error.localizedDescription)") }
        try preflightTokens(tokens)
        let nodes: [Node]
        do { nodes = try Parser.parse(tokens) }
        catch { throw unsupported("Jinja parser error: \(error.localizedDescription)") }
        var count = 0
        let cost = try inspect(nodes, loopDepth: 0, multiplier: 1,
                               messageCount: messages.count,
                               partCount: messages.compactMap { $0["content"] as? [[String: any Sendable]] }
                                   .map(\.count).max() ?? 0,
                               toolCount: tools?.count ?? 0, count: &count)
        guard cost <= maximumExpansion else {
            throw InferenceFailure.invalidRequest("Chat template expansion exceeds the 8 MiB preflight budget.")
        }
    }

    private static func preflightTokens(_ tokens: [Token]) throws {
        guard tokens.count <= 4_096 else { throw unsupported("too many lexical tokens") }
        var blocks = 0
        var groups = 0
        var unaryRun = 0
        var elifCount = 0
        for token in tokens {
            if [.not, .plus, .minus].contains(token.kind) { unaryRun += 1 }
            else { unaryRun = 0 }
            if token.kind == .elif { elifCount += 1 }
            switch token.kind {
            case .if, .for, .macro, .call, .filter, .generation, .set:
                blocks += 1
            case .endif, .endfor, .endmacro, .endcall, .endfilter, .endgeneration, .endset:
                blocks -= 1
            case .openParen, .openBracket, .openBrace: groups += 1
            case .closeParen, .closeBracket, .closeBrace: groups -= 1
            default: break
            }
            guard (0...12).contains(blocks), (0...12).contains(groups),
                  unaryRun <= 12, elifCount <= 12 else {
                throw unsupported("syntax nesting exceeds 12")
            }
        }
    }

    private static func inspect(_ nodes: [Node], loopDepth: Int, multiplier: Int,
                                messageCount: Int, partCount: Int, toolCount: Int,
                                count: inout Int) throws -> Int {
        var cost = 0
        for node in nodes {
            count += 1
            guard count <= maximumNodes else { throw unsupported("too many syntax nodes") }
            switch node {
            case .text(let text): cost = try add(cost, text.utf8.count * multiplier)
            case .comment: break
            case .expression(let expression):
                try inspect(expression)
                guard !referencesRootCollection(expression) else {
                    throw unsupported("whole messages or tools collections cannot be emitted")
                }
                // JSON escaping can expand a bounded input byte up to six bytes.
                cost = try add(cost, 49_152 * multiplier)
            case .statement(.if(let condition, let yes, let no)):
                try inspect(condition)
                let yesCost = try inspect(yes, loopDepth: loopDepth, multiplier: multiplier,
                                          messageCount: messageCount, partCount: partCount,
                                          toolCount: toolCount, count: &count)
                let noCost = try inspect(no, loopDepth: loopDepth, multiplier: multiplier,
                                         messageCount: messageCount, partCount: partCount,
                                         toolCount: toolCount, count: &count)
                cost = try add(cost, max(yesCost, noCost))
            case .statement(.for(let variable, let iterable, let body, let otherwise, let test)):
                guard loopDepth < 2, test == nil, otherwise.isEmpty,
                      case .single(let name) = variable,
                      isMessagesLoop(iterable, name: name, depth: loopDepth) ||
                      isPartsLoop(iterable, name: name, depth: loopDepth) ||
                      isToolsLoop(iterable, name: name, depth: loopDepth) else {
                    throw unsupported("loops may only traverse messages, message.content, or tools")
                }
                let iterations: Int
                if case .identifier("messages") = iterable { iterations = messageCount }
                else if isPartsLoop(iterable, name: name, depth: loopDepth) { iterations = partCount }
                else { iterations = toolCount }
                guard iterations <= 256, multiplier <= maximumExpansion / max(1, iterations) else {
                    throw unsupported("loop count exceeds the execution budget")
                }
                cost = try add(cost, inspect(body, loopDepth: loopDepth + 1,
                    multiplier: multiplier * iterations, messageCount: messageCount,
                    partCount: partCount, toolCount: toolCount, count: &count))
            default: throw unsupported("assignments, macros, calls, and dynamic loops are unavailable")
            }
        }
        return cost
    }

    private static func isMessagesLoop(_ expression: Jinja.Expression, name: String, depth: Int) -> Bool {
        guard depth == 0, name == "message", case .identifier("messages") = expression else { return false }
        return true
    }

    private static func isPartsLoop(_ expression: Jinja.Expression, name: String, depth: Int) -> Bool {
        guard depth == 1, name == "part",
              case .member(.identifier("message"), .identifier("content"), computed: false) = expression else { return false }
        return true
    }

    private static func isToolsLoop(_ expression: Jinja.Expression, name: String, depth: Int) -> Bool {
        guard depth == 0, name == "tool", case .identifier("tools") = expression else { return false }
        return true
    }

    private static func inspect(_ expression: Jinja.Expression, depth: Int = 0) throws {
        guard depth < 12 else { throw unsupported("expression nesting exceeds 12") }
        switch expression {
        case .string(let value): guard value.utf8.count <= 4_096 else { throw unsupported("literal is too large") }
        case .boolean, .null, .integer: break
        case .identifier(let name):
            guard ["messages", "message", "part", "tools", "tool", "loop",
                   "add_generation_prompt", "enable_thinking", "reasoning_effort",
                   "preserve_thinking", "add_vision_id", "eos_token", "bos_token",
                   "pad_token"].contains(name) else { throw unsupported("unknown variable \(name)") }
        case .member(let base, let member, let computed):
            guard !computed, case .identifier(let key) = member,
                  ["role", "content", "type", "text", "name", "description", "function",
                   "parameters", "tool_calls", "tool_call_id", "reasoning_content",
                   "first", "last", "index0"].contains(key) else {
                throw unsupported("dynamic member access is unavailable")
            }
            try inspect(base, depth: depth + 1)
        case .unary(.not, let value): try inspect(value, depth: depth + 1)
        case .binary(let op, let lhs, let rhs):
            guard [.equal, .notEqual, .and, .or, .in].contains(op) else {
                throw unsupported("arithmetic and expansion operators are unavailable")
            }
            try inspect(lhs, depth: depth + 1)
            try inspect(rhs, depth: depth + 1)
        case .filter(let value, let name, let args, let keywords):
            guard ["tojson", "trim"].contains(name), args.isEmpty, keywords.isEmpty else {
                throw unsupported("filter is unavailable")
            }
            try inspect(value, depth: depth + 1)
        default: throw unsupported("function calls, slices, and computed expressions are unavailable")
        }
    }

    private static func referencesRootCollection(_ expression: Jinja.Expression) -> Bool {
        switch expression {
        case .identifier("messages"), .identifier("tools"): true
        case .filter(let value, _, _, _): referencesRootCollection(value)
        // and/or return an operand in Jinja, so either branch may emit the whole array.
        case .binary(_, let lhs, let rhs):
            referencesRootCollection(lhs) || referencesRootCollection(rhs)
        case .member(let base, _, _), .unary(_, let base):
            referencesRootCollection(base)
        default: false
        }
    }

    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        guard rhs <= maximumExpansion, lhs <= maximumExpansion - rhs else {
            throw unsupported("template expansion exceeds 8 MiB")
        }
        return lhs + rhs
    }

    private static func unsupported(_ detail: String) -> InferenceFailure {
        .invalidRequest("Unsupported editable chat template: \(detail). Restore the installed template to use full model syntax.")
    }

    static func render(_ source: String, config: Config,
                       messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                       additionalContext: [String: any Sendable]?) throws -> String {
        var context: [String: Value] = [
            "messages": try .array(messages.map { try Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools { context["tools"] = try .array(tools.map { try Value(any: $0) }) }
        if let additionalContext {
            for (key, value) in additionalContext { context[key] = try Value(any: value) }
        }
        for (key, value) in config.dictionary(or: [:]) {
            guard ["bos_token", "eos_token", "unk_token", "sep_token", "pad_token",
                   "cls_token", "mask_token", "additional_special_tokens"].contains(key.string),
                  !value.isNull() else { continue }
            if let string = value.string() { context[key.string] = .string(string) }
            else if let dictionary = value.dictionary(), let content = dictionary["content"]?.string() {
                context[key.string] = .string(content)
            } else if let strings: [String] = value.get() {
                context[key.string] = .array(strings.map { .string($0) })
            } else { context[key.string] = try Value(any: value) }
        }
        let rendered = try Template(source).render(context)
        guard rendered.utf8.count <= maximumExpansion else {
            throw InferenceFailure.invalidRequest("Rendered chat template exceeds 8 MiB.")
        }
        return rendered
    }

    static func validateOutput(_ rendered: String, messages: [[String: any Sendable]],
                               tools: [[String: any Sendable]]?, thinkingEnabled: Bool? = nil) throws {
        let open = "<|im_start|>assistant\n<think>\n"
        let closed = "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let validPrefix: Bool
        switch thinkingEnabled {
        case .some(false): validPrefix = rendered.hasSuffix(closed)
        case .some(true): validPrefix = rendered.hasSuffix(open)
        case nil: validPrefix = rendered.hasSuffix(open) || rendered.hasSuffix(closed)
        }
        guard validPrefix else {
            throw unsupported("generation prefix or thinking channel is missing")
        }
        let imageCount = messages.reduce(0) { total, message in
            total + (message["content"] as? [[String: any Sendable]] ?? [])
                .filter { $0["type"] as? String == "image" }.count
        }
        let videoCount = messages.reduce(0) { total, message in
            total + (message["content"] as? [[String: any Sendable]] ?? [])
                .filter { $0["type"] as? String == "video" }.count
        }
        guard occurrences("<|vision_start|><|image_pad|><|vision_end|>", in: rendered) == imageCount,
              occurrences("<|vision_start|><|video_pad|><|vision_end|>", in: rendered) == videoCount else {
            throw unsupported("media placeholders do not match the request")
        }
        var remaining = rendered[...]
        var outsideMessages = ""
        // A template may put tool declarations in system-body gaps, never in input text.
        var systemDeclarationAreas = [Substring]()
        for message in messages {
            guard let role = message["role"] as? String else { throw unsupported("message role is missing") }
            let boundary = role == "tool" ? "<tool_response>\n" : "<|im_start|>\(role)\n"
            guard let range = remaining.range(of: boundary) else {
                throw unsupported("rendered \(role) role boundary is missing or out of order")
            }
            outsideMessages.append(contentsOf: remaining[..<range.lowerBound])
            guard let end = remaining[range.upperBound...].range(of: "<|im_end|>") else {
                throw unsupported("rendered \(role) message end is missing")
            }
            let fullBody = remaining[range.upperBound..<end.lowerBound]
            let unused = try validateBody(fullBody, message: message)
            if role == "system" { systemDeclarationAreas.append(contentsOf: unused) }
            remaining = remaining[end.upperBound...]
        }
        outsideMessages.append(contentsOf: remaining)
        for tool in tools ?? [] {
            var found = try containsExactJSON(tool, in: outsideMessages[...])
            if !found {
                for declarationArea in systemDeclarationAreas where !found {
                    found = try containsExactJSON(tool, in: declarationArea)
                }
            }
            guard found else {
                throw unsupported("complete tool declaration must appear as JSON outside messages or in a system message")
            }
        }
    }

    /// Choose complete, non-overlapping message fields together. Looking for final text
    /// first is incorrect when reasoning quotes it (and reversing alone has the same flaw).
    private static func validateBody(_ body: Substring,
                                     message: [String: any Sendable]) throws -> [Substring] {
        guard message["content"] == nil || message["content"] is [[String: any Sendable]],
              message["reasoning_content"] == nil || message["reasoning_content"] is String,
              message["tool_calls"] == nil || message["tool_calls"] is [[String: any Sendable]] else {
            throw unsupported("message fields have an invalid shape")
        }
        let parts = try (message["content"] as? [[String: any Sendable]] ?? []).map { part -> String in
            switch part["type"] as? String {
            case "text":
                guard let text = part["text"] as? String else { throw unsupported("invalid message text") }
                return text
            case "image": return "<|vision_start|><|image_pad|><|vision_end|>"
            case "video": return "<|vision_start|><|video_pad|><|vision_end|>"
            default: throw unsupported("unknown message part")
            }
        }.filter { !$0.isEmpty }
        let reasoning = message["reasoning_content"] as? String ?? ""
        var choices: [Range<String.Index>?] = [nil]
        if !reasoning.isEmpty {
            choices = []
            var cursor = body.startIndex
            while cursor < body.endIndex,
                  let found = body[cursor...].range(of: reasoning) {
                guard choices.count < 128 else { throw unsupported("ambiguous repeated reasoning exceeds validation budget") }
                choices.append(found)
                cursor = body.index(after: found.lowerBound)
            }
        }
        let calls = message["tool_calls"] as? [[String: any Sendable]] ?? []
        let callChoices: [Range<String.Index>?] = calls.isEmpty ? [nil]
            : try exactJSONRanges(calls, in: body).map(Optional.some)
        guard choices.count * callChoices.count <= 1_024 else {
            throw unsupported("ambiguous message fields exceed validation budget")
        }
        for reasoningRange in choices {
            for callRange in callChoices {
                if let reasoningRange, let callRange, reasoningRange.overlaps(callRange) { continue }
                let reserved = [reasoningRange, callRange].compactMap { $0 }
                var ranges = reserved
                var cursor = body.startIndex
                var complete = true
                for part in parts {
                    var match: Range<String.Index>?
                    while cursor < body.endIndex,
                          let found = body[cursor...].range(of: part) {
                        if let overlap = reserved.first(where: { found.overlaps($0) }) {
                            cursor = overlap.upperBound
                            continue
                        }
                        match = found
                        break
                    }
                    guard let match else { complete = false; break }
                    ranges.append(match); cursor = match.upperBound
                }
                if complete { return unclaimedAreas(body, excluding: ranges) }
            }
        }
        throw unsupported("message content, reasoning, or independent complete tool calls were omitted or reordered")
    }

    private static func unclaimedAreas(_ text: Substring,
                                       excluding ranges: [Range<String.Index>]) -> [Substring] {
        var cursor = text.startIndex
        var areas: [Substring] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if cursor < range.lowerBound { areas.append(text[cursor..<range.lowerBound]) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < text.endIndex { areas.append(text[cursor...]) }
        return areas
    }

    private static func containsExactJSON(_ expected: Any, in text: Substring) throws -> Bool {
        try !exactJSONRanges(expected, in: text).isEmpty
    }

    private static func exactJSONRanges(_ expected: Any, in text: Substring) throws -> [Range<String.Index>] {
        let reference = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        var matches: [Range<String.Index>] = []
        var candidates = 0, inspected = 0
        // The surrounding message is arbitrary natural language. Start each potential
        // JSON object independently so an unmatched bracket/quote in prose cannot mask it.
        for start in text.indices where text[start] == "{" || text[start] == "[" {
            candidates += 1
            guard candidates <= 4_096 else { throw unsupported("too many JSON candidates") }
            var stack: [Character] = [], quoted = false, escaped = false
            var end: String.Index?
            for index in text[start...].indices {
                inspected += 1
                guard inspected <= 16_777_216 else { throw unsupported("JSON scan exceeds validation budget") }
                let character = text[index]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                    continue
                }
                if character == "\"" { quoted = true }
                else if character == "{" || character == "[" {
                    guard stack.count < 32 else { throw unsupported("JSON nesting exceeds validation budget") }
                    stack.append(character)
                } else if character == "}" || character == "]" {
                    guard let opening = stack.popLast(), opening == (character == "}" ? "{" : "[") else { break }
                    if stack.isEmpty { end = text.index(after: index); break }
                }
            }
            guard let end else { continue }
            let data = Data(text[start..<end].utf8)
            if let value = try? JSONSerialization.jsonObject(with: data),
               let normalized = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               normalized == reference { matches.append(start..<end) }
        }
        return matches
    }

    private static func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    static func validateProbe(_ source: String, config: Config) throws {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let toolName = "probe_" + nonce
        let probeCalls: [[String: any Sendable]] = [["type": "function", "function": [
            "name": toolName, "arguments": ["value_" + nonce: "argument_" + nonce]
        ] as [String: any Sendable]]]
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": [["type": "text", "text": "system_" + nonce]]],
            ["role": "user", "content": [["type": "text", "text": "user_" + nonce],
                                         ["type": "image"], ["type": "video"]]],
            ["role": "assistant", "content": [["type": "text", "text": "assistant_" + nonce]],
             "reasoning_content": "reasoning_" + nonce,
             "tool_calls": probeCalls],
            ["role": "tool", "content": [["type": "text", "text": "result_" + nonce]],
             "tool_call_id": "call_" + nonce],
        ]
        let tools: [[String: any Sendable]] = [["type": "function", "function": [
            "name": toolName, "description": "description_" + nonce,
            "parameters": ["type": "object", "value_" + nonce: "string"]
        ] as [String: any Sendable]]]
        try validate(source, source: "", messages: messages, tools: tools,
                     additionalContext: nil)
        for enabled in [true, false] {
            let rendered = try render(source, config: config, messages: messages, tools: tools,
                                      additionalContext: ["enable_thinking": enabled])
            try validateOutput(rendered, messages: messages, tools: tools, thinkingEnabled: enabled)
            guard rendered.contains("argument_" + nonce) else {
                throw unsupported("tool call argument value was omitted")
            }
        }
    }
}

/// The application retains the installed model lease while this CPU-only operation runs.
public enum ChatTemplatePreviewProvider {
    public static func preview(model: ModelReference, request: TextRequest) async throws -> TextTemplatePreview {
        // The public preview has no backend instance. Use the selected prompt ceiling,
        // or the VLM default, while retaining the model's own context admission.
        let capability = TextExecutionCapability(
            maximumPromptTokens: request.execution?.maximumPromptTokens ?? 32_768,
            maximumOutputTokens: max(8_192, request.maxTokens), profile: TextExecutionCapability.qwen35VLMProfile)
        let inventory = try QwenVLMModelInventory.inspect(
            InferenceRequest(model: model, input: .text(request)), capability: capability)
        let tokenizer = try await LocalTokenizerLoader(fileSet: inventory.fileSet,
            chatTemplateOverride: request.chatTemplateOverride,
            hasTools: !(request.tools ?? []).isEmpty).loadLocal(from: inventory.directory)
        let context = try QwenMessageMapping.context(for: request.thinking, modelSize: inventory.size)
        let (source, rendered, ids) = try tokenizer.preview(
            messages: QwenMessageMapping.messages(request), tools: QwenMessageMapping.tools(request.tools),
            additionalContext: context)
        return TextTemplatePreview(sourceTemplate: source, renderedTemplate: rendered,
            templateTokenIDs: ids, diagnostics: [
                "CPU template expansion only; image and video markers are placeholders, not final media-expanded tokens."
            ])
    }
}
