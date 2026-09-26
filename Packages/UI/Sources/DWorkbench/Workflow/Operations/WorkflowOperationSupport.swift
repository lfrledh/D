import Foundation

enum WorkflowScalarReader {
    static func text(_ field: String, in node: WorkflowNode) throws -> String {
        guard case .text(let value)? = node.parameters[field] else {
            throw WorkflowIssue("字段 \(field) 必须是文字。", nodeID: node.id)
        }
        return value
    }

    static func integer(_ field: String, in node: WorkflowNode) throws -> Int {
        guard case .integer(let value)? = node.parameters[field] else {
            throw WorkflowIssue("字段 \(field) 必须是整数。", nodeID: node.id)
        }
        return value
    }

    static func decimal(_ field: String, in node: WorkflowNode) throws -> Double {
        guard case .decimal(let value)? = node.parameters[field], value.isFinite else {
            throw WorkflowIssue("字段 \(field) 必须是有限小数。", nodeID: node.id)
        }
        return value
    }
}

enum WorkflowLimits {
    static func positive(_ value: Int, field: String, node: WorkflowNode) throws {
        guard value > 0 else { throw WorkflowIssue("字段 \(field) 必须大于零。", nodeID: node.id) }
    }

    static func range(_ value: Double, _ range: ClosedRange<Double>, field: String, node: WorkflowNode) throws {
        guard range.contains(value) else {
            throw WorkflowIssue("字段 \(field) 超出范围 \(range.lowerBound)...\(range.upperBound)。", nodeID: node.id)
        }
    }

    static func nonnegative(_ value: Double, field: String, node: WorkflowNode) throws {
        guard value >= 0 else { throw WorkflowIssue("字段 \(field) 不能为负数。", nodeID: node.id) }
    }

    static func positiveUnit(_ value: Double, field: String, node: WorkflowNode) throws {
        guard value > 0, value <= 1 else {
            throw WorkflowIssue("字段 \(field) 必须大于零且不超过 1。", nodeID: node.id)
        }
    }
}

enum WorkflowTemplate {
    static func validate(_ template: String, nodeID: UUID) throws {
        let remainder = template
            .replacingOccurrences(of: "{{input}}", with: "")
            .replacingOccurrences(of: "{{other}}", with: "")
        guard !remainder.contains("{{"), !remainder.contains("}}") else {
            throw WorkflowIssue("模板只允许 {{input}} 和 {{other}}，且不会执行脚本。", nodeID: nodeID)
        }
    }

    static func render(_ template: String, input: String?, other: String?, nodeID: UUID) throws -> String {
        var remainder = template[...]
        var result = ""
        while !remainder.isEmpty {
            let inputRange = remainder.range(of: "{{input}}")
            let otherRange = remainder.range(of: "{{other}}")
            let selection: (range: Range<String.Index>, value: String?)?
            switch (inputRange, otherRange) {
            case (.some(let left), .some(let right)):
                selection = left.lowerBound < right.lowerBound ? (left, input) : (right, other)
            case (.some(let range), .none): selection = (range, input)
            case (.none, .some(let range)): selection = (range, other)
            case (.none, .none): selection = nil
            }
            guard let selection else {
                result.append(contentsOf: remainder)
                break
            }
            result.append(contentsOf: remainder[..<selection.range.lowerBound])
            guard let value = selection.value else {
                throw WorkflowIssue("模板引用的变量缺少值。", nodeID: nodeID)
            }
            result.append(value)
            remainder = remainder[selection.range.upperBound...]
        }
        return result
    }

    @MainActor static func value(
        port: String,
        fallback: String,
        context: WorkflowExecutionContext,
        services: any WorkflowOperationServices
    ) async throws -> (text: String, parent: WorkflowAssetReference?) {
        if let input = context.inputs[port] {
            let reference = try WorkflowExecution.asset(input, kind: .text, port: port, node: context.node)
            let text = try await services.readText(reference)
            try WorkflowExecution.ensureTextLimit(text, node: context.node, port: port)
            return (text, reference)
        }
        let text = try WorkflowScalarReader.text(fallback, in: context.node)
        guard !text.isEmpty else {
            throw WorkflowIssue("模板引用的变量缺少值。", nodeID: context.node.id, port: port)
        }
        try WorkflowExecution.ensureTextLimit(text, node: context.node, port: port)
        return (text, nil)
    }
}

enum WorkflowExecution {
    private static let maximumTextBytes = 1_048_576

    static func requireModel(in node: WorkflowNode) throws {
        let modelID = try WorkflowScalarReader.text("modelID", in: node)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowIssue("执行前必须绑定已登记模型的内容身份。", nodeID: node.id)
        }
    }

    static func ensureTextLimit(_ text: String, node: WorkflowNode, port: String?) throws {
        guard text.utf8.count <= maximumTextBytes else {
            throw WorkflowIssue("输入文字超过 \(maximumTextBytes) 字节。", nodeID: node.id, port: port)
        }
    }

    static func inputAsset(_ port: String, kind: WorkflowDataKind, context: WorkflowExecutionContext) throws -> WorkflowAssetReference {
        guard let value = context.inputs[port] else {
            throw WorkflowIssue("输入尚未就绪。", nodeID: context.node.id, port: port)
        }
        return try asset(value, kind: kind, port: port, node: context.node)
    }

    static func asset(_ value: WorkflowValue, kind: WorkflowDataKind, port: String, node: WorkflowNode) throws -> WorkflowAssetReference {
        guard case .asset(let reference) = value, reference.kind == kind else {
            throw WorkflowIssue("输入实际类型不符。", nodeID: node.id, port: port)
        }
        return reference
    }
}
