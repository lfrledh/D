import DInference
import Foundation

/// A value-only plan. The caller validates asset access and the model's token budget.
public struct ChatContextPlan: Sendable, Equatable {
    public let messagesJSON: String
    public let images: [WorkflowAssetReference]
    public let videos: [WorkflowAssetReference]
    /// The existing conservative byte estimate, not a tokenizer result.
    public let estimatedTokens: Int

    private struct FormMessage: Encodable {
        let role: String
        let parts: [FormPart]
        let reasoningContent: String?
        let toolCalls: [TextToolCall]?
    }
    private struct FormPart: Encodable {
        let type: String
        let text: String?
        let index: Int?
    }

    public static func build(path: [ChatMessage], attempts: [ChatAttempt], prompt: String,
                             attachments: [ChatAttachment], system: String,
                             adopted: [UUID: String] = [:], excluded: Set<UUID> = [],
                             knowledgeExcerpts: [ChatKnowledgeExcerpt] = []) throws -> Self {
        let pathIDs = Set(path.map(\.id))
        guard pathIDs.count == path.count, Set(attempts.map(\.id)).count == attempts.count,
              excluded.isSubset(of: pathIDs), Set(adopted.keys).isDisjoint(with: excluded),
              adopted.keys.allSatisfy({ id in
                  path.contains { $0.id == id && $0.role == .assistant } &&
                  !(adopted[id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
              }) else { throw WorkflowIssue("上下文选择含未知、重复或无效的消息身份。") }
        let byAttempt = Dictionary(uniqueKeysWithValues: attempts.map { ($0.id, $0) })
        var messages: [FormMessage] = []
        var images: [WorkflowAssetReference] = []
        var videos: [WorkflowAssetReference] = []
        if !system.isEmpty {
            messages.append(.init(role: "system", parts: [.init(type: "text", text: system, index: nil)],
                                  reasoningContent: nil, toolCalls: nil))
        }
        let selected = path.filter { !excluded.contains($0.id) }
        for entry in selected {
            var parts: [FormPart] = []
            var reasoning: String?
            if entry.role == .user {
                try appendUserParts(entry.attachments, text: entry.text, to: &parts,
                                    images: &images, videos: &videos, excerpts: entry.knowledgeExcerpts ?? [])
            } else {
                guard let attemptID = entry.attemptID, let attempt = byAttempt[attemptID],
                      attempt.assistantMessageID == entry.id,
                      attempt.response?.toolCalls.isEmpty != false,
                      attempt.response?.finishReason != .toolCalls,
                      attempt.response?.finishReason != .incomplete,
                      attempt.status != .running, attempt.status != .saving else {
                    throw WorkflowIssue("所选路径含未完成或待处理工具调用。")
                }
                let selectedText: String
                if let replacement = adopted[entry.id] {
                    selectedText = replacement
                } else {
                    guard attempt.status == .completed,
                          let final = attempt.response?.finalText, !final.isEmpty else {
                        throw WorkflowIssue("部分回答须显式采用后才能进入上下文。")
                    }
                    selectedText = final
                    reasoning = attempt.response?.reasoningText
                }
                parts.append(.init(type: "text", text: selectedText, index: nil))
            }
            messages.append(.init(role: entry.role.rawValue, parts: parts,
                                  reasoningContent: reasoning, toolCalls: nil))
        }
        var promptParts: [FormPart] = []
        try appendUserParts(attachments, text: prompt, to: &promptParts,
                            images: &images, videos: &videos, excerpts: knowledgeExcerpts)
        messages.append(.init(role: "user", parts: promptParts, reasoningContent: nil, toolCalls: nil))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(messages)
        guard bytes.count <= 1_048_576 else {
            throw WorkflowIssue("完整聊天消息超过1MiB；请显式开启新会话或分叉较短路径。")
        }
        return .init(messagesJSON: String(decoding: bytes, as: UTF8.self), images: images,
                     videos: videos, estimatedTokens: (bytes.count + 2) / 3 + images.count * 1024 + videos.count * 4096)
    }

    private static func appendUserParts(_ attachments: [ChatAttachment], text: String,
                                        to parts: inout [FormPart],
                                        images: inout [WorkflowAssetReference],
                                        videos: inout [WorkflowAssetReference],
                                        excerpts: [ChatKnowledgeExcerpt]) throws {
        for excerpt in excerpts {
            try excerpt.validate()
            parts.append(.init(type: "text", text: excerpt.promptText, index: nil))
        }
        for item in attachments where item.sourceOnly != true {
            switch item.reference.kind {
            case .text, .document:
                guard let snapshot = item.textSnapshot else { throw WorkflowIssue("文字附件缺少冻结快照。") }
                parts.append(.init(type: "text", text: "[Source material: \(item.name)]\n\(snapshot)\n[/Source material]", index: nil))
            case .image:
                parts.append(.init(type: "image", text: nil, index: images.count)); images.append(item.reference)
            case .video:
                parts.append(.init(type: "video", text: nil, index: videos.count)); videos.append(item.reference)
            default: throw WorkflowIssue("附件类型不能用于文字聊天。")
            }
        }
        parts.append(.init(type: "text", text: text, index: nil))
    }
}
