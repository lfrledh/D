import DWorkbench
import Foundation
import SwiftUI

@MainActor
private func workflowFormText(
    _ store: UILanguageStore?,
    _ key: String,
    fallback: String,
    arguments: [String: String] = [:]
) -> String {
    store?.text(key, fallback: fallback, arguments: arguments)
        ?? LanguagePackCodec.render(fallback, arguments: arguments)
}

@MainActor
private func workflowFormSchemaName(_ schema: WorkflowDataSchema, language: UILanguageStore?) -> String {
    let key: String
    let fallback: String
    var arguments: [String: String] = [:]
    switch schema {
    case .text: key = "workflow.language.form.type.text"; fallback = "Text"
    case .number(let unit):
        if let unit {
            key = "workflow.language.form.type.numberUnit"; fallback = "Number ({unit})"; arguments["unit"] = unit
        } else {
            key = "workflow.language.form.type.number"; fallback = "Number"
        }
    case .boolean: key = "workflow.language.form.type.boolean"; fallback = "Bool"
    case .enumeration: key = "workflow.language.form.type.enumeration"; fallback = "Enum"
    case .record: key = "workflow.language.form.type.record"; fallback = "Record"
    case .list: key = "workflow.language.form.type.list"; fallback = "List"
    case .optional: key = "workflow.language.form.type.optional"; fallback = "Optional"
    case .result: key = "workflow.language.form.type.result"; fallback = "Result"
    case .asset(let kind):
        key = "workflow.language.form.type.asset"; fallback = "Asset ({kind})"; arguments["kind"] = kind.rawValue
    }
    return workflowFormText(language, key, fallback: fallback, arguments: arguments)
}

enum WorkflowDatumSeedKind: String, CaseIterable, Identifiable {
    case text, number, boolean, enumeration, record, list, optional
    var id: String { rawValue }

    var schema: WorkflowDataSchema {
        switch self {
        case .text: .text
        case .number: .number(unit: nil)
        case .boolean: .boolean
        case .enumeration: .enumeration([])
        case .record: .record([])
        case .list: .list(.text)
        case .optional: .optional(.text)
        }
    }

    var seed: WorkflowDatum? {
        switch self {
        case .text: .text("")
        case .number: .number(0, unit: nil)
        case .boolean: .boolean(false)
        case .enumeration: nil
        case .record: .record(schema: [], fields: [:])
        case .list: .list(element: .text, items: [])
        case .optional: .none(.text)
        }
    }
}

struct WorkflowDatumFormState: Equatable {
    var numberDraft: String
    var error: String?

    init(numberDraft: String = "", error: String? = nil) {
        self.numberDraft = numberDraft
        self.error = error
    }

    mutating func updateNumber(_ draft: String, unit: String?, current: WorkflowDatum?) -> WorkflowDatum? {
        numberDraft = draft
        guard let number = Double(draft), number.isFinite else {
            error = "Number is incomplete or invalid."
            return current
        }
        error = nil
        return .number(number, unit: unit)
    }
}

struct WorkflowEnumerationFormState: Equatable {
    var choices: [String]
    var choiceDraft: String
    var selected: String?
    var isIncomplete: Bool

    init(value: WorkflowDatum?, choices: [String]) {
        self.choices = choices
        choiceDraft = ""
        if case .enumeration(let selected, let committedChoices)? = value,
           committedChoices == choices,
           choices.contains(selected) {
            self.selected = selected
            isIncomplete = false
        } else {
            self.selected = nil
            isIncomplete = true
        }
    }

    var candidate: WorkflowDatum? {
        guard !choices.isEmpty, Set(choices).count == choices.count,
              let selected, choices.contains(selected) else { return nil }
        let candidate = WorkflowDatum.enumeration(selected, choices: choices)
        guard (try? candidate.validate()) != nil else { return nil }
        return candidate
    }

    mutating func select(_ choice: String) -> WorkflowDatum? {
        guard choices.contains(choice) else { return nil }
        selected = choice
        return refreshCandidate()
    }

    mutating func addDraftChoice() -> WorkflowDatum? {
        guard !choiceDraft.isEmpty, !choices.contains(choiceDraft) else { return nil }
        choices.append(choiceDraft)
        choiceDraft = ""
        return refreshCandidate()
    }

    mutating func remove(_ choice: String) -> WorkflowDatum? {
        choices.removeAll { $0 == choice }
        if selected == choice { selected = nil }
        return refreshCandidate()
    }

    private mutating func refreshCandidate() -> WorkflowDatum? {
        let next = candidate
        isIncomplete = next == nil
        return next
    }
}

struct WorkflowNamedRowFormState: Equatable, Identifiable {
    let id: String
    var nameDraft: String
    var hasInvalidName: Bool

    init(id: String) {
        self.id = id
        nameDraft = id
        hasInvalidName = false
    }

    mutating func proposeName(_ next: String, siblingNames: Set<String>) -> String? {
        nameDraft = next
        guard !next.isEmpty, next.utf8.count <= 256, !siblingNames.contains(next) else {
            hasInvalidName = true
            return nil
        }
        hasInvalidName = false
        return next
    }
}

struct WorkflowStableNamedRow: Equatable, Identifiable {
    let id: UUID
    var fieldName: String

    init(id: UUID = UUID(), fieldName: String) {
        self.id = id
        self.fieldName = fieldName
    }
}

struct WorkflowStableNamedRows: Equatable {
    var rows: [WorkflowStableNamedRow]

    init(names: [String]) {
        rows = names.map { WorkflowStableNamedRow(fieldName: $0) }
    }

    mutating func append(_ name: String) {
        rows.append(WorkflowStableNamedRow(fieldName: name))
    }

    mutating func rename(id: UUID, to name: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].fieldName = name
    }

    mutating func remove(id: UUID) {
        rows.removeAll { $0.id == id }
    }
}

enum WorkflowFormSupport {
    /// Suggestions from the connected, declared data only. This does not execute
    /// upstream nodes or turn labels/history into a validation schema.
    static func connectedRecordFields(nodeID: UUID, graph: WorkflowGraph?, tools: [WorkflowToolDefinition]) -> [WorkflowRecordField] {
        guard let graph else { return [] }
        func inputSchema(_ id: UUID, visited: Set<UUID>) -> WorkflowDataSchema? {
            let edges = graph.connections.filter { $0.targetNode == id && $0.targetPort == "input" }
            guard edges.count == 1, let edge = edges.first else { return nil }
            return outputSchema(edge.sourceNode, port: edge.sourcePort, visited: visited)
        }
        func outputSchema(_ id: UUID, port: String, visited: Set<UUID>) -> WorkflowDataSchema? {
            guard visited.count < 64, !visited.contains(id), let source = graph.nodes.first(where: { $0.id == id }) else { return nil }
            let next = visited.union([id])
            if case .invoke(let reference) = source.control {
                guard let tool = tools.first(where: { $0.id == reference.id && $0.version == reference.version }),
                      (try? WorkflowPlanCompiler.digest(tool)) == reference.digest else { return nil }
                return tool.graph.interface?.outputs.first(where: { $0.name == port })?.schema
            }
            guard port == "output" else { return nil }
            switch source.operationID {
            case "d.value.input":
                if let name = source.parameters["publicName"]?.string, !name.isEmpty,
                   let field = graph.interface?.inputs.first(where: { $0.name == name }) { return field.type }
                return source.dataConfiguration?.value?.schema
            case "d.value.record": return .record(source.dataConfiguration?.fields ?? [])
            case "d.value.validate": return source.dataConfiguration?.schema.map { WorkflowDataConfiguration.validationReportSchema(for: $0) }
            case "d.value.field", "d.control.human": return source.dataConfiguration?.schema
            case "d.model.language", WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38: return source.parameters["outputMode"]?.string == "json" ? source.dataConfiguration?.schema : .text
            case "d.value.return", "d.value.filter": return inputSchema(id, visited: next)
            default: return nil
            }
        }
        guard let schema = inputSchema(nodeID, visited: [nodeID]), (try? schema.validateDefinition()) != nil else { return [] }
        if case .record(let fields) = schema { return fields }
        if case .list(.record(let fields)) = schema { return fields }
        return []
    }

    static func isReadOnlyDepth(_ depth: Int) -> Bool { depth >= 8 }

    static func seed(for schema: WorkflowDataSchema) -> WorkflowDatum? {
        switch schema {
        case .text: .text("")
        case .number(let unit): .number(0, unit: unit)
        case .boolean: .boolean(false)
        case .enumeration: nil
        case .record(let fields): .record(schema: fields, fields: [:])
        case .list(let element): .list(element: element, items: [])
        case .optional(let inner): .none(inner)
        case .asset, .result: nil
        }
    }

    static func schemaName(_ schema: WorkflowDataSchema) -> String {
        switch schema {
        case .text: "Text"
        case .number(let unit): unit.map { "Number (\($0))" } ?? "Number"
        case .boolean: "Bool"
        case .enumeration: "Enum"
        case .record: "Record"
        case .list: "List"
        case .optional: "Optional"
        case .result: "Result"
        case .asset(let kind): "Asset (\(kind.rawValue))"
        }
    }

    static func validationError(_ value: WorkflowDatum?, as schema: WorkflowDataSchema) -> String? {
        guard let value else { return "A value is required." }
        do {
            try value.validate(as: schema)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func validatedExplicitValue(_ value: WorkflowDatum?, as schema: WorkflowDataSchema) -> WorkflowDatum? {
        guard validationError(value, as: schema) == nil else { return nil }
        return value
    }

    static func appendingExplicitItem(
        to items: [WorkflowDataItem],
        schema: WorkflowDataSchema,
        id: String,
        value: WorkflowDatum?
    ) -> [WorkflowDataItem]? {
        guard !id.isEmpty, !items.contains(where: { $0.id == id }),
              let value = validatedExplicitValue(value, as: schema) else { return nil }
        return items + [WorkflowDataItem(id: id, value: value)]
    }

    static func moved(_ items: [WorkflowDataItem], from index: Int, by offset: Int) -> [WorkflowDataItem] {
        let destination = index + offset
        guard items.indices.contains(index), items.indices.contains(destination) else { return items }
        var result = items
        result.swapAt(index, destination)
        return result
    }

    static func appendingItem(to items: [WorkflowDataItem], schema: WorkflowDataSchema, id: String = UUID().uuidString) -> [WorkflowDataItem]? {
        guard !id.isEmpty, !items.contains(where: { $0.id == id }), let value = seed(for: schema) else { return nil }
        return items + [WorkflowDataItem(id: id, value: value)]
    }

    static func schema(at path: [String], in root: WorkflowDataSchema) -> WorkflowDataSchema? {
        var current = root
        for component in path {
            guard case .record(let fields) = current,
                  let field = fields.first(where: { $0.name == component }) else { return nil }
            current = field.type
        }
        return current
    }

    static func recordPaths(in fields: [WorkflowRecordField], maximumDepth: Int = 8) -> [[String]] {
        func visit(_ fields: [WorkflowRecordField], prefix: [String], depth: Int) -> [[String]] {
            guard depth < maximumDepth else { return [] }
            return fields.flatMap { field -> [[String]] in
                let path = prefix + [field.name]
                if case .record(let nested) = field.type {
                    return [path] + visit(nested, prefix: path, depth: depth + 1)
                }
                return [path]
            }
        }
        return visit(fields, prefix: [], depth: 0)
    }

    static func replacingField(
        in configuration: WorkflowDataConfiguration,
        at index: Int,
        name: String? = nil,
        type: WorkflowDataSchema? = nil,
        required: Bool? = nil
    ) throws -> WorkflowDataConfiguration {
        guard configuration.fields.indices.contains(index) else { return configuration }
        var result = configuration
        let old = result.fields[index]
        let nextName = name ?? old.name
        let nextType = type ?? old.type
        let nextRequired = required ?? old.required
        try nextType.validateDefinition()
        guard !nextName.isEmpty, nextName.utf8.count <= 256,
              !result.fields.enumerated().contains(where: { $0.offset != index && $0.element.name == nextName }) else {
            throw WorkflowIssue("Field names must be nonempty and unique.")
        }

        var fallbackFields: [String: WorkflowDatum] = [:]
        if case .record(_, let fields)? = result.value { fallbackFields = fields }
        if let fallback = fallbackFields.removeValue(forKey: old.name) {
            try fallback.validate(as: nextType)
            fallbackFields[nextName] = fallback
        }
        result.fields[index] = WorkflowRecordField(nextName, nextType, required: nextRequired)
        result.value = .record(schema: result.fields, fields: fallbackFields)
        return result
    }
}

@MainActor
struct WorkflowDatumSnapshotView: View {
    let value: WorkflowDatum
    @State private var generation = UUID()

    var body: some View {
        WorkflowDatumEditor(value: .constant(value)).disabled(true)
            .id(generation)
            // Editors deliberately keep incomplete drafts. A published result
            // has no draft: replace only this read-only subtree on a new value.
            // Unchanged results, neighboring editors and the inspector retain identity.
            .onChange(of: value) { _, _ in generation = UUID() }
    }
}

@MainActor
struct WorkflowDatumEditor: View {
    @Binding private var value: WorkflowDatum?
    private let allowsTypeSelection: Bool
    @State private var selectedSchema: WorkflowDataSchema?
    @Environment(\.dLanguageStore) private var languageStore

    init(value: Binding<WorkflowDatum?>, allowsTypeSelection: Bool = true) {
        _value = value
        self.allowsTypeSelection = allowsTypeSelection
        _selectedSchema = State(initialValue: value.wrappedValue?.schema)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if allowsTypeSelection {
                Menu(workflowFormText(languageStore, "workflow.language.form.type", fallback: "Type")) {
                    ForEach(WorkflowDatumSeedKind.allCases) { kind in
                        Button(typeTitle(kind)) { select(kind) }
                    }
                }
                .accessibilityIdentifier("workflow-language-form-type")
            }
            if let schema = selectedSchema ?? value?.schema {
                WorkflowDatumValueEditor(value: synchronizedValue, schema: schema, depth: 0, allowsSchemaEditing: true)
            } else {
                Text(workflowFormText(
                    languageStore,
                    "workflow.language.form.empty",
                    fallback: "No value. Choose a type to create one."
                ))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var synchronizedValue: Binding<WorkflowDatum?> {
        Binding(get: { value }, set: { next in
            value = next
            if case .optional? = selectedSchema {
                if case .none(let inner)? = next { selectedSchema = .optional(inner) }
                return
            }
            if let next { selectedSchema = next.schema }
        })
    }

    private func select(_ kind: WorkflowDatumSeedKind) {
        selectedSchema = kind.schema
        value = kind.seed
    }

    private func typeTitle(_ kind: WorkflowDatumSeedKind) -> String {
        workflowFormText(
            languageStore,
            "workflow.language.form.type.\(kind.rawValue)",
            fallback: kind.rawValue.capitalized
        )
    }
}

@MainActor
struct WorkflowDatumValueEditor: View {
    @Binding var value: WorkflowDatum?
    let schema: WorkflowDataSchema
    let depth: Int
    var allowsSchemaEditing = false

    @ViewBuilder var body: some View {
        if WorkflowFormSupport.isReadOnlyDepth(depth) {
            WorkflowReadOnlyDatum(value: value, reasonKey: "workflow.language.form.depthLimit")
        } else {
            switch schema {
            case .text:
                TextEditor(text: Binding(
                    get: { value?.text ?? "" },
                    set: { value = .text($0) }
                ))
                .frame(minHeight: 64)
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
            case .number(let unit):
                WorkflowNumberDatumEditor(value: $value, unit: unit, allowsUnitEditing: allowsSchemaEditing)
            case .boolean:
                Toggle("", isOn: Binding(
                    get: { if case .boolean(let flag)? = value { flag } else { false } },
                    set: { value = .boolean($0) }
                )).labelsHidden()
            case .enumeration(let choices):
                WorkflowEnumerationDatumEditor(
                    value: $value, initialChoices: choices, allowsOptionsEditing: allowsSchemaEditing
                )
            case .record(let fields):
                WorkflowRecordDatumEditor(
                    value: $value, fields: fields, depth: depth, allowsSchemaEditing: allowsSchemaEditing
                )
            case .list(let element):
                WorkflowListDatumEditor(
                    value: $value, element: element, depth: depth, allowsSchemaEditing: allowsSchemaEditing
                )
            case .optional(let inner):
                WorkflowOptionalDatumEditor(
                    value: $value, inner: inner, depth: depth, allowsSchemaEditing: allowsSchemaEditing
                )
            case .asset, .result:
                WorkflowReadOnlyDatum(value: value, reasonKey: "workflow.language.form.readOnly")
            }
        }
    }
}

@MainActor
private struct WorkflowNumberDatumEditor: View {
    @Binding var value: WorkflowDatum?
    let unit: String?
    let allowsUnitEditing: Bool
    @State private var state: WorkflowDatumFormState
    @State private var unitDraft: String
    @Environment(\.dLanguageStore) private var languageStore

    init(value: Binding<WorkflowDatum?>, unit: String?, allowsUnitEditing: Bool) {
        _value = value
        self.unit = unit
        self.allowsUnitEditing = allowsUnitEditing
        let initial: String
        if case .number(let number, _)? = value.wrappedValue { initial = String(number) } else { initial = "" }
        _state = State(initialValue: WorkflowDatumFormState(numberDraft: initial))
        _unitDraft = State(initialValue: unit ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(workflowFormText(languageStore, "workflow.language.form.number", fallback: "Number"), text: Binding(
                get: { state.numberDraft },
                set: { value = state.updateNumber($0, unit: normalizedUnit, current: value) }
            ))
            if allowsUnitEditing {
                TextField(workflowFormText(languageStore, "workflow.language.form.unit", fallback: "Unit (optional)"), text: Binding(
                    get: { unitDraft },
                    set: { draft in
                        unitDraft = draft
                        if case .number(let number, _)? = value { value = .number(number, unit: normalizedUnit) }
                    }
                ))
            } else if let unit {
                Text(unit).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if state.error != nil {
                Text(workflowFormText(languageStore, "workflow.language.form.invalidNumber", fallback: "Enter a complete finite number."))
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var normalizedUnit: String? { unitDraft.isEmpty ? nil : unitDraft }
}

@MainActor
private struct WorkflowEnumerationDatumEditor: View {
    @Binding var value: WorkflowDatum?
    let allowsOptionsEditing: Bool
    @State private var state: WorkflowEnumerationFormState
    @Environment(\.dLanguageStore) private var languageStore

    init(value: Binding<WorkflowDatum?>, initialChoices: [String], allowsOptionsEditing: Bool) {
        _value = value
        self.allowsOptionsEditing = allowsOptionsEditing
        _state = State(initialValue: WorkflowEnumerationFormState(value: value.wrappedValue, choices: initialChoices))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.choices, id: \.self) { choice in
                HStack {
                    Button {
                        publish(state.select(choice))
                    } label: {
                        Label(choice, systemImage: state.selected == choice ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if allowsOptionsEditing {
                        Button(role: .destructive) {
                            publish(state.remove(choice))
                        } label: { Image(systemName: "minus.circle") }
                    }
                }
            }
            if allowsOptionsEditing {
                HStack {
                    TextField(workflowFormText(languageStore, "workflow.language.form.enumOption", fallback: "New option"), text: $state.choiceDraft)
                    Button(workflowFormText(languageStore, "workflow.language.form.add", fallback: "Add")) { addChoice() }
                        .disabled(state.choiceDraft.isEmpty || state.choices.contains(state.choiceDraft))
                }
            }
            if state.isIncomplete {
                Text(workflowFormText(
                    languageStore,
                    "workflow.language.form.enumIncomplete",
                    fallback: "Add unique options and explicitly select one."
                )).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func addChoice() {
        publish(state.addDraftChoice())
    }

    private func publish(_ candidate: WorkflowDatum?) {
        guard let candidate else { return }
        value = candidate
    }
}

@MainActor
private struct WorkflowRecordDatumEditor: View {
    @Binding var value: WorkflowDatum?
    let fields: [WorkflowRecordField]
    let depth: Int
    let allowsSchemaEditing: Bool
    @State private var newFieldName = ""
    @State private var error: String?
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(field.name).font(.callout.weight(.medium))
                        if !field.required {
                            Text(workflowFormText(languageStore, "workflow.language.form.optional", fallback: "Optional"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if allowsSchemaEditing {
                            Button(role: .destructive) { removeField(index) } label: { Image(systemName: "minus.circle") }
                        }
                    }
                    if allowsSchemaEditing {
                        WorkflowSchemaEditor(schema: Binding(get: { field.type }, set: { next in
                            if let next { updateFieldType(index, to: next) }
                        }), depth: depth + 1)
                    }
                    if field.required || fieldValue(field).wrappedValue != nil {
                        AnyView(WorkflowDatumValueEditor(value: fieldValue(field), schema: field.type, depth: depth + 1))
                    } else {
                        Button(workflowFormText(
                            languageStore,
                            "workflow.language.form.addOptionalValue",
                            fallback: "Add optional value"
                        )) {
                            guard let seed = WorkflowFormSupport.seed(for: field.type) else {
                                error = workflowFormText(
                                    languageStore,
                                    "workflow.language.form.noSeed",
                                    fallback: "Define a valid value before continuing."
                                )
                                return
                            }
                            fieldValue(field).wrappedValue = seed
                        }
                    }
                }
                .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
            if allowsSchemaEditing {
                HStack {
                    TextField(workflowFormText(languageStore, "workflow.language.form.fieldName", fallback: "Field name"), text: $newFieldName)
                    Button(workflowFormText(languageStore, "workflow.language.form.addField", fallback: "Add field")) { addField() }
                        .disabled(newFieldName.isEmpty || fields.contains(where: { $0.name == newFieldName }))
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func fieldValue(_ field: WorkflowRecordField) -> Binding<WorkflowDatum?> {
        Binding(get: {
            guard case .record(_, let values)? = value else { return nil }
            return values[field.name]
        }, set: { next in
            var values: [String: WorkflowDatum] = [:]
            if case .record(_, let existing)? = value { values = existing }
            values[field.name] = next
            value = .record(schema: fields, fields: values)
        })
    }

    private func addField() {
        guard !newFieldName.isEmpty, !fields.contains(where: { $0.name == newFieldName }) else { return }
        let nextFields = fields + [WorkflowRecordField(newFieldName, .text, required: false)]
        var values: [String: WorkflowDatum] = [:]
        if case .record(_, let existing)? = value { values = existing }
        value = .record(schema: nextFields, fields: values)
        newFieldName = ""
        error = nil
    }

    private func removeField(_ index: Int) {
        guard fields.indices.contains(index) else { return }
        let removed = fields[index]
        var nextFields = fields
        nextFields.remove(at: index)
        var values: [String: WorkflowDatum] = [:]
        if case .record(_, let existing)? = value { values = existing }
        values.removeValue(forKey: removed.name)
        value = .record(schema: nextFields, fields: values)
    }

    private func updateFieldType(_ index: Int, to type: WorkflowDataSchema) {
        guard fields.indices.contains(index) else { return }
        do {
            try type.validateDefinition()
            let old = fields[index]
            var values: [String: WorkflowDatum] = [:]
            if case .record(_, let existing)? = value { values = existing }
            if let current = values[old.name] { try current.validate(as: type) }
            var nextFields = fields
            nextFields[index] = WorkflowRecordField(old.name, type, required: old.required)
            value = .record(schema: nextFields, fields: values)
            error = nil
        } catch {
            self.error = workflowFormText(
                languageStore,
                "workflow.language.form.invalidEdit",
                fallback: "The edit is invalid; the previous valid configuration was preserved."
            )
        }
    }
}

@MainActor
private struct WorkflowListDatumEditor: View {
    @Binding var value: WorkflowDatum?
    let element: WorkflowDataSchema
    let depth: Int
    let allowsSchemaEditing: Bool
    @State private var elementDraft: WorkflowDataSchema?
    @State private var error: String?
    @State private var pendingItemID: String?
    @State private var pendingItemValue: WorkflowDatum?
    @Environment(\.dLanguageStore) private var languageStore

    init(value: Binding<WorkflowDatum?>, element: WorkflowDataSchema, depth: Int, allowsSchemaEditing: Bool) {
        _value = value
        self.element = element
        self.depth = depth
        self.allowsSchemaEditing = allowsSchemaEditing
        _elementDraft = State(initialValue: element)
        _pendingItemID = State(initialValue: nil)
        _pendingItemValue = State(initialValue: nil)
    }

    private var items: [WorkflowDataItem] {
        if case .list(_, let items)? = value { return items }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if allowsSchemaEditing {
                WorkflowSchemaEditor(schema: Binding(get: { elementDraft }, set: { next in
                    elementDraft = next
                    if let next { updateElementSchema(next) }
                }), depth: depth + 1)
            }
            Text(workflowFormText(
                languageStore,
                "workflow.language.form.listElement",
                fallback: "Element: {type}",
                arguments: ["type": workflowFormSchemaName(element, language: languageStore)]
            )).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.id).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { setItems(WorkflowFormSupport.moved(items, from: index, by: -1)) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0)
                        Button { setItems(WorkflowFormSupport.moved(items, from: index, by: 1)) } label: { Image(systemName: "arrow.down") }
                            .disabled(index + 1 == items.count)
                        Button(role: .destructive) {
                            var next = items; next.remove(at: index); setItems(next)
                        } label: { Image(systemName: "minus.circle") }
                    }
                    AnyView(WorkflowDatumValueEditor(value: itemValue(item.id), schema: element, depth: depth + 1))
                }
                .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
            if pendingItemID != nil {
                VStack(alignment: .leading, spacing: 5) {
                    WorkflowDatumValueEditor(value: $pendingItemValue, schema: element, depth: depth + 1)
                    HStack {
                        Button(workflowFormText(languageStore, "workflow.language.form.finishItem", fallback: "Add this item")) {
                            commitPendingItem()
                        }.disabled(WorkflowFormSupport.validationError(pendingItemValue, as: element) != nil)
                        Button(workflowFormText(languageStore, "workflow.language.form.cancelPending", fallback: "Cancel")) {
                            pendingItemID = nil; pendingItemValue = nil; error = nil
                        }
                    }
                }
                .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            } else {
                Button(workflowFormText(languageStore, "workflow.language.form.addItem", fallback: "Add item")) {
                    beginAddingItem()
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func itemValue(_ id: String) -> Binding<WorkflowDatum?> {
        Binding(get: { items.first(where: { $0.id == id })?.value }, set: { next in
            guard let next, let index = items.firstIndex(where: { $0.id == id }) else { return }
            var updated = items
            updated[index].value = next
            setItems(updated)
        })
    }

    private func setItems(_ items: [WorkflowDataItem]) { value = .list(element: element, items: items) }

    private func beginAddingItem() {
        if let next = WorkflowFormSupport.appendingItem(to: items, schema: element) {
            setItems(next); error = nil
            return
        }
        guard case .enumeration = element else {
            error = workflowFormText(
                languageStore,
                "workflow.language.form.noSeed",
                fallback: "Define a valid element value before adding an item."
            )
            return
        }
        pendingItemID = UUID().uuidString
        pendingItemValue = nil
        error = nil
    }

    private func commitPendingItem() {
        guard let id = pendingItemID,
              let next = WorkflowFormSupport.appendingExplicitItem(
                to: items, schema: element, id: id, value: pendingItemValue
              ) else { return }
        setItems(next)
        self.pendingItemID = nil
        self.pendingItemValue = nil
        error = nil
    }

    private func updateElementSchema(_ next: WorkflowDataSchema) {
        do {
            for item in items { try item.value.validate(as: next) }
            value = .list(element: next, items: items)
            error = nil
        } catch {
            self.error = workflowFormText(
                languageStore,
                "workflow.language.form.invalidEdit",
                fallback: "The edit is invalid; the previous valid configuration was preserved."
            )
        }
    }
}

@MainActor
private struct WorkflowOptionalDatumEditor: View {
    @Binding var value: WorkflowDatum?
    let inner: WorkflowDataSchema
    let depth: Int
    let allowsSchemaEditing: Bool
    @State private var innerDraft: WorkflowDataSchema?
    @State private var error: String?
    @State private var pendingPresentValue: WorkflowDatum?
    @State private var isCreatingPresentValue: Bool
    @Environment(\.dLanguageStore) private var languageStore

    init(value: Binding<WorkflowDatum?>, inner: WorkflowDataSchema, depth: Int, allowsSchemaEditing: Bool) {
        _value = value
        self.inner = inner
        self.depth = depth
        self.allowsSchemaEditing = allowsSchemaEditing
        _innerDraft = State(initialValue: inner)
        _pendingPresentValue = State(initialValue: nil)
        _isCreatingPresentValue = State(initialValue: false)
    }

    private var isPresent: Bool {
        if case .none? = value { return false }
        return value != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if allowsSchemaEditing {
                WorkflowSchemaEditor(schema: Binding(get: { innerDraft }, set: { next in
                    innerDraft = next
                    if let next { updateInnerSchema(next) }
                }), depth: depth + 1)
            }
            Toggle(workflowFormText(languageStore, "workflow.language.form.present", fallback: "Value is present"), isOn: Binding(
                get: { isPresent || isCreatingPresentValue },
                set: { present in
                    if present {
                        if let seed = WorkflowFormSupport.seed(for: inner) {
                            value = seed
                            return
                        }
                        if case .enumeration = inner {
                            pendingPresentValue = nil
                            isCreatingPresentValue = true
                        } else {
                            error = workflowFormText(
                                languageStore,
                                "workflow.language.form.noSeed",
                                fallback: "Define a valid value before making it present."
                            )
                        }
                    } else {
                        value = .none(inner)
                        pendingPresentValue = nil
                        isCreatingPresentValue = false
                    }
                }
            ))
            if isCreatingPresentValue {
                WorkflowDatumValueEditor(value: $pendingPresentValue, schema: inner, depth: depth + 1)
                HStack {
                    Button(workflowFormText(languageStore, "workflow.language.form.usePendingValue", fallback: "Use this value")) {
                        guard let pendingPresentValue = WorkflowFormSupport.validatedExplicitValue(
                            pendingPresentValue, as: inner
                        ) else { return }
                        value = pendingPresentValue
                        self.pendingPresentValue = nil
                        isCreatingPresentValue = false
                        error = nil
                    }.disabled(WorkflowFormSupport.validationError(pendingPresentValue, as: inner) != nil)
                    Button(workflowFormText(languageStore, "workflow.language.form.cancelPending", fallback: "Cancel")) {
                        pendingPresentValue = nil
                        isCreatingPresentValue = false
                    }
                }
            } else if isPresent {
                AnyView(WorkflowDatumValueEditor(value: $value, schema: inner, depth: depth + 1))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func updateInnerSchema(_ next: WorkflowDataSchema) {
        if isPresent, next != inner {
            error = workflowFormText(
                languageStore,
                "workflow.language.form.optionalTypeWhilePresent",
                fallback: "Make the optional value absent before changing its wrapped type."
            )
            return
        }
        if !isPresent { value = .none(next) }
        error = nil
    }
}

@MainActor
private struct WorkflowReadOnlyDatum: View {
    let value: WorkflowDatum?
    let reasonKey: String
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.map { workflowFormSchemaName($0.schema, language: languageStore) } ?? "—")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text(workflowFormText(
                languageStore,
                reasonKey,
                fallback: reasonKey.hasSuffix("depthLimit")
                    ? "Nested data at depth 8 or greater is preserved read-only."
                    : "This value is available as a read-only preview."
            )).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct WorkflowSchemaEditor: View {
    @Binding private var schema: WorkflowDataSchema?
    let depth: Int
    @State private var draftSchema: WorkflowDataSchema?
    @State private var optionDraft = ""
    @State private var fieldDraft = ""
    @State private var recordRows: WorkflowStableNamedRows
    @Environment(\.dLanguageStore) private var languageStore

    init(schema: Binding<WorkflowDataSchema?>, depth: Int) {
        _schema = schema
        self.depth = depth
        _draftSchema = State(initialValue: schema.wrappedValue)
        let fieldNames: [String]
        if case .record(let fields)? = schema.wrappedValue {
            fieldNames = fields.map(\.name)
        } else {
            fieldNames = []
        }
        _recordRows = State(initialValue: WorkflowStableNamedRows(names: fieldNames))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if WorkflowFormSupport.isReadOnlyDepth(depth) {
                Text(draftSchema.map { workflowFormSchemaName($0, language: languageStore) } ?? "—")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(workflowFormText(languageStore, "workflow.language.form.depthLimit", fallback: "Nested data at depth 8 or greater is preserved read-only."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Menu(draftSchema.map { workflowFormSchemaName($0, language: languageStore) } ?? workflowFormText(
                    languageStore, "workflow.language.form.chooseSchema", fallback: "Choose schema"
                )) {
                    schemaButtons
                }
                if let draftSchema { schemaDetails(draftSchema) }
            }
        }
    }

    @ViewBuilder private var schemaButtons: some View {
        Button(workflowFormSchemaName(.text, language: languageStore)) { setDraft(.text) }
        Button(workflowFormSchemaName(.number(unit: nil), language: languageStore)) { setDraft(.number(unit: nil)) }
        Button(workflowFormSchemaName(.boolean, language: languageStore)) { setDraft(.boolean) }
        Button(workflowFormSchemaName(.enumeration([]), language: languageStore)) { setDraft(.enumeration([])) }
        Button(workflowFormSchemaName(.record([]), language: languageStore)) {
            recordRows = WorkflowStableNamedRows(names: [])
            setDraft(.record([]))
        }
        Button(workflowFormSchemaName(.list(.text), language: languageStore)) { setDraft(.list(.text)) }
        Button(workflowFormSchemaName(.optional(.text), language: languageStore)) { setDraft(.optional(.text)) }
        Button(workflowFormSchemaName(.result(.text), language: languageStore)) { setDraft(.result(.text)) }
        Menu(workflowFormText(languageStore, "workflow.language.form.type.asset", fallback: "Asset ({kind})", arguments: ["kind": "…"])) {
            ForEach([WorkflowDataKind.text, .image, .audio, .video, .notes, .chords, .tempo, .pitch], id: \.rawValue) { kind in
                Button(workflowFormText(
                    languageStore,
                    "workflow.language.form.assetKind.\(kind.rawValue)",
                    fallback: kind.rawValue.capitalized
                )) { setDraft(.asset(kind)) }
            }
        }
    }

    @ViewBuilder private func schemaDetails(_ current: WorkflowDataSchema) -> some View {
        switch current {
        case .number(let unit):
            TextField(workflowFormText(languageStore, "workflow.language.form.unit", fallback: "Unit (optional)"), text: Binding(
                get: { unit ?? "" }, set: { setDraft(.number(unit: $0.isEmpty ? nil : $0)) }
            ))
        case .enumeration(let options):
            ForEach(options, id: \.self) { option in
                HStack { Text(option); Spacer(); Button(role: .destructive) {
                    setDraft(.enumeration(options.filter { $0 != option }))
                } label: { Image(systemName: "minus.circle") } }
            }
            HStack {
                TextField(workflowFormText(languageStore, "workflow.language.form.enumOption", fallback: "New option"), text: $optionDraft)
                Button(workflowFormText(languageStore, "workflow.language.form.add", fallback: "Add")) {
                    guard !optionDraft.isEmpty, !options.contains(optionDraft) else { return }
                    setDraft(.enumeration(options + [optionDraft])); optionDraft = ""
                }.disabled(optionDraft.isEmpty || options.contains(optionDraft))
            }
        case .record(let fields):
            ForEach(recordRows.rows) { row in
                if let index = fields.firstIndex(where: { $0.name == row.fieldName }) {
                    let field = fields[index]
                    WorkflowSchemaRecordFieldRow(
                        field: field,
                        siblingNames: Set(fields.map(\.name)).subtracting([field.name]),
                        depth: depth
                    ) { updated in
                        var next = fields
                        next[index] = updated
                        setDraft(.record(next))
                        if updated.name != row.fieldName {
                            recordRows.rename(id: row.id, to: updated.name)
                        }
                    } onRemove: {
                        var next = fields
                        next.remove(at: index)
                        setDraft(.record(next))
                        recordRows.remove(id: row.id)
                    }
                }
            }
            HStack {
                TextField(workflowFormText(languageStore, "workflow.language.form.fieldName", fallback: "Field name"), text: $fieldDraft)
                Button(workflowFormText(languageStore, "workflow.language.form.addField", fallback: "Add field")) {
                    guard !fieldDraft.isEmpty, !fields.contains(where: { $0.name == fieldDraft }) else { return }
                    let name = fieldDraft
                    setDraft(.record(fields + [WorkflowRecordField(name, .text, required: false)]))
                    recordRows.append(name)
                    fieldDraft = ""
                }.disabled(fieldDraft.isEmpty || fields.contains(where: { $0.name == fieldDraft }))
            }
        case .list(let inner):
            nestedSchema(inner) { setDraft(.list($0)) }
        case .optional(let inner):
            nestedSchema(inner) { setDraft(.optional($0)) }
        case .result(let inner):
            nestedSchema(inner) { setDraft(.result($0)) }
        default: EmptyView()
        }
    }

    private func nestedSchema(_ current: WorkflowDataSchema, set: @escaping (WorkflowDataSchema) -> Void) -> some View {
        AnyView(WorkflowSchemaEditor(schema: Binding<WorkflowDataSchema?>(
            get: { current }, set: { if let next = $0 { set(next) } }
        ), depth: depth + 1)
        .padding(.leading, 10))
    }

    private func setDraft(_ next: WorkflowDataSchema) {
        draftSchema = next
        guard (try? next.validateDefinition()) != nil else { return }
        schema = next
    }
}

@MainActor
private struct WorkflowSchemaRecordFieldRow: View {
    let field: WorkflowRecordField
    let siblingNames: Set<String>
    let depth: Int
    let onChange: (WorkflowRecordField) -> Void
    let onRemove: () -> Void
    @State private var rowState: WorkflowNamedRowFormState
    @State private var typeDraft: WorkflowDataSchema?
    @Environment(\.dLanguageStore) private var languageStore

    init(
        field: WorkflowRecordField,
        siblingNames: Set<String>,
        depth: Int,
        onChange: @escaping (WorkflowRecordField) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.field = field
        self.siblingNames = siblingNames
        self.depth = depth
        self.onChange = onChange
        self.onRemove = onRemove
        _rowState = State(initialValue: WorkflowNamedRowFormState(id: field.name))
        _typeDraft = State(initialValue: field.type)
    }

    var body: some View {
        Group {
            if WorkflowFormSupport.isReadOnlyDepth(depth + 1) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.name).font(.callout.weight(.medium)).textSelection(.enabled)
                    Text(workflowFormSchemaName(field.type, language: languageStore))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text(workflowFormText(
                        languageStore,
                        "workflow.language.form.depthLimit",
                        fallback: "Nested data at depth 8 or greater is preserved read-only."
                    )).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        TextField(workflowFormText(languageStore, "workflow.language.form.fieldName", fallback: "Field name"), text: Binding(
                            get: { rowState.nameDraft }, set: { next in
                                guard let accepted = rowState.proposeName(next, siblingNames: siblingNames) else { return }
                                onChange(WorkflowRecordField(accepted, field.type, required: field.required))
                            }
                        ))
                        Toggle(workflowFormText(languageStore, "workflow.language.form.required", fallback: "Required"), isOn: Binding(
                            get: { field.required },
                            set: { onChange(WorkflowRecordField(field.name, field.type, required: $0)) }
                        ))
                        Button(role: .destructive, action: onRemove) { Image(systemName: "minus.circle") }
                    }
                    WorkflowSchemaEditor(schema: Binding(get: { typeDraft }, set: { next in
                        typeDraft = next
                        if let next { onChange(WorkflowRecordField(field.name, next, required: field.required)) }
                    }), depth: depth + 1)
                    .padding(.leading, 10)
                    if rowState.hasInvalidName {
                        Text(workflowFormText(
                            languageStore,
                            "workflow.language.form.invalidName",
                            fallback: "Names must be nonempty and unique; the previous name was preserved."
                        )).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

@MainActor
struct WorkflowNodeDataEditor: View {
    @Binding private var node: WorkflowNode
    private let availableRecordSchema: [WorkflowRecordField]
    @Environment(\.dLanguageStore) private var languageStore

    init(node: Binding<WorkflowNode>, availableRecordSchema: [WorkflowRecordField] = []) {
        _node = node
        self.availableRecordSchema = availableRecordSchema
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch node.operationID {
            case "d.value.input":
                WorkflowDatumEditor(value: configurationValue)
            case "d.value.template":
                WorkflowTemplateFallbackEditor(configuration: configuration)
            case "d.value.record":
                WorkflowRecordNodeEditor(configuration: configuration)
            case "d.value.field":
                WorkflowSchemaAndPathEditor(configuration: configuration, availableRecordSchema: availableRecordSchema, pathRequired: true)
            case "d.value.list":
                WorkflowListNodeEditor(configuration: configuration, mode: node.parameters["mode"]?.string ?? "")
            case "d.value.filter":
                WorkflowRulesNodeEditor(configuration: configuration, availableRecordSchema: availableRecordSchema)
            case "d.value.pair":
                WorkflowPathEditor(path: configurationPath, availableRecordSchema: availableRecordSchema, pathRequired: true)
            case "d.music.chords":
                WorkflowDatumEditor(value: configurationValue)
            case "d.value.validate":
                Picker(workflowFormText(languageStore, "workflow.language.form.validationInput", fallback: "Input interpretation"), selection: Binding(
                    get: { node.dataConfiguration?.validationInputFormat ?? .typed },
                    set: { format in
                        var next = node.dataConfiguration ?? .init()
                        next.validationInputFormat = format == .typed ? nil : format
                        var updated = node; updated.dataConfiguration = next; node = updated
                    }
                )) {
                    Text(workflowFormText(languageStore, "workflow.language.form.validationTyped", fallback: "Typed value")).tag(WorkflowValidationInputFormat.typed)
                    Text(workflowFormText(languageStore, "workflow.language.form.validationJSON", fallback: "Parse complete JSON text")).tag(WorkflowValidationInputFormat.jsonText)
                }
                WorkflowSchemaEditor(schema: configurationSchema, depth: 0)
            case "d.model.language", WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38, "d.control.human":
                WorkflowSchemaEditor(schema: configurationSchema, depth: 0)
            default:
                Text(workflowFormText(
                    languageStore,
                    "workflow.language.form.unsupportedNode",
                    fallback: "This node has no structured data form."
                )).foregroundStyle(.secondary)
            }
        }
    }

    private var configuration: Binding<WorkflowDataConfiguration> {
        Binding(get: { node.dataConfiguration ?? .init() }, set: { next in
            var updated = node
            updated.dataConfiguration = next
            node = updated
        })
    }

    private var configurationValue: Binding<WorkflowDatum?> {
        Binding(get: { node.dataConfiguration?.value }, set: { next in
            var configuration = node.dataConfiguration ?? .init(); configuration.value = next
            var updated = node; updated.dataConfiguration = configuration; node = updated
        })
    }

    private var configurationSchema: Binding<WorkflowDataSchema?> {
        Binding(get: { node.dataConfiguration?.schema }, set: { next in
            var configuration = node.dataConfiguration ?? .init(); configuration.schema = next
            var updated = node; updated.dataConfiguration = configuration; node = updated
        })
    }

    private var configurationPath: Binding<[String]> {
        Binding(get: { node.dataConfiguration?.path ?? [] }, set: { next in
            var configuration = node.dataConfiguration ?? .init(); configuration.path = next
            var updated = node; updated.dataConfiguration = configuration; node = updated
        })
    }
}

@MainActor
private struct WorkflowTemplateFallbackEditor: View {
    @Binding var configuration: WorkflowDataConfiguration
    @State private var invalidType = false
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workflowFormText(languageStore, "workflow.language.form.templateFallback", fallback: "Fallback fields"))
                .font(.callout.weight(.medium))
            WorkflowDatumValueEditor(
                value: Binding(get: {
                    if case .record? = configuration.value { return configuration.value }
                    return .record(schema: [], fields: [:])
                }, set: { next in
                    guard case .record(let fields, _)? = next,
                          fields.allSatisfy({ isTemplateScalar($0.type) }) else {
                        invalidType = true
                        return
                    }
                    configuration.value = next
                    invalidType = false
                }),
                schema: configuration.value?.schema ?? .record([]),
                depth: 0,
                allowsSchemaEditing: true
            )
            if invalidType {
                Text(workflowFormText(
                    languageStore,
                    "workflow.language.form.templateScalarOnly",
                    fallback: "Template fallbacks support only Text, Number, Bool, and Enum fields."
                )).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func isTemplateScalar(_ schema: WorkflowDataSchema) -> Bool {
        switch schema {
        case .text, .number, .boolean, .enumeration: true
        default: false
        }
    }
}

@MainActor
private struct WorkflowRecordNodeEditor: View {
    @Binding var configuration: WorkflowDataConfiguration
    @State private var nameDraft = ""
    @State private var error: String?
    @State private var fieldRows: WorkflowStableNamedRows
    @Environment(\.dLanguageStore) private var languageStore

    init(configuration: Binding<WorkflowDataConfiguration>) {
        _configuration = configuration
        _fieldRows = State(initialValue: WorkflowStableNamedRows(
            names: configuration.wrappedValue.fields.map(\.name)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fieldRows.rows) { row in
                if configuration.fields.contains(where: { $0.name == row.fieldName }) {
                    WorkflowConfiguredFieldRow(
                        configuration: $configuration,
                        fieldName: row.fieldName,
                        onRenamed: { fieldRows.rename(id: row.id, to: $0) },
                        onRemoved: { fieldRows.remove(id: row.id) }
                    )
                }
            }
            HStack {
                TextField(workflowFormText(languageStore, "workflow.language.form.fieldName", fallback: "Field name"), text: $nameDraft)
                Button(workflowFormText(languageStore, "workflow.language.form.addField", fallback: "Add field")) { addField() }
                    .disabled(nameDraft.isEmpty || configuration.fields.contains(where: { $0.name == nameDraft }))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func addField() {
        guard !nameDraft.isEmpty, !configuration.fields.contains(where: { $0.name == nameDraft }) else { return }
        let name = nameDraft
        configuration.fields.append(WorkflowRecordField(name, .text, required: true))
        var fallback: [String: WorkflowDatum] = [:]
        if case .record(_, let fields)? = configuration.value { fallback = fields }
        configuration.value = .record(schema: configuration.fields, fields: fallback)
        fieldRows.append(name)
        nameDraft = ""; error = nil
    }
}

@MainActor
private struct WorkflowConfiguredFieldRow: View {
    @Binding var configuration: WorkflowDataConfiguration
    let fieldName: String
    let onRenamed: (String) -> Void
    let onRemoved: () -> Void
    @State private var rowState: WorkflowNamedRowFormState
    @State private var schemaDraft: WorkflowDataSchema?
    @State private var error: String?
    @State private var pendingFallback: WorkflowDatum?
    @State private var isCreatingFallback: Bool
    @Environment(\.dLanguageStore) private var languageStore

    init(
        configuration: Binding<WorkflowDataConfiguration>,
        fieldName: String,
        onRenamed: @escaping (String) -> Void,
        onRemoved: @escaping () -> Void
    ) {
        _configuration = configuration
        self.fieldName = fieldName
        self.onRenamed = onRenamed
        self.onRemoved = onRemoved
        let field = configuration.wrappedValue.fields.first(where: { $0.name == fieldName })!
        _rowState = State(initialValue: WorkflowNamedRowFormState(id: field.name))
        _schemaDraft = State(initialValue: field.type)
        _pendingFallback = State(initialValue: nil)
        _isCreatingFallback = State(initialValue: false)
    }

    var body: some View {
        if let index = currentIndex {
            let field = configuration.fields[index]
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(workflowFormText(languageStore, "workflow.language.form.fieldName", fallback: "Field name"), text: Binding(
                        get: { rowState.nameDraft }, set: { commitName($0) }
                    ))
                    Toggle(workflowFormText(languageStore, "workflow.language.form.required", fallback: "Required"), isOn: Binding(
                        get: { field.required }, set: { replace(required: $0) }
                    ))
                    Button(role: .destructive) { remove() } label: { Image(systemName: "minus.circle") }
                }
                WorkflowSchemaEditor(schema: Binding(get: { schemaDraft }, set: { next in
                    schemaDraft = next
                    if let next { replace(type: next) }
                }), depth: 0)
                Toggle(workflowFormText(
                    languageStore,
                    "workflow.language.form.fixedFallback",
                    fallback: "Use fixed fallback"
                ), isOn: Binding(
                    get: { fallbackBinding(field.name).wrappedValue != nil || isCreatingFallback },
                    set: { present in
                        if present {
                            if let seed = WorkflowFormSupport.seed(for: field.type) {
                                fallbackBinding(field.name).wrappedValue = seed
                                return
                            }
                            if case .enumeration = field.type {
                                pendingFallback = nil
                                isCreatingFallback = true
                            } else {
                                error = "seed"
                            }
                        } else {
                            fallbackBinding(field.name).wrappedValue = nil
                            pendingFallback = nil
                            isCreatingFallback = false
                        }
                    }
                ))
                if isCreatingFallback {
                    WorkflowDatumValueEditor(value: $pendingFallback, schema: field.type, depth: 0)
                    HStack {
                        Button(workflowFormText(languageStore, "workflow.language.form.usePendingValue", fallback: "Use this value")) {
                            guard let pendingFallback = WorkflowFormSupport.validatedExplicitValue(
                                pendingFallback, as: field.type
                            ) else { return }
                            fallbackBinding(field.name).wrappedValue = pendingFallback
                            self.pendingFallback = nil
                            isCreatingFallback = false
                            error = nil
                        }.disabled(WorkflowFormSupport.validationError(pendingFallback, as: field.type) != nil)
                        Button(workflowFormText(languageStore, "workflow.language.form.cancelPending", fallback: "Cancel")) {
                            pendingFallback = nil
                            isCreatingFallback = false
                        }
                    }
                } else if fallbackBinding(field.name).wrappedValue != nil {
                    WorkflowDatumValueEditor(value: fallbackBinding(field.name), schema: field.type, depth: 0)
                }
                if error != nil {
                    Text(workflowFormText(
                        languageStore,
                        "workflow.language.form.invalidEdit",
                        fallback: "The edit is invalid; the previous valid configuration was preserved."
                    )).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func commitName(_ name: String) {
        let siblings = Set(configuration.fields.map(\.name)).subtracting([fieldName])
        guard let accepted = rowState.proposeName(name, siblingNames: siblings) else {
            error = "name"
            return
        }
        replace(name: accepted)
    }

    private func replace(name: String? = nil, type: WorkflowDataSchema? = nil, required: Bool? = nil) {
        guard let index = currentIndex else { return }
        do {
            configuration = try WorkflowFormSupport.replacingField(
                in: configuration, at: index, name: name, type: type, required: required
            )
            if let name { onRenamed(name) }
            error = nil
        } catch let caughtError {
            self.error = caughtError.localizedDescription
        }
    }

    private func fallbackBinding(_ name: String) -> Binding<WorkflowDatum?> {
        Binding(get: {
            guard case .record(_, let fields)? = configuration.value else { return nil }
            return fields[name]
        }, set: { next in
            var values: [String: WorkflowDatum] = [:]
            if case .record(_, let existing)? = configuration.value { values = existing }
            values[name] = next
            configuration.value = .record(schema: configuration.fields, fields: values)
        })
    }

    private func remove() {
        guard let index = currentIndex else { return }
        let name = configuration.fields[index].name
        configuration.fields.remove(at: index)
        var values: [String: WorkflowDatum] = [:]
        if case .record(_, let existing)? = configuration.value { values = existing }
        values.removeValue(forKey: name)
        configuration.value = .record(schema: configuration.fields, fields: values)
        onRemoved()
    }

    private var currentIndex: Int? {
        configuration.fields.firstIndex(where: { $0.name == fieldName })
    }
}

@MainActor
private struct WorkflowSchemaAndPathEditor: View {
    @Binding var configuration: WorkflowDataConfiguration
    let availableRecordSchema: [WorkflowRecordField]
    let pathRequired: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkflowSchemaEditor(schema: $configuration.schema, depth: 0)
            WorkflowPathEditor(path: Binding(get: { configuration.path }, set: { next in
                configuration.path = next
                if let selected = WorkflowFormSupport.schema(at: next, in: .record(availableRecordSchema)) {
                    configuration.schema = selected
                }
            }), availableRecordSchema: availableRecordSchema, pathRequired: pathRequired)
        }
    }
}

@MainActor
private struct WorkflowPathEditor: View {
    @Binding var path: [String]
    let availableRecordSchema: [WorkflowRecordField]
    let pathRequired: Bool
    @State private var componentDraft = ""
    @State private var error: String?
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !availableRecordSchema.isEmpty {
                Menu(workflowFormText(languageStore, "workflow.language.form.choosePath", fallback: "Choose schema path")) {
                    ForEach(WorkflowFormSupport.recordPaths(in: availableRecordSchema), id: \.self) { option in
                        Button(option.joined(separator: " › ")) { path = option; error = nil }
                    }
                }
            }
            ForEach(Array(path.enumerated()), id: \.offset) { index, component in
                HStack {
                    Text(component).textSelection(.enabled)
                    Spacer()
                    Button(role: .destructive) { path.remove(at: index) } label: { Image(systemName: "minus.circle") }
                }
            }
            HStack {
                TextField(workflowFormText(languageStore, "workflow.language.form.pathComponent", fallback: "Literal field name"), text: $componentDraft)
                Button(workflowFormText(languageStore, "workflow.language.form.add", fallback: "Add")) {
                    guard !componentDraft.isEmpty, componentDraft.utf8.count <= 256, path.count < 24 else { return }
                    path.append(componentDraft); componentDraft = ""; error = nil
                }.disabled(componentDraft.isEmpty || path.count >= 24)
            }
            if pathRequired && path.isEmpty {
                Text(workflowFormText(languageStore, "workflow.language.form.pathRequired", fallback: "Add at least one literal path component."))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

@MainActor
private struct WorkflowListNodeEditor: View {
    @Binding var configuration: WorkflowDataConfiguration
    let mode: String
    @State private var schemaDraft: WorkflowDataSchema?
    @State private var portDraft = ""
    @State private var error: String?
    @State private var portRows: WorkflowStableNamedRows
    @Environment(\.dLanguageStore) private var languageStore

    init(configuration: Binding<WorkflowDataConfiguration>, mode: String) {
        _configuration = configuration
        self.mode = mode
        _schemaDraft = State(initialValue: configuration.wrappedValue.schema)
        _portRows = State(initialValue: WorkflowStableNamedRows(
            names: configuration.wrappedValue.fields.map(\.name)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowFormText(
                languageStore,
                "workflow.language.form.listMode",
                fallback: "Mode: {mode}",
                arguments: ["mode": mode]
            )).font(.caption).foregroundStyle(.secondary)
            WorkflowSchemaEditor(schema: Binding(get: { schemaDraft }, set: { next in
                schemaDraft = next
                if let next { commitSchema(next) }
            }), depth: 0)
            if let element = configuration.schema {
                WorkflowDatumValueEditor(value: listValueBinding(element), schema: .list(element), depth: 0)
                ForEach(portRows.rows) { row in
                    if configuration.fields.contains(where: { $0.name == row.fieldName }) {
                        WorkflowListPortRow(
                            configuration: $configuration,
                            fieldName: row.fieldName,
                            onRenamed: { portRows.rename(id: row.id, to: $0) },
                            onRemoved: { portRows.remove(id: row.id) }
                        )
                    }
                }
                HStack {
                    TextField(workflowFormText(languageStore, "workflow.language.form.portName", fallback: "Input port name"), text: $portDraft)
                    Button(workflowFormText(languageStore, "workflow.language.form.addPort", fallback: "Add port")) { addPort(element) }
                        .disabled(portDraft.isEmpty || configuration.fields.contains(where: { $0.name == portDraft }))
                }
            }
            if error != nil {
                Text(workflowFormText(
                    languageStore,
                    "workflow.language.form.invalidEdit",
                    fallback: "The edit is invalid; the previous valid configuration was preserved."
                )).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func commitSchema(_ schema: WorkflowDataSchema) {
        do {
            for item in configuration.items { try item.value.validate(as: schema) }
            configuration.schema = schema
            let portType: WorkflowDataSchema = mode == "concat" ? .list(schema) : schema
            configuration.fields = configuration.fields.map { WorkflowRecordField($0.name, portType, required: $0.required) }
            error = nil
        } catch let caughtError {
            self.error = caughtError.localizedDescription
        }
    }

    private func listValueBinding(_ element: WorkflowDataSchema) -> Binding<WorkflowDatum?> {
        Binding(get: { .list(element: element, items: configuration.items) }, set: { next in
            guard case .list(let nextElement, let items)? = next, nextElement == element else { return }
            configuration.items = items
        })
    }

    private func addPort(_ element: WorkflowDataSchema) {
        guard !portDraft.isEmpty, !configuration.fields.contains(where: { $0.name == portDraft }) else { return }
        let type: WorkflowDataSchema = mode == "concat" ? .list(element) : element
        let name = portDraft
        configuration.fields.append(WorkflowRecordField(name, type, required: true))
        portRows.append(name)
        portDraft = ""
    }
}

@MainActor
private struct WorkflowListPortRow: View {
    @Binding var configuration: WorkflowDataConfiguration
    let fieldName: String
    let onRenamed: (String) -> Void
    let onRemoved: () -> Void
    @State private var rowState: WorkflowNamedRowFormState
    @Environment(\.dLanguageStore) private var languageStore

    init(
        configuration: Binding<WorkflowDataConfiguration>,
        fieldName: String,
        onRenamed: @escaping (String) -> Void,
        onRemoved: @escaping () -> Void
    ) {
        _configuration = configuration
        self.fieldName = fieldName
        self.onRenamed = onRenamed
        self.onRemoved = onRemoved
        _rowState = State(initialValue: WorkflowNamedRowFormState(id: fieldName))
    }

    var body: some View {
        if let index = currentIndex {
            let field = configuration.fields[index]
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField(workflowFormText(languageStore, "workflow.language.form.portName", fallback: "Input port name"), text: Binding(
                        get: { rowState.nameDraft }, set: { rename($0) }
                    ))
                    Text(workflowFormSchemaName(field.type, language: languageStore))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(workflowFormText(languageStore, "workflow.language.form.required", fallback: "Required"), isOn: Binding(
                        get: { field.required }, set: {
                            configuration.fields[index] = WorkflowRecordField(field.name, field.type, required: $0)
                        }
                    ))
                    Button(role: .destructive) {
                        configuration.fields.remove(at: index)
                        onRemoved()
                    } label: { Image(systemName: "minus.circle") }
                }
                if rowState.hasInvalidName {
                    Text(workflowFormText(
                        languageStore,
                        "workflow.language.form.invalidName",
                        fallback: "Names must be nonempty and unique; the previous name was preserved."
                    )).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func rename(_ next: String) {
        guard let index = currentIndex else { return }
        let siblings = Set(configuration.fields.enumerated().compactMap { $0.offset == index ? nil : $0.element.name })
        guard let accepted = rowState.proposeName(next, siblingNames: siblings) else { return }
        let field = configuration.fields[index]
        configuration.fields[index] = WorkflowRecordField(accepted, field.type, required: field.required)
        onRenamed(accepted)
    }

    private var currentIndex: Int? {
        configuration.fields.firstIndex(where: { $0.name == fieldName })
    }
}

@MainActor
private struct WorkflowRulesNodeEditor: View {
    @Binding var configuration: WorkflowDataConfiguration
    let availableRecordSchema: [WorkflowRecordField]
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowFormText(languageStore, "workflow.language.form.ruleSchema", fallback: "Rule item schema"))
                .font(.callout.weight(.medium))
            WorkflowSchemaEditor(schema: $configuration.schema, depth: 0)
            WorkflowPathEditor(
                path: $configuration.path,
                availableRecordSchema: availableRecordSchema,
                pathRequired: false
            )
            ForEach(Array(configuration.rules.enumerated()), id: \.offset) { index, _ in
                VStack(alignment: .trailing, spacing: 4) {
                    WorkflowRuleEditor(rule: Binding(
                        get: { configuration.rules[index] },
                        set: { configuration.rules[index] = $0 }
                    ), rootSchema: configuration.schema, availableRecordSchema: availableRecordSchema)
                    Button(role: .destructive) { configuration.rules.remove(at: index) } label: {
                        Label(workflowFormText(languageStore, "workflow.language.form.removeRule", fallback: "Remove rule"), systemImage: "minus.circle")
                    }
                }
            }
            Button(workflowFormText(languageStore, "workflow.language.form.addRule", fallback: "Add rule")) {
                configuration.rules.append(.init())
            }
        }
    }
}

@MainActor
private struct WorkflowRuleEditor: View {
    @Binding var rule: WorkflowDataRule
    let rootSchema: WorkflowDataSchema?
    let availableRecordSchema: [WorkflowRecordField]
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkflowPathEditor(path: $rule.path, availableRecordSchema: recordSchema, pathRequired: false)
            Picker(workflowFormText(languageStore, "workflow.language.form.comparison", fallback: "Comparison"), selection: Binding(
                get: { rule.comparison.rawValue },
                set: { if let next = WorkflowComparison(rawValue: $0) { rule.comparison = next } }
            )) {
                ForEach(WorkflowComparison.allCases, id: \.rawValue) { comparison in
                    Text(workflowFormText(
                        languageStore,
                        "workflow.language.form.comparison.\(comparison.rawValue)",
                        fallback: comparison.rawValue
                    )).tag(comparison.rawValue)
                }
            }
            if rule.comparison != .exists, let expected = expectedSchema {
                WorkflowDatumValueEditor(value: $rule.value, schema: expected, depth: 0)
            }
        }
        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var recordSchema: [WorkflowRecordField] {
        if case .record(let fields)? = rootSchema { return fields }
        return availableRecordSchema
    }

    private var expectedSchema: WorkflowDataSchema? {
        guard let rootSchema else { return nil }
        return WorkflowFormSupport.schema(at: rule.path, in: rootSchema)
    }
}
