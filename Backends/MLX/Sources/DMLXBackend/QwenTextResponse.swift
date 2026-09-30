import DInference
import Foundation

/// Strictly consumes the Qwen3.5 XML function grammar after channel separation.
/// This never calls the upstream XML parser, whose number conversion can trap.
enum QwenTextResponse {
    static func assemble(raw: String, reasoning: String?, final: String?, stopped: String,
                         tools: [TextToolDefinition]?, runID: UUID? = nil) -> TextResponse {
        guard let final else {
            return TextResponse(rawText: raw, reasoningText: reasoning, finishReason: .incomplete)
        }
        guard !final.contains("<think>"), !final.contains("</think>") else {
            return TextResponse(rawText: raw, reasoningText: reasoning, finishReason: .incomplete)
        }
        let parsed = parseFinal(final, tools: tools ?? [])
        let reason: TextFinishReason = parsed.error != nil ? .incomplete :
            stopped == "length" ? .length : parsed.calls.isEmpty ? .stop : .toolCalls
        return TextResponse(rawText: raw, reasoningText: reasoning,
                            finalText: parsed.error == nil ? parsed.text : nil,
                            toolCalls: parsed.calls.enumerated().map { index, call in
                                guard let runID else { return call }
                                return TextToolCall(id: "call_" + runID.uuidString.replacingOccurrences(of: "-", with: "_") + "_\(index)",
                                    name: call.name, arguments: call.arguments, validationError: call.validationError)
                            }, finishReason: reason)
    }

    static func parseFinal(_ input: String, tools: [TextToolDefinition])
        -> (text: String, calls: [TextToolCall], error: String?) {
        // Bound tool parsing, not completed reasoning or ordinary final text.
        // The raw response is always retained when a tool payload exceeds this budget.
        if input.contains("<tool_call>"), input.utf8.count > 1_048_576 {
            return ("", [], "Tool payload exceeds 1 MiB parsing budget")
        }
        var remaining = input[...]
        var text = ""
        var calls = [TextToolCall]()
        while let open = remaining.range(of: "<tool_call>") {
            text += String(remaining[..<open.lowerBound])
            remaining = remaining[open.upperBound...]
            guard let close = remaining.range(of: "</tool_call>") else {
                return (text, calls, "Unclosed tool call")
            }
            let body = String(remaining[..<close.lowerBound])
            remaining = remaining[close.upperBound...]
            guard let parsed = parseBlock(body, tools: tools, index: calls.count) else {
                return (text, calls, "Malformed or undeclared tool call")
            }
            calls.append(parsed)
            if let error = parsed.validationError { return (text, calls, error) }
        }
        // A prefix of a tool tag or a stray delimiter is incomplete, never final text.
        let tail = String(remaining)
        guard !tail.contains("<tool"), !tail.contains("</tool"),
              !tail.contains("<function"), !tail.contains("</function"),
              !tail.contains("<parameter"), !tail.contains("</parameter") else {
            return (text, calls, "Incomplete tool delimiter")
        }
        text += tail
        return (text, calls, nil)
    }

    private static func parseBlock(_ body: String, tools: [TextToolDefinition], index: Int) -> TextToolCall? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<function="), let nameEnd = trimmed.firstIndex(of: ">") else { return nil }
        let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 10)..<nameEnd])
        guard let tool = tools.first(where: { $0.name == name }),
              trimmed.hasSuffix("</function>") else { return nil }
        let ending = trimmed.range(of: "</function>", options: .backwards)!
        var body = trimmed[nameEnd...]
        body = body[body.index(after: body.startIndex)..<ending.lowerBound]
        var args = [String: TextJSONValue]()
        var remaining = body[...]
        while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remaining = remaining.drop { $0.isWhitespace }
            guard remaining.hasPrefix("<parameter="), let closeName = remaining.firstIndex(of: ">") else { return nil }
            let key = String(remaining[remaining.index(remaining.startIndex, offsetBy: 11)..<closeName])
            guard !key.isEmpty, args[key] == nil else { return nil }
            remaining = remaining[remaining.index(after: closeName)...]
            guard let closeValue = remaining.range(of: "</parameter>") else { return nil }
            var lexical = String(remaining[..<closeValue.lowerBound])
            if lexical.hasPrefix("\n") { lexical.removeFirst() }
            if lexical.hasSuffix("\n") { lexical.removeLast() }
            remaining = remaining[closeValue.upperBound...]
            guard let schema = propertySchema(tool.parameters, key: key),
                  let value = parseValue(lexical, schema: schema) else {
                return TextToolCall(id: "call_\(index)", name: name, arguments: args,
                                    validationError: "Invalid or undeclared parameter \(key)")
            }
            args[key] = value
        }
        let error = validateArguments(args, schema: tool.parameters)
        return TextToolCall(id: "call_\(index)", name: name, arguments: args, validationError: error)
    }

    private static func propertySchema(_ schema: [String: TextJSONValue], key: String) -> [String: TextJSONValue]? {
        guard case .object(let properties)? = schema["properties"],
              case .object(let value)? = properties[key] else { return nil }
        return value
    }

    private static func parseValue(_ lexical: String, schema: [String: TextJSONValue]) -> TextJSONValue? {
        guard case .string(let type)? = schema["type"] else { return nil }
        switch type {
        case "string": return .string(lexical)
        case "boolean":
            if lexical == "true" { return .bool(true) }
            if lexical == "false" { return .bool(false) }
            return nil
        case "integer": return Int64(lexical).map(TextJSONValue.int)
        case "number":
            guard let number = Double(lexical), number.isFinite else { return nil }
            return .double(number)
        case "object", "array":
            guard let data = lexical.data(using: .utf8), data.count <= 1_048_576,
                  uniqueJSONKeys(data),
                  let value = try? JSONDecoder().decode(TextJSONValue.self, from: data) else { return nil }
            var count = 0
            guard matches(value, kind: type), (try? value.validate(count: &count)) != nil else { return nil }
            return value
        case "null": return lexical == "null" ? .null : nil
        default: return nil
        }
    }

    private static func validateArguments(_ args: [String: TextJSONValue],
                                          schema: [String: TextJSONValue]) -> String? {
        guard schema["type"] == .string("object") else { return "Unsupported parameter schema" }
        if let required = schema["required"] {
            guard case .array = required else { return "Invalid required schema" }
        }
        if let properties = schema["properties"] {
            guard case .object = properties else { return "Invalid properties schema" }
        }
        if case .array(let required)? = schema["required"] {
            for item in required {
                guard case .string(let key) = item, args[key] != nil else { return "Missing required parameter" }
            }
        }
        let recognized = Set(["type", "properties", "required", "additionalProperties", "description", "title"])
        if schema.keys.contains(where: { !recognized.contains($0) }) { return "Unvalidated schema constraint" }
        if schema["additionalProperties"] == .bool(false),
           case .object(let properties)? = schema["properties"],
           args.keys.contains(where: { properties[$0] == nil }) { return "Unexpected parameter" }
        for (key, value) in args {
            guard let property = propertySchema(schema, key: key) else { return "Undeclared parameter" }
            if let allowed = property["enum"] {
                guard case .array(let cases) = allowed, cases.contains(value) else { return "Enum mismatch" }
            }
            let recognizedProperty = Set(["type", "description", "title", "enum", "properties", "required", "additionalProperties", "items"])
            if property.keys.contains(where: { !recognizedProperty.contains($0) }) {
                return "Unvalidated schema constraint"
            }
            if case .object(let object) = value, let nested = validateArguments(object, schema: property) { return nested }
            if case .array(let array) = value {
                guard case .object(let itemSchema)? = property["items"] else { return "Unvalidated array items" }
                for item in array {
                    if case .object(let object) = item, let nested = validateArguments(object, schema: itemSchema) { return nested }
                    if case .string(let kind)? = itemSchema["type"], !matches(item, kind: kind) { return "Array item type mismatch" }
                }
            }
        }
        return nil
    }

    private static func matches(_ value: TextJSONValue, kind: String) -> Bool {
        switch (kind, value) {
        case ("string", .string), ("boolean", .bool), ("integer", .int),
             ("number", .double), ("number", .int), ("object", .object),
             ("array", .array), ("null", .null): true
        default: false
        }
    }

    /// A lexical prepass because JSONDecoder silently keeps one duplicate object key.
    /// JSONDecoder performs the full syntax check after this bounded scan.
    private static func uniqueJSONKeys(_ data: Data) -> Bool {
        let bytes = Array(data)
        var index = 0
        func whitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        func string() -> String? {
            guard index < bytes.count, bytes[index] == 34 else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    index += 1
                    return try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
                index += 1
            }
            return nil
        }
        func value(_ depth: Int) -> Bool {
            guard depth <= 24 else { return false }
            whitespace()
            guard index < bytes.count else { return false }
            if bytes[index] == 34 { return string() != nil }
            if bytes[index] == 123 {
                index += 1; whitespace()
                var keys = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return true }
                while index < bytes.count {
                    whitespace()
                    guard let key = string(), keys.insert(key).inserted else { return false }
                    whitespace()
                    guard index < bytes.count, bytes[index] == 58 else { return false }
                    index += 1
                    guard value(depth + 1) else { return false }
                    whitespace()
                    guard index < bytes.count else { return false }
                    if bytes[index] == 125 { index += 1; return true }
                    guard bytes[index] == 44 else { return false }
                    index += 1
                }
                return false
            }
            if bytes[index] == 91 {
                index += 1; whitespace()
                if index < bytes.count, bytes[index] == 93 { index += 1; return true }
                while index < bytes.count {
                    guard value(depth + 1) else { return false }
                    whitespace()
                    guard index < bytes.count else { return false }
                    if bytes[index] == 93 { index += 1; return true }
                    guard bytes[index] == 44 else { return false }
                    index += 1
                }
                return false
            }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
                index += 1
            }
            return index > start
        }
        guard value(0) else { return false }
        whitespace()
        return index == bytes.count
    }
}
