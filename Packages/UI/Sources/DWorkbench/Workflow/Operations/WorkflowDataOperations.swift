import Foundation

/// Deterministic, in-memory operations for the versioned workflow data language.
enum WorkflowDataOperations {
    static let operations: [WorkflowOperation] = [
        input, template, record, field, list, filter, select, pair, validate, returnValue,
    ]

    private static let input = WorkflowOperation(
        definition: .init(
            id: "d.value.input", title: "Data Input", detail: "Provides a frozen typed value.", inputs: [],
            outputs: [.init("output", "Value", kinds: WorkflowDataKind.allCases)],
            fields: [.init("publicName", "Public Name", .text(multiline: false), .text(""))]
        ),
        validate: { node in _ = try WorkflowScalarReader.text("publicName", in: node) },
        execute: { context, _ in
            try WorkflowDataOperationSupport.requireOnlyInputs([], context: context)
            _ = try WorkflowScalarReader.text("publicName", in: context.node)
            guard let value = context.node.dataConfiguration?.value else {
                throw WorkflowIssue("Data input has no frozen value.", nodeID: context.node.id)
            }
            try value.validate()
            return .outputs(["output": .data(value)])
        }
    )

    private static let template = WorkflowOperation(
        definition: .init(
            id: "d.value.template", title: "Data Template", detail: "Safely substitutes scalar record fields.",
            inputs: [.init("fields", "Fields", kinds: [.record], required: false)],
            outputs: [.init("output", "Text", kinds: [.text])],
            fields: [.init("template", "Template", .text(multiline: true), .text(""))]
        ),
        validate: { node in
            try WorkflowDataOperationSupport.validateTemplate(WorkflowScalarReader.text("template", in: node), node: node)
        },
        execute: { context, _ in
            try WorkflowDataOperationSupport.requireOnlyInputs(["fields"], context: context)
            let source: WorkflowDatum?
            if context.inputs["fields"] != nil {
                source = try WorkflowDataOperationSupport.inputDatum("fields", context: context)
            } else {
                source = context.node.dataConfiguration?.value
            }
            let fields: [String: WorkflowDatum]
            if let source {
                try source.validate()
                guard case .record(_, let values) = source else {
                    throw WorkflowIssue("Template fields must be a record.", nodeID: context.node.id, port: "fields")
                }
                fields = values
            } else {
                fields = [:]
            }
            let sourceTemplate = try WorkflowScalarReader.text("template", in: context.node)
            let rendered = try WorkflowDataOperationSupport.renderTemplate(sourceTemplate, fields: fields, node: context.node)
            let output = WorkflowDatum.text(rendered)
            try output.validate()
            return .outputs(["output": .data(output)])
        }
    )

    private static let record = WorkflowOperation(
        definition: .init(
            id: "d.value.record", title: "Record", detail: "Builds a typed record from configured fields.",
            inputs: [], outputs: [.init("output", "Record", kinds: [.record])]
        ),
        execute: { context, _ in
            let configuration = context.node.dataConfiguration
            let schema = configuration?.fields ?? []
            try WorkflowDataOperationSupport.validateFields(schema, node: context.node)
            try WorkflowDataOperationSupport.requireOnlyInputs(Set(schema.map(\.name)), context: context)

            var fallback: [String: WorkflowDatum] = [:]
            if let value = configuration?.value {
                try value.validate()
                guard case .record(_, let fields) = value else {
                    throw WorkflowIssue("Record fallback must be a record.", nodeID: context.node.id)
                }
                fallback = fields
            }

            var fields: [String: WorkflowDatum] = [:]
            for declaration in schema {
                let value: WorkflowDatum?
                if context.inputs[declaration.name] != nil {
                    value = try WorkflowDataOperationSupport.inputDatum(declaration.name, context: context)
                } else {
                    value = fallback[declaration.name]
                }
                guard let value else {
                    if declaration.required {
                        throw WorkflowIssue("Required record field is missing.", nodeID: context.node.id, port: declaration.name)
                    }
                    continue
                }
                try value.validate(as: declaration.type)
                fields[declaration.name] = value
            }
            let output = WorkflowDatum.record(schema: schema, fields: fields)
            try output.validate()
            return .outputs(["output": .data(output)])
        }
    )

    private static let field = WorkflowOperation(
        definition: .init(
            id: "d.value.field", title: "Field", detail: "Reads a typed value at a record path.",
            inputs: [.init("input", "Record", kinds: [.record])],
            outputs: [.init("output", "Value", kinds: WorkflowDataKind.allCases)]
        ),
        execute: { context, _ in
            try WorkflowDataOperationSupport.requireOnlyInputs(["input"], context: context)
            let input = try WorkflowDataOperationSupport.inputDatum("input", context: context)
            try input.validate()
            guard case .record = input else {
                throw WorkflowIssue("Field input must be a record.", nodeID: context.node.id, port: "input")
            }
            guard let configuration = context.node.dataConfiguration, let expected = configuration.schema else {
                throw WorkflowIssue("Field output schema is required.", nodeID: context.node.id)
            }
            try WorkflowDataOperationSupport.validatePath(configuration.path, node: context.node)
            let output = try input.value(at: configuration.path)
            try output.validate(as: expected)
            return .outputs(["output": .data(output)])
        }
    )

    private static let list = WorkflowOperation(
        definition: .init(
            id: "d.value.list", title: "List", detail: "Builds or concatenates one level of typed list members.",
            inputs: [], outputs: [.init("output", "List", kinds: [.list])],
            fields: [.init("mode", "Mode", .choice(["items", "concat"]), .text("items"))]
        ),
        validate: { node in try WorkflowDataOperationSupport.validateListNode(node) },
        execute: { context, _ in
            try WorkflowDataOperationSupport.validateListNode(context.node)
            guard let configuration = context.node.dataConfiguration, let element = configuration.schema else {
                throw WorkflowIssue("List element schema is required.", nodeID: context.node.id)
            }
            try WorkflowDataOperationSupport.validateFields(configuration.fields, node: context.node)
            try WorkflowDataOperationSupport.requireOnlyInputs(Set(configuration.fields.map(\.name)), context: context)

            var items = configuration.items
            for item in items { try item.value.validate(as: element) }
            let mode = try WorkflowScalarReader.text("mode", in: context.node)
            let expectedPortType: WorkflowDataSchema = mode == "items" ? element : .list(element)
            guard configuration.fields.allSatisfy({ $0.type == expectedPortType }) else {
                throw WorkflowIssue("List port types do not match the selected mode.", nodeID: context.node.id)
            }
            for port in configuration.fields {
                guard context.inputs[port.name] != nil else {
                    if port.required {
                        throw WorkflowIssue("Required list input is missing.", nodeID: context.node.id, port: port.name)
                    }
                    continue
                }
                let value = try WorkflowDataOperationSupport.inputDatum(port.name, context: context)
                if mode == "items" {
                    try value.validate(as: element)
                    items.append(.init(id: port.name, value: value))
                } else {
                    try value.validate(as: .list(element))
                    guard case .list(_, let nested) = value else {
                        throw WorkflowIssue("Concat input must be a list.", nodeID: context.node.id, port: port.name)
                    }
                    items.append(contentsOf: nested)
                }
            }
            let output = WorkflowDatum.list(element: element, items: items)
            try output.validate()
            return .outputs(["output": .data(output)])
        }
    )

    private static let filter = WorkflowOperation(
        definition: .init(
            id: "d.value.filter", title: "Filter", detail: "Filters and optionally stably sorts a typed list.",
            inputs: [.init("input", "List", kinds: [.list])], outputs: [.init("output", "List", kinds: [.list])],
            fields: [
                .init("ascending", "Ascending", .flag, .flag(true)),
                .init("limit", "Limit", .integer, .integer(4_096)),
            ]
        ),
        validate: { node in try WorkflowDataOperationSupport.validateFilterNode(node) },
        execute: { context, _ in
            try WorkflowDataOperationSupport.validateFilterNode(context.node)
            try WorkflowDataOperationSupport.requireOnlyInputs(["input"], context: context)
            let input = try WorkflowDataOperationSupport.inputDatum("input", context: context)
            try input.validate()
            guard case .list(let element, let sourceItems) = input else {
                throw WorkflowIssue("Filter input must be a list.", nodeID: context.node.id, port: "input")
            }
            let configuration = context.node.dataConfiguration ?? .init()
            try WorkflowDataOperationSupport.validateRules(configuration.rules, against: element, node: context.node)

            var filtered: [WorkflowDataItem] = []
            for item in sourceItems {
                var matches = true
                for rule in configuration.rules {
                    let ruleMatches = try rule.matches(item.value)
                    matches = matches && ruleMatches
                }
                if matches { filtered.append(item) }
            }

            if !configuration.path.isEmpty {
                try WorkflowDataOperationSupport.validatePath(configuration.path, node: context.node)
                let keySchema = try WorkflowDataOperationSupport.schema(at: configuration.path, in: element, node: context.node)
                try WorkflowDataOperationSupport.requireSortable(keySchema, node: context.node)
                let keyed = try filtered.enumerated().map { offset, item in
                    let value = try item.value.value(at: configuration.path)
                    try value.validate(as: keySchema)
                    return (offset: offset, item: item, key: try WorkflowDataOperationSupport.sortKey(value, node: context.node))
                }
                let ascending = try WorkflowDataOperationSupport.flag("ascending", in: context.node)
                filtered = keyed.sorted { left, right in
                    let order = WorkflowDataOperationSupport.compare(left.key, right.key)
                    if order == 0 { return left.offset < right.offset }
                    return ascending ? order < 0 : order > 0
                }.map { $0.item }
            }
            let limit = try WorkflowScalarReader.integer("limit", in: context.node)
            let output = WorkflowDatum.list(element: element, items: Array(filtered.prefix(limit)))
            try output.validate()
            return .outputs(["output": .data(output)])
        }
    )

    private static let select = WorkflowOperation(
        definition: .init(
            id: "d.value.select", title: "Select", detail: "Selects an explicit list member by identity or one-based index.",
            inputs: [.init("input", "List", kinds: [.list])], outputs: [.init("output", "Value", kinds: WorkflowDataKind.allCases)],
            fields: [
                .init("method", "Method", .choice(["id", "index"]), .text("id")),
                .init("itemID", "Item ID", .text(multiline: false), .text("")),
                .init("index", "Index", .integer, .integer(1)),
            ]
        ),
        validate: { node in try WorkflowDataOperationSupport.validateSelectNode(node) },
        execute: { context, _ in
            try WorkflowDataOperationSupport.validateSelectNode(context.node)
            try WorkflowDataOperationSupport.requireOnlyInputs(["input"], context: context)
            let input = try WorkflowDataOperationSupport.inputDatum("input", context: context)
            try input.validate()
            guard case .list(_, let items) = input else {
                throw WorkflowIssue("Select input must be a list.", nodeID: context.node.id, port: "input")
            }
            let method = try WorkflowScalarReader.text("method", in: context.node)
            let selected: WorkflowDataItem
            if method == "id" {
                let itemID = try WorkflowScalarReader.text("itemID", in: context.node)
                guard !itemID.isEmpty else { throw WorkflowIssue("Item ID must be explicit.", nodeID: context.node.id) }
                guard let match = items.first(where: { $0.id == itemID }) else {
                    throw WorkflowIssue("Unknown item ID.", nodeID: context.node.id)
                }
                selected = match
            } else {
                let index = try WorkflowScalarReader.integer("index", in: context.node)
                guard index >= 1, index <= items.count else {
                    throw WorkflowIssue("One-based list index is out of range.", nodeID: context.node.id)
                }
                selected = items[index - 1]
            }
            return .outputs(["output": .data(selected.value)])
        }
    )

    private static let pair = WorkflowOperation(
        definition: .init(
            id: "d.value.pair", title: "Pair", detail: "Pairs two record lists by unique scalar keys.",
            inputs: [
                .init("left", "Left", kinds: [.list]),
                .init("right", "Right", kinds: [.list]),
            ],
            outputs: [
                .init("output", "Pairs", kinds: [.list]),
                .init("leftUnmatched", "Left Unmatched", kinds: [.list]),
                .init("rightUnmatched", "Right Unmatched", kinds: [.list]),
            ]
        ),
        execute: { context, _ in
            try WorkflowDataOperationSupport.requireOnlyInputs(["left", "right"], context: context)
            let left = try WorkflowDataOperationSupport.inputDatum("left", context: context)
            let right = try WorkflowDataOperationSupport.inputDatum("right", context: context)
            try left.validate(); try right.validate()
            guard case .list(let leftElement, let leftItems) = left,
                  case .record = leftElement,
                  case .list(let rightElement, let rightItems) = right,
                  case .record = rightElement else {
                throw WorkflowIssue("Pair inputs must be lists of records.", nodeID: context.node.id)
            }
            guard let configuration = context.node.dataConfiguration else {
                throw WorkflowIssue("Pair key path is required.", nodeID: context.node.id)
            }
            try WorkflowDataOperationSupport.validatePath(configuration.path, node: context.node, allowEmpty: false)
            let leftKeySchema = try WorkflowDataOperationSupport.schema(at: configuration.path, in: leftElement, node: context.node)
            let rightKeySchema = try WorkflowDataOperationSupport.schema(at: configuration.path, in: rightElement, node: context.node)
            guard leftKeySchema == rightKeySchema else {
                throw WorkflowIssue("Pair key types differ.", nodeID: context.node.id)
            }
            try WorkflowDataOperationSupport.requirePairKey(leftKeySchema, node: context.node)

            let leftKeyed = try WorkflowDataOperationSupport.uniqueKeys(leftItems, path: configuration.path, schema: leftKeySchema, side: "left", node: context.node)
            let rightKeyed = try WorkflowDataOperationSupport.uniqueKeys(rightItems, path: configuration.path, schema: rightKeySchema, side: "right", node: context.node)
            let rightByKey = Dictionary(uniqueKeysWithValues: rightKeyed.map { ($0.key, $0.item) })

            let pairSchema: [WorkflowRecordField] = [
                .init("left", leftElement), .init("right", rightElement),
            ]
            var paired: [WorkflowDataItem] = []
            var leftUnmatched: [WorkflowDataItem] = []
            var usedRight: Set<WorkflowDataOperationSupport.PairKey> = []
            for entry in leftKeyed {
                guard let rightItem = rightByKey[entry.key] else {
                    leftUnmatched.append(entry.item)
                    continue
                }
                usedRight.insert(entry.key)
                let value = WorkflowDatum.record(schema: pairSchema, fields: [
                    "left": entry.item.value, "right": rightItem.value,
                ])
                paired.append(.init(id: entry.item.id, value: value))
            }
            let rightUnmatched = rightKeyed.compactMap { usedRight.contains($0.key) ? nil : $0.item }
            let outputs: [String: WorkflowValue] = [
                "output": .data(.list(element: .record(pairSchema), items: paired)),
                "leftUnmatched": .data(.list(element: leftElement, items: leftUnmatched)),
                "rightUnmatched": .data(.list(element: rightElement, items: rightUnmatched)),
            ]
            for value in outputs.values {
                guard let datum = value.datum else { throw WorkflowIssue("Pair produced a non-data output.", nodeID: context.node.id) }
                try datum.validate()
            }
            return .outputs(outputs)
        }
    )

    private static let validate = WorkflowOperation(
        definition: .init(
            id: "d.value.validate", title: "Validate", detail: "Reports typed validation issues or throws in strict mode.",
            inputs: [.init("input", "Value", kinds: WorkflowDataKind.allCases)], outputs: [.init("output", "Report", kinds: [.record])],
            fields: [.init("strict", "Strict", .flag, .flag(false)),
                     .init("expectedItemCount", "List item count (-1: unrestricted)", .integer, .integer(-1))]
        ),
        validate: { node in
            _ = try WorkflowDataOperationSupport.flag("strict", in: node)
            _ = try WorkflowDataOperationSupport.expectedItemCount(in: node)
            if node.dataConfiguration?.validationInputFormat == .jsonText {
                guard let schema = node.dataConfiguration?.schema else {
                    throw WorkflowIssue("Validation schema is required.", nodeID: node.id)
                }
                try WorkflowStructuredText.validateSchema(schema)
                try WorkflowDataConfiguration.validationReportSchema(for: schema).validateDefinition()
            }
        },
        execute: { context, _ in
            try WorkflowDataOperationSupport.requireOnlyInputs(["input"], context: context)
            let input = try WorkflowDataOperationSupport.inputDatum("input", context: context)
            guard let expected = context.node.dataConfiguration?.schema else {
                throw WorkflowIssue("Validation schema is required.", nodeID: context.node.id)
            }
            let strict = try WorkflowDataOperationSupport.flag("strict", in: context.node)
            let expectedItemCount = try WorkflowDataOperationSupport.expectedItemCount(in: context.node)
            let jsonText: String?
            if context.node.dataConfiguration?.validationInputFormat == .jsonText {
                // Configuration and input-shape errors are not model-output repair data.
                try WorkflowStructuredText.validateSchema(expected)
                try WorkflowDataConfiguration.validationReportSchema(for: expected).validateDefinition()
                guard case .text(let text) = input else {
                    throw WorkflowIssue("JSON validation requires a Text value.", nodeID: context.node.id)
                }
                jsonText = text
            } else { jsonText = nil }
            let valid: Bool
            let data: WorkflowDatum
            let issueMessages: [String]
            do {
                let parsed: WorkflowDatum
                if let jsonText { parsed = try WorkflowStructuredText.parse(jsonText, as: expected) }
                else { try input.validate(as: expected); parsed = input }
                if let expectedItemCount, parsed.items?.count != expectedItemCount {
                    throw WorkflowIssue("Expected exactly \(expectedItemCount) list items; received \(parsed.items?.count ?? 0).")
                }
                data = parsed; valid = true; issueMessages = []
            } catch {
                // Only pure parsing/typed validation runs inside this catch.
                if strict { throw error }
                valid = false; data = .none(expected)
                issueMessages = [jsonText == nil ? error.localizedDescription : WorkflowDataOperationSupport.boundedDiagnostic(error.localizedDescription)]
            }
            let issueItems = issueMessages.enumerated().map {
                WorkflowDataItem(id: "issue-\($0.offset + 1)", value: .text($0.element))
            }
            guard case .record(let reportSchema) = WorkflowDataConfiguration.validationReportSchema(for: expected) else {
                throw WorkflowIssue("Invalid validation report schema.", nodeID: context.node.id)
            }
            let report = WorkflowDatum.record(schema: reportSchema, fields: [
                "valid": .boolean(valid),
                "data": data,
                "issues": .list(element: .text, items: issueItems),
            ])
            try report.validate()
            return .outputs(["output": .data(report)])
        }
    )

    private static let returnValue = WorkflowOperation(
        definition: .init(
            id: "d.value.return", title: "Return", detail: "Names and returns a valid workflow value.",
            inputs: [.init("input", "Value", kinds: WorkflowDataKind.allCases)], outputs: [.init("output", "Value", kinds: WorkflowDataKind.allCases)],
            fields: [.init("name", "Name", .text(multiline: false), .text("result"))]
        ),
        validate: { node in _ = try WorkflowScalarReader.text("name", in: node) },
        execute: { context, _ in
            try WorkflowDataOperationSupport.requireOnlyInputs(["input"], context: context)
            _ = try WorkflowScalarReader.text("name", in: context.node)
            let input = try WorkflowDataOperationSupport.inputDatum("input", context: context)
            try input.validate()
            return .outputs(["output": .data(input)])
        }
    )
}

private enum WorkflowDataOperationSupport {
    private static let maximumTextBytes = 1_048_576

    static func boundedDiagnostic(_ message: String) -> String {
        guard message.utf8.count > 4_096 else { return message }
        var prefix = "", bytes = 0
        for scalar in message.unicodeScalars {
            let size = scalar.utf8.count
            guard bytes + size <= 4_096 else { break }
            prefix.unicodeScalars.append(scalar); bytes += size
        }
        return prefix + "… [diagnostic truncated; original text retained]"
    }

    enum SortKey {
        case text(String)
        case number(Double)
        case boolean(Bool)
        case enumeration(Int)
    }

    enum PairKey: Hashable {
        case text(String)
        case number(Double, String?)
        case boolean(Bool)
        case enumeration(String, [String])
    }

    static func requireOnlyInputs(_ allowed: Set<String>, context: WorkflowExecutionContext) throws {
        let unknown = Set(context.inputs.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw WorkflowIssue("Unexpected input ports: \(unknown.joined(separator: ", ")).", nodeID: context.node.id)
        }
    }

    static func inputDatum(_ port: String, context: WorkflowExecutionContext) throws -> WorkflowDatum {
        guard let value = context.inputs[port] else {
            throw WorkflowIssue("Input is not ready.", nodeID: context.node.id, port: port)
        }
        guard let datum = value.datum else {
            throw WorkflowIssue("Input is not workflow data.", nodeID: context.node.id, port: port)
        }
        return datum
    }

    static func flag(_ field: String, in node: WorkflowNode) throws -> Bool {
        guard case .flag(let value)? = node.parameters[field] else {
            throw WorkflowIssue("Field \(field) must be a Boolean.", nodeID: node.id)
        }
        return value
    }

    static func validateFields(_ fields: [WorkflowRecordField], node: WorkflowNode) throws {
        guard fields.count <= 256, Set(fields.map(\.name)).count == fields.count,
              fields.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 256 }) else {
            throw WorkflowIssue("Configured fields are duplicated or exceed safe limits.", nodeID: node.id)
        }
    }

    static func validatePath(_ path: [String], node: WorkflowNode, allowEmpty: Bool = true) throws {
        guard (allowEmpty || !path.isEmpty), path.count <= 24,
              path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw WorkflowIssue("Field path is empty or exceeds safe limits.", nodeID: node.id)
        }
    }

    static func validateTemplate(_ template: String, node: WorkflowNode) throws {
        guard template.utf8.count <= maximumTextBytes else {
            throw WorkflowIssue("Template text is too long.", nodeID: node.id)
        }
        var remainder = template[...]
        while let opening = remainder.range(of: "{{") {
            guard !remainder[..<opening.lowerBound].contains("}}"),
                  let closing = remainder[opening.upperBound...].range(of: "}}") else {
                throw WorkflowIssue("Template marker is malformed.", nodeID: node.id)
            }
            let name = remainder[opening.upperBound..<closing.lowerBound]
            guard !name.isEmpty, name.utf8.count <= 256, !name.contains("{"), !name.contains("}") else {
                throw WorkflowIssue("Template field name is invalid.", nodeID: node.id)
            }
            remainder = remainder[closing.upperBound...]
        }
        guard !remainder.contains("}}") else { throw WorkflowIssue("Template marker is malformed.", nodeID: node.id) }
    }

    static func renderTemplate(_ template: String, fields: [String: WorkflowDatum], node: WorkflowNode) throws -> String {
        try validateTemplate(template, node: node)
        var remainder = template[...]
        var result = ""
        var resultByteCount = 0
        while let opening = remainder.range(of: "{{") {
            try appendTemplateFragment(
                remainder[..<opening.lowerBound], to: &result, byteCount: &resultByteCount, node: node
            )
            guard let closing = remainder[opening.upperBound...].range(of: "}}") else {
                throw WorkflowIssue("Template marker is malformed.", nodeID: node.id)
            }
            let name = String(remainder[opening.upperBound..<closing.lowerBound])
            guard let value = fields[name] else {
                throw WorkflowIssue("Template field is missing: \(name).", nodeID: node.id, port: name)
            }
            try appendTemplateFragment(
                try scalarText(value, field: name, node: node),
                to: &result,
                byteCount: &resultByteCount,
                node: node
            )
            remainder = remainder[closing.upperBound...]
        }
        try appendTemplateFragment(remainder, to: &result, byteCount: &resultByteCount, node: node)
        return result
    }

    static func appendTemplateFragment<S: StringProtocol>(
        _ fragment: S,
        to result: inout String,
        byteCount: inout Int,
        node: WorkflowNode
    ) throws {
        let fragmentByteCount = fragment.utf8.count
        guard fragmentByteCount <= maximumTextBytes - byteCount else {
            throw WorkflowIssue("Rendered template text is too long.", nodeID: node.id)
        }
        result.append(contentsOf: fragment)
        byteCount += fragmentByteCount
    }

    static func scalarText(_ value: WorkflowDatum, field: String, node: WorkflowNode) throws -> String {
        switch value {
        case .text(let text): return text
        case .number(let number, _): return String(number)
        case .boolean(let flag): return flag ? "true" : "false"
        case .enumeration(let choice, _): return choice
        default: throw WorkflowIssue("Template field must be Text, Number, Bool, or Enum.", nodeID: node.id, port: field)
        }
    }

    static func validateListNode(_ node: WorkflowNode) throws {
        let mode = try WorkflowScalarReader.text("mode", in: node)
        guard mode == "items" || mode == "concat" else {
            throw WorkflowIssue("List mode must be items or concat.", nodeID: node.id)
        }
    }

    static func validateFilterNode(_ node: WorkflowNode) throws {
        _ = try flag("ascending", in: node)
        let limit = try WorkflowScalarReader.integer("limit", in: node)
        guard (0 ... 4_096).contains(limit) else {
            throw WorkflowIssue("Filter limit must be between 0 and 4096.", nodeID: node.id)
        }
    }

    // Missing preserves old nodes; a configured constraint is never inferred from prose.
    static func expectedItemCount(in node: WorkflowNode) throws -> Int? {
        guard let parameter = node.parameters["expectedItemCount"] else { return nil }
        guard case .integer(let count) = parameter, (-1...4096).contains(count) else {
            throw WorkflowIssue("List item count must be -1 (unrestricted) or 0...4096.", nodeID: node.id)
        }
        guard count != -1 else { return nil }
        guard case .list = node.dataConfiguration?.schema else {
            throw WorkflowIssue("An item-count constraint requires a List schema.", nodeID: node.id)
        }
        return count
    }

    static func validateRules(
        _ rules: [WorkflowDataRule],
        against element: WorkflowDataSchema,
        node: WorkflowNode
    ) throws {
        guard rules.count <= 256 else {
            throw WorkflowIssue("Filter has too many rules.", nodeID: node.id)
        }
        for rule in rules {
            try validatePath(rule.path, node: node)
            if rule.comparison == .exists {
                // Missing and absent optional fields are valid existence queries and evaluate false at runtime.
                continue
            }
            let fieldSchema = try schema(at: rule.path, in: element, node: node)
            guard let value = rule.value else {
                throw WorkflowIssue("Comparison is missing its right value.", nodeID: node.id)
            }
            try value.validate(as: fieldSchema)
            switch rule.comparison {
            case .less, .lessOrEqual, .greater, .greaterOrEqual:
                guard isNumber(fieldSchema), case .number = value else {
                    throw WorkflowIssue("Ordered comparison requires a number with the field's unit.", nodeID: node.id)
                }
            case .equals, .notEquals, .exists:
                break
            }
        }
    }

    static func isNumber(_ schema: WorkflowDataSchema) -> Bool {
        switch schema {
        case .number: return true
        case .optional(let inner): return isNumber(inner)
        default: return false
        }
    }

    static func validateSelectNode(_ node: WorkflowNode) throws {
        let method = try WorkflowScalarReader.text("method", in: node)
        guard method == "id" || method == "index" else {
            throw WorkflowIssue("Selection method must be id or index.", nodeID: node.id)
        }
        _ = try WorkflowScalarReader.text("itemID", in: node)
        _ = try WorkflowScalarReader.integer("index", in: node)
    }

    static func schema(at path: [String], in root: WorkflowDataSchema, node: WorkflowNode) throws -> WorkflowDataSchema {
        var current = root
        for part in path {
            guard case .record(let fields) = current,
                  let field = fields.first(where: { $0.name == part }) else {
                throw WorkflowIssue("Configured path does not exist in the schema: \(part).", nodeID: node.id)
            }
            current = field.type
        }
        return current
    }

    static func requireSortable(_ schema: WorkflowDataSchema, node: WorkflowNode) throws {
        switch schema {
        case .text, .number, .boolean, .enumeration: return
        default: throw WorkflowIssue("Sort key must be Text, Number, Bool, or Enum.", nodeID: node.id)
        }
    }

    static func sortKey(_ value: WorkflowDatum, node: WorkflowNode) throws -> SortKey {
        switch value {
        case .text(let value): return .text(value)
        case .number(let value, _): return .number(value)
        case .boolean(let value): return .boolean(value)
        case .enumeration(let value, let choices):
            guard let index = choices.firstIndex(of: value) else {
                throw WorkflowIssue("Enum sort key is invalid.", nodeID: node.id)
            }
            return .enumeration(index)
        default: throw WorkflowIssue("Sort key must be Text, Number, Bool, or Enum.", nodeID: node.id)
        }
    }

    static func compare(_ left: SortKey, _ right: SortKey) -> Int {
        switch (left, right) {
        case (.text(let lhs), .text(let rhs)): return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
        case (.number(let lhs), .number(let rhs)): return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
        case (.boolean(let lhs), .boolean(let rhs)): return lhs == rhs ? 0 : (lhs ? 1 : -1)
        case (.enumeration(let lhs), .enumeration(let rhs)): return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
        default: return 0
        }
    }

    static func requirePairKey(_ schema: WorkflowDataSchema, node: WorkflowNode) throws {
        switch schema {
        case .text, .number, .boolean, .enumeration: return
        default: throw WorkflowIssue("Pair key must be Text, Number, Bool, or Enum.", nodeID: node.id)
        }
    }

    static func pairKey(_ value: WorkflowDatum, node: WorkflowNode) throws -> PairKey {
        switch value {
        case .text(let value): return .text(value)
        case .number(let value, let unit): return .number(value, unit)
        case .boolean(let value): return .boolean(value)
        case .enumeration(let value, let choices): return .enumeration(value, choices)
        default: throw WorkflowIssue("Pair key must be Text, Number, Bool, or Enum.", nodeID: node.id)
        }
    }

    static func uniqueKeys(
        _ items: [WorkflowDataItem],
        path: [String],
        schema: WorkflowDataSchema,
        side: String,
        node: WorkflowNode
    ) throws -> [(key: PairKey, item: WorkflowDataItem)] {
        var seen: Set<PairKey> = []
        return try items.map { item in
            let value = try item.value.value(at: path)
            try value.validate(as: schema)
            let key = try pairKey(value, node: node)
            guard seen.insert(key).inserted else {
                throw WorkflowIssue("Duplicate \(side) pair key.", nodeID: node.id)
            }
            return (key, item)
        }
    }
}
