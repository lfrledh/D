import DWorkbench
import Foundation
import SwiftUI

enum WorkflowControlFormError: Error, LocalizedError, Equatable {
    case unavailableOperations
    case missingPassthrough
    case unsupportedControl
    case missingControl
    case invalidLoopRange
    case missingTool
    case changedTool
    case mismatchedToolFields
    case mismatchedControl
    case invalidPredicatePath
    case missingPredicateValue
    case duplicateNames
    case invalidInputName
    case missingInputSchema
    case invalidOutputName
    case missingOutputPort
    case missingOutputSchema
    case incompatibleOutputSchema
    case bindingRejected

    var localizationKey: String {
        switch self {
        case .unavailableOperations: "workflow.language.control.error.unavailableOperations"
        case .missingPassthrough: "workflow.language.control.error.missingPassthrough"
        case .unsupportedControl: "workflow.language.control.error.unsupportedControl"
        case .missingControl: "workflow.language.control.error.missingControl"
        case .invalidLoopRange: "workflow.language.control.error.invalidLoopRange"
        case .missingTool: "workflow.language.control.error.missingTool"
        case .changedTool: "workflow.language.control.error.changedTool"
        case .mismatchedToolFields: "workflow.language.control.error.mismatchedToolFields"
        case .mismatchedControl: "workflow.language.control.error.mismatchedControl"
        case .invalidPredicatePath: "workflow.language.control.error.invalidPredicatePath"
        case .missingPredicateValue: "workflow.language.control.error.missingPredicateValue"
        case .duplicateNames: "workflow.language.control.error.duplicateNames"
        case .invalidInputName: "workflow.language.control.error.invalidInputName"
        case .missingInputSchema: "workflow.language.control.error.missingInputSchema"
        case .invalidOutputName: "workflow.language.control.error.invalidOutputName"
        case .missingOutputPort: "workflow.language.control.error.missingOutputPort"
        case .missingOutputSchema: "workflow.language.control.error.missingOutputSchema"
        case .incompatibleOutputSchema: "workflow.language.control.error.incompatibleOutputSchema"
        case .bindingRejected: "workflow.language.control.error.bindingRejected"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailableOperations: "The standard input or return operation is unavailable."
        case .missingPassthrough: "The passthrough input is unavailable."
        case .unsupportedControl: "This node does not support a local control body."
        case .missingControl: "Create or select a control before applying the draft."
        case .invalidLoopRange: "Loop iterations must be between 1 and 1000."
        case .missingTool: "The fixed tool version is unavailable; the existing reference was preserved."
        case .changedTool: "The fixed tool digest no longer matches."
        case .mismatchedToolFields: "The invocation fields do not match the fixed tool interface."
        case .mismatchedControl: "The control kind does not match the node operation."
        case .invalidPredicatePath: "Predicate paths cannot contain empty or oversized components."
        case .missingPredicateValue: "This comparison requires an explicit value."
        case .duplicateNames: "Interface names must be unique within inputs and outputs."
        case .invalidInputName: "Every input needs a valid name."
        case .missingInputSchema: "Every input needs an explicitly chosen schema."
        case .invalidOutputName: "Every output needs a valid name."
        case .missingOutputPort: "An output refers to a missing node or port; the draft was preserved."
        case .missingOutputSchema: "Every output needs an explicitly chosen schema."
        case .incompatibleOutputSchema: "The output schema is incompatible with the selected port kinds."
        case .bindingRejected: "The controller rejected this change. The draft was preserved; correct the graph and apply again."
        }
    }
}

struct WorkflowControlDraft: Equatable {
    var control: WorkflowControlBlock?
    var dataConfiguration: WorkflowDataConfiguration?

    init(node: WorkflowNode) {
        control = node.control
        dataConfiguration = node.dataConfiguration
    }
}

struct WorkflowInterfaceInputDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var schema: WorkflowDataSchema?
    var required: Bool

    init(id: UUID = UUID(), name: String = "", schema: WorkflowDataSchema? = nil, required: Bool = true) {
        self.id = id
        self.name = name
        self.schema = schema
        self.required = required
    }
}

struct WorkflowInterfaceOutputDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var nodeID: UUID?
    var port: String
    var schema: WorkflowDataSchema?

    init(
        id: UUID = UUID(),
        name: String = "",
        nodeID: UUID? = nil,
        port: String = "",
        schema: WorkflowDataSchema? = nil
    ) {
        self.id = id
        self.name = name
        self.nodeID = nodeID
        self.port = port
        self.schema = schema
    }
}

struct WorkflowInterfaceDraft: Equatable {
    var inputs: [WorkflowInterfaceInputDraft]
    var outputs: [WorkflowInterfaceOutputDraft]

    init(interface: WorkflowGraphInterface?) {
        inputs = (interface?.inputs ?? []).map {
            WorkflowInterfaceInputDraft(name: $0.name, schema: $0.type, required: $0.required)
        }
        outputs = (interface?.outputs ?? []).map {
            WorkflowInterfaceOutputDraft(name: $0.name, nodeID: $0.nodeID, port: $0.port, schema: $0.schema)
        }
    }

    mutating func renameInput(id: UUID, to name: String) {
        guard let index = inputs.firstIndex(where: { $0.id == id }) else { return }
        inputs[index].name = name
    }

    func matches(_ interface: WorkflowGraphInterface?) -> Bool {
        let publishedInputs = interface?.inputs ?? []
        let publishedOutputs = interface?.outputs ?? []
        guard inputs.count == publishedInputs.count, outputs.count == publishedOutputs.count else { return false }
        for (draft, published) in zip(inputs, publishedInputs) {
            guard draft.name == published.name, draft.schema == published.type,
                  draft.required == published.required else { return false }
        }
        for (draft, published) in zip(outputs, publishedOutputs) {
            guard draft.name == published.name, draft.nodeID == Optional(published.nodeID),
                  draft.port == published.port, draft.schema == Optional(published.schema) else { return false }
        }
        return true
    }
}

struct WorkflowOutputPortChoice: Identifiable, Equatable {
    var id: String { nodeID.uuidString + "\u{1f}" + port }
    let nodeID: UUID
    let nodeTitle: String
    let port: String
    let kinds: [WorkflowDataKind]
}

enum WorkflowControlFormSupport {
    static let mapVariableNames = ["item", "value", "index"]
    static let loopVariableNames = ["state", "iteration"]

    static func controlCommitWasAccepted(
        _ proposed: WorkflowControlDraft,
        storedNode: WorkflowNode
    ) -> Bool {
        WorkflowControlDraft(node: storedNode) == proposed
    }

    static func interfaceCommitWasAccepted(
        _ proposed: WorkflowGraphInterface,
        storedGraph: WorkflowGraph
    ) -> Bool {
        storedGraph.interface == proposed
    }

    static func canOpenNestedContent(
        draft: WorkflowControlDraft,
        baseline: WorkflowControlDraft,
        conflict: Bool
    ) -> Bool {
        !conflict && draft == baseline
    }

    static func sample(for schema: WorkflowDataSchema) -> WorkflowDatum? {
        switch schema {
        case .text:
            .text("")
        case .number(let unit):
            .number(0, unit: unit)
        case .boolean:
            .boolean(false)
        case .enumeration:
            nil
        case .record(let fields):
            .record(schema: fields, fields: [:])
        case .list(let element):
            .list(element: element, items: [])
        case .optional(let inner):
            .none(inner)
        case .asset, .result:
            nil
        }
    }

    static func acceptsNewSchema(_ schema: WorkflowDataSchema) -> Bool {
        switch schema {
        case .asset, .result:
            false
        case .record(let fields):
            fields.allSatisfy { acceptsNewSchema($0.type) }
        case .list(let inner), .optional(let inner):
            acceptsNewSchema(inner)
        default:
            true
        }
    }

    static func makeBody(
        name: String,
        inputs: [WorkflowRecordField],
        passthrough: String,
        outputName: String,
        registry: WorkflowRegistry = .standard
    ) throws -> WorkflowGraph {
        guard let sourceDefinition = registry.operation("d.value.input")?.definition,
              let returnDefinition = registry.operation("d.value.return")?.definition,
              let selected = inputs.first(where: { $0.name == passthrough }) else {
            throw WorkflowControlFormError.unavailableOperations
        }

        var inputNodes: [WorkflowNode] = []
        var selectedNodeID: UUID?
        for field in inputs {
            var node = sourceDefinition.makeNode()
            node.title = field.name
            node.parameters["publicName"] = .text(field.name)
            node.dataConfiguration = .init(value: sample(for: field.type))
            inputNodes.append(node)
            if field.name == passthrough { selectedNodeID = node.id }
        }
        guard let selectedNodeID else {
            throw WorkflowControlFormError.missingPassthrough
        }

        var returnNode = returnDefinition.makeNode()
        returnNode.title = outputName
        returnNode.parameters["name"] = .text(outputName)
        let connection = WorkflowConnection(
            sourceNode: selectedNodeID,
            sourcePort: "output",
            targetNode: returnNode.id,
            targetPort: "input"
        )
        var graph = WorkflowGraph(name: name, nodes: inputNodes + [returnNode], connections: [connection])
        graph.interface = WorkflowGraphInterface(
            inputs: inputs,
            outputs: [WorkflowNamedOutput(
                name: outputName,
                nodeID: returnNode.id,
                port: "output",
                schema: selected.type
            )]
        )
        return graph
    }

    static func makeDefaultControl(
        operationID: String,
        registry: WorkflowRegistry = .standard
    ) throws -> WorkflowControlBlock {
        switch operationID {
        case "d.control.branch":
            let fields = [WorkflowRecordField("input", .text)]
            return .branch(
                predicate: .init(comparison: .exists),
                then: try makeBody(name: "Then", inputs: fields, passthrough: "input", outputName: "output", registry: registry),
                otherwise: try makeBody(name: "Otherwise", inputs: fields, passthrough: "input", outputName: "output", registry: registry)
            )
        case "d.control.map":
            let fields = [
                WorkflowRecordField("item", .text),
                WorkflowRecordField("value", .text),
                WorkflowRecordField("index", .number(unit: nil)),
            ]
            return .map(
                body: try makeBody(name: "Map Body", inputs: fields, passthrough: "item", outputName: "output", registry: registry),
                continueOnFailure: false
            )
        case "d.control.loop":
            // The current executor supplies `state` but not `iteration`. Keeping iteration optional
            // exposes the specified body variable without making every generated body fail at entry.
            let fields = [
                WorkflowRecordField("state", .text),
                WorkflowRecordField("iteration", .number(unit: nil), required: false),
            ]
            return .loop(
                body: try makeBody(name: "Loop Body", inputs: fields, passthrough: "state", outputName: "nextState", registry: registry),
                stateSchema: .text,
                maximumIterations: 1,
                until: .init(comparison: .equals, value: .text(""))
            )
        default:
            throw WorkflowControlFormError.unsupportedControl
        }
    }

    static func selecting(
        tool: WorkflowToolDefinition,
        in draft: WorkflowControlDraft
    ) throws -> WorkflowControlDraft {
        var result = draft
        result.control = .invoke(.init(
            id: tool.id,
            version: tool.version,
            digest: try WorkflowPlanCompiler.digest(tool)
        ))
        var configuration = result.dataConfiguration ?? .init()
        configuration.fields = tool.graph.interface?.inputs ?? []
        result.dataConfiguration = configuration
        return result
    }

    static func validate(
        _ draft: WorkflowControlDraft,
        operationID: String,
        tools: [WorkflowToolDefinition]
    ) throws {
        guard let control = draft.control else {
            throw WorkflowControlFormError.missingControl
        }
        switch (operationID, control) {
        case ("d.control.branch", .branch(let predicate, _, _)):
            try validate(predicate)
        case ("d.control.map", .map):
            break
        case ("d.control.loop", .loop(_, let schema, let maximum, let until)):
            try schema.validateDefinition()
            guard (1...1_000).contains(maximum) else {
                throw WorkflowControlFormError.invalidLoopRange
            }
            try validate(until)
        case ("d.control.invoke", .invoke(let reference)):
            guard let tool = tools.first(where: { $0.id == reference.id && $0.version == reference.version }) else {
                throw WorkflowControlFormError.missingTool
            }
            guard try WorkflowPlanCompiler.digest(tool) == reference.digest else {
                throw WorkflowControlFormError.changedTool
            }
            guard draft.dataConfiguration?.fields == (tool.graph.interface?.inputs ?? []) else {
                throw WorkflowControlFormError.mismatchedToolFields
            }
        default:
            throw WorkflowControlFormError.mismatchedControl
        }
    }

    static func validate(_ rule: WorkflowDataRule) throws {
        guard rule.path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw WorkflowControlFormError.invalidPredicatePath
        }
        if rule.comparison == .exists { return }
        guard let value = rule.value else {
            throw WorkflowControlFormError.missingPredicateValue
        }
        try value.validate()
    }

    static func outputChoices(
        graph: WorkflowGraph,
        registry: WorkflowRegistry,
        tools: [WorkflowToolDefinition]
    ) -> [WorkflowOutputPortChoice] {
        graph.nodes.flatMap { node in
            (registry.definition(for: node, tools: tools)?.outputs ?? []).map {
                WorkflowOutputPortChoice(
                    nodeID: node.id,
                    nodeTitle: node.title,
                    port: $0.id,
                    kinds: $0.kinds
                )
            }
        }
    }

    static func validatedInterface(
        _ draft: WorkflowInterfaceDraft,
        choices: [WorkflowOutputPortChoice]
    ) throws -> WorkflowGraphInterface {
        let inputNames = draft.inputs.map(\.name)
        let outputNames = draft.outputs.map(\.name)
        guard Set(inputNames).count == inputNames.count, Set(outputNames).count == outputNames.count else {
            throw WorkflowControlFormError.duplicateNames
        }

        let inputs = try draft.inputs.map { row -> WorkflowRecordField in
            guard !row.name.isEmpty, row.name.utf8.count <= 256 else {
                throw WorkflowControlFormError.invalidInputName
            }
            guard let schema = row.schema else {
                throw WorkflowControlFormError.missingInputSchema
            }
            try schema.validateDefinition()
            return WorkflowRecordField(row.name, schema, required: row.required)
        }
        let outputs = try draft.outputs.map { row -> WorkflowNamedOutput in
            guard !row.name.isEmpty, row.name.utf8.count <= 256 else {
                throw WorkflowControlFormError.invalidOutputName
            }
            guard let nodeID = row.nodeID,
                  let choice = choices.first(where: { $0.nodeID == nodeID && $0.port == row.port }) else {
                throw WorkflowControlFormError.missingOutputPort
            }
            guard let schema = row.schema else {
                throw WorkflowControlFormError.missingOutputSchema
            }
            try schema.validateDefinition()
            guard !Set(choice.kinds).isDisjoint(with: schema.portKinds) else {
                throw WorkflowControlFormError.incompatibleOutputSchema
            }
            return WorkflowNamedOutput(name: row.name, nodeID: nodeID, port: row.port, schema: schema)
        }
        return WorkflowGraphInterface(inputs: inputs, outputs: outputs)
    }
}

@MainActor
private func workflowControlText(_ store: UILanguageStore?, _ key: String, fallback: String) -> String {
    store?.text(key, fallback: fallback) ?? fallback
}

@MainActor
private func workflowControlErrorText(_ error: Error, store: UILanguageStore?) -> String {
    if let error = error as? WorkflowControlFormError {
        return workflowControlText(
            store,
            error.localizationKey,
            fallback: error.errorDescription ?? "The draft is invalid."
        )
    }
    return workflowControlText(
        store,
        "workflow.language.control.error.invalidDraft",
        fallback: "The draft is invalid and was preserved."
    )
}

@MainActor
struct WorkflowControlEditor: View {
    @Binding private var node: WorkflowNode
    private let tools: [WorkflowToolDefinition]
    private let onOpenBody: (String) -> Void

    @State private var identity: UUID
    @State private var baseline: WorkflowControlDraft
    @State private var draft: WorkflowControlDraft
    @State private var reloadToken = UUID()
    @State private var conflict = false
    @State private var error: String?
    @Environment(\.dLanguageStore) private var languageStore

    init(
        node: Binding<WorkflowNode>,
        tools: [WorkflowToolDefinition],
        onOpenBody: @escaping (String) -> Void
    ) {
        _node = node
        self.tools = tools
        self.onOpenBody = onOpenBody
        let initial = WorkflowControlDraft(node: node.wrappedValue)
        _identity = State(initialValue: node.wrappedValue.id)
        _baseline = State(initialValue: initial)
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if conflict {
                conflictMessage
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !canOpenNestedContent, draft.control != nil {
                Text(text(
                    "workflow.language.control.applyBeforeOpen",
                    "Apply this draft before opening nested content. Reload first if the controlled value changed."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            controlFields
            HStack {
                Button(text("workflow.language.control.apply", "Apply"), action: apply)
                    .disabled(conflict || draft == baseline)
                Button(text("workflow.language.control.reload", "Reload"), action: reload)
                Spacer()
            }
        }
        .onChange(of: node.id) { _, next in
            guard next != identity else { return }
            reload()
        }
        .onChange(of: WorkflowControlDraft(node: node)) { _, next in
            guard node.id == identity, next != baseline else { return }
            if draft != baseline {
                conflict = true
            } else {
                baseline = next
                draft = next
                reloadToken = UUID()
                error = nil
            }
        }
    }

    @ViewBuilder private var controlFields: some View {
        switch draft.control {
        case .branch(let predicate, _, _):
            WorkflowControlRuleEditor(rule: Binding(
                get: { predicate },
                set: { replaceBranchPredicate($0) }
            ))
            HStack {
                Button(text("workflow.language.control.openThen", "Open then body")) { onOpenBody("then") }
                    .disabled(!canOpenNestedContent)
                Button(text("workflow.language.control.openOtherwise", "Open otherwise body")) { onOpenBody("otherwise") }
                    .disabled(!canOpenNestedContent)
            }
        case .map(_, let continueOnFailure):
            Toggle(text("workflow.language.control.continueOnFailure", "Continue after item failure"), isOn: Binding(
                get: { continueOnFailure },
                set: { replaceMapContinue($0) }
            ))
            Button(text("workflow.language.control.openBody", "Open body")) { onOpenBody("body") }
                .disabled(!canOpenNestedContent)
        case .loop(_, let stateSchema, let maximumIterations, let until):
            WorkflowControlSchemaSampleEditor(schema: Binding(
                get: { stateSchema },
                set: { if let schema = $0 { replaceLoopSchema(schema) } }
            ))
            .id(reloadToken)
            Stepper(
                text("workflow.language.control.iterations", "Maximum iterations") + ": \(maximumIterations)",
                value: Binding(get: { maximumIterations }, set: replaceLoopMaximum),
                in: 1...1_000
            )
            Text(text("workflow.language.control.until", "Stop rule")).font(.caption.weight(.semibold))
            WorkflowControlRuleEditor(rule: Binding(get: { until }, set: replaceLoopRule))
            Button(text("workflow.language.control.openBody", "Open body")) { onOpenBody("body") }
                .disabled(!canOpenNestedContent)
        case .invoke(let reference):
            invocationEditor(reference)
        case nil:
            missingControlEditor
        }
    }

    private var conflictMessage: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text(
                "workflow.language.control.externalChange",
                "The controlled value changed outside this form. Reload before applying this draft."
            )).font(.caption).foregroundStyle(.orange)
            Button(text("workflow.language.control.reload", "Reload"), action: reload)
        }
    }

    @ViewBuilder private var missingControlEditor: some View {
        if node.operationID == "d.control.invoke" {
            Text(text("workflow.language.control.chooseTool", "Choose a fixed tool version."))
            toolMenu
        } else if ["d.control.branch", "d.control.map", "d.control.loop"].contains(node.operationID) {
            Button(text("workflow.language.control.createLocal", "Create local flow")) {
                do {
                    draft.control = try WorkflowControlFormSupport.makeDefaultControl(operationID: node.operationID)
                    error = nil
                } catch {
                    self.error = workflowControlErrorText(error, store: languageStore)
                }
            }
        } else {
            Text(text("workflow.language.control.unsupported", "This node has no editable control block."))
                .foregroundStyle(.secondary)
        }
    }

    private func invocationEditor(_ reference: WorkflowToolReference) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let tool = tools.first(where: { $0.id == reference.id && $0.version == reference.version }),
               (try? WorkflowPlanCompiler.digest(tool)) == reference.digest {
                Text(tool.name + " v\(tool.version)")
            } else {
                Text(text("workflow.language.control.missingTool", "Missing or changed fixed tool"))
                    .foregroundStyle(.red)
                Text("\(reference.id.uuidString) v\(reference.version) · \(reference.digest)")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            toolMenu
            Button(text("workflow.language.control.openTool", "Open fixed tool")) { onOpenBody("tool") }
                .disabled(!canOpenNestedContent)
        }
    }

    private var toolMenu: some View {
        Menu(text("workflow.language.control.chooseTool", "Choose a fixed tool version")) {
            if tools.isEmpty {
                Text(text("workflow.language.control.noTools", "No tools available"))
            } else {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    Button(tool.name + " v\(tool.version)") { select(tool) }
                }
            }
        }
    }

    private func select(_ tool: WorkflowToolDefinition) {
        do {
            draft = try WorkflowControlFormSupport.selecting(tool: tool, in: draft)
            error = nil
        } catch {
            self.error = workflowControlErrorText(error, store: languageStore)
        }
    }

    private func apply() {
        guard !conflict, node.id == identity else { return }
        do {
            try WorkflowControlFormSupport.validate(draft, operationID: node.operationID, tools: tools)
            var next = node
            next.control = draft.control
            next.dataConfiguration = draft.dataConfiguration
            node = next
            guard WorkflowControlFormSupport.controlCommitWasAccepted(draft, storedNode: node) else {
                self.error = workflowControlErrorText(
                    WorkflowControlFormError.bindingRejected,
                    store: languageStore
                )
                return
            }
            baseline = WorkflowControlDraft(node: node)
            error = nil
        } catch {
            self.error = workflowControlErrorText(error, store: languageStore)
        }
    }

    private func reload() {
        let next = WorkflowControlDraft(node: node)
        identity = node.id
        baseline = next
        draft = next
        reloadToken = UUID()
        conflict = false
        error = nil
    }

    private var canOpenNestedContent: Bool {
        WorkflowControlFormSupport.canOpenNestedContent(
            draft: draft,
            baseline: baseline,
            conflict: conflict
        )
    }

    private func replaceBranchPredicate(_ predicate: WorkflowDataRule) {
        guard case .branch(_, let thenGraph, let otherwiseGraph) = draft.control else { return }
        draft.control = .branch(predicate: predicate, then: thenGraph, otherwise: otherwiseGraph)
    }

    private func replaceMapContinue(_ value: Bool) {
        guard case .map(let body, _) = draft.control else { return }
        draft.control = .map(body: body, continueOnFailure: value)
    }

    private func replaceLoopSchema(_ schema: WorkflowDataSchema) {
        guard case .loop(let body, _, let maximum, let until) = draft.control else { return }
        draft.control = .loop(body: body, stateSchema: schema, maximumIterations: maximum, until: until)
    }

    private func replaceLoopMaximum(_ maximum: Int) {
        guard case .loop(let body, let schema, _, let until) = draft.control else { return }
        draft.control = .loop(body: body, stateSchema: schema, maximumIterations: maximum, until: until)
    }

    private func replaceLoopRule(_ until: WorkflowDataRule) {
        guard case .loop(let body, let schema, let maximum, _) = draft.control else { return }
        draft.control = .loop(body: body, stateSchema: schema, maximumIterations: maximum, until: until)
    }

    private func text(_ key: String, _ fallback: String) -> String {
        workflowControlText(languageStore, key, fallback: fallback)
    }
}

@MainActor
private struct WorkflowControlRuleEditor: View {
    @Binding var rule: WorkflowDataRule
    @Environment(\.dLanguageStore) private var languageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rule.path.indices), id: \.self) { index in
                HStack {
                    TextField(text("workflow.language.control.path", "Path component"), text: Binding(
                        get: { rule.path[index] },
                        set: { rule.path[index] = $0 }
                    ))
                    Button(role: .destructive) { rule.path.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
            Button(text("workflow.language.control.addPath", "Add path component")) { rule.path.append("") }
            Picker(text("workflow.language.control.comparison", "Comparison"), selection: Binding(
                get: { rule.comparison.rawValue },
                set: {
                    guard let next = WorkflowComparison(rawValue: $0) else { return }
                    rule.comparison = next
                    if next == .exists { rule.value = nil }
                }
            )) {
                ForEach(WorkflowComparison.allCases, id: \.rawValue) { comparison in
                    Text(text(
                        "workflow.language.control.comparison.\(comparison.rawValue)",
                        comparison.rawValue
                    )).tag(comparison.rawValue)
                }
            }
            if rule.comparison != .exists {
                WorkflowDatumEditor(value: $rule.value)
            }
        }
    }

    private func text(_ key: String, _ fallback: String) -> String {
        workflowControlText(languageStore, key, fallback: fallback)
    }
}

@MainActor
private struct WorkflowControlSchemaSampleEditor: View {
    @Binding var schema: WorkflowDataSchema?
    @State private var sample: WorkflowDatum?
    @State private var observedSchema: WorkflowDataSchema?
    @State private var editorToken = UUID()
    @State private var error: String?
    @Environment(\.dLanguageStore) private var languageStore

    init(schema: Binding<WorkflowDataSchema?>) {
        _schema = schema
        _sample = State(initialValue: schema.wrappedValue.flatMap(WorkflowControlFormSupport.sample))
        _observedSchema = State(initialValue: schema.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(schema.map(schemaName) ?? text("workflow.language.control.noSchema", "No schema selected"))
                .font(.caption.monospaced())
            Menu(text("workflow.language.control.chooseSchema", "Choose schema from sample")) {
                Button(text("workflow.language.control.type.text", "Text")) { choose(.text("")) }
                Button(text("workflow.language.control.type.number", "Number")) { choose(.number(0, unit: nil)) }
                Button(text("workflow.language.control.type.boolean", "Bool")) { choose(.boolean(false)) }
                Button(text("workflow.language.control.type.enumeration", "Enum")) {
                    choose(.enumeration("value", choices: ["value"]))
                }
                Button(text("workflow.language.control.type.record", "Record")) {
                    choose(.record(schema: [], fields: [:]))
                }
                Button(text("workflow.language.control.type.list", "List")) {
                    choose(.list(element: .text, items: []))
                }
                Button(text("workflow.language.control.type.optional", "Optional")) { choose(.none(.text)) }
            }
            WorkflowDatumEditor(value: Binding(
                get: { sample },
                set: accept
            ), allowsTypeSelection: false)
            .id(editorToken)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: schema) { _, next in
            guard next != observedSchema else { return }
            observedSchema = next
            sample = next.flatMap(WorkflowControlFormSupport.sample)
            editorToken = UUID()
            error = nil
        }
    }

    private func choose(_ value: WorkflowDatum) {
        sample = value
        observedSchema = value.schema
        schema = value.schema
        editorToken = UUID()
        error = nil
    }

    private func accept(_ value: WorkflowDatum?) {
        sample = value
        guard let value else { return }
        let candidate = value.schema
        guard WorkflowControlFormSupport.acceptsNewSchema(candidate),
              (try? candidate.validateDefinition()) != nil else {
            error = text(
                "workflow.language.control.unsupportedSchema",
                "Asset and Result schemas cannot be forged here; the last valid schema was preserved."
            )
            return
        }
        observedSchema = candidate
        schema = candidate
        error = nil
    }

    private func schemaName(_ schema: WorkflowDataSchema) -> String {
        switch schema {
        case .text: text("workflow.language.control.type.text", "Text")
        case .number(let unit):
            unit.map { text("workflow.language.control.type.number", "Number") + " (\($0))" }
                ?? text("workflow.language.control.type.number", "Number")
        case .boolean: text("workflow.language.control.type.boolean", "Bool")
        case .enumeration: text("workflow.language.control.type.enumeration", "Enum")
        case .record: text("workflow.language.control.type.record", "Record")
        case .list: text("workflow.language.control.type.list", "List")
        case .optional: text("workflow.language.control.type.optional", "Optional")
        case .result: text("workflow.language.control.type.result", "Result")
        case .asset(let kind): text("workflow.language.control.type.asset", "Asset") + " (\(kind.rawValue))"
        }
    }

    private func text(_ key: String, _ fallback: String) -> String {
        workflowControlText(languageStore, key, fallback: fallback)
    }
}

@MainActor
struct WorkflowGraphInterfaceEditor: View {
    @Binding private var graph: WorkflowGraph
    private let registry: WorkflowRegistry
    private let tools: [WorkflowToolDefinition]

    @State private var identity: UUID
    @State private var baselineInterface: WorkflowGraphInterface?
    @State private var draft: WorkflowInterfaceDraft
    @State private var conflict = false
    @State private var error: String?
    @Environment(\.dLanguageStore) private var languageStore

    init(graph: Binding<WorkflowGraph>, registry: WorkflowRegistry, tools: [WorkflowToolDefinition]) {
        _graph = graph
        self.registry = registry
        self.tools = tools
        _identity = State(initialValue: graph.wrappedValue.id)
        _baselineInterface = State(initialValue: graph.wrappedValue.interface)
        _draft = State(initialValue: WorkflowInterfaceDraft(interface: graph.wrappedValue.interface))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if conflict {
                Text(text(
                    "workflow.language.control.externalChange",
                    "The controlled value changed outside this form. Reload before applying this draft."
                )).font(.caption).foregroundStyle(.orange)
                Button(text("workflow.language.control.reload", "Reload"), action: reload)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            Text(text("workflow.language.control.inputs", "Public inputs")).font(.headline)
            ForEach($draft.inputs) { $row in
                inputRow($row)
            }
            Button(text("workflow.language.control.addInput", "Add input")) {
                draft.inputs.append(.init())
            }

            Text(text("workflow.language.control.outputs", "Public outputs")).font(.headline)
            ForEach($draft.outputs) { $row in
                outputRow($row)
            }
            Button(text("workflow.language.control.addOutput", "Add output")) {
                draft.outputs.append(.init())
            }

            HStack {
                Button(text("workflow.language.control.applyInterface", "Apply interface"), action: apply)
                    .disabled(conflict || draft.matches(baselineInterface))
                Button(text("workflow.language.control.reload", "Reload"), action: reload)
                Spacer()
            }
        }
        .onChange(of: graph.id) { _, next in
            guard next != identity else { return }
            reload()
        }
        .onChange(of: graph.interface) { _, next in
            guard graph.id == identity, next != baselineInterface else { return }
            if !draft.matches(baselineInterface) {
                conflict = true
            } else {
                baselineInterface = next
                draft = WorkflowInterfaceDraft(interface: next)
                error = nil
            }
        }
    }

    private var choices: [WorkflowOutputPortChoice] {
        WorkflowControlFormSupport.outputChoices(graph: graph, registry: registry, tools: tools)
    }

    private func inputRow(_ row: Binding<WorkflowInterfaceInputDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(text("workflow.language.control.name", "Name"), text: row.name)
                Toggle(text("workflow.language.control.required", "Required"), isOn: row.required)
                Button(role: .destructive) {
                    draft.inputs.removeAll { $0.id == row.wrappedValue.id }
                } label: { Image(systemName: "minus.circle") }
            }
            WorkflowControlSchemaSampleEditor(schema: row.schema)
        }
        .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func outputRow(_ row: Binding<WorkflowInterfaceOutputDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(text("workflow.language.control.name", "Name"), text: row.name)
                Button(role: .destructive) {
                    draft.outputs.removeAll { $0.id == row.wrappedValue.id }
                } label: { Image(systemName: "minus.circle") }
            }
            Menu(outputSelectionTitle(row.wrappedValue)) {
                if choices.isEmpty {
                    Text(text("workflow.language.control.noPorts", "No output ports available"))
                } else {
                    ForEach(choices) { choice in
                        Button(choice.nodeTitle + " · " + choice.port) {
                            row.wrappedValue.nodeID = choice.nodeID
                            row.wrappedValue.port = choice.port
                        }
                    }
                }
            }
            WorkflowControlSchemaSampleEditor(schema: row.schema)
        }
        .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func outputSelectionTitle(_ row: WorkflowInterfaceOutputDraft) -> String {
        guard let nodeID = row.nodeID else {
            return text("workflow.language.control.choosePort", "Choose node output")
        }
        if let choice = choices.first(where: { $0.nodeID == nodeID && $0.port == row.port }) {
            return choice.nodeTitle + " · " + choice.port
        }
        return text("workflow.language.control.missingPort", "Missing node or port") + " · " + row.port
    }

    private func apply() {
        guard !conflict, graph.id == identity else { return }
        do {
            let interface = try WorkflowControlFormSupport.validatedInterface(draft, choices: choices)
            var next = graph
            next.interface = interface
            graph = next
            guard WorkflowControlFormSupport.interfaceCommitWasAccepted(interface, storedGraph: graph) else {
                self.error = workflowControlErrorText(
                    WorkflowControlFormError.bindingRejected,
                    store: languageStore
                )
                return
            }
            baselineInterface = graph.interface
            error = nil
        } catch {
            self.error = workflowControlErrorText(error, store: languageStore)
        }
    }

    private func reload() {
        identity = graph.id
        baselineInterface = graph.interface
        draft = WorkflowInterfaceDraft(interface: graph.interface)
        conflict = false
        error = nil
    }

    private func text(_ key: String, _ fallback: String) -> String {
        workflowControlText(languageStore, key, fallback: fallback)
    }
}
