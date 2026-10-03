import Foundation

/// User decisions are versions alongside model output, never edits to the output.
public struct ChatTextRevision: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let messageID: UUID
    public let text: String
    public let createdAt: Date
    public init(id: UUID = UUID(), messageID: UUID, text: String, createdAt: Date = Date()) {
        self.id = id; self.messageID = messageID; self.text = text; self.createdAt = createdAt
    }
}

/// Optional at the session boundary so existing v1 records round-trip unchanged.
public struct ChatContextChoices: Codable, Sendable, Equatable {
    public var revisions: [ChatTextRevision] = []
    public var adoptedRevisionIDs: [UUID] = []
    public var excludedMessageIDs: [UUID] = []
    public var favoriteMessageIDs: [UUID] = []
    public var tags: [String] = []
    public var pinned = false
    public var deletedAt: Date?
    public var manuallyNamed = false
    public init() {}

    public var adopted: [UUID: String] {
        var result: [UUID: String] = [:]
        for id in adoptedRevisionIDs {
            if let revision = revisions.first(where: { $0.id == id }) { result[revision.messageID] = revision.text }
        }
        return result
    }

    public func validate(messages: [ChatMessage]) throws {
        let ids = Set(messages.map(\.id)), assistantIDs = Set(messages.filter { $0.role == .assistant }.map(\.id))
        let revisionIDs = Set(revisions.map(\.id))
        guard revisions.count <= 10_000, revisionIDs.count == revisions.count,
              Set(adoptedRevisionIDs).count == adoptedRevisionIDs.count,
              Set(adoptedRevisionIDs).isSubset(of: revisionIDs),
              Set(excludedMessageIDs).count == excludedMessageIDs.count,
              Set(excludedMessageIDs).isSubset(of: ids),
              Set(favoriteMessageIDs).count == favoriteMessageIDs.count,
              Set(favoriteMessageIDs).isSubset(of: ids), tags.count <= 24,
              Set(tags).count == tags.count else { throw WorkflowIssue("聊天选择记录的身份或范围无效。") }
        var adoptedMessages = Set<UUID>()
        for revision in revisions {
            guard assistantIDs.contains(revision.messageID), !revision.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  revision.text.utf8.count <= 1_048_576 else { throw WorkflowIssue("人工回答版本无效。") }
            if adoptedRevisionIDs.contains(revision.id), !adoptedMessages.insert(revision.messageID).inserted {
                throw WorkflowIssue("同一消息只能采用一个人工版本。")
            }
        }
        for tag in tags {
            guard !tag.isEmpty, tag.count <= 32, tag == tag.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw WorkflowIssue("标签须为1至32个字符。")
            }
        }
    }
}

/// One explicit, reusable answer choice. Manual revisions remain distinct assets;
/// the model's original receipt and earlier published assets are never rewritten.
public struct ChatSelectedAnswer: Sendable, Equatable {
    public let text: String
    public let assetID: UUID
    public let revisionID: UUID?
    public let attempt: ChatAttempt?
    public let importedSource: ChatImportedSource?
}

extension ChatSession {
    public func selectedAnswer(messageID: UUID) -> ChatSelectedAnswer? {
        guard let message = messages.first(where: { $0.id == messageID && $0.role == .assistant }) else { return nil }
        let attempt = message.attemptID.flatMap { id in attempts.first { $0.id == id && $0.assistantMessageID == messageID } }
        // A running answer cannot be published, even if a stale UI offers an action.
        guard attempt?.status != .running, attempt?.status != .saving else { return nil }
        if let choices = contextChoices,
           let revision = choices.revisions.first(where: { $0.messageID == messageID && choices.adoptedRevisionIDs.contains($0.id) }) {
            return .init(text: revision.text, assetID: revision.id, revisionID: revision.id,
                         attempt: attempt, importedSource: message.importedSource)
        }
        if let attempt, attempt.status == .completed, let text = attempt.response?.finalText, !text.isEmpty {
            return .init(text: text, assetID: message.id, revisionID: nil, attempt: attempt, importedSource: nil)
        }
        if let source = message.importedSource, !message.text.isEmpty {
            return .init(text: message.text, assetID: message.id, revisionID: nil, attempt: nil, importedSource: source)
        }
        return nil // Partial output needs explicit adoption before it becomes an asset.
    }
}
