import AppKit
import Combine
import SwiftUI
import UI

/// Close and Quit can arrive together. Share one prompt and one drain/flush operation.
@MainActor
final class CloseRequestGate {
    private let action: @MainActor () async -> Bool
    private var pending: Task<Bool, Never>?

    init(action: @escaping @MainActor () async -> Bool) { self.action = action }

    func prepareToClose() async -> Bool {
        if let pending { return await pending.value }
        let task = Task { await action() }
        pending = task
        let result = await task.value
        pending = nil
        return result
    }
}

/// Window geometry changes can happen outside the input method's event handling.
/// Ask AppKit to query its native screen coordinates again after SwiftUI layout.
/// This never commits marked text or caches a responder across a focus change.
@MainActor
final class WorkbenchInputGeometry {
    private weak var window: NSWindow?
    private var scheduled = false
    private let invalidate: @MainActor (NSView) -> Void

    init(window: NSWindow, invalidate: @escaping @MainActor (NSView) -> Void = {
        $0.inputContext?.invalidateCharacterCoordinates()
    }) { self.window = window; self.invalidate = invalidate }

    func invalidateAfterLayout() {
        guard !scheduled else { return }
        scheduled = true
        // Window dragging/resizing runs a nested tracking loop. A main-queue
        // block alone can wait until mouse-up; schedule in those modes too.
        RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.scheduled = false }
                guard var target = self.window else { return }
                // Sheets own their input client. Resolve it at delivery time so
                // a dismissed sheet or an old responder is never retained.
                while let sheet = target.attachedSheet { target = sheet }
                target.contentView?.layoutSubtreeIfNeeded()
                guard let responder = target.firstResponder as? NSView,
                      responder.window === target else { return }
                #if DEBUG
                WorkbenchInputDiagnostic.record(window: target, reason: "before-invalidate")
                #endif
                self.invalidate(responder)
                #if DEBUG
                WorkbenchInputDiagnostic.record(window: target, reason: "after-invalidate")
                #endif
            }
        }
    }
}

#if DEBUG
/// Opt-in, task-local diagnostic. Never records text, changes focus or consumes an event.
/// Queries are labelled so they cannot be mistaken for the input method's own queries.
@MainActor
private enum WorkbenchInputDiagnostic {
    static let enabled = ProcessInfo.processInfo.environment["D_INPUT_GEOMETRY_DIAGNOSTICS"] == "1"
        && UUID(uuidString: ProcessInfo.processInfo.environment["D_UI_TEST_SESSION"] ?? "") != nil
    static var monitor: Any?
    static weak var observedWindow: NSWindow?
    static var lastCursorSignature: String?

    static func install(window: NSWindow) {
        guard enabled || WorkbenchNaturalInputTrace.enabled else { return }
        observedWindow = window
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited, .keyDown]) { event in
            MainActor.assumeIsolated {
                if let window = observedWindow, event.window === window {
                    let cursor = String(describing: NSCursor.current)
                    let signature = "\(event.type.rawValue):\(cursor)"
                    if signature != lastCursorSignature || event.type == .keyDown {
                        lastCursorSignature = signature
                        record(window: window, reason: "event-\(event.type.rawValue)")
                    }
                }
            }
            return event
        }
        WorkbenchNaturalInputTrace.installNativeControlIfRequested()
    }

    static func record(window: NSWindow, reason: String) {
        if WorkbenchNaturalInputTrace.enabled {
            WorkbenchNaturalInputTrace.observe(window: window, reason: reason)
            return // Do not create diagnostic firstRect calls in the natural trace.
        }
        guard enabled else { return }
        func identity(_ object: AnyObject?) -> String {
            guard let object else { return "nil" }
            return "\(type(of: object)):\(ObjectIdentifier(object))"
        }
        let responder = window.firstResponder as? NSView
        let context = responder?.inputContext
        let active = NSTextInputContext.current
        var row: [String: Any] = ["event": "D_INPUT_GEOMETRY", "reason": reason,
            "time": ProcessInfo.processInfo.systemUptime, "window": identity(window),
            "delegate": identity(window.delegate), "frame": NSStringFromRect(window.frame),
            "responder": identity(responder), "context": identity(context),
            "activeContext": identity(active), "client": identity(context?.client),
            "activeClient": identity(active?.client), "cursor": String(describing: NSCursor.current),
            "pointer": NSStringFromPoint(NSEvent.mouseLocation)]
        if let view = responder {
            row["visibleScreenRect"] = NSStringFromRect(window.convertToScreen(view.convert(view.visibleRect, to: nil)))
        }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        if let content = window.contentView {
            let parentPoint = content.superview?.convert(point, from: nil) ?? point
            row["hitView"] = identity(content.hitTest(parentPoint))
        }
        if let client = context?.client {
            let marked = client.markedRange(), selected = client.selectedRange()
            row["markedRange"] = NSStringFromRange(marked); row["selectedRange"] = NSStringFromRange(selected)
            var actual = NSRange(location: NSNotFound, length: 0)
            let requested = marked.location == NSNotFound ? selected : marked
            row["queryOrigin"] = "diagnostic-explicit"
            row["firstRectScreen"] = NSStringFromRect(client.firstRect(forCharacterRange: requested, actualRange: &actual))
            row["actualRange"] = NSStringFromRange(actual)
        }
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            // stderr belongs to the launcher. No arbitrary file paths, content or credentials.
            try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
#endif

@MainActor
final class WorkbenchApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    @Published private(set) var hasPresentedSheet = false
    private weak var workbenchWindow: NSWindow?
    private weak var previousWindowDelegate: (any NSWindowDelegate)?
    private var closeGate: CloseRequestGate?
    private var windowClosePending = false
    private var windowCloseApproved = false
    private var terminationPending = false
    private var prepareLibraryForTermination: (@MainActor () async -> Bool)?
    private var prepareQuickForTermination: (@MainActor () async -> Bool)?
    private var cancelTermination: (@MainActor () -> Void)?
    private var inputGeometry: WorkbenchInputGeometry?

    // Installation belongs to the app. A single SwiftUI Window otherwise quits
    // when closed; only an explicit app Quit should shut the library down.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func connect(window: NSWindow, model: WorkbenchModel,
                 prepareLibraryForTermination: @escaping @MainActor () async -> Bool,
                 prepareQuickForTermination: @escaping @MainActor () async -> Bool = { true },
                 cancelTermination: @escaping @MainActor () -> Void = {},
                 invalidateInputContext: @escaping @MainActor (NSView) -> Void = {
                     $0.inputContext?.invalidateCharacterCoordinates()
                 }) {
        if workbenchWindow === window {
            if inputGeometry == nil {
                inputGeometry = WorkbenchInputGeometry(window: window, invalidate: invalidateInputContext)
            }
            return
        }
        workbenchWindow = window
        hasPresentedSheet = window.attachedSheet != nil
        inputGeometry = WorkbenchInputGeometry(window: window, invalidate: invalidateInputContext)
        previousWindowDelegate = window.delegate
        closeGate = CloseRequestGate { await model.requestClose() }
        self.prepareLibraryForTermination = prepareLibraryForTermination
        self.prepareQuickForTermination = prepareQuickForTermination
        self.cancelTermination = cancelTermination
        window.delegate = self
        #if DEBUG
        WorkbenchInputDiagnostic.install(window: window)
        #endif
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === workbenchWindow, let closeGate else { return true }
        if windowCloseApproved { return true }
        guard !windowClosePending else { return false }
        windowClosePending = true
        Task { @MainActor [weak self, weak sender] in
            let approved = await closeGate.prepareToClose()
            guard let self else { return }
            self.windowClosePending = false
            guard approved, let sender else { return }
            self.windowCloseApproved = true
            sender.performClose(nil)
            self.windowCloseApproved = false
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let closeGate else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor [weak self] in
            var approved = await self?.prepareQuickForTermination?() ?? true
            if approved { approved = await closeGate.prepareToClose() }
            if approved { approved = await self?.prepareLibraryForTermination?() ?? true }
            if !approved { self?.cancelTermination?() }
            self?.terminationPending = false
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }

    // Forward AppKit's main-actor callbacks explicitly. NSObject's generic forwarding hooks
    // are nonisolated and cannot safely read the window delegate's actor-owned state.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        previousWindowDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
    }
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        previousWindowDelegate?.windowWillUseStandardFrame?(window, defaultFrame: defaultFrame) ?? defaultFrame
    }
    func windowShouldZoom(_ window: NSWindow, toFrame: NSRect) -> Bool {
        previousWindowDelegate?.windowShouldZoom?(window, toFrame: toFrame) ?? true
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        previousWindowDelegate?.windowWillReturnUndoManager?(window)
    }
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        previousWindowDelegate?.window?(window, willEncodeRestorableState: state)
    }
    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        previousWindowDelegate?.window?(window, didDecodeRestorableState: state)
    }
    private func inputGeometryChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === workbenchWindow else { return }
        inputGeometry?.invalidateAfterLayout()
    }
    func windowDidResize(_ notification: Notification) {
        previousWindowDelegate?.windowDidResize?(notification)
        inputGeometryChanged(notification)
    }
    func windowDidExpose(_ notification: Notification) { previousWindowDelegate?.windowDidExpose?(notification) }
    func windowWillMove(_ notification: Notification) { previousWindowDelegate?.windowWillMove?(notification) }
    func windowDidMove(_ notification: Notification) {
        previousWindowDelegate?.windowDidMove?(notification)
        inputGeometryChanged(notification)
    }
    func windowDidBecomeKey(_ notification: Notification) { previousWindowDelegate?.windowDidBecomeKey?(notification) }
    func windowDidResignKey(_ notification: Notification) { previousWindowDelegate?.windowDidResignKey?(notification) }
    func windowDidBecomeMain(_ notification: Notification) { previousWindowDelegate?.windowDidBecomeMain?(notification) }
    func windowDidResignMain(_ notification: Notification) { previousWindowDelegate?.windowDidResignMain?(notification) }
    func windowWillClose(_ notification: Notification) {
        previousWindowDelegate?.windowWillClose?(notification)
        if let window = notification.object as? NSWindow, window === workbenchWindow { inputGeometry = nil }
    }
    func windowWillMiniaturize(_ notification: Notification) { previousWindowDelegate?.windowWillMiniaturize?(notification) }
    func windowDidMiniaturize(_ notification: Notification) { previousWindowDelegate?.windowDidMiniaturize?(notification) }
    func windowDidDeminiaturize(_ notification: Notification) { previousWindowDelegate?.windowDidDeminiaturize?(notification) }
    func windowDidUpdate(_ notification: Notification) { previousWindowDelegate?.windowDidUpdate?(notification) }
    func windowDidChangeScreen(_ notification: Notification) {
        previousWindowDelegate?.windowDidChangeScreen?(notification)
        inputGeometryChanged(notification)
    }
    func windowDidChangeScreenProfile(_ notification: Notification) { previousWindowDelegate?.windowDidChangeScreenProfile?(notification) }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        previousWindowDelegate?.windowDidChangeBackingProperties?(notification)
        inputGeometryChanged(notification)
    }
    func windowWillBeginSheet(_ notification: Notification) {
        if notification.object as? NSWindow === workbenchWindow { hasPresentedSheet = true }
        previousWindowDelegate?.windowWillBeginSheet?(notification)
    }
    func windowDidEndSheet(_ notification: Notification) {
        previousWindowDelegate?.windowDidEndSheet?(notification)
        if let window = notification.object as? NSWindow, window === workbenchWindow {
            hasPresentedSheet = window.attachedSheet != nil
        }
    }
    func windowWillStartLiveResize(_ notification: Notification) { previousWindowDelegate?.windowWillStartLiveResize?(notification) }
    func windowDidEndLiveResize(_ notification: Notification) {
        previousWindowDelegate?.windowDidEndLiveResize?(notification)
        inputGeometryChanged(notification)
    }
    func windowWillEnterFullScreen(_ notification: Notification) { previousWindowDelegate?.windowWillEnterFullScreen?(notification) }
    func windowDidEnterFullScreen(_ notification: Notification) { previousWindowDelegate?.windowDidEnterFullScreen?(notification) }
    func windowWillExitFullScreen(_ notification: Notification) { previousWindowDelegate?.windowWillExitFullScreen?(notification) }
    func windowDidExitFullScreen(_ notification: Notification) { previousWindowDelegate?.windowDidExitFullScreen?(notification) }
    func windowDidChangeOcclusionState(_ notification: Notification) { previousWindowDelegate?.windowDidChangeOcclusionState?(notification) }
}

/// Observe this view's window; never select an unrelated global application window.
struct WorkbenchWindowConnection: NSViewRepresentable {
    let delegate: WorkbenchApplicationDelegate
    let model: WorkbenchModel
    let prepareLibraryForTermination: @MainActor () async -> Bool
    var prepareQuickForTermination: @MainActor () async -> Bool = { true }
    var cancelTermination: @MainActor () -> Void = {}

    func makeNSView(context: Context) -> WindowConnectionView {
        WindowConnectionView { window in
            delegate.connect(window: window, model: model,
                             prepareLibraryForTermination: prepareLibraryForTermination,
                             prepareQuickForTermination: prepareQuickForTermination, cancelTermination: cancelTermination)
        }
    }

    func updateNSView(_ nsView: WindowConnectionView, context: Context) {}
}

final class WindowConnectionView: NSView {
    private let connect: @MainActor (NSWindow) -> Void

    init(connect: @escaping @MainActor (NSWindow) -> Void) {
        self.connect = connect
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { connect(window) }
    }
}
