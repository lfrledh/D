import AppKit

/// Test-process events, not OS input injection or proof of foreground usability.
/// AX press is unsupported by some hosted SwiftUI virtual controls. Deliver the
/// same down/up pair at their real geometry; callers must assert the action result.
@MainActor enum HostingControlClick {
    static func diagnoseTree(in root: NSView) {
        var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), rows = 0
        var completeProtocol = 0, roleProtocol = 0, identifiers = 0
        func objectValue(_ object: NSObject, _ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        while let object = pending.popLast(), visited.count < 2_000 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let complete = object is any NSAccessibilityProtocol
            let role = object is any NSAccessibilityElementProtocol
            if complete { completeProtocol += 1 }
            if role { roleProtocol += 1 }
            let identifier = objectValue(object, "accessibilityIdentifier") as? String
            if identifier != nil { identifiers += 1 }
            if rows < 64 {
                print("D_HOSTING_TREE", String(describing: type(of: object)),
                    "complete", complete, "role", role, "id", identifier ?? "none",
                    "label", objectValue(object, "accessibilityLabel") as? String ?? "none")
                rows += 1
            }
            pending.append(contentsOf: (objectValue(object, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject })
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        print("D_HOSTING_TREE_SUMMARY", visited.count, "remaining", pending.count,
            "complete", completeProtocol, "role", roleProtocol, "identifiers", identifiers)
    }

    static func contains(_ identifier: String, in root: NSView) -> Bool {
        var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>()
        while let object = pending.popLast(), visited.count < 2_000 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let element = object as? any NSAccessibilityProtocol {
                if element.accessibilityIdentifier() == identifier { return true }
                pending.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap { $0 as? NSObject })
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return false
    }

    static func send(to element: any NSAccessibilityProtocol, in root: NSView) -> Bool {
        func reject(_ stage: String) -> Bool {
            let frame = element.accessibilityFrame()
            let point = root.window.map { root.convert($0.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY)), from: nil) }
            print("D_HOSTING_CONTROL", element.accessibilityIdentifier() ?? "no-id", stage,
                "frame", frame, "rootPoint", String(describing: point), "bounds", root.bounds,
                "window", root.window?.windowNumber ?? -1, "visible", root.window?.isVisible ?? false)
            return false
        }
        guard let window = root.window else { return reject("no-window") }
        let frame = element.accessibilityFrame()
        guard frame.width > 0, frame.height > 0,
              frame.minX.isFinite, frame.minY.isFinite else { return reject("invalid-frame") }
        let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
        guard root.bounds.contains(root.convert(point, from: nil)) else { return reject("outside-root") }
        // AppKit's queued mouse event number round-trips as a signed 16-bit value.
        // Keep the exact identity check; generate an identity representable by that queue.
        let identity = Int.random(in: 1...Int(Int16.max))
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: identity, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return reject("event-nil") }
        // Queue the complete pair before dispatch: a native control may consume
        // mouse-up synchronously in its mouse-down tracking loop.
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
        guard let queued = NSApp.nextEvent(matching: .leftMouseDown,
            until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true) else { return reject("dequeue-empty") }
        guard queued.windowNumber == window.windowNumber, queued.eventNumber == identity else {
            // Preserve the identity guard; record the actual factory/queue boundary once it fails.
            for (name, value) in [("down", down), ("up", up), ("queued", queued)] {
                print("D_HOSTING_EVENT", name, "requested", identity, "targetWindow", window.windowNumber,
                      "type", value.type.rawValue, "window", value.windowNumber, "number", value.eventNumber,
                      "timestamp", value.timestamp, "location", value.locationInWindow, "sameDown", value === down)
            }
            NSApp.postEvent(queued, atStart: true)
            return reject("identity-mismatch")
        }
        NSApp.sendEvent(queued)
        if let remaining = NSApp.nextEvent(matching: .leftMouseUp,
            until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true) {
            guard remaining.windowNumber == window.windowNumber, remaining.eventNumber == identity else {
                NSApp.postEvent(remaining, atStart: true)
                return true // Own mouse-up was consumed by synchronous control tracking.
            }
            NSApp.sendEvent(remaining)
        }
        return true
    }
}
