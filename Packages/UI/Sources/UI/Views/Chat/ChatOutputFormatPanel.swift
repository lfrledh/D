import DWorkbench
import SwiftUI

/// A soft model instruction plus a post-generation validator; never a decoder switch.
struct ChatOutputFormatPanel: View {
    let chat: ChatController
    let sessionID: UUID
    @Environment(\.dLanguageStore) private var language
    @State private var kind: ChatOutputFormat.Kind = .automatic
    @State private var schemaText = ""
    @State private var issue: String?
    @State private var loaded = false
    private func name(_ kind: ChatOutputFormat.Kind) -> String {
        switch kind {
        case .automatic: workflowText(language, "consistency.remaining.7eb336e42cb5")
        case .plainText: workflowText(language, "chat.artifactEditor.plainText")
        case .markdown: "Markdown"
        case .json: "JSON"
        case .schema: workflowText(language, "chat.outputFormatPanel.dStructuredSchema")
        }
    }
    private var saved: ChatOutputFormat { chat.state.sessions.first { $0.id == sessionID }?.outputFormat ?? .init() }
    private func encodedSchema(_ format: ChatOutputFormat) -> String {
        guard let schema = format.schema else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(schema)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    private var hasChanges: Bool {
        guard kind == saved.kind else { return true }
        guard kind == .schema else { return false }
        guard (try? WorkflowStructuredText.validateJSONSyntax(schemaText)) != nil,
              let schema = try? JSONDecoder().decode(WorkflowDataSchema.self, from: Data(schemaText.utf8)) else { return true }
        return schema != saved.schema
    }
    private func load() { kind = saved.kind; schemaText = encodedSchema(saved); issue = nil }
    var body: some View {
        DisclosureGroup(workflowText(language, "chat.outputFormatPanel.responseFormat")) {
            VStack(alignment: .leading, spacing: 8) {
                WorkbenchPicker(workflowText(language, "workflow.operation.d.image.convert.field.format"), selection: $kind) {
                    WorkbenchChoiceForEach([ChatOutputFormat.Kind.automatic, .plainText, .markdown, .json, .schema], id: \.self) { value in
                        WorkbenchChoice(name(value), value:value)
                    }
                }.accessibilityIdentifier("chat-output-format-kind")
                if kind == .schema {
                    Text(workflowText(language, "chat.outputFormatPanel.dWorkflowDataSchemaCodableJSONNotGeneralJSONSchemaExampleA"))
                        .font(.caption).foregroundStyle(.secondary)
                    TextSourcesQuestionEditor(value: schemaText, editEpoch: 0, isEditable: true,
                        accessibilityIdentifier: "chat-output-schema-" + sessionID.uuidString, onEdit: { schemaText = $0 })
                        .frame(height: 120).workbenchInputSurface()
                    Button(workflowText(language, "chat.outputFormatPanel.insertRecordExample")) {
                        let schema = WorkflowDataSchema.record([.init("title", .text), .init("tags", .list(.text), required: false)])
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        schemaText = (try? encoder.encode(schema)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    }
                }
                Text(workflowText(language, "chat.outputFormatPanel.explicitFormatInstructionsAreAddedToFutureRequestsJSONIs"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(hasChanges ? workflowText(language, "chat.outputFormatPanel.changesAreNotApplied") : workflowText(language, "chat.outputFormatPanel.showingSavedFormat"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(workflowText(language, "chat.outputFormatPanel.discardFormatEdits")) { load() }.disabled(!hasChanges)
                Button(workflowText(language, "chat.outputFormatPanel.applyToFutureAnswers")) {
                    do {
                        let schema: WorkflowDataSchema?
                        if kind == .schema {
                            guard schemaText.utf8.count <= 65_536 else { throw WorkflowIssue("Schema declaration exceeds 64 KiB.") }
                            try WorkflowStructuredText.validateJSONSyntax(schemaText)
                            schema = try JSONDecoder().decode(WorkflowDataSchema.self, from: Data(schemaText.utf8))
                        } else { schema = nil }
                        try chat.setOutputFormat(.init(kind: kind, schema: schema), sessionID: sessionID); issue = nil
                    } catch { issue = error.localizedDescription }
                }.accessibilityIdentifier("chat-output-format-apply").disabled(!hasChanges)
                if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(.top, 6)
        }.onAppear {
            guard !loaded else { return }; loaded = true
            load()
        }
    }
}
