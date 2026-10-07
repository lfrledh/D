import AppKit
import SwiftUI
import Testing
@testable import UI

/// Native destination-method evidence with a controlled pasteboard. This does
/// not replace Finder hit-testing or sandbox import/save/reopen acceptance.
@Suite("Chat file drop boundary", .serialized) @MainActor
struct ChatFileDropTests {
    @Test func plainTextFileRegistrationSurvivesUpdatesAndFollowsBindingLifetime() {
        let view = FileDropTextView(), coordinator = TextSourcesQuestionEditor.Coordinator()
        view.isRichText = false
        view.delegate = coordinator
        view.onFileDrop = { _ in }
        for _ in 0..<3 {
            coordinator.update(view, value: "保留草稿", isEditable: true, onEdit: { _ in })
            #expect(view.registeredDraggedTypes == [.fileURL])
        }
        coordinator.update(view, value: "保留草稿", isEditable: false, onEdit: { _ in })
        #expect(view.registeredDraggedTypes.isEmpty)
        coordinator.update(view, value: "保留草稿", isEditable: true, onEdit: { _ in })
        #expect(view.registeredDraggedTypes == [.fileURL])
        view.onFileDrop = nil
        #expect(view.registeredDraggedTypes.isEmpty)
        view.onFileDrop = { _ in }
        #expect(view.registeredDraggedTypes == [.fileURL])
        let scroll = NSScrollView(); scroll.documentView = view
        TextSourcesQuestionEditor.dismantleNSView(scroll, coordinator: coordinator)
        #expect(view.registeredDraggedTypes.isEmpty)
        #expect(!view.isRichText && view.string == "保留草稿")
    }

    @Test func fileCopyFeedbackAndAcceptanceIgnoreCaretAndTextSelection() throws {
        let view = FileDropTextView(), coordinator = TextSourcesQuestionEditor.Coordinator()
        view.delegate = coordinator
        coordinator.update(view, value: "保留草稿 abc 中文", isEditable: true, onEdit: { _ in })
        view.textContainerInset = NSSize(width: 6, height: 6)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        let drag = FileDropInfo(urls: [URL(fileURLWithPath: "/fixture/numbers.csv")])
        drag.draggingDestinationWindow = window
        defer { drag.draggingPasteboard.releaseGlobally() }
        var received = 0
        view.onFileDrop = { _ in received += 1 }
        let original = view.string
        // Traverse both sides of the caret, over selected glyphs and empty
        // viewport space. File attachments have no text insertion position.
        let points = [NSPoint(x: 1, y: 1), NSPoint(x: 8, y: 12),
                      NSPoint(x: 50, y: 12), NSPoint(x: 390, y: 12),
                      NSPoint(x: 200, y: 160), NSPoint(x: 8, y: 12)]
        for selection in [NSRange(location: 0, length: 0), NSRange(location: 5, length: 0),
                          NSRange(location: 0, length: view.string.utf16.count)] {
            view.setSelectedRange(selection)
            for (index, point) in points.enumerated() {
                drag.draggingLocation = view.convert(point, to: nil)
                let operation = index == 0 ? view.draggingEntered(drag) : view.draggingUpdated(drag)
                #expect(operation == .copy, "File copy feedback at \(point), selection \(selection)")
                #expect(view.prepareForDragOperation(drag))
                #expect(view.string == original && view.selectedRange() == selection)
            }
            #expect(view.performDragOperation(drag))
            view.concludeDragOperation(drag)
            #expect(view.string == original && view.selectedRange() == selection)
        }
        #expect(received == 3)
    }

    @Test func filesReachCallbackWithoutEditingSelectionOrUndo() throws {
        let view = FileDropTextView()
        view.allowsUndo = true
        let coordinator = TextSourcesQuestionEditor.Coordinator()
        view.delegate = coordinator
        var edits = 0, received: [[URL]] = []
        coordinator.update(view, value: "保留 👩🏽‍🎨 e\u{301}", isEditable: true, onEdit: { _ in edits += 1 })
        view.onFileDrop = { received.append($0) }
        view.setSelectedRange(NSRange(location: 0, length: 2))
        let before = view.string, selection = view.selectedRange()
        let undo = try #require(view.undoManager)
        let sentinel = UndoSentinel()
        undo.registerUndo(withTarget: sentinel) { $0.value = true }
        let urls = [URL(fileURLWithPath: "/fixture/numbers.csv"), URL(fileURLWithPath: "/fixture/中文 note.txt")]
        let drag = FileDropInfo(urls: urls)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        drag.draggingDestinationWindow = window
        defer { window.contentView = nil }
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.draggingUpdated(drag) == .copy)
        #expect(view.dragOperation(for: drag, type: .string) == .copy)
        #expect(received.isEmpty, "Hover must never import")
        #expect(view.prepareForDragOperation(drag))
        #expect(view.string == before && view.selectedRange() == selection)
        #expect(view.performDragOperation(drag))
        view.concludeDragOperation(drag)
        #expect(received == [urls])
        #expect(view.string == before && view.selectedRange() == selection && edits == 0)
        #expect(undo.canUndo && !sentinel.value)
        undo.undo(); #expect(sentinel.value)
    }

    @Test func readonlyCompositionMoveOnlyAndDetachedRejectWithoutMutation() throws {
        let view = FileDropTextView(), coordinator = TextSourcesQuestionEditor.Coordinator()
        view.delegate = coordinator
        var received = 0
        coordinator.update(view, value: "原文 ", isEditable: true, onEdit: { _ in })
        view.onFileDrop = { _ in received += 1 }
        let drag = FileDropInfo(urls: [URL(fileURLWithPath: "/fixture/numbers.csv")])
        defer { drag.draggingPasteboard.releaseGlobally() }
        view.isEditable = false
        #expect(view.draggingEntered(drag).isEmpty && view.draggingUpdated(drag).isEmpty)
        #expect(!view.prepareForDragOperation(drag))
        #expect(view.dragOperation(for: drag, type: .fileURL).isEmpty)
        #expect(!view.performDragOperation(drag))
        view.isEditable = true
        drag.draggingSourceOperationMask = .move
        #expect(view.draggingEntered(drag).isEmpty && view.draggingUpdated(drag).isEmpty)
        #expect(!view.prepareForDragOperation(drag))
        #expect(view.dragOperation(for: drag, type: .fileURL).isEmpty)
        #expect(!view.performDragOperation(drag))
        drag.draggingSourceOperationMask = .copy
        view.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
            replacementRange: NSRange(location: view.string.utf16.count, length: 0))
        let marked = view.markedRange(), text = view.string, selection = view.selectedRange()
        #expect(view.draggingEntered(drag).isEmpty && view.draggingUpdated(drag).isEmpty)
        #expect(!view.prepareForDragOperation(drag))
        #expect(view.dragOperation(for: drag, type: .fileURL).isEmpty)
        #expect(!view.performDragOperation(drag))
        #expect(view.string == text && view.markedRange() == marked && view.selectedRange() == selection)
        view.unmarkText()
        let scroll = NSScrollView(); scroll.documentView = view
        TextSourcesQuestionEditor.dismantleNSView(scroll, coordinator: coordinator)
        #expect(view.draggingEntered(drag).isEmpty && view.draggingUpdated(drag).isEmpty)
        #expect(!view.prepareForDragOperation(drag))
        #expect(!view.performDragOperation(drag) && received == 0)
    }

    @Test func plainTextPathAndWebURLRemainTextAndDoNotGrantFileAccess() {
        let view = FileDropTextView(), coordinator = TextSourcesQuestionEditor.Coordinator()
        view.delegate = coordinator
        coordinator.update(view, value: "", isEditable: true, onEdit: { _ in })
        var received = 0
        view.onFileDrop = { _ in received += 1 }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        // Native paste/Services remain unchanged: even a path-looking string
        // must remain text rather than being resolved into an attachment.
        for text in ["普通文字 👩🏽‍🎨", "/fixture/numbers.csv", "file:///fixture/numbers.csv", "https://example.org/numbers.csv"] {
            board.clearContents(); board.setString(text, forType: .string)
            view.string = ""; view.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(view.readSelection(from: board, type: .string))
            #expect(view.string == text)
        }
        #expect(received == 0)
    }

    @Test func plainTextDragKeepsNativeBehaviorIncludingPathLookingText() {
        let native = NSTextView(), view = FileDropTextView()
        let coordinator = TextSourcesQuestionEditor.Coordinator()
        view.delegate = coordinator
        coordinator.update(view, value: "", isEditable: true, onEdit: { _ in })
        var received = 0
        view.onFileDrop = { _ in received += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        for text in ["普通文字 👩🏽‍🎨", "/fixture/numbers.csv", "file:///fixture/numbers.csv", "https://example.org/numbers.csv"] {
            let drag = FileDropInfo(urls: [])
            defer { drag.draggingPasteboard.releaseGlobally() }
            drag.draggingDestinationWindow = window
            drag.draggingPasteboard.setString(text, forType: .string)
            var operations: [NSDragOperation] = [], results: [Bool] = [], values: [String] = []
            for target in [native, view] {
                target.isRichText = false; target.isEditable = true; target.string = ""
                window.contentView = target
                operations.append(target.draggingEntered(drag))
                _ = target.draggingUpdated(drag)
                #expect(target.prepareForDragOperation(drag))
                results.append(target.performDragOperation(drag))
                target.concludeDragOperation(drag)
                values.append(target.string)
            }
            #expect(operations[0] == operations[1])
            #expect(results == [true, true] && values == [text, text])
        }
        #expect(received == 0)
    }

    @Test func representableOptInBindsOnlyAttachmentEditorAndClearsCallback() throws {
        var received: [[URL]] = []
        let host = NSHostingView(rootView: TextSourcesQuestionEditor(value: "草稿", editEpoch: 0,
            isEditable: true, onEdit: { _ in }, onFileDrop: { received.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap { find($0) }.first
        }
        let editor = try #require(find(host) as? FileDropTextView)
        let clip = try #require(editor.superview as? NSClipView)
        for point in [NSPoint(x: 2, y: 2), NSPoint(x: clip.bounds.width - 2, y: 2),
                      NSPoint(x: 2, y: clip.bounds.height - 2),
                      NSPoint(x: clip.bounds.width - 2, y: clip.bounds.height - 2)] {
            #expect(editor.frame.contains(point), "Attachment editor must fill visible input at \(point)")
        }
        let drag = FileDropInfo(urls: [URL(fileURLWithPath: "/fixture/numbers.csv")])
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(editor.performDragOperation(drag) && received.count == 1)
        #expect(editor.string == "草稿")
        let ordinary = NSHostingView(rootView: TextSourcesQuestionEditor(value: "", editEpoch: 0,
            isEditable: true, onEdit: { _ in }))
        ordinary.frame = host.frame; ordinary.layoutSubtreeIfNeeded()
        #expect(find(ordinary) != nil && !(find(ordinary) is FileDropTextView))
    }
}

@MainActor private final class UndoSentinel { var value = false }

@MainActor private final class FileDropInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingDestinationWindow: NSWindow?
    var draggingLocation = NSPoint(x: 100, y: 80)
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(urls: [URL]) {
        super.init()
        draggingPasteboard.writeObjects(urls as [NSURL])
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
