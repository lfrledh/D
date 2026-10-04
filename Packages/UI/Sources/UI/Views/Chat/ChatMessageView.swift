import AppKit
import DWorkbench
import SwiftUI

/// A projection of the stored attempt. Bytes without a stored parsed response
/// cannot be assigned to an answer or reasoning channel, even after interruption.
struct ChatChannelPresentation {
    let text: String
    let rawText: String
    /// Whether generation is still active; this is independent of parsing.
    let isStreaming: Bool
    let isUnseparatedRaw: Bool
    let formatReport: ChatOutputFormat.Report?
    let structuredResult: String?

    init(_ attempt: ChatAttempt) {
        let runtimeActive = attempt.status == .running
        let unseparated = runtimeActive || attempt.response == nil
        let selectedText = unseparated ? attempt.rawText : (attempt.response?.finalText ?? attempt.rawText)
        isStreaming = runtimeActive
        isUnseparatedRaw = unseparated
        rawText = runtimeActive ? attempt.rawText : (attempt.response?.rawText ?? attempt.rawText)
        text = selectedText
        if !unseparated, attempt.status != .saving,
           let format = attempt.outputFormat, [.json, .schema].contains(format.kind) {
            let checkedText = selectedText
            let report = format.check(checkedText)
            formatReport = report
            // JSON has no datum; schema output has one only after the strict parse.
            // The checked original is the read-only result, never executable content.
            structuredResult = report.status == .valid &&
                (format.kind == .json || report.datum != nil) ? checkedText : nil
        } else {
            formatReport = nil
            structuredResult = nil
        }
    }
}

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

    @Environment(\.chatDisplayPreferences) private var displayPreferences
    @State private var rawOutputExpanded = true

    @Environment(\.dLanguageStore) private var language

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }

    private func wording(_ english: String, _ chinese: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attempt {
                let presentation = ChatChannelPresentation(attempt)
                if presentation.isUnseparatedRaw {
                    DisclosureGroup(isExpanded: $rawOutputExpanded) {
                        if !presentation.text.isEmpty {
                            ChatMarkdownView(messageID: message.id, text: presentation.text,
                                             rawText: presentation.rawText, isStreaming: true)
                                .id(message.id)
                        }
                    } label: {
                        Text(presentation.isStreaming
                             ? wording("Raw streaming model output · answer and reasoning not separated yet",
                                       "原始流式模型输出 · 尚未分离正文/思考")
                             : wording("Unseparated model output · answer and reasoning unknown",
                                       "未分离的模型输出 · 正文/思考归属未知"))
                    }
                    .accessibilityIdentifier("chat-\(presentation.isStreaming ? "stream" : "unseparated")-raw-\(message.id.uuidString)")
                } else if !presentation.text.isEmpty {
                    ChatMarkdownView(messageID: message.id, text: presentation.text,
                                     rawText: presentation.rawText, isStreaming: false)
                        .id(message.id)
                }
                if !presentation.isUnseparatedRaw,
                   let reasoning = attempt.response?.reasoningText, !reasoning.isEmpty {
                    DisclosureGroup(label("reasoning", "思考内容")) {
                        Text(reasoning).font(.system(size: CGFloat(displayPreferences.textPointSize))).textSelection(.enabled)
                        Button(label("copyReasoning", "复制思考内容")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reasoning, forType: .string)
                        }
                    }
                }
                if let report = presentation.formatReport {
                    DisclosureGroup(label("formatCheck", "输出格式检查 · 不代表生成已完整结束")) {
                        Text(report.status == .valid ? label("validFormat", "原文符合请求的格式") : label("invalidFormat", "原文未通过格式检查"))
                        if let reason = report.reason { Text(reason).font(.caption).textSelection(.enabled) }
                        Text(label("formatAdvisory", "这是生成后检查，不是受约束解码；原回答保持不变。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let result = presentation.structuredResult {
                    DisclosureGroup(wording("Structured result · read only", "结构化结果 · 只读")) {
                        Text(result).font(.body.monospaced()).textSelection(.enabled)
                    }
                    .accessibilityIdentifier("chat-structured-result-\(message.id.uuidString)")
                }
                if !presentation.isUnseparatedRaw,
                   let calls = attempt.response?.toolCalls, !calls.isEmpty {
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
                Text(message.text).font(.system(size: CGFloat(displayPreferences.textPointSize))).textSelection(.enabled)
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
