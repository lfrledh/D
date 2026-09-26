import Foundation

extension WorkflowArchive {
    var requiresLanguageVersion: Bool {
        tools != nil || runs.contains { run in
            run.planCheckpoint != nil || run.steps.contains { step in
                step.node.requiresLanguageVersion || step.humanTask != nil || (Array(step.inputs.values) + Array(step.outputs.values)).contains {
                    if case .data = $0 { true } else { false }
                }
            }
        } ||
        (graphs + runs.map(\.graph)).contains { graph in
            graph.interface != nil || graph.nodes.contains {
                $0.requiresLanguageVersion
            }
        }
    }
}

private extension WorkflowNode {
    var requiresLanguageVersion: Bool {
        control != nil || dataConfiguration != nil || operationID.hasPrefix("d.value.") ||
        operationID.hasPrefix("d.control.")
    }
}

/// Pure validation shared by the durable Store. Unknown source keys are retained read-only.
enum WorkflowArchiveInspection {
    static func containsUnknownFields(original: Data, decoded: WorkflowArchive) throws -> Bool {
        let source = try JSONSerialization.jsonObject(with: original)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
        func unknown(_ source: Any, _ known: Any, depth: Int) throws -> Bool {
            guard depth <= 192 else { throw WorkflowIssue("流程数据层级过深。") }
            if let object = source as? [String: Any], let recognized = known as? [String: Any] {
                for (key, value) in object {
                    guard let counterpart = recognized[key] else {
                        // Explicit null is not an unknown property if a known optional omitted it.
                        // Conservatively preserve it read-only rather than guessing the schema.
                        return true
                    }
                    if try unknown(value, counterpart, depth: depth + 1) { return true }
                }
            } else if let items = source as? [Any], let counterparts = known as? [Any] {
                guard items.count == counterparts.count else { return true }
                // Codable represents non-string-key dictionaries as alternating key/value arrays.
                // Dictionary iteration order is not a semantic change (checkpoint inputs use UUID keys).
                let pairs = items.count.isMultiple(of: 2) && !items.isEmpty &&
                    stride(from: 0, to: items.count, by: 2).allSatisfy { index in
                        (items[index] as? String).flatMap(UUID.init(uuidString:)) != nil &&
                        (counterparts[index] as? String).flatMap(UUID.init(uuidString:)) != nil
                    }
                if pairs {
                    for index in stride(from: 0, to: items.count, by: 2) {
                        guard let target = stride(from: 0, to: counterparts.count, by: 2).first(where: {
                            counterparts[$0] as? String == items[index] as? String
                        }) else { return true }
                        if try unknown(items[index + 1], counterparts[target + 1], depth: depth + 1) { return true }
                    }
                    return false
                }
                for (a, b) in zip(items, counterparts) where try unknown(a, b, depth: depth + 1) { return true }
            }
            return false
        }
        return try unknown(source, encoded, depth: 0)
    }

    static func unknownOperation(in data: Data, registry: WorkflowRegistry = .standard) throws -> String? {
        func visit(_ value: Any, depth: Int) throws -> String? {
            guard depth <= 192 else { throw WorkflowIssue("流程数据层级过深。") }
            if let object = value as? [String: Any] {
                if let id = object["operationID"] as? String, let version = object["definitionVersion"] as? Int {
                    guard let op = registry.operation(id), op.definition.version == version else { return "\(id) v\(version)" }
                }
                for value in object.values { if let issue = try visit(value, depth: depth + 1) { return issue } }
            } else if let items = value as? [Any] {
                for value in items { if let issue = try visit(value, depth: depth + 1) { return issue } }
            }
            return nil
        }
        return try visit(JSONSerialization.jsonObject(with: data), depth: 0)
    }

    static func validateStructure(_ archive: WorkflowArchive) throws {
        guard archive.version == 2 || !archive.requiresLanguageVersion else {
            throw WorkflowIssue("新语言数据必须使用流程格式 v2；不能写入旧格式。")
        }
        let tools = archive.tools ?? []
        guard tools.count <= 256, Set(tools.map { "\($0.id):\($0.version)" }).count == tools.count else {
            throw WorkflowIssue("工具版本重复或数量超限。")
        }
        var count = 0
        func graph(_ value: WorkflowGraph, depth: Int) throws {
            guard depth <= 16 else { throw WorkflowIssue("局部流程超过 16 层。") }
            try WorkflowRegistry.standard.validate(value, tools: tools)
            count += value.nodes.count
            guard count <= 65_536 else { throw WorkflowIssue("流程存储节点总数超过预算。") }
            if let interface = value.interface {
                try WorkflowDataSchema.record(interface.inputs).validateDefinition()
                guard Set(interface.outputs.map(\.name)).count == interface.outputs.count,
                      interface.outputs.count <= 256 else { throw WorkflowIssue("工具输出名称重复或超限。") }
                for output in interface.outputs {
                    guard !output.name.isEmpty, value.nodes.contains(where: { $0.id == output.nodeID }) else {
                        throw WorkflowIssue("工具输出未指向局部节点。")
                    }
                    try output.schema.validateDefinition()
                }
            }
            for node in value.nodes {
                if let config = node.dataConfiguration {
                    try config.schema?.validateDefinition()
                    try config.value?.validate()
                    try WorkflowDataSchema.record(config.fields).validateDefinition()
                    guard config.path.count <= 24, config.rules.count <= 256, config.items.count <= 4096 else {
                        throw WorkflowIssue("节点数据配置超过预算。", nodeID: node.id)
                    }
                    for item in config.items { try item.value.validate() }
                    for rule in config.rules { try rule.value?.validate() }
                }
                switch node.control {
                case .branch(let predicate, let yes, let no):
                    try predicate.value?.validate(); try graph(yes, depth: depth + 1); try graph(no, depth: depth + 1)
                case .map(let body, _): try graph(body, depth: depth + 1)
                case .loop(let body, let schema, let maximum, let until):
                    guard (1...1000).contains(maximum) else { throw WorkflowIssue("循环上限必须为 1—1000。") }
                    try schema.validateDefinition(); try until.value?.validate(); try graph(body, depth: depth + 1)
                case .invoke(let reference):
                    guard reference.version > 0, reference.digest.count == 64,
                          reference.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                        throw WorkflowIssue("工具引用版本或摘要无效。")
                    }
                case nil: break
                }
            }
        }
        for item in archive.graphs + archive.runs.map(\.graph) + tools.map(\.graph) { try graph(item, depth: 0) }
        for tool in tools {
            guard tool.version > 0, !tool.name.isEmpty, tool.graph.interface != nil else { throw WorkflowIssue("工具缺少版本或接口。") }
        }
    }
}
