import DWorkbench
import SwiftUI

enum WorkflowHumanTaskFormError: Equatable {
    case incompatibleMaterials
    case incompatibleResultSchema
    case invalidDraft
}

struct WorkflowHumanTaskFormState: Equatable {
    let displayedTaskID: UUID
    let kind: WorkflowHumanTaskKind
    let resultSchema: WorkflowDataSchema
    let choiceElement: WorkflowDataSchema?
    let choiceItems: [WorkflowDataItem]
    var draft: WorkflowDatum?
    var selectedItemIDs: Set<String>
    let contractError: WorkflowHumanTaskFormError?
    var draftIsInvalid: Bool
    var hasExplicitInput: Bool

    var error: WorkflowHumanTaskFormError? {
        contractError ?? (draftIsInvalid ? .invalidDraft : nil)
    }

    init(task: WorkflowHumanTask) {
        displayedTaskID = task.id
        kind = task.kind
        resultSchema = task.resultSchema
        draft = task.draft
        selectedItemIDs = []

        if case .list(let element, let items) = task.materials {
            choiceElement = element
            choiceItems = items
        } else {
            choiceElement = nil
            choiceItems = []
        }

        contractError = Self.contractError(task)
        draftIsInvalid = false
        hasExplicitInput = false
        guard contractError == nil else { return }

        if let draft = task.draft {
            do {
                try draft.validate(as: task.resultSchema)
                selectedItemIDs = Self.selectionIDs(from: draft, kind: task.kind, items: choiceItems)
                if task.kind == .singleChoice, selectedItemIDs.count != 1 {
                    draftIsInvalid = true
                } else if task.kind == .multipleChoice,
                          case .list(_, let selected) = draft,
                          selected.count != selectedItemIDs.count {
                    draftIsInvalid = true
                } else {
                    hasExplicitInput = true
                }
            } catch {
                draftIsInvalid = true
            }
        } else if task.kind == .editText, case .text = task.materials {
            draft = task.materials
            hasExplicitInput = true
        } else if task.kind == .editMusic {
            do {
                try task.materials.validate(as: task.resultSchema)
                draft = task.materials
                hasExplicitInput = true
            } catch {
                // Music materials may be contextual rather than an editable result. Start empty in that case.
            }
        }
    }

    var candidate: WorkflowDatum? {
        guard contractError == nil, hasExplicitInput else { return nil }
        switch kind {
        case .singleChoice:
            guard selectedItemIDs.count == 1,
                  let selected = choiceItems.first(where: { selectedItemIDs.contains($0.id) }),
                  let element = choiceElement else { return nil }
            let fields = [
                WorkflowRecordField("id", .text),
                WorkflowRecordField("value", element),
            ]
            return .record(schema: fields, fields: ["id": .text(selected.id), "value": selected.value])
        case .multipleChoice:
            guard let element = choiceElement else { return nil }
            return .list(element: element, items: choiceItems.filter { selectedItemIDs.contains($0.id) })
        case .editText, .approve, .editMusic:
            return draft
        }
    }

    var canSubmit: Bool {
        guard let candidate else { return false }
        return (try? candidate.validate(as: resultSchema)) != nil
    }

    func isReadyToRender(taskID: UUID) -> Bool {
        displayedTaskID == taskID
    }

    mutating func updateDraft(_ value: WorkflowDatum?, taskID: UUID) -> WorkflowDatum? {
        guard displayedTaskID == taskID, contractError == nil else { return nil }
        draft = value
        hasExplicitInput = true
        guard let value else { return nil }
        do {
            try value.validate(as: resultSchema)
            draftIsInvalid = false
            return value
        } catch {
            draftIsInvalid = true
            return nil
        }
    }

    mutating func selectSingle(_ id: String, taskID: UUID) -> WorkflowDatum? {
        guard displayedTaskID == taskID, contractError == nil, kind == .singleChoice,
              choiceItems.contains(where: { $0.id == id }) else { return nil }
        selectedItemIDs = [id]
        hasExplicitInput = true
        return validatedCandidate(taskID: taskID)
    }

    mutating func toggleMultiple(_ id: String, taskID: UUID) -> WorkflowDatum? {
        guard displayedTaskID == taskID, contractError == nil, kind == .multipleChoice,
              choiceItems.contains(where: { $0.id == id }) else { return nil }
        if !selectedItemIDs.insert(id).inserted { selectedItemIDs.remove(id) }
        hasExplicitInput = true
        return validatedCandidate(taskID: taskID)
    }

    mutating func chooseApproval(_ approved: Bool, taskID: UUID) -> WorkflowDatum? {
        guard displayedTaskID == taskID, contractError == nil, kind == .approve else { return nil }
        draft = .boolean(approved)
        hasExplicitInput = true
        return validatedCandidate(taskID: taskID)
    }

    mutating func validatedCandidate(taskID: UUID) -> WorkflowDatum? {
        guard displayedTaskID == taskID, contractError == nil else { return nil }
        guard let candidate else { return nil }
        do {
            try candidate.validate(as: resultSchema)
            draft = candidate
            draftIsInvalid = false
            return candidate
        } catch {
            draftIsInvalid = true
            return nil
        }
    }

    private static func contractError(_ task: WorkflowHumanTask) -> WorkflowHumanTaskFormError? {
        switch task.kind {
        case .editText:
            guard task.resultSchema == .text, case .text = task.materials else { return .incompatibleResultSchema }
        case .approve:
            guard task.resultSchema == .boolean else { return .incompatibleResultSchema }
        case .editMusic:
            do { try task.resultSchema.validateDefinition() } catch { return .incompatibleResultSchema }
        case .singleChoice:
            guard case .list(let element, let items) = task.materials,
                  Set(items.map(\.id)).count == items.count else { return .incompatibleMaterials }
            do { try task.materials.validate() } catch { return .incompatibleMaterials }
            let expected: WorkflowDataSchema = .record([
                WorkflowRecordField("id", .text),
                WorkflowRecordField("value", element),
            ])
            guard task.resultSchema == expected else { return .incompatibleResultSchema }
        case .multipleChoice:
            guard case .list(let element, let items) = task.materials,
                  Set(items.map(\.id)).count == items.count else { return .incompatibleMaterials }
            do { try task.materials.validate() } catch { return .incompatibleMaterials }
            guard task.resultSchema == .list(element) else { return .incompatibleResultSchema }
        }
        return nil
    }

    private static func selectionIDs(
        from draft: WorkflowDatum,
        kind: WorkflowHumanTaskKind,
        items: [WorkflowDataItem]
    ) -> Set<String> {
        switch (kind, draft) {
        case (.singleChoice, .record(_, let fields)):
            guard case .text(let id)? = fields["id"],
                  let item = items.first(where: { $0.id == id }),
                  fields["value"] == item.value else { return [] }
            return [id]
        case (.multipleChoice, .list(_, let selected)):
            let selectedIDs = Set(selected.map(\.id))
            guard selected.allSatisfy({ selected in
                items.contains(where: { $0.id == selected.id && $0.value == selected.value })
            }) else { return [] }
            return selectedIDs
        default:
            return []
        }
    }
}

@MainActor
struct WorkflowHumanTaskForm: View {
    let task: WorkflowHumanTask
    let onSaveDraft: (WorkflowDatum?) -> Void
    let onSubmit: (WorkflowDatum) -> Void
    let onReject: () -> Void
    @State private var state: WorkflowHumanTaskFormState
    @Environment(\.dLanguageStore) private var languageStore

    init(
        task: WorkflowHumanTask,
        onSaveDraft: @escaping (WorkflowDatum?) -> Void,
        onSubmit: @escaping (WorkflowDatum) -> Void,
        onReject: @escaping () -> Void
    ) {
        self.task = task
        self.onSaveDraft = onSaveDraft
        self.onSubmit = onSubmit
        self.onReject = onReject
        _state = State(initialValue: WorkflowHumanTaskFormState(task: task))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.title).font(.headline)
            if state.isReadyToRender(taskID: task.id) {
                if let error = state.error {
                    Label(errorText(error), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("workflow-human-task-error")
                }
                taskEditor.id(task.id)
                HStack {
                    Button(humanTaskText("workflow.language.form.submit", fallback: "Submit")) { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.canSubmit)
                        .accessibilityIdentifier("workflow-human-task-submit")
                    Button(humanTaskText("workflow.language.form.reject", fallback: "Reject"), role: .destructive) {
                        guard state.displayedTaskID == task.id else { return }
                        onReject()
                    }
                    .accessibilityIdentifier("workflow-human-task-reject")
                }
            }
        }
        .onChange(of: task.id) { _, _ in
            state = WorkflowHumanTaskFormState(task: task)
        }
    }

    @ViewBuilder private var taskEditor: some View {
        switch task.kind {
        case .editText:
            TextEditor(text: Binding(
                get: { state.draft?.text ?? "" },
                set: { text in save(state.updateDraft(.text(text), taskID: task.id), taskID: task.id) }
            ))
            .frame(minHeight: 110)
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
            .accessibilityIdentifier("workflow-human-task-edit-text")
        case .singleChoice:
            choiceList(multiple: false)
        case .multipleChoice:
            choiceList(multiple: true)
        case .approve:
            HStack {
                Button(humanTaskText("workflow.language.form.approve", fallback: "Approve")) {
                    save(state.chooseApproval(true, taskID: task.id), taskID: task.id)
                }
                .accessibilityIdentifier("workflow-human-task-approve")
                Button(humanTaskText("workflow.language.form.decline", fallback: "Do not approve")) {
                    save(state.chooseApproval(false, taskID: task.id), taskID: task.id)
                }
                .accessibilityIdentifier("workflow-human-task-decline")
            }
        case .editMusic:
            WorkflowDatumValueEditor(value: Binding(
                get: { state.draft },
                set: { save(state.updateDraft($0, taskID: task.id), taskID: task.id) }
            ), schema: task.resultSchema, depth: 0)
            .accessibilityIdentifier("workflow-human-task-edit-music")
        }
    }

    private func choiceList(multiple: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.choiceItems) { item in
                Button {
                    if multiple {
                        save(state.toggleMultiple(item.id, taskID: task.id), taskID: task.id)
                    } else {
                        save(state.selectSingle(item.id, taskID: task.id), taskID: task.id)
                    }
                } label: {
                    HStack {
                        Image(systemName: state.selectedItemIDs.contains(item.id)
                              ? (multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                              : (multiple ? "square" : "circle"))
                        Text(item.id).font(.body.monospaced())
                        Spacer()
                        Text(humanTaskSchemaName(item.value.schema))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workflow-human-task-choice-\(item.id)")
            }
        }
    }

    private func save(_ draft: WorkflowDatum?, taskID: UUID) {
        guard state.displayedTaskID == taskID, task.id == taskID, let draft else { return }
        onSaveDraft(draft)
    }

    private func submit() {
        guard state.displayedTaskID == task.id,
              let candidate = state.validatedCandidate(taskID: task.id) else { return }
        onSubmit(candidate)
    }

    private func errorText(_ error: WorkflowHumanTaskFormError) -> String {
        switch error {
        case .incompatibleMaterials:
            humanTaskText("workflow.language.form.error.choiceMaterials", fallback: "Choice tasks require a valid list with stable, unique item IDs.")
        case .incompatibleResultSchema:
            humanTaskText("workflow.language.form.error.resultSchema", fallback: "This task's result schema is incompatible with its form.")
        case .invalidDraft:
            humanTaskText("workflow.language.form.error.invalidDraft", fallback: "The draft is invalid. It has been preserved and cannot be submitted yet.")
        }
    }

    private func humanTaskText(
        _ key: String,
        fallback: String,
        arguments: [String: String] = [:]
    ) -> String {
        languageStore?.text(key, fallback: fallback, arguments: arguments)
            ?? LanguagePackCodec.render(fallback, arguments: arguments)
    }

    private func humanTaskSchemaName(_ schema: WorkflowDataSchema) -> String {
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
        return humanTaskText(key, fallback: fallback, arguments: arguments)
    }
}
