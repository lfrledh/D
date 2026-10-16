import AppKit
import Darwin
import Synchronization
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An optional application preference. Absence means the historical opaque blend.
/// Neither this reference nor its pixels enter a project or inference request.
struct WorkbenchLocalAppearance: Codable, Equatable, Sendable {
    enum Material: String, Codable, Sendable { case glass, solid }
    var version = 1
    var material: Material = .glass
    var strength = 0.55
    var wallpaper: String?
    var isValid: Bool {
        version == 1 && strength.isFinite && (0...1).contains(strength)
            && (wallpaper == nil || Self.isOwnedName(wallpaper!))
    }
    static func isOwnedName(_ name: String) -> Bool {
        name.hasSuffix(".png") && UUID(uuidString: String(name.dropLast(4))) != nil
            && !name.contains("/")
    }
}

enum WorkbenchWallpaperError: Error { case unavailable, invalidImage, tooLarge, changedOwner, saveFailed }

/// Exact ownership begins only after exclusive mkdir succeeds. A failed writer
/// may leave partial bytes, but only inside this task's unpublished directory.
enum WorkbenchWallpaperPublication {
    static func publish(_ data: Data, to destination: URL,
                        write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".prepare-" + UUID().uuidString)
        guard mkdir(stage.path, 0o700) == 0 else { throw WorkbenchWallpaperError.saveFailed }
        defer { try? FileManager.default.removeItem(at: stage) }
        let file = stage.appendingPathComponent("image.png")
        try write(data, file)
        // Same-volume rename refuses an existing destination; no replacement.
        try FileManager.default.moveItem(at: file, to: destination)
    }
}

#if DEBUG
enum WorkbenchBackgroundCounters {
    struct Snapshot: Sendable { var decodes = 0; var blurs = 0; var draws = 0 }
    private static let value = Mutex(Snapshot())
    static var snapshot: Snapshot { value.withLock { $0 } }
    static func decode() { value.withLock { $0.decodes += 1 } }
    static func blur() { value.withLock { $0.blurs += 1 } }
    static func draw() { value.withLock { $0.draws += 1 } }
}
#endif

/// Serial preparation bounds concurrent decoding to one. ImageIO downsamples before
/// decoding; no full-resolution NSImage, network, asset store or window capture.
actor WorkbenchWallpaperDecoder {
    static let shared = WorkbenchWallpaperDecoder()
    static let maximumDimension = 2048
    func prepare(_ url: URL) throws -> Data { try Task.checkCancellation(); return try Self.prepareFile(url) }
    func textures(_ url: URL, blur: Bool) throws -> (CGImage, CGImage?) {
        try Task.checkCancellation()
        let data = try Self.prepareFile(url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WorkbenchWallpaperError.invalidImage }
        try Task.checkCancellation()
        return (image, blur ? WorkbenchLocalRenderer.blur(image) : nil)
    }
    nonisolated static func prepareFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 64 * 1024 * 1024 else { throw WorkbenchWallpaperError.tooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
              CGImageSourceGetCount(source) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 65536, h <= 65536, Double(w) * Double(h) <= 120_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let context = WorkbenchLocalRenderer.bitmap(width: image.width, height: image.height) else {
            throw WorkbenchWallpaperError.invalidImage
        }
        #if DEBUG
        WorkbenchBackgroundCounters.decode()
        #endif
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = context.makeImage() else { throw WorkbenchWallpaperError.invalidImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw WorkbenchWallpaperError.invalidImage
        }
        CGImageDestinationAddImage(destination, converted, nil)
        guard CGImageDestinationFinalize(destination) else { throw WorkbenchWallpaperError.invalidImage }
        return data as Data
    }
}

/// Production renderer also used by the offscreen pixel checks. Only a prepared
/// D-owned CGImage is accepted. No backdrop APIs or content snapshots are used.
enum WorkbenchLocalRenderer {
    static func bitmap(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    static func color(_ hex: String) -> CGColor {
        let n = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(srgbRed: CGFloat((n >> 16) & 255) / 255,
            green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
    }
    static func mapping(image: CGSize, viewport: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = max(viewport.width / image.width, viewport.height / image.height)
        return CGRect(x: (viewport.width - image.width * scale) / 2,
                      y: (viewport.height - image.height * scale) / 2,
                      width: image.width * scale, height: image.height * scale)
    }
    static func blur(_ image: CGImage) -> CGImage? {
        #if DEBUG
        WorkbenchBackgroundCounters.blur()
        #endif
        let input = CIImage(cgImage: image)
        // One bounded shared blur per source, not one texture per component. A CPU
        // Core Image context also works without a visible desktop/Metal device.
        let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        return context.createCGImage(input.clampedToExtent().applyingFilter("CIGaussianBlur",
            parameters: [kCIInputRadiusKey: 0.65]).cropped(to: input.extent), from: input.extent)
    }
    /// Geometry only: no pixels or content snapshots. A rectangular hole known
    /// to be inside the inner contour lets Core Graphics skip that image area
    /// before applying the curved ring mask. Otherwise it samples the entire
    /// plate for every thin ring, including the masked-out centre.
    struct RefractionRing { let path: CGPath; let clips: [CGRect] }
    final class RefractionGeometry {
        private var size: CGSize = .zero
        private var sourceSize: CGSize = .zero
        private var rings: [RefractionRing] = []
        func resolve(size: CGSize, rect: CGRect, contour: ((CGRect, CGFloat) -> CGPath)?) -> [RefractionRing] {
            if self.size == size && sourceSize == rect.size && !rings.isEmpty { return rings }
            self.size = size; sourceSize = rect.size
            let bounds = CGRect(origin: .zero, size: size)
            let scale = min(size.width / rect.width, size.height / rect.height)
            let rim = min(12, min(rect.width, rect.height) / 4)
            let outline = contour ?? { box, inset in CGPath(rect: box.insetBy(dx: inset, dy: inset), transform: nil) }
            rings = (0..<12).map { i in
                let inner = outline(bounds, CGFloat(i + 1) * rim / 12 * scale)
                let path = CGMutablePath(); path.addPath(outline(bounds, CGFloat(i) * rim / 12 * scale)); path.addPath(inner)
                var low: CGFloat = 0, high = min(inner.boundingBoxOfPath.width, inner.boundingBoxOfPath.height) / 2
                var hole = CGRect.null
                for _ in 0..<9 {
                    let inset = (low + high) / 2
                    let candidate = inner.boundingBoxOfPath.insetBy(dx: inset, dy: inset)
                    if CGPath(rect: candidate, transform: nil).subtracting(inner, using: .evenOdd).isEmpty {
                        hole = candidate; high = inset
                    } else { low = inset }
                }
                // Inset a little further to avoid the path boolean operation's
                // curve tolerance at the boundary. The original ring mask stays.
                hole = hole.insetBy(dx: 1, dy: 1).intersection(bounds)
                guard !hole.isNull, !hole.isEmpty else { return RefractionRing(path: path, clips: [bounds]) }
                let clips = [CGRect(x: 0, y: 0, width: bounds.width, height: hole.minY),
                    CGRect(x: 0, y: hole.maxY, width: bounds.width, height: bounds.maxY - hole.maxY),
                    CGRect(x: 0, y: hole.minY, width: hole.minX, height: hole.height),
                    CGRect(x: hole.maxX, y: hole.minY, width: bounds.maxX - hole.maxX, height: hole.height)]
                return RefractionRing(path: path, clips: clips.filter { !$0.isEmpty })
            }
            return rings
        }
    }

    /// rect and viewport use top-left workspace points, independent of desktop
    /// position and graph coordinates. Edges clamp via an opaque base + aspect fill.
    static func draw(in c: CGContext, size: CGSize, rect: CGRect, viewport: CGSize,
                     image: CGImage?, canvas: String, panel: String, strength: Double,
                     glass: Bool, refraction: Bool = true,
                     contour: ((CGRect, CGFloat) -> CGPath)? = nil,
                     geometry: RefractionGeometry? = nil) {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        c.saveGState(); defer { c.restoreGState() }
        c.setFillColor(color(canvas)); c.fill(bounds)
        if let image {
            let mapped = mapping(image: CGSize(width: image.width, height: image.height), viewport: viewport)
            let sx = size.width / rect.width, sy = size.height / rect.height
            func sample(clip: CGRect, lens: CGPath? = nil, magnification: CGFloat = 1) {
                c.saveGState()
                // Ring samples must not blend the canvas reset and translucent
                // wallpaper separately at fractional boundaries.
                // The outer rounded shell owns its normal edge antialiasing.
                c.setAllowsAntialiasing(false); c.setShouldAntialias(false); c.clip(to: clip)
                if let lens { c.addPath(lens); c.clip(using: .evenOdd) }
                // Each displaced sample composites once over D's canvas. Reusing
                // the previous sample would accumulate alpha at the rim/corners.
                c.setFillColor(color(canvas)); c.fill(bounds)
                var target = CGRect(x: (mapped.minX - rect.minX) * sx,
                    y: (mapped.minY - rect.minY) * sy, width: mapped.width * sx, height: mapped.height * sy)
                // A shallow convex lens enlarges only the D background near its
                // curved shoulder. The clear central content remains undistorted.
                target = CGRect(x: size.width / 2 + (target.minX - size.width / 2) * magnification,
                    y: size.height / 2 + (target.minY - size.height / 2) * magnification,
                    width: target.width * magnification, height: target.height * magnification)
                // CGContext image coordinates are bottom-up; the native view is flipped.
                c.translateBy(x: target.minX, y: target.maxY); c.scaleBy(x: 1, y: -1)
                c.draw(image, in: CGRect(origin: .zero, size: target.size)); c.restoreGState()
            }
            sample(clip: bounds)
            if glass && refraction {
                // Follow the actual Capsule/Circle/rounded panel outline. Each
                // ring resets its own sample, so translucent wallpaper cannot
                // accumulate. Twelve shared-source samples, no per-control texture.
                let rings = geometry?.resolve(size: size, rect: rect, contour: contour)
                let rim = min(12, min(rect.width, rect.height) / 4)
                let outline = contour ?? { box, inset in CGPath(rect: box.insetBy(dx: inset, dy: inset), transform: nil) }
                for i in 0..<12 {
                    let ring: CGPath
                    if let rings { ring = rings[i].path }
                    else {
                        let path = CGMutablePath()
                        path.addPath(outline(bounds, CGFloat(i) * rim / 12 * min(sx, sy)))
                        path.addPath(outline(bounds, CGFloat(i + 1) * rim / 12 * min(sx, sy)))
                        ring = path
                    }
                    let shoulder = sin((CGFloat(i) + 0.5) / 12 * .pi)
                    let shift = shoulder * 5.5 * min(1, max(0, strength))
                    let magnification = 1 + shift / max(1, max(rect.width, rect.height) / 2)
                    for clip in rings?[i].clips ?? [bounds] { sample(clip: clip, lens: ring, magnification: magnification) }
                }
            }
        }
        if glass {
            // The saved strength is the user's transparency control: opaque at
            // zero, up to 82% of the clear local background at one. Only this
            // decorative plate is composited; glyphs, editors and media stay sharp.
            c.setFillColor(color(panel).copy(alpha: 1 - min(1,max(0,strength)) * 0.82)!)
            c.fill(bounds)
        }
    }
}

/// One prepared immutable image pair per appearance preference owner. Windows
/// reuse pixels, never coordinates or view ownership. No process-wide cache.
@MainActor final class WorkbenchBackgroundTextures {
    struct Entry {
        let url: URL
        let blur: Bool
        let image: CGImage
        let blurred: CGImage?
    }
    private(set) var entry: Entry?
    private(set) var generation = UUID()
    func clear() { entry = nil; generation = UUID() }
    func store(_ value: Entry, generation: UUID) {
        guard self.generation == generation else { return }
        entry = value
    }
}

/// Window-local resource owner. Position notifications never publish to SwiftUI
/// or business state. At most two 2048px images are retained, independent of nodes.
@MainActor final class WorkbenchBackgroundOwner {
    weak var root: WorkbenchBackgroundNSView?
    let surfaces = NSHashTable<WorkbenchBackgroundNSView>.weakObjects()
    let readability = WorkbenchReadabilityRegistry()
    private(set) var image: CGImage?
    private(set) var blurred: CGImage?
    private(set) var decodeCount = 0
    private(set) var blurCount = 0
    private(set) var drawCount = 0
    private(set) var key: URL?
    private var preparesBlur = true
    private var textures: WorkbenchBackgroundTextures?
    private var textureGeneration: UUID?
    private var request = UUID()
    private var preparation: Task<Void, Never>?
    var failure: (() -> Void)?
    func load(_ url: URL?, blur: Bool = true, cache: WorkbenchBackgroundTextures? = nil) {
        guard key != url || preparesBlur != blur || textures !== cache
                || textureGeneration != cache?.generation else { return }
        preparation?.cancel(); preparation = nil
        textures = cache; textureGeneration = cache?.generation
        key = url; preparesBlur = blur; let ticket = UUID(); request = ticket
        image = nil; blurred = nil
        if let url, let ready = cache?.entry, ready.url == url, ready.blur == blur {
            // Synchronous adoption during the NSView update, before its first
            // display. Opening a sheet does not restart background preparation.
            image = ready.image; blurred = ready.blurred
            invalidate(); return
        }
        invalidate()
        guard let url else { return }
        let generation = cache?.generation
        preparation = Task { [weak self] in
            do {
                let (decoded, preparedBlur) = try await WorkbenchWallpaperDecoder.shared.textures(url, blur: blur)
                guard let self, request == ticket, key == url, !Task.isCancelled,
                      cache?.generation == generation else { return }
                decodeCount += 1
                image = decoded; blurred = preparedBlur
                if preparedBlur != nil { blurCount += 1 }
                if let cache, let generation {
                    cache.store(.init(url: url, blur: blur, image: decoded, blurred: preparedBlur), generation: generation)
                }
                invalidate()
            } catch {
                guard let self, request == ticket, !Task.isCancelled,
                      cache?.generation == generation else { return }
                failure?()
            }
        }
    }
    func invalidate() { for view in surfaces.allObjects { view.needsDisplay = true; view.titlebar?.surface.needsDisplay = true } }
    func coordinateRoot(in window: NSWindow?) -> NSView? {
        guard let root, root.window === window else { return window?.contentView }
        return root.stylesWindowTitlebar ? window?.contentView : root
    }
    func coordinates(for view: NSView) -> (rect: CGRect, viewport: CGSize) {
        guard let root = coordinateRoot(in: view.window) else { return (view.bounds, view.bounds.size) }
        let converted = view.convert(view.bounds, to: root)
        let rect = CGRect(x: converted.minX - root.bounds.minX,
            y: root.isFlipped ? converted.minY - root.bounds.minY : root.bounds.maxY - converted.maxY,
            width: converted.width, height: converted.height)
        return (rect, root.bounds.size)
    }
    func didDraw() { drawCount += 1 }
    var retainedBytes: Int { [image, blurred].compactMap { $0 }.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
}

private struct WorkbenchBackgroundKey: EnvironmentKey {
    static let defaultValue: WorkbenchBackgroundOwner? = nil
}
extension EnvironmentValues {
    var workbenchBackground: WorkbenchBackgroundOwner? {
        get { self[WorkbenchBackgroundKey.self] }
        set { self[WorkbenchBackgroundKey.self] = newValue }
    }
}

@MainActor final class WorkbenchBackgroundNSView: NSView {
    var owner: WorkbenchBackgroundOwner? {
        didSet {
            if oldValue !== owner { oldValue?.readability.remove(self); owner?.readability.configure(self) }
        }
    }
    var isCanvas = false
    var isGeometryOnly = false
    var palette = WorkbenchPalette.defaultLight
    var strength = 0.55
    var drawsGlass = true { didSet { if oldValue != drawsGlass { owner?.readability.configure(self) } } }
    var surfaceGroup: String? = nil
    var surfaceRole = WorkbenchSurfaceRole.panel
    var readability = WorkbenchReadabilitySettings() {
        didSet { if oldValue != readability { owner?.readability.configure(self); needsDisplay = true } }
    }
    var contour: ((CGRect, CGFloat) -> CGPath)? { didSet { refractionGeometry = .init() } }
    private var refractionGeometry = WorkbenchLocalRenderer.RefractionGeometry()
    var stylesWindowTitlebar = false
    var legacyTitlebarBlend: Double?
    private(set) var titlebar: WorkbenchWindowTitlebar?
    private var observers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { !isGeometryOnly }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeGeometry() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); synchronizeTitlebar(); observeGeometry()
    }
    func synchronizeTitlebar() {
        if titlebar?.window !== window || !stylesWindowTitlebar || !isCanvas {
            let previous = titlebar; titlebar = nil; previous?.restore()
        }
        guard isCanvas, stylesWindowTitlebar, let window else { return }
        if titlebar == nil {
            titlebar = WorkbenchWindowTitlebar(window: window) { [weak self] in self?.needsDisplay = true }
        }
        titlebar?.update(palette: palette, canvas: self)
    }
    func releaseTitlebar() {
        let previous = titlebar; titlebar = nil; stylesWindowTitlebar = false; previous?.restore()
    }
    private func observeGeometry() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        var ancestor: NSView? = self
        while let view = ancestor {
            view.postsFrameChangedNotifications = true; view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.needsDisplay = true; if let self { self.owner?.readability.update(self) }; if self?.isCanvas == true { self?.owner?.invalidate() } }
                })
            }
            ancestor = view.superview
        }
    }
    isolated deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    override func layout() {
        super.layout(); needsDisplay = true; owner?.readability.update(self)
        #if DEBUG
        WorkbenchCategoryUpdateProbe.phase("background-layout")
        #endif
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !isGeometryOnly else { return }
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        owner?.didDraw()
        #if DEBUG
        WorkbenchBackgroundCounters.draw()
        if window?.isVisible == true && !isHiddenOrHasHiddenAncestor {
            WorkbenchCategoryUpdateProbe.phase("visible-background-draw")
        }
        #endif
        let coordinates = owner?.coordinates(for: self) ?? (rect: bounds, viewport: bounds.size)
        let enhancement = owner?.readability.effect(for: self) ?? .none
        WorkbenchLocalRenderer.draw(in: c, size: bounds.size, rect: coordinates.rect, viewport: coordinates.viewport,
            image: isCanvas ? owner?.image : (drawsGlass ? owner?.blurred : nil),
            canvas: isCanvas || drawsGlass ? palette.canvas : palette.panel, panel: palette.panel,
            strength: strength, glass: !isCanvas && drawsGlass, refraction: !enhancement.contained, contour: contour, geometry: refractionGeometry)
        WorkbenchReadabilityRegistry.paint(enhancement, in: c, view: self)

    }
}

struct WorkbenchLocalSurface: NSViewRepresentable {
    let owner: WorkbenchBackgroundOwner?
    let palette: WorkbenchPalette
    var isCanvas = false
    var strength = 0.55
    var drawsGlass = true
    var surfaceGroup: String? = nil
    var surfaceRole = WorkbenchSurfaceRole.panel
    var readability = WorkbenchReadabilitySettings()
    var contour: ((CGRect, CGFloat) -> CGPath)? = nil
    var prepare: (() -> Void)? = nil
    var stylesWindowTitlebar = false
    var legacyTitlebarBlend: Double? = nil
    func makeNSView(context: Context) -> WorkbenchBackgroundNSView {
        let view = WorkbenchBackgroundNSView(); view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: WorkbenchBackgroundNSView, context: Context) {
        prepare?()
        if view.owner !== owner { view.owner?.readability.remove(view) }
        view.owner = owner; view.palette = palette; view.isCanvas = isCanvas
        view.strength = strength; view.drawsGlass = drawsGlass; view.contour = contour
        view.surfaceGroup = surfaceGroup; view.surfaceRole = surfaceRole; view.readability = readability
        view.stylesWindowTitlebar = stylesWindowTitlebar; view.legacyTitlebarBlend = legacyTitlebarBlend
        view.synchronizeTitlebar()
        owner?.surfaces.add(view)
        if isCanvas, owner?.root !== view { owner?.root = view; owner?.invalidate() }
        view.needsDisplay = true; owner?.readability.update(view)
    }
    static func dismantleNSView(_ view: WorkbenchBackgroundNSView, coordinator: ()) {
        view.releaseTitlebar(); view.owner?.readability.remove(view)
    }
}

struct WorkbenchCanvasModifier: ViewModifier {
    let state: ChatDisplayPreferencesState
    var stylesWindowTitlebar = false
    @State private var owner = WorkbenchBackgroundOwner()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var usesCanvasBlend: Bool {
        WorkbenchEffectsPolicy(appearance: state.preferences.resolvedAppearance,
            reduceMotion: false, reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased).usesCanvasBlend
    }
    private var preparesBlur: Bool {
        state.preferences.resolvedAppearance.local?.material == .glass && usesCanvasBlend
    }
    func body(content: Content) -> some View {
        let appearance = state.preferences.resolvedAppearance
        let palette = appearance.palette(for: state.preferences.preferredColorScheme ?? scheme)
        content.environment(\.workbenchBackground, owner)
            .environment(\.workbenchAppearanceState, state)
            .background {
                WorkbenchLocalSurface(owner: owner, palette: palette, isCanvas: true,
                    strength: appearance.local?.strength ?? 0, drawsGlass: preparesBlur,
                    prepare: prepare, stylesWindowTitlebar: stylesWindowTitlebar,
                    legacyTitlebarBlend: appearance.local == nil ? (usesCanvasBlend ? appearance.backgroundTransparency : 0) : nil)
                    .ignoresSafeArea(.container, edges: stylesWindowTitlebar ? .top : [])
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .onAppear {
                if state.preferences.appearance?.local?.wallpaper != nil && state.wallpaperURL() == nil {
                    state.markWallpaperUnavailable()
                }
            }
            .onDisappear { owner.load(nil) }
    }
    private func prepare() {
        owner.failure = { [weak state] in state?.markWallpaperUnavailable() }
        owner.load(state.wallpaperURL(), blur: preparesBlur, cache: state.backgroundTextures)
    }

}
