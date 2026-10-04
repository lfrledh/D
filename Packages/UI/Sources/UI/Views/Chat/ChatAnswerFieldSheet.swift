import DWorkbench
import SwiftUI

struct ChatAnswerFieldSheet: View {
    @Environment(\.dLanguageStore) private var language
    let choices: [ChatAnswerField]
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
                Text(wording("Structured answer fields", "结构化回答字段")).font(.headline)
                Spacer()
                Button(wording("Close", "关闭")) { task?.cancel(); onClose() }
            }
            Text(wording("Saves the selected answer version and typed field. Workflow receives a record with value, source, and path; nothing runs automatically. Use Extract field → value for the value alone.", "保存所采用的回答版本和字段类型。工作流收到 value（值）、source（来源）及 path（路径）记录，不自动运行；需要纯值时用“提取字段 → value”。"))
                .font(.caption).foregroundStyle(.secondary)
            Picker(wording("Field", "字段"), selection: $selected) {
                ForEach(choices.indices, id: \.self) { index in
                    Text(choices[index].path.isEmpty ? wording("Entire structure", "整个结构") : pathLabel(choices[index].path)).tag(index)
                }
            }.onChange(of: selected) { _, _ in publication = UUID(); issue = nil }
            if choices.indices.contains(selected) {
                ScrollView {
                    Text(preview(choices[selected].value)).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 160)
            }
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(wording("Save field", "保存字段")) { save(false) }
                Button(wording("Save and send to workflow", "保存并交给工作流")) { save(true) }
                if task != nil { ProgressView().controlSize(.small) }
            }.disabled(task != nil || !choices.indices.contains(selected))
        }.padding(20).frame(minWidth: 560, idealWidth: 740, minHeight: 360)
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
