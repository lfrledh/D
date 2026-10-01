import AppKit

/// Test-process events, not OS input injection or proof of foreground usability.
/// AX press is unsupported by some hosted SwiftUI virtual controls. Deliver the
/// same down/up pair at their real geometry; callers must assert the action result.
@MainActor enum HostingControlClick {
    static func send(to element: any NSAccessibilityProtocol, in root: NSView) -> Bool {
        guard let window = root.window else { return false }
        let frame = element.accessibilityFrame()
        guard frame.width > 0, frame.height > 0,
              frame.minX.isFinite, frame.minY.isFinite else { return false }
        let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
        guard root.bounds.contains(root.convert(point, from: nil)) else { return false }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        // Queue the complete pair before dispatch: a native control may consume
        // mouse-up synchronously in its mouse-down tracking loop.
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
        guard let queued = NSApp.nextEvent(matching: .leftMouseDown,
            until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true),
              queued.windowNumber == window.windowNumber else { return false }
        NSApp.sendEvent(queued)
        if let remaining = NSApp.nextEvent(matching: .leftMouseUp,
            until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true) {
            guard remaining.windowNumber == window.windowNumber else { return false }
            NSApp.sendEvent(remaining)
        }
        return true
    }
}
