import AppKit
import SwiftUI
import Testing
@testable import UI

// Explicit component fixture: controls only AppKit key-window state. It does
// not claim OS focus or keyboard delivery; signed-App CGEvent covers that.
@MainActor private final class ComposerRoutingWindow: NSWindow {
    var hasKeyFocus = true
    override var isKeyWindow: Bool { hasKeyFocus }
}

@Suite("Native composer key routing", .serialized)
@MainActor struct ChatComposerKeyRoutingTests {
    @Test func commandReturnUsesNativeResponderOnceAndPreservesOtherEditors() async throws {
        _ = NSApplication.shared
        var submissions = 0
        let host = NSHostingView(rootView: TextSourcesQuestionEditor(
            value: "draft", editEpoch: 0, isEditable: true, onEdit: { _ in },
            onSubmit: { submissions += 1 }))
        let window = ComposerRoutingWindow(contentRect: .init(x: 100, y: 100, width: 400, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> FileDropTextView? {
            if let editor = view as? FileDropTextView { return editor }
            return view.subviews.compactMap(find).first
        }
        let editor = try #require(find(host))
        #expect(window.makeFirstResponder(editor))
        try #require(window.isKeyWindow)
        func event(_ flags: NSEvent.ModifierFlags = .command, repeatKey: Bool = false, key: UInt16 = 36) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: key))
        }
        // Exercise AppKit's window/responder route, not Coordinator.submitIfAllowed.
        #expect(try window.performKeyEquivalent(with: event()))
        #expect(submissions == 1)
        #expect(editor.string == "draft")
        #expect(try window.performKeyEquivalent(with: event(key: 76)))
        #expect(submissions == 2)
        _ = try window.performKeyEquivalent(with: event(repeatKey: true))
        #expect(submissions == 2)
        for flags: NSEvent.ModifierFlags in [.option, .control, [.command, .shift]] {
            _ = try window.performKeyEquivalent(with: event(flags))
            #expect(submissions == 2)
        }
        editor.setMarkedText("ni", selectedRange: .init(location: 2, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0))
        _ = try window.performKeyEquivalent(with: event())
        #expect(submissions == 2 && editor.hasMarkedText())
        editor.unmarkText()
        editor.isEditable = false
        _ = try window.performKeyEquivalent(with: event())
        #expect(submissions == 2)
        editor.isEditable = true; host.isHidden = true
        _ = try window.performKeyEquivalent(with: event())
        #expect(submissions == 2)
        host.isHidden = false
        window.hasKeyFocus = false
        _ = try window.performKeyEquivalent(with: event())
        #expect(submissions == 2)
        window.hasKeyFocus = true
        let other = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 40))
        host.addSubview(other); window.makeFirstResponder(other)
        _ = try window.performKeyEquivalent(with: event())
        #expect(submissions == 2)
        host.rootView = TextSourcesQuestionEditor(value: "draft", editEpoch: 0,
            isEditable: true, onEdit: { _ in }, sendsOnReturn: true,
            onSubmit: { submissions += 1 })
        host.layoutSubtreeIfNeeded()
        #expect(find(host) === editor)
        window.makeFirstResponder(editor)
        _ = try window.performKeyEquivalent(with: event())
        #expect(submissions == 2) // Return preference does not enable Cmd-Return.
    }
}
