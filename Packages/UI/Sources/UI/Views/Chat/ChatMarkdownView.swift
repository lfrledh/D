import AppKit
import SwiftStreamingMarkdown
import SwiftUI

/// The renderer supplies normalized table Markdown, not a raw-source slice.
struct ChatMarkdownListener: MarkdownListener {
    func onTableCopyTap(content: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
        }
    }
    func onRender(markdown: RenderableDocument) async {}
    func onTableDownloadTap(content: String) async {}
    func onContextMenuAppear(id: String, selectedContent: String) async {}
    func onContextMenuTap(id: String, selectedContent: String) async {}
    func onImageTap(image: MarkdownImage) async {}
}

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
    static func config(for preferences: ChatDisplayPreferences, colorScheme: ColorScheme = .light) -> MarkdownRenderConfig {
        let palette = preferences.resolvedAppearance.palette(for: preferences.preferredColorScheme ?? colorScheme)
        let size = CGFloat(preferences.textPointSize)
        let base = fonts(size)
        let code = fonts(size, monospaced: true)
        let table = MarkdownRenderConfig.defaultTableStyle
        let inline = MarkdownRenderConfig.defaultInlineStyle
        let codeBlock = CodeBlockConfig.default
        var block = CodeBlockConfig(theme: codeBlock.theme, backgroundColor: codeBlock.backgroundColor,
            foregroundColor: codeBlock.foregroundColor, codeTextFonts: code, chromeTextFonts: fonts(max(12, size - 2)))
        block.wrapsLines = preferences.wrapsCode
        return MarkdownRenderConfig(
            blockQuoteStyle: .init(textFonts: base, textColor: palette.foregroundColor),
            headingStyle: .init(h1Font: fonts(size * 28 / 17), h2Font: fonts(size * 24 / 17),
                                h3Font: fonts(size * 20 / 17), h4Font: fonts(size * 20 / 17),
                                h5Font: fonts(size * 20 / 17), h6Font: fonts(size * 20 / 17),
                                textColor: palette.foregroundColor),
            orderedListStyle: .init(textFonts: base, textColor: palette.foregroundColor),
            paragraphStyle: .init(textFonts: base, textColor: palette.foregroundColor),
            tableStyle: .init(textFonts: base, headerTextColor: palette.foregroundColor,
                              regularTextColor: palette.foregroundColor,
                              headerBackgroundColor: palette.panelColor,
                              borderColor: table.borderColor, actionButtonColor: palette.accentColor),
            inlineStyle: .init(boldTextColor: palette.foregroundColor, linkTextFont: base.normal,
                               linkTextColor: palette.accentColor,
                               linkUnderlineStyle: inline.linkUnderlineStyle,
                               codeTextFont: code.normal, codeTextColor: inline.codeTextColor,
                               codeBackgroundColor: inline.codeBackgroundColor,
                               codeUnderlineColor: inline.codeUnderlineColor),
            codeBlockConfig: block,
            imageConfig: .disabled)
    }

    /// Model links are untrusted. Clicking only proposes a visible destination;
    /// opening it remains a separate, explicit browser action.
    static func requestURL(_ url: URL, confirm: (URL) -> Void) -> OpenURLAction.Result {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
        else { return .discarded }
        confirm(url)
        return .handled
    }

    @MainActor
    static func parse(_ source: String, pointSize: Int = ChatDisplayPreferences.defaultTextPointSize,
                      palette: WorkbenchPalette? = nil) async -> RenderableDocument {
        var preferences = ChatDisplayPreferences()
        preferences.textPointSize = pointSize
        if let palette {
            var appearance = WorkbenchAppearance(); appearance.light = palette; appearance.dark = palette
            preferences.appearance = appearance
        }
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
    private struct Entry { let source: String; let pointSize: Int; let foreground: String; let accent: String; let document: RenderableDocument }
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private let capacity = 32

    func document(for id: UUID, source: String, pointSize: Int, foreground: String, accent: String) -> RenderableDocument? {
        guard let entry = entries[id], entry.source == source, entry.pointSize == pointSize, entry.foreground == foreground, entry.accent == accent else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return entry.document
    }
    func insert(_ document: RenderableDocument, for id: UUID, source: String, pointSize: Int, foreground: String, accent: String) {
        entries[id] = Entry(source: source, pointSize: pointSize, foreground: foreground, accent: accent, document: document)
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
        let foreground: String
        let accent: String
    }
    let messageID: UUID
    let text: String
    let rawText: String
    let isStreaming: Bool
    @State private var parsedText: String?
    @State private var parsedKey: ParseKey?
    @State private var document: RenderableDocument?
    @State private var showsRaw = false
    @State private var pendingLink: URL?
    @Environment(\.dLanguageStore) private var language
    @Environment(\.chatDisplayPreferences) private var displayPreferences
    @Environment(\.colorScheme) private var colorScheme

    private var renderPalette: WorkbenchPalette {
        displayPreferences.resolvedAppearance.palette(for: displayPreferences.preferredColorScheme ?? colorScheme)
    }
    private var parseKey: ParseKey {
        ParseKey(source: text, pointSize: displayPreferences.textPointSize,
                 foreground: renderPalette.foreground, accent: renderPalette.accent)
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
                parsed: parsedKey?.source == text && parsedKey?.pointSize == displayPreferences.textPointSize ? parsedText : nil, document: document) {
                Text(literal).font(.system(size: CGFloat(displayPreferences.textPointSize)))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat-raw-\(messageID.uuidString)")
            } else if let document {
                DocumentView(renderableDocument: document,
                             config: ChatMarkdownPresentation.config(for: displayPreferences, colorScheme: colorScheme),
                             listener: ChatMarkdownListener())
                    .environment(\.openURL, OpenURLAction { url in
                        ChatMarkdownPresentation.requestURL(url) { pendingLink = $0 }
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert(label("externalLink", "在浏览器中打开链接？"), isPresented: Binding(
            get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }), presenting: pendingLink) { url in
            Button(label("openBrowser", "打开浏览器")) { NSWorkspace.shared.open(url); pendingLink = nil }
            Button(label("cancel", "取消"), role: .cancel) { pendingLink = nil }
        } message: { url in
            Text(label("externalLinkNotice", "这是回答中的外部地址。打开后将由浏览器访问该网站：") + "\n\n" + url.absoluteString)
        }
        .onChange(of: text) { _, _ in pendingLink = nil }
        .onDisappear { pendingLink = nil }
        .task(id: isStreaming ? nil : parseKey) {
            guard !isStreaming, !text.isEmpty else { return }
            let key = parseKey
            if let cached = ChatMarkdownCache.shared.document(for: messageID, source: key.source,
                                                               pointSize: key.pointSize, foreground: key.foreground, accent: key.accent) {
                parsedKey = key; parsedText = key.source; document = cached; return
            }
            let rendered = await ChatMarkdownPresentation.parse(key.source, pointSize: key.pointSize, palette: renderPalette)
            guard !Task.isCancelled else { return }
            ChatMarkdownCache.shared.insert(rendered, for: messageID, source: key.source,
                                            pointSize: key.pointSize, foreground: key.foreground, accent: key.accent)
            parsedKey = key
            parsedText = key.source
            document = rendered
        }
    }
}
