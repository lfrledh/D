import DWorkbench
import SwiftUI

/// Preview is inert. Only the explicit acceptance callback creates a new conversation.
struct ChatConversationImportSheet: View {
    let preview: ChatInterchange.ImportPreview
    let title: String
    let onCancel: () -> Void
    let onAccept: (Bool, UUID) async throws -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var acceptLosses = false
    @State private var importID = UUID()
    @State private var saving = false
    @State private var issue: String?

    private func text(_ en: String, _ zh: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("Import conversation", "导入会话")).font(.headline)
            Text(title)
            Text(text("OpenAI role/content messages · D import wrapper v1. This is not a ChatGPT account archive. Creates a new conversation; no model or tool runs.",
                      "OpenAI role/content 消息 · D 导入封装 v1。不是 ChatGPT 账号备份格式。创建新会话，不运行模型或工具。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !preview.systemPrompt.isEmpty { Text("System\n" + preview.systemPrompt).textSelection(.enabled) }
                    ForEach(preview.messages.indices, id: \.self) { index in
                        VStack(alignment: .leading) {
                            Text(preview.messages[index].role.rawValue).font(.caption.bold())
                            Text(preview.messages[index].text).textSelection(.enabled)
                        }
                    }
                    if !preview.losses.isEmpty {
                        Text(text("Fields that cannot be imported", "无法导入的字段")).font(.headline)
                        ForEach(preview.losses.indices, id: \.self) { index in
                            Text(preview.losses[index].location + ": " + preview.losses[index].reason).font(.caption)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !preview.losses.isEmpty {
                Toggle(text("I accept the listed losses; keep the source file unchanged", "接受上述信息损失；原文件保持不变"), isOn: $acceptLosses)
            }
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(text("Cancel", "取消"), action: onCancel).disabled(saving)
                Spacer()
                Button(text("Create imported conversation", "创建导入会话")) {
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do { try await onAccept(acceptLosses, importID) } catch { issue = error.localizedDescription }
                    }
                }.disabled(saving || (!preview.losses.isEmpty && !acceptLosses))
            }
        }.padding(20).frame(minWidth: 580, idealWidth: 720, minHeight: 440, idealHeight: 600)
    }
}
