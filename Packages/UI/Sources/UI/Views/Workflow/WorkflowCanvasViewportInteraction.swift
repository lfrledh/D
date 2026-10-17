import AppKit
import SwiftUI

enum WorkflowCanvasTool: String, CaseIterable {
    case pointer, hand
}

/// Application-only navigation preference, never a project or frozen request field.
struct WorkflowCanvasNavigationPreferences: Codable, Equatable {
    var version = 1
    var wheelSpeed = 1.0
    static let speedRange = 0.25...4.0
    var isValid: Bool { version == 1 && wheelSpeed.isFinite && Self.speedRange.contains(wheelSpeed) }
    var resolvedSpeed: CGFloat { isValid ? CGFloat(wheelSpeed) : 1 }
}

enum WorkflowCanvasWheelResponse {
    // AppKit reports discrete wheels in lines and precise wheels in points.
    // Keep the established precise response; one discrete unit is a 10% step.
    static func delta(_ event: NSEvent) -> CGFloat {
        event.hasPreciseScrollingDeltas ? event.scrollingDeltaY
            : event.scrollingDeltaY * CGFloat(log(1.1) / 0.015)
    }
    static func isHorizontalNavigation(_ event: NSEvent) -> Bool {
        event.hasPreciseScrollingDeltas && event.scrollingDeltaY == 0 && event.scrollingDeltaX != 0
    }
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
    let wheelZoom = WorkflowCanvasWheelZoom()
}

/// Wheel events can arrive before SwiftUI lays out the preceding scale. Accumulate
/// from the requested view, then apply its offset only to the matching native layout.
/// No asynchronous scrollTo remains to overwrite a later pan or scrollbar action.
final class WorkflowCanvasWheelZoom {
    private struct Target {
        let scope: WorkflowCanvasScope
        let layout: WorkflowCanvasViewportGeometry
        let offset: CGPoint
    }
    private var pending: Target?
    private var requestedZoom: CGFloat?

    func offset(in layout: WorkflowCanvasViewportGeometry, scope: WorkflowCanvasScope) -> CGPoint? {
        guard let pending, pending.scope == scope, pending.layout == layout else { return nil }
        return pending.offset
    }

    func request(delta: CGFloat, mouse: CGPoint, nativeOffset: CGPoint,
                 layout: WorkflowCanvasViewportGeometry, scope: WorkflowCanvasScope) -> CGFloat {
        let currentOffset = offset(in: layout, scope: scope) ?? nativeOffset
        let next = layout.anchoredZoom(toward: layout.zoom * CGFloat(exp(Double(delta) * 0.015)),
                                     mouse: mouse, offset: currentOffset)
        guard next.zoom != layout.zoom else { return layout.zoom }
        let target = WorkflowCanvasViewportGeometry(graphSize: layout.graphSize,
            viewportSize: layout.viewportSize, zoom: next.zoom, translation: layout.translation)
        pending = Target(scope: scope, layout: target, offset: next.offset)
        requestedZoom = next.zoom
        return next.zoom
    }

    /// Cancelled wheels still own their scale change; it must not become a
    /// toolbar-style center zoom when its delayed onChange arrives.
    func consumeScaleChange(to zoom: CGFloat) -> Bool {
        let isWheel = requestedZoom == zoom
        requestedZoom = nil
        if !isWheel { cancel() }
        return isWheel
    }

    func cancel() { pending = nil }

    func takeReadyOffset(scope: WorkflowCanvasScope?, declaredLayout: WorkflowCanvasViewportGeometry?, contentSize: CGSize,
                         viewport: CGSize) -> CGPoint? {
        guard let pending, pending.scope == scope,
              pending.layout == declaredLayout,
              pending.layout.viewportSize == viewport,
              abs(contentSize.width - pending.layout.contentSize.width) <= 1,
              abs(contentSize.height - pending.layout.contentSize.height) <= 1 else { return nil }
        self.pending = nil
        return pending.offset
    }
}

/// Keep the raw camera across same-canvas origin changes. Only a matching
/// native layout may consume the correction, and a later navigation cancels it.
final class WorkflowCanvasLayoutAnchor {
    private struct Snapshot {
        let identity: WorkflowCanvasScopeIdentity
        let layout: WorkflowCanvasViewportGeometry
        let offset: CGPoint
    }
    private var ready: Snapshot?
    private var pending: Snapshot?
    private var declared: WorkflowCanvasViewportGeometry?
    func cancel() { ready = nil; pending = nil; declared = nil }
    func reconcile(scope: WorkflowCanvasScope?, layout: WorkflowCanvasViewportGeometry?,
                   contentSize: CGSize, viewport: CGSize, offset: CGPoint) -> CGPoint? {
        guard let scope, let layout else { cancel(); return nil }
        let previous = pending ?? ready
        if let previous, previous.identity != scope.identity || previous.layout.zoom != layout.zoom
            || previous.layout.viewportSize != layout.viewportSize { cancel() }
        if declared != layout {
            if let previous = pending ?? ready, previous.identity == scope.identity,
               previous.layout.translation != layout.translation {
                pending = Snapshot(identity: scope.identity, layout: layout,
                    offset: layout.centeredOffset(on: previous.layout.visibleRawCenter(offset: previous.offset)))
            } else if let pending {
                self.pending = Snapshot(identity: pending.identity, layout: layout, offset: pending.offset)
            }
            declared = layout
        }
        guard layout.viewportSize == viewport,
              abs(contentSize.width - layout.contentSize.width) <= 1,
              abs(contentSize.height - layout.contentSize.height) <= 1 else { return nil }
        if let pending {
            self.pending = nil; ready = pending
            return pending.offset
        }
        ready = Snapshot(identity: scope.identity, layout: layout, offset: offset)
        return nil
    }
}

/// The probe lives inside the graph's scroll content. The local monitor is active only while
/// that native view is mounted, and accepts events whose native hit path reaches its scroll view.
struct WorkflowCanvasViewportInput: NSViewRepresentable {
    typealias Coordinator = Void
    var tool: WorkflowCanvasTool = .pointer
    var interactionScope: WorkflowCanvasScope? = nil
    var wheelZoom: WorkflowCanvasWheelZoom? = nil
    var navigationID: UUID? = nil
    var wheelLayout: (CGSize) -> WorkflowCanvasViewportGeometry? = { _ in nil }
    var pointerTarget: (CGPoint, CGPoint, CGSize) -> WorkflowCanvasPointerTarget = { _, _, _ in .control }
    var onPointer: (WorkflowCanvasPointerUpdate) -> Void = { _ in }
    var onPan: (Bool, CGPoint, CGSize) -> Void = { _, _, _ in }
    var navigationAllowed: () -> Bool
    var allowsEvent: (_ point: CGPoint, _ offset: CGPoint, _ viewport: CGSize) -> Bool
    var onViewportSize: (WorkflowCanvasViewportMeasurement) -> Void
    var onWheel: (_ deltaY: CGFloat, _ point: CGPoint, _ offset: CGPoint, _ viewport: CGSize) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        if view.interactionScope != interactionScope { view.cancelPointer() }
        if view.navigationID != navigationID { view.layoutAnchor.cancel() }
        view.navigationID = navigationID
        view.interactionScope = interactionScope
        view.wheelZoom = wheelZoom
        view.wheelLayout = wheelLayout
        view.setTool(tool)
        view.pointerTarget = pointerTarget
        view.onPointer = onPointer
        view.onPan = onPan
        view.navigationAllowed = navigationAllowed
        view.allowsEvent = allowsEvent
        view.onViewportSize = onViewportSize
        view.onWheel = onWheel
        view.reportViewportSize()
    }

    final class ProbeView: NSView {
        var interactionScope: WorkflowCanvasScope? { didSet { if oldValue != interactionScope { wheelOwner = nil; wheelScrollOwner = nil } } }
        var wheelZoom: WorkflowCanvasWheelZoom?
        var navigationID: UUID?
        let layoutAnchor = WorkflowCanvasLayoutAnchor()
        var wheelLayout: (CGSize) -> WorkflowCanvasViewportGeometry? = { _ in nil }
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
        private enum WheelOwner { case canvas, foreign }
        private var wheelOwner: WheelOwner?
        private weak var wheelScrollOwner: NSScrollView?

        var navigationAllowed: () -> Bool = { false }
        var allowsEvent: (CGPoint, CGPoint, CGSize) -> Bool = { _, _, _ in false }
        var onViewportSize: (WorkflowCanvasViewportMeasurement) -> Void = { _ in }
        var onWheel: (CGFloat, CGPoint, CGPoint, CGSize) -> Void = { _, _, _, _ in }
        private var monitor: Any?
        private var cursorTracking: NSTrackingArea?
        private var resignObserver: NSObjectProtocol?
        private var windowUpdateObserver: NSObjectProtocol?
        private(set) var tool: WorkflowCanvasTool = .pointer
        private(set) var handPressed = false
        private var ownsCursor = false
        private var cursorRefresh: UUID?
        struct HandCursorRegion: Equatable {
            let rect: NSRect
            let cursor: NSCursor
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.rect == rhs.rect && lhs.cursor === rhs.cursor
            }
        }
        private(set) var registeredHandCursorRegion: HandCursorRegion?
        private var cursorRectInvalidationPending = false
        #if DEBUG
        // Observe cursor decisions in component tests without changing the user's cursor.
        var cursorSink: ((NSCursor) -> Void)?
        #endif

        private func setCursor(_ cursor: NSCursor) {
            #if DEBUG
            if let cursorSink { cursorSink(cursor); return }
            #endif
            cursor.set()
        }

        func setTool(_ next: WorkflowCanvasTool) {
            guard next != tool else { return }
            cursorRefresh = nil
            cancelPointer(); layoutAnchor.cancel(); resetHandCursor(); tool = next
            window?.invalidateCursorRects(for: self)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // inVisibleRect follows native geometry itself. Replacing this area
            // during every zoom creates exit/enter transitions under a still mouse.
            guard cursorTracking == nil else { return }
            let area = NSTrackingArea(rect: .zero,
                options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate],
                owner: self, userInfo: nil)
            addTrackingArea(area); cursorTracking = area
        }
        override func resetCursorRects() {
            super.resetCursorRects()
            clearHandCursorRegion()
            cursorRectInvalidationPending = false
            // AppKit chooses from these rectangles during the reset itself.
            // A later main-queue set() alone leaves an arrow during live zoom.
            if let region = currentHandCursorRegion() {
                addCursorRect(region.rect, cursor: region.cursor)
                registeredHandCursorRegion = region
            }
            scheduleCursorRefresh()
        }

        private func currentHandCursorRegion() -> HandCursorRegion? {
            guard tool == .hand, let window, window.isKeyWindow,
                  visibleCanvasScroll() != nil else { return nil }
            let mouse = window.mouseLocationOutsideOfEventStream
            guard accepts(at: mouse), let owner = canvasHit(at: mouse) else { return nil }
            let local = convert(mouse, from: nil)
            let pixel = convertToBacking(local)
            let rect = convertFromBacking(NSRect(x: pixel.x - 0.5, y: pixel.y - 0.5, width: 1, height: 1))
                .intersection(visibleRect).intersection(bounds)
            guard !rect.isEmpty, local.x > rect.minX, local.x < rect.maxX,
                  local.y > rect.minY, local.y < rect.maxY else { return nil }
            // Never claim a whole card or the canvas over its controls. Even
            // this one-pixel cell must have the same accepted hit at its edges.
            let inset = rect.insetBy(dx: rect.width * 0.001, dy: rect.height * 0.001)
            for point in [CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY),
                          CGPoint(x: inset.minX, y: inset.maxY), CGPoint(x: inset.maxX, y: inset.maxY)] {
                let location = convert(point, to: nil)
                guard canvasHit(at: location) === owner else { return nil }
            }
            return HandCursorRegion(rect: rect, cursor: handPressed ? .closedHand : .openHand)
        }

        private func clearHandCursorRegion() {
            if let region = registeredHandCursorRegion { removeCursorRect(region.rect, cursor: region.cursor) }
            registeredHandCursorRegion = nil
        }

        // Also called when a stationary pointer acquires a new native owner
        // (for example an editor or a floating panel appearing below it).
        func reconcileHandCursorRegion() {
            let desired = currentHandCursorRegion()
            if desired == nil && !handPressed { ownsCursor = false }
            guard desired != registeredHandCursorRegion else { return }
            clearHandCursorRegion()
            guard desired != nil, !cursorRectInvalidationPending, let window else { return }
            cursorRectInvalidationPending = true
            window.invalidateCursorRects(for: self)
        }

        // AppKit resets cursor rectangles after scrolling and layout, even if
        // the mouse has not moved. Reconcile once after that synchronous work;
        // this is event-driven, never a timer or a self-sustaining render loop.
        private func scheduleCursorRefresh() {
            guard tool == .hand, cursorRefresh == nil, let window else { return }
            let request = UUID()
            cursorRefresh = request
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, self.cursorRefresh == request else { return }
                self.cursorRefresh = nil
                guard let window, self.window === window, window.isKeyWindow,
                      self.tool == .hand, self.visibleCanvasScroll() != nil,
                      (self.handPressed && self.pointerSession != nil)
                        || self.accepts(at: window.mouseLocationOutsideOfEventStream) else {
                    // Another native owner may already have installed an I-beam
                    // or resize cursor. Never overwrite it using old ownership.
                    self.ownsCursor = false
                    return
                }
                self.setCursor(self.handPressed ? .closedHand : .openHand)
                self.ownsCursor = true
            }
        }
        override func cursorUpdate(with event: NSEvent) {
            if !updateHandCursor(for: event) { super.cursorUpdate(with: event) }
        }
        override func mouseEntered(with event: NSEvent) { updateHandCursor(for: event) }
        override func mouseExited(with event: NSEvent) {
            // A geometry update can exit an old tracking region without leaving
            // the canvas. Recheck the actual window hit before releasing ownership.
            updateHandCursor(for: event)
        }
        @discardableResult private func updateHandCursor(for event: NSEvent) -> Bool {
            reconcileHandCursorRegion()
            guard tool == .hand, window?.isKeyWindow == true,
                  handPressed || accepts(event) else {
                if !handPressed { resetHandCursor() }; return false
            }
            setCursor(handPressed ? NSCursor.closedHand : NSCursor.openHand)
            ownsCursor = true
            return true
        }
        private func resetHandCursor() {
            clearHandCursorRegion()
            handPressed = false
            if ownsCursor { setCursor(.arrow); ownsCursor = false }
        }

        private var reportedSize: WorkflowCanvasViewportMeasurement?
        private weak var observedScroll: NSScrollView?
        private weak var observedDocument: NSView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidHide() { super.viewDidHide(); cancelPointer(); layoutAnchor.cancel(); resetHandCursor() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            reportViewportSize()
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelPointer(); self?.resetHandCursor() }
                }
            windowUpdateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcileHandCursorRegion() }
                }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel,
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
                if event.type == .scrollWheel { return self.routeWheel(event) ? nil : event }
                return event
            }
        }

        /// Uses native window deltas, so moving/scrolling the document does not
        /// feed its own coordinate changes back into the gesture.
        @discardableResult
        func routePointer(_ event: NSEvent) -> Bool {
            if event.type == .leftMouseDown {
                if canvasHit(event) != nil { wheelZoom?.cancel(); layoutAnchor.cancel() }
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
                    if session.moved { finishPan(session) } else { session.update(.clicked) }
                } else { session.update(session.moved ? .ended : .clicked) }
                resetHandCursor(); updateHandCursor(for: event)
            }
            return true
        }

        private func finishPan(_ session: PointerSession) {
            session.pan(false, session.lastOffset ?? session.offset, session.lastViewport ?? session.viewport)
        }

        func cancelPointer() {
            wheelZoom?.cancel()
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
            layoutAnchor.cancel()
            onWheel(delta, point, offset, viewport)
            return true
        }



        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            reportViewportSize()
        }

        override func layout() {
            super.layout()
            reportViewportSize()
            scheduleCursorRefresh()
        }

        func reportViewportSize() {
            defer { reconcileHandCursorRegion() }
            updateViewportObservation()
            guard let scroll = enclosingScrollView else { return }
            if scroll.scrollerStyle != .overlay || scroll.hasHorizontalScroller || scroll.hasVerticalScroller {
                scroll.scrollerStyle = .overlay
                scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
                scroll.tile() // Clear stale gutters once, never on each pan tick.
            }
            scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
            let measured = WorkflowCanvasViewportMeasurement(clip: scroll.contentView.bounds.size,
                                                              surfaceWidth: scroll.frame.width)
            if let reportedSize, reportedSize.clip != measured.clip { wheelZoom?.cancel(); layoutAnchor.cancel() }
            applyLayoutAnchor()
            applyWheelOffset()
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
            guard observedScroll !== scroll || observedDocument !== scroll?.documentView else { return }
            stopViewportObservation()
            layoutAnchor.cancel()
            guard let scroll else { return }
            observedScroll = scroll
            observedDocument = scroll.documentView
            scroll.postsFrameChangedNotifications = true
            scroll.contentView.postsBoundsChangedNotifications = true
            observedDocument?.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: NSView.frameDidChangeNotification, object: scroll)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            if let observedDocument {
                NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                    name: NSView.frameDidChangeNotification, object: observedDocument)
            }
        }

        @objc private func viewportChanged(_ notification: Notification) { reportViewportSize() }

        private func stopViewportObservation() {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
            observedScroll = nil
            observedDocument = nil
        }

        /// Establish canvas ownership before deciding whether a child owns scrolling.
        /// Native controls such as ports must not leak an unused wheel into the canvas.
        private func visibleCanvasScroll() -> NSScrollView? {
            guard let window, window.attachedSheet == nil,
                  !isHiddenOrHasHiddenAncestor,
                  let scroll = enclosingScrollView, !scroll.isHiddenOrHasHiddenAncestor else { return nil }
            var ancestor: NSView? = self
            while let current = ancestor {
                if current.alphaValue <= 0.01 || (current.layer?.opacity ?? 1) <= 0.01 { return nil }
                ancestor = current.superview
            }
            return scroll
        }

        private func canvasHit(_ event: NSEvent) -> NSView? {
            guard let window, event.window === window || event.windowNumber == window.windowNumber else { return nil }
            return canvasHit(at: event.locationInWindow)
        }
        private func canvasHit(at location: CGPoint) -> NSView? {
            guard let window, let scroll = visibleCanvasScroll(), let content = window.contentView else { return nil }
            let point = content.superview?.convert(location, from: nil) ?? location
            guard let hit = content.hitTest(point) else { return nil }
            var view: NSView? = hit
            while let current = view, current !== scroll { view = current.superview }
            return view === scroll ? hit : nil
        }

        private func accepts(_ event: NSEvent) -> Bool {
            guard let window, event.window === window || event.windowNumber == window.windowNumber else { return false }
            return accepts(at: event.locationInWindow)
        }
        private func accepts(at location: CGPoint) -> Bool {
            guard let hit = canvasHit(at: location), let scroll = enclosingScrollView else { return false }
            var view: NSView? = hit
            while let current = view, current !== scroll {
                if current is NSControl || current is NSTextView || current is NSScrollView || current is WorkflowPortDragView || current is WorkflowConnectionHitView { return false }
                view = current.superview
            }
            return view === scroll
        }

        @discardableResult
        func routeWheel(_ event: NSEvent) -> Bool {
            guard let scroll = visibleCanvasScroll(), let window,
                  event.window === window || event.windowNumber == window.windowNumber else { return false }
            defer { reconcileHandCursorRegion(); scheduleCursorRefresh() }
            return routeWheel(event, in: scroll, window: window, location: event.locationInWindow)
        }

        // Resolve the validated event once, then keep one owner for its gesture.
        private func routeWheel(_ event: NSEvent, in scroll: NSScrollView, window: NSWindow, location: CGPoint) -> Bool {
            guard self.window === window, visibleCanvasScroll() === scroll else { return false }
            let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
            let begins = event.phase.contains(.began) || event.phase.contains(.mayBegin)
            if begins || !phased { wheelOwner = nil; wheelScrollOwner = nil }
            let hit = canvasHit(at: location)
            if wheelOwner == nil {
                var current: NSView? = hit ?? window.contentView?.hitTest(
                    window.contentView?.superview?.convert(location, from: nil) ?? location)
                var nested: NSScrollView?
                var ownsControl = false
                while let view = current, view !== scroll {
                    if let inner = view as? NSScrollView { nested = inner; break }
                    ownsControl = ownsControl || view is NSControl || view is NSTextView
                    current = view.superview
                }
                if hit != nil && nested == nil && !ownsControl {
                    wheelOwner = .canvas
                } else {
                    wheelOwner = .foreign; wheelScrollOwner = nested
                }
            }
            defer {
                if !phased || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
                    wheelOwner = nil; wheelScrollOwner = nil
                }
            }
            if wheelOwner == .foreign {
                wheelZoom?.cancel()
                if let owner = wheelScrollOwner, owner !== scroll,
                   owner.window === window, !owner.isHiddenOrHasHiddenAncestor {
                    // Keep the same inner scroll owner through boundaries and inertia,
                    // including when it reaches an edge. Never chain into the canvas.
                    owner.scrollWheel(with: event)
                    return true
                }
                return hit != nil // A control's unused wheel must not bubble to the canvas.
            }
            guard pointerSession == nil, navigationAllowed() else { return true }
            let clip = scroll.contentView
            let location = clip.convert(location, from: nil)
            let point = CGPoint(x: location.x - clip.bounds.minX,
                y: clip.isFlipped ? location.y - clip.bounds.minY : clip.bounds.maxY - location.y)
            guard event.scrollingDeltaY != 0 else {
                // Preserve the existing precise trackpad horizontal route only.
                // Discrete mouse wheels are consumed even at a zoom limit or zero Y.
                if WorkflowCanvasWheelResponse.isHorizontalNavigation(event) {
                    wheelZoom?.cancel(); layoutAnchor.cancel()
                    scroll.scrollWheel(with: event) // Keep the initial canvas owner across regions.
                    return true
                }
                return true
            }
            _ = dispatchWheel(WorkflowCanvasWheelResponse.delta(event), point, clip.bounds.origin, clip.bounds.size)
            applyWheelOffset()
            return true
        }

        private func applyLayoutAnchor() {
            guard !isHiddenOrHasHiddenAncestor, let scroll = enclosingScrollView, let document = scroll.documentView else { layoutAnchor.cancel(); return }
            let clip = scroll.contentView
            guard let offset = layoutAnchor.reconcile(scope: interactionScope,
                layout: wheelLayout(clip.bounds.size), contentSize: document.frame.size,
                viewport: clip.bounds.size, offset: clip.bounds.origin) else { return }
            var bounds = clip.bounds; bounds.origin = offset
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
        }

        private func applyWheelOffset() {
            guard let scroll = visibleCanvasScroll() else { wheelZoom?.cancel(); return }
            guard let document = scroll.documentView,
                  let offset = wheelZoom?.takeReadyOffset(scope: interactionScope,
                      declaredLayout: wheelLayout(scroll.contentView.bounds.size),
                      contentSize: document.frame.size, viewport: scroll.contentView.bounds.size) else { return }
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin = offset
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
        }

        func stopMonitoring() {
            cursorRefresh = nil
            cursorRectInvalidationPending = false
            layoutAnchor.cancel()
            wheelOwner = nil; wheelScrollOwner = nil
            cancelPointer()
            resetHandCursor()
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
            if let windowUpdateObserver { NotificationCenter.default.removeObserver(windowUpdateObserver) }; windowUpdateObserver = nil
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
    struct Workspace {
        let draftTarget:UUID?
        let open:(UUID,Int)->Void
        let target:(UUID)->Void
        let range:(Int)->Void
    }
    static var workspace:((Workspace)->Void)?
    static var canvasBody: (() -> Void)?
    static var surfaceBody: (() -> Void)?
    static var nodeBody: ((UUID) -> Void)?
    static var nodeMenuBuild: ((UUID) -> Void)?
    static var wireHitBuild: ((Double) -> Void)?
}
#endif
