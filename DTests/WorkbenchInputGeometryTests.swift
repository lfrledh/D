import AppKit
import DWorkbench
import Testing
import UI
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
        let undo = try #require(editor.undoManager)
        undo.beginUndoGrouping()
        editor.insertText("test", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        editor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        #expect(editor.hasMarkedText())
        let value = editor.string, marked = editor.markedRange(), selected = editor.selectedRange()
        let canUndo = undo.canUndo
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
            #expect(editor.undoManager === undo && undo.canUndo == canUndo)
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

    @Test func realDelegateForwardsEventsAndOnlyInvalidatesItsAttachedWindow() async throws {
        let suite = "D.Geometry." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let model = WorkbenchModel(sessionFactory: { _ in throw WorkflowIssue("No inference in geometry test") }, settings: settings)
        let (window, editor) = fixture(), (otherWindow, other) = fixture()
        defer { window.contentView = nil; otherWindow.contentView = nil; window.close(); otherWindow.close() }
        let previous = GeometryWindowDelegate()
        window.delegate = previous
        let delegate = WorkbenchApplicationDelegate()
        delegate.connect(window: window, model: model, prepareLibraryForTermination: { true })
        let callbacks: [(Notification.Name, (Notification) -> Void)] = [
            (NSWindow.didMoveNotification, delegate.windowDidMove),
            (NSWindow.didResizeNotification, delegate.windowDidResize),
            (NSWindow.didChangeScreenNotification, delegate.windowDidChangeScreen),
            (NSWindow.didChangeBackingPropertiesNotification, delegate.windowDidChangeBackingProperties),
            (NSWindow.didEndLiveResizeNotification, delegate.windowDidEndLiveResize)
        ]
        for (name, callback) in callbacks {
            editor.geometryContext.invalidations = 0
            let prior = previous.events[name, default: 0]
            callback(Notification(name: name, object: window))
            await drainMainQueue()
            #expect(previous.events[name, default: 0] == prior + 1)
            #expect(editor.geometryContext.invalidations == 1)
        }
        editor.geometryContext.invalidations = 0; other.geometryContext.invalidations = 0
        delegate.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: otherWindow))
        await drainMainQueue()
        #expect(editor.geometryContext.invalidations == 0 && other.geometryContext.invalidations == 0)
        delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        await drainMainQueue()
        #expect(editor.geometryContext.invalidations == 0, "Closing must cancel the queued update even if the window remains retained.")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}

@MainActor private final class GeometryWindowDelegate: NSObject, NSWindowDelegate {
    var events: [Notification.Name: Int] = [:]
    func windowDidMove(_ n: Notification) { events[n.name, default: 0] += 1 }
    func windowDidResize(_ n: Notification) { events[n.name, default: 0] += 1 }
    func windowDidChangeScreen(_ n: Notification) { events[n.name, default: 0] += 1 }
    func windowDidChangeBackingProperties(_ n: Notification) { events[n.name, default: 0] += 1 }
    func windowDidEndLiveResize(_ n: Notification) { events[n.name, default: 0] += 1 }
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
