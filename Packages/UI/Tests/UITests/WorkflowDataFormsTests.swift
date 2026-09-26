import DWorkbench
import Foundation
import Testing
@testable import UI

@Suite @MainActor
struct WorkflowDataFormsTests {
    @Test func connectedFieldsFollowActualWiringAndPreserveLiteralNames() throws {
        let registry = WorkflowRegistry.standard
        var record = try #require(registry.operation("d.value.record")).definition.makeNode()
        let fields = [WorkflowRecordField("音高.Hz", .number(unit: "Hz")), WorkflowRecordField("文本", .text)]
        record.dataConfiguration = .init(fields: fields)
        let field = try #require(registry.operation("d.value.field")).definition.makeNode()
        var graph = WorkflowGraph(name: "menu source", nodes: [record, field], connections: [.init(sourceNode: record.id, targetNode: field.id)])
        #expect(WorkflowFormSupport.connectedRecordFields(nodeID: field.id, graph: graph, tools: []) == fields)
        graph.nodes[0].dataConfiguration?.fields = [.init("改名", .boolean)]
        #expect(WorkflowFormSupport.connectedRecordFields(nodeID: field.id, graph: graph, tools: []).map(\.name) == ["改名"])
        graph.connections = []
        #expect(WorkflowFormSupport.connectedRecordFields(nodeID: field.id, graph: graph, tools: []).isEmpty)
    }

    @Test func connectedFieldsUseDeclaredModelSchemaWithoutRunningOrParsingLabels() throws {
        let registry = WorkflowRegistry.standard
        var language = try #require(registry.operation("d.model.language")).definition.makeNode()
        language.parameters["outputMode"] = .text("json")
        let fields = [WorkflowRecordField("title", .text)]
        language.dataConfiguration = .init(schema: .record(fields))
        let field = try #require(registry.operation("d.value.field")).definition.makeNode()
        var graph = WorkflowGraph(name: "not installed", nodes: [language, field], connections: [.init(sourceNode: language.id, targetNode: field.id)])
        #expect(WorkflowFormSupport.connectedRecordFields(nodeID: field.id, graph: graph, tools: []) == fields)
        graph.nodes[0].parameters["outputMode"] = .text("text")
        #expect(WorkflowFormSupport.connectedRecordFields(nodeID: field.id, graph: graph, tools: []).isEmpty)
        graph.connections[0].sourcePort = "raw"
        #expect(WorkflowFormSupport.connectedRecordFields(nodeID: field.id, graph: graph, tools: []).isEmpty)
    }

    @Test
    func incompleteNumberPreservesTheLastValidDatum() {
        let original = WorkflowDatum.number(12.5, unit: "Hz")
        var state = WorkflowDatumFormState(numberDraft: "12.5")

        let incomplete = state.updateNumber("-", unit: "Hz", current: original)
        #expect(incomplete == original)
        #expect(state.numberDraft == "-")
        #expect(state.error != nil)

        let repaired = state.updateNumber("13.25", unit: "Hz", current: original)
        #expect(repaired == .number(13.25, unit: "Hz"))
        #expect(state.error == nil)
    }

    @Test
    func explicitSeedsNeverChooseAnEnumOption() {
        #expect(WorkflowDatumSeedKind.text.seed == .text(""))
        #expect(WorkflowDatumSeedKind.number.seed == .number(0, unit: nil))
        #expect(WorkflowDatumSeedKind.boolean.seed == .boolean(false))
        #expect(WorkflowDatumSeedKind.enumeration.seed == nil)
        #expect(WorkflowDatumSeedKind.record.seed == .record(schema: [], fields: [:]))
        #expect(WorkflowDatumSeedKind.list.seed == .list(element: .text, items: []))
        #expect(WorkflowDatumSeedKind.optional.seed == .none(.text))
    }

    @Test
    func incompleteEnumEditsRetainTheLastPublishedValue() {
        let committed = WorkflowDatum.enumeration("A", choices: ["A", "B"])
        var state = WorkflowEnumerationFormState(value: committed, choices: ["A", "B"])
        #expect(state.candidate == committed)

        let afterRemovingSelection = state.remove("A")
        #expect(afterRemovingSelection == nil)
        #expect(state.choices == ["B"])
        #expect(state.selected == nil)
        #expect(state.isIncomplete)
        #expect(committed == .enumeration("A", choices: ["A", "B"]))

        let repaired = state.select("B")
        #expect(repaired == .enumeration("B", choices: ["B"]))
        #expect(!state.isIncomplete)
    }

    @Test
    func invalidEnumDefinitionNeverReplacesTheLastPublishedValue() {
        let committed = WorkflowDatum.enumeration("A", choices: ["A", "B"])
        var published = committed
        var longOptionState = WorkflowEnumerationFormState(value: committed, choices: ["A", "B"])
        let longOption = String(repeating: "x", count: 1_025)
        longOptionState.choiceDraft = longOption

        let longOptionCandidate = longOptionState.addDraftChoice()
        if let longOptionCandidate { published = longOptionCandidate }
        #expect(longOptionCandidate == nil)
        #expect(longOptionState.choices.last == longOption)
        #expect(longOptionState.isIncomplete)
        #expect(published == committed)

        let maximumChoices = (0..<256).map { "choice-\($0)" }
        let maximumDatum = WorkflowDatum.enumeration(maximumChoices[0], choices: maximumChoices)
        published = maximumDatum
        var countState = WorkflowEnumerationFormState(value: maximumDatum, choices: maximumChoices)
        countState.choiceDraft = "choice-256"

        let tooManyChoicesCandidate = countState.addDraftChoice()
        if let tooManyChoicesCandidate { published = tooManyChoicesCandidate }
        #expect(tooManyChoicesCandidate == nil)
        #expect(countState.choices.count == 257)
        #expect(countState.choices.last == "choice-256")
        #expect(countState.isIncomplete)
        #expect(published == maximumDatum)
    }

    @Test
    func explicitEnumSelectionCanCreateListItemsWithoutChoosingFirst() throws {
        let schema = WorkflowDataSchema.enumeration(["red", "blue"])
        var state = WorkflowEnumerationFormState(value: nil, choices: ["red", "blue"])
        #expect(state.selected == nil)
        #expect(state.candidate == nil)
        #expect(WorkflowFormSupport.appendingItem(to: [], schema: schema, id: "color") == nil)

        let selectedCandidate = state.select("blue")
        let selected = try #require(selectedCandidate)
        let items = try #require(WorkflowFormSupport.appendingExplicitItem(
            to: [], schema: schema, id: "color", value: selected
        ))
        #expect(items == [WorkflowDataItem(id: "color", value: .enumeration("blue", choices: ["red", "blue"]))])
    }

    @Test
    func depthEightIsReadOnlyWithoutTruncatingSchema() {
        #expect(!WorkflowFormSupport.isReadOnlyDepth(0))
        #expect(!WorkflowFormSupport.isReadOnlyDepth(7))
        #expect(WorkflowFormSupport.isReadOnlyDepth(8))
        let nested = WorkflowDataSchema.optional(.list(.record([
            WorkflowRecordField("value", .enumeration(["保留"])),
        ])))
        #expect(WorkflowFormSupport.schema(at: ["value"], in: .record([
            WorkflowRecordField("value", nested),
        ])) == nested)
    }

    @Test
    func stableNamedRowDraftDoesNotMoveAfterPredecessorDeletion() {
        var rows = WorkflowStableNamedRows(names: ["A", "B"])
        let firstID = rows.rows[0].id
        let secondID = rows.rows[1].id
        var second = WorkflowNamedRowFormState(id: "B")
        let incompleteRename = second.proposeName("", siblingNames: Set(["A"]))
        #expect(incompleteRename == nil)
        #expect(second.nameDraft == "")
        #expect(second.hasInvalidName)

        rows.rename(id: firstID, to: "A-renamed")
        #expect(rows.rows[0].id == firstID)
        #expect(rows.rows[0].fieldName == "A-renamed")
        #expect(rows.rows[1].id == secondID)
        #expect(second.nameDraft == "")

        rows.remove(id: firstID)
        #expect(rows.rows.map(\.id) == [secondID])
        #expect(rows.rows[0].fieldName == "B")
        #expect(second.nameDraft == "")
        #expect(second.hasInvalidName)
    }

    @Test
    func listInsertionAndMovementPreserveStableIdentity() throws {
        let first = WorkflowDataItem(id: "first", value: .text("same"))
        let second = WorkflowDataItem(id: "second", value: .text("same"))
        let appended = try #require(WorkflowFormSupport.appendingItem(
            to: [first, second], schema: .text, id: "third"
        ))
        #expect(appended.map(\.id) == ["first", "second", "third"])

        let moved = WorkflowFormSupport.moved(appended, from: 2, by: -1)
        #expect(moved.map(\.id) == ["first", "third", "second"])
        #expect(moved.first(where: { $0.id == "second" })?.value == .text("same"))
    }

    @Test
    func recordFallbackRenameKeepsValuesAndOptionalAbsence() throws {
        let fields = [
            WorkflowRecordField("required", .text),
            WorkflowRecordField("optional", .number(unit: nil), required: false),
        ]
        let configuration = WorkflowDataConfiguration(
            value: .record(schema: fields, fields: ["required": .text("组合字符 e\u{301}")]),
            fields: fields
        )

        let renamed = try WorkflowFormSupport.replacingField(
            in: configuration, at: 0, name: "literal.with.dot"
        )
        #expect(renamed.fields.map(\.name) == ["literal.with.dot", "optional"])
        guard case .record(let schema, let fallback)? = renamed.value else {
            Issue.record("Expected record fallback")
            return
        }
        #expect(schema == renamed.fields)
        #expect(fallback["literal.with.dot"] == .text("组合字符 e\u{301}"))
        #expect(fallback["optional"] == nil)
    }

    @Test
    func invalidFieldTypeChangePreservesTheValidConfiguration() throws {
        let fields = [WorkflowRecordField("value", .text)]
        let configuration = WorkflowDataConfiguration(
            value: .record(schema: fields, fields: ["value": .text("keep")]),
            fields: fields
        )

        #expect(throws: WorkflowIssue.self) {
            _ = try WorkflowFormSupport.replacingField(
                in: configuration, at: 0, type: .enumeration([])
            )
        }
        #expect(configuration.fields == fields)
        #expect(configuration.value == .record(schema: fields, fields: ["value": .text("keep")]))
    }

    @Test
    func pathsKeepLiteralComponentsIncludingDots() {
        let nested = [WorkflowRecordField("literal.with.dot", .record([
            WorkflowRecordField("子字段", .text),
        ]))]
        let paths = WorkflowFormSupport.recordPaths(in: nested)
        #expect(paths.contains(["literal.with.dot"]))
        #expect(paths.contains(["literal.with.dot", "子字段"]))
        #expect(!paths.contains(["literal", "with", "dot"]))
    }

    @Test
    func singleChoiceUsesStableIDAndDoesNotAutoSelectEqualValues() throws {
        let items = [
            WorkflowDataItem(id: "a", value: .text("duplicate")),
            WorkflowDataItem(id: "b", value: .text("duplicate")),
        ]
        let resultSchema = WorkflowDataSchema.record([
            WorkflowRecordField("id", .text),
            WorkflowRecordField("value", .text),
        ])
        let task = WorkflowHumanTask(
            id: UUID(), kind: .singleChoice, title: "Choose",
            materials: .list(element: .text, items: items), resultSchema: resultSchema
        )
        var state = WorkflowHumanTaskFormState(task: task)
        #expect(state.selectedItemIDs.isEmpty)
        #expect(!state.canSubmit)

        let selectedCandidate = state.selectSingle("b", taskID: task.id)
        let draft = try #require(selectedCandidate)
        try draft.validate(as: resultSchema)
        guard case .record(_, let fields) = draft else {
            Issue.record("Expected selected record")
            return
        }
        #expect(fields["id"] == .text("b"))
        #expect(fields["value"] == .text("duplicate"))
        #expect(state.canSubmit)
    }

    @Test
    func multipleChoicePreservesMaterialOrderAndStableIDs() throws {
        let items = [
            WorkflowDataItem(id: "first", value: .text("1")),
            WorkflowDataItem(id: "second", value: .text("2")),
            WorkflowDataItem(id: "third", value: .text("3")),
        ]
        let task = WorkflowHumanTask(
            id: UUID(), kind: .multipleChoice, title: "Choose many",
            materials: .list(element: .text, items: items), resultSchema: .list(.text)
        )
        var state = WorkflowHumanTaskFormState(task: task)
        _ = state.toggleMultiple("third", taskID: task.id)
        let selectedCandidate = state.toggleMultiple("first", taskID: task.id)
        let draft = try #require(selectedCandidate)
        guard case .list(let element, let selected) = draft else {
            Issue.record("Expected selected list")
            return
        }
        #expect(element == .text)
        #expect(selected.map(\.id) == ["first", "third"])

        _ = state.toggleMultiple("first", taskID: task.id)
        _ = state.toggleMultiple("third", taskID: task.id)
        guard case .list(_, let empty)? = state.candidate else {
            Issue.record("Expected an explicitly empty list")
            return
        }
        #expect(empty.isEmpty)
        #expect(state.canSubmit)
    }

    @Test
    func incompatibleChoiceSchemaCannotSubmitOrCreateDraft() {
        let materials = WorkflowDatum.list(
            element: .text,
            items: [WorkflowDataItem(id: "stable", value: .text("value"))]
        )
        let task = WorkflowHumanTask(
            id: UUID(), kind: .singleChoice, title: "Bad contract",
            materials: materials, resultSchema: .text
        )
        var state = WorkflowHumanTaskFormState(task: task)
        #expect(state.error == .incompatibleResultSchema)
        #expect(state.selectSingle("stable", taskID: task.id) == nil)
        #expect(!state.canSubmit)
    }

    @Test
    func approvalHasNoImplicitValueAndRequiresAnExplicitChoice() {
        let task = WorkflowHumanTask(
            id: UUID(), kind: .approve, title: "Approval",
            materials: .text("Review this"), resultSchema: .boolean
        )
        var state = WorkflowHumanTaskFormState(task: task)
        #expect(state.draft == nil)
        #expect(!state.canSubmit)
        #expect(state.chooseApproval(false, taskID: task.id) == .boolean(false))
        #expect(state.canSubmit)
    }

    @Test
    func reparableDraftErrorsRecoverForApprovalAndChoices() throws {
        var approval = WorkflowHumanTask(
            id: UUID(), kind: .approve, title: "Approval",
            materials: .text("Review"), resultSchema: .boolean
        )
        approval.draft = .text("wrong")
        var approvalState = WorkflowHumanTaskFormState(task: approval)
        #expect(approvalState.error == .invalidDraft)
        #expect(approvalState.chooseApproval(true, taskID: approval.id) == .boolean(true))
        #expect(approvalState.error == nil)

        let item = WorkflowDataItem(id: "choice", value: .text("same"))
        let singleSchema = WorkflowDataSchema.record([
            WorkflowRecordField("id", .text), WorkflowRecordField("value", .text),
        ])
        var single = WorkflowHumanTask(
            id: UUID(), kind: .singleChoice, title: "Single",
            materials: .list(element: .text, items: [item]), resultSchema: singleSchema
        )
        single.draft = .text("wrong")
        var singleState = WorkflowHumanTaskFormState(task: single)
        #expect(singleState.error == .invalidDraft)
        let singleCandidate = singleState.selectSingle("choice", taskID: single.id)
        _ = try #require(singleCandidate)
        #expect(singleState.error == nil)

        var multiple = WorkflowHumanTask(
            id: UUID(), kind: .multipleChoice, title: "Multiple",
            materials: .list(element: .text, items: [item]), resultSchema: .list(.text)
        )
        multiple.draft = .text("wrong")
        var multipleState = WorkflowHumanTaskFormState(task: multiple)
        #expect(multipleState.error == .invalidDraft)
        #expect(!multipleState.canSubmit)
        let multipleCandidate = multipleState.toggleMultiple("choice", taskID: multiple.id)
        _ = try #require(multipleCandidate)
        #expect(multipleState.error == nil)
    }

    @Test
    func staleTaskIdentityCannotMutateReplacementState() {
        let oldID = UUID()
        let replacement = WorkflowHumanTask(
            id: UUID(), kind: .approve, title: "Replacement",
            materials: .text("Review"), resultSchema: .boolean
        )
        var state = WorkflowHumanTaskFormState(task: replacement)
        #expect(state.chooseApproval(true, taskID: oldID) == nil)
        #expect(state.draft == nil)
        #expect(state.selectedItemIDs.isEmpty)
        #expect(state.chooseApproval(false, taskID: replacement.id) == .boolean(false))

        let enumTaskA = WorkflowHumanTask(
            id: UUID(), kind: .editMusic, title: "A",
            materials: .enumeration("A", choices: ["A", "B"]),
            resultSchema: .enumeration(["A", "B"])
        )
        let enumTaskB = WorkflowHumanTask(
            id: UUID(), kind: .editMusic, title: "B",
            materials: .enumeration("Y", choices: ["X", "Y"]),
            resultSchema: .enumeration(["X", "Y"])
        )
        let enumStateA = WorkflowHumanTaskFormState(task: enumTaskA)
        var enumStateB = WorkflowHumanTaskFormState(task: enumTaskB)
        #expect(enumStateA.draft == .enumeration("A", choices: ["A", "B"]))
        #expect(enumStateB.draft == .enumeration("Y", choices: ["X", "Y"]))
        #expect(enumStateB.updateDraft(
            .enumeration("B", choices: ["A", "B"]), taskID: enumTaskA.id
        ) == nil)
        #expect(enumStateB.draft == .enumeration("Y", choices: ["X", "Y"]))

        let oldEditor = WorkflowEnumerationFormState(
            value: .enumeration("A", choices: ["A", "B"]), choices: ["A", "B"]
        )
        let replacementEditor = WorkflowEnumerationFormState(
            value: .enumeration("Y", choices: ["X", "Y"]), choices: ["X", "Y"]
        )
        #expect(oldEditor.choices == ["A", "B"])
        #expect(replacementEditor.choices == ["X", "Y"])
        #expect(replacementEditor.selected == "Y")

        let oldNumberEditor = WorkflowDatumFormState(numberDraft: "12.")
        let replacementNumberEditor = WorkflowDatumFormState(numberDraft: "99")
        #expect(oldNumberEditor.numberDraft == "12.")
        #expect(replacementNumberEditor.numberDraft == "99")
    }

    @Test
    func replacementTaskIsNotRenderedUntilItsMatchingStateIsInstalled() {
        let taskA = WorkflowHumanTask(
            id: UUID(), kind: .editMusic, title: "A",
            materials: .number(12, unit: nil), resultSchema: .number(unit: nil)
        )
        let taskB = WorkflowHumanTask(
            id: UUID(), kind: .editMusic, title: "B",
            materials: .number(99, unit: nil), resultSchema: .number(unit: nil)
        )
        var state = WorkflowHumanTaskFormState(task: taskA)
        #expect(state.isReadyToRender(taskID: taskA.id))
        #expect(!state.isReadyToRender(taskID: taskB.id))

        let staleSubmission = state.validatedCandidate(taskID: taskB.id)
        #expect(staleSubmission == nil)
        #expect(state.draft == .number(12, unit: nil))

        state = WorkflowHumanTaskFormState(task: taskB)
        #expect(state.isReadyToRender(taskID: taskB.id))
        #expect(!state.isReadyToRender(taskID: taskA.id))
        #expect(state.draft == .number(99, unit: nil))
        let replacementSubmission = state.validatedCandidate(taskID: taskB.id)
        #expect(replacementSubmission == .number(99, unit: nil))
    }

    @Test
    func textDraftPreservesChineseAndComposedCharacters() throws {
        let taskID = UUID()
        let task = WorkflowHumanTask(
            id: taskID, kind: .editText, title: "Edit",
            materials: .text("初稿"), resultSchema: .text
        )
        var state = WorkflowHumanTaskFormState(task: task)
        #expect(state.displayedTaskID == taskID)
        let text = "中文输入 e\u{301} 👩🏽‍🎨"
        #expect(state.updateDraft(.text(text), taskID: task.id) == .text(text))
        #expect(state.draft == .text(text))

        let replacement = WorkflowHumanTask(
            id: UUID(), kind: .editText, title: "Other",
            materials: .text("另一任务"), resultSchema: .text
        )
        let replacementState = WorkflowHumanTaskFormState(task: replacement)
        #expect(replacementState.displayedTaskID != state.displayedTaskID)
        #expect(replacementState.draft == .text("另一任务"))
    }

    @Test
    func invalidMusicDraftIsPreservedButNotReturnedForSaving() {
        let task = WorkflowHumanTask(
            id: UUID(), kind: .editMusic, title: "Music",
            materials: .record(schema: [], fields: [:]), resultSchema: .number(unit: "Hz")
        )
        var state = WorkflowHumanTaskFormState(task: task)
        let invalid = WorkflowDatum.text("unfinished")
        #expect(state.updateDraft(invalid, taskID: task.id) == nil)
        #expect(state.draft == invalid)
        #expect(state.error == .invalidDraft)
        #expect(!state.canSubmit)
    }
}
