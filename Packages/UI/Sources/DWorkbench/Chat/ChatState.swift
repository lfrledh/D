import DInference
import Foundation

public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let reference: WorkflowAssetReference
    /// Exact UTF-8 source material captured when the attachment was admitted.
    public let textSnapshot: String?
    public init(id: UUID = UUID(), name: String, reference: WorkflowAssetReference, textSnapshot: String? = nil) {
        self.id = id; self.name = name; self.reference = reference; self.textSnapshot = textSnapshot
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: UUID
    public let parentID: UUID?
    public let role: Role
    public let text: String
    public let attachments: [ChatAttachment]
    public let attemptID: UUID?
    public init(id: UUID = UUID(), parentID: UUID?, role: Role, text: String,
                attachments: [ChatAttachment] = [], attemptID: UUID? = nil) {
        self.id = id; self.parentID = parentID; self.role = role; self.text = text
        self.attachments = attachments; self.attemptID = attemptID
    }
}

public struct ChatAttempt: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case running, completed, partial, cancelled, failed, interrupted, saving }
    public let id: UUID
    public let sessionID: UUID
    public let userMessageID: UUID
    public let assistantMessageID: UUID
    public let node: WorkflowNode
    public let messagesJSON: String
    public let inputs: [String: WorkflowValue]
    public let systemPrompt: String
    public let createdAt: Date
    public var status: Status
    public var rawText: String
    public var response: TextResponse?
    public var output: WorkflowAssetReference?
    public var issue: String?
    public init(id: UUID = UUID(), sessionID: UUID, userMessageID: UUID, assistantMessageID: UUID,
                node: WorkflowNode, messagesJSON: String, inputs: [String: WorkflowValue],
                systemPrompt: String, createdAt: Date = Date(), status: Status = .running) {
        self.id = id; self.sessionID = sessionID; self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID; self.node = node; self.messagesJSON = messagesJSON
        self.inputs = inputs; self.systemPrompt = systemPrompt; self.createdAt = createdAt
        self.status = status; self.rawText = ""; self.response = nil; self.output = nil; self.issue = nil
    }
}

public struct ChatSession: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var archived = false
    public var selectedLeafID: UUID?
    public var messages: [ChatMessage] = []
    public var attempts: [ChatAttempt] = []
    public var draft = ""
    public var attachments: [ChatAttachment] = []
    public var configuration: WorkflowNode?
    public var systemPrompt = ""
    public var originSessionID: UUID?
    public var originLeafID: UUID?
    public init(id: UUID = UUID(), title: String = "新对话") { self.id = id; self.title = title }

    public func path(to leaf: UUID?) throws -> [ChatMessage] {
        guard let leaf else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var seen = Set<UUID>(), reversed: [ChatMessage] = [], cursor: UUID? = leaf
        while let id = cursor {
            guard seen.insert(id).inserted, let message = byID[id] else { throw WorkflowIssue("聊天分支引用或循环无效。") }
            reversed.append(message); cursor = message.parentID
        }
        return Array(reversed.reversed())
    }
}

public struct ChatPromptPreset: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var prompt: String
    public init(id: UUID = UUID(), name: String, prompt: String) { self.id = id; self.name = name; self.prompt = prompt }
}

public struct ChatState: Codable, Sendable, Equatable {
    public var version = 1
    public var revision: UInt64 = 0
    public var selectedSessionID: UUID?
    public var sessions: [ChatSession] = []
    public var presets: [ChatPromptPreset] = []
    public init() {}

    public func validate() throws {
        guard version == 1, sessions.count <= 512, presets.count <= 128,
              Set(sessions.map(\.id)).count == sessions.count,
              Set(presets.map(\.id)).count == presets.count,
              selectedSessionID == nil || sessions.contains(where: { $0.id == selectedSessionID }) else {
            throw WorkflowIssue("聊天记录版本、身份或选中会话无效；原件保持只读。")
        }
        for preset in presets {
            guard !preset.name.isEmpty, preset.name.utf8.count <= 256, preset.prompt.utf8.count <= 65_536 else {
                throw WorkflowIssue("聊天提示预设无效；原件保持只读。")
            }
        }
        for session in sessions {
            guard !session.title.isEmpty, session.title.utf8.count <= 512,
                  session.draft.utf8.count <= 1_048_576, session.systemPrompt.utf8.count <= 65_536,
                  session.messages.count <= 10_000, session.attempts.count <= 10_000,
                  Set(session.messages.map(\.id)).count == session.messages.count,
                  Set(session.attempts.map(\.id)).count == session.attempts.count,
                  session.selectedLeafID == nil || session.messages.contains(where: { $0.id == session.selectedLeafID }) else {
                throw WorkflowIssue("聊天会话内容或分支身份无效；原件保持只读。")
            }
            if let node = session.configuration { try Self.validateNode(node) }
            try Self.validateAttachments(session.attachments)
            let byID = Dictionary(uniqueKeysWithValues: session.messages.map { ($0.id, $0) })
            let attempts = Dictionary(uniqueKeysWithValues: session.attempts.map { ($0.id, $0) })
            for message in session.messages {
                guard message.text.utf8.count <= 1_048_576,
                      message.parentID == nil || byID[message.parentID!] != nil,
                      message.parentID != message.id else { throw WorkflowIssue("聊天消息内容或父项无效。") }
                try Self.validateAttachments(message.attachments)
                switch message.role {
                case .user:
                    guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          message.attemptID == nil,
                          message.parentID == nil || byID[message.parentID!]?.role == .assistant else {
                        throw WorkflowIssue("用户消息文字或父助手消息无效。")
                    }
                case .assistant:
                    guard let attemptID = message.attemptID, let attempt = attempts[attemptID],
                          attempt.assistantMessageID == message.id, attempt.userMessageID == message.parentID,
                          message.parentID.flatMap({ byID[$0]?.role }) == .user else {
                        throw WorkflowIssue("助手消息缺少冻结尝试或父用户消息。")
                    }
                }
                _ = try session.path(to: message.id)
            }
            for attempt in session.attempts {
                guard attempt.sessionID == session.id, byID[attempt.userMessageID]?.role == .user,
                      byID[attempt.assistantMessageID]?.role == .assistant,
                      attempt.rawText.utf8.count <= 4_194_304,
                      (attempt.response?.rawText.utf8.count ?? 0) <= 4_194_304,
                      attempt.messagesJSON.utf8.count <= 1_048_576,
                      attempt.node.parameters["messagesJSON"]?.string == attempt.messagesJSON,
                      attempt.systemPrompt.utf8.count <= 65_536 else { throw WorkflowIssue("聊天尝试引用或大小无效。") }
                try Self.validateNode(attempt.node)
                for value in attempt.inputs.values {
                    for ref in value.datum?.assetReferences ?? [] { guard [.image, .video].contains(ref.kind) else { throw WorkflowIssue("聊天媒体端口类型无效。") } }
                }
            }
        }
    }
    private static func validateNode(_ node: WorkflowNode) throws {
        guard [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38].contains(node.operationID),
              node.parameters["modelID"]?.string?.isEmpty == false else { throw WorkflowIssue("聊天必须使用明确的文字模型。") }
        try WorkflowRegistry.standard.validate(node)
    }
    private static func validateAttachments(_ items: [ChatAttachment]) throws {
        guard items.count <= 32, Set(items.map(\.id)).count == items.count else { throw WorkflowIssue("聊天附件数量或身份无效。") }
        for item in items {
            guard !item.name.isEmpty, item.name.utf8.count <= 512,
                  [.text, .image, .video].contains(item.reference.kind),
                  (item.textSnapshot?.utf8.count ?? 0) <= 524_288,
                  (item.reference.kind == .text) == (item.textSnapshot != nil) else {
                throw WorkflowIssue("聊天附件类型、快照或名称无效。")
            }
        }
    }
}
