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

    init?(window: NSWindow, invalidate: @escaping @MainActor () -> Void) {
        // Sheets keep their system-owned attachment chrome; their D content
        // already uses the local material. No ordinary system panel is touched.
        guard window.styleMask.contains(.titled), window.sheetParent == nil else { return nil }
        self.window = window
        fullSize = window.styleMask.contains(.fullSizeContentView)
        transparent = window.titlebarAppearsTransparent
        separator = window.titlebarSeparatorStyle
        opaque = window.isOpaque
        background = window.backgroundColor
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        geometry = window.observe(\.contentLayoutRect, options: [.new]) { _, _ in
            MainActor.assumeIsolated { invalidate() }
        }
    }

    func update(palette: WorkbenchPalette) {
        guard let window, !restored else { return }
        let color = NSColor(palette.canvasColor)
        if window.backgroundColor != color { window.backgroundColor = color }
        appliedBackground = color
        // SwiftUI owns preferred/system appearance. Do not pin the native window
        // to today's resolved scheme, which would stop following system changes.
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
        guard let window else { return }
        if window.backgroundColor == appliedBackground { window.backgroundColor = background }
        if window.isOpaque { window.isOpaque = opaque }
        if window.titlebarSeparatorStyle == .none { window.titlebarSeparatorStyle = separator }
        if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = transparent }
        if !fullSize { window.styleMask.remove(.fullSizeContentView) }
    }
    isolated deinit { restore() }
}
