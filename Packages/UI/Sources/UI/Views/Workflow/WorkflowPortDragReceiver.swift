import AppKit
import SwiftUI

/// A port connection is a local mouse gesture, not a file/Transferable drag.
/// One responder owns preview, target hit testing, cancellation and release.
struct WorkflowPortDragReceiver: NSViewRepresentable {
    let port: WorkflowPortIdentity
    let scope: WorkflowCanvasScope
    let enabled: Bool
    let onClick: () -> Void
    let onChange: (CGSize) -> Void
    let onEnd: (WorkflowPortIdentity?) -> Void
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> WorkflowPortDragView {
        let view = WorkflowPortDragView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: WorkflowPortDragView, context: Context) {
        let accepts = enabled && environmentEnabled
        if view.port != port || view.scope != scope || !accepts { view.cancel(notify: false) }
        view.port = port; view.scope = scope; view.enabled = accepts
        view.onClick = onClick; view.onChange = onChange; view.onEnd = onEnd
    }
    static func dismantleNSView(_ view: WorkflowPortDragView, coordinator: ()) {
        view.cancel(notify: false)
    }
}

final class WorkflowPortDragView: NSView {
    var port: WorkflowPortIdentity?
    var scope: WorkflowCanvasScope?
    var enabled = false
    var onClick: () -> Void = {}
    var onChange: (CGSize) -> Void = { _ in }
    var onEnd: (WorkflowPortIdentity?) -> Void = { _ in }
    private var start: CGPoint?
    private var dragging = false
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, !isHiddenOrHasHiddenAncestor else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled, event.buttonNumber == 0, let window, window.isKeyWindow else { return }
        cancel(notify: false)
        start = convert(event.locationInWindow, from: nil)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.start != nil, event.window === self.window, event.keyCode == 53 else { return event }
            self.cancel(); return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, let start, let port else { cancel(); return }
        let point = convert(event.locationInWindow, from: nil)
        guard dragging || hypot(point.x - start.x, point.y - start.y) >= 2 else { return }
        dragging = true
        // The measured dot is 9 pt wide at the corresponding row edge. Native
        // conversion includes the graph's zoom; do not divide this delta again.
        let dot = CGPoint(x: port.input ? 4.5 : bounds.width - 4.5, y: bounds.midY)
        onChange(CGSize(width: point.x - dot.x, height: point.y - dot.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        let wasDragging = dragging
        let destination = target(at: event.locationInWindow)
        let click = enabled && bounds.contains(convert(event.locationInWindow, from: nil))
            && window?.isKeyWindow == true
        cancel(notify: false) // Consume the gesture before any controller mutation.
        if wasDragging { onEnd(destination) } else if click { onClick() }
    }
    private func target(at windowPoint: CGPoint) -> WorkflowPortIdentity? {
        guard enabled, let window, window.isKeyWindow, let content = window.contentView else { return nil }
        let point = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let target = content.hitTest(point) as? WorkflowPortDragView,
              target.enabled, target.scope == scope, target.port != port else { return nil }
        return target.port
    }
    func cancel(notify: Bool = true) {
        let wasDragging = dragging
        start = nil; dragging = false
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        if notify && wasDragging { onEnd(nil) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancel() }
        super.viewWillMove(toWindow: newWindow)
    }
}
