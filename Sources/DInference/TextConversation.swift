import Foundation

public enum TextJSONValue: Sendable, Equatable, Codable {
    case null, bool(Bool), int(Int64), double(Double), string(String)
    indirect case array([TextJSONValue]), object([String: TextJSONValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Int64.self) { self = .int(item) }
        else if let item = try? value.decode(Double.self) {
            guard item.isFinite else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Nonfinite JSON number") }
            self = .double(item)
        } else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([TextJSONValue].self) { self = .array(item) }
        else { self = .object(try value.decode([String: TextJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .int(let item): try value.encode(item)
        case .double(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }

    public func validate(depth: Int = 0, count: inout Int) throws {
        count += 1
        guard count <= 65_536, depth <= 24 else { throw InferenceFailure.invalidRequest("JSON value budget exceeded.") }
        switch self {
        case .double(let number):
            guard number.isFinite else { throw InferenceFailure.invalidRequest("Nonfinite JSON number.") }
        case .array(let values):
            guard values.count <= 4_096 else { throw InferenceFailure.invalidRequest("JSON array budget exceeded.") }
            for value in values { try value.validate(depth: depth + 1, count: &count) }
        case .object(let values):
            guard values.count <= 256 else { throw InferenceFailure.invalidRequest("JSON object budget exceeded.") }
            for value in values.values { try value.validate(depth: depth + 1, count: &count) }
        default: break
        }
    }
}

public enum TextMessageRole: String, Sendable, Codable, Equatable { case system, user, assistant, tool }
public enum TextMessagePart: Sendable, Codable, Equatable {
    case text(String), image(TextImageReference), video(TextVideoReference)
}

public struct TextToolCall: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let arguments: [String: TextJSONValue]
    public let validationError: String?

    public init(id: String, name: String, arguments: [String: TextJSONValue], validationError: String? = nil) {
        self.id = id; self.name = name; self.arguments = arguments; self.validationError = validationError
    }
}

public struct TextMessage: Sendable, Codable, Equatable {
    public let role: TextMessageRole
    public let parts: [TextMessagePart]
    public let reasoningContent: String?
    public let toolCalls: [TextToolCall]?
    public let toolCallID: String?

    public init(role: TextMessageRole, parts: [TextMessagePart], reasoningContent: String? = nil,
                toolCalls: [TextToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role; self.parts = parts; self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls; self.toolCallID = toolCallID
    }
}

public struct TextToolDefinition: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let parameters: [String: TextJSONValue]

    public init(name: String, description: String, parameters: [String: TextJSONValue]) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public enum TextReasoningEffort: String, Sendable, Codable, Equatable { case low, medium, xhigh }
public struct TextThinkingOptions: Sendable, Codable, Equatable {
    public let enableThinking: Bool?
    public let reasoningEffort: TextReasoningEffort?
    public let preserveThinking: Bool?

    public init(enableThinking: Bool? = nil, reasoningEffort: TextReasoningEffort? = nil,
                preserveThinking: Bool? = nil) {
        self.enableThinking = enableThinking; self.reasoningEffort = reasoningEffort
        self.preserveThinking = preserveThinking
    }
}

public enum TextFinishReason: String, Sendable, Codable, Equatable { case stop, length, toolCalls, incomplete }
public struct TextResponse: Sendable, Codable, Equatable {
    public let rawText: String
    public let reasoningText: String?
    public let finalText: String?
    public let toolCalls: [TextToolCall]
    public let finishReason: TextFinishReason

    public init(rawText: String, reasoningText: String? = nil, finalText: String? = nil,
                toolCalls: [TextToolCall] = [], finishReason: TextFinishReason) {
        self.rawText = rawText; self.reasoningText = reasoningText; self.finalText = finalText
        self.toolCalls = toolCalls; self.finishReason = finishReason
    }
}
