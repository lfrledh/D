import AppKit
import DWorkbench
import SwiftUI

enum ChatQuoteSelectionAction: String, CaseIterable, Hashable, Sendable {
    case ask
    case explain
    case translate
    case rewrite
}

/// An optional raw-text source view; rich transcript rendering stays with ChatMessageView.
@MainActor
struct ChatQuoteSelectionView: View {
    let source: ChatQuoteSource
    let onUse: (ChatQuoteSelection, ChatQuoteSelectionAction) -> Void

    @Environment(\.dLanguageStore) private var language
    @State private var selection: ChatQuoteSelection?

    private var usableSelection: ChatQuoteSelection? {
        guard let selection, (try? selection.validate(against: source)) != nil else { return nil }
        return selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeTextView(source: source) { selected in
                // Source changes are reset by onChange. A delayed old selection
                // cannot enable or dispatch an action for the new source.
                selection = selected
            }
            .frame(minHeight: 120)

            HStack {
                ForEach(ChatQuoteSelectionAction.allCases, id: \.self) { action in
                    Button(title(for: action)) {
                        guard let selection = usableSelection else { return }
                        onUse(selection, action)
                    }
                    .disabled(usableSelection == nil)
                    .accessibilityIdentifier("chat-quote-\(action.rawValue)")
                }
            }
        }
        .onChange(of: source) { _, _ in selection = nil }
    }

    private func title(for action: ChatQuoteSelectionAction) -> String {
        let chinese = language?.effectiveLanguageIdentifier.hasPrefix("zh") == true
        return switch action {
        case .ask: workflowText(language, "chat.quote.ask", fallback: chinese ? "引用提问" : "Ask")
        case .explain: workflowText(language, "chat.quote.explain", fallback: chinese ? "解释" : "Explain")
        case .translate: workflowText(language, "chat.quote.translate", fallback: chinese ? "翻译" : "Translate")
        case .rewrite: workflowText(language, "chat.quote.rewrite", fallback: chinese ? "改写" : "Rewrite")
        }
    }

    struct NativeTextView: NSViewRepresentable {
        let source: ChatQuoteSource
        let onSelection: (ChatQuoteSelection?) -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let textView = NSTextView()
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFontPanel = false
            textView.font = .preferredFont(forTextStyle: .body)
            textView.textColor = .labelColor
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                            height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.delegate = context.coordinator

            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.documentView = textView
            context.coordinator.update(source: source, textView: textView, onSelection: onSelection)
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let textView = scroll.documentView as? NSTextView else { return }
            context.coordinator.update(source: source, textView: textView, onSelection: onSelection)
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            private var source: ChatQuoteSource?
            private weak var activeTextView: NSTextView?
            private var onSelection: ((ChatQuoteSelection?) -> Void)?
            private var suppress = false

            func update(source: ChatQuoteSource, textView: NSTextView,
                        onSelection: @escaping (ChatQuoteSelection?) -> Void) {
                self.onSelection = onSelection
                let changed = self.source != source || activeTextView !== textView
                guard changed else { return }
                suppress = true
                self.source = source
                activeTextView = textView
                textView.string = source.text
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                suppress = false
                onSelection(nil)
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard !suppress, let textView = notification.object as? NSTextView,
                      textView === activeTextView, let source,
                      textView.string == source.text else { return }
                onSelection?(try? ChatQuoteSelection(source: source, range: textView.selectedRange()))
            }
        }
    }
}
