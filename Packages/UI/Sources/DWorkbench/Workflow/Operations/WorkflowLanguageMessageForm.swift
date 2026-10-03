import DInference
import Foundation

/// Shared Quick/Canvas form transport. Media are indexes into admitted asset
/// ports, never arbitrary paths or URLs supplied by a text field.
enum WorkflowLanguageMessageForm {
    static let optionalFields: Set<String> = ["messagesJSON", "toolsJSON", "thinking", "reasoningEffort", "preserveThinking", "seed", "memoryBudgetGiB", "loadingStrategy", "chatTemplateOverride"]
    static let fields: [WorkflowFieldDefinition] = [
        .init("memoryBudgetGiB", "显式内存预算 GiB（0使用运行时策略）", .integer, .integer(0)),
        .init("loadingStrategy", "加载方式（精度不变）", .choice(["resident", "ssdLayered"]), .text("resident")),
        .init("messagesJSON", "有序消息 JSON（留空使用任务；媒体 index 从0开始）", .text(multiline: true), .text("")),
        .init("toolsJSON", "工具声明 JSON（仅声明，不自动执行）", .text(multiline: true), .text("")),
        .init("thinking", "思考", .choice(["model", "on", "off"]), .text("model")),
        .init("reasoningEffort", "思考强度（27B）", .choice(["model", "low", "medium", "xhigh"]), .text("model")),
        .init("preserveThinking", "保留历史思考（27B）", .choice(["model", "on", "off"]), .text("model")),
        .init("seed", "文字随机种子（留空随机）", .text(multiline: false), .text("")),
    ]
    static func loadingStrategy(_ parameters: [String: WorkflowScalar]) throws -> TextLoadingStrategy? {
        guard let value = parameters["loadingStrategy"] else { return nil }
        guard case .text(let raw) = value, let strategy = TextLoadingStrategy(rawValue: raw) else {
            throw WorkflowIssue("文字加载方式无效；不会静默切换模型或精度。")
        }
        return strategy
    }
    static func memoryBudgetBytes(_ parameters: [String: WorkflowScalar]) throws -> UInt64? {
        guard let value = parameters["memoryBudgetGiB"] else { return nil }
        guard case .integer(let budget) = value, budget >= 0,
              let gib = UInt64(exactly: budget), gib <= UInt64(Int64.max) / 1_073_741_824 else {
            throw WorkflowIssue("内存预算必须是非负的整数 GiB；0 使用运行时策略。")
        }
        return gib == 0 ? nil : gib * 1_073_741_824
    }
    private struct Message: Decodable {
        let role: TextMessageRole
        let parts: [Part]
        let reasoningContent: String?
        let toolCalls: [TextToolCall]?
        let toolCallID: String?
    }
    private struct Part: Decodable { let type: String; let text: String?; let index: Int? }
    static func messages(_ json: String, images: [TextImageReference], videos: [TextVideoReference]) throws -> [TextMessage]? {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        for object in try objects(json) {
            try keys(object, allowed: ["role", "parts", "reasoningContent", "toolCalls", "toolCallID"])
            if let parts = object["parts"] as? [[String: Any]] {
                for part in parts { try keys(part, allowed: ["type", "text", "index"]) }
            }
            if let calls = object["toolCalls"] as? [[String: Any]] {
                for call in calls { try keys(call, allowed: ["id", "name", "arguments", "validationError"]) }
            }
        }
        let forms = try decode([Message].self, json)
        var usedImages = Set<Int>(), usedVideos = Set<Int>()
        let messages = try forms.map { message in
            let parts = try message.parts.map { part -> TextMessagePart in
                switch part.type {
                case "text":
                    guard let text = part.text, part.index == nil else { throw WorkflowIssue("文字消息片段需要 text，不接受媒体 index。") }
                    return .text(text)
                case "image":
                    guard part.text == nil, let i = part.index, images.indices.contains(i) else { throw WorkflowIssue("图像消息 index 未对应已接入图像。") }
                    usedImages.insert(i); return .image(images[i])
                case "video":
                    guard part.text == nil, let i = part.index, videos.indices.contains(i) else { throw WorkflowIssue("视频消息 index 未对应已接入视频。") }
                    usedVideos.insert(i); return .video(videos[i])
                default: throw WorkflowIssue("消息片段 type 仅支持 text、image、video。")
                }
            }
            return TextMessage(role: message.role, parts: parts, reasoningContent: message.reasoningContent,
                toolCalls: message.toolCalls, toolCallID: message.toolCallID)
        }
        guard usedImages == Set(images.indices), usedVideos == Set(videos.indices) else {
            throw WorkflowIssue("消息未引用全部已接入媒体；不会静默忽略输入。")
        }
        return messages
    }
    static func tools(_ json: String) throws -> [TextToolDefinition]? {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        for object in try objects(json) { try keys(object, allowed: ["name", "description", "parameters"]) }
        return try decode([TextToolDefinition].self, json)
    }
    static func thinking(_ p: [String: WorkflowScalar]) throws -> TextThinkingOptions? {
        func flag(_ key: String) throws -> Bool? {
            switch p[key]?.string ?? "model" { case "model": nil; case "on": true; case "off": false
            default: throw WorkflowIssue("未知的思考设置。") }
        }
        let enabled = try flag("thinking"), preserve = try flag("preserveThinking")
        let value = p["reasoningEffort"]?.string ?? "model"
        let effort: TextReasoningEffort?
        if value == "model" { effort = nil }
        else { guard let parsed = TextReasoningEffort(rawValue: value) else { throw WorkflowIssue("未知的思考强度。") }; effort = parsed }
        return enabled == nil && preserve == nil && effort == nil ? nil : .init(enableThinking: enabled, reasoningEffort: effort, preserveThinking: preserve)
    }
    static func seed(_ p: [String: WorkflowScalar]) throws -> UInt64? {
        let text = p["seed"]?.string ?? ""
        if text.isEmpty { return nil }
        guard let value = UInt64(text), String(value) == text else { throw WorkflowIssue("seed 需要完整 UInt64 十进制整数。") }
        return value
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        guard text.utf8.count <= 1_048_576 else { throw WorkflowIssue("消息或工具声明超过1MiB解析预算。") }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    private static func objects(_ text: String) throws -> [[String: Any]] {
        guard text.utf8.count <= 1_048_576,
              let objects = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
            throw WorkflowIssue("消息和工具必须是对象数组，且不超过1MiB。")
        }
        return objects
    }
    private static func keys(_ object: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw WorkflowIssue("未支持的消息/工具字段：\(unknown.sorted().joined(separator: ", "))；未忽略输入。") }
    }
}
