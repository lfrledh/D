import CryptoKit
import Foundation

/// Product limits for these values, independent of the device's memory or model context window.
public struct ChatMemoryValidationLimits: Codable, Sendable, Equatable {
    public let maxSourceBytes: Int
    public let maxTextBytes: Int
    public let maxCoveredMessages: Int

    public init(maxSourceBytes: Int = 16_777_216, maxTextBytes: Int = 262_144,
                maxCoveredMessages: Int = 1_024) {
        self.maxSourceBytes = maxSourceBytes
        self.maxTextBytes = maxTextBytes
        self.maxCoveredMessages = maxCoveredMessages
    }

    fileprivate func validate() throws {
        guard maxSourceBytes > 0, maxTextBytes > 0, maxCoveredMessages > 0 else {
            throw WorkflowIssue("摘要或记忆的容量限制必须为正数。")
        }
    }
}

/// A digest of the actual selected ChatSession path, never a second representation of a session.
public struct ChatContextSource: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let selectedLeafID: UUID
    public let sha256: String
    /// Exact path order, including messages excluded from the next model request.
    public let pathMessageIDs: [UUID]
    /// Exact covered messages in path order; excluded messages cannot be covered.
    public let coveredMessageIDs: [UUID]

    private struct Snapshot: Encodable {
        let format: Int
        let sessionID: UUID
        let selectedLeafID: UUID
        let path: [ChatMessage]
        let attempts: [ChatAttempt]
        let systemPrompt: String
        let adoptedRevisions: [ChatTextRevision]
        let excludedMessageIDs: [UUID]
        let coveredMessageIDs: [UUID]
    }

    /// `coveredMessageIDs` is explicit: a summary may cover only part of the selected path.
    public static func capture(session: ChatSession, coveredMessageIDs: [UUID],
                               limits: ChatMemoryValidationLimits = .init()) throws -> Self {
        try limits.validate()
        guard let leaf = session.selectedLeafID else {
            throw WorkflowIssue("请先选择有消息的聊天分支，再记录来源。")
        }
        guard Set(session.messages.map(\.id)).count == session.messages.count,
              Set(session.attempts.map(\.id)).count == session.attempts.count else {
            throw WorkflowIssue("聊天来源存在重复的消息或尝试身份。")
        }
        try session.contextChoices?.validate(messages: session.messages)
        let path = try session.path(to: leaf)
        guard !path.isEmpty, path.count <= limits.maxCoveredMessages else {
            throw WorkflowIssue("聊天来源路径为空或超过消息数量限制。")
        }
        let pathIDs = path.map(\.id)
        let excluded = Set(session.contextChoices?.excludedMessageIDs ?? []).intersection(pathIDs)
        let available = pathIDs.filter { !excluded.contains($0) }
        let covered = Set(coveredMessageIDs)
        guard !coveredMessageIDs.isEmpty, covered.count == coveredMessageIDs.count,
              coveredMessageIDs.count <= limits.maxCoveredMessages,
              coveredMessageIDs == available.filter({ covered.contains($0) }) else {
            throw WorkflowIssue("摘要覆盖的消息须按当前分支顺序列出，且不能包含排除项。")
        }

        let choices = session.contextChoices
        let adoptedIDs = Set(choices?.adoptedRevisionIDs ?? [])
        let adopted = (choices?.revisions ?? []).filter { adoptedIDs.contains($0.id) && pathIDs.contains($0.messageID) }
            .sorted { $0.messageID.uuidString < $1.messageID.uuidString }
        let byAttempt = Dictionary(uniqueKeysWithValues: session.attempts.map { ($0.id, $0) })
        var attempts: [ChatAttempt] = []
        for message in path where message.role == .assistant {
            guard let id = message.attemptID, let parentID = message.parentID,
                  let attempt = byAttempt[id],
                  attempt.sessionID == session.id, attempt.assistantMessageID == message.id,
                  attempt.userMessageID == parentID else {
                throw WorkflowIssue("聊天来源缺少对应的助手尝试。")
            }
            if !excluded.contains(message.id) {
                let isAdopted = adopted.contains { $0.messageID == message.id }
                guard attempt.status != .running, attempt.status != .saving,
                      attempt.response?.toolCalls.isEmpty != false,
                      attempt.response?.finishReason != .toolCalls,
                      attempt.response?.finishReason != .incomplete,
                      isAdopted || (attempt.status == .completed && attempt.response?.finalText?.isEmpty == false) else {
                    throw WorkflowIssue("未完成、工具待处理或未采用的部分回答不能作为摘要来源。")
                }
            }
            attempts.append(attempt)
        }
        let snapshot = Snapshot(format: 1, sessionID: session.id, selectedLeafID: leaf,
                                path: path, attempts: attempts, systemPrompt: session.systemPrompt,
                                adoptedRevisions: adopted,
                                excludedMessageIDs: excluded.sorted { $0.uuidString < $1.uuidString },
                                coveredMessageIDs: coveredMessageIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Bound the aggregate before encoding the entire snapshot at once.
        var estimatedBytes = 0
        func account(_ count: Int) throws {
            guard count <= limits.maxSourceBytes - estimatedBytes else {
                throw WorkflowIssue("聊天来源快照超过设定容量；请缩短所选分支。")
            }
            estimatedBytes += count
        }
        try account(encoder.encode(session.systemPrompt).count)
        for message in path { try account(encoder.encode(message).count) }
        for attempt in attempts { try account(encoder.encode(attempt).count) }
        for revision in adopted { try account(encoder.encode(revision).count) }
        let bytes = try encoder.encode(snapshot)
        guard bytes.count <= limits.maxSourceBytes else {
            throw WorkflowIssue("聊天来源快照超过设定容量；请缩短所选分支。")
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let source = Self(sessionID: session.id, selectedLeafID: leaf, sha256: digest,
                          pathMessageIDs: pathIDs, coveredMessageIDs: coveredMessageIDs)
        try source.validate(limits: limits)
        return source
    }

    public func validate(limits: ChatMemoryValidationLimits = .init()) throws {
        try limits.validate()
        let covered = Set(coveredMessageIDs)
        guard !pathMessageIDs.isEmpty, pathMessageIDs.count <= limits.maxCoveredMessages,
              pathMessageIDs.last == selectedLeafID,
              Set(pathMessageIDs).count == pathMessageIDs.count,
              !coveredMessageIDs.isEmpty, coveredMessageIDs.count <= limits.maxCoveredMessages,
              covered.count == coveredMessageIDs.count,
              coveredMessageIDs == pathMessageIDs.filter({ covered.contains($0) }),
              sha256.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw WorkflowIssue("聊天来源摘要、路径或覆盖消息无效。")
        }
    }

    /// Recompute against current session values. A branch, edit, choice or media change fails closed.
    public func validate(current session: ChatSession,
                         limits: ChatMemoryValidationLimits = .init()) throws {
        try validate(limits: limits)
        guard session.id == sessionID else { throw WorkflowIssue("摘要来源属于另一聊天会话。") }
        guard session.selectedLeafID == selectedLeafID else { throw WorkflowIssue("摘要来源分支已改变。") }
        let current = try Self.capture(session: session, coveredMessageIDs: coveredMessageIDs, limits: limits)
        guard current.pathMessageIDs == pathMessageIDs else {
            throw WorkflowIssue("摘要覆盖的原消息已缺失或路径已改变。")
        }
        guard current.sha256 == sha256 else {
            throw WorkflowIssue("摘要来源消息、采用版本、排除项或附件已改变；请重新审核摘要。")
        }
    }
}

/// User-authored derivative text. Revision changes retain the same frozen source identity.
public struct ChatContextSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let revision: UInt64
    public let text: String
    public let source: ChatContextSource
    public let createdAt: Date
    public let auxiliaryAttemptID: UUID?
    public let enabled: Bool

    public init(id: UUID = UUID(), revision: UInt64 = 1, text: String, source: ChatContextSource,
                createdAt: Date = Date(), auxiliaryAttemptID: UUID? = nil, enabled: Bool = false,
                limits: ChatMemoryValidationLimits = .init()) throws {
        self.id = id; self.revision = revision; self.text = text; self.source = source
        self.createdAt = createdAt; self.auxiliaryAttemptID = auxiliaryAttemptID; self.enabled = enabled
        try validate(limits: limits)
    }

    public func validate(limits: ChatMemoryValidationLimits = .init()) throws {
        try limits.validate()
        guard revision > 0, !text.isEmpty, text.utf8.count <= limits.maxTextBytes else {
            throw WorkflowIssue("摘要版本、正文、来源或容量无效。")
        }
        try source.validate(limits: limits)
    }

    public func validate(current session: ChatSession,
                         limits: ChatMemoryValidationLimits = .init()) throws {
        try validate(limits: limits)
        try source.validate(current: session, limits: limits)
    }

    public func edited(text: String, limits: ChatMemoryValidationLimits = .init()) throws -> Self {
        guard revision < UInt64.max else { throw WorkflowIssue("摘要版本已达上限。") }
        return try .init(id: id, revision: revision + 1, text: text, source: source,
                         createdAt: createdAt, auxiliaryAttemptID: auxiliaryAttemptID,
                         enabled: enabled, limits: limits)
    }

    public func settingEnabled(_ value: Bool, limits: ChatMemoryValidationLimits = .init()) throws -> Self {
        guard revision < UInt64.max else { throw WorkflowIssue("摘要版本已达上限。") }
        return try .init(id: id, revision: revision + 1, text: text, source: source,
                         createdAt: createdAt, auxiliaryAttemptID: auxiliaryAttemptID,
                         enabled: value, limits: limits)
    }
}

public enum ChatMemoryScope: Codable, Sendable, Hashable {
    case personal
    case project(UUID)
}

public enum ChatMemorySource: Codable, Sendable, Equatable {
    case manual
    case chat(ChatContextSource)
}

public enum ChatMemoryAcceptance: String, Codable, Sendable, Equatable { case suggested, accepted }

/// A forgotten entry remains identifiable for persistence and cannot be re-enabled by these APIs.
public struct ChatMemoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let revision: UInt64
    public let text: String
    public let scope: ChatMemoryScope
    public let source: ChatMemorySource
    public let acceptance: ChatMemoryAcceptance
    public let enabled: Bool
    public let forgottenAt: Date?
    public let createdAt: Date

    public init(id: UUID = UUID(), revision: UInt64 = 1, text: String, scope: ChatMemoryScope,
                source: ChatMemorySource, acceptance: ChatMemoryAcceptance = .suggested,
                enabled: Bool = false, forgottenAt: Date? = nil, createdAt: Date = Date(),
                limits: ChatMemoryValidationLimits = .init()) throws {
        self.id = id; self.revision = revision; self.text = text; self.scope = scope
        self.source = source; self.acceptance = acceptance; self.enabled = enabled
        self.forgottenAt = forgottenAt; self.createdAt = createdAt
        try validate(limits: limits)
    }

    public static func manual(text: String, scope: ChatMemoryScope,
                              limits: ChatMemoryValidationLimits = .init()) throws -> Self {
        try .init(text: text, scope: scope, source: .manual, acceptance: .accepted, limits: limits)
    }

    public static func suggestion(text: String, scope: ChatMemoryScope, source: ChatContextSource,
                                  limits: ChatMemoryValidationLimits = .init()) throws -> Self {
        try .init(text: text, scope: scope, source: .chat(source), limits: limits)
    }

    public func validate(limits: ChatMemoryValidationLimits = .init()) throws {
        try limits.validate()
        guard revision > 0, !text.isEmpty, text.utf8.count <= limits.maxTextBytes,
              !(enabled && acceptance != .accepted), !(enabled && forgottenAt != nil),
              (forgottenAt == nil || forgottenAt! >= createdAt) else {
            throw WorkflowIssue("记忆正文、版本、采用状态或容量无效。")
        }
        if case .chat(let source) = source {
            try source.validate(limits: limits)
        }
    }

    public func edited(text: String, limits: ChatMemoryValidationLimits = .init()) throws -> Self {
        try changed(text: text, acceptance: acceptance, enabled: enabled, forgottenAt: forgottenAt, limits: limits)
    }

    /// Explicit review changes only the acceptance state; it does not enable injection.
    public func approved(limits: ChatMemoryValidationLimits = .init()) throws -> Self {
        guard forgottenAt == nil else { throw WorkflowIssue("已忘记的记忆不能重新采用。") }
        return try changed(text: text, acceptance: .accepted, enabled: enabled,
                           forgottenAt: nil, limits: limits)
    }

    public func settingEnabled(_ value: Bool, limits: ChatMemoryValidationLimits = .init()) throws -> Self {
        guard !value || (acceptance == .accepted && forgottenAt == nil) else {
            throw WorkflowIssue("只有未忘记且已审核采用的记忆可以启用。")
        }
        return try changed(text: text, acceptance: acceptance, enabled: value,
                           forgottenAt: forgottenAt, limits: limits)
    }

    public func forgotten(at date: Date = Date(), limits: ChatMemoryValidationLimits = .init()) throws -> Self {
        guard forgottenAt == nil else { throw WorkflowIssue("这条记忆已经忘记。") }
        return try changed(text: text, acceptance: acceptance, enabled: false,
                           forgottenAt: date, limits: limits)
    }

    private func changed(text: String, acceptance: ChatMemoryAcceptance, enabled: Bool,
                         forgottenAt: Date?, limits: ChatMemoryValidationLimits) throws -> Self {
        guard revision < UInt64.max else { throw WorkflowIssue("记忆版本已达上限。") }
        return try .init(id: id, revision: revision + 1, text: text, scope: scope,
                         source: source, acceptance: acceptance, enabled: enabled,
                         forgottenAt: forgottenAt, createdAt: createdAt, limits: limits)
    }

    /// The caller explicitly enables personal and/or one project scope for this session.
    public static func activeProjection(_ entries: [Self],
                                        enabledScopes: Set<ChatMemoryScope> = [],
                                        isTemporarySession: Bool = false) -> [Self] {
        guard !enabledScopes.isEmpty, !isTemporarySession else { return [] }
        // Old accepted revisions must not revive a later disabled or forgotten entry.
        // Conflicting values at the same latest revision fail closed for that identity.
        let newest = Dictionary(grouping: entries, by: \.id).compactMapValues { versions -> Self? in
            guard let first = versions.first,
                  versions.allSatisfy({ $0.source == first.source && $0.scope == first.scope &&
                                        $0.createdAt == first.createdAt }),
                  !versions.contains(where: { $0.forgottenAt != nil }) else { return nil }
            guard let revision = versions.map(\.revision).max() else { return nil }
            let latest = versions.filter { $0.revision == revision }
            return latest.count == 1 ? latest[0] : nil
        }
        var emitted = Set<UUID>()
        return entries.filter { entry in
            guard let current = newest[entry.id], current == entry,
                  emitted.insert(entry.id).inserted else { return false }
            return entry.acceptance == .accepted && entry.enabled && entry.forgottenAt == nil &&
                enabledScopes.contains(entry.scope)
        }
    }
}

/// Identity of an explicitly injected memory; old request replay must consult current consent.
public struct ChatMemoryUse: Codable, Sendable, Equatable {
    public let id: UUID
    public let revision: UInt64
    public let scope: ChatMemoryScope
    public init(_ entry: ChatMemoryEntry) { id = entry.id; revision = entry.revision; scope = entry.scope }
}

extension ChatContextSource {
    /// A summary covers an unchanged ancestor, not unrelated later messages.
    public func validateAncestor(of session: ChatSession, path: [ChatMessage]) throws {
        guard path.contains(where: { $0.id == selectedLeafID }) else { throw WorkflowIssue("摘要不属于当前路径，请停用或重新整理。") }
        var anchor = session; anchor.selectedLeafID = selectedLeafID
        try validate(current: anchor)
    }
}
