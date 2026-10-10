import AppKit
import SwiftUI

enum WorkflowCanvasTool: String, CaseIterable {
    case pointer, hand
}

enum WorkflowCanvasViewportNavigationGate {
    static func allows(marqueeActive: Bool, interactionLocked: Bool,
                       nodeDragging: Bool, outputDragging: Bool) -> Bool {
        !marqueeActive && !interactionLocked && !nodeDragging && !outputDragging
    }
}

/// A view operation: the rectangle is measured in raw graph coordinates.
enum WorkflowCanvasFit {
    static func view(for bounds: CGRect, viewport: CGSize, margin: CGFloat = 28)
        -> (zoom: CGFloat, center: CGPoint)? {
        guard !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite,
              bounds.midX.isFinite, bounds.midY.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let availableWidth = max(1, viewport.width - margin * 2)
        let availableHeight = max(1, viewport.height - margin * 2)
        let scale = min(1, min(availableWidth / max(bounds.width, 1),
                               availableHeight / max(bounds.height, 1)))
        guard scale.isFinite, scale > 0 else { return nil }
        return (scale,
                CGPoint(x: bounds.midX, y: bounds.midY))
    }
}

/// The native clip and enclosing surface are sampled together. Fit is visibly disabled
/// while the surface still has an old/intermediate panel width; no delayed fit is queued.
struct WorkflowCanvasViewportMeasurement: Equatable {
    let clip: CGSize
    let surfaceWidth: CGFloat
    func permitsFit(targetWidth: CGFloat) -> Bool {
        clip.width.isFinite && clip.height.isFinite && clip.width > 0 && clip.height > 0
            && targetWidth.isFinite && targetWidth > 0 && surfaceWidth.isFinite
            && abs(surfaceWidth - targetWidth) <= 0.5
    }
}

struct WorkflowCanvasNavigationRequest: Equatable {
    let id = UUID()
    /// Nil requests the current graph's content center.
    let rawCenter: CGPoint?
}

struct WorkflowCanvasPanSession: Equatable {
    private(set) var startOffset: CGPoint?
    private(set) var suppressBlankTap = false

    mutating func startIfNeeded(at offset: CGPoint) -> CGPoint {
        if startOffset == nil { startOffset = offset }
        suppressBlankTap = true
        return startOffset!
    }

    mutating func reset() {
        startOffset = nil
        suppressBlankTap = false
    }
}

/// The initial hit owns the complete mouse sequence; crossing a card cannot
/// turn a blank pan into a node move, or a node move into a pan.
enum WorkflowCanvasPointerTarget: Equatable {
    case control, node(UUID), blank
}

struct WorkflowCanvasPointerUpdate {
    enum Phase { case began, changed, ended, cancelled, clicked }
    let phase: Phase
    let sessionID: UUID
    let target: WorkflowCanvasPointerTarget
    let startPoint: CGPoint
    let startOffset: CGPoint
    let viewport: CGSize
    let translation: CGSize
    let extendingSelection: Bool
}

/// Scroll observations are presentation bookkeeping, not reactive graph state.
/// Native panning publishes its final view once, including interrupted gestures.
final class WorkflowCanvasScrollTracking {
    var offset = CGPoint.zero
    var isPanning = false
}

/// The probe lives inside the graph's scroll content. The local monitor is active only while
/// that native view is mounted, and accepts events whose native hit path reaches its scroll view.
struct WorkflowCanvasViewportInput: NSViewRepresentable {
    typealias Coordinator = Void
    var tool: WorkflowCanvasTool = .pointer
    var interactionScope: WorkflowCanvasScope? = nil
    var pointerTarget: (CGPoint, CGPoint, CGSize) -> WorkflowCanvasPointerTarget = { _, _, _ in .control }
    var onPointer: (WorkflowCanvasPointerUpdate) -> Void = { _ in }
    var onPan: (Bool, CGPoint, CGSize) -> Void = { _, _, _ in }
    var navigationAllowed: () -> Bool
    var allowsEvent: (_ point: CGPoint, _ offset: CGPoint, _ viewport: CGSize) -> Bool
    var onViewportSize: (WorkflowCanvasViewportMeasurement) -> Void
    var onWheel: (_ deltaY: CGFloat, _ point: CGPoint, _ offset: CGPoint, _ viewport: CGSize) -> Void
    var onMiddleClick: (_ viewport: CGSize) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        if view.interactionScope != interactionScope { view.cancelPointer() }
        view.interactionScope = interactionScope
        view.setTool(tool)
        view.pointerTarget = pointerTarget
        view.onPointer = onPointer
        view.onPan = onPan
        view.navigationAllowed = navigationAllowed
        view.allowsEvent = allowsEvent
        view.onViewportSize = onViewportSize
        view.onWheel = onWheel
        view.onMiddleClick = onMiddleClick
        view.reportViewportSize()
    }

    final class ProbeView: NSView {
        var interactionScope: WorkflowCanvasScope?
        var pointerTarget: (CGPoint, CGPoint, CGSize) -> WorkflowCanvasPointerTarget = { _, _, _ in .control }
        var onPointer: (WorkflowCanvasPointerUpdate) -> Void = { _ in }
        var onPan: (Bool, CGPoint, CGSize) -> Void = { _, _, _ in }
        private struct PointerSession {
            let id = UUID()
            let target: WorkflowCanvasPointerTarget
            let tool: WorkflowCanvasTool
            let windowStart: CGPoint
            let point: CGPoint
            let offset: CGPoint
            let viewport: CGSize
            let shift: Bool
            let pointer: (WorkflowCanvasPointerUpdate) -> Void
            let pan: (Bool, CGPoint, CGSize) -> Void
            var lastOffset: CGPoint?
            var lastViewport: CGSize?
            var moved = false
            var translation = CGSize.zero
            func update(_ phase: WorkflowCanvasPointerUpdate.Phase) {
                pointer(WorkflowCanvasPointerUpdate(phase: phase, sessionID: id,
                    target: target, startPoint: point, startOffset: offset, viewport: viewport,
                    translation: translation, extendingSelection: shift))
            }
        }
        private var pointerSession: PointerSession?
        var navigationAllowed: () -> Bool = { false }
        var allowsEvent: (CGPoint, CGPoint, CGSize) -> Bool = { _, _, _ in false }
        var onViewportSize: (WorkflowCanvasViewportMeasurement) -> Void = { _ in }
        var onWheel: (CGFloat, CGPoint, CGPoint, CGSize) -> Void = { _, _, _, _ in }
        var onMiddleClick: (CGSize) -> Void = { _ in }
        private var monitor: Any?
        private var cursorTracking: NSTrackingArea?
        private var resignObserver: NSObjectProtocol?
        private(set) var tool: WorkflowCanvasTool = .pointer
        private(set) var handPressed = false
        private var ownsCursor = false

        func setTool(_ next: WorkflowCanvasTool) {
            guard next != tool else { return }
            cancelPointer(); resetHandCursor(); tool = next
            window?.invalidateCursorRects(for: self)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorTracking { removeTrackingArea(cursorTracking) }
            let area = NSTrackingArea(rect: .zero,
                options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate],
                owner: self, userInfo: nil)
            addTrackingArea(area); cursorTracking = area
        }
        override func cursorUpdate(with event: NSEvent) { updateHandCursor(for: event) }
        override func mouseEntered(with event: NSEvent) { updateHandCursor(for: event) }
        override func mouseExited(with event: NSEvent) {
            if !handPressed { resetHandCursor() }
        }
        private func updateHandCursor(for event: NSEvent) {
            guard tool == .hand, window?.isKeyWindow == true,
                  handPressed || accepts(event) else {
                if !handPressed { resetHandCursor() }; return
            }
            (handPressed ? NSCursor.closedHand : NSCursor.openHand).set()
            ownsCursor = true
        }
        private func resetHandCursor() {
            handPressed = false
            if ownsCursor { NSCursor.arrow.set(); ownsCursor = false }
        }

        private var reportedSize: WorkflowCanvasViewportMeasurement?
        private weak var observedScroll: NSScrollView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidHide() { super.viewDidHide(); cancelPointer(); resetHandCursor() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            reportViewportSize()
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelPointer(); self?.resetHandCursor() }
                }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown,
                .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self else { return event }
                switch event.type {
                case .keyDown:
                    if event.keyCode == 53, self.pointerSession != nil {
                        self.cancelPointer(); return nil
                    }
                    return event
                case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                    return self.routePointer(event) ? nil : event
                case .mouseMoved:
                    self.updateHandCursor(for: event); return event
                default: break
                }
                guard self.accepts(event),
                      let scroll = self.enclosingScrollView else { return event }
                let clip = scroll.contentView
                let location = clip.convert(event.locationInWindow, from: nil)
                let point = CGPoint(
                    x: location.x - clip.bounds.minX,
                    y: clip.isFlipped ? location.y - clip.bounds.minY : clip.bounds.maxY - location.y
                )
                if self.pointerSession != nil || !self.navigationAllowed() {
                    return event.type == .scrollWheel ? nil : event
                }
                guard self.allowsViewportEvent(point, clip.bounds.origin, clip.bounds.size) else { return event }
                if event.type == .scrollWheel {
                    guard event.scrollingDeltaY != 0 else { return event }
                    return self.dispatchWheel(event.scrollingDeltaY, point, clip.bounds.origin, clip.bounds.size)
                        ? nil : event // A zoom wheel event must not also scroll the native view.
                }
                guard event.buttonNumber == 2 else { return event }
                return self.dispatchMiddleClick(scroll.contentView.bounds.size) ? nil : event
            }
        }

        /// Uses native window deltas, so moving/scrolling the document does not
        /// feed its own coordinate changes back into the gesture.
        @discardableResult
        func routePointer(_ event: NSEvent) -> Bool {
            if event.type == .leftMouseDown {
                guard window?.isKeyWindow == true, accepts(event), navigationAllowed(),
                      let clip = enclosingScrollView?.contentView else { return false }
                let location = clip.convert(event.locationInWindow, from: nil)
                let point = CGPoint(x: location.x - clip.bounds.minX,
                    y: clip.isFlipped ? location.y - clip.bounds.minY : clip.bounds.maxY - location.y)
                let target = pointerTarget(point, clip.bounds.origin, clip.bounds.size)
                guard target != .control else { return false }
                cancelPointer()
                pointerSession = PointerSession(target: target, tool: tool,
                    windowStart: event.locationInWindow, point: point, offset: clip.bounds.origin,
                    viewport: clip.bounds.size, shift: event.modifierFlags.contains(.shift),
                    pointer: onPointer, pan: onPan)
                handPressed = tool == .hand
                updateHandCursor(for: event)
                return true
            }
            guard var session = pointerSession else { return false }
            guard event.window === window, window?.isKeyWindow == true,
                  !isHiddenOrHasHiddenAncestor else { cancelPointer(); return true }
            session.translation = CGSize(width: event.locationInWindow.x - session.windowStart.x,
                                          height: session.windowStart.y - event.locationInWindow.y)
            if event.type == .leftMouseDragged {
                guard session.moved || hypot(session.translation.width, session.translation.height) >= 5 else { return true }
                let began = !session.moved
                session.moved = true
                pointerSession = session
                if session.target == .blank, session.tool == .hand,
                   let scroll = enclosingScrollView {
                    if began { session.pan(true, session.offset, session.viewport) }
                    let clip = scroll.contentView
                    var rect = clip.bounds
                    rect.origin = CGPoint(x: session.offset.x - session.translation.width,
                                          y: session.offset.y - session.translation.height)
                    clip.scroll(to: clip.constrainBoundsRect(rect).origin)
                    scroll.reflectScrolledClipView(clip)
                    session.lastOffset = clip.bounds.origin
                    session.lastViewport = clip.bounds.size
                    pointerSession = session
                } else { session.update(began ? .began : .changed) }
                updateHandCursor(for: event)
            } else if event.type == .leftMouseUp {
                pointerSession = nil // Consume before controller mutations/revision changes.
                if session.target == .blank, session.tool == .hand {
                    if session.moved { finishPan(session) }
                } else { session.update(session.moved ? .ended : .clicked) }
                resetHandCursor(); updateHandCursor(for: event)
            }
            return true
        }

        private func finishPan(_ session: PointerSession) {
            session.pan(false, session.lastOffset ?? session.offset, session.lastViewport ?? session.viewport)
        }

        func cancelPointer() {
            guard let session = pointerSession else { return }
            pointerSession = nil
            if session.moved {
                if session.target == .blank, session.tool == .hand { finishPan(session) }
                else { session.update(.cancelled) }
            }
            resetHandCursor()
        }

        func allowsViewportEvent(_ point: CGPoint, _ offset: CGPoint, _ viewport: CGSize) -> Bool {
            navigationAllowed() && allowsEvent(point, offset, viewport)
        }

        @discardableResult
        func dispatchWheel(_ delta: CGFloat, _ point: CGPoint, _ offset: CGPoint,
                           _ viewport: CGSize) -> Bool {
            guard navigationAllowed() else { return false }
            onWheel(delta, point, offset, viewport)
            return true
        }

        @discardableResult
        func dispatchMiddleClick(_ viewport: CGSize) -> Bool {
            guard navigationAllowed() else { return false }
            onMiddleClick(viewport)
            return true
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            reportViewportSize()
        }

        override func layout() {
            super.layout()
            reportViewportSize()
        }

        func reportViewportSize() {
            updateViewportObservation()
            guard let scroll = enclosingScrollView else { return }
            let measured = WorkflowCanvasViewportMeasurement(clip: scroll.contentView.bounds.size,
                                                              surfaceWidth: scroll.frame.width)
            guard measured.clip.width > 0, measured.clip.height > 0,
                  reportedSize != measured else { return }
            reportedSize = measured
            onViewportSize(measured)
        }

        // The graph document can keep its size while its enclosing panel finishes
        // resizing. Observe the actual surface and clip instead of waiting for a
        // document layout that may never happen.
        private func updateViewportObservation() {
            let scroll = enclosingScrollView
            guard observedScroll !== scroll else { return }
            stopViewportObservation()
            guard let scroll else { return }
            observedScroll = scroll
            scroll.postsFrameChangedNotifications = true
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: NSView.frameDidChangeNotification, object: scroll)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }

        @objc private func viewportChanged(_ notification: Notification) { reportViewportSize() }

        private func stopViewportObservation() {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
            observedScroll = nil
        }

        private func accepts(_ event: NSEvent) -> Bool {
            guard let window,
                  (event.window === window || event.windowNumber == window.windowNumber),
                  window.attachedSheet == nil,
                  !isHiddenOrHasHiddenAncestor,
                  let scroll = enclosingScrollView, !scroll.isHiddenOrHasHiddenAncestor,
                  let content = window.contentView else { return false }
            var ancestor: NSView? = self
            while let current = ancestor {
                if current.alphaValue <= 0.01 || (current.layer?.opacity ?? 1) <= 0.01 { return false }
                ancestor = current.superview
            }
            let point = content.superview?.convert(event.locationInWindow, from: nil)
                ?? event.locationInWindow
            guard let hit = content.hitTest(point) else { return false }
            var view: NSView? = hit
            while let current = view, current !== scroll {
                if current is NSControl || current is NSTextView || current is WorkflowPortDragView || current is WorkflowConnectionHitView { return false }
                view = current.superview
            }
            return view === scroll
        }

        func stopMonitoring() {
            cancelPointer()
            resetHandCursor()
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
            stopViewportObservation()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

/// Screen pixels and raw graph coordinates stay distinct, including the scrollable edge space.
struct WorkflowCanvasViewportGeometry: Equatable {
    let graphSize: CGSize
    let viewportSize: CGSize
    let zoom: CGFloat
    let translation: CGSize

    // Keep the same raw edge region at every zoom. Its screen size is at least one viewport.
    var padding: CGSize {
        // Preserve the established edge space from 50% upward. Lower fit levels
        // still need one screen of padding to keep the fitted center reachable.
        let factor = max(1, zoom / 0.5)
        return CGSize(width: viewportSize.width * factor, height: viewportSize.height * factor)
    }
    var contentSize: CGSize {
        CGSize(width: max(graphSize.width * zoom, viewportSize.width) + 2 * padding.width,
               height: max(graphSize.height * zoom, viewportSize.height) + 2 * padding.height)
    }
    var unscaledGraphSize: CGSize {
        CGSize(width: max(graphSize.width, viewportSize.width / zoom),
               height: max(graphSize.height, viewportSize.height / zoom))
    }
    var unscaledPadding: CGSize {
        CGSize(width: padding.width / zoom, height: padding.height / zoom)
    }
    var centerRawPoint: CGPoint {
        CGPoint(x: graphSize.width / 2 - translation.width,
                y: graphSize.height / 2 - translation.height)
    }

    func rawPoint(screenPoint: CGPoint, offset: CGPoint) -> CGPoint {
        CGPoint(x: (screenPoint.x + offset.x - padding.width) / zoom - translation.width,
                y: (screenPoint.y + offset.y - padding.height) / zoom - translation.height)
    }

    func offset(rawPoint: CGPoint, at screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: (rawPoint.x + translation.width) * zoom + padding.width - screenPoint.x,
                y: (rawPoint.y + translation.height) * zoom + padding.height - screenPoint.y)
    }

    func visibleRawCenter(offset: CGPoint) -> CGPoint {
        rawPoint(screenPoint: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2),
                 offset: offset)
    }

    func centeredOffset(on rawPoint: CGPoint) -> CGPoint {
        offset(rawPoint: rawPoint,
               at: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
    }

    func pannedOffset(from start: CGPoint, translation: CGSize) -> CGPoint {
        CGPoint(x: start.x - translation.width, y: start.y - translation.height)
    }

    /// Move only as far as the finite scroll surface can keep the raw point under the mouse.
    func anchoredZoom(toward requested: CGFloat, mouse: CGPoint, offset currentOffset: CGPoint)
        -> (zoom: CGFloat, offset: CGPoint) {
        let requested = WorkflowCanvasLayoutPolicy.clampedInteractiveZoom(requested, current: zoom)
        guard requested != zoom else { return (zoom, currentOffset) }
        let raw = rawPoint(screenPoint: mouse, offset: currentOffset)
        func candidate(_ scale: CGFloat) -> (zoom: CGFloat, offset: CGPoint, fits: Bool) {
            let next = WorkflowCanvasViewportGeometry(graphSize: graphSize, viewportSize: viewportSize,
                zoom: scale, translation: translation)
            let target = next.offset(rawPoint: raw, at: mouse)
            let maximum = CGPoint(x: next.contentSize.width - viewportSize.width,
                                  y: next.contentSize.height - viewportSize.height)
            return (scale, target,
                    target.x >= 0 && target.y >= 0 && target.x <= maximum.x && target.y <= maximum.y)
        }
        let final = candidate(requested)
        if final.fits { return (final.zoom, final.offset) }
        var accepted: CGFloat = 0
        var rejected: CGFloat = 1
        for _ in 0..<24 {
            let fraction = (accepted + rejected) / 2
            let step = candidate(zoom + (requested - zoom) * fraction)
            if step.fits { accepted = fraction } else { rejected = fraction }
        }
        let limited = candidate(zoom + (requested - zoom) * accepted)
        return limited.fits && abs(limited.zoom - zoom) > 0.00001
            ? (limited.zoom, limited.offset) : (zoom, currentOffset)
    }
}

#if DEBUG
@MainActor
enum WorkflowCanvasUpdateProbe {
    static var canvasBody: (() -> Void)?
    static var surfaceBody: (() -> Void)?
    static var nodeBody: ((UUID) -> Void)?
    static var wireHitBuild: ((Double) -> Void)?
}
#endif
