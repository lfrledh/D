import SwiftUI
import DWorkbench
import DInference

/// Explicit CPU preview, never runs or installs a language model.
struct ChatTemplatePanel: View {
    let chat: ChatController
    let sessionID: UUID
    @State private var result: TextTemplatePreview?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @Environment(\.dLanguageStore) private var language
    private func text(_ en: String, _ zh: String) -> String { language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("Template and token preview", "模板与分词预览")).font(.headline)
            Text(text("Reads the installed tokenizer only. Media placeholders precede vision processing; this is not the final visual token count. Edited templates support a bounded Jinja subset and reject missing input.",
                      "只读取已安装分词器。视觉处理前仍为媒体占位，不是最终视觉token计数。编辑模板支持有界Jinja子集；丢失输入会明确拒绝。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(text("Preview current request", "预览当前请求")) {
                    error = nil; result = nil
                    task = Task { @MainActor in
                        defer { task = nil }
                        do { result = try await chat.previewTemplate(sessionID: sessionID) }
                        catch is CancellationError {} catch { self.error = error.localizedDescription }
                    }
                }.disabled(task != nil).accessibilityIdentifier("chat-preview-template")
                if task != nil { Button(text("Cancel preview", "取消预览")) { task?.cancel() } }
                Button(text("Use model template", "恢复模型模板")) {
                    do {
                        guard var node = chat.state.sessions.first(where: { $0.id == sessionID })?.configuration else { return }
                        node.parameters["chatTemplateOverride"] = .text("")
                        try chat.updateConfiguration(node, sessionID: sessionID); result = nil
                    } catch { self.error = error.localizedDescription }
                }.disabled(task != nil)
            }
            if let error { Text(ChatErrorText.display(error, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            if let result {
                DisclosureGroup(text("Installed source", "模型原模板")) {
                    ScrollView { Text(result.sourceTemplate).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                }
                DisclosureGroup(text("Rendered request", "展开后的请求")) {
                    ScrollView { Text(result.renderedTemplate).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                }
                Text(text("Template tokens: ", "模板token数：") + String(result.templateTokenIDs.count))
                Text(result.diagnostics.joined(separator: "\n")).font(.caption).textSelection(.enabled)
            }
        }.onChange(of: chat.state.sessions.first(where: { $0.id == sessionID })) { _, _ in
            task?.cancel(); result = nil; error = nil
        }.onDisappear { task?.cancel() }
    }
}
