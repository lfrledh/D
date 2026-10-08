import AppKit
import SwiftUI

/// Keeps unfinished input-method text out of SwiftUI's authoritative-value
/// writeback. The containing TextSourcesView has the target document's identity.
struct TextSourcesQuestionEditor: NSViewRepresentable {
    let value: String
    let editEpoch: UInt64
    let isEditable: Bool
    var accessibilityIdentifier: String = "text-sources-question"
    var accessibilityLabel: String? = nil
    let onEdit: (String) -> Void
    var pointSize: CGFloat? = nil
    var sendsOnReturn = false
    var onSubmit: (() -> Void)? = nil
    var onFileDrop: (([URL]) -> Void)? = nil
    // Opt-in for the chat composer. Other native editors keep their existing sizing.
    var contentHeight: ClosedRange<CGFloat>? = nil
    var transparentBackground = false
    var foregroundColor: NSColor? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // Only attachment composers opt in. Other question/system editors keep
        // NSTextView's normal text/paste/drag behavior.
        let editor: NSTextView = onFileDrop == nil ? NSTextView() : FileDropTextView()
        (editor as? FileDropTextView)?.onFileDrop = onFileDrop
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
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        context.coordinator.update(editor, value: value, isEditable: isEditable, onEdit: onEdit,
            pointSize: pointSize, sendsOnReturn: sendsOnReturn, onSubmit: onSubmit)
        applyAppearance(scroll, editor: editor)
        return scroll
    }

    private func applyAppearance(_ scroll: NSScrollView, editor: NSTextView) {
        scroll.drawsBackground = !transparentBackground
        editor.drawsBackground = !transparentBackground
        let color = foregroundColor ?? .labelColor
        if editor.textColor != color { editor.textColor = color }
        if editor.insertionPointColor != color { editor.insertionPointColor = color }
    }

    static func fittedHeight(text: String, font: NSFont, width: CGFloat,
                             range: ClosedRange<CGFloat>) -> CGFloat {
        // Match the native 6-point insets and default 5-point line-fragment padding.
        // This is a measurement only: no authoritative text, selection or Undo mutation.
        let bounds = ((text.isEmpty ? " " : text + "\n") as NSString).boundingRect(
            with: NSSize(width: max(1, width - 22), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(range.upperBound, max(range.lowerBound, ceil(bounds.height) + 12))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 320
        if let contentHeight, let editor = nsView.documentView as? NSTextView {
            return CGSize(width: width, height: Self.fittedHeight(text: editor.string,
                font: editor.font ?? .preferredFont(forTextStyle: .body), width: width, range: contentHeight))
        }
        return CGSize(width: width,
               height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 90)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        applyAppearance(scroll, editor: editor)
        (editor as? FileDropTextView)?.onFileDrop = onFileDrop
        if editor.accessibilityLabel() != accessibilityLabel { editor.setAccessibilityLabel(accessibilityLabel) }
        context.coordinator.update(editor, value: value, isEditable: isEditable, onEdit: onEdit,
            pointSize: pointSize, sendsOnReturn: sendsOnReturn, onSubmit: onSubmit)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // A removed document must not receive a late input-method callback.
        (scroll.documentView as? NSTextView)?.delegate = nil
        (scroll.documentView as? FileDropTextView)?.onFileDrop = nil
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

/// NSTextView consumes Finder drops before a surrounding SwiftUI dropDestination
/// can see them. Intercept only file URLs at the native destination; do not turn
/// ordinary pasted path strings into file access or change text dragging.
@MainActor final class FileDropTextView: NSTextView {
    var onFileDrop: (([URL]) -> Void)? {
        didSet { updateDragTypeRegistration() }
    }

    override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        // NSTextView unregisters drag types for plain-text editors. Our file
        // attachment callback is independent of rich-text insertion. Restore
        // only file URLs after AppKit refreshes registration (e.g. editability).
        // The native refresh can leave this subclass's extra registration in
        // place; explicitly clear it before recomputing plain-text acceptance.
        if !isRichText { unregisterDraggedTypes() }
        if isEditable, onFileDrop != nil { registerForDraggedTypes([.fileURL]) }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let types = super.acceptableDragTypes
        return types.contains(.fileURL) ? types : types + [.fileURL]
    }

    private func files(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func canReceive(_ sender: NSDraggingInfo) -> Bool {
        !isHiddenOrHasHiddenAncestor && isEditable && !hasMarkedText() && onFileDrop != nil && delegate != nil &&
            sender.draggingSourceOperationMask.contains(.copy)
    }

    // Attachments belong to the composer, not to a text insertion position.
    // Decide file-only acceptance directly at the destination entry points,
    // independently of caret/selection. Preserve native text drag handling.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !files(sender.draggingPasteboard).isEmpty else { return super.draggingEntered(sender) }
        return canReceive(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !files(sender.draggingPasteboard).isEmpty else { return super.draggingUpdated(sender) }
        return canReceive(sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !files(sender.draggingPasteboard).isEmpty else { return super.prepareForDragOperation(sender) }
        return canReceive(sender)
    }

    override func dragOperation(for draggingInfo: NSDraggingInfo,
                                type: NSPasteboard.PasteboardType) -> NSDragOperation {
        guard !files(draggingInfo.draggingPasteboard).isEmpty else {
            return super.dragOperation(for: draggingInfo, type: type)
        }
        return canReceive(draggingInfo) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        // Bypass native insertion only for file drops, before it can replace
        // the selection or confirm marked text. Import errors remain visible
        // through the composer's existing import path.
        guard canReceive(sender), let onFileDrop else { return false }
        onFileDrop(urls)
        return true
    }
}
