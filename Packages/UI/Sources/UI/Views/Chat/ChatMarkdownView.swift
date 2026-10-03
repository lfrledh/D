import AppKit
import SwiftStreamingMarkdown
import SwiftUI

enum ChatMarkdownPresentation {
    static let config = MarkdownRenderConfig(imageConfig: .disabled)

    static func discardURL(_ url: URL) -> OpenURLAction.Result { .discarded }

    /// Exact source shown before parse, during streaming, and on explicit raw.
    static func literalText(rendered: String, raw: String, streaming: Bool,
                            showingRaw: Bool, parsed: String?, hasDocument: Bool) -> String? {
        if showingRaw { return raw }
        if streaming || parsed != rendered || !hasDocument { return rendered }
        return nil
    }
}

@MainActor
private final class ChatMarkdownCache {
    static let shared = ChatMarkdownCache()
    private struct Entry { let source: String; let document: RenderableDocument }
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private let capacity = 32

    func document(for id: UUID, source: String) -> RenderableDocument? {
        guard let entry = entries[id], entry.source == source else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return entry.document
    }
    func insert(_ document: RenderableDocument, for id: UUID, source: String) {
        entries[id] = Entry(source: source, document: document)
        order.removeAll { $0 == id }; order.append(id)
        if order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
    }
}

/// One parser and one renderer for a completed message. Streaming text stays
/// literal; a failed or delayed parse leaves the exact original visible.
@MainActor
struct ChatMarkdownView: View {
    let messageID: UUID
    let text: String
    let rawText: String
    let isStreaming: Bool
    @State private var parsedText: String?
    @State private var document: RenderableDocument?
    @State private var showsRaw = false
    @Environment(\.dLanguageStore) private var language

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !isStreaming {
                    Button(showsRaw ? label("rendered", "渲染") : label("raw", "原文")) { showsRaw.toggle() }
                        .accessibilityIdentifier("chat-raw-toggle-\(messageID.uuidString)")
                }
                Button(label("copyRaw", "复制原文")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rawText, forType: .string)
                }
                Spacer()
            }.font(.caption)
            if let literal = ChatMarkdownPresentation.literalText(rendered: text, raw: rawText,
                streaming: isStreaming, showingRaw: showsRaw, parsed: parsedText, hasDocument: document != nil) {
                Text(literal).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat-raw-\(messageID.uuidString)")
            } else if let document {
                DocumentView(renderableDocument: document, config: ChatMarkdownPresentation.config)
                    .environment(\.openURL, OpenURLAction { url in ChatMarkdownPresentation.discardURL(url) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: isStreaming ? nil : text) {
            guard !isStreaming, !text.isEmpty else { return }
            let source = text
            if let cached = ChatMarkdownCache.shared.document(for: messageID, source: source) {
                parsedText = source; document = cached; return
            }
            let rendered = await MarkdownParserImpl().parse(text: source, config: ChatMarkdownPresentation.config)
            guard !Task.isCancelled else { return }
            ChatMarkdownCache.shared.insert(rendered, for: messageID, source: source)
            parsedText = source
            document = rendered
        }
    }
}
