import Foundation

public struct ChatSearchHit: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case title, message, attachment }
    public enum TextVersion: String, Sendable, Equatable { case original, selected }
    public let sessionID: UUID
    public let messageID: UUID?
    public let sourceText: String
    public let range: NSRange
    public let kind: Kind
    public var textVersion: TextVersion? = nil
    public var revisionID: UUID? = nil
    public var attemptID: UUID? = nil
}

/// Lexical matching over stored, visible conversation records in their stored order.
public enum ChatHistorySearch {
    public static func matches(in sessions: [ChatSession], query: String,
                               maximumHits: Int = 200) -> [ChatSearchHit] {
        guard maximumHits > 0, !query.isEmpty else { return [] }
        var hits: [ChatSearchHit] = []
        func collect(_ source: String, sessionID: UUID, messageID: UUID?, kind: ChatSearchHit.Kind,
                     version: ChatSearchHit.TextVersion? = nil, revisionID: UUID? = nil, attemptID: UUID? = nil) {
            guard !source.isEmpty, hits.count < maximumHits else { return }
            var cursor = source.startIndex
            while cursor < source.endIndex, hits.count < maximumHits,
                  let found = source.range(of: query, options: [.caseInsensitive],
                                           range: cursor..<source.endIndex) {
                // Foundation's lexical search can return a piece of a composed character.
                // Only complete Character boundaries are safe for a jump/highlight range.
                if !found.isEmpty && source.indices.contains(found.lowerBound) &&
                   (found.upperBound == source.endIndex || source.indices.contains(found.upperBound)) {
                    hits.append(.init(sessionID: sessionID, messageID: messageID,
                                      sourceText: source, range: NSRange(found, in: source), kind: kind,
                                      textVersion: version, revisionID: revisionID, attemptID: attemptID))
                    cursor = found.upperBound
                } else if let next = source.indices.first(where: { $0 > found.lowerBound }) {
                    cursor = next
                } else { break }
            }
        }
        for session in sessions {
            if hits.count >= maximumHits { break }
            collect(session.title, sessionID: session.id, messageID: nil, kind: .title)
            let attempts = Dictionary(session.attempts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let adopted = session.contextChoices?.adopted ?? [:]
            for message in session.messages {
                if hits.count >= maximumHits { break }
                var indexed = Set<String>()
                func messageText(_ text: String, version: ChatSearchHit.TextVersion?) {
                    guard indexed.insert(text).inserted else { return }
                    let revisionID = version == .selected ? session.contextChoices?.revisions.first {
                        $0.messageID == message.id && session.contextChoices?.adoptedRevisionIDs.contains($0.id) == true
                    }?.id : nil
                    collect(text, sessionID: session.id, messageID: message.id, kind: .message,
                            version: version, revisionID: revisionID, attemptID: message.attemptID)
                }
                if let selected = adopted[message.id] { messageText(selected, version: .selected) }
                messageText(message.text, version: message.role == .assistant ? .original : nil)
                if message.role == .assistant, let id = message.attemptID, let attempt = attempts[id] {
                    let body = attempt.response?.finalText.flatMap { $0.isEmpty ? nil : $0 } ?? attempt.rawText
                    messageText(body, version: .original)
                }
                for attachment in message.attachments {
                    if hits.count >= maximumHits { break }
                    collect(attachment.name, sessionID: session.id, messageID: message.id, kind: .attachment)
                    if let snapshot = attachment.textSnapshot, snapshot != attachment.name {
                        collect(snapshot, sessionID: session.id, messageID: message.id, kind: .attachment)
                    }
                }
            }
        }
        return hits
    }

    public static func isCurrent(_ hit: ChatSearchHit, in session: ChatSession) -> Bool {
        guard hit.sessionID == session.id, session.contextChoices?.deletedAt == nil else { return false }
        guard let id = hit.messageID else { return session.title == hit.sourceText }
        guard let message = session.messages.first(where: { $0.id == id }), message.attemptID == hit.attemptID || hit.textVersion == nil else { return false }
        if let revisionID = hit.revisionID {
            return session.contextChoices?.adoptedRevisionIDs.contains(revisionID) == true &&
                session.contextChoices?.revisions.contains { $0.id == revisionID && $0.messageID == id && $0.text == hit.sourceText } == true
        }
        if hit.kind == .attachment { return message.attachments.contains { $0.name == hit.sourceText || $0.textSnapshot == hit.sourceText } }
        if message.text == hit.sourceText { return true }
        guard let attempt = session.attempts.first(where: { $0.id == hit.attemptID }) else { return false }
        return (attempt.response?.finalText.flatMap { $0.isEmpty ? nil : $0 } ?? attempt.rawText) == hit.sourceText
    }
}
