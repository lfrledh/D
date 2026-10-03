import AppKit
import SwiftStreamingMarkdown
import SwiftUI

enum ChatMarkdownPresentation {
    @MainActor
    static let config = config(for: ChatDisplayPreferences())

    @MainActor
    private static func fonts(_ size: CGFloat, monospaced: Bool = false) -> TextFonts {
        let normal = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                                : NSFont.systemFont(ofSize: size)
        let bold = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
                              : NSFont.systemFont(ofSize: size, weight: .semibold)
        let italic = NSFontManager.shared.convert(normal, toHaveTrait: .italicFontMask)
        let boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        return TextFonts(normal: normal, italic: italic, bold: bold, boldItalic: boldItalic,
                         preferredLetterSpacing: nil, preferredLineHeight: nil)
    }

    @MainActor
    static func config(for preferences: ChatDisplayPreferences) -> MarkdownRenderConfig {
        let size = CGFloat(preferences.textPointSize)
        let base = fonts(size)
        let code = fonts(size, monospaced: true)
        let paragraph = MarkdownRenderConfig.defaultParagraphStyle
        let quote = MarkdownRenderConfig.defaultBlockQuoteStyle
        let list = MarkdownRenderConfig.defaultOrderedListStyle
        let table = MarkdownRenderConfig.defaultTableStyle
        let heading = MarkdownRenderConfig.defaultHeadingStyle
        let inline = MarkdownRenderConfig.defaultInlineStyle
        let codeBlock = CodeBlockConfig.default
        return MarkdownRenderConfig(
            blockQuoteStyle: .init(textFonts: base, textColor: quote.textColor),
            headingStyle: .init(h1Font: fonts(size * 28 / 17), h2Font: fonts(size * 24 / 17),
                                h3Font: fonts(size * 20 / 17), h4Font: fonts(size * 20 / 17),
                                h5Font: fonts(size * 20 / 17), h6Font: fonts(size * 20 / 17),
                                textColor: heading.textColor),
            orderedListStyle: .init(textFonts: base, textColor: list.textColor),
            paragraphStyle: .init(textFonts: base, textColor: paragraph.textColor),
            tableStyle: .init(textFonts: base, headerTextColor: table.headerTextColor,
                              regularTextColor: table.regularTextColor,
                              headerBackgroundColor: table.headerBackgroundColor,
                              borderColor: table.borderColor, actionButtonColor: table.actionButtonColor),
            inlineStyle: .init(boldTextColor: inline.boldTextColor, linkTextFont: base.normal,
                               linkTextColor: inline.linkTextColor,
                               linkUnderlineStyle: inline.linkUnderlineStyle,
                               codeTextFont: code.normal, codeTextColor: inline.codeTextColor,
                               codeBackgroundColor: inline.codeBackgroundColor,
                               codeUnderlineColor: inline.codeUnderlineColor),
            codeBlockConfig: .init(theme: codeBlock.theme, backgroundColor: codeBlock.backgroundColor,
                                   foregroundColor: codeBlock.foregroundColor,
                                   codeTextFonts: code, chromeTextFonts: fonts(max(12, size - 2))),
            imageConfig: .disabled)
    }

    static func discardURL(_ url: URL) -> OpenURLAction.Result { .discarded }

    @MainActor
    static func parse(_ source: String, pointSize: Int = ChatDisplayPreferences.defaultTextPointSize) async -> RenderableDocument {
        var preferences = ChatDisplayPreferences()
        preferences.textPointSize = pointSize
        return await MarkdownParserImpl().parse(text: source, config: config(for: preferences))
    }

    /// Exact source shown before parse, during streaming, and on explicit raw.
    static func literalText(rendered: String, raw: String, streaming: Bool,
                            showingRaw: Bool, parsed: String?, document: RenderableDocument?) -> String? {
        if showingRaw { return raw }
        if streaming || parsed != rendered || document == nil || document == .empty { return rendered }
        return nil
    }
}

@MainActor
private final class ChatMarkdownCache {
    static let shared = ChatMarkdownCache()
    private struct Entry { let source: String; let pointSize: Int; let document: RenderableDocument }
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private let capacity = 32

    func document(for id: UUID, source: String, pointSize: Int) -> RenderableDocument? {
        guard let entry = entries[id], entry.source == source, entry.pointSize == pointSize else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return entry.document
    }
    func insert(_ document: RenderableDocument, for id: UUID, source: String, pointSize: Int) {
        entries[id] = Entry(source: source, pointSize: pointSize, document: document)
        order.removeAll { $0 == id }; order.append(id)
        if order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
    }
}

/// One parser and one renderer for a completed message. Streaming text stays
/// literal; a failed or delayed parse leaves the exact original visible.
@MainActor
struct ChatMarkdownView: View {
    private struct ParseKey: Hashable {
        let source: String
        let pointSize: Int
    }
    let messageID: UUID
    let text: String
    let rawText: String
    let isStreaming: Bool
    @State private var parsedText: String?
    @State private var parsedKey: ParseKey?
    @State private var document: RenderableDocument?
    @State private var showsRaw = false
    @Environment(\.dLanguageStore) private var language
    @Environment(\.chatDisplayPreferences) private var displayPreferences

    private var parseKey: ParseKey {
        ParseKey(source: text, pointSize: displayPreferences.textPointSize)
    }

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
                streaming: isStreaming, showingRaw: showsRaw,
                parsed: parsedKey == parseKey ? parsedText : nil, document: document) {
                Text(literal).font(.system(size: CGFloat(displayPreferences.textPointSize)))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat-raw-\(messageID.uuidString)")
            } else if let document {
                DocumentView(renderableDocument: document,
                             config: ChatMarkdownPresentation.config(for: displayPreferences))
                    .environment(\.openURL, OpenURLAction { url in ChatMarkdownPresentation.discardURL(url) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: isStreaming ? nil : parseKey) {
            guard !isStreaming, !text.isEmpty else { return }
            let key = parseKey
            if let cached = ChatMarkdownCache.shared.document(for: messageID, source: key.source,
                                                               pointSize: key.pointSize) {
                parsedKey = key; parsedText = key.source; document = cached; return
            }
            let rendered = await ChatMarkdownPresentation.parse(key.source, pointSize: key.pointSize)
            guard !Task.isCancelled else { return }
            ChatMarkdownCache.shared.insert(rendered, for: messageID, source: key.source,
                                            pointSize: key.pointSize)
            parsedKey = key
            parsedText = key.source
            document = rendered
        }
    }
}
