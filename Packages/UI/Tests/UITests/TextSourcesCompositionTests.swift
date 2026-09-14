import AppKit
import DInference
import DWorkbench
import SwiftUI
import Testing
@testable import UI

/// Native marked-text checks are deterministic component evidence. They do not
/// replace the separate human Pinyin / Space-key acceptance in an ordinary app.
@Suite("Sources question composition", .serialized) @MainActor
struct TextSourcesCompositionTests {
    @Test func nativeUndoRedoAndDetachedDocumentKeepValidIndependentQuestions() async throws {
        func controller(_ question: String) throws -> ProjectTextSourcesController {
            try .init(notebook: TextSourcesNotebook(question: question), document: TextDraftDocument(text: "正文"),
                      engine: CompositionEngine(), backendID: "fixture", persist: { _, _, _, _ in })
        }
        let first = try controller("初稿 👩‍💻"), second = try controller("另一份 e\u{301}")
        let host = NSHostingView(rootView: CompositionHost(controller: first))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() async throws {
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        func editor() throws -> NSTextView {
            func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
            return try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        }
        try await settle()
        let oldEditor = try editor(), undo = try #require(oldEditor.undoManager)
        let windowUndo = try #require(window.undoManager)
        #expect(undo !== windowUndo)
        let unrelated = UndoSentinel()
        windowUndo.registerUndo(withTarget: unrelated) { $0.value = false }
        #expect(window.makeFirstResponder(oldEditor))
        func append(_ value: String) {
            undo.beginUndoGrouping()
            oldEditor.insertText(value, replacementRange: NSRange(location: oldEditor.string.utf16.count, length: 0))
            undo.endUndoGrouping()
        }
        append(" 修改")
        try await settle()
        #expect(first.notebook.question == "初稿 👩‍💻 修改")
        #expect(undo.canUndo)
        undo.undo(); try await settle()
        print("IME undo native=\(oldEditor.string.debugDescription) accepted=\(first.notebook.question.debugDescription) canUndo=\(undo.canUndo) canRedo=\(undo.canRedo) grouping=\(undo.groupingLevel)")
        #expect(first.notebook.question == "初稿 👩‍💻" && oldEditor.string == first.notebook.question)
        #expect(undo.canRedo)
        undo.redo(); try await settle()
        #expect(first.notebook.question == "初稿 👩‍💻 修改")
        append(String(repeating: "x", count: TextSourcesLimits.questionBytes + 1))
        try await settle()
        #expect(oldEditor.string == first.notebook.question && first.notebook.question == "初稿 👩‍💻 修改")
        #expect(!undo.canUndo && !undo.canRedo, "Rejected native text invalidates this editor's old typing ranges.")
        #expect(windowUndo.canUndo && unrelated.value, "Do not clear unrelated window undo actions.")
        if undo.canUndo { undo.undo(); try await settle() }
        if undo.canRedo { undo.redo(); try await settle() }
        #expect(oldEditor.string.utf8.elementsEqual(first.notebook.question.utf8))
        #expect(first.notebook.question.utf8.count <= TextSourcesLimits.questionBytes)
        append(" 正常编辑")
        try await settle()
        #expect(undo.canUndo)
        let firstValue = first.notebook.question
        host.rootView = CompositionHost(controller: second)
        try await settle()
        let next = try editor()
        #expect(next !== oldEditor && oldEditor.delegate == nil)
        #expect(!undo.canUndo && !undo.canRedo && windowUndo.canUndo)
        #expect(window.makeFirstResponder(next))
        if undo.canUndo { undo.undo(); try await settle() }
        #expect(first.notebook.question == firstValue)
        #expect(second.notebook.question.utf8.elementsEqual("另一份 e\u{301}".utf8))
        #expect(next.string.utf8.elementsEqual(second.notebook.question.utf8))
    }

    @Test func compositionDoesNotPublishPartialTextOrRebindItsOwner() {
        let editor = NSTextView()
        let coordinator = TextSourcesQuestionEditor.Coordinator()
        editor.delegate = coordinator
        var oldEdits: [String] = [], newEdits: [String] = []
        coordinator.update(editor, value: "旧问题 ", isEditable: true) { oldEdits.append($0) }
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(oldEdits.isEmpty)
        coordinator.update(editor, value: "其他文档", isEditable: false) { newEdits.append($0) }
        #expect(editor.hasMarkedText() && editor.string == "旧问题 zhong")
        editor.insertText("中", replacementRange: editor.markedRange())
        #expect(oldEdits == ["旧问题 中"] && newEdits.isEmpty)
        coordinator.update(editor, value: "其他文档", isEditable: true) { newEdits.append($0) }
        let scroll = NSScrollView(); scroll.documentView = editor
        TextSourcesQuestionEditor.dismantleNSView(scroll, coordinator: coordinator)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(editor.delegate == nil && newEdits.isEmpty)
    }

    @Test func repeatedRejectedEditsRestoreAuthorityAndUnicodeEditsRemainExact() async throws {
        let controller = try ProjectTextSourcesController(
            notebook: TextSourcesNotebook(question: "中文 e\u{301} 👩‍💻"),
            document: TextDraftDocument(text: "原稿"), engine: CompositionEngine(),
            backendID: "fixture", persist: { _, _, _, _ in })
        let host = NSHostingView(rootView: CompositionHost(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 540)
        func settle() async throws {
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        try await settle()
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        let accepted = controller.notebook.question
        for _ in 0..<2 {
            editor.insertText(String(repeating: "x", count: TextSourcesLimits.questionBytes + 1),
                              replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await settle()
            #expect(controller.errorMessage != nil)
            #expect(controller.notebook.question.utf8.elementsEqual(accepted.utf8))
            #expect(editor.string.utf8.elementsEqual(accepted.utf8), "Repeated same-error rejection must restore the native editor too.")
        }
        let changed = "中文 é 👩‍💻"
        #expect(changed == accepted && !changed.utf8.elementsEqual(accepted.utf8))
        editor.insertText(changed, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await settle()
        #expect(editor.string.utf8.elementsEqual(changed.utf8))
        #expect(controller.notebook.question.utf8.elementsEqual(changed.utf8))
        #expect(controller.errorMessage == nil && controller.document.text == "原稿")
    }

    @Test func liveControllerKeepsMarkedTextAcrossLayoutUpdates() async throws {
        let controller = try ProjectTextSourcesController(
            notebook: TextSourcesNotebook(question: "中文 e\u{301} 👩‍💻 "),
            document: TextDraftDocument(text: "原文"), engine: CompositionEngine(),
            backendID: "fixture", persist: { _, _, _, _ in })
        let host = NSHostingView(rootView: CompositionHost(controller: controller))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle(_ width: CGFloat) async throws {
            window.setContentSize(NSSize(width: width, height: 540))
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func editor() throws -> NSTextView {
            func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
            return try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        }
        try await settle(900)
        let original = try editor()
        #expect(window.makeFirstResponder(original))
        let before = original.string
        let insertion = NSRange(location: before.utf16.count, length: 0)
        original.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: insertion)
        #expect(original.hasMarkedText())
        let marked = original.markedRange(), selection = original.selectedRange()
        for width: CGFloat in [900, 860, 600, 1000] {
            try await settle(width)
            let current = try editor()
            print("IME probe width=\(width) same=\(current === original) responder=\(window.firstResponder === current) marked=\(current.markedRange()) selected=\(current.selectedRange()) native=\(current.string.debugDescription) accepted=\(controller.notebook.question.debugDescription)")
            #expect(current === original)
            #expect(window.firstResponder === current)
            #expect(current.hasMarkedText(), "Layout / controller publication must not discard composition.")
            #expect(current.markedRange() == marked)
            #expect(current.selectedRange() == selection)
            #expect(current.string.utf8.elementsEqual((before + "zhong").utf8))
        }
        // Simulate the input method's committed replacement, not an actual Pinyin key event.
        original.insertText("中", replacementRange: original.markedRange())
        try await settle(600)
        #expect(!original.hasMarkedText())
        #expect(original.string.utf8.elementsEqual((before + "中").utf8))
        #expect(controller.notebook.question.utf8.elementsEqual((before + "中").utf8))
        #expect(controller.document.text == "原文")
    }
}

private final class UndoSentinel { var value = true }

private struct CompositionHost: View {
    @Bindable var controller: ProjectTextSourcesController
    var body: some View {
        TextSourcesView(notebook: controller.notebook, partialAnswer: controller.partialAnswer,
            isRunning: controller.isRunning, isCancelling: controller.isCancelling,
            isSaving: controller.isSaving, canAsk: controller.canAsk, canUndo: controller.canUndo,
            errorMessage: controller.errorMessage, canAccept: controller.canAccept,
            citationSummary: controller.citationSummary,
            actions: .init(importSource: {}, removeSource: controller.removeSource,
                useExcerpt: { controller.useExcerpt(sourceID: $0, range: $1) },
                changeQuestion: controller.changeQuestion, ask: {}, cancel: {},
                accept: { _ in }, reject: { _ in }, undo: {}, save: {}))
        .id(controller.document.id)
    }
}

private actor CompositionEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        .init(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { .cancelled })
    }
}
