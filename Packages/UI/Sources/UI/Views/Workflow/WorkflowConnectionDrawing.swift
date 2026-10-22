import AppKit
import SwiftUI

/// Graph coordinates may be very large. Only this view's visible child owns a
/// drawing backing; the wrapper preserves layout, curves outside the node bounds
/// and the existing, separate native hit receivers. No node content is captured.
struct WorkflowConnectionDrawing: NSViewRepresentable {
    struct Stroke: Equatable {
        let path: Path
        let color: Color
        let selected: Bool
    }
    let strokes: [Stroke]
    let origin: CGPoint
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WorkflowConnectionDrawingView {
        WorkflowConnectionDrawingView()
    }
    func updateNSView(_ view: WorkflowConnectionDrawingView, context: Context) {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if view.appearance != appearance { view.appearance = appearance }
        view.update(strokes: strokes, origin: origin)
    }
}

@MainActor final class WorkflowConnectionDrawingView: NSView {
    let drawing = DrawingView()
    private var observers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(drawing)
        drawing.setAccessibilityElement(false)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(strokes: [WorkflowConnectionDrawing.Stroke], origin: CGPoint) {
        if drawing.strokes != strokes || drawing.origin != origin {
            drawing.strokes = strokes
            drawing.origin = origin
            drawing.paths = strokes.map { $0.path.cgPath }
            drawing.needsDisplay = true
        }
        updateViewport()
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeViewport() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeViewport() }
    override func layout() { super.layout(); updateViewport() }
    override func viewDidHide() { super.viewDidHide(); updateViewport() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateViewport() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); drawing.needsDisplay = true
    }
    private func observeViewport() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        var ancestor: NSView? = self
        while let view = ancestor {
            view.postsBoundsChangedNotifications = true
            view.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateViewport() }
                })
            }
            ancestor = view.superview
        }
        updateViewport()
    }
    isolated deinit { for token in observers { NotificationCenter.default.removeObserver(token) } }

    func updateViewport() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, let clip = enclosingScrollView?.contentView else {
            drawing.isHidden = true; drawing.frame = .zero; return
        }
        let visible = visibleRect.intersection(bounds).intersection(convert(clip.bounds, from: clip))
        guard !visible.isNull, !visible.isEmpty, !drawing.strokes.isEmpty else {
            drawing.isHidden = true
            // Release the old large viewport when the whole layer leaves view.
            drawing.frame = .zero
            return
        }
        drawing.isHidden = false
        // A zoomed-out graph can expose millions of logical points. Keep the
        // child's drawing bounds in viewport points as well as clipping its frame.
        let drawingBounds = CGRect(origin: .zero, size: convert(visible, to: clip).size)
        if drawing.frame != visible || drawing.bounds != drawingBounds || drawing.sourceRect != visible {
            // Pure pan changes the origin, not the backing size. Assigning the
            // whole frame also invokes AppKit's size/layout/tracking machinery.
            if drawing.frame.size != visible.size { drawing.setFrameSize(visible.size) }
            if drawing.frame.origin != visible.origin { drawing.setFrameOrigin(visible.origin) }
            // Changing frame size can change bounds; compare after the resize.
            if drawing.bounds != drawingBounds { drawing.bounds = drawingBounds }
            drawing.sourceRect = visible
            drawing.needsDisplay = true
        }
    }

    @MainActor final class DrawingView: NSView {
        var strokes: [WorkflowConnectionDrawing.Stroke] = []
        var paths: [CGPath] = []
        var origin = CGPoint.zero
        var sourceRect = CGRect.zero
        #if DEBUG
        private(set) var frameSizeCalls = 0
        override func setFrameSize(_ newSize: NSSize) {
            frameSizeCalls += 1
            super.setFrameSize(newSize)
        }
        #endif
        private(set) var drawCount = 0
        private(set) var strokedPathCount = 0
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let dirty = dirtyRect.intersection(bounds)
            guard !dirty.isNull, !dirty.isEmpty else { return }
            drawCount += 1
            context.saveGState(); defer { context.restoreGState() }
            context.clip(to: dirty)
            guard sourceRect.width > 0, sourceRect.height > 0 else { return }
            let sx = bounds.width / sourceRect.width, sy = bounds.height / sourceRect.height
            context.scaleBy(x: sx, y: sy)
            context.translateBy(x: -sourceRect.minX - origin.x, y: -sourceRect.minY - origin.y)
            let graphDirty = CGRect(x: dirty.minX / sx + sourceRect.minX + origin.x,
                y: dirty.minY / sy + sourceRect.minY + origin.y,
                width: dirty.width / sx, height: dirty.height / sy)
            for (stroke, path) in zip(strokes, paths) {
                guard path.boundingBoxOfPath.insetBy(dx: -3 - 1 / sx, dy: -3 - 1 / sy).intersects(graphDirty) else { continue }
                strokedPathCount += 1
                if stroke.selected {
                    context.addPath(path); context.setStrokeColor(NSColor(Color.primary.opacity(0.75)).cgColor)
                    context.setLineWidth(6); context.strokePath()
                }
                context.addPath(path); context.setStrokeColor(NSColor(stroke.color).cgColor)
                context.setLineWidth(2.5); context.strokePath()
            }
        }
    }
}
