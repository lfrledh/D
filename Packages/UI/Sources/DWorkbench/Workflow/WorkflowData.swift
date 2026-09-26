import Foundation

/// Versioned values crossing workflow ports. This is data, never executable source.
public indirect enum WorkflowDataSchema: Codable, Sendable, Equatable {
    case text, number(unit: String?), boolean, enumeration([String])
    case record([WorkflowRecordField]), list(WorkflowDataSchema), optional(WorkflowDataSchema)
    case result(WorkflowDataSchema), asset(WorkflowDataKind)
    public var kind: WorkflowDataKind {
        switch self {
        case .text: .text; case .number: .number; case .boolean: .boolean
        case .enumeration: .enumeration; case .record: .record; case .list: .list
        case .optional: .optional; case .result: .result; case .asset(let kind): kind
        }
    }
    public var portKinds: [WorkflowDataKind] {
        if case .optional(let wrapped) = self { return [.optional] + wrapped.portKinds }
        return [kind]
    }
}

public struct WorkflowRecordField: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var type: WorkflowDataSchema
    public var required: Bool
    public init(_ name: String, _ type: WorkflowDataSchema, required: Bool = true) {
        self.name = name; self.type = type; self.required = required
    }
}

public struct WorkflowDataItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var value: WorkflowDatum
    public init(id: String = UUID().uuidString, value: WorkflowDatum) { self.id = id; self.value = value }
}

public enum WorkflowDataOutcome: String, Codable, Sendable { case success, failed, skipped, cancelled }
public struct WorkflowDataResult: Codable, Sendable, Equatable {
    public var status: WorkflowDataOutcome
    public var expected: WorkflowDataSchema
    public var value: WorkflowDatum?
    public var issues: [String]
    public init(status: WorkflowDataOutcome, expected: WorkflowDataSchema, value: WorkflowDatum? = nil, issues: [String] = []) {
        self.status = status; self.expected = expected; self.value = value; self.issues = issues
    }
}

public indirect enum WorkflowDatum: Codable, Sendable, Equatable {
    case text(String), number(Double, unit: String?), boolean(Bool), enumeration(String, choices: [String])
    case record(schema: [WorkflowRecordField], fields: [String: WorkflowDatum])
    case list(element: WorkflowDataSchema, items: [WorkflowDataItem])
    case none(WorkflowDataSchema), result(WorkflowDataResult), asset(WorkflowAssetReference)

    public var schema: WorkflowDataSchema {
        switch self {
        case .text: .text
        case .number(_, let unit): .number(unit: unit)
        case .boolean: .boolean
        case .enumeration(_, let choices): .enumeration(choices)
        case .record(let schema, _): .record(schema)
        case .list(let element, _): .list(element)
        case .none(let type): .optional(type)
        case .result(let result): .result(result.expected)
        case .asset(let ref): .asset(ref.kind)
        }
    }
    public var kind: WorkflowDataKind {
        switch self {
        case .text: .text
        case .number: .number
        case .boolean: .boolean
        case .enumeration: .enumeration
        case .record: .record
        case .list: .list
        case .none: .optional
        case .result: .result
        case .asset(let ref): ref.kind
        }
    }
    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var fields: [String: Self]? { if case .record(_, let fields) = self { fields } else { nil } }
    public var items: [WorkflowDataItem]? { if case .list(_, let items) = self { items } else { nil } }
    public func value(at path: [String]) throws -> Self {
        var value = self
        for part in path {
            guard case .record(_, let fields) = value else { throw WorkflowIssue("字段路径经过非记录值：\(part)。") }
            guard let next = fields[part] else { throw WorkflowIssue("缺少字段：\(part)。") }
            value = next
        }
        return value
    }
    public var assetReferences: [WorkflowAssetReference] {
        switch self {
        case .asset(let ref): [ref]
        case .record(_, let fields): fields.keys.sorted().flatMap { fields[$0]!.assetReferences }
        case .list(_, let items): items.flatMap { $0.value.assetReferences }
        case .result(let result): result.value?.assetReferences ?? []
        default: []
        }
    }
    /// A bounded validation pass also rejects malformed runtime/decoded values.
    public func validate(as expected: WorkflowDataSchema? = nil) throws {
        var count = 0
        try check(expected ?? schema, path: "$", depth: 0, count: &count)
    }
    private func check(_ expected: WorkflowDataSchema, path: String, depth: Int, count: inout Int) throws {
        count += 1
        guard depth <= 24, count <= 16_384 else { throw WorkflowIssue("数据层级或数量超过安全限制。") }
        if case .optional(let inner) = expected {
            if case .none(let declared) = self {
                guard declared == inner else { throw WorkflowIssue("\(path)：可选值类型不符。") }; return
            }
            try check(inner, path: path, depth: depth + 1, count: &count); return
        }
        switch (self, expected) {
        case (.text(let value), .text):
            guard value.utf8.count <= 1_048_576 else { throw WorkflowIssue("\(path)：文字过长。") }
        case (.number(let value, let unit), .number(let required)):
            guard value.isFinite, unit == required else { throw WorkflowIssue("\(path)：数字或单位不合法。") }
        case (.boolean, .boolean): break
        case (.enumeration(let value, let choices), .enumeration(let required)):
            guard choices == required, !choices.isEmpty, Set(choices).count == choices.count, choices.contains(value) else {
                throw WorkflowIssue("\(path)：枚举值或选项不合法。")
            }
        case (.record(let declared, let fields), .record(let required)):
            guard declared == required, required.count <= 256, Set(required.map(\.name)).count == required.count,
                  required.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 256 }),
                  Set(fields.keys).isSubset(of: Set(required.map(\.name))) else { throw WorkflowIssue("\(path)：记录结构不符或字段重复。") }
            for field in required {
                guard let value = fields[field.name] else {
                    if field.required { throw WorkflowIssue("\(path)：缺少字段 \(field.name)。") }; continue
                }
                try value.check(field.type, path: path + "." + field.name, depth: depth + 1, count: &count)
            }
        case (.list(let element, let items), .list(let required)):
            guard element == required, items.count <= 4_096, Set(items.map(\.id)).count == items.count,
                  items.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 }) else { throw WorkflowIssue("\(path)：列表类型、数量或成员身份不合法。") }
            for item in items { try item.value.check(required, path: path + "[" + item.id + "]", depth: depth + 1, count: &count) }
        case (.result(let result), .result(let required)):
            guard result.expected == required, result.issues.count <= 256 else { throw WorkflowIssue("\(path)：结果结构不符。") }
            if result.status == .success {
                guard let value = result.value, result.issues.isEmpty else { throw WorkflowIssue("\(path)：成功结果缺少合法数据。") }
                try value.check(required, path: path, depth: depth + 1, count: &count)
            } else if result.value != nil { throw WorkflowIssue("\(path)：失败结果不能提供合法数据。") }
        case (.asset(let ref), .asset(let kind)):
            guard ref.kind == kind, ref.sha256.count == 64, ref.sha256.allSatisfy({ $0.isHexDigit }) else { throw WorkflowIssue("\(path)：资产类型或摘要不符。") }
        default: throw WorkflowIssue("\(path)：数据类型不符。")
        }
    }
}

public enum WorkflowComparison: String, Codable, Sendable, CaseIterable { case equals, notEquals, less, lessOrEqual, greater, greaterOrEqual, exists }
public struct WorkflowDataRule: Codable, Sendable, Equatable {
    public var path: [String]
    public var comparison: WorkflowComparison
    public var value: WorkflowDatum?
    public init(path: [String] = [], comparison: WorkflowComparison = .exists, value: WorkflowDatum? = nil) {
        self.path = path; self.comparison = comparison; self.value = value
    }
    public func matches(_ data: WorkflowDatum) throws -> Bool {
        if comparison == .exists { return (try? data.value(at: path)).map { if case .none = $0 { false } else { true } } ?? false }
        let actual = try data.value(at: path)
        guard let value else { throw WorkflowIssue("比较缺少右侧值。") }
        try actual.validate(); try value.validate()
        guard actual.schema == value.schema else { throw WorkflowIssue("比较值的类型或单位不一致。") }
        switch comparison {
        case .equals: return actual == value
        case .notEquals: return actual != value
        case .exists: return true
        default:
            guard case .number(let left, _) = actual, case .number(let right, _) = value else { throw WorkflowIssue("大小比较需要同单位数字。") }
            switch comparison { case .less: return left < right; case .lessOrEqual: return left <= right
            case .greater: return left > right; case .greaterOrEqual: return left >= right; default: return false }
        }
    }
}

/// Form-backed settings for the standard data nodes; no source strings or executable scripts.
public struct WorkflowDataConfiguration: Codable, Sendable, Equatable {
    public var value: WorkflowDatum?
    public var schema: WorkflowDataSchema?
    public var fields: [WorkflowRecordField]
    public var path: [String]
    public var rules: [WorkflowDataRule]
    public var items: [WorkflowDataItem]
    public init(value: WorkflowDatum? = nil, schema: WorkflowDataSchema? = nil, fields: [WorkflowRecordField] = [],
                path: [String] = [], rules: [WorkflowDataRule] = [], items: [WorkflowDataItem] = []) {
        self.value = value; self.schema = schema; self.fields = fields; self.path = path; self.rules = rules; self.items = items
    }
}
