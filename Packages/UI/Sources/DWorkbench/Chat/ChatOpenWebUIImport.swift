import CoreFoundation
import Foundation

/// Inert mapping of the documented, unversioned Open WebUI history export.
/// Source: https://docs.openwebui.com/features/chat-conversations/data-controls/import-export/
/// `formatVersion` describes D's mapping contract, not an upstream schemaVersion.
public enum ChatOpenWebUIImport {
    public static let format = "open-webui-history"
    public static let formatVersion = 1
    public static let maximumConversations = 128

    public struct ConversationChoice: Sendable, Equatable {
        public let index: Int
        public let title: String
    }

    private struct Entry {
        let outer: [String: Any]?
        let chat: [String: Any]
        let history: [String: Any]
        let title: String
    }

    private struct Node {
        let id: String
        let parent: String?
        let children: [String]
        let role: String
        let content: String
        let sourceIndex: Int
    }

    /// Indices refer to the original array order. A lone object has index zero.
    public static func conversations(in data: Data) throws -> [ConversationChoice] {
        try archive(data).enumerated().map { .init(index: $0.offset, title: $0.element.title) }
    }

    /// Validates the entire selected tree, then maps only currentId's parent path.
    public static func preview(_ data: Data, selectedConversationIndex: Int? = nil) throws -> ChatInterchange.ImportPreview {
        let entries = try archive(data)
        guard entries.count == 1 || selectedConversationIndex != nil else {
            throw invalid("Choose a conversation index from this \(entries.count)-conversation archive.")
        }
        let index = selectedConversationIndex ?? 0
        guard entries.indices.contains(index) else { throw invalid("Conversation index is out of range.") }
        let entry = entries[index]
        guard let rawMessages = entry.history["messages"] as? [String: Any],
              !rawMessages.isEmpty, rawMessages.count <= ChatInterchange.maximumMessages,
              let currentID = entry.history["currentId"] as? String, !currentID.isEmpty else {
            throw invalid("Selected conversation needs a bounded history.messages map and currentId.")
        }

        // Swift's String order is deterministic; ordinals of sorted map keys are sourceIndex.
        // This does not depend on JSON dictionary iteration order or on the active path.
        let sortedIDs = rawMessages.keys.sorted()
        var nodes: [String: Node] = [:]
        var losses: [ChatInterchange.Loss] = []
        for (ordinal, key) in sortedIDs.enumerated() {
            let location = "chat.history.messages[\(ordinal)]"
            guard let raw = rawMessages[key] as? [String: Any],
                  let id = raw["id"] as? String, id == key, !id.isEmpty,
                  raw.keys.contains("parentId"),
                  let childValues = raw["childrenIds"] as? [Any],
                  childValues.count <= ChatInterchange.maximumMessages,
                  let role = raw["role"] as? String,
                  ["user", "assistant", "system", "tool"].contains(role),
                  let content = raw["content"] as? String else {
                throw invalid("\(location) needs matching id, parentId, childrenIds, supported role, and text content.")
            }
            let parent: String?
            if raw["parentId"] is NSNull { parent = nil }
            else if let value = raw["parentId"] as? String, !value.isEmpty { parent = value }
            else { throw invalid("\(location).parentId must be null or a nonempty ID.") }
            var children: [String] = []
            var uniqueChildren: Set<String> = []
            for value in childValues {
                guard let child = value as? String, !child.isEmpty, uniqueChildren.insert(child).inserted else {
                    throw invalid("\(location).childrenIds contains a duplicate or invalid ID.")
                }
                children.append(child)
            }
            if role == "user" || role == "assistant" {
                guard !content.isEmpty else { throw invalid("\(location) has no representable text.") }
            } else {
                try addLoss(location, "\(role) message omitted; it is not authorized as a system prompt or executed as a tool.", to: &losses)
            }
            if let done = raw["done"] {
                guard let number = done as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw invalid("\(location).done must be a Boolean.")
                }
                guard number.boolValue else {
                    throw invalid("\(location) is unfinished (done: false); finish or remove it before import.")
                }
                try addLoss("\(location).done", "Completion flag omitted; no execution is inferred.", to: &losses)
            }
            for field in raw.keys.sorted() where !["id", "parentId", "childrenIds", "role", "content", "done"].contains(field) {
                let reason: String
                switch field {
                case "model": reason = "Model identity omitted; no model is selected."
                case "tool_calls", "tool", "tools": reason = "Tool data omitted; no tool is executed."
                case "files", "images", "attachments": reason = "Attachment omitted; no file or URI is read."
                default: reason = "Unsupported message field omitted."
                }
                try addLoss("\(location).\(field)", reason, to: &losses)
            }
            nodes[key] = .init(id: id, parent: parent, children: children, role: role,
                               content: content, sourceIndex: ordinal)
        }
        guard nodes[currentID] != nil else { throw invalid("currentId does not identify a history message.") }

        let roots = nodes.values.filter { $0.parent == nil }
        guard roots.count == 1 else { throw invalid("History must have exactly one root message.") }
        for node in nodes.values {
            if let parent = node.parent {
                guard let ancestor = nodes[parent], ancestor.children.contains(node.id) else {
                    throw invalid("History has a missing parent or a nonreciprocal child link.")
                }
            }
            for child in node.children {
                guard let descendant = nodes[child], descendant.parent == node.id else {
                    throw invalid("History has a foreign child or a nonreciprocal parent link.")
                }
            }
        }
        var visited: Set<String> = []
        var pending: [(String, ChatInterchange.ImportedMessage.Role)] = [(roots[0].id, .user)]
        while let (id, expectedRole) = pending.popLast() {
            guard visited.insert(id).inserted else { throw invalid("History contains a cycle or repeated child.") }
            let node = nodes[id]!
            var next = expectedRole
            if node.role == "user" || node.role == "assistant" {
                let actual: ChatInterchange.ImportedMessage.Role = node.role == "user" ? .user : .assistant
                guard actual == expectedRole else {
                    throw invalid("Every history branch must alternate user and assistant, starting with user.")
                }
                next = actual == .user ? .assistant : .user
            }
            pending.append(contentsOf: node.children.map { ($0, next) })
        }
        guard visited.count == nodes.count else { throw invalid("History contains a cycle or disconnected messages.") }

        var path: [Node] = []
        var cursor: String? = currentID
        var pathIDs: Set<String> = []
        while let id = cursor {
            guard pathIDs.insert(id).inserted, let node = nodes[id] else {
                throw invalid("currentId parent path contains a cycle or missing message.")
            }
            path.append(node)
            cursor = node.parent
        }
        path.reverse()
        var mapped: [ChatInterchange.ImportedMessage] = []
        var nextRole: ChatInterchange.ImportedMessage.Role = .user
        var textBytes = 0
        for node in path {
            let location = "chat.history.messages[\(node.sourceIndex)]"
            if node.role == "system" || node.role == "tool" {
                continue
            }
            let role: ChatInterchange.ImportedMessage.Role = node.role == "user" ? .user : .assistant
            guard role == nextRole else {
                throw invalid("Active path must alternate user and assistant, starting with user.")
            }
            textBytes += node.content.utf8.count
            guard textBytes <= ChatInterchange.maximumTextBytes else { throw invalid("Mapped text exceeds 1 MiB.") }
            mapped.append(.init(role: role, text: node.content, sourceIndex: node.sourceIndex))
            nextRole = role == .user ? .assistant : .user
        }
        guard !mapped.isEmpty else { throw invalid("Active path contains no representable user/assistant text.") }
        if nodes.count != path.count {
            try addLoss("chat.history.messages", "\(nodes.count - path.count) alternate-branch message(s) omitted; only the currentId path is imported.", to: &losses)
        }
        if let outer = entry.outer {
            for field in outer.keys.sorted() where field != "chat" {
                try addLoss(field, "Archive entry field omitted.", to: &losses)
            }
        }
        for field in entry.chat.keys.sorted() where field != "title" && field != "history" {
            try addLoss("chat.\(field)", "Chat setting or metadata omitted; no model or permission is selected.", to: &losses)
        }
        for field in entry.history.keys.sorted() where field != "currentId" && field != "messages" {
            try addLoss("chat.history.\(field)", "History field omitted.", to: &losses)
        }
        return .init(format: format, version: formatVersion, systemPrompt: "", messages: mapped,
                     losses: losses, sourceTitle: entry.title, conversationIndex: index)
    }

    private static func archive(_ data: Data) throws -> [Entry] {
        guard !data.isEmpty, data.count <= ChatInterchange.maximumImportBytes,
              String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw invalid("Import must be nonempty UTF-8 JSON of at most 2 MiB.")
        }
        try ChatInterchange.checkJSONDepth(data)
        let root = try JSONSerialization.jsonObject(with: data)
        let rawEntries: [Any]
        if let array = root as? [Any] { rawEntries = array }
        else if let object = root as? [String: Any] { rawEntries = [object] }
        else { throw invalid("Expected a standard or legacy Open WebUI conversation object or array.") }
        guard !rawEntries.isEmpty, rawEntries.count <= maximumConversations else {
            throw invalid("Archive must contain 1...\(maximumConversations) conversations.")
        }
        return try rawEntries.enumerated().map { index, value in
            guard let object = value as? [String: Any] else { throw invalid("Conversation \(index) is not an object.") }
            let outer: [String: Any]?
            let chat: [String: Any]
            if object.keys.contains("chat") {
                guard let body = object["chat"] as? [String: Any] else {
                    throw invalid("Conversation \(index).chat is not an object.")
                }
                outer = object; chat = body
            } else { outer = nil; chat = object }
            guard let title = chat["title"] as? String,
                  let history = chat["history"] as? [String: Any],
                  let currentID = history["currentId"] as? String, !currentID.isEmpty,
                  let messages = history["messages"] as? [String: Any], !messages.isEmpty else {
                throw invalid("Conversation \(index) needs title and history.currentId/messages.")
            }
            guard messages.count <= ChatInterchange.maximumMessages else {
                throw invalid("Conversation \(index) has too many history messages (limit 1,000).")
            }
            return .init(outer: outer, chat: chat, history: history, title: title)
        }
    }

    private static func addLoss(_ location: String, _ reason: String,
                                to losses: inout [ChatInterchange.Loss]) throws {
        guard losses.count < 4_096 else { throw invalid("Import has too many unsupported fields or parts.") }
        losses.append(.init(location: location, reason: reason))
    }

    private static func invalid(_ reason: String) -> ChatInterchangeError { .invalid(reason) }
}
