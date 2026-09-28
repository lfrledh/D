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
        // Count this helper's deliveries, not independent AppKit layout notifications.
        var delivered: [NSView] = []
        let tracker = WorkbenchInputGeometry(window: window) { responder in
            delivered.append(responder)
            responder.inputContext?.invalidateCharacterCoordinates()
        }
        for _ in 0..<20 { tracker.invalidateAfterLayout() }
        window.makeFirstResponder(next)
        try await Task.sleep(for: .milliseconds(30))
        #expect(delivered.count == 1)
        #expect(delivered.first === next)
        #expect(!delivered.contains { $0 === old || $0 === other })
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
        var delivered: [NSView] = []
        delegate.connect(window: window, model: model, prepareLibraryForTermination: { true },
                         invalidateInputContext: { view in
            delivered.append(view)
            view.inputContext?.invalidateCharacterCoordinates()
        })
        let callbacks: [(Notification.Name, (Notification) -> Void)] = [
            (NSWindow.didMoveNotification, delegate.windowDidMove),
            (NSWindow.didResizeNotification, delegate.windowDidResize),
            (NSWindow.didChangeScreenNotification, delegate.windowDidChangeScreen),
            (NSWindow.didChangeBackingPropertiesNotification, delegate.windowDidChangeBackingProperties),
            (NSWindow.didEndLiveResizeNotification, delegate.windowDidEndLiveResize)
        ]
        for (name, callback) in callbacks {
            delivered = []
            let prior = previous.events[name, default: 0]
            callback(Notification(name: name, object: window))
            drainGeometryUpdates()
            #expect(previous.events[name, default: 0] == prior + 1)
            #expect(delivered.count == 1 && delivered.first === editor)
        }
        delivered = []
        delegate.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: otherWindow))
        drainGeometryUpdates()
        #expect(delivered.isEmpty)
        delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        drainGeometryUpdates()
        #expect(delivered.isEmpty, "Closing must cancel the queued update even if the window remains retained.")
        delegate.connect(window: window, model: model, prepareLibraryForTermination: { true },
                         invalidateInputContext: { view in delivered.append(view); view.inputContext?.invalidateCharacterCoordinates() })
        let forwardedBeforeReopen = previous.events[NSWindow.didMoveNotification, default: 0]
        delegate.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        drainGeometryUpdates()
        #expect(delivered.count == 1 && delivered.first === editor)
        #expect(previous.events[NSWindow.didMoveNotification, default: 0] == forwardedBeforeReopen + 1)
    }

    @Test func attachedSheetReceivesGeometryUpdateWithoutChangingMarkedText() async throws {
        let (window, rootEditor) = fixture()
        let (sheet, sheetEditor) = fixture()
        let (unrelated, unrelatedEditor) = fixture()
        defer {
            window.endSheet(sheet)
            sheet.orderOut(nil)
            window.close(); sheet.close(); unrelated.close()
        }
        window.beginSheet(sheet, completionHandler: nil)
        sheet.makeFirstResponder(sheetEditor)
        sheetEditor.string = "中文 e\u{301} 👩🏽‍🎨 "
        sheetEditor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
                                  replacementRange: NSRange(location: sheetEditor.string.utf16.count, length: 0))
        let text = sheetEditor.string, marked = sheetEditor.markedRange(), selection = sheetEditor.selectedRange()
        var delivered: [NSView] = []
        let tracker = WorkbenchInputGeometry(window: window) { view in delivered.append(view) }
        tracker.invalidateAfterLayout()
        drainGeometryUpdates()
        #expect(delivered.count == 1 && delivered.first === sheetEditor,
                "A parent move must invalidate the presented sheet's input client, not its old root responder.")
        #expect(!delivered.contains { $0 === rootEditor || $0 === unrelatedEditor })
        #expect(sheetEditor.string.utf8.elementsEqual(text.utf8))
        #expect(sheetEditor.markedRange() == marked && sheetEditor.selectedRange() == selection)
        delivered = []
        tracker.invalidateAfterLayout()
        window.endSheet(sheet)
        sheet.orderOut(nil)
        window.makeFirstResponder(rootEditor)
        drainGeometryUpdates()
        #expect(delivered.count == 1 && delivered.first === rootEditor)
        #expect(!delivered.contains { $0 === sheetEditor || $0 === unrelatedEditor },
                "Queued delivery must return to the root client, not retain the dismissed sheet.")
    }

    @Test func geometryDeliveryDoesNotWaitForEndOfEventTracking() {
        let (window, editor) = fixture()
        defer { window.close() }
        var delivered: [NSView] = []
        let tracker = WorkbenchInputGeometry(window: window) { delivered.append($0) }
        for mode in [RunLoop.Mode.eventTracking, .modalPanel] {
            delivered = []
            tracker.invalidateAfterLayout()
            let deadline = Date(timeIntervalSinceNow: 0.05)
            while delivered.isEmpty && Date() < deadline {
                _ = RunLoop.main.run(mode: mode, before: deadline)
            }
            #expect(delivered.count == 1 && delivered.first === editor,
                    "Input coordinates must update before the tracking or modal loop ends.")
        }
    }

    private func drainGeometryUpdates() {
        // Exercise the helper's run-loop scheduling, including negative cases.
        // A DispatchQueue marker alone does not establish this delivery boundary.
        let deadline = Date(timeIntervalSinceNow: 0.02)
        repeat { _ = RunLoop.main.run(mode: .default, before: deadline) } while Date() < deadline
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
