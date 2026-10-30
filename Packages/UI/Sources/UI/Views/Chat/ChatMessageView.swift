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

    init(_ attempt: ChatAttempt, checksFormat: Bool = true) {
        let runtimeActive = attempt.status == .running
        let unseparated = (runtimeActive && attempt.languageEnd == nil) || attempt.response == nil
        let selectedText = unseparated ? attempt.rawText : (attempt.response?.finalText ?? "")
        isStreaming = runtimeActive
        isUnseparatedRaw = unseparated
        rawText = runtimeActive ? attempt.rawText : (attempt.response?.rawText ?? attempt.rawText)
        text = selectedText
        if checksFormat, !unseparated, !selectedText.isEmpty, attempt.status != .saving,
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
    var showsNewButton = true
    @Environment(\.dLanguageStore) private var language

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }

    var body: some View {
        VStack {
            ContentUnavailableView(label("empty", "开始新对话"), systemImage: "bubble.left.and.bubble.right",
                description: Text(label("emptyHelp", "新建对话后选择模型。不会自动发送。")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsNewButton {
                Button(label("new", "新建"), systemImage: "plus", action: onNew).padding(20)
            }
        }
    }
}

/// The same message content is used by the transcript and offscreen presentation fixtures.
@MainActor
struct ChatMessageContent: View {
    let message: ChatMessage
    let attempt: ChatAttempt?
    var selectedAnswer: ChatSelectedAnswer? = nil
    let onPreview: (WorkflowAssetReference) -> Void

    @State private var reasoningExpanded = false
    @Environment(\.chatDisplayPreferences) private var displayPreferences

    @Environment(\.dLanguageStore) private var language

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }


    /// Copy, speech and editing use the same selected version as the transcript.
    static func answerText(message: ChatMessage, attempt: ChatAttempt?, selectedAnswer: ChatSelectedAnswer?) -> String {
        if let selectedAnswer { return selectedAnswer.text }
        if let response = attempt?.response { return response.finalText ?? "" }
        return attempt?.rawText ?? message.text
    }

    var recordedReasoning: String? {
        guard attempt?.status != .running, let value = attempt?.response?.reasoningText, !value.isEmpty else { return nil }
        return value
    }

    var primaryText: String { Self.answerText(message: message, attempt: attempt, selectedAnswer: selectedAnswer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedAnswer?.revisionID != nil {
                ChatMarkdownView(messageID: message.id, text: primaryText,
                                 rawText: primaryText, isStreaming: false)
            } else {
                sourceContent
            }
            if let reasoning = recordedReasoning {
                if attempt?.response?.finalText?.isEmpty != false {
                    Text(workflowText(language, "partial.reasoning")).font(.caption).foregroundStyle(.secondary)
                    Text(reasoning).font(.system(size: CGFloat(displayPreferences.textPointSize))).textSelection(.enabled)
                } else {
                DisclosureGroup(label("reasoning", "思考过程"), isExpanded: $reasoningExpanded) {
                    Text(reasoning).font(.system(size: CGFloat(displayPreferences.textPointSize))).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reasoning, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 16)).frame(width: 28, height: 28) }
                    .buttonStyle(ChatMessageIconStyle()).help(label("copyReasoning", "复制思考内容"))
                    .accessibilityLabel(label("copyReasoning", "复制思考内容"))
                }
            }
        }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat-message-content-\(message.id.uuidString)")
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attempt {
                let presentation = ChatChannelPresentation(attempt, checksFormat: false)
                if !presentation.text.isEmpty {
                    ChatMarkdownView(messageID: message.id, text: presentation.text,
                                     rawText: presentation.rawText, isStreaming: presentation.isUnseparatedRaw)
                        .id(message.id)
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
    }
}
