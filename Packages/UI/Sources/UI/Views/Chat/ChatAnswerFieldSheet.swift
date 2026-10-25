import DWorkbench
import SwiftUI

struct ChatAnswerFieldSheet: View {
    @Environment(\.dLanguageStore) private var language
    let choices: [ChatAnswerField]
    @Environment(\.dLanguageStore) private var copyLanguage
    let wording: (String, String) -> String
    let onSave: (ChatAnswerField, UUID, Bool) async throws -> Void
    let onClose: () -> Void
    @State private var selected = 0
    @State private var publication = UUID()
    @State private var task: Task<Void, Never>?
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(workflowText(copyLanguage, "chat.answerFieldSheet.structuredAnswerFields")).font(.headline)
                Spacer()
                WorkbenchRequestCloseButton(title: workflowText(copyLanguage, "workflow.action.close"), fallback: onClose)
            }
            Text(workflowText(copyLanguage, "chat.answerFieldSheet.savesTheSelectedAnswerVersionAndTypedFieldWorkflowReceives"))
                .font(.caption).foregroundStyle(.secondary)
            WorkbenchPicker(workflowText(copyLanguage, "workflow.operation.d.value.field.title"), selection: $selected) {
                WorkbenchChoiceForEach(choices.indices, id: \.self) { index in
                    WorkbenchChoice(choices[index].path.isEmpty ? workflowText(copyLanguage, "chat.answerFieldSheet.entireStructure") : pathLabel(choices[index].path), value:index)
                }
            }.onChange(of: selected) { _, _ in publication = UUID(); issue = nil }
            if choices.indices.contains(selected) {
                ScrollView {
                    Text(preview(choices[selected].value)).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 160)
            }
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(workflowText(copyLanguage, "chat.answerFieldSheet.saveField")) { save(false) }
                Button(workflowText(copyLanguage, "chat.answerFieldSheet.saveAndSendToWorkflow")) { save(true) }
                if task != nil { ProgressView().controlSize(.small) }
            }.disabled(task != nil || !choices.indices.contains(selected))
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .workbenchCloseProtection(isDirty: issue != nil, isSaving: task != nil)
            .onDisappear { task?.cancel() }
    }
    private func pathLabel(_ path: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(path), as: UTF8.self)) ?? ""
    }
    private func preview(_ value: WorkflowDatum) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
    }
    private func save(_ workflow: Bool) {
        guard task == nil, choices.indices.contains(selected) else { return }
        let field = choices[selected], id = publication
        task = Task { @MainActor in
            defer { task = nil }
            do { try await onSave(field, id, workflow); try Task.checkCancellation(); onClose() }
            catch is CancellationError {} catch { issue = error.localizedDescription }
        }
    }
}
