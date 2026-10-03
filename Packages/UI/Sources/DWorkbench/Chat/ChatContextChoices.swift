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
