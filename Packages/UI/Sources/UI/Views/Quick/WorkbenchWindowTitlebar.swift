import AppKit
import SwiftUI

/// The existing application delegate forwards only failed full-screen transitions.
/// Success and geometry are window-local AppKit notifications, not a global owner.
@MainActor public enum WorkbenchWindowChrome {
    static let transitionFailed = Notification.Name("D.WorkbenchWindowChrome.transitionFailed")
    public static func fullScreenTransitionFailed(_ window: NSWindow) {
        NotificationCenter.default.post(name: transitionFailed, object: window)
    }
}

/// Owns public chrome properties and the placement of the *real* standard buttons.
/// No full-width titlebar painter, content/delegate replacement or fake controls.
@MainActor final class WorkbenchWindowTitlebar {
    weak var window: NSWindow?
    private let fullSize: Bool
    private let transparent: Bool
    private let visibility: NSWindow.TitleVisibility
    private let separator: NSTitlebarSeparatorStyle
    private let opaque: Bool
    private let background: NSColor
    private var appliedBackground: NSColor?
    private var geometry: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var restored = false
    private var updating = false
    private var transitioning = false
    private(set) var isFullScreen = false
    weak var controls: WorkbenchWindowControlHost?
    private let invalidate: @MainActor () -> Void
    private struct Placement {
        let type: NSWindow.ButtonType
        let button: NSButton
        let parent: NSView
        let frame: CGRect
        let mask: NSView.AutoresizingMask
        let next: NSView?
        let index: Int
        let inWindow: CGRect
    }
    private var placements: [Placement] = []
    private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    init?(window: NSWindow, invalidate: @escaping @MainActor () -> Void) {
        guard window.styleMask.contains(.titled), window.sheetParent == nil else { return nil }
        self.window = window; self.invalidate = invalidate
        fullSize = window.styleMask.contains(.fullSizeContentView)
        transparent = window.titlebarAppearsTransparent; visibility = window.titleVisibility
        separator = window.titlebarSeparatorStyle; opaque = window.isOpaque; background = window.backgroundColor
        isFullScreen = window.styleMask.contains(.fullScreen)
        applyChrome()
        geometry = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshGeometry() }
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification, NSWindow.didUpdateNotification,
                     NSWindow.didChangeBackingPropertiesNotification, WorkbenchWindowChrome.transitionFailed] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.transition(name) }
            })
        }
    }
    private func applyChrome() {
        guard let window else { return }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        if !window.isOpaque { window.isOpaque = true }
    }
    func update(palette: WorkbenchPalette, canvas: WorkbenchBackgroundNSView) {
        guard let window, !restored else { return }
        let color = NSColor(palette.canvasColor)
        if window.backgroundColor != color { window.backgroundColor = color }
        appliedBackground = color
        if let host = canvas.owner?.windowControls { attach(host) }
        refreshGeometry()
    }
    func attach(_ host: WorkbenchWindowControlHost) {
        guard !restored, host.window === window else { return }
        if controls !== host {
            restoreButtons(); controls?.cancelReport(); controls?.chrome = nil
            controls = host; host.chrome = self
        }
        refreshGeometry()
    }
    private func transition(_ name: Notification.Name) {
        guard let window else { return }
        if name == NSWindow.didUpdateNotification {
            // AppKit may reinstall its standard controls after a scene update.
            // Reconcile only changed ownership/frames; ordinary updates do no
            // layout, state publication, backdrop invalidation or window writes.
            guard !transitioning, !isFullScreen, let host = controls else { return }
            let ready = Self.types.allSatisfy { type in
                guard let button = window.standardWindowButton(type) else { return false }
                return button.window === window && button.superview != nil
            }
            guard ready && (placements.isEmpty || placements.contains(where: {
                window.standardWindowButton($0.type) !== $0.button ||
                $0.button.superview !== host || $0.button.frame != buttonFrame($0, in: host)
            })) else { return }
            refreshGeometry(); return
        }
        if name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification {
            transitioning = true; isFullScreen = true; restoreButtons()
        } else if name == NSWindow.didEnterFullScreenNotification || name == NSWindow.didExitFullScreenNotification || name == WorkbenchWindowChrome.transitionFailed {
            transitioning = false; isFullScreen = window.styleMask.contains(.fullScreen)
        }
        refreshGeometry()
    }
    func refreshGeometry() {
        guard !restored, !updating, let window else { return }
        updating = true; defer { updating = false }
        applyChrome()
        if !transitioning { isFullScreen = window.styleMask.contains(.fullScreen) }
        guard let host = controls, host.window === window else { return }
        if isFullScreen || transitioning {
            restoreButtons(); host.report(size: host.measuredSize, fullScreen: true); return
        }
        if !placements.isEmpty && placements.contains(where: { window.standardWindowButton($0.type) !== $0.button }) { restoreButtons() }
        if placements.isEmpty {
            let buttons = Self.types.compactMap { type -> Placement? in
                guard let button = window.standardWindowButton(type), button.window === window,
                      let parent = button.superview, parent !== host, let index = parent.subviews.firstIndex(of: button) else { return nil }
                let next = parent.subviews.dropFirst(index + 1).first
                return Placement(type: type, button: button, parent: parent, frame: button.frame,
                    mask: button.autoresizingMask, next: next, index: index, inWindow: button.convert(button.bounds, to: nil))
            }
            guard buttons.count == Self.types.count else { return }
            placements = buttons
            for item in placements { host.addSubview(item.button); item.button.autoresizingMask = [] }
        }
        let union = placements.reduce(CGRect.null) { $0.union($1.inWindow) }
        guard !union.isNull, union.width.isFinite, union.width > 0 else { return }
        host.report(size: CGSize(width: union.width + 16, height: max(32, union.height + 16)), fullScreen: false)
        for item in placements {
            if item.button.superview !== host { host.addSubview(item.button); item.button.autoresizingMask = [] }
            let frame = buttonFrame(item, in: host)
            if item.button.frame != frame { item.button.frame = frame }
        }
    }
    private func buttonFrame(_ item: Placement, in host: NSView) -> CGRect {
        let union = placements.reduce(CGRect.null) { $0.union($1.inWindow) }
        return CGRect(x: 8 + item.inWindow.minX - union.minX,
            y: (host.bounds.height - union.height) / 2 + item.inWindow.minY - union.minY,
            width: item.frame.width, height: item.frame.height)
    }
    private func restoreButtons() {
        for item in placements.sorted(by: { $0.index > $1.index }) where item.button.superview === controls {
            // If AppKit replaced a native button/parent, do not install stale objects.
            guard window?.standardWindowButton(item.type) === item.button else { item.button.removeFromSuperview(); continue }
            // AppKit can temporarily detach its titlebar parent during a transition.
            // Put the current native button back in that original parent, even while
            // detached; never discard it as though AppKit had replaced the button.
            guard item.parent.window == nil || item.parent.window === window else { continue }
            if let next = item.next, next.superview === item.parent {
                item.parent.addSubview(item.button, positioned: .below, relativeTo: next)
            } else { item.parent.addSubview(item.button) }
            item.button.autoresizingMask = item.mask; item.button.frame = item.frame
        }
        placements = []
    }
    func drag(with event: NSEvent) {
        guard let window, !isFullScreen, !transitioning, event.window === window, window.attachedSheet == nil, !WorkbenchChildPanels.isPresented(on: window) else { return }
        if event.clickCount == 2 {
            // The native parent remains in the window. Delegate this event rather
            // than hard-coding Zoom or changing the user's double-click setting.
            placements.first?.parent.mouseDown(with: event)
        } else { window.performDrag(with: event) }
    }
    func detach(_ host: WorkbenchWindowControlHost) {
        guard controls === host else { return }
        restoreButtons(); host.cancelReport(); host.chrome = nil; controls = nil
    }
    func restore() {
        guard !restored else { return }; restored = true
        geometry?.invalidate(); geometry = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        restoreButtons(); controls?.cancelReport(); controls?.chrome = nil; controls = nil
        guard let window else { return }
        if window.backgroundColor == appliedBackground { window.backgroundColor = background }
        if window.isOpaque { window.isOpaque = opaque }
        if window.titlebarSeparatorStyle == .none { window.titlebarSeparatorStyle = separator }
        if window.titleVisibility == .hidden { window.titleVisibility = visibility }
        if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = transparent }
        if !fullSize { window.styleMask.remove(.fullSizeContentView) }
        invalidate()
    }
    isolated deinit { restore() }
}

@MainActor final class WorkbenchWindowControlHost: NSView {
    weak var chrome: WorkbenchWindowTitlebar?
    weak var owner: WorkbenchBackgroundOwner?
    var changed: ((CGSize, Bool) -> Void)?
    private(set) var measuredSize = CGSize(width: 80, height: 32)
    private var reported: (CGSize, Bool)?
    private var reportID = UUID()
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() { super.layout(); chrome?.refreshGeometry() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { chrome?.detach(self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bind() }
    func bind() { guard window != nil else { return }; owner?.windowControls = self; owner?.root?.synchronizeTitlebar() }
    func report(size: CGSize, fullScreen: Bool) {
        guard reported?.0 != size || reported?.1 != fullScreen else { return }
        measuredSize = size; reported = (size, fullScreen)
        let ticket = UUID(); reportID = ticket
        let sourceChrome = chrome, sourceWindow = window
        DispatchQueue.main.async { [weak self, weak sourceChrome, weak sourceWindow] in
            guard let self, self.reportID == ticket, self.chrome === sourceChrome, self.window === sourceWindow,
                  sourceChrome != nil, sourceWindow != nil else { return }
            self.changed?(size, fullScreen)
        }
    }
    func cancelReport() { reportID = UUID(); reported = nil }
    override func mouseDown(with event: NSEvent) { chrome?.drag(with: event) }
}

struct WorkbenchNativeWindowControls: View {
    @Binding var fullScreen: Bool
    @Binding var size: CGSize
    @Environment(\.workbenchBackground) private var owner
    var body: some View {
        Host(owner: owner) { measured, full in
            if size != measured { size = measured }
            if fullScreen != full { fullScreen = full }
        }.frame(width: fullScreen ? 0 : size.width, height: size.height)
            .workbenchPanel(in: Capsule())
            .opacity(fullScreen ? 0 : 1).allowsHitTesting(!fullScreen)
            .accessibilityIdentifier("workbench-window-controls")
    }
    private struct Host: NSViewRepresentable {
        let owner: WorkbenchBackgroundOwner?
        let changed: (CGSize, Bool) -> Void
        func makeNSView(context: Context) -> WorkbenchWindowControlHost { let view = WorkbenchWindowControlHost(); view.owner = owner; view.changed = changed; return view }
        func updateNSView(_ view: WorkbenchWindowControlHost, context: Context) { view.owner = owner; view.changed = changed; view.bind() }
        static func dismantleNSView(_ view: WorkbenchWindowControlHost, coordinator: ()) { view.chrome?.detach(view); if view.owner?.windowControls === view { view.owner?.windowControls = nil } }
    }
}

// Only unusually large native controls add local sidebar clearance. The normal
// 32pt shell ends at y=40; Quick's existing y=52 sidebar leaves a 12pt gap.
private struct WorkbenchWindowControlSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 80, height: 32)
}
extension EnvironmentValues {
    var workbenchWindowControlSize: CGSize {
        get { self[WorkbenchWindowControlSizeKey.self] }
        set { self[WorkbenchWindowControlSizeKey.self] = newValue }
    }
}

/// Only this explicit 72×32 (or wider) top-row space starts a window drag.
struct WorkbenchWindowDragRegion: NSViewRepresentable {
    @Environment(\.workbenchBackground) private var owner
    func makeNSView(context: Context) -> View { let view = View(); view.owner = owner; return view }
    func updateNSView(_ view: View, context: Context) { view.owner = owner }
    final class View: NSView {
        weak var owner: WorkbenchBackgroundOwner?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { owner?.root?.titlebar?.drag(with: event) }
    }
}
