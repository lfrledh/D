#if DEBUG
import AppKit
import ObjectiveC

/// Bounded, opt-in observation of calls made by AppKit/IME. It never requests a
/// character rectangle, sets a cursor, commits composition, or reads text.
@MainActor
enum WorkbenchNaturalInputTrace {
    static let enabled = ProcessInfo.processInfo.environment["D_INPUT_NATURAL_TRACE"] == "1"
        && UUID(uuidString: ProcessInfo.processInfo.environment["D_UI_TEST_SESSION"] ?? "") != nil
    private static var installed = Set<String>()
    private static var pending: [[String: Any]] = []
    private static var scheduled = false
    private static var recording = false
    private static var count = 0
    private static var truncated = false
    private static var control: NSWindow?

    static func observe(window: NSWindow, reason: String) {
        guard enabled else { return }
        let responder = window.firstResponder as? NSView
        let responderContext = responder?.inputContext
        let active = NSTextInputContext.current
        var row: [String: Any] = ["kind": "client", "reason": reason, "window": identity(window),
                "frame": NSStringFromRect(window.frame), "responder": identity(responder),
                "context": identity(responderContext), "activeContext": identity(active),
                "contextClient": identity(responderContext?.client), "activeClient": identity(active?.client),
                "inputSource": active?.selectedKeyboardInputSource ?? "unknown",
                "cursor": identity(NSCursor.current), "systemCursor": identity(NSCursor.currentSystem)]
        if let client = active?.client {
            row["hasMarkedText"] = client.hasMarkedText()
            row["markedRange"] = NSStringFromRange(client.markedRange())
            row["selectedRange"] = NSStringFromRange(client.selectedRange())
        }
        append(row)
        for client in [responderContext?.client, active?.client].compactMap({ $0 }) { hookClient(client) }
        var view = responder
        while let current = view { hookView(current); view = current.superview }
        if let frame = window.contentView?.superview { hookView(frame) }
        hookCursor()
    }

    static func installNativeControlIfRequested() {
        guard enabled, control == nil,
              ProcessInfo.processInfo.environment["D_INPUT_NATIVE_CONTROL"] == "1" else { return }
        let window = NSWindow(contentRect: NSRect(x: 180, y: 200, width: 640, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "D — Native NSTextView control (diagnostic)"
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false; text.allowsUndo = true
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; window.contentView?.addSubview(scroll)
        control = window
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
        observe(window: window, reason: "native-control")
    }

    private static func identity(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return "\(type(of: object)):\(ObjectIdentifier(object))"
    }

    private static func append(_ values: [String: Any], stack: Bool = false) {
        guard enabled, !recording, !truncated else { return }
        recording = true; defer { recording = false }
        var row = values
        if count >= 4000 {
            truncated = true
            row = ["kind": "trace-truncated", "coverage": "incomplete", "limit": 4000]
        }
        row["event"] = "D_NATURAL_INPUT_TRACE"
        row["time"] = ProcessInfo.processInfo.systemUptime
        if stack && !truncated { row["returnAddresses"] = Thread.callStackReturnAddresses.prefix(16).map { String(format: "%llx", $0.uint64Value) } }
        count += 1; pending.append(row)
        guard !scheduled else { return }
        scheduled = true
        RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
            MainActor.assumeIsolated {
                let rows = pending; pending.removeAll(keepingCapacity: true); scheduled = false
                for row in rows {
                    if var bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                        bytes.append(10); try? FileHandle.standardError.write(contentsOf: bytes)
                    }
                }
            }
        }
    }

    private static func replace(_ cls: AnyClass, _ selector: Selector, block: Any) {
        guard let method = class_getInstanceMethod(cls, selector),
              let types = method_getTypeEncoding(method) else { return }
        let replacement = imp_implementationWithBlock(block)
        // Add to this dynamic class first; do not accidentally replace an inherited
        // implementation on every unrelated superclass instance.
        if !class_addMethod(cls, selector, replacement, types) {
            class_replaceMethod(cls, selector, replacement, types)
        }
    }

    private static func hookClient(_ client: any NSTextInputClient) {
        guard let cls = object_getClass(client) else { return }
        let selector = #selector(NSTextInputClient.firstRect(forCharacterRange:actualRange:))
        let key = "\(ObjectIdentifier(cls)):firstRect"
        guard !installed.contains(key), let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, NSRange, UnsafeMutablePointer<NSRange>?) -> NSRect
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let block: @convention(block) (AnyObject, NSRange, UnsafeMutablePointer<NSRange>?) -> NSRect = { object, range, actual in
            // Exactly one original call, same pointer (including nil), same return.
            let rect = original(object, selector, range, actual)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    var row: [String: Any] = ["kind": "firstRect", "origin": "intercepted-no-tracer-query",
                        "client": identity(object), "requestedRange": NSStringFromRange(range),
                        "rectScreen": NSStringFromRect(rect), "actualPointerWasNil": actual == nil]
                    if let actual { row["actualRange"] = NSStringFromRange(actual.pointee) }
                    if let view = object as? NSView, let window = view.window {
                        row["windowFrame"] = NSStringFromRect(window.frame)
                        row["clientScreenRect"] = NSStringFromRect(window.convertToScreen(view.convert(view.bounds, to: nil)))
                    }
                    append(row, stack: true)
                }
            }
            return rect
        }
        replace(cls, selector, block: block); installed.insert(key)
    }

    private static func hookVoid(_ cls: AnyClass, _ selector: Selector, kind: String) {
        let key = "\(ObjectIdentifier(cls)):" + NSStringFromSelector(selector)
        guard !installed.contains(key), let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let block: @convention(block) (AnyObject) -> Void = { object in
            original(object, selector)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    append(["kind": kind, "method": NSStringFromSelector(selector), "receiver": identity(object),
                            "cursor": identity(NSCursor.current), "systemCursor": identity(NSCursor.currentSystem)], stack: true)
                }
            }
        }
        replace(cls, selector, block: block); installed.insert(key)
        append(["kind": "hook-installed", "target": key, "method": NSStringFromSelector(selector), "hookKind": kind])
    }

    private static func hookCursor() {
        for selector in [#selector(NSCursor.set), #selector(NSCursor.push)] { hookVoid(NSCursor.self, selector, kind: "cursor") }
        let pop = NSSelectorFromString("pop")
        hookVoid(NSCursor.self, pop, kind: "cursor")
        if let meta = object_getClass(NSCursor.self) { hookVoid(meta, pop, kind: "cursor-class") }
    }

    private static func hookView(_ view: NSView) {
        guard let cls = object_getClass(view) else { return }
        hookVoid(cls, #selector(NSView.resetCursorRects), kind: "view-cursor")
        let selector = #selector(NSView.addCursorRect(_:cursor:))
        let key = "\(ObjectIdentifier(cls)):addCursorRect"
        guard !installed.contains(key), let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, NSRect, NSCursor) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let block: @convention(block) (AnyObject, NSRect, NSCursor) -> Void = { object, rect, cursor in
            original(object, selector, rect, cursor)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    append(["kind": "addCursorRect", "receiver": identity(object),
                            "rectLocal": NSStringFromRect(rect), "cursor": identity(cursor)], stack: true)
                }
            }
        }
        replace(cls, selector, block: block); installed.insert(key)
    }
}
#endif
