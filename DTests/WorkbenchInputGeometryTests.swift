import AppKit
import Testing
@testable import D

/// Component evidence: native input contexts and screen rectangles, not a human IME test.
@Suite(.serialized) @MainActor
struct WorkbenchInputGeometryTests {
    private func fixture() -> (NSWindow, GeometryTextView) {
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 700, height: 260),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = GeometryTextView(frame: NSRect(x: 20, y: 20, width: 600, height: 180))
        editor.autoresizingMask = [.width, .height]
        editor.allowsUndo = true
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)
        return (window, editor)
    }

    @Test func nativeCoordinatesMoveWhileCompositionAndUndoRemainIntact() async throws {
        let (window, editor) = fixture()
        defer { window.contentView = nil; window.close() }
        editor.string = "中文 e\u{301} 👩🏽‍🎨 "
        editor.insertText("test", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        #expect(editor.hasMarkedText())
        let value = editor.string, marked = editor.markedRange(), selected = editor.selectedRange()
        let undo = editor.undoManager, canUndo = undo?.canUndo
        var actual = NSRange()
        let before = editor.firstRect(forCharacterRange: marked, actualRange: &actual)
        let tracker = WorkbenchInputGeometry(window: window)
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: origin.x + 100, y: origin.y + 60))
        tracker.invalidateAfterLayout()
        try await Task.sleep(for: .milliseconds(30))
        let after = editor.firstRect(forCharacterRange: marked, actualRange: &actual)
        #expect(abs(after.minX - before.minX - 100) < 1)
        #expect(abs(after.minY - before.minY - 60) < 1)
        for width: CGFloat in [420, 850] {
            window.setContentSize(NSSize(width: width, height: 260))
            tracker.invalidateAfterLayout()
            try await Task.sleep(for: .milliseconds(30))
            #expect(editor.string.utf8.elementsEqual(value.utf8))
            #expect(editor.hasMarkedText() && editor.markedRange() == marked)
            #expect(editor.selectedRange() == selected && window.firstResponder === editor)
            #expect(editor.undoManager === undo && undo?.canUndo == canUndo)
        }
        #expect(editor.geometryContext.invalidations > 0)
    }

    @Test func coalescesAndUsesCurrentFocusWithoutTouchingAnotherWindow() async throws {
        let (window, old) = fixture(), (otherWindow, other) = fixture()
        defer { window.contentView = nil; otherWindow.contentView = nil; window.close(); otherWindow.close() }
        let next = GeometryTextView(frame: old.frame)
        window.contentView?.addSubview(next)
        let tracker = WorkbenchInputGeometry(window: window)
        for _ in 0..<20 { tracker.invalidateAfterLayout() }
        window.makeFirstResponder(next)
        old.geometryContext.invalidations = 0
        next.geometryContext.invalidations = 0
        other.geometryContext.invalidations = 0
        try await Task.sleep(for: .milliseconds(30))
        #expect(old.geometryContext.invalidations == 0)
        #expect(next.geometryContext.invalidations == 1)
        #expect(other.geometryContext.invalidations == 0)
    }
}

@MainActor private final class GeometryTextView: NSTextView {
    lazy var geometryContext = GeometryInputContext(client: self)
    override var inputContext: NSTextInputContext? { geometryContext }
}

@MainActor private final class GeometryInputContext: NSTextInputContext {
    var invalidations = 0
    override func invalidateCharacterCoordinates() {
        invalidations += 1
        super.invalidateCharacterCoordinates()
    }
}
