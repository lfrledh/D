import AppKit
import SwiftUI

/// One geometry owns the track, painted lens, hit region and release candidates.
struct WorkbenchSegmentGeometry: Equatable {
    enum Direction: Hashable { case horizontal, vertical }
    var direction: Direction = .horizontal
    var count = 4
    var length: CGFloat = 264
    var thickness: CGFloat = 44
    var itemLength: CGFloat { count > 0 ? length / CGFloat(count) : 0 }
    var slotSize: CGSize { direction == .horizontal ? .init(width: length, height: thickness + 8) : .init(width: thickness + 8, height: length) }
    var track: CGRect { direction == .horizontal ? .init(x: 0, y: 4, width: length, height: thickness) : .init(x: 4, y: 0, width: thickness, height: length) }
    func coordinate(_ point: CGPoint) -> CGFloat { direction == .horizontal ? point.x : point.y }
    func lens(_ position: CGFloat, engagement: CGFloat) -> CGRect {
        let cross = thickness + 4 * min(1, max(0, engagement))
        let along = position * itemLength
        return direction == .horizontal ? .init(x: along, y: (thickness + 8 - cross) / 2, width: itemLength, height: cross)
            : .init(x: (thickness + 8 - cross) / 2, y: along, width: cross, height: itemLength)
    }
    func target(_ position: CGFloat, available: Set<Int>, original: Int) -> Int? {
        let candidates = available.filter { $0 >= 0 && $0 < count }
        return candidates.min { a, b in
            let da = abs(CGFloat(a) - position), db = abs(CGFloat(b) - position)
            if abs(da - db) < 0.000001 {
                if a == original { return true }; if b == original { return false }; return a < b
            }
            return da < db
        }
    }
}

/// Only the existing lens receives a drag. The four real buttons underneath
/// retain ordinary clicks, keyboard focus and accessibility activation.
struct WorkbenchCategoryDragReceiver: NSViewRepresentable {
    let selection: Int
    let owner: AnyHashable
    let enabled: Bool
    let onPreview: (CGFloat?) -> Void
    let onCommit: (Int) -> Void
    var geometry = WorkbenchSegmentGeometry()
    var options: [AnyHashable] = (0..<4).map { AnyHashable($0) }
    var available: Set<Int> = [0, 1, 2, 3]
    var presentation = CGRect(x: 0, y: 4, width: 66, height: 44)
    var presentationSelection: CGFloat = 0
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> WorkbenchCategoryDragView {
        let view = WorkbenchCategoryDragView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: WorkbenchCategoryDragView, context: Context) {
        let accepts = enabled && environmentEnabled
        if view.owner != owner || view.selection != selection || view.options != options || view.available != available || view.geometry != geometry || !accepts {
            // SwiftUI clears its preview for owner/availability changes. Never
            // publish state from inside a representable update.
            view.cancel(notify: false)
        }
        view.geometry = geometry; view.options = options; view.available = available
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
    static let itemWidth: CGFloat = 66
    static let stride: CGFloat = 66
    var selection = 0
    var owner: AnyHashable?
    var enabled = true
    var onPreview: (CGFloat?) -> Void = { _ in }
    var onCommit: (Int) -> Void = { _ in }
    var geometry = WorkbenchSegmentGeometry() { didSet { if oldValue != geometry { cancel() } } }
    var options: [AnyHashable] = (0..<4).map { AnyHashable($0) } { didSet { if oldValue != options { cancel() } } }
    var available: Set<Int> = [0, 1, 2, 3] { didSet { if oldValue != available { cancel() } } }
    var presentation = CGRect(x: 0, y: 4, width: 66, height: 44)
    var presentationSelection: CGFloat = 0
    private var lastPreview: CGFloat?
    private var startPresentation: CGFloat = 0
    private var start: CGPoint?
    private var startSelection = 0
    private var startOwner: AnyHashable?
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, available.contains(selection), geometry.count > 0, !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        return NSBezierPath(roundedRect: presentation, xRadius: min(presentation.width, presentation.height) / 2,
            yRadius: min(presentation.width, presentation.height) / 2).contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled, available.contains(selection), geometry.itemLength > 0, !isHiddenOrHasHiddenAncestor, event.buttonNumber == 0, let window, window.isKeyWindow else { return }
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
        return min(CGFloat(max(0, geometry.count - 1)), max(0, startPresentation + (geometry.coordinate(point) - geometry.coordinate(start)) / geometry.itemLength))
    }
    override func mouseDragged(with event: NSEvent) {
        guard start != nil, enabled, !isHiddenOrHasHiddenAncestor, owner == startOwner, selection == startSelection else { cancel(); return }
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
        let target = geometry.target(preview(at: point), available: available, original: startSelection)
        let accepts = enabled && !isHiddenOrHasHiddenAncestor && owner == startOwner && selection == startSelection
            && geometry.track.insetBy(dx: -12, dy: -12).contains(point) && window?.isKeyWindow == true
        cancel()
        if accepts, let target, target != selection {
            #if DEBUG
            WorkbenchCategoryUpdateProbe.beginCommit()
            #endif
            onCommit(target)
            #if DEBUG
            WorkbenchCategoryUpdateProbe.phase("owner-returned")
            #endif
        }
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
    override func viewDidHide() { cancel(); super.viewDidHide() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancel() }
        super.viewWillMove(toWindow: newWindow)
    }
}
