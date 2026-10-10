import AppKit
import SwiftUI

/// A wire has a narrow native event surface, not its rectangular layout bounds.
/// Core Graphics supplies the same precise path after excluding port/control holes.
struct WorkflowConnectionReceiver: NSViewRepresentable {
    let path: CGPath
    let midpoint: CGPoint
    let canDisconnect: Bool
    let cutAvailable: Bool
    let label: String
    let disconnectTitle: String
    let identifier: String
    let onSelect: () -> Void
    let onDisconnect: () -> Void

    func makeNSView(context: Context) -> WorkflowConnectionHitView { WorkflowConnectionHitView() }
    func updateNSView(_ view: WorkflowConnectionHitView, context: Context) {
        view.wirePath = path; view.midpoint = midpoint
        view.canDisconnect = canDisconnect; view.cutAvailable = cutAvailable
        view.onSelect = onSelect; view.onDisconnect = onDisconnect
        view.disconnectTitle = disconnectTitle
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label); view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityCustomActions(canDisconnect ? [NSAccessibilityCustomAction(name: disconnectTitle) {
            onDisconnect(); return true
        }] : [])
    }
}

final class WorkflowConnectionHitView: NSView {
    var wirePath = CGMutablePath() as CGPath
    var midpoint = CGPoint.zero
    var canDisconnect = false
    var cutAvailable = true
    var disconnectTitle = "断开连接"
    var onSelect: () -> Void = {}
    var onDisconnect: () -> Void = {}
    private(set) var hovering = false
    private(set) var hoveringCut = false
    private var pressedAction: (cut: Bool, action: () -> Void)?
    private var menuAction: (() -> Void)?
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    private var cutRect: CGRect { CGRect(x: midpoint.x - 11, y: midpoint.y - 11, width: 22, height: 22) }
    private func containsCut(_ point: CGPoint) -> Bool {
        hovering && canDisconnect && cutAvailable && hypot(point.x - midpoint.x, point.y - midpoint.y) <= 11
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        return containsCut(local) || wirePath.contains(local) ? self : nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(next); tracking = next
    }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { clearHover() }
    override func viewDidHide() { super.viewDidHide(); clearHover(); cancelPress() }
    func updateHover(at point: CGPoint) {
        let cut = containsCut(point)
        let next = cut || wirePath.contains(point)
        guard next != hovering || cut != hoveringCut else { return }
        hovering = next; hoveringCut = cut
        setNeedsDisplay(cutRect.insetBy(dx: -2, dy: -2))
    }
    private func clearHover() {
        hovering = false; hoveringCut = false
        setNeedsDisplay(cutRect.insetBy(dx: -2, dy: -2))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering && canDisconnect && cutAvailable else { return }
        let circle = NSBezierPath(ovalIn: cutRect)
        (pressedAction?.cut == true ? NSColor.selectedControlColor : NSColor.windowBackgroundColor).setFill()
        circle.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke(); circle.lineWidth = 1; circle.stroke()
        if hoveringCut, let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil) {
            let configured = image.withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? image
            configured.draw(in: cutRect.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: midpoint.x - 2.5, y: midpoint.y - 2.5, width: 5, height: 5)).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard window?.isKeyWindow == true else { return }
        cancelPress()
        let cut = containsCut(convert(event.locationInWindow, from: nil))
        pressedAction = (cut, cut ? onDisconnect : onSelect)
        setNeedsDisplay(cutRect.insetBy(dx: -2, dy: -2))
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.pressedAction != nil, event.window === self.window, event.keyCode == 53 else { return event }
            self.cancelPress(); return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPress(); self?.clearHover() }
            }
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseUp(with event: NSEvent) {
        guard let pressed = pressedAction else { return }
        cancelPress() // Consume once before invoking a captured, scope-checked action.
        guard window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        let point = convert(event.locationInWindow, from: nil)
        if pressed.cut { if containsCut(point) { pressed.action() } }
        else if wirePath.contains(point) { pressed.action() }
    }
    private func cancelPress() {
        pressedAction = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        setNeedsDisplay(cutRect.insetBy(dx: -2, dy: -2))
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelPress(); clearHover() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu(); menu.autoenablesItems = false
        let item = NSMenuItem(title: disconnectTitle, action: #selector(disconnectWire), keyEquivalent: "")
        item.target = self; item.isEnabled = canDisconnect
        item.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
        menu.addItem(item)
        menuAction = onDisconnect // Preserve the scope at menu opening, even across view updates.
        defer { menuAction = nil }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func disconnectWire() { if canDisconnect { menuAction?() } }
    override func accessibilityPerformPress() -> Bool { onSelect(); return true }
}
