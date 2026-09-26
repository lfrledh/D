import DWorkbench
import Foundation
import Testing
@testable import UI

@Suite @MainActor
struct WorkflowControlFormsTests {
    @Test
    func generatedBodiesCompileAndExposeExecutorKeys() throws {
        let compiler = WorkflowPlanCompiler()

        let branch = try WorkflowControlFormSupport.makeDefaultControl(operationID: "d.control.branch")
        guard case .branch(_, let thenGraph, let otherwiseGraph) = branch else {
            Issue.record("Expected branch control")
            return
        }
        #expect(try compiler.compile(thenGraph).interface.outputs.map(\.name) == ["output"])
        #expect(try compiler.compile(otherwiseGraph).interface.outputs.map(\.name) == ["output"])

        let map = try WorkflowControlFormSupport.makeDefaultControl(operationID: "d.control.map")
        guard case .map(let mapBody, _) = map else {
            Issue.record("Expected map control")
            return
        }
        let mapPlan = try compiler.compile(mapBody)
        #expect(mapPlan.interface.inputs.map(\.name) == WorkflowControlFormSupport.mapVariableNames)
        #expect(mapPlan.interface.outputs.map(\.name) == ["output"])

        let loop = try WorkflowControlFormSupport.makeDefaultControl(operationID: "d.control.loop")
        guard case .loop(let loopBody, let schema, let maximum, _) = loop else {
            Issue.record("Expected loop control")
            return
        }
        let loopPlan = try compiler.compile(loopBody)
        #expect(loopPlan.interface.inputs.map(\.name) == WorkflowControlFormSupport.loopVariableNames)
        #expect(loopPlan.interface.inputs.first(where: { $0.name == "iteration" })?.required == false)
        #expect(loopPlan.interface.outputs.map(\.name) == ["nextState"])
        #expect(loopPlan.interface.outputs.first?.schema == schema)
        #expect(maximum == 1)
    }

    @Test
    func toolSelectionPinsDigestAndSynchronizesOnlyInvocationFields() throws {
        let body = try WorkflowControlFormSupport.makeBody(
            name: "工具",
            inputs: [WorkflowRecordField("提示", .text)],
            passthrough: "提示",
            outputName: "output"
        )
        let tool = WorkflowToolDefinition(id: UUID(), version: 7, name: "固定工具", graph: body)
        var node = WorkflowRegistry.standard.operation("d.control.invoke")!.definition.makeNode()
        node.dataConfiguration = .init(schema: .boolean, path: ["preserve"])

        let selected = try WorkflowControlFormSupport.selecting(tool: tool, in: .init(node: node))
        guard case .invoke(let reference) = selected.control else {
            Issue.record("Expected invocation reference")
            return
        }
        #expect(reference.id == tool.id)
        #expect(reference.version == 7)
        #expect(reference.digest == (try WorkflowPlanCompiler.digest(tool)))
        #expect(selected.dataConfiguration?.fields == body.interface?.inputs)
        #expect(selected.dataConfiguration?.schema == .boolean)
        #expect(selected.dataConfiguration?.path == ["preserve"])
        try WorkflowControlFormSupport.validate(selected, operationID: "d.control.invoke", tools: [tool])
    }

    @Test
    func missingToolAndChangedDigestRemainInvalidInsteadOfSelectingAReplacement() throws {
        let body = try WorkflowControlFormSupport.makeBody(
            name: "Body", inputs: [WorkflowRecordField("input", .text)],
            passthrough: "input", outputName: "output"
        )
        let original = WorkflowToolDefinition(id: UUID(), version: 1, name: "Original", graph: body)
        let replacement = WorkflowToolDefinition(id: UUID(), version: 1, name: "Replacement", graph: body)
        var node = WorkflowRegistry.standard.operation("d.control.invoke")!.definition.makeNode()
        let selected = try WorkflowControlFormSupport.selecting(tool: original, in: .init(node: node))
        node.control = selected.control
        node.dataConfiguration = selected.dataConfiguration

        #expect(throws: (any Error).self) {
            try WorkflowControlFormSupport.validate(.init(node: node), operationID: node.operationID, tools: [replacement])
        }

        var changed = original
        changed.name = "Changed content"
        #expect(throws: (any Error).self) {
            try WorkflowControlFormSupport.validate(.init(node: node), operationID: node.operationID, tools: [changed])
        }
        #expect(node.control == selected.control)
    }

    @Test
    func duplicateAndInvalidInterfaceDraftsDoNotReplaceThePublishedValue() throws {
        let node = WorkflowRegistry.standard.operation("d.value.return")!.definition.makeNode()
        var graph = WorkflowGraph(nodes: [node])
        let published = WorkflowGraphInterface(
            inputs: [WorkflowRecordField("原值", .text)],
            outputs: [WorkflowNamedOutput(name: "结果", nodeID: node.id, schema: .text)]
        )
        graph.interface = published
        let choices = WorkflowControlFormSupport.outputChoices(
            graph: graph, registry: .standard, tools: []
        )

        var duplicate = WorkflowInterfaceDraft(interface: published)
        duplicate.inputs.append(.init(name: "原值", schema: .number(unit: nil)))
        #expect(throws: (any Error).self) {
            try WorkflowControlFormSupport.validatedInterface(duplicate, choices: choices)
        }
        #expect(graph.interface == published)

        var wrongKind = WorkflowInterfaceDraft(interface: published)
        wrongKind.outputs[0].schema = .asset(.image)
        let textOnly = [WorkflowOutputPortChoice(
            nodeID: node.id, nodeTitle: node.title, port: "output", kinds: [.text]
        )]
        #expect(throws: (any Error).self) {
            try WorkflowControlFormSupport.validatedInterface(wrongKind, choices: textOnly)
        }
        #expect(graph.interface == published)
    }

    @Test
    func outputRequiresTheExactExistingPortWithoutGuessingByName() throws {
        let nodeID = UUID()
        let choice = WorkflowOutputPortChoice(
            nodeID: nodeID, nodeTitle: "节点", port: "真实端口", kinds: [.text, .notes]
        )
        let valid = WorkflowInterfaceDraft(interface: WorkflowGraphInterface(outputs: [
            WorkflowNamedOutput(name: "输出", nodeID: nodeID, port: "真实端口", schema: .text),
        ]))
        #expect(try WorkflowControlFormSupport.validatedInterface(valid, choices: [choice]).outputs.first?.port == "真实端口")

        var missing = valid
        missing.outputs[0].port = "输出"
        #expect(throws: (any Error).self) {
            try WorkflowControlFormSupport.validatedInterface(missing, choices: [choice])
        }
    }

    @Test
    func rowIdentitySurvivesUnicodeRenameAndIsNotDerivedFromTheName() {
        let originalName = "输入👩🏽‍🎨e\u{301}"
        var draft = WorkflowInterfaceDraft(interface: WorkflowGraphInterface(inputs: [
            WorkflowRecordField(originalName, .text),
        ]))
        let id = draft.inputs[0].id

        draft.renameInput(id: id, to: "改名🎼")

        #expect(draft.inputs[0].id == id)
        #expect(draft.inputs[0].name == "改名🎼")
        #expect(draft.inputs[0].id.uuidString != originalName)
    }

    @Test
    func assetAndResultSchemasCannotBeInferredAsNewControlSchemas() {
        #expect(WorkflowControlFormSupport.acceptsNewSchema(.text))
        #expect(WorkflowControlFormSupport.acceptsNewSchema(.record([
            WorkflowRecordField("列表", .list(.boolean)),
        ])))
        #expect(!WorkflowControlFormSupport.acceptsNewSchema(.asset(.image)))
        #expect(!WorkflowControlFormSupport.acceptsNewSchema(.result(.text)))
        #expect(!WorkflowControlFormSupport.acceptsNewSchema(.list(.asset(.audio))))
    }
}
