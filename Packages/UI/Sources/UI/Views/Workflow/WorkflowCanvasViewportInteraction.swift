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

/// The probe lives inside the graph's scroll content. The local monitor is active only while
/// that native view is mounted, and accepts events whose native hit path reaches its scroll view.
struct WorkflowCanvasViewportInput: NSViewRepresentable {
    typealias Coordinator = Void
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
        view.navigationAllowed = navigationAllowed
        view.allowsEvent = allowsEvent
        view.onViewportSize = onViewportSize
        view.onWheel = onWheel
        view.onMiddleClick = onMiddleClick
        view.reportViewportSize()
    }

    final class ProbeView: NSView {
        var navigationAllowed: () -> Bool = { false }
        var allowsEvent: (CGPoint, CGPoint, CGSize) -> Bool = { _, _, _ in false }
        var onViewportSize: (WorkflowCanvasViewportMeasurement) -> Void = { _ in }
        var onWheel: (CGFloat, CGPoint, CGPoint, CGSize) -> Void = { _, _, _, _ in }
        var onMiddleClick: (CGSize) -> Void = { _ in }
        private var monitor: Any?
        private var reportedSize: WorkflowCanvasViewportMeasurement?
        private weak var observedScroll: NSScrollView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            reportViewportSize()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown]) { [weak self] event in
                guard let self, self.accepts(event),
                      let scroll = self.enclosingScrollView else { return event }
                let clip = scroll.contentView
                let location = clip.convert(event.locationInWindow, from: nil)
                let point = CGPoint(
                    x: location.x - clip.bounds.minX,
                    y: clip.isFlipped ? location.y - clip.bounds.minY : clip.bounds.maxY - location.y
                )
                if !self.navigationAllowed() {
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
                if current is NSControl || current is NSTextView { return false }
                view = current.superview
            }
            return view === scroll
        }

        func stopMonitoring() {
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
