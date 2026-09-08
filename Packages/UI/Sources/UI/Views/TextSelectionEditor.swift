import AppKit
import DWorkbench
import SwiftUI

/// The native editor deliberately compares UTF-8 bytes.  Swift `String` equality
/// normalizes canonically equivalent text, while a draft revision must retain the
/// exact bytes the user entered.
enum TextSelectionEditorState {
    static func needsTextReplacement(current: String, incoming: String) -> Bool {
        !current.utf8.elementsEqual(incoming.utf8)
    }

    static func validRange(_ range: NSRange, in document: TextDraftDocument) -> NSRange? {
        guard (try? TextRewriteSelection(document: document, range: range)) != nil else { return nil }
        return range
    }

    static func validCursorRange(_ range: NSRange, in document: TextDraftDocument) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length == 0,
              Range(range, in: document.text) != nil else { return nil }
        return range
    }

    static func validRange(_ range: NSRange, inNativeText text: String, document: TextDraftDocument) -> NSRange? {
        guard let nativeDocument = try? TextDraftDocument(id: document.id, revision: document.revision, text: text),
              (try? TextRewriteSelection(document: nativeDocument, range: range)) != nil else { return nil }
        return range
    }
}

/// An AppKit text view keeps IME composition and selection handling out of the
/// SwiftUI update cycle.  Edits and selections are merely reported to its owner.
public struct TextSelectionEditor: NSViewRepresentable {
    public let document: TextDraftDocument
    public let selection: NSRange
    public let onEdit: (String) -> Void
    public let onSelection: (NSRange) -> Void

    public init(document: TextDraftDocument, selection: NSRange,
                onEdit: @escaping (String) -> Void, onSelection: @escaping (NSRange) -> Void) {
        self.document = document
        self.selection = selection
        self.onEdit = onEdit
        self.onSelection = onSelection
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: .greatestFiniteMagnitude,
                                                        height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.documentView = textView
        context.coordinator.install(document: document, selection: selection,
                                    in: textView, edit: onEdit, select: onSelection)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.update(document: document, requestedSelection: selection,
                                   in: textView, edit: onEdit, select: onSelection)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        private var documentID: UUID?
        private var documentRevision: UUID?
        private var lastReportedSelection = NSRange(location: NSNotFound, length: 0)
        private var suppressCallbacks = false
        private var onEdit: ((String) -> Void)?
        private var onSelection: ((NSRange) -> Void)?
        private var currentDocument: TextDraftDocument?

        func install(document: TextDraftDocument, selection: NSRange, in textView: NSTextView,
                     edit: @escaping (String) -> Void, select: @escaping (NSRange) -> Void) {
            onEdit = edit
            onSelection = select
            replace(document: document, selection: selection, in: textView, clearSelection: true)
        }

        func update(document: TextDraftDocument, requestedSelection: NSRange, in textView: NSTextView,
                    edit: @escaping (String) -> Void, select: @escaping (NSRange) -> Void) {
            let changedDocument = documentID != document.id
            // Keep both callbacks and identity frozen during composition. In particular,
            // a cross-document SwiftUI update must not route old marked text to the new document.
            guard !textView.hasMarkedText() else { return }
            onEdit = edit
            onSelection = select
            if changedDocument {
                replace(document: document, selection: requestedSelection, in: textView, clearSelection: true)
                return
            }
            if TextSelectionEditorState.needsTextReplacement(current: textView.string, incoming: document.text) {
                replace(document: document, selection: requestedSelection, in: textView, clearSelection: false)
                return
            }
            documentRevision = document.revision
            currentDocument = document
            if requestedSelection != lastReportedSelection,
               let valid = TextSelectionEditorState.validRange(requestedSelection, in: document)
                ?? TextSelectionEditorState.validCursorRange(requestedSelection, in: document) {
                suppressCallbacks = true
                textView.setSelectedRange(valid)
                suppressCallbacks = false
                lastReportedSelection = valid
            }
        }

        private func replace(document: TextDraftDocument, selection: NSRange, in textView: NSTextView,
                             clearSelection: Bool) {
            suppressCallbacks = true
            textView.string = document.text
            let nextSelection = clearSelection ? NSRange(location: 0, length: 0)
                : (TextSelectionEditorState.validRange(selection, in: document)
                    ?? TextSelectionEditorState.validCursorRange(selection, in: document)
                    ?? NSRange(location: 0, length: 0))
            textView.setSelectedRange(nextSelection)
            suppressCallbacks = false
            documentID = document.id
            documentRevision = document.revision
            currentDocument = document
            lastReportedSelection = nextSelection
        }

        public func textDidChange(_ notification: Notification) {
            guard !suppressCallbacks, let textView = notification.object as? NSTextView,
                  let currentDocument, documentID == currentDocument.id,
                  documentRevision == currentDocument.revision else { return }
            onEdit?(textView.string)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !suppressCallbacks, let textView = notification.object as? NSTextView,
                  let currentDocument, documentID == currentDocument.id,
                  documentRevision == currentDocument.revision else { return }
            let range = textView.selectedRange()
            lastReportedSelection = range
            if range.length == 0 {
                onSelection?(range) // A collapsed selection clears a previous rewrite target.
            } else if TextSelectionEditorState.validRange(range, inNativeText: textView.string,
                                                           document: currentDocument) != nil {
                onSelection?(range)
            } else {
                onSelection?(NSRange(location: NSNotFound, length: 0))
            }
        }
    }
}
