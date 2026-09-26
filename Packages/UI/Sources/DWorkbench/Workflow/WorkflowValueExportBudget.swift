import Foundation

/// Conservative encoded-size preflight. Counts repeated schema and escaped strings
/// before JSONEncoder can allocate one large document. It never reads asset bytes.
enum WorkflowValueExportBudget {
    static func validate(_ value: WorkflowDatum, limit: Int = 16 * 1_024 * 1_024) throws {
        var remaining = limit
        func add(_ bytes: Int) throws {
            guard bytes >= 0, bytes <= remaining else { throw WorkflowIssue("结构化导出超过16 MiB编码预算。") }
            remaining -= bytes
        }
        func string(_ value: String) throws {
            try add(2)
            for byte in value.utf8 { try add(byte < 32 ? 6 : (byte == 34 || byte == 92 ? 2 : 1)) }
        }
        func schema(_ s: WorkflowDataSchema, depth: Int) throws {
            try add(256 + depth * 32)
            switch s {
            case .number(let unit): if let unit { try string(unit) }
            case .enumeration(let choices): for choice in choices { try string(choice); try add(128 + depth * 8) }
            case .record(let fields):
                for field in fields { try string(field.name); try add(256 + depth * 32); try schema(field.type, depth: depth + 1) }
            case .list(let type), .optional(let type), .result(let type): try schema(type, depth: depth + 1)
            case .asset: try add(128)
            default: break
            }
        }
        func visit(_ value: WorkflowDatum, depth: Int) throws {
            try add(512 + depth * 64)
            switch value {
            case .text(let text): try string(text)
            case .number(_, let unit): if let unit { try string(unit) }
            case .boolean: break
            case .enumeration(let selected, let choices): try string(selected); for choice in choices { try string(choice); try add(128 + depth * 8) }
            case .record(let fields, let values):
                try schema(.record(fields), depth: depth + 1)
                for (name, item) in values { try string(name); try visit(item, depth: depth + 1) }
            case .list(let element, let items):
                try schema(element, depth: depth + 1)
                for item in items { try string(item.id); try add(128 + depth * 16); try visit(item.value, depth: depth + 1) }
            case .none(let type): try schema(type, depth: depth + 1)
            case .result(let result):
                try schema(result.expected, depth: depth + 1)
                for issue in result.issues { try string(issue); try add(128 + depth * 8) }
                if let data = result.value { try visit(data, depth: depth + 1) }
            case .asset: try add(1024)
            }
        }
        try value.validate()
        try visit(value, depth: 0)
    }
}
