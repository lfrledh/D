import AppKit
import SwiftUI

/// Keeps unfinished input-method text out of SwiftUI's authoritative-value
/// writeback. The containing TextSourcesView has the target document's identity.
struct TextSourcesQuestionEditor: NSViewRepresentable {
    let value: String
    let editEpoch: UInt64
    let isEditable: Bool
    var accessibilityIdentifier: String = "text-sources-question"
    let onEdit: (String) -> Void
    var pointSize: CGFloat? = nil
    var sendsOnReturn = false
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = NSTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isSelectable = true
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                    height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityIdentifier(accessibilityIdentifier)
        editor.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        context.coordinator.update(editor, value: value, isEditable: isEditable, onEdit: onEdit,
            pointSize: pointSize, sendsOnReturn: sendsOnReturn, onSubmit: onSubmit)
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 320,
               height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 90)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.update(editor, value: value, isEditable: isEditable, onEdit: onEdit,
            pointSize: pointSize, sendsOnReturn: sendsOnReturn, onSubmit: onSubmit)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // A removed document must not receive a late input-method callback.
        (scroll.documentView as? NSTextView)?.delegate = nil
        coordinator.typingUndo.removeAllActions()
        coordinator.onSubmit = nil
        coordinator.onEdit = nil
        coordinator.editor = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var onEdit: ((String) -> Void)?
        fileprivate let typingUndo = UndoManager()
        fileprivate weak var editor: NSTextView?
        private var replacing = false
        private var sendsOnReturn = false
        private var pendingPreferences: (pointSize: CGFloat?, sendsOnReturn: Bool)?

        private func applyPendingPreferences(_ editor: NSTextView) {
            guard self.editor === editor, !editor.hasMarkedText(), let value = pendingPreferences else { return }
            pendingPreferences = nil
            sendsOnReturn = value.sendsOnReturn
            if let size = value.pointSize, editor.font?.pointSize != size { editor.font = .systemFont(ofSize: size) }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { applyPendingPreferences(editor) }
        }
        func submitIfAllowed(_ editor: NSTextView, modifiers: NSEvent.ModifierFlags) -> Bool {
            applyPendingPreferences(editor)
            guard self.editor === editor, editor.isEditable, let onSubmit,
                  Self.shouldSubmit(markedText: editor.hasMarkedText(), sendsOnReturn: sendsOnReturn,
                                    modifiers: modifiers) else { return false }
            onSubmit(); return true
        }
        fileprivate var onSubmit: (() -> Void)?

        static func shouldSubmit(markedText: Bool, sendsOnReturn: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
            guard !markedText else { return false }
            let keys = modifiers.intersection([.shift, .control, .option, .command])
            return sendsOnReturn ? keys.isEmpty : keys == .command
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let event = NSApp.currentEvent, event.type == .keyDown else { return false }
            return submitIfAllowed(textView, modifiers: event.modifierFlags)
        }

        override init() {
            super.init()
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(typingUndoDidFinish(_:)),
                                                       name: name, object: typingUndo)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func typingUndoDidFinish(_ notification: Notification) {
            // A manager undo can change NSTextStorage without textDidChange.
            // Publish the completed native value through the same validation path.
            guard let editor else { return }
            textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        }

        func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

        func update(_ editor: NSTextView, value: String, isEditable: Bool,
                    onEdit: @escaping (String) -> Void, pointSize: CGFloat? = nil,
                    sendsOnReturn: Bool = false, onSubmit: (() -> Void)? = nil) {
            // Do not replace marked text, selection, or its callback owner during
            // composition, including layout-only redraws and rejected edits.
            guard !editor.hasMarkedText() else {
                if self.editor === editor { pendingPreferences = (pointSize, sendsOnReturn) }
                return
            }
            pendingPreferences = nil
            self.editor = editor
            self.onEdit = onEdit
            self.onSubmit = onSubmit
            self.sendsOnReturn = sendsOnReturn
            if let pointSize, editor.font?.pointSize != pointSize {
                editor.font = .systemFont(ofSize: pointSize)
            }
            editor.isEditable = isEditable
            guard !editor.string.utf8.elementsEqual(value.utf8) else { return }
            let requested = min(editor.selectedRange().location, value.utf16.count)
            let cursor = ([value.startIndex] + value.indices + [value.endIndex])
                .map { $0.utf16Offset(in: value) }.last { $0 <= requested } ?? 0
            replacing = true
            editor.string = value
            editor.setSelectedRange(NSRange(location: cursor, length: 0))
            // AppKit typing undo ranges refer to the superseded native string.
            // A rejected edit / authoritative replacement invalidates them. Only
            // this editor's manager is cleared; never the window's undo history.
            typingUndo.removeAllActions()
            replacing = false
        }

        func textDidChange(_ notification: Notification) {
            guard !replacing, let editor = notification.object as? NSTextView,
                  !editor.hasMarkedText() else { return }
            applyPendingPreferences(editor)
            onEdit?(editor.string)
        }
    }

}
