import DInference
import Foundation

/// An inspection of the frozen attempt, independent of current controller state.
public struct ChatRequestInspection: Sendable {
    public struct Field: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let value: String
    }
    public struct Section: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let fields: [Field]
    }

    public let sections: [Section]
    public let redactedJSON: String

    public init(attempt: ChatAttempt) {
        let node = attempt.node
        func field(_ id: String, _ label: String, _ value: String) -> Field {
            .init(id: id, label: label, value: value)
        }
        let sources: [Field] = [
            field("attempt", "Attempt", attempt.id.uuidString),
            field("session", "Session", attempt.sessionID.uuidString),
            field("user", "User message", attempt.userMessageID.uuidString),
            field("assistant", "Assistant message", attempt.assistantMessageID.uuidString),
            field("replay", "Replayed attempt", attempt.replayedAttemptID?.uuidString ?? "—"),
            field("comparison", "Comparison input source", attempt.comparisonSourceAttemptID?.uuidString ?? "—"),
            field("status", "Status", attempt.status.rawValue),
            field("operation", "Operation", Self.safeIdentifier(node.operationID)),
            field("version", "Definition version", String(node.definitionVersion))
        ]
        let parameterFields = node.parameters.keys.sorted().filter {
            !["seed", "messagesJSON", "toolsJSON", "chatTemplateOverride"].contains($0)
        }.compactMap { key -> Field? in
            guard let value = node.parameters[key] else { return nil }
            return field(key, Self.safeIdentifier(key), Self.isSensitiveVisibleIdentifier(key) ? "[redacted]" : Self.localText(Self.localValue(value)))
        }
        var inputFields: [Field] = [
            field("system", "System rules (frozen)", Self.localText(attempt.systemPrompt)),
            field("format", "Requested response format (advisory, validated after generation)", attempt.outputFormat?.kind.rawValue ?? "automatic"),
            field("messages", "Stored ordered message source",
                  attempt.messagesJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No ordered message snapshot recorded" : "See ordered messages below; raw JSON withheld"),
            field("displayLimit", "Local display protection",
                  "Recognized credential assignments and token patterns are redacted locally; arbitrary secrets may still be visible. Use the redacted export for sharing")
        ]
        let media = Self.mediaReferences(attempt.inputs)
        for key in attempt.inputs.keys.sorted() {
            guard let value = attempt.inputs[key] else { continue }
            let refs = value.datum?.assetReferences ?? []
            inputFields.append(field("input.\(key)", Self.safeIdentifier(key),
                                     refs.isEmpty ? "[structured input]" : refs.map {
                "\($0.kind.rawValue) \($0.assetID.uuidString) v\($0.version.uuidString) sha256:\(Self.localText($0.sha256))"
            }.joined(separator: "\n")))
        }
        let messageFields = Self.messageFields(attempt.messagesJSON, media: media)
        self.sections = [
            .init(id: "source", title: "Source and identity", fields: sources),
            .init(id: "input", title: "System rules and output format", fields: inputFields),
            .init(id: "messages", title: "Ordered messages", fields: messageFields),
            .init(id: "memory", title: "Frozen memory and summary sources", fields: Self.memoryFields(attempt.memoryUses)),
            .init(id: "media", title: "Media processing", fields: Self.mediaFields(node: node, media: media)),
            .init(id: "tools", title: "Tool declarations", fields: Self.toolFields(node.parameters["toolsJSON"]?.string ?? "")),
            .init(id: "template", title: "Model chat template", fields: [field("selection", "Selection",
                (node.parameters["chatTemplateOverride"]?.string ?? "").isEmpty
                    ? "Model default; expanded historical template not recorded"
                    : "Frozen custom override; expanded rendering not recorded")]),
            .init(id: "parameters", title: "Model parameters", fields: parameterFields),
            .init(id: "seed", title: "Seed", fields: [field("seed", "Frozen seed",
                node.parameters["seed"].map { Self.localText(Self.localValue($0)) } ?? "[not specified]")]),
            .init(id: "response", title: "Response and usage", fields: Self.responseFields(attempt: attempt, media: media,
                messagesDecoded: messageFields.first?.value.hasPrefix("Decoded ") == true))
        ]

        struct SafeAsset: Encodable {
            let kind: String
            let sha256: String
            let version: UUID
        }
        struct SafeReport: Encodable {
            let attemptID: UUID
            let sessionID: UUID
            let userMessageID: UUID
            let assistantMessageID: UUID
            let replayedAttemptID: UUID?
            let comparisonSourceAttemptID: UUID?
            let operationID: String
            let definitionVersion: Int
            let parameters: [String: String]
            let assets: [SafeAsset]
            let systemPrompt: String
            let messagesJSON: String
        }
        var safeParameters: [String: String] = [:]
        let knownOperation = [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38].contains(node.operationID)
        let definition = knownOperation ? WorkflowLanguageOperations.operations.first(where: { $0.definition.id == node.operationID })?.definition : nil
        for (key, value) in node.parameters {
            if let safe = Self.exportValue(value, key: key, fields: definition?.fields ?? []) { safeParameters[key] = safe }
        }
        let safeAssets = attempt.inputs.keys.sorted().flatMap { key -> [SafeAsset] in
            (attempt.inputs[key]?.datum?.assetReferences ?? []).compactMap { ref in
                guard ref.sha256.count == 64,
                      ref.sha256.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) })
                else { return nil }
                return .init(kind: ref.kind.rawValue, sha256: ref.sha256, version: ref.version)
            }
        }
        let report = SafeReport(attemptID: attempt.id, sessionID: attempt.sessionID,
                                userMessageID: attempt.userMessageID, assistantMessageID: attempt.assistantMessageID,
                                replayedAttemptID: attempt.replayedAttemptID,
                                comparisonSourceAttemptID: attempt.comparisonSourceAttemptID,
                                operationID: knownOperation ? node.operationID : "[withheld]",
                                definitionVersion: node.definitionVersion, parameters: safeParameters,
                                assets: safeAssets, systemPrompt: "[withheld]", messagesJSON: "[withheld]")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        self.redactedJSON = (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func mediaReferences(_ inputs: [String: WorkflowValue]) -> [String: [WorkflowAssetReference]] {
        ["image": inputs["images"]?.datum?.assetReferences ?? [],
         "video": inputs["video"]?.datum?.assetReferences ?? []]
    }

    private static func messageFields(_ json: String, media: [String: [WorkflowAssetReference]]) -> [Field] {
        func field(_ id: String, _ label: String, _ value: String) -> Field { .init(id: id, label: label, value: value) }
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [field("parse", "Parse status", "No ordered message snapshot recorded"),
                    field("raw", "Stored source", "[empty]")]
        }
        do {
            // The production form checks unknown keys, part shape, and that every
            // admitted media reference is used. These URLs are inert placeholders;
            // parsing does not open a file or infer any historical media metadata.
            let images = (media["image"] ?? []).indices.map { index in
                TextImageReference(url: URL(fileURLWithPath: "/inspection/image/\(index).png"),
                                   width: 1, height: 1, byteCount: 1,
                                   contentSHA256: String(repeating: "0", count: 64))
            }
            let videos = (media["video"] ?? []).indices.map { index in
                TextVideoReference(url: URL(fileURLWithPath: "/inspection/video/\(index).mp4"),
                                   byteCount: 1, contentSHA256: String(repeating: "0", count: 64),
                                   durationSeconds: 1)
            }
            guard let messages = try WorkflowLanguageMessageForm.messages(json, images: images, videos: videos) else {
                throw InspectionParseError.missingSnapshot
            }
            var result = [field("parse", "Parse status", "Decoded \(messages.count) stored messages")]
            for (index, message) in messages.enumerated() {
                var lines: [String] = []
                for (partIndex, part) in message.parts.enumerated() {
                    switch part {
                    case .text(let text):
                        lines.append("Part \(partIndex + 1) · text: \(localText(text))")
                    case .image(let image):
                        guard let mediaIndex = images.firstIndex(of: image),
                              let ref = media["image"]?[mediaIndex] else { throw InspectionParseError.invalidPart }
                        lines.append("Part \(partIndex + 1) · image [\(mediaIndex)] · asset \(ref.assetID.uuidString) v\(ref.version.uuidString)")
                    case .video(let video):
                        guard let mediaIndex = videos.firstIndex(of: video),
                              let ref = media["video"]?[mediaIndex] else { throw InspectionParseError.invalidPart }
                        lines.append("Part \(partIndex + 1) · video [\(mediaIndex)] · asset \(ref.assetID.uuidString) v\(ref.version.uuidString)")
                    }
                }
                if message.reasoningContent != nil { lines.append("Stored reasoning content: \(localText(message.reasoningContent!))") }
                if let callID = message.toolCallID { lines.append("Tool result for call: \(safeIdentifier(callID))") }
                for (callIndex, call) in (message.toolCalls ?? []).enumerated() {
                    lines.append("Tool call \(callIndex + 1): \(safeIdentifier(call.name)); arguments withheld (\(call.arguments.count) fields); execution not recorded here")
                }
                result.append(field("message.\(index)", "\(index + 1). \(message.role.rawValue)", lines.joined(separator: "\n")))
            }
            return result
        } catch {
            return [field("parse", "Parse status", "Stored message source could not be decoded; no messages inferred"),
                    field("raw", "Stored source", "[withheld: invalid stored message JSON]")]
        }
    }

    private enum InspectionParseError: Error { case invalidPart, missingSnapshot }

    private static func memoryFields(_ uses: [ChatMemoryUse]?) -> [Field] {
        var fields: [Field] = [
            .init(id: "summary", label: "Summary identity/revision", value: "Not recorded in this attempt; any summary text is part of the frozen messages")
        ]
        guard let uses, !uses.isEmpty else {
            fields.append(.init(id: "uses", label: "Memory uses", value: "None recorded"))
            return fields
        }
        fields += uses.enumerated().map { index, use in
            .init(id: "use.\(index)", label: "Memory use \(index + 1)",
                  value: "\(memoryScope(use.scope)) · \(use.id.uuidString) · revision \(use.revision)")
        }
        return fields
    }

    private static func memoryScope(_ scope: ChatMemoryScope) -> String {
        switch scope {
        case .personal: "personal"
        case .project(let id): "project \(id.uuidString)"
        }
    }

    private static func mediaFields(node: WorkflowNode, media: [String: [WorkflowAssetReference]]) -> [Field] {
        var fields: [Field] = []
        for kind in ["image", "video"] {
            let refs = media[kind] ?? []
            fields.append(.init(id: kind, label: "\(kind.capitalized) inputs", value: "\(refs.count) frozen asset reference(s)"))
        }
        for key in ["minimumPixels", "maximumPixels", "maximumVideoFrames"] {
            fields.append(.init(id: key, label: key, value: node.parameters[key].map { localText(localValue($0)) } ?? "Not recorded"))
        }
        fields.append(.init(id: "processing", label: "Actual decoded pixels/frames", value: "Not recorded in this attempt"))
        return fields
    }

    private static func toolFields(_ json: String) -> [Field] {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [.init(id: "status", label: "Stored declarations", value: "None recorded")]
        }
        do {
            let tools = try WorkflowLanguageMessageForm.tools(json) ?? []
            return [.init(id: "status", label: "Stored declarations", value: "\(tools.count) typed declaration(s); declaration does not prove execution")]
                + tools.enumerated().map { index, tool in
                    .init(id: "tool.\(index)", label: "Tool \(index + 1)", value: safeIdentifier(tool.name))
                }
        } catch {
            return [.init(id: "status", label: "Parse status", value: "Stored tool declarations could not be decoded"),
                    .init(id: "raw", label: "Stored source", value: "[withheld: invalid stored tool JSON]")]
        }
    }

    private static func responseFields(attempt: ChatAttempt, media: [String: [WorkflowAssetReference]], messagesDecoded: Bool) -> [Field] {
        var fields: [Field] = [
            .init(id: "actualTokens", label: "Actual token usage", value: "Not recorded in this attempt")
        ]
        if messagesDecoded {
            let images = media["image"]?.count ?? 0, videos = media["video"]?.count ?? 0
            let estimate = (attempt.messagesJSON.utf8.count + 2) / 3 + images * 1024 + videos * 4096
            fields.append(.init(id: "estimatedTokens", label: "Conservative input budget estimate (not tokenizer usage)", value: "Approximately \(estimate) tokens; frozen message byte count and media allowances"))
        } else {
            fields.append(.init(id: "estimatedTokens", label: "Input budget estimate", value: "Unavailable: no valid stored message snapshot"))
        }
        fields.append(.init(id: "finish", label: "Finish reason", value: attempt.response?.finishReason.rawValue ?? "Not recorded"))
        fields.append(.init(id: "responseToolCalls", label: "Response tool calls", value: attempt.response.map { "\($0.toolCalls.count) typed call(s); execution not recorded here" } ?? "Not recorded"))
        return fields
    }

    private static func safeIdentifier(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 80,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0) }),
              !isSensitiveVisibleIdentifier(value) else { return "[withheld]" }
        return value
    }

    private static func localText(_ value: String) -> String {
        // Inspect the decoded text: JSON escapes must not bypass field redaction.
        let assignments = #"(?i)(?<![A-Za-z0-9_])((?:['"]?(?:api[_-]?(?:key|token)|access[_-]?(?:key|token)|refresh[_-]?token|auth[_-]?token|private[_-]?key|client[_-]?secret|authorization|password|secret|credential|bearer)['"]?)[ \t]*[:=][ \t\r\n]*)("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\n,;}]+)"#
        let bearer = #"(?i)(?<![A-Za-z0-9_])(bearer[ \t\r\n]+)([A-Za-z0-9._~+/-]+)"#
        return redactMatches(redactMatches(redactMatches(value, pattern: assignments, group: 2),
                                          pattern: bearer, group: 2),
                             pattern: concreteTokenPattern, group: 0)
    }

    private static func isSensitiveVisibleIdentifier(_ value: String) -> Bool {
        if value == "maximumPromptTokens" || value == "maximumOutputTokens" { return false }
        return isCredentialKey(value) || containsMatch(value, pattern: concreteTokenPattern)
    }

    private static let concreteTokenPattern = #"(?i)(?<![A-Za-z0-9_])(?:sk-|ghp_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]+"#

    private static func containsMatch(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func redactMatches(_ value: String, pattern: String, group: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(match.range(at: group), in: result) else { continue }
            result.replaceSubrange(range, with: "[redacted]")
        }
        return result
    }

    private static func localValue(_ value: WorkflowScalar) -> String {
        switch value {
        case .text(let text): text
        case .integer(let number): String(number)
        case .decimal(let number): String(number)
        case .flag(let flag): String(flag)
        }
    }

    private static func isCredentialKey(_ key: String) -> Bool {
        if key == "maximumPromptTokens" || key == "maximumOutputTokens" { return false }
        let lower = key.lowercased()
        if ["bookmark", "credential", "password", "secret", "token", "key", "authorization", "header",
            "apikey", "api_key", "accesskey", "access_token", "accesstoken"].contains(lower) { return true }
        if ["Password", "Secret", "Credential", "Token", "Key", "Authorization", "Header"].contains(where: key.hasSuffix) {
            return true
        }
        return key.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." }).contains {
            ["password", "secret", "credential", "token", "key", "authorization", "header"].contains($0.lowercased())
        }
    }

    private static func exportValue(_ value: WorkflowScalar, key: String,
                                    fields: [WorkflowFieldDefinition]) -> String? {
        // Export only declared, bounded request settings. Free text and identifiers stay local.
        let safeKeys: Set<String> = ["maximumPromptTokens", "maximumOutputTokens", "temperature", "topP",
                                     "outputMode", "memoryBudgetGiB", "loadingStrategy", "thinking",
                                     "reasoningEffort", "preserveThinking", "minimumPixels", "maximumPixels",
                                     "maximumVideoFrames"]
        guard !isCredentialKey(key) else { return nil }
        if key == "seed", case .text(let text) = value,
           let parsed = UInt64(text), String(parsed) == text { return text }
        guard safeKeys.contains(key), let field = fields.first(where: { $0.id == key }) else { return nil }
        switch (field.kind, value) {
        case (.integer, .integer(let number)): return String(number)
        case (.decimal, .decimal(let number)) where number.isFinite: return String(number)
        case (.flag, .flag(let flag)): return String(flag)
        case (.choice(let choices), .text(let text)) where choices.contains(text): return text
        default: return nil
        }
    }
}
