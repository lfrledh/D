import AppKit
import SwiftUI

/// Only the existing lens receives a drag. The four real buttons underneath
/// retain ordinary clicks, keyboard focus and accessibility activation.
struct WorkbenchCategoryDragReceiver: NSViewRepresentable {
    let selection: Int
    let owner: ObjectIdentifier
    let enabled: Bool
    let onPreview: (CGFloat?) -> Void
    let onCommit: (Int) -> Void
    var presentation = CGRect(x: 0, y: 0, width: 62.5, height: 36)
    var presentationSelection: CGFloat = 0
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> WorkbenchCategoryDragView {
        let view = WorkbenchCategoryDragView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: WorkbenchCategoryDragView, context: Context) {
        let accepts = enabled && environmentEnabled
        if view.owner != owner || view.selection != selection || !accepts {
            // SwiftUI clears its preview for owner/availability changes. Never
            // publish state from inside a representable update.
            view.cancel(notify: false)
        }
        view.selection = selection; view.owner = owner; view.enabled = accepts
        view.onPreview = onPreview; view.onCommit = onCommit
        view.presentation = presentation; view.presentationSelection = presentationSelection
        #if DEBUG
        WorkbenchCategoryUpdateProbe.presentationTrace()
        #endif
    }
    static func dismantleNSView(_ view: WorkbenchCategoryDragView, coordinator: ()) {
        view.cancel(notify: false)
    }
}

final class WorkbenchCategoryDragView: NSView {
    static let itemWidth: CGFloat = 62.5
    static let stride: CGFloat = 64.5
    var selection = 0
    var owner: ObjectIdentifier?
    var enabled = true
    var onPreview: (CGFloat?) -> Void = { _ in }
    var onCommit: (Int) -> Void = { _ in }
    var presentation = CGRect(x: 0, y: 0, width: 62.5, height: 36)
    var presentationSelection: CGFloat = 0
    private var lastPreview: CGFloat?
    private var startPresentation: CGFloat = 0
    private var start: CGPoint?
    private var startSelection = 0
    private var startOwner: ObjectIdentifier?
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        return NSBezierPath(roundedRect: presentation, xRadius: presentation.height / 2,
            yRadius: presentation.height / 2).contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled, event.buttonNumber == 0, let window, window.isKeyWindow else { return }
        cancel(notify: false)
        #if DEBUG
        WorkbenchCategoryUpdateProbe.beginTrace()
        #endif
        start = convert(event.locationInWindow, from: nil)
        startSelection = selection; startOwner = owner; startPresentation = presentationSelection
        lastPreview = startPresentation
        onPreview(startPresentation)
        // A temporary, window-scoped Escape monitor cancels a drag without
        // stealing the editor's first responder or invoking the sidebar shortcut.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.start != nil, event.window === self.window, event.keyCode == 53 else { return event }
            self.cancel(); return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
    }
    private func preview(at point: CGPoint) -> CGFloat {
        guard let start else { return CGFloat(selection) }
        return min(3, max(0, startPresentation + (point.x - start.x) / Self.stride))
    }
    override func mouseDragged(with event: NSEvent) {
        guard start != nil, enabled, owner == startOwner, selection == startSelection else { cancel(); return }
        let next = preview(at: convert(event.locationInWindow, from: nil))
        guard next != lastPreview else { return }
        #if DEBUG
        WorkbenchCategoryUpdateProbe.inputTrace()
        #endif
        lastPreview = next; onPreview(next)
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = Int(preview(at: point).rounded())
        let accepts = enabled && owner == startOwner && selection == startSelection
            && bounds.insetBy(dx: -12, dy: -12).contains(point) && window?.isKeyWindow == true
        cancel()
        if accepts && target != selection { onCommit(target) }
    }
    func cancel(notify: Bool = true) {
        #if DEBUG
        WorkbenchCategoryUpdateProbe.endTrace()
        #endif
        let wasActive = start != nil
        start = nil; startOwner = nil; lastPreview = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        if notify && wasActive { onPreview(nil) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancel() }
        super.viewWillMove(toWindow: newWindow)
    }
}
