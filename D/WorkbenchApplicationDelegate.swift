import AppKit
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

@MainActor
final class WorkbenchApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private weak var workbenchWindow: NSWindow?
    private weak var previousWindowDelegate: (any NSWindowDelegate)?
    private var closeGate: CloseRequestGate?
    private var windowClosePending = false
    private var windowCloseApproved = false
    private var terminationPending = false

    func connect(window: NSWindow, model: WorkbenchModel) {
        guard workbenchWindow !== window else { return }
        workbenchWindow = window
        previousWindowDelegate = window.delegate
        closeGate = CloseRequestGate { await model.requestClose() }
        window.delegate = self
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
            let approved = await closeGate.prepareToClose()
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
    func windowDidResize(_ notification: Notification) { previousWindowDelegate?.windowDidResize?(notification) }
    func windowDidExpose(_ notification: Notification) { previousWindowDelegate?.windowDidExpose?(notification) }
    func windowWillMove(_ notification: Notification) { previousWindowDelegate?.windowWillMove?(notification) }
    func windowDidMove(_ notification: Notification) { previousWindowDelegate?.windowDidMove?(notification) }
    func windowDidBecomeKey(_ notification: Notification) { previousWindowDelegate?.windowDidBecomeKey?(notification) }
    func windowDidResignKey(_ notification: Notification) { previousWindowDelegate?.windowDidResignKey?(notification) }
    func windowDidBecomeMain(_ notification: Notification) { previousWindowDelegate?.windowDidBecomeMain?(notification) }
    func windowDidResignMain(_ notification: Notification) { previousWindowDelegate?.windowDidResignMain?(notification) }
    func windowWillClose(_ notification: Notification) { previousWindowDelegate?.windowWillClose?(notification) }
    func windowWillMiniaturize(_ notification: Notification) { previousWindowDelegate?.windowWillMiniaturize?(notification) }
    func windowDidMiniaturize(_ notification: Notification) { previousWindowDelegate?.windowDidMiniaturize?(notification) }
    func windowDidDeminiaturize(_ notification: Notification) { previousWindowDelegate?.windowDidDeminiaturize?(notification) }
    func windowDidUpdate(_ notification: Notification) { previousWindowDelegate?.windowDidUpdate?(notification) }
    func windowDidChangeScreen(_ notification: Notification) { previousWindowDelegate?.windowDidChangeScreen?(notification) }
    func windowDidChangeScreenProfile(_ notification: Notification) { previousWindowDelegate?.windowDidChangeScreenProfile?(notification) }
    func windowDidChangeBackingProperties(_ notification: Notification) { previousWindowDelegate?.windowDidChangeBackingProperties?(notification) }
    func windowWillBeginSheet(_ notification: Notification) { previousWindowDelegate?.windowWillBeginSheet?(notification) }
    func windowDidEndSheet(_ notification: Notification) { previousWindowDelegate?.windowDidEndSheet?(notification) }
    func windowWillStartLiveResize(_ notification: Notification) { previousWindowDelegate?.windowWillStartLiveResize?(notification) }
    func windowDidEndLiveResize(_ notification: Notification) { previousWindowDelegate?.windowDidEndLiveResize?(notification) }
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

    func makeNSView(context: Context) -> WindowConnectionView {
        WindowConnectionView { window in delegate.connect(window: window, model: model) }
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
