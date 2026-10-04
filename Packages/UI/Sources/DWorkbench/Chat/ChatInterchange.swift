import CoreFoundation
import Foundation

public enum ChatInterchangeError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

/// Value-only interchange. The caller owns file access, approval UI, and persistence.
public enum ChatInterchange {
    public static let sourceFormat = "openai-messages"
    public static let sourceVersion = 1
    public static let maximumImportBytes = 2_097_152
    public static let maximumJSONDepth = 32
    public static let maximumMessages = 1_000
    public static let maximumTextBytes = 1_048_576
    public static let maximumHTMLSourceBytes = 8_388_608

    public struct ImportedMessage: Sendable, Equatable {
        public enum Role: String, Sendable { case user, assistant }
        public let role: Role
        public let text: String
        /// Array index in the D wrapper; ordinal of sorted history keys in Open WebUI.
        public let sourceIndex: Int
    }

    public struct Loss: Sendable, Equatable {
        public let location: String
        public let reason: String
    }

    /// Parsing and previewing never changes ChatState or executes imported content.
    public struct ImportPreview: Sendable, Equatable {
        public let format: String
        public let version: Int
        public let systemPrompt: String
        public let messages: [ImportedMessage]
        public let losses: [Loss]
        /// Set for an external archive; the D wrapper has neither property.
        public let sourceTitle: String?
        public let conversationIndex: Int?

        init(format: String, version: Int, systemPrompt: String, messages: [ImportedMessage],
             losses: [Loss], sourceTitle: String? = nil, conversationIndex: Int? = nil) {
            self.format = format; self.version = version; self.systemPrompt = systemPrompt
            self.messages = messages; self.losses = losses
            self.sourceTitle = sourceTitle; self.conversationIndex = conversationIndex
        }

        /// An explicit acceptance step. The returned values still need Lead-owned storage wiring.
        public func accept(allowingLosses: Bool = false) throws -> AcceptedImport {
            guard losses.isEmpty || allowingLosses else {
                throw ChatInterchangeError.invalid("Import losses require explicit approval.")
            }
            return AcceptedImport(format: format, version: version, systemPrompt: systemPrompt,
                                  messages: messages, acknowledgedLosses: losses)
        }
    }

    /// Neutral imported-source values: no model identity, generation, or ChatAttempt is implied.
    public struct AcceptedImport: Sendable, Equatable {
        public let format: String
        public let version: Int
        public let systemPrompt: String
        public let messages: [ImportedMessage]
        public let acknowledgedLosses: [Loss]
    }

    /// Auto-preview for the exact D wrapper or a documented Open WebUI history export.
    /// An archive with multiple conversations requires an explicit selection index.
    public static func previewImport(_ data: Data, selectedConversationIndex: Int? = nil) throws -> ImportPreview {
        guard !data.isEmpty, data.count <= maximumImportBytes,
              String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw ChatInterchangeError.invalid("Import must be nonempty UTF-8 JSON of at most 2 MiB.")
        }
        try checkJSONDepth(data)
        let root = try JSONSerialization.jsonObject(with: data)
        if let object = root as? [String: Any], object.keys.contains("format") {
            guard selectedConversationIndex == nil else {
                throw ChatInterchangeError.invalid("The D import wrapper has no conversation selection index.")
            }
            return try previewOpenAIMessagesV1(data)
        }
        return try ChatOpenWebUIImport.preview(data, selectedConversationIndex: selectedConversationIndex)
    }

    /// UTF-8 HTML for one selected path. Body text is never interpreted as markup.
    public static func exportHTML(session: ChatSession, leafID: UUID) throws -> String {
        guard Set(session.messages.map(\.id)).count == session.messages.count,
              Set(session.attempts.map(\.id)).count == session.attempts.count else {
            throw ChatInterchangeError.invalid("Selected session has duplicate message or attempt IDs.")
        }
        let path = try session.path(to: leafID)
        let attempts = Dictionary(uniqueKeysWithValues: session.attempts.map { ($0.id, $0) })
        var sourceBytes = session.title.utf8.count + session.systemPrompt.utf8.count
        guard sourceBytes <= maximumHTMLSourceBytes else {
            throw ChatInterchangeError.invalid("Selected path exceeds HTML export limit.")
        }
        var html = "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">" +
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; base-uri 'none'; form-action 'none'\">" +
            "<meta name=\"referrer\" content=\"no-referrer\"><title>\(escaped(session.title))</title></head><body>" +
            "<main><h1>\(escaped(session.title))</h1>"
        if !session.systemPrompt.isEmpty {
            html += "<section><h2>System</h2><pre>\(escaped(session.systemPrompt))</pre></section>"
        }
        for message in path {
            let body: String
            if let answer = session.selectedAnswer(messageID: message.id) { body = answer.text
            } else if message.role == .assistant, message.importedSource == nil {
                guard let id = message.attemptID, let attempt = attempts[id],
                      attempt.assistantMessageID == message.id else {
                    throw ChatInterchangeError.invalid("Selected assistant message has no matching attempt.")
                }
                body = attempt.response?.finalText ?? attempt.rawText
            } else {
                body = message.text
            }
            sourceBytes += body.utf8.count
            guard sourceBytes <= maximumHTMLSourceBytes else {
                throw ChatInterchangeError.invalid("Selected path exceeds HTML export limit.")
            }
            let heading = message.role == .user ? "User" : "Assistant"
            html += "<section><h2>\(heading)</h2><pre>\(escaped(body))</pre></section>"
        }
        return html + "</main></body></html>\n"
    }

    /// Versioned wrapper around an OpenAI role/content messages array:
    /// {"format":"openai-messages","version":1,"messages":[...]}.
    /// This is not a ChatGPT account backup format.
    public static func previewOpenAIMessagesV1(_ data: Data) throws -> ImportPreview {
        guard !data.isEmpty, data.count <= maximumImportBytes else {
            throw ChatInterchangeError.invalid("Import must be nonempty and at most 2 MiB.")
        }
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw ChatInterchangeError.invalid("Import must be UTF-8 JSON.")
        }
        try checkJSONDepth(data)
        let requiredKeys: Set<String> = ["format", "version", "messages"]
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == requiredKeys,
              root["format"] as? String == sourceFormat,
              let number = root["version"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              String(cString: number.objCType) != "d",
              String(cString: number.objCType) != "f",
              number.intValue == sourceVersion,
              number.doubleValue == Double(sourceVersion),
              let rawMessages = root["messages"] as? [[String: Any]],
              !rawMessages.isEmpty, rawMessages.count <= maximumMessages else {
            throw ChatInterchangeError.invalid("Import wrapper, version, or message count is unsupported.")
        }

        var systemPrompt = ""
        var messages: [ImportedMessage] = []
        var losses: [Loss] = []
        var sawSystem = false
        var nextRole: ImportedMessage.Role = .user
        var textBytes = 0
        for (index, raw) in rawMessages.enumerated() {
            guard let role = raw["role"] as? String, raw.keys.contains("content") else {
                throw ChatInterchangeError.invalid("Message \(index) needs string role and content.")
            }
            let location = "messages[\(index)]"
            if role == "tool" {
                try appendLoss(.init(location: location, reason: "Tool result omitted; no tool is executed."),
                               to: &losses)
                continue
            }
            guard role == "system" || role == "user" || role == "assistant" else {
                throw ChatInterchangeError.invalid("Unknown role at \(location).")
            }
            let content = try textContent(raw["content"]!, at: location, losses: &losses)
            guard !content.isEmpty else {
                throw ChatInterchangeError.invalid("No representable text at \(location).")
            }
            textBytes += content.utf8.count
            guard textBytes <= maximumTextBytes else {
                throw ChatInterchangeError.invalid("Imported text exceeds 1 MiB.")
            }
            if role == "system" {
                guard !sawSystem, messages.isEmpty, index == 0 else {
                    throw ChatInterchangeError.invalid("System prompt must occur once, before dialogue.")
                }
                sawSystem = true
                systemPrompt = content
            } else {
                let mapped: ImportedMessage.Role = role == "user" ? .user : .assistant
                guard mapped == nextRole else {
                    throw ChatInterchangeError.invalid("User and assistant messages must alternate, starting with user.")
                }
                messages.append(.init(role: mapped, text: content, sourceIndex: index))
                nextRole = mapped == .user ? .assistant : .user
            }
            for key in raw.keys.sorted() where key != "role" && key != "content" {
                try appendLoss(.init(location: "\(location).\(key)", reason: "Unsupported field omitted."),
                               to: &losses)
            }
        }
        guard !messages.isEmpty else {
            throw ChatInterchangeError.invalid("Import contains no user/assistant text.")
        }
        return .init(format: sourceFormat, version: sourceVersion, systemPrompt: systemPrompt,
                     messages: messages, losses: losses)
    }

    private static func textContent(_ value: Any, at location: String, losses: inout [Loss]) throws -> String {
        if let text = value as? String { return text }
        guard let parts = value as? [Any], !parts.isEmpty, parts.count <= maximumMessages else {
            throw ChatInterchangeError.invalid("Content at \(location) must be text or a bounded parts array.")
        }
        var text = ""
        for (index, part) in parts.enumerated() {
            let partLocation = "\(location).content[\(index)]"
            guard let object = part as? [String: Any], let type = object["type"] as? String else {
                throw ChatInterchangeError.invalid("Content part at \(partLocation) needs a string type.")
            }
            if type == "text" {
                guard let fragment = object["text"] as? String else {
                    throw ChatInterchangeError.invalid("Text part at \(partLocation) needs string text.")
                }
                text += fragment
                for key in object.keys.sorted() where key != "type" && key != "text" {
                    try appendLoss(.init(location: "\(partLocation).\(key)",
                                         reason: "Unsupported text-part field omitted."), to: &losses)
                }
            } else {
                try appendLoss(.init(location: partLocation, reason: "Unsupported \(type) part omitted."),
                               to: &losses)
            }
        }
        return text
    }

    private static func appendLoss(_ loss: Loss, to losses: inout [Loss]) throws {
        guard losses.count < 4_096 else {
            throw ChatInterchangeError.invalid("Import has too many unsupported fields or parts.")
        }
        losses.append(loss)
    }

    static func checkJSONDepth(_ data: Data) throws {
        try rejectDuplicateMembers(data)
        var depth = 0
        var quoted = false
        var escapedCharacter = false
        for byte in data {
            if quoted {
                if escapedCharacter { escapedCharacter = false }
                else if byte == 0x5C { escapedCharacter = true }
                else if byte == 0x22 { quoted = false }
            } else if byte == 0x22 {
                quoted = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                guard depth <= maximumJSONDepth else {
                    throw ChatInterchangeError.invalid("JSON nesting exceeds \(maximumJSONDepth).")
                }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
            }
        }
    }

    /// Foundation collapses duplicate members when decoding dictionaries. Check decoded
    /// keys before that conversion; Foundation remains responsible for JSON grammar.
    private static func rejectDuplicateMembers(_ data: Data) throws {
        let bytes = Array(data)
        var containers: [Set<String>?] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x7B, 0x5B:
                containers.append(bytes[index] == 0x7B ? Set<String>() : nil)
                guard containers.count <= maximumJSONDepth else {
                    throw ChatInterchangeError.invalid("JSON nesting exceeds \(maximumJSONDepth).")
                }
            case 0x7D, 0x5D:
                if !containers.isEmpty { containers.removeLast() }
            case 0x22:
                let start = index
                index += 1
                var escaped = false
                while index < bytes.count {
                    if escaped { escaped = false }
                    else if bytes[index] == 0x5C { escaped = true }
                    else if bytes[index] == 0x22 { break }
                    index += 1
                }
                guard index < bytes.count else { throw ChatInterchangeError.invalid("Unterminated JSON string.") }
                var after = index + 1
                while after < bytes.count && [UInt8(9), 10, 13, 32].contains(bytes[after]) { after += 1 }
                if after < bytes.count, bytes[after] == 0x3A, !containers.isEmpty,
                   containers[containers.count - 1] != nil {
                    let key = try JSONSerialization.jsonObject(with: Data(bytes[start...index]), options: [.fragmentsAllowed]) as? String
                    guard let key, containers[containers.count - 1]?.insert(key).inserted == true else {
                        throw ChatInterchangeError.invalid("Duplicate JSON object member.")
                    }
                }
            default: break
            }
            index += 1
        }
    }

    private static func escaped(_ source: String) -> String {
        source.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
