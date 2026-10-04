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
    private func wording(_ en: String, _ zh: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en
    }
    private func name(_ kind: ChatOutputFormat.Kind) -> String {
        switch kind {
        case .automatic: wording("Automatic", "自动")
        case .plainText: wording("Plain text", "纯文本")
        case .markdown: "Markdown"
        case .json: "JSON"
        case .schema: wording("D structured schema", "D 结构定义")
        }
    }
    var body: some View {
        DisclosureGroup(wording("Response format", "回答格式")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(wording("Format", "格式"), selection: $kind) {
                    ForEach([ChatOutputFormat.Kind.automatic, .plainText, .markdown, .json, .schema], id: \.self) { value in
                        Text(name(value)).tag(value)
                    }
                }.accessibilityIdentifier("chat-output-format-kind")
                if kind == .schema {
                    Text(wording("D WorkflowDataSchema Codable JSON, not general JSON Schema. Example: a record with a title.", "填写 D WorkflowDataSchema 的 JSON，并非通用 JSON Schema。示例是带标题的记录。"))
                        .font(.caption).foregroundStyle(.secondary)
                    TextSourcesQuestionEditor(value: schemaText, editEpoch: 0, isEditable: true,
                        accessibilityIdentifier: "chat-output-schema-" + sessionID.uuidString, onEdit: { schemaText = $0 })
                        .frame(height: 120)
                    Button(wording("Insert record example", "填入记录示例")) {
                        let schema = WorkflowDataSchema.record([.init("title", .text), .init("tags", .list(.text), required: false)])
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        schemaText = (try? encoder.encode(schema)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    }
                }
                Text(wording("Explicit format instructions are added to future requests. JSON is checked after generation; this does not force valid output. Invalid output stays available.", "显式格式要求加入之后的请求；JSON 在生成后检查，不保证模型一定遵守。未通过的原文仍保留。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(wording("Apply to future answers", "应用到之后的回答")) {
                    do {
                        let schema: WorkflowDataSchema?
                        if kind == .schema {
                            guard schemaText.utf8.count <= 65_536 else { throw WorkflowIssue("Schema declaration exceeds 64 KiB.") }
                            try WorkflowStructuredText.validateJSONSyntax(schemaText)
                            schema = try JSONDecoder().decode(WorkflowDataSchema.self, from: Data(schemaText.utf8))
                        } else { schema = nil }
                        try chat.setOutputFormat(.init(kind: kind, schema: schema), sessionID: sessionID); issue = nil
                    } catch { issue = error.localizedDescription }
                }.accessibilityIdentifier("chat-output-format-apply")
                if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(.top, 6)
        }.onAppear {
            guard !loaded else { return }; loaded = true
            let format = chat.state.sessions.first { $0.id == sessionID }?.outputFormat ?? .init()
            kind = format.kind
            if let schema = format.schema {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                schemaText = (try? encoder.encode(schema)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
        }
    }
}
