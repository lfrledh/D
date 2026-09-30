import Foundation

public struct TextRequest: Sendable, Codable, Equatable {
    public let prompt: String
    public let maxTokens: Int
    public let temperature: Float
    public let topP: Float
    public let execution: TextExecutionSelection?
    public let images: [TextImageReference]?
    public let video: TextVideoReference?
    public let visualProcessing: TextVisualProcessing?
    public let messages: [TextMessage]?
    public let tools: [TextToolDefinition]?
    public let thinking: TextThinkingOptions?
    public let seed: UInt64?

    public init(prompt: String, maxTokens: Int = 256, temperature: Float = 0.7, topP: Float = 0.95,
                execution: TextExecutionSelection? = nil,
                images: [TextImageReference]? = nil, video: TextVideoReference? = nil,
                visualProcessing: TextVisualProcessing? = nil,
                messages: [TextMessage]? = nil, tools: [TextToolDefinition]? = nil,
                thinking: TextThinkingOptions? = nil, seed: UInt64? = nil) {
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.execution = execution
        self.images = images
        self.video = video
        self.visualProcessing = visualProcessing
        self.messages = messages
        self.tools = tools
        self.thinking = thinking
        self.seed = seed
    }

    public var hasVisualInput: Bool {
        !allImages.isEmpty || !allVideos.isEmpty || visualProcessing != nil
    }

    public var resolvedMessages: [TextMessage] {
        if let messages { return messages }
        return [TextMessage(role: .user, parts: (images ?? []).map { .image($0) } +
                            (video.map { [.video($0)] } ?? []) + [.text(prompt)])]
    }

    public var allImages: [TextImageReference] {
        resolvedMessages.flatMap { message in message.parts.compactMap {
            if case .image(let image) = $0 { image } else { nil }
        } }
    }

    public var allVideos: [TextVideoReference] {
        resolvedMessages.flatMap { message in message.parts.compactMap {
            if case .video(let video) = $0 { video } else { nil }
        } }
    }

    /// Tool results must immediately follow their assistant calls in the same order.
    /// Qwen's chat template pairs results by position, even when IDs are present.
    public func validateConversation() throws {
        if let messages {
            guard prompt.isEmpty, images == nil, video == nil, !messages.isEmpty else {
                throw InferenceFailure.invalidRequest("Conversation messages cannot mix with legacy prompt or media.")
            }
        }
        var pending = [String]()
        var nextResult = 0
        var used = Set<String>()
        var jsonCount = 0
        let names = Set((tools ?? []).map(\.name))
        guard names.count == (tools ?? []).count else {
            throw InferenceFailure.invalidRequest("Tool names must be unique.")
        }
        for tool in tools ?? [] {
            guard Self.validIdentifier(tool.name), !tool.description.isEmpty,
                  tool.parameters["type"] == .string("object") else {
                throw InferenceFailure.invalidRequest("Invalid tool declaration.")
            }
            try TextJSONValue.object(tool.parameters).validate(count: &jsonCount)
            try Self.validateSchema(tool.parameters)
        }
        for message in resolvedMessages {
            guard !message.parts.isEmpty || message.role == .assistant && message.toolCalls != nil else {
                throw InferenceFailure.invalidRequest("Empty conversation message.")
            }
            for part in message.parts {
                switch part {
                case .text: break
                case .image(let image): try image.validate()
                case .video(let video): try video.validate()
                }
                if message.role != .user, case .image = part {
                    throw InferenceFailure.invalidRequest("Only user messages may carry media.")
                }
                if message.role != .user, case .video = part {
                    throw InferenceFailure.invalidRequest("Only user messages may carry media.")
                }
            }
            guard message.role == .assistant || message.reasoningContent == nil && message.toolCalls == nil,
                  message.role == .tool || message.toolCallID == nil else {
                throw InferenceFailure.invalidRequest("Conversation role metadata is invalid.")
            }
            if message.role == .tool {
                guard let id = message.toolCallID, nextResult < pending.count,
                      id == pending[nextResult],
                      message.parts.allSatisfy({ if case .text = $0 { true } else { false } }) else {
                    throw InferenceFailure.invalidRequest("Tool results must answer pending calls in order by ID.")
                }
                nextResult += 1
                if nextResult == pending.count {
                    pending.removeAll(keepingCapacity: true)
                    nextResult = 0
                }
            } else if !pending.isEmpty {
                throw InferenceFailure.invalidRequest("Tool results must follow pending assistant calls.")
            }
            for call in message.toolCalls ?? [] {
                guard Self.validIdentifier(call.id), Self.validIdentifier(call.name),
                      names.contains(call.name), call.validationError == nil,
                      used.insert(call.id).inserted else {
                    throw InferenceFailure.invalidRequest("Invalid or duplicate assistant tool call.")
                }
                try TextJSONValue.object(call.arguments).validate(count: &jsonCount)
                pending.append(call.id)
            }
        }
        guard pending.isEmpty else { throw InferenceFailure.invalidRequest("Missing tool result.") }
        let payload = ConversationPayload(prompt: prompt, messages: messages, tools: tools)
        guard ((try? JSONEncoder().encode(payload).count) ?? Int.max) <= 1_048_576 else {
            throw InferenceFailure.invalidRequest("Text, messages and tools exceed 1 MiB serialized.")
        }
    }

    private struct ConversationPayload: Encodable {
        let prompt: String
        let messages: [TextMessage]?
        let tools: [TextToolDefinition]?
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 95 || $0 == 45 }
    }

    private static func validateSchema(_ schema: [String: TextJSONValue]) throws {
        guard case .string(let kind)? = schema["type"],
              ["object", "array", "string", "integer", "number", "boolean", "null"].contains(kind) else {
            throw InferenceFailure.invalidRequest("Tool schema has an invalid type.")
        }
        if let values = schema["enum"] {
            guard case .array(let cases) = values, !cases.isEmpty else {
                throw InferenceFailure.invalidRequest("Tool schema enum must be a nonempty array.")
            }
        }
        if let values = schema["properties"] {
            guard kind == "object", case .object(let properties) = values else {
                throw InferenceFailure.invalidRequest("Tool schema properties must be an object.")
            }
            for value in properties.values {
                guard case .object(let nested) = value else {
                    throw InferenceFailure.invalidRequest("Tool property schema must be an object.")
                }
                try validateSchema(nested)
            }
        }
        if let values = schema["required"] {
            guard kind == "object", case .array(let required) = values,
                  case .object(let properties)? = schema["properties"] else {
                throw InferenceFailure.invalidRequest("Tool required fields need declared properties.")
            }
            var names = Set<String>()
            for value in required {
                guard case .string(let name) = value, properties[name] != nil,
                      names.insert(name).inserted else {
                    throw InferenceFailure.invalidRequest("Tool required field is unknown or duplicated.")
                }
            }
        }
        if let value = schema["additionalProperties"] {
            guard kind == "object", case .bool = value else {
                throw InferenceFailure.invalidRequest("Tool additionalProperties must be Boolean.")
            }
        }
        if let value = schema["items"] {
            guard kind == "array", case .object(let items) = value else {
                throw InferenceFailure.invalidRequest("Tool items must be an object schema.")
            }
            try validateSchema(items)
        }
    }
}
