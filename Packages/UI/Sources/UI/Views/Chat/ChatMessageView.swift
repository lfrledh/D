import AppKit
import DWorkbench
import SwiftUI

@MainActor
struct ChatEmptyConversationView: View {
    let onNew: () -> Void
    @Environment(\.dLanguageStore) private var language

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }

    var body: some View {
        VStack {
            ContentUnavailableView(label("empty", "开始新对话"), systemImage: "bubble.left.and.bubble.right",
                description: Text(label("emptyHelp", "新建对话后选择模型。不会自动发送。")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(label("new", "新建"), systemImage: "plus", action: onNew)
                .padding(20)
        }
    }
}

/// The same message content is used by the transcript and offscreen presentation fixtures.
@MainActor
struct ChatMessageContent: View {
    let message: ChatMessage
    let attempt: ChatAttempt?
    let onPreview: (WorkflowAssetReference) -> Void

    @Environment(\.dLanguageStore) private var language

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attempt {
                let final = attempt.response?.finalText
                let raw = attempt.response?.rawText ?? attempt.rawText
                let shown = attempt.status == .running ? attempt.rawText : (final ?? raw)
                if !shown.isEmpty {
                    ChatMarkdownView(messageID: message.id, text: shown, rawText: raw,
                                     isStreaming: attempt.status == .running)
                        .id(message.id)
                }
                if let reasoning = attempt.response?.reasoningText, !reasoning.isEmpty {
                    DisclosureGroup(label("reasoning", "思考内容")) {
                        Text(reasoning).textSelection(.enabled)
                        Button(label("copyReasoning", "复制思考内容")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reasoning, forType: .string)
                        }
                    }
                }
                if let calls = attempt.response?.toolCalls, !calls.isEmpty {
                    DisclosureGroup(label("toolCalls", "工具调用声明 · 未执行")) {
                        ForEach(calls, id: \.id) { call in
                            VStack(alignment: .leading) {
                                Text(call.name).font(.subheadline.bold())
                                Text(String(data: (try? JSONEncoder().encode(call)) ?? Data(), encoding: .utf8) ?? "")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            } else {
                Text(message.text).textSelection(.enabled)
                ForEach(message.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.reference.kind == .image ? "photo" :
                            attachment.reference.kind == .video ? "film" : "doc.text")
                        Text(attachment.name).lineLimit(1)
                        Button(label("preview", "预览")) { onPreview(attachment.reference) }
                    }
                    .font(.caption).padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat-message-content-\(message.id.uuidString)")
    }
}
