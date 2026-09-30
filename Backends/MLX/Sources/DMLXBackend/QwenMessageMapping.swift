import DInference
import Foundation
import MLXLMCommon

enum QwenMessageMapping {
    static func context(for thinking: TextThinkingOptions?, modelSize: String) throws -> [String: any Sendable] {
        if modelSize == "9B" {
            guard thinking?.reasoningEffort == nil, thinking?.preserveThinking == nil else {
                throw InferenceFailure.invalidRequest("9B supports enableThinking only.")
            }
        } else if modelSize == "27B" {
            guard thinking?.enableThinking != false || thinking?.reasoningEffort == nil else {
                throw InferenceFailure.invalidRequest("Reasoning effort requires thinking enabled.")
            }
        } else { throw InferenceFailure.invalidRequest("Unsupported Qwen model size.") }
        var result: [String: any Sendable] = [:]
        if let enabled = thinking?.enableThinking { result["enable_thinking"] = enabled }
        if let effort = thinking?.reasoningEffort { result["reasoning_effort"] = effort.rawValue }
        if let preserve = thinking?.preserveThinking { result["preserve_thinking"] = preserve }
        return result
    }

    static func messages(_ input: TextRequest) -> [MLXLMCommon.Message] {
        input.resolvedMessages.map { message in
            let content: [[String: any Sendable]] = message.parts.map { part in
                switch part {
                case .text(let text): ["type": "text", "text": text]
                case .image: ["type": "image"]
                case .video: ["type": "video"]
                }
            }
            var mapped: MLXLMCommon.Message = ["role": message.role.rawValue, "content": content]
            if let reasoning = message.reasoningContent { mapped["reasoning_content"] = reasoning }
            if let id = message.toolCallID { mapped["tool_call_id"] = id }
            if let calls = message.toolCalls {
                mapped["tool_calls"] = calls.map { call -> [String: any Sendable] in
                    ["id": call.id, "type": "function", "function": [
                        "name": call.name, "arguments": object(call.arguments)
                    ] as [String: any Sendable]]
                }
            }
            return mapped
        }
    }

    static func tools(_ values: [TextToolDefinition]?) -> [ToolSpec]? {
        values?.map { tool in
            ["type": "function", "function": [
                "name": tool.name, "description": tool.description,
                "parameters": object(tool.parameters)
            ] as [String: any Sendable]]
        }
    }

    static func object(_ value: [String: TextJSONValue]) -> [String: any Sendable] {
        value.mapValues { sendable($0) }
    }

    private static func sendable(_ value: TextJSONValue) -> any Sendable {
        switch value {
        case .null: NSNull()
        case .bool(let item): item
        case .int(let item): item
        case .double(let item): item
        case .string(let item): item
        case .array(let items): items.map { sendable($0) }
        case .object(let items): object(items)
        }
    }
}
