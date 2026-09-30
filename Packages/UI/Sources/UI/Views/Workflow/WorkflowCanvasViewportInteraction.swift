import AppKit
import SwiftUI

struct WorkflowCanvasNavigationRequest: Equatable {
    let id = UUID()
    /// Nil requests the current graph's content center.
    let rawCenter: CGPoint?
}

/// The probe lives inside the graph's scroll content. The local monitor is active only while
/// that native view is mounted, and accepts events whose native hit path reaches its scroll view.
struct WorkflowCanvasViewportInput: NSViewRepresentable {
    typealias Coordinator = Void
    var allowsEvent: () -> Bool
    var onWheel: (_ deltaY: CGFloat, _ point: CGPoint, _ offset: CGPoint, _ viewport: CGSize) -> Void
    var onMiddleClick: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.allowsEvent = allowsEvent
        view.onWheel = onWheel
        view.onMiddleClick = onMiddleClick
    }

    final class ProbeView: NSView {
        var allowsEvent: () -> Bool = { false }
        var onWheel: (CGFloat, CGPoint, CGPoint, CGSize) -> Void = { _, _, _, _ in }
        var onMiddleClick: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown]) { [weak self] event in
                guard let self, self.accepts(event), self.allowsEvent() else { return event }
                if event.type == .scrollWheel {
                    guard event.scrollingDeltaY != 0,
                          let scroll = self.enclosingScrollView else { return event }
                    let clip = scroll.contentView
                    let location = clip.convert(event.locationInWindow, from: nil)
                    let point = CGPoint(
                        x: location.x - clip.bounds.minX,
                        y: clip.isFlipped ? location.y - clip.bounds.minY : clip.bounds.maxY - location.y
                    )
                    self.onWheel(event.scrollingDeltaY, point, clip.bounds.origin, clip.bounds.size)
                    return nil // A zoom wheel event must not also scroll the native view.
                }
                guard event.buttonNumber == 2 else { return event }
                self.onMiddleClick()
                return nil
            }
        }

        private func accepts(_ event: NSEvent) -> Bool {
            guard let window,
                  (event.window === window || event.windowNumber == window.windowNumber),
                  window.attachedSheet == nil,
                  !isHiddenOrHasHiddenAncestor,
                  let scroll = enclosingScrollView, !scroll.isHiddenOrHasHiddenAncestor,
                  let content = window.contentView else { return false }
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
        let factor = zoom / WorkflowCanvasLayoutPolicy.zoomRange.lowerBound
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
        let requested = WorkflowCanvasLayoutPolicy.clampedZoom(requested)
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
