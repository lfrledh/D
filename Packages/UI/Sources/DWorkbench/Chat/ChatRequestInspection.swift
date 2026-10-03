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
            field("operation", "Operation", node.operationID),
            field("version", "Definition version", String(node.definitionVersion))
        ]
        let parameterFields = node.parameters.keys.sorted().filter { $0 != "seed" }.compactMap { key -> Field? in
            guard let value = node.parameters[key] else { return nil }
            return field(key, key, Self.isCredentialKey(key) ? "[redacted]" : Self.localValue(value))
        }
        var inputFields: [Field] = [
            field("system", "System prompt", attempt.systemPrompt),
            field("messages", "Encoded messages", attempt.messagesJSON)
        ]
        for key in attempt.inputs.keys.sorted() {
            guard let value = attempt.inputs[key] else { continue }
            let refs = value.datum?.assetReferences ?? []
            inputFields.append(field("input.\(key)", key,
                                     refs.isEmpty ? "[structured input]" : refs.map {
                "\($0.kind.rawValue) \($0.assetID.uuidString) v\($0.version.uuidString) sha256:\($0.sha256)"
            }.joined(separator: "\n")))
        }
        self.sections = [
            .init(id: "source", title: "Source and identity", fields: sources),
            .init(id: "input", title: "Frozen input", fields: inputFields),
            .init(id: "parameters", title: "Model parameters", fields: parameterFields),
            .init(id: "seed", title: "Seed", fields: [field("seed", "Frozen seed",
                node.parameters["seed"].map(Self.localValue) ?? "[not specified]")])
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
        return ["bookmark", "credential", "password", "secret", "token", "authorization", "header", "apikey", "api_key"]
            .contains(where: { lower.contains($0) })
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
