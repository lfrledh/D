import AppKit
import SwiftUI

/// Owns only the public chrome properties of the window containing D's canvas.
/// It never replaces the content view, delegate, native buttons or drag policy.
@MainActor final class WorkbenchWindowTitlebar {
    weak var window: NSWindow?
    private let fullSize: Bool
    private let transparent: Bool
    private let separator: NSTitlebarSeparatorStyle
    private let opaque: Bool
    private let background: NSColor
    private var appliedBackground: NSColor?
    private var geometry: NSKeyValueObservation?
    private var restored = false
    private var updating = false
    let surface = WorkbenchTitlebarSurface()
    private let invalidate: @MainActor () -> Void

    init?(window: NSWindow, invalidate: @escaping @MainActor () -> Void) {
        // Sheets keep their system-owned attachment chrome; their D content
        // already uses the local material. No ordinary system panel is touched.
        guard window.styleMask.contains(.titled), window.sheetParent == nil else { return nil }
        self.window = window
        self.invalidate = invalidate
        fullSize = window.styleMask.contains(.fullSizeContentView)
        transparent = window.titlebarAppearsTransparent
        separator = window.titlebarSeparatorStyle
        opaque = window.isOpaque
        background = window.backgroundColor
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        geometry = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshGeometry(); invalidate() }
        }
    }

    func update(palette: WorkbenchPalette, canvas: WorkbenchBackgroundNSView) {
        guard let window, !restored else { return }
        let color = NSColor(palette.canvasColor)
        if window.backgroundColor != color { window.backgroundColor = color }
        appliedBackground = color
        surface.canvas = canvas
        refreshGeometry()
        surface.needsDisplay = true
        // SwiftUI owns preferred/system appearance. Do not pin the native window
        // to today's resolved scheme, which would stop following system changes.
    }

    private func refreshGeometry() {
        guard let window, !restored, !updating else { return }
        updating = true; defer { updating = false }
        // SwiftUI may reapply chrome after creating the Window. Maintain only
        // the properties this owner already owns; leave native controls intact.
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        if !window.isOpaque { window.isOpaque = true }
        guard let content = window.contentView else { return }
        if surface.superview !== content {
            surface.removeFromSuperview()
            content.addSubview(surface, positioned: .above, relativeTo: nil)
        }
        let band = frame(in: content)
        surface.isHidden = band.isEmpty || band.isNull
        if !surface.isHidden && surface.frame != band { surface.frame = band }
        surface.needsDisplay = true
    }

    /// Window coordinates, including toolbars/full screen, are supplied by AppKit.
    /// Only the background enters the reserved strip; content keeps its safe area.
    func frame(in view: NSView) -> CGRect {
        guard let window, view.window === window, let content = window.contentView else { return .zero }
        let full = content.convert(content.bounds, to: nil)
        let layout = window.contentLayoutRect
        let strip = CGRect(x: full.minX, y: max(full.minY, layout.maxY), width: full.width,
                           height: max(0, full.maxY - max(full.minY, layout.maxY)))
        return view.convert(strip, from: nil).intersection(view.bounds)
    }

    func restore() {
        guard !restored else { return }; restored = true
        geometry?.invalidate(); geometry = nil
        surface.canvas = nil; surface.removeFromSuperview()
        guard let window else { return }
        if window.backgroundColor == appliedBackground { window.backgroundColor = background }
        if window.isOpaque { window.isOpaque = opaque }
        if window.titlebarSeparatorStyle == .none { window.titlebarSeparatorStyle = separator }
        if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = transparent }
        if !fullSize { window.styleMask.remove(.fullSizeContentView) }
    }
    isolated deinit { restore() }
}

/// Continue D's root background behind the native floating controls. This is
/// not a glass plate: no separate tint, blur, refraction or sampled child host.
/// The shallow canvas may be clipped below the titlebar, so the continuation
/// belongs to the real content host. AppKit still owns all native interactions.
@MainActor final class WorkbenchTitlebarSurface: NSView {
    weak var canvas: WorkbenchBackgroundNSView?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // This opaque continuation owns only the reserved titlebar strip.
        // AppKit otherwise allows its visible drawing region to span the host.
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    #if DEBUG
    private var recordedDraw = false
    #endif
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, canvas.window === window, let c = NSGraphicsContext.current?.cgContext else { return }
        let coordinates = canvas.owner?.coordinates(for: self) ?? (rect: bounds, viewport: bounds.size)
        WorkbenchLocalRenderer.draw(in: c, size: bounds.size, rect: coordinates.rect,
            viewport: coordinates.viewport, image: canvas.owner?.image,
            canvas: canvas.palette.canvas, panel: canvas.palette.panel,
            strength: 0, glass: false, refraction: false)
        #if DEBUG
        if !recordedDraw, window?.isVisible == true,
           UUID(uuidString: ProcessInfo.processInfo.environment["D_UI_TEST_SESSION"] ?? "") != nil {
            recordedDraw = true
            print("D_TITLEBAR_SURFACE pid=\(ProcessInfo.processInfo.processIdentifier) frame=\(frame) visible=\(visibleRect) transparent=\(window?.titlebarAppearsTransparent == true) opaque=\(window?.isOpaque == true)")
        }
        #endif
    }
}
