import Foundation

public struct ChatSearchHit: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case title, message, attachment }
    public let sessionID: UUID
    public let messageID: UUID?
    public let sourceText: String
    public let range: NSRange
    public let kind: Kind
}

/// Lexical matching over stored, visible conversation records in their stored order.
public enum ChatHistorySearch {
    public static func matches(in sessions: [ChatSession], query: String,
                               maximumHits: Int = 200) -> [ChatSearchHit] {
        guard maximumHits > 0, !query.isEmpty else { return [] }
        var hits: [ChatSearchHit] = []
        func collect(_ source: String, sessionID: UUID, messageID: UUID?, kind: ChatSearchHit.Kind) {
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
                                      sourceText: source, range: NSRange(found, in: source), kind: kind))
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
            for message in session.messages {
                if hits.count >= maximumHits { break }
                collect(message.text, sessionID: session.id, messageID: message.id, kind: .message)
                if message.role == .assistant, let id = message.attemptID, let attempt = attempts[id] {
                    let body = attempt.response?.finalText.flatMap { $0.isEmpty ? nil : $0 } ?? attempt.rawText
                    if body != message.text {
                        collect(body, sessionID: session.id, messageID: message.id, kind: .message)
                    }
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
}
