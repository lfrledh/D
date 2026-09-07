import AppKit
import ImageIO
import SwiftUI

/// Preview pixels are disposable. The project keeps the original file as its source of truth.
actor ArtworkPreviewDecoder {
    static let shared = ArtworkPreviewDecoder()
    private var thumbnails: [URL: CGImage] = [:]

    func decode(_ url: URL, thumbnail: Bool) -> CGImage? {
        if thumbnail, let cached = thumbnails[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let image: CGImage?
        if thumbnail {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 144,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        if thumbnail, let image {
            // This cache never contains originals, and stays bounded as projects change.
            if thumbnails.count >= 80 { thumbnails.removeAll(keepingCapacity: true) }
            thumbnails[url] = image
        }
        return image
    }
}

struct ArtworkThumbnail: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await ArtworkPreviewDecoder.shared.decode(url, thumbnail: true)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

enum ArtworkZoom: String, CaseIterable {
    case fit = "适合窗口"
    case actual = "100%"
}

struct ArtworkCanvas: View {
    let url: URL
    let label: String
    @State private var image: CGImage?
    @State private var loadFailed = false
    @State private var zoom: ArtworkZoom = .fit
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .bottom) {
            // A neutral, opaque surface keeps surrounding glass from changing artwork contrast.
            Color(nsColor: .underPageBackgroundColor)
            if let image {
                PixelCanvas(image: image, zoom: zoom)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("artwork-canvas")
                zoomControls.padding(.bottom, 20)
            } else if loadFailed {
                ContentUnavailableView("无法读取这张作品", systemImage: "photo.badge.exclamationmark",
                    description: Text("请检查项目所在磁盘是否已连接，并尝试重新打开项目。"))
            } else {
                ProgressView("正在读取作品…")
            }
        }
        .task(id: url) {
            image = nil
            loadFailed = false
            let loaded = await ArtworkPreviewDecoder.shared.decode(url, thumbnail: false)
            guard !Task.isCancelled else { return }
            image = loaded
            loadFailed = loaded == nil
        }
    }

    @ViewBuilder private var zoomControls: some View {
        if reduceTransparency {
            zoomButtons
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().stroke(.separator.opacity(0.5)))
        } else {
            GlassEffectContainer(spacing: 16) {
                zoomButtons.padding(6).glassEffect(.regular, in: .capsule)
            }
        }
    }

    private var zoomButtons: some View {
        HStack(spacing: 2) {
            ForEach(ArtworkZoom.allCases, id: \.self) { value in
                Button {
                    zoom = value
                } label: {
                    Text(value.rawValue)
                        .font(.callout.weight(zoom == value ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(zoom == value ? Color.primary.opacity(0.10) : .clear,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(value == .fit ? KeyEquivalent("0") : KeyEquivalent("1"), modifiers: .command)
                .accessibilityIdentifier(value == .fit ? "zoom-fit" : "zoom-actual")
                .accessibilityAddTraits(zoom == value ? .isSelected : [])
                .help(value == .actual ? "每个图片像素对应一个屏幕像素；拖动图片可平移（⌘ 1）" : "完整显示作品（⌘ 0）")
            }
        }
    }
}

/// Native scroll and mouse handling, including backing-scale changes between displays.
struct PixelCanvas: NSViewRepresentable {
    let image: CGImage
    let zoom: ArtworkZoom
    var synchronizedPan: Binding<CGPoint>? = nil

    func makeNSView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = CanvasDocumentView()
        scroll.setImage(image, zoom: zoom)
        configurePan(scroll)
        return scroll
    }

    func updateNSView(_ scroll: CanvasScrollView, context: Context) {
        scroll.setImage(image, zoom: zoom)
        configurePan(scroll)
    }

    private func configurePan(_ scroll: CanvasScrollView) {
        guard let synchronizedPan else { scroll.panChanged = nil; return }
        scroll.setNormalizedPan(synchronizedPan.wrappedValue)
        scroll.panChanged = { point in
            // AppKit may report bounds during SwiftUI layout. Publish on the next turn.
            DispatchQueue.main.async {
                if abs(synchronizedPan.wrappedValue.x - point.x) > 0.0001 ||
                    abs(synchronizedPan.wrappedValue.y - point.y) > 0.0001 {
                    synchronizedPan.wrappedValue = point
                }
            }
        }
    }
}

final class CanvasScrollView: NSScrollView {
    private var pixels: CGImage?
    private var zoom: ArtworkZoom = .fit
    var panChanged: ((CGPoint) -> Void)?
    private var normalizedPan = CGPoint(x: 0.5, y: 0.5)
    private var arranging = false

    func setNormalizedPan(_ point: CGPoint) {
        normalizedPan = point
        guard zoom == .actual, let document = documentView as? CanvasDocumentView else { return }
        arranging = true
        defer { arranging = false }
        var proposed = contentView.bounds
        proposed.origin = CGPoint(x: document.imageRect.minX + document.imageRect.width * point.x - proposed.width / 2,
                                  y: document.imageRect.minY + document.imageRect.height * point.y - proposed.height / 2)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard !arranging, zoom == .actual, let document = documentView as? CanvasDocumentView,
              document.imageRect.width > 0, document.imageRect.height > 0 else { return }
        normalizedPan = CGPoint(x: min(1, max(0, (clipView.bounds.midX - document.imageRect.minX) / document.imageRect.width)),
                                y: min(1, max(0, (clipView.bounds.midY - document.imageRect.minY) / document.imageRect.height)))
        panChanged?(normalizedPan)
    }

    func setImage(_ image: CGImage, zoom: ArtworkZoom) {
        let changed = pixels !== image || self.zoom != zoom
        pixels = image
        self.zoom = zoom
        guard let document = documentView as? CanvasDocumentView else { return }
        if changed {
            document.image = image
            arrangeImage(center: true)
        }
    }

    override func layout() {
        super.layout()
        arrangeImage(center: zoom == .fit)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        arrangeImage(center: true)
    }

    private func arrangeImage(center: Bool) {
        guard let pixels, let document = documentView as? CanvasDocumentView else { return }
        arranging = true
        defer { arranging = false }
        let available = contentView.bounds.size
        guard available.width > 0, available.height > 0 else { return }
        let scale: CGFloat
        if zoom == .actual {
            scale = 1 / (window?.backingScaleFactor ?? 1)
        } else {
            scale = min(max(available.width - 64, 1) / CGFloat(pixels.width),
                        max(available.height - 96, 1) / CGFloat(pixels.height))
        }
        let size = NSSize(width: CGFloat(pixels.width) * scale, height: CGFloat(pixels.height) * scale)
        let documentSize = NSSize(width: max(available.width, size.width + 64),
                                  height: max(available.height, size.height + 96))
        if document.frame.size != documentSize { document.setFrameSize(documentSize) }
        document.imageRect = NSRect(x: (documentSize.width - size.width) / 2,
                                    y: (documentSize.height - size.height) / 2 - 12,
                                    width: size.width, height: size.height)
        if center {
            contentView.scroll(to: NSPoint(x: (documentSize.width - available.width) / 2,
                                           y: (documentSize.height - available.height) / 2))
            reflectScrolledClipView(contentView)
        }
    }
}

private final class CanvasDocumentView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var imageRect = NSRect.zero { didSet { if oldValue != imageRect { needsDisplay = true } } }
    private var dragStart: NSPoint?
    private var scrollStart = NSPoint.zero
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        // NSImage bridges the decoded pixels for drawing only; it is never project storage.
        NSImage(cgImage: image, size: imageRect.size).draw(in: imageRect,
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high])
    }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        scrollStart = enclosingScrollView?.contentView.bounds.origin ?? .zero
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let scroll = enclosingScrollView else { return }
        let delta = NSPoint(x: event.locationInWindow.x - dragStart.x,
                            y: event.locationInWindow.y - dragStart.y)
        var proposed = scroll.contentView.bounds
        proposed.origin = NSPoint(x: scrollStart.x - delta.x, y: scrollStart.y + delta.y)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}
