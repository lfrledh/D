import Foundation

/// Builds an editable, bounded repair graph for model-produced JSON.
public enum WorkflowJSONRepairTool {
    public static func make(
        schema: WorkflowDataSchema,
        task: String,
        exampleJSON: String,
        maximumRepairs: Int = 2,
        expectedItemCount: Int? = nil
    ) throws -> WorkflowToolDefinition {
        try WorkflowStructuredText.validateSchema(schema)
        let example = try WorkflowStructuredText.parse(exampleJSON, as: schema)
        if let expectedItemCount {
            guard (0...4096).contains(expectedItemCount), case .list = schema,
                  example.items?.count == expectedItemCount else {
                throw WorkflowIssue("The structural example must match the explicit list item count.")
            }
        }
        guard (1...2).contains(maximumRepairs) else {
            throw WorkflowIssue("JSON repair count must be in 1...2.")
        }

        let schemaText = try encodedSchema(schema)
        let reportSchema = WorkflowDataConfiguration.validationReportSchema(for: schema)
        let stateFields: [WorkflowRecordField] = [
            .init("text", .text),
            .init("check", reportSchema),
        ]
        let stateSchema = WorkflowDataSchema.record(stateFields)

        let content = try publicInput("content", schema: .text, fallback: .text(""), title: "Content to structure")
        let taskValue = try valueInput("Requested task", value: .text(task))
        let schemaValue = try valueInput("Complete target schema", value: .text(schemaText))
        let exampleValue = try valueInput("Valid shape example", value: .text(exampleJSON))

        let promptFields: [WorkflowRecordField] = [
            .init("task", .text),
            .init("schema", .text),
            .init("exampleJSON", .text),
        ]
        var initialPromptFields = try node("d.value.record", title: "Collect initial JSON instructions")
        initialPromptFields.dataConfiguration = .init(fields: promptFields)

        var initialPrompt = try node("d.value.template", title: "Describe the complete JSON target")
        initialPrompt.parameters["template"] = .text(initialPromptTemplate)

        let initialLanguage = try languageNode(title: "Generate candidate JSON")
        let initialCheck = try validationNode(
            title: "Check candidate JSON", schema: schema, strict: false, expectedItemCount: expectedItemCount
        )

        var initialState = try node("d.value.record", title: "Keep candidate and validation report")
        initialState.dataConfiguration = .init(fields: stateFields)

        let sharedFields: [WorkflowRecordField] = [
            .init("task", .text),
            .init("schema", .text),
            .init("exampleJSON", .text),
            .init("originalContent", .text),
        ]
        var shared = try node("d.value.record", title: "Keep explicit repair context")
        shared.dataConfiguration = .init(fields: sharedFields)

        var loop = try node("d.control.loop", title: "Repair invalid JSON a bounded number of times")
        loop.control = .loop(
            body: try repairBody(stateSchema: stateSchema, reportSchema: reportSchema, targetSchema: schema, expectedItemCount: expectedItemCount),
            stateSchema: stateSchema,
            maximumIterations: maximumRepairs,
            until: .init(path: ["check", "valid"], comparison: .equals, value: .boolean(true))
        )

        var finalText = try node("d.value.field", title: "Read final candidate text")
        finalText.dataConfiguration = .init(schema: .text, path: ["text"])
        let strictCheck = try validationNode(
            title: "Strictly validate final JSON", schema: schema, strict: true, expectedItemCount: expectedItemCount
        )
        var finalData = try node("d.value.field", title: "Read validated JSON data")
        finalData.dataConfiguration = .init(schema: .optional(schema), path: ["data"])
        var output = try node("d.value.return", title: "Return validated structured data")
        output.parameters["name"] = .text("output")

        let nodes = [
            content, taskValue, schemaValue, exampleValue, initialPromptFields, initialPrompt,
            initialLanguage, initialCheck, initialState, shared, loop, finalText, strictCheck, finalData, output,
        ]
        var graph = WorkflowGraph(
            name: "Bounded JSON repair",
            nodes: nodes,
            connections: [
                connect(taskValue, initialPromptFields, targetPort: "task"),
                connect(schemaValue, initialPromptFields, targetPort: "schema"),
                connect(exampleValue, initialPromptFields, targetPort: "exampleJSON"),
                connect(initialPromptFields, initialPrompt, targetPort: "fields"),
                connect(initialPrompt, initialLanguage, targetPort: "task"),
                connect(content, initialLanguage, targetPort: "content"),
                connect(initialLanguage, initialCheck),
                connect(initialLanguage, initialState, targetPort: "text"),
                connect(initialCheck, initialState, targetPort: "check"),
                connect(taskValue, shared, targetPort: "task"),
                connect(schemaValue, shared, targetPort: "schema"),
                connect(exampleValue, shared, targetPort: "exampleJSON"),
                connect(content, shared, targetPort: "originalContent"),
                connect(initialState, loop),
                connect(shared, loop, targetPort: "shared"),
                connect(loop, finalText),
                connect(finalText, strictCheck),
                connect(strictCheck, finalData),
                connect(finalData, output),
            ],
            layout: WorkflowLanguageExamples.gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [.init("content", .text)],
            outputs: [.init(name: "output", nodeID: output.id, schema: schema)]
        )
        return WorkflowToolDefinition(name: "Bounded JSON repair", graph: graph)
    }

    private static func repairBody(
        stateSchema: WorkflowDataSchema,
        reportSchema: WorkflowDataSchema,
        targetSchema: WorkflowDataSchema,
        expectedItemCount: Int?
    ) throws -> WorkflowGraph {
        let state = try requiredPublicInput("state", schema: stateSchema, title: "Current repair state")
        let iteration = try requiredPublicInput(
            "iteration", schema: .number(unit: nil), title: "Repair iteration"
        )
        let task = try requiredPublicInput("task", schema: .text, title: "Original task")
        let schema = try requiredPublicInput("schema", schema: .text, title: "Complete target schema")
        let example = try requiredPublicInput("exampleJSON", schema: .text, title: "Valid shape example")
        let originalContent = try requiredPublicInput(
            "originalContent", schema: .text, title: "Original content"
        )

        var previousText = try node("d.value.field", title: "Read previous invalid JSON")
        previousText.dataConfiguration = .init(schema: .text, path: ["text"])
        var issues = try node("d.value.field", title: "Read validation issues")
        issues.dataConfiguration = .init(schema: .list(.text), path: ["check", "issues"])
        var firstIssue = try node("d.value.select", title: "Read first validation issue")
        firstIssue.parameters["method"] = .text("index")
        firstIssue.parameters["index"] = .integer(1)

        let repairPromptFields: [WorkflowRecordField] = [
            .init("task", .text),
            .init("schema", .text),
            .init("exampleJSON", .text),
            .init("originalContent", .text),
            .init("previousJSON", .text),
            .init("firstIssue", .text),
            .init("iteration", .number(unit: nil)),
        ]
        var repairPromptFieldsNode = try node("d.value.record", title: "Collect complete repair instructions")
        repairPromptFieldsNode.dataConfiguration = .init(fields: repairPromptFields)
        var repairPrompt = try node("d.value.template", title: "Describe one bounded repair")
        repairPrompt.parameters["template"] = .text(repairPromptTemplate)

        let repairLanguage = try languageNode(title: "Repair candidate JSON")
        let repairedCheck = try validationNode(
            title: "Check repaired JSON", schema: targetSchema, strict: false, expectedItemCount: expectedItemCount
        )
        let nextStateFields: [WorkflowRecordField] = [
            .init("text", .text),
            .init("check", reportSchema),
        ]
        var nextState = try node("d.value.record", title: "Keep repaired candidate and report")
        nextState.dataConfiguration = .init(fields: nextStateFields)
        var result = try node("d.value.return", title: "Return next repair state")
        result.parameters["name"] = .text("state")

        let nodes = [
            state, iteration, task, schema, example, originalContent, previousText, issues, firstIssue,
            repairPromptFieldsNode, repairPrompt, repairLanguage, repairedCheck, nextState, result,
        ]
        var graph = WorkflowGraph(
            name: "Repair one invalid JSON candidate",
            nodes: nodes,
            connections: [
                connect(state, previousText),
                connect(state, issues),
                connect(issues, firstIssue),
                connect(task, repairPromptFieldsNode, targetPort: "task"),
                connect(schema, repairPromptFieldsNode, targetPort: "schema"),
                connect(example, repairPromptFieldsNode, targetPort: "exampleJSON"),
                connect(originalContent, repairPromptFieldsNode, targetPort: "originalContent"),
                connect(previousText, repairPromptFieldsNode, targetPort: "previousJSON"),
                connect(firstIssue, repairPromptFieldsNode, targetPort: "firstIssue"),
                connect(iteration, repairPromptFieldsNode, targetPort: "iteration"),
                connect(repairPromptFieldsNode, repairPrompt, targetPort: "fields"),
                connect(repairPrompt, repairLanguage, targetPort: "task"),
                connect(originalContent, repairLanguage, targetPort: "content"),
                connect(repairLanguage, repairedCheck),
                connect(repairLanguage, nextState, targetPort: "text"),
                connect(repairedCheck, nextState, targetPort: "check"),
                connect(nextState, result),
            ],
            layout: WorkflowLanguageExamples.gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [
                .init("state", stateSchema),
                .init("iteration", .number(unit: nil)),
                .init("task", .text),
                .init("schema", .text),
                .init("exampleJSON", .text),
                .init("originalContent", .text),
            ],
            outputs: [.init(name: "state", nodeID: result.id, schema: stateSchema)]
        )
        return graph
    }

    private static let initialPromptTemplate = """
    Produce one JSON value for the following local workflow task.
    Task:
    {{task}}
    Complete target schema (WorkflowDataSchema JSON encoding):
    {{schema}}
    Valid structural example (shape only; do not copy its content as the answer):
    {{exampleJSON}}
    Use the separately supplied content as the source. Return exactly one JSON value matching the complete schema. Do not return Markdown fences or an explanation.
    """

    private static let repairPromptTemplate = """
    Repair attempt {{iteration}} for a JSON value produced for this local workflow.
    Original task:
    {{task}}
    Complete target schema (WorkflowDataSchema JSON encoding):
    {{schema}}
    Valid structural example (shape only; do not copy its content as the answer):
    {{exampleJSON}}
    Original source content:
    {{originalContent}}
    Previous invalid JSON (preserve its intended content where compatible):
    {{previousJSON}}
    First validation issue:
    {{firstIssue}}
    Return exactly one corrected JSON value matching the complete schema. Do not return Markdown fences or an explanation.
    """

    private static func encodedSchema(_ schema: WorkflowDataSchema) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(schema), as: UTF8.self)
    }

    private static func languageNode(title: String) throws -> WorkflowNode {
        var result = try node("d.model.language", title: title)
        result.parameters["modelID"] = .text("")
        result.parameters["outputMode"] = .text("text")
        // A short editable recipe should not reserve the entire supported context by default.
        result.parameters["maximumPromptTokens"] = .integer(4_096)
        result.parameters["maximumOutputTokens"] = .integer(768)
        result.parameters["temperature"] = .decimal(0)
        return result
    }

    private static func validationNode(
        title: String,
        schema: WorkflowDataSchema,
        strict: Bool,
        expectedItemCount: Int?
    ) throws -> WorkflowNode {
        var result = try node("d.value.validate", title: title)
        result.parameters["strict"] = .flag(strict)
        if let expectedItemCount { result.parameters["expectedItemCount"] = .integer(expectedItemCount) }
        result.dataConfiguration = .init(schema: schema, validationInputFormat: .jsonText)
        return result
    }

    private static func node(_ operationID: String, title: String) throws -> WorkflowNode {
        guard let operation = WorkflowRegistry.standard.operation(operationID) else {
            throw WorkflowIssue("JSON repair tool requires unregistered operation: \(operationID).")
        }
        var result = operation.definition.makeNode()
        result.title = title
        return result
    }

    private static func valueInput(_ title: String, value: WorkflowDatum) throws -> WorkflowNode {
        var result = try node("d.value.input", title: title)
        result.dataConfiguration = .init(value: value)
        return result
    }

    private static func publicInput(
        _ name: String,
        schema: WorkflowDataSchema,
        fallback: WorkflowDatum,
        title: String
    ) throws -> WorkflowNode {
        try fallback.validate(as: schema)
        var result = try valueInput(title, value: fallback)
        result.parameters["publicName"] = .text(name)
        return result
    }

    private static func requiredPublicInput(
        _ name: String,
        schema: WorkflowDataSchema,
        title: String
    ) throws -> WorkflowNode {
        try schema.validateDefinition()
        var result = try node("d.value.input", title: title)
        result.parameters["publicName"] = .text(name)
        result.dataConfiguration = .init(schema: schema)
        return result
    }

    private static func connect(
        _ source: WorkflowNode,
        _ target: WorkflowNode,
        sourcePort: String = "output",
        targetPort: String = "input"
    ) -> WorkflowConnection {
        .init(
            sourceNode: source.id,
            sourcePort: sourcePort,
            targetNode: target.id,
            targetPort: targetPort
        )
    }

}
