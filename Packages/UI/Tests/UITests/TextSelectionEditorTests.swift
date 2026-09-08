import AppKit
import DWorkbench
import Foundation
import Testing
@testable import UI

@Suite @MainActor
struct TextSelectionEditorTests {
    @Test func replacementUsesExactUTF8BytesRatherThanCanonicalStringEquality() {
        #expect(TextSelectionEditorState.needsTextReplacement(current: "e\u{301}", incoming: "é"))
        #expect(!TextSelectionEditorState.needsTextReplacement(current: "👩‍💻", incoming: "👩‍💻"))
    }

    @Test func rewriteRangeRequiresCharacterAlignmentButCursorMayBeEmpty() throws {
        let document = try TextDraftDocument(text: "中e\u{301}👩‍💻🇯🇵Z")
        #expect(TextSelectionEditorState.validRange(NSRange(location: 1, length: 2), in: document) != nil)
        #expect(TextSelectionEditorState.validRange(NSRange(location: 2, length: 1), in: document) == nil)
        #expect(TextSelectionEditorState.validRange(NSRange(location: 0, length: 0), in: document) == nil)
        #expect(TextSelectionEditorState.validCursorRange(NSRange(location: 1, length: 0), in: document) != nil)
        #expect(TextSelectionEditorState.validCursorRange(NSRange(location: 2, length: 0), in: document) == nil)
    }

    @Test func programmaticTextReplacementDoesNotEchoEditCallback() throws {
        let original = try TextDraftDocument(text: "原稿")
        let replacement = try TextDraftDocument(id: original.id, text: "更新后的原稿")
        let textView = NSTextView()
        let coordinator = TextSelectionEditor.Coordinator()
        textView.delegate = coordinator
        var editCount = 0
        coordinator.install(document: original, selection: NSRange(location: 0, length: 0), in: textView,
                            edit: { _ in editCount += 1 }, select: { _ in })

        coordinator.update(document: replacement, requestedSelection: NSRange(location: 0, length: 0), in: textView,
                           edit: { _ in editCount += 1 }, select: { _ in })

        #expect(textView.string == replacement.text)
        #expect(editCount == 0)
    }

    @Test func documentSwitchReplacesTextAndClearsSelection() throws {
        let first = try TextDraftDocument(text: "first document")
        let second = try TextDraftDocument(text: "second document")
        let textView = NSTextView()
        let coordinator = TextSelectionEditor.Coordinator()
        textView.delegate = coordinator
        coordinator.install(document: first, selection: NSRange(location: 1, length: 3), in: textView,
                            edit: { _ in }, select: { _ in })

        coordinator.update(document: second, requestedSelection: NSRange(location: 1, length: 3), in: textView,
                           edit: { _ in }, select: { _ in })

        #expect(textView.string == second.text)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func sameDocumentRevisionCanProgrammaticallyClearToCursor() throws {
        let document = try TextDraftDocument(text: "中e\u{301}")
        let revised = try TextDraftDocument(id: document.id, text: document.text)
        let textView = NSTextView()
        let coordinator = TextSelectionEditor.Coordinator()
        textView.delegate = coordinator
        coordinator.install(document: document, selection: NSRange(location: 1, length: 2), in: textView,
                            edit: { _ in }, select: { _ in })

        coordinator.update(document: revised, requestedSelection: NSRange(location: 1, length: 0), in: textView,
                           edit: { _ in }, select: { _ in })

        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func nativeTextSelectionUsesTheEditedUnicodeTextBeforeSwiftUIRefresh() throws {
        let document = try TextDraftDocument(text: "e")
        let textView = NSTextView()
        let coordinator = TextSelectionEditor.Coordinator()
        textView.delegate = coordinator
        var reported: NSRange?
        coordinator.install(document: document, selection: NSRange(location: 0, length: 0), in: textView,
                            edit: { _ in }, select: { reported = $0 })
        textView.string = "e\u{301}"
        textView.setSelectedRange(NSRange(location: 0, length: 2))

        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,
                                                             object: textView))

        #expect(reported == NSRange(location: 0, length: 2))
    }

    @Test func markedTextIsNotOverwrittenBySameOrNewDocumentUpdate() throws {
        let original = try TextDraftDocument(text: "draft")
        let replacement = try TextDraftDocument(text: "other document")
        let textView = NSTextView()
        let coordinator = TextSelectionEditor.Coordinator()
        textView.delegate = coordinator
        coordinator.install(document: original, selection: NSRange(location: 0, length: 0), in: textView,
                            edit: { _ in }, select: { _ in })
        textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: 0, length: 0))

        coordinator.update(document: replacement, requestedSelection: NSRange(location: 0, length: 0), in: textView,
                           edit: { _ in }, select: { _ in })

        #expect(textView.hasMarkedText())
        #expect(textView.string != replacement.text)
    }
}
