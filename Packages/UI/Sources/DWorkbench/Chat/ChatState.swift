import DInference
import Foundation

public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let reference: WorkflowAssetReference
    /// Exact UTF-8 source material captured when the attachment was admitted.
    public let textSnapshot: String?
    public let documentSnapshot: ChatDocumentSnapshot?
    /// Provenance retained with the draft; content is represented by the editable draft text.
    public let sourceOnly: Bool?
    public init(id: UUID = UUID(), name: String, reference: WorkflowAssetReference, textSnapshot: String? = nil,
                documentSnapshot: ChatDocumentSnapshot? = nil, sourceOnly: Bool? = nil) {
        self.id = id; self.name = name; self.reference = reference; self.textSnapshot = textSnapshot
        self.documentSnapshot = documentSnapshot; self.sourceOnly = sourceOnly
    }
}

/// Imported transcript provenance is not a model execution receipt.
public struct ChatImportedSource: Codable, Sendable, Equatable {
    public let format: String
    public let version: Int
    public let sourceSHA256: String
    public let sourceIndex: Int
    func validate() throws {
        guard format == ChatInterchange.sourceFormat, version == ChatInterchange.sourceVersion,
              sourceIndex >= 0, sourceIndex < ChatInterchange.maximumMessages,
              sourceSHA256.count == 64, sourceSHA256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw WorkflowIssue("Invalid imported transcript provenance.")
        }
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: UUID
    public let parentID: UUID?
    public let role: Role
    public let text: String
    public let attachments: [ChatAttachment]
    public let knowledgeExcerpts: [ChatKnowledgeExcerpt]?
    public let attemptID: UUID?
    public let importedSource: ChatImportedSource?
    public init(id: UUID = UUID(), parentID: UUID?, role: Role, text: String,
                attachments: [ChatAttachment] = [], attemptID: UUID? = nil,
                knowledgeExcerpts: [ChatKnowledgeExcerpt]? = nil, importedSource: ChatImportedSource? = nil) {
        self.id = id; self.parentID = parentID; self.role = role; self.text = text
        self.attachments = attachments; self.attemptID = attemptID
        self.knowledgeExcerpts = knowledgeExcerpts; self.importedSource = importedSource
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
    /// An explicit replay keeps the source attempt immutable; nil also decodes old records.
    public var replayedAttemptID: UUID?
    /// Comparison reuses the frozen input but deliberately changes model/settings.
    public var comparisonSourceAttemptID: UUID?
    public var memoryUses: [ChatMemoryUse]?
    public var outputFormat: ChatOutputFormat?
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
    public var contextChoices: ChatContextChoices?
    public var pendingSpeechDraft: ChatAttachment?
    public var contextSummaries: [ChatContextSummary]?
    public var memoryScopes: [ChatMemoryScope]?
    public var webOptions: ChatWebOptions?
    public var outputFormat: ChatOutputFormat?
    public var mcpEndpoint: String?
    public var assistanceOptions: ChatAssistanceOptions?
    public var assistanceExecutions: [ChatAssistanceExecution]?
    public var importLossNotes: [String]?
    public var toolActivities: [ChatToolActivity]?
    public var artifacts: [ChatArtifactContent]?
    public var knowledgeReranks: [ChatKnowledgeRerank]?
    public var knowledgeScope: [UUID]?
    public var knowledgeExcerpts: [ChatKnowledgeExcerpt]?
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
    public var configuration: WorkflowNode?
    public var selectionInstruction: String?
    public init(id: UUID = UUID(), name: String, prompt: String,
                configuration: WorkflowNode? = nil, selectionInstruction: String? = nil) {
        self.id = id; self.name = name; self.prompt = prompt
        self.configuration = configuration; self.selectionInstruction = selectionInstruction
    }
}

public struct ChatState: Codable, Sendable, Equatable {
    public var version = 1
    public var revision: UInt64 = 0
    public var selectedSessionID: UUID?
    public var sessions: [ChatSession] = []
    public var presets: [ChatPromptPreset] = []
    public var knowledgeDocuments: [ChatKnowledgeDocument]?
    public var memoryEntries: [ChatMemoryEntry]?
    public init() {}

    public func validate() throws {
        guard version == 1, sessions.count <= 512, presets.count <= 128,
              Set(sessions.map(\.id)).count == sessions.count,
              Set(presets.map(\.id)).count == presets.count,
              selectedSessionID == nil || sessions.contains(where: { $0.id == selectedSessionID }) else {
            throw WorkflowIssue("聊天记录版本、身份或选中会话无效；原件保持只读。")
        }
        for preset in presets {
            // v1 accepted whitespace-only names; preserve old archives on read.
            guard !preset.name.isEmpty,
                  preset.name.utf8.count <= 256, preset.prompt.utf8.count <= 65_536,
                  (preset.selectionInstruction?.utf8.count ?? 0) <= 16_384 else {
                throw WorkflowIssue("聊天提示预设无效；原件保持只读。")
            }
            if let node = preset.configuration { try Self.validateNode(node) }
        }
        let documents = knowledgeDocuments ?? []
        guard documents.count <= 64, Set(documents.map(\.id)).count == documents.count,
              documents.reduce(0, { $0 + ($1.material.textSnapshot?.utf8.count ?? 0) }) <= 8_388_608 else {
            throw WorkflowIssue("资料库容量或身份无效。")
        }
        for document in documents {
            try Self.validateAttachments([document.material]); _ = try document.extraction()
        }
        let memories = memoryEntries ?? []
        guard memories.count <= 1024, Set(memories.map { "\($0.id):\($0.revision)" }).count == memories.count,
              memories.reduce(0, { $0 + $1.text.utf8.count }) <= 2_097_152 else { throw WorkflowIssue("记忆记录容量或版本身份无效。") }
        for entry in memories { try entry.validate() }
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
            let artifacts = session.artifacts ?? []
            guard artifacts.count <= 1024,
                  Set(artifacts.map { "\($0.id):\($0.revision)" }).count == artifacts.count else {
                throw WorkflowIssue("成果版本数量或身份无效。")
            }
            for artifact in artifacts {
                try artifact.validate()
                guard artifact.sessionID == session.id, artifact.output != nil else {
                    throw WorkflowIssue("成果不属于本会话或未发布。")
                }
            }
            let reranks = session.knowledgeReranks ?? []
            guard reranks.count <= 256, Set(reranks.map(\.id)).count == reranks.count else { throw WorkflowIssue("资料重排记录数量或身份无效。") }
            for record in reranks { try record.validate() }
            try session.outputFormat?.validate()
            try session.assistanceOptions?.validate()
            let assistance = session.assistanceExecutions ?? []
            guard assistance.count <= 256, Set(assistance.map(\.id)).count == assistance.count else {
                throw WorkflowIssue("辅助任务历史数量或身份无效。")
            }
            for execution in assistance {
                try execution.validate()
                guard execution.record.source.sessionID == session.id else { throw WorkflowIssue("辅助任务来源不属于本会话。") }
            }
            let importNotes = session.importLossNotes ?? []
            guard importNotes.count <= 4096, importNotes.reduce(0, { $0 + $1.utf8.count }) <= 524_288 else {
                throw WorkflowIssue("Imported transcript mapping notes exceed the supported limit.")
            }
            let activities = session.toolActivities ?? []
            guard activities.count <= 256, Set(activities.map(\.id)).count == activities.count,
                  activities.reduce(0, { $0 + ($1.resultJSON?.utf8.count ?? 0) }) <= 8_388_608 else { throw WorkflowIssue("工具历史超过保存预算。") }
            for activity in activities { try activity.validate() }
            let summaries = session.contextSummaries ?? []
            guard summaries.count <= 256, Set(summaries.map { "\($0.id):\($0.revision)" }).count == summaries.count,
                  (session.memoryScopes?.count ?? 0) <= 2 else { throw WorkflowIssue("摘要历史或记忆范围无效。") }
            for summary in summaries { try summary.validate() }
            try session.contextChoices?.validate(messages: session.messages)
            if let endpoint = session.mcpEndpoint { _ = try ChatMCPService.validateEndpoint(endpoint) }
            try Self.validateAttachments(session.attachments)
            if let pending = session.pendingSpeechDraft {
                try Self.validateAttachments([pending])
                guard pending.sourceOnly == true else { throw WorkflowIssue("语音原稿必须是明确的来源引用。") }
            }
            if let scope = session.knowledgeScope {
                guard scope.count <= 64, Set(scope).count == scope.count,
                      Set(scope).isSubset(of: Set(documents.map(\.id))) else {
                    throw WorkflowIssue("资料范围引用了未登记的内容。")
                }
            }
            try Self.validateExcerpts(session.knowledgeExcerpts)
            let byID = Dictionary(uniqueKeysWithValues: session.messages.map { ($0.id, $0) })
            let attempts = Dictionary(uniqueKeysWithValues: session.attempts.map { ($0.id, $0) })
            for message in session.messages {
                guard message.text.utf8.count <= 1_048_576,
                      message.parentID == nil || byID[message.parentID!] != nil,
                      message.parentID != message.id else { throw WorkflowIssue("聊天消息内容或父项无效。") }
                try message.importedSource?.validate()
                try Self.validateAttachments(message.attachments)
                try Self.validateExcerpts(message.knowledgeExcerpts)
                switch message.role {
                case .user:
                    guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          message.attemptID == nil,
                          message.parentID == nil || byID[message.parentID!]?.role == .assistant else {
                        throw WorkflowIssue("用户消息文字或父助手消息无效。")
                    }
                case .assistant:
                    if message.importedSource != nil {
                        guard message.attemptID == nil, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              message.parentID.flatMap({ byID[$0]?.role }) == .user else {
                            throw WorkflowIssue("Imported assistant text cannot masquerade as a local model attempt.")
                        }
                        break
                    }
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
                      byID[attempt.assistantMessageID]?.attemptID == attempt.id,
                      byID[attempt.assistantMessageID]?.importedSource == nil,
                      attempt.rawText.utf8.count <= 4_194_304,
                      (attempt.response?.rawText.utf8.count ?? 0) <= 4_194_304,
                      attempt.messagesJSON.utf8.count <= 1_048_576,
                      attempt.node.parameters["messagesJSON"]?.string == attempt.messagesJSON,
                      attempt.systemPrompt.utf8.count <= 65_536 else { throw WorkflowIssue("聊天尝试引用或大小无效。") }
                guard (attempt.memoryUses?.count ?? 0) <= 1024 else { throw WorkflowIssue("记忆来源数量无效。") }
                for use in attempt.memoryUses ?? [] { guard use.revision > 0 else { throw WorkflowIssue("记忆来源版本无效。") } }
                try attempt.outputFormat?.validate()
                try Self.validateNode(attempt.node)
                for value in attempt.inputs.values {
                    for ref in value.datum?.assetReferences ?? [] { guard [.image, .video].contains(ref.kind) else { throw WorkflowIssue("聊天媒体端口类型无效。") } }
                }
            }
        }
    }
    private static func validateExcerpts(_ excerpts: [ChatKnowledgeExcerpt]?) throws {
        guard let excerpts else { return }
        guard excerpts.count <= 32, Set(excerpts.map(\.id)).count == excerpts.count,
              excerpts.reduce(0, { $0 + $1.text.utf8.count }) <= 524_288 else {
            throw WorkflowIssue("资料引用数量或大小无效。")
        }
        for excerpt in excerpts { try excerpt.validate() }
    }
    static func validateNode(_ node: WorkflowNode) throws {
        guard [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38].contains(node.operationID),
              node.parameters["modelID"]?.string?.isEmpty == false else { throw WorkflowIssue("聊天必须使用明确的文字模型。") }
        try WorkflowRegistry.standard.validate(node)
    }
    private static func validateAttachments(_ items: [ChatAttachment]) throws {
        guard items.count <= 32, Set(items.map(\.id)).count == items.count else { throw WorkflowIssue("聊天附件数量或身份无效。") }
        for item in items {
            guard !item.name.isEmpty, item.name.utf8.count <= 512,
                  [.text, .image, .video, .document].contains(item.reference.kind),
                  item.sourceOnly != true || item.reference.kind == .text,
                  (item.textSnapshot?.utf8.count ?? 0) <= 524_288,
                  ([.text, .document].contains(item.reference.kind)) == (item.textSnapshot != nil),
                  (item.reference.kind == .document) == (item.documentSnapshot != nil) else {
                throw WorkflowIssue("聊天附件类型、快照或名称无效。")
            }
            if let document = item.documentSnapshot, let text = item.textSnapshot {
                try document.validate(reference: item.reference, text: text)
            }
        }
    }
}
