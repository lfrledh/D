import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

/// Actual Quick field and controller; native marked-text simulation is component
/// evidence, separate from physical Pinyin/Japanese acceptance in the App.
@Suite(.serialized) @MainActor
struct QuickCompositionTests {
    @Test func savedRevisionAndLayoutDoNotDiscardUnconfirmedInput() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("quick-composition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Test.dproject"), name: "Test")
        let quick = QuickGenerationController(store: store) { throw WorkflowIssue("No inference permitted") }
        await quick.load()
        quick.select(operationID: "d.model.language", modelID: "fixture:composition")
        let id = try #require(quick.draft?.id)
        let original = "中文 e\u{301} 👩‍💻 "
        quick.setParameter("task", value: .text(original), draftID: id)
        try await quick.flush()
        let host = NSHostingView(rootView: QuickCompositionHost(quick: quick))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() async throws {
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        func editor() throws -> NSTextView {
            func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
            return try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        }
        try await settle()
        let text = try editor()
        #expect(window.makeFirstResponder(text))
        #expect(text.string == original)
        text.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                           replacementRange: NSRange(location: original.utf16.count, length: 0))
        try #require(text.hasMarkedText())
        let marked = text.markedRange()
        let revision = quick.state.revision
        try #require(quick.draft?.node.parameters["task"]?.string == original)
        try await quick.flush()
        try #require(quick.state.revision > revision)
        try await settle()
        #expect(text.hasMarkedText(), "A revision-only save must preserve composition even without resizing")
        #expect(text.string == original + "zhong")
        for width: CGFloat in [640, 480, 800] {
            window.setContentSize(NSSize(width: width, height: 300))
            try await settle()
            let current = try editor()
            #expect(current === text)
            #expect(text.hasMarkedText(), "Saved revision/layout must not erase unconfirmed input")
            #expect(text.markedRange() == marked)
            #expect(text.string == original + "zhong")
        }
        text.insertText("中", replacementRange: text.markedRange())
        try await settle()
        #expect(text.string == original + "中")
        #expect(quick.draft?.node.parameters["task"]?.string == original + "中")
        try await quick.flush()
        #expect(quick.state.runs.isEmpty)
        text.setMarkedText("old", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        try #require(text.hasMarkedText())
        quick.select(operationID: "d.model.language", modelID: "fixture:other-owner")
        try await settle()
        let other = try editor()
        #expect(other !== text && text.delegate == nil)
        #expect(!other.hasMarkedText())
        other.insertText("新草稿", replacementRange: NSRange(location: 0, length: other.string.utf16.count))
        try await settle()
        #expect(quick.draft?.node.parameters["task"]?.string == "新草稿")
        #expect(quick.state.drafts.first(where: { $0.id == id })?.node.parameters["task"]?.string == original + "中")
        quick.select(operationID: "d.model.language", modelID: "fixture:composition")
        try await quick.flush()
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let restored = QuickGenerationController(store: reopened) { throw WorkflowIssue("No inference permitted") }
        await restored.load()
        #expect(restored.draft?.node.parameters["task"]?.string == original + "中")
        try await reopened.close()
    }
}

@MainActor private struct QuickCompositionHost: View {
    @Bindable var quick: QuickGenerationController
    var body: some View {
        if let draft = quick.draft, let field = quick.definition?.fields.first(where: { $0.id == "task" }) {
            QuickParameterField(ownerID: draft.id, operationID: draft.node.operationID, field: field,
                value: draft.node.parameters[field.id] ?? field.defaultValue,
                onChange: { quick.setParameter(field.id, value: $0, draftID: draft.id) },
                raw: draft.fieldText[field.id], onRaw: { quick.setFieldText(field.id, text: $0, draftID: draft.id) })
        }
    }
}
