import Foundation

/// A requested presentation format for one chat answer. Instructions are advisory;
/// validation happens after generation and does not constrain decoding.
public struct ChatOutputFormat: Codable, Sendable, Equatable {
    fileprivate static let maximumSchemaDeclarationBytes = 65_536
    private static let schemaInstructionPrefix = "Respond with one complete JSON value matching this D WorkflowDataSchema "
        + "declaration (Codable data, not arbitrary JSON Schema): "
    private static let schemaInstructionSuffix = ". Include required fields, omit or include optional fields as declared, "
        + "and add no unknown fields or Markdown fences."
    private static let maximumSchemaInstructionBytes = maximumSchemaDeclarationBytes
        + schemaInstructionPrefix.utf8.count + schemaInstructionSuffix.utf8.count

    public enum Kind: String, Codable, Sendable {
        case automatic
        case plainText
        case markdown
        case json
        case schema
    }

    public struct ValidationError: Error, LocalizedError, Equatable, Sendable {
        public let reason: String

        public var errorDescription: String? { reason }

        public init(_ reason: String) { self.reason = reason }
    }

    public struct Report: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case notChecked
            case valid
            case invalid
        }

        public let status: Status
        public let reason: String?
        public let datum: WorkflowDatum?

        public init(status: Status, reason: String? = nil, datum: WorkflowDatum? = nil) {
            self.status = status
            self.reason = reason
            self.datum = datum
        }
    }

    public let kind: Kind
    public let schema: WorkflowDataSchema?

    public init(kind: Kind = .automatic, schema: WorkflowDataSchema? = nil) {
        self.kind = kind
        self.schema = schema
    }

    /// Call before admitting a request. Decoding a stored value does not bypass this check.
    public func validate() throws {
        switch kind {
        case .schema:
            guard let schema else {
                throw ValidationError("A D structured schema is required for schema output.")
            }
            var budget = SchemaDeclarationBudget()
            try budget.count(schema)
            try WorkflowStructuredText.validateSchema(schema)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(schema)
            guard encoded.count <= Self.maximumSchemaDeclarationBytes else {
                throw ValidationError("D schema declaration exceeds 64 KiB.")
            }
        case .automatic, .plainText, .markdown, .json:
            guard schema == nil else {
                throw ValidationError("A D structured schema is only allowed for schema output.")
            }
        }
    }

    /// This is a soft request to the model, never a constrained decoding setting.
    /// Invalid configurations have no instruction; callers must use validate() before admission.
    public var promptInstruction: String? {
        do { try validate() } catch { return nil }

        switch kind {
        case .automatic:
            return nil
        case .plainText:
            return "Respond in plain text."
        case .markdown:
            return "Respond in Markdown."
        case .json:
            return "Respond with one complete JSON value only, without Markdown fences or extra text."
        case .schema:
            guard let schema else { return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let encoded = try? encoder.encode(schema) else { return nil }
            let declaration = String(decoding: encoded, as: UTF8.self)
            let instruction = Self.schemaInstructionPrefix + declaration + Self.schemaInstructionSuffix
            guard instruction.utf8.count <= Self.maximumSchemaInstructionBytes else { return nil }
            return instruction
        }
    }

    /// Checks the original answer in full. JSON and schema use the same strict,
    /// bounded parser (1 MiB UTF-8, depth 24, 65,536 values, 256 object fields,
    /// 4,096 array items, finite Double numbers); text and Markdown have no
    /// reliable format check. Already lossy-decoded input bytes cannot be
    /// recovered from a Swift String.
    public func check(_ text: String) -> Report {
        do {
            try validate()
            switch kind {
            case .automatic, .plainText, .markdown:
                return Report(status: .notChecked)
            case .json:
                try WorkflowStructuredText.validateJSONSyntax(text)
                return Report(status: .valid)
            case .schema:
                guard let schema else {
                    return Report(status: .invalid, reason: "A D structured schema is required for schema output.")
                }
                let datum = try WorkflowStructuredText.parse(text, as: schema)
                return Report(status: .valid, datum: datum)
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return Report(status: .invalid, reason: reason)
        }
    }
}

/// Counts the Codable declaration before encoding the whole schema. Each encoded
/// string is bounded by its schema rule, so even escape expansion stays small.
private struct SchemaDeclarationBudget {
    private var bytes = 0
    private var nodes = 0
    private let encoder = JSONEncoder()

    private mutating func add(_ count: Int) throws {
        guard count <= ChatOutputFormat.maximumSchemaDeclarationBytes - bytes else {
            throw ChatOutputFormat.ValidationError("D schema declaration exceeds 64 KiB.")
        }
        bytes += count
    }

    private mutating func add(_ literal: String) throws {
        try add(literal.utf8.count)
    }

    private mutating func addString(_ value: String, maximumRawBytes: Int) throws {
        guard value.utf8.count <= maximumRawBytes else {
            throw ChatOutputFormat.ValidationError("D schema string exceeds its allowed length.")
        }
        try add(try encoder.encode(value).count)
    }

    mutating func count(_ schema: WorkflowDataSchema, depth: Int = 0) throws {
        nodes += 1
        guard depth <= 24, nodes <= 16_384 else {
            throw ChatOutputFormat.ValidationError("D schema depth or node count exceeds its limit.")
        }
        switch schema {
        case .text:
            try add(#"{"text":{}}"#)
        case .boolean:
            try add(#"{"boolean":{}}"#)
        case .number(let unit):
            if let unit {
                try add("{\"number\":{\"unit\":")
                try addString(unit, maximumRawBytes: 64)
                try add("}}")
            } else {
                try add(#"{"number":{}}"#)
            }
        case .enumeration(let choices):
            try add("{\"enumeration\":{\"_0\":[")
            for (index, choice) in choices.enumerated() {
                if index > 0 { try add(",") }
                try addString(choice, maximumRawBytes: 1_024)
            }
            try add("]}}")
        case .record(let fields):
            try add("{\"record\":{\"_0\":[")
            for (index, field) in fields.enumerated() {
                if index > 0 { try add(",") }
                try add("{\"name\":")
                try addString(field.name, maximumRawBytes: 256)
                try add(",\"required\":")
                try add(field.required ? "true" : "false")
                try add(",\"type\":")
                try count(field.type, depth: depth + 1)
                try add("}")
            }
            try add("]}}")
        case .list(let element):
            try add("{\"list\":{\"_0\":")
            try count(element, depth: depth + 1)
            try add("}}")
        case .optional(let element):
            try add("{\"optional\":{\"_0\":")
            try count(element, depth: depth + 1)
            try add("}}")
        case .result, .asset:
            // The shared parser rejects these schemas after bounded preflight.
            try add("{}")
        }
    }
}
