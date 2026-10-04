import DWorkbench
import SwiftUI

/// All previews are inert. An archive entry and any mapping losses are chosen explicitly.
struct ChatConversationImportSheet: View {
    let data: Data
    let title: String
    let onCancel: () -> Void
    let onAccept: (Int?, String, Bool, UUID) async throws -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var choices: [ChatOpenWebUIImport.ConversationChoice] = []
    @State private var selectedIndex = -1
    @State private var preview: ChatInterchange.ImportPreview?
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
            Text(text("Open WebUI history (D mapping v1), or D role/content wrapper v1. Creates a new conversation without running a model or tool. Unfinished history trees are rejected; the source file is unchanged.",
                      "Open WebUI 历史（D 映射 v1），或 D role/content 封装 v1。创建新会话，不运行模型或工具。含未完成消息的历史树会被拒绝；原文件保持不变。"))
                .font(.caption).foregroundStyle(.secondary)
            if choices.count > 1 {
                Picker(text("Conversation", "选择会话"), selection: $selectedIndex) {
                    Text(text("Choose a conversation…", "请选择会话…")).tag(-1)
                    ForEach(choices, id: \.index) { item in Text(item.title).tag(item.index) }
                }.disabled(saving).accessibilityIdentifier("chat-import-conversation-choice")
            }
            if let preview {
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
                    Toggle(text("I accept these losses; keep the source unchanged", "接受上述信息损失；原文件保持不变"), isOn: $acceptLosses).disabled(saving)
                }
            } else { Spacer() }
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(text("Cancel", "取消"), action: onCancel).disabled(saving)
                Spacer()
                Button(text("Create imported conversation", "创建导入会话")) {
                    guard let preview else { return }
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do { try await onAccept(preview.conversationIndex, preview.sourceTitle ?? title, acceptLosses, importID) }
                        catch { issue = error.localizedDescription }
                    }
                }.disabled(saving || preview == nil || (preview?.losses.isEmpty == false && !acceptLosses))
            }
        }.padding(20).frame(minWidth: 580, idealWidth: 720, minHeight: 440, idealHeight: 600)
        .task {
            do {
                choices = (try? ChatOpenWebUIImport.conversations(in: data)) ?? []
                if choices.count == 1 { selectedIndex = choices[0].index }
                else if choices.isEmpty { preview = try ChatInterchange.previewImport(data) }
            } catch { issue = error.localizedDescription }
        }
        .onChange(of: selectedIndex) { _, index in
            // A different entry requires a new acceptance and retry identity.
            preview = nil; issue = nil; acceptLosses = false; importID = UUID()
            guard index >= 0 else { return }
            do { preview = try ChatInterchange.previewImport(data, selectedConversationIndex: index) }
            catch { issue = error.localizedDescription }
        }
    }
}
