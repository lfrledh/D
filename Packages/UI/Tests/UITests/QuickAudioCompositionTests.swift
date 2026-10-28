import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite(.serialized) @MainActor struct QuickAudioCompositionTests {
    @Test func audioEditorKeepsIdentityMarkedTextAndUndoAcrossSaveLanguageAndResize() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("audio-editor-\(UUID()).dproject")
        let store = try await ProjectStore.create(at: root, name: "Audio editor fixture")
        let quick = QuickGenerationController(store: store) { throw WorkflowIssue("No inference") }
        await quick.load(); quick.select(operationID: "d.music.generate", modelID: "fixture:audio")
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let host = NSHostingView(rootView: QuickAudioInput(quick: quick, continueInWorkflow: { _ in }).environment(\.dLanguageStore, language))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 230), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        func settle() async throws { for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) } }
        func editor() throws -> NSTextView {
            func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
            return try #require(all(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        }
        try await settle(); let text = try editor(); #expect(window.makeFirstResponder(text))
        text.insertText("Piano ", replacementRange: .init(location: 0, length: 0))
        try await settle()
        text.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0), replacementRange: .init(location: 6, length: 0))
        #expect(text.hasMarkedText())
        try await quick.flush(); try language.select("en"); window.setContentSize(.init(width: 360, height: 220)); try await settle()
        #expect(try editor() === text); #expect(text.hasMarkedText()); #expect(text.string == "Piano zhong")
        text.insertText("中", replacementRange: text.markedRange()); try await settle()
        #expect(quick.draft?.node.parameters["promptText"] == .text("Piano 中"))
        #expect(text.undoManager?.canUndo == true)
        text.undoManager?.undo(); try await settle()
        #expect(!text.hasMarkedText()); #expect(quick.state.runs.isEmpty)
        #expect(language.text("quick.audio.description", fallback: "missing") == "Music description")
        try language.select("zh-Hans"); #expect(language.text("quick.audio.generate", fallback: "missing") == "生成音频")
        try await quick.prepareForTermination(); try await store.close()
    }
}
