import AppKit
import AVKit
import DInference
@testable import DWorkbench
import ImageIO
import Metal
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import UI

private actor LocalGlassNoInference: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw WorkflowIssue("Local glass fixture never submits inference")
    }
}

@MainActor private final class TitlebarCoordinateHost: NSView {
    var flipsY = false
    override var isFlipped: Bool { flipsY }
}

@MainActor private final class TitlebarLayoutWindow: NSWindow {
    var testLayout: CGRect?
    override var contentLayoutRect: NSRect { testLayout ?? super.contentLayoutRect }
}

@MainActor private final class DeferredChromeWindow: NSWindow {
    var buttonsReady = true
    var replacements: [NSWindow.ButtonType: NSButton] = [:]
    override func standardWindowButton(_ type: NSWindow.ButtonType) -> NSButton? {
        guard buttonsReady else { return nil }
        return replacements[type] ?? super.standardWindowButton(type)
    }
}

@MainActor private final class DragRecordingWindow: NSWindow {
    var dragEvents: [NSEvent] = []
    override var isKeyWindow: Bool { true }
    override func performDrag(with event: NSEvent) { dragEvents.append(event) }
}

@Suite("D-owned local glass", .serialized)
@MainActor struct WorkbenchLocalGlassTests {
    private func temporary() throws -> URL {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let url = URL(fileURLWithPath: base).appendingPathComponent("local-glass-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func pattern(_ variant: Int = 0, width: Int = 160, height: Int = 100, alpha: Bool = false) throws -> CGImage {
        let c = try #require(WorkbenchLocalRenderer.bitmap(width: width, height: height))
        for y in 0..<height { for x in 0..<width {
            let stripe = (x / 4 + y / 7) % 2 == 0
            c.setFillColor(CGColor(srgbRed: variant == 0 ? (stripe ? 0.4 + 0.55 * CGFloat(x) / CGFloat(width) : 0.05 + 0.2 * CGFloat(x) / CGFloat(width)) : 0.1,
                green: CGFloat(y) / CGFloat(height), blue: variant == 1 ? (stripe ? 0.95 : 0.1) : 0.2,
                alpha: alpha && x < width / 3 ? 0 : 1))
            c.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return try #require(c.makeImage())
    }
    private func png(_ image: CGImage, at url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
    private func render(_ image: CGImage?, rect: CGRect = CGRect(x: 20, y: 10, width: 80, height: 60),
                        viewport: CGSize = CGSize(width: 160, height: 100), glass: Bool = true,
                        refract: Bool = true, external: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)) throws -> [UInt8] {
        let c = try #require(WorkbenchLocalRenderer.bitmap(width: Int(rect.width), height: Int(rect.height)))
        c.setFillColor(external); c.fill(CGRect(origin: .zero, size: rect.size))
        WorkbenchLocalRenderer.draw(in: c, size: rect.size, rect: rect, viewport: viewport, image: image,
            canvas: "#111D1A", panel: "#1D2B25", strength: 0.55, glass: glass, refraction: refract)
        let ptr = try #require(c.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: ptr, count: c.bytesPerRow * c.height))
    }
    private func rootPixel(_ canvas: WorkbenchBackgroundNSView, external: CGColor) throws -> [UInt8] {
        let c = try #require(WorkbenchLocalRenderer.bitmap(width: Int(canvas.bounds.width), height: Int(canvas.bounds.height)))
        c.setFillColor(external); c.fill(canvas.bounds)
        c.translateBy(x: 0, y: CGFloat(c.height)); c.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(c.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: c.bytesPerRow * c.height))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func floatingChromeKeepsRootOpaqueAndPreservesLegacyPreferences(scheme: ColorScheme) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ChatDisplayPreferencesState(appearanceDirectory: root)
        var value = state.preferences; value.appearance?.local = nil
        try #require(state.update(value))
        func content() -> some View {
            Text("Legacy").frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea(.container, edges: .top)
                .modifier(WorkbenchCanvasModifier(state: state, stylesWindowTitlebar: true)).environment(\.colorScheme, scheme)
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        var images: [[UInt8]] = []
        for blend in [0.0, 0.83, 1.0] {
            value.appearance?.backgroundTransparency = blend; try #require(state.update(value)); host.rootView = content()
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let canvas = try #require(children(host).compactMap { $0 as? WorkbenchBackgroundNSView }.first { $0.isCanvas })
            #expect(canvas.legacyTitlebarBlend == blend && !canvas.drawsGlass && window.isOpaque)
            #expect(state.preferences == value && state.preferences.appearance?.local == nil)
            let red = try rootPixel(canvas, external: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            let green = try rootPixel(canvas, external: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            #expect(red == green && red.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { $0.element == 255 })
            images.append(red)
        }
        #expect(images[0] == images[1] && images[1] == images[2])
    }

    @Test func floatingChromeMovesRealButtonsAndRestoresAfterFailedFullScreen() async throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentView!.bounds); window.contentView = host
        defer { window.contentView = nil; window.close() }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = try types.map { try #require(window.standardWindowButton($0)) }
        let parents = buttons.map(\.superview), frames = buttons.map(\.frame)
        let originalButtonOrder = parents[0]?.subviews.filter { view in buttons.contains { $0 === view } }
        let union = buttons.reduce(CGRect.null) { $0.union($1.convert($1.bounds, to: nil)) }
        let owner = WorkbenchBackgroundOwner()
        let canvas = WorkbenchBackgroundNSView(frame: host.bounds); canvas.owner = owner; owner.root = canvas
        canvas.isCanvas = true; canvas.stylesWindowTitlebar = true; host.addSubview(canvas)
        let controls = WorkbenchWindowControlHost(frame: .init(x: 16, y: host.bounds.height - 40, width: union.width + 16, height: 32))
        controls.owner = owner; host.addSubview(controls); controls.bind()
        let chrome = try #require(canvas.titlebar)
        #expect(window.contentView === host && window.styleMask.contains(.titled) && window.isOpaque)
        #expect(buttons.allSatisfy { $0.superview === controls })
        #expect(zip(types, buttons).allSatisfy { window.standardWindowButton($0) === $1 })
        #expect(controls.measuredSize == CGSize(width: union.width + 16, height: max(32, union.height + 16)))
        #expect(buttons.map { $0.frame.size } == frames.map(\.size))
        #expect(abs(buttons.first!.frame.minX - 8) < 0.1)
        #expect(abs(buttons.last!.frame.maxX - (controls.measuredSize.width - 8)) < 0.1)
        #expect(buttons.allSatisfy { controls.bounds.contains($0.frame) })
        // Model the public effect of AppKit restoring controls during a scene update.
        for (button, parent) in zip(buttons, parents) { parent?.addSubview(button) }
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(buttons.allSatisfy { $0.superview === controls })
        let restoredFrames = buttons.map(\.frame)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(buttons.map(\.frame) == restoredFrames)
        let siblingCount = host.superview?.subviews.count
        chrome.refreshGeometry(); chrome.refreshGeometry()
        #expect(host.superview?.subviews.count == siblingCount, "No full-width titlebar or repeated overlay is mounted")
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(zip(buttons, parents).allSatisfy { $0.superview === $1 })
        WorkbenchWindowChrome.fullScreenTransitionFailed(window)
        #expect(buttons.allSatisfy { $0.superview === controls })
        var callbacks = 0; controls.changed = { _, _ in callbacks += 1 }
        controls.report(size: CGSize(width: controls.measuredSize.width + 1, height: controls.measuredSize.height), fullScreen: true)
        chrome.detach(controls)
        await Task.yield(); try await Task.sleep(for: .milliseconds(10))
        #expect(callbacks == 0, "Detached host must not deliver stale full-screen state")
        #expect(parents[0]?.subviews.filter { view in buttons.contains { $0 === view } } == originalButtonOrder)
        #expect(zip(buttons, parents).allSatisfy { $0.superview === $1 } && buttons.map(\.frame) == frames)
        #expect(window.standardWindowButton(.closeButton) === buttons[0])
        canvas.releaseTitlebar()
        #expect(!window.titlebarAppearsTransparent && !window.styleMask.contains(.fullSizeContentView))
    }

    @Test func floatingChromeHandlesLateAndReplacedNativeButtonsWithoutResize() throws {
        let window = DeferredChromeWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentView!.bounds); window.contentView = host
        defer { window.contentView = nil; window.close() }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let originals = try types.map { try #require(window.standardWindowButton($0)) }
        let parents = originals.map(\.superview), frames = originals.map(\.frame)
        window.buttonsReady = false
        let owner = WorkbenchBackgroundOwner()
        let canvas = WorkbenchBackgroundNSView(frame: host.bounds); canvas.owner = owner; owner.root = canvas
        canvas.isCanvas = true; canvas.stylesWindowTitlebar = true; host.addSubview(canvas)
        let controls = WorkbenchWindowControlHost(frame: .init(x: 16, y: 348, width: 84, height: 40))
        controls.owner = owner; host.addSubview(controls); controls.bind()
        #expect(originals.allSatisfy { $0.superview !== controls })
        window.buttonsReady = true
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(originals.allSatisfy { $0.superview === controls })
        let replacements = try types.enumerated().map { index, type in
            let button = try #require(NSWindow.standardWindowButton(type, for: window.styleMask))
            button.frame = frames[index]; parents[index]?.addSubview(button)
            window.replacements[type] = button
            return button
        }
        // Old objects remain at the exact correct frames; identity alone changes.
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(replacements.allSatisfy { $0.superview === controls })
        #expect(originals.allSatisfy { $0.superview == nil })
        canvas.releaseTitlebar()
        #expect(zip(replacements, parents).allSatisfy { $0.superview === $1 })
        #expect(replacements.map(\.frame) == frames)
    }

    @Test func floatingChromeFitsLargerNativeBoundsWithoutScalingOrClosingGaps() throws {
        let window = DeferredChromeWindow(contentRect: .init(x:0,y:0,width:1080,height:680),
            styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame:window.contentView!.bounds); window.contentView = root
        defer { window.contentView = nil; window.close() }
        let types: [NSWindow.ButtonType] = [.closeButton,.miniaturizeButton,.zoomButton]
        let buttons = try types.enumerated().map { index,type in
            let old = try #require(window.standardWindowButton(type))
            let button = try #require(NSWindow.standardWindowButton(type,for:window.styleMask))
            button.frame = CGRect(x:6 + index*38,y:2,width:26,height:30)
            old.superview?.addSubview(button); window.replacements[type] = button
            return button
        }
        let frames = buttons.map(\.frame)
        let union = buttons.reduce(CGRect.null) { $0.union($1.convert($1.bounds,to:nil)) }
        let owner = WorkbenchBackgroundOwner()
        let canvas = WorkbenchBackgroundNSView(frame:root.bounds); canvas.owner=owner; owner.root=canvas
        canvas.isCanvas=true; canvas.stylesWindowTitlebar=true; root.addSubview(canvas)
        let controls = WorkbenchWindowControlHost(frame:.init(x:16,y:600,width:80,height:32))
        controls.owner=owner; root.addSubview(controls); controls.bind()
        #expect(controls.measuredSize == CGSize(width:union.width+16,height:46))
        controls.setFrameSize(controls.measuredSize); controls.chrome?.refreshGeometry()
        #expect(buttons.map { $0.frame.size } == frames.map(\.size))
        #expect(buttons.allSatisfy { controls.bounds.contains($0.frame) })
        #expect(buttons.first?.frame.minX == 8 && buttons.last?.frame.maxX == controls.bounds.maxX-8)
        #expect(buttons[1].frame.minX-buttons[0].frame.maxX == frames[1].minX-frames[0].maxX)
        canvas.releaseTitlebar()
        #expect(buttons.map(\.frame) == frames)
    }

    @Test func floatingChromeClearanceSurvivesRetainedSidebarAndSmallWindow() async throws {
        var preferences = ChatDisplayPreferences(), appearance = WorkbenchAppearance()
        var local = WorkbenchLocalAppearance(); local.material = .solid
        appearance.local = local; preferences.appearance = appearance
        // Same sidebar geometry; solid exposes our public native shape surface.
        // This is not a native Liquid Glass pixel/appearance assertion.
        func content(height: CGFloat, open: Bool) -> some View {
            VStack(spacing:0) {
                Color.clear.frame(height:52)
                RetainedContentHost(content: WorkbenchSidebar(leading:true,expanded:open,title:"Settings",
                    identifier:"clearance-toggle",hostIdentifier:"clearance-content",toggle:{}) { Text("Retained content") },
                    visible:true,identifier:"clearance-workspace")
            }.environment(\.chatDisplayPreferences,preferences)
                .environment(\.workbenchWindowControlSize,CGSize(width:80,height:height))
        }
        let host = NSHostingView(rootView:content(height:32,open:true))
        let window = NSWindow(contentRect:.init(x:0,y:0,width:1080,height:680),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentView=host
        defer { window.contentView=nil; window.close() }
        func children(_ view:NSView)->[NSView] { view.subviews.flatMap { [$0]+children($0) } }
        for size in [CGSize(width:1080,height:680),CGSize(width:1440,height:900)] {
            window.setContentSize(size)
            for height:CGFloat in [32,46] {
                for open in [true,false] {
                    host.rootView=content(height:height,open:open)
                    for _ in 0..<35 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(10)) }
                    let surfaces=children(host).compactMap { $0 as? WorkbenchBackgroundNSView }
                        .filter { $0.surfaceGroup?.hasPrefix("sidebar:")==true && !$0.isHiddenOrHasHiddenAncestor }
                    let surface=try #require(surfaces.max { $0.bounds.width*$0.bounds.height < $1.bounds.width*$1.bounds.height })
                    let rect=host.convert(surface.bounds,from:surface)
                    let top=host.isFlipped ? rect.minY : host.bounds.height-rect.maxY
                    #expect(top-(8+height) >= 11.9)
                    #expect(abs(top-(52+max(0,height-32)+(open ? 0 : WorkbenchSidebarLayout.buttonInset))) < 1)
                }
            }
        }
    }

    @Test func actualWorkbenchTopRowDoesNotRouteDragIntoCanvas() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "D.ChromeTest." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let project = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: LocalGlassNoInference(), backendID: "chrome.fixture",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: settings)
        await project.createProject(at: directory.appendingPathComponent("Chrome.dproject"))
        await project.enableProjectQuick(); await project.openWorkflow()
        do {
            let quick = try #require(project.projectQuick)
            let model = WorkbenchModel(projectSession: project)
            model.chatDisplaySettings = ChatDisplayPreferencesState(appearanceDirectory: directory.appendingPathComponent("Appearance"))
            let library = ModelLibraryModel(library: try await ModelLibrary(stateDirectory: directory.appendingPathComponent("models")))
            let host = NSHostingView(rootView: DualWorkbenchView(model: model, quickModel: model, quick: quick,
                library: library, nodeTags: ModelNodeTagStore(), metadata: nil))
            let window = DragRecordingWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
            for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let modes = try #require(children(host).compactMap { $0 as? WorkbenchCategoryDragView }.first { $0.geometry.count == 2 && $0.geometry.thickness == 32 })
            modes.onCommit(1) // Select the real workflow page; this is component setup, not a native gesture.
            for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let region = try #require(children(host).compactMap { $0 as? WorkbenchWindowDragRegion.View }.first)
            #expect(region.bounds.width >= 72 && region.bounds.height == 32)
            #expect(region.owner?.root?.titlebar?.window === window)
            let probe = try #require(children(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first)
            try #require(modes.selection == 1)
            let scroll = try #require(probe.enclosingScrollView)
            try #require(!probe.isHiddenOrHasHiddenAncestor && !scroll.isHiddenOrHasHiddenAncestor && !scroll.visibleRect.isEmpty)
            try #require(probe.navigationAllowed())
            let frameView = try #require(host.superview)
            for local in [CGPoint(x: 1, y: 1), CGPoint(x: region.bounds.midX, y: region.bounds.midY), CGPoint(x: region.bounds.maxX - 1, y: 31)] {
                let point = region.convert(local, to: nil)
                let hit = try #require(frameView.hitTest(frameView.superview?.convert(point, from: nil) ?? point))
                #expect(hit === region)
                let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                #expect(!probe.routePointer(event))
                hit.mouseDown(with: event)
                #expect(window.dragEvents.last === event)
            }
            #expect(window.dragEvents.count == 3)
        } catch { await project.closeProject(); throw error }
        await project.closeProject()
    }

    @Test func floatingChromeOwnershipIsWindowLocalAndRestoresOnlyOwnedProperties() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        for w in [window, other, panel] { w.isReleasedWhenClosed = false }
        defer { for w in [window, other, panel] { w.contentView = nil; w.close() } }
        let color = window.backgroundColor, separator = window.titlebarSeparatorStyle, visibility = window.titleVisibility
        let view = WorkbenchBackgroundNSView(frame: .init(x: 0, y: 0, width: 400, height: 250))
        view.isCanvas = true; window.contentView = view
        #expect(view.titlebar == nil && !window.titlebarAppearsTransparent)
        view.stylesWindowTitlebar = true; view.synchronizeTitlebar()
        #expect(view.titlebar?.window === window && window.titlebarAppearsTransparent && window.titleVisibility == .hidden)
        #expect(!other.titlebarAppearsTransparent && !other.styleMask.contains(.fullSizeContentView))
        #expect(WorkbenchWindowTitlebar(window: panel, invalidate: {}) == nil)
        window.contentView = nil; other.contentView = view
        #expect(!window.titlebarAppearsTransparent && !window.styleMask.contains(.fullSizeContentView))
        #expect(window.backgroundColor == color && window.titlebarSeparatorStyle == separator && window.titleVisibility == visibility)
        #expect(view.titlebar?.window === other && other.titlebarAppearsTransparent)
        other.title = "Unrelated new title"; other.backgroundColor = .orange
        view.releaseTitlebar(); view.releaseTitlebar()
        #expect(other.title == "Unrelated new title" && other.backgroundColor == .orange)
        #expect(!other.titlebarAppearsTransparent && !other.styleMask.contains(.fullSizeContentView))
    }

    @Test(arguments: [CGFloat(22), CGFloat(48), CGFloat(320)])
    func refractionCacheValidatesEveryInsetAndReusesSafeHoles(width: CGFloat) throws {
        let size = CGSize(width: width, height: width == 320 ? 240 : width)
        let geometry = WorkbenchLocalRenderer.RefractionGeometry()
        let image = try pattern()
        var variant = 0
        let outline: (CGRect, CGFloat) -> CGPath = { rect, inset in
            if variant == 1 { return Circle().inset(by: inset).path(in: rect).cgPath }
            // Variants 0 and 2 deliberately have identical outer paths, with
            // different interior inset behavior. Comparing only outline is unsafe.
            return RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: variant == 2 ? inset * 1.5 : inset).path(in: rect).cgPath
        }
        func draw(_ zoom: CGFloat, cached: Bool) throws -> [UInt8] {
            let c = try #require(WorkbenchLocalRenderer.bitmap(width: Int(size.width * 2), height: Int(size.height * 2)))
            c.scaleBy(x: 2, y: 2)
            WorkbenchLocalRenderer.draw(in: c, size: size,
                rect: CGRect(x: 30.25, y: 20.5, width: size.width * zoom, height: size.height * zoom),
                viewport: CGSize(width: 640, height: 480), image: image,
                canvas: "#111D1A", panel: "#1D2B25", strength: 0.55, glass: true,
                contour: outline, geometry: cached ? geometry : nil)
            return Array(UnsafeBufferPointer(start: try #require(c.data).assumingMemoryBound(to: UInt8.self), count: c.bytesPerRow * c.height))
        }
        let initial = try draw(1, cached: true)
        let builds = geometry.rebuildCount, operations = geometry.subtractionCount
        for _ in 0..<5 {
            geometry.invalidateContour() // Equivalent closures assigned by representable update.
            #expect(try draw(1, cached: true) == initial)
        }
        #expect(geometry.rebuildCount == builds && geometry.subtractionCount == operations)
        for nextVariant in [0, 2, 1, 0] {
            variant = nextVariant; geometry.invalidateContour()
            for zoom: CGFloat in [1, 1.1, 1.3, 0.65, 0.67, 1.8, 0.98] {
                #expect(try draw(zoom, cached: true) == draw(zoom, cached: false),
                    "Cached arbitrary inset geometry must match the original complete sampling, including zoom and shape switches")
            }
        }
        if width == 320 {
            #expect(geometry.subtractionCount < geometry.rebuildCount * 108,
                "Verified hole reuse must avoid the full 108 path operations at every scale")
        }
        print("REFRACTION_CACHE width=\(width) builds=\(geometry.rebuildCount) subtract=\(geometry.subtractionCount)")
    }

    @Test(arguments: [false, true])
    func textInputShellsFollowSettingsAcrossNativeHosts(retained: Bool) async throws {
        let owner = WorkbenchBackgroundOwner()
        var preferences = ChatDisplayPreferences(); var appearance = WorkbenchAppearance()
        appearance.local = WorkbenchLocalAppearance(); preferences.appearance = appearance
        var scheme = ColorScheme.light
        func inputs() -> some View {
            VStack {
                TextField("Search", text: .constant("未过滤 e\u{301}"))
                TextField("Number", value: .constant(42), format: .number)
                TextField("Note", text: .constant("多行说明\nunchanged"), axis: .vertical).lineLimit(2...4)
                TextEditor(text: .constant("Multi-line\n内容")).frame(height: 80).workbenchInputSurface()
                TextSourcesQuestionEditor(value: "原生输入", editEpoch: 0, isEditable: true, onEdit: { _ in })
                    .frame(height: 80).workbenchInputSurface()
            }.environment(\.chatDisplayPreferences, preferences).environment(\.colorScheme, scheme)
        }
        @ViewBuilder func content() -> some View {
            if retained {
                RetainedContentHost(content: inputs(), visible: true, identifier: "input-fixture")
                    .environment(\.workbenchBackground, owner)
            } else {
                inputs().workbenchTheme(paintsCanvas: false).environment(\.workbenchBackground, owner)
            }
        }
        let host = NSHostingView(rootView: content()); host.frame = CGRect(x: 0, y: 0, width: 420, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        func settle() async throws {
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        try await settle()
        let before = children(host)
        let native = before.filter { $0 is NSTextField || $0 is NSTextView }
        #expect(native.count >= 5)
        let initialSurfaces = before.compactMap { $0 as? WorkbenchBackgroundNSView }
        #expect(initialSurfaces.count == 5, "Each input has one local shell, including plain inherited fields")
        #expect(initialSurfaces.allSatisfy { $0.owner === owner && $0.drawsGlass })
        #expect(before.compactMap { $0 as? NSTextField }.allSatisfy { !$0.drawsBackground && !$0.isBezeled })
        #expect(before.compactMap { $0 as? NSTextView }.allSatisfy { !$0.drawsBackground })
        for strength in [0.0, 0.55, 1.0] {
            preferences.appearance?.local?.strength = strength; scheme = .dark
            host.rootView = content(); try await settle()
            let after = children(host), surfaces = after.compactMap { $0 as? WorkbenchBackgroundNSView }
            #expect(surfaces.count == 5 && surfaces.allSatisfy { $0.owner === owner && $0.strength == strength && $0.drawsGlass })
            #expect(surfaces.allSatisfy { $0.palette == WorkbenchPalette.defaultDark })
            #expect(native.allSatisfy { input in after.contains { $0 === input } })
        }
        preferences.appearance?.local?.material = .solid
        host.rootView = content(); try await settle()
        #expect(children(host).compactMap { $0 as? WorkbenchBackgroundNSView }.allSatisfy { !$0.drawsGlass })
    }

    @Test(arguments: [false, true])
    func inputAppearanceChangesPreserveCompositionUndoFocusAndScroll(manuscript: Bool) async throws {
        var value = String(repeating: "中文 e\u{301} 👩‍💻 — unchanged paragraph\n", count: 35)
        var document = try TextDraftDocument(text: value)
        var preferences = ChatDisplayPreferences(); var appearance = WorkbenchAppearance()
        appearance.local = WorkbenchLocalAppearance(); preferences.appearance = appearance
        var scheme = ColorScheme.light
        @ViewBuilder func editor() -> some View {
            if manuscript {
                TextSelectionEditor(document: document, selection: NSRange(location: 0, length: 0), onEdit: { text in
                    value = text
                    document = try! TextDraftDocument(id: document.id, text: text)
                }, onSelection: { _ in })
            } else {
                TextSourcesQuestionEditor(value: value, editEpoch: 0, isEditable: true, onEdit: { value = $0 })
            }
        }
        func content() -> some View {
            editor().workbenchInputSurface().environment(\.chatDisplayPreferences, preferences).environment(\.colorScheme, scheme)
        }
        let host = NSHostingView(rootView: content()); host.frame = CGRect(x: 0, y: 0, width: 420, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        func settle() async throws {
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        try await settle()
        let native = try #require(children(host).compactMap { $0 as? NSTextView }.first)
        #expect(window.makeFirstResponder(native))
        let undo = try #require(native.undoManager)
        undo.beginUndoGrouping(); native.insertText("!", replacementRange: NSRange(location: 0, length: 0)); undo.endUndoGrouping()
        #expect(undo.canUndo)
        native.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: 12, length: 0))
        let composed = Array(native.string.utf8), selected = native.selectedRange(), marked = native.markedRange()
        let scroll = try #require(native.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 60)); scroll.reflectScrolledClipView(scroll.contentView)
        let position = scroll.contentView.bounds.origin
        preferences.appearance?.local?.strength = 0.9; scheme = .dark
        host.rootView = content(); try await settle()
        #expect(children(host).contains { $0 === native })
        #expect(window.firstResponder === native && native.undoManager === undo && undo.canUndo)
        #expect(native.hasMarkedText() && native.markedRange() == marked && native.selectedRange() == selected)
        #expect(Array(native.string.utf8) == composed && scroll.contentView.bounds.origin == position)
        #expect(!native.drawsBackground && !scroll.drawsBackground && !scroll.contentView.drawsBackground)
        #expect(native.textColor == NSColor(WorkbenchPalette.defaultDark.foregroundColor))
        native.unmarkText(); undo.undo()
        #expect(Array(native.string.utf8) != composed, "Native undo remains operational after appearance changes")
    }

    @Test func liquidTransparencyKeepsARealContinuousRange() throws {
        let source = try #require(WorkbenchLocalRenderer.bitmap(width: 100, height: 80))
        source.setFillColor(CGColor(gray: 1, alpha: 1)); source.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let image = try #require(source.makeImage())
        var levels: [UInt8] = []
        for strength in [0.0, 0.55, 1.0] {
            let c = try #require(WorkbenchLocalRenderer.bitmap(width: 100, height: 80))
            WorkbenchLocalRenderer.draw(in: c, size: CGSize(width: 100, height: 80),
                rect: CGRect(x: 0, y: 0, width: 100, height: 80), viewport: CGSize(width: 100, height: 80),
                image: image, canvas: "#000000", panel: "#000000", strength: strength, glass: true)
            let pixels = try #require(c.data).assumingMemoryBound(to: UInt8.self)
            levels.append(pixels[(40 * 100 + 50) * 4])
            #expect(pixels[(40 * 100 + 50) * 4 + 3] == 255)
        }
        #expect(levels[0] == 0)
        #expect(levels[1] > 100 && levels[1] < 135)
        #expect(levels[2] > 200 && levels[2] < 220)
    }

    @Test func liquidDiffusionKeepsFineBackgroundDetail() throws {
        let raw = try pattern(width: 160, height: 100)
        let diffuse = try #require(WorkbenchLocalRenderer.blur(raw))
        let a = try render(raw, refract: false), b = try render(diffuse, refract: false)
        func horizontalDetail(_ pixels: [UInt8]) -> Int {
            (20..<40).reduce(0) { sum, y in
                sum + (20..<60).reduce(0) { $0 + abs(Int(pixels[(y * 80 + $1) * 4]) - Int(pixels[(y * 80 + $1 - 1) * 4])) }
            }
        }
        #expect(a != b, "The bounded optical diffusion is real")
        #expect(Double(horizontalDetail(b)) / Double(horizontalDetail(a)) > 0.60,
                "Clear glass must retain the local pattern, not a broad frosted blur")
    }

    @Test(arguments: ["capsule", "circle", "node"])
    func liquidRefractionFollowsActualOutlineWithoutChangingTheCenter(shape: String) throws {
        let size = shape == "circle" ? CGSize(width: 80, height: 80) : CGSize(width: 160, height: 80)
        let outline: (CGRect, CGFloat) -> CGPath = { rect, inset in
            if shape == "capsule" { return Capsule().inset(by: inset).path(in: rect).cgPath }
            if shape == "circle" { return Circle().inset(by: inset).path(in: rect).cgPath }
            return RoundedRectangle(cornerRadius: 13).inset(by: inset).path(in: rect).cgPath
        }
        let image = try pattern(width: 320, height: 200)
        func pixels(_ refract: Bool) throws -> [UInt8] {
            let c = try #require(WorkbenchLocalRenderer.bitmap(width: Int(size.width), height: Int(size.height)))
            WorkbenchLocalRenderer.draw(in: c, size: size, rect: CGRect(origin: CGPoint(x: 20, y: 30), size: size),
                viewport: CGSize(width: 320, height: 200), image: image, canvas: "#111D1A", panel: "#1D2B25",
                strength: 0.85, glass: true, refraction: refract, contour: outline)
            return Array(UnsafeBufferPointer(start: try #require(c.data).assumingMemoryBound(to: UInt8.self), count: c.bytesPerRow * c.height))
        }
        let straight = try pixels(false), lens = try pixels(true)
        var changed = 0
        for y in 0..<Int(size.height) { for x in 0..<Int(size.width) {
            let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5), index = (y * Int(size.width) + x) * 4
            let same = straight[index..<index+4] == lens[index..<index+4]
            if outline(CGRect(origin: .zero, size: size), 14).contains(point) { #expect(same) }
            if !same { changed += 1 }
        } }
        #expect(changed > 100, "A real curved lens, not only a border")
        // Rounded shoulders bend pixels outside the old rectangular 12-point rim.
        let probe = CGPoint(x: 14.5, y: 14.5)
        if shape == "capsule" || shape == "circle" {
            #expect(outline(CGRect(origin: .zero, size: size), 0).contains(probe))
            #expect(!outline(CGRect(origin: .zero, size: size), 12).contains(probe))
        }
    }

    @Test func liquidControlFamiliesUseTheSameOwnerAndKeepNativeInput() async throws {
        let owner = WorkbenchBackgroundOwner()
        var preferences = ChatDisplayPreferences(); var appearance = WorkbenchAppearance()
        appearance.local = WorkbenchLocalAppearance(); preferences.appearance = appearance
        func content() -> some View {
            VStack {
                Button("Normal") {}.buttonStyle(WorkbenchGlassButtonStyle())
                Button("Primary") {}.buttonStyle(WorkbenchPrimaryButtonStyle())
                Button("Icon", systemImage: "gearshape") {}.buttonStyle(WorkbenchIconButtonStyle())
                Button("Row") {}.buttonStyle(WorkbenchRowButtonStyle())
                Menu("Menu") { Button("Action") {} }.menuStyle(WorkbenchGlassMenuStyle())
                Text("Panel").padding(20).workbenchPanel(cornerRadius: 13)
                TextField("Native input", text: .constant("unfiltered"))
            }.environment(\.workbenchBackground, owner).environment(\.chatDisplayPreferences, preferences)
        }
        let host = NSHostingView(rootView: content()); host.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        let before = children(host), surfaces = before.compactMap { $0 as? WorkbenchBackgroundNSView }
        #expect(surfaces.count == 6)
        #expect(surfaces.allSatisfy { $0.owner === owner && $0.contour != nil && $0.hitTest(.zero) == nil })
        let inputs = before.compactMap { $0 as? NSTextField }; #expect(!inputs.isEmpty)
        preferences.appearance?.local?.strength = 1; host.rootView = content()
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let after = children(host)
        #expect(inputs.allSatisfy { input in after.contains { $0 === input } })
        #expect(after.compactMap { $0 as? WorkbenchBackgroundNSView }.allSatisfy { $0.strength == 1 })
    }

    @Test func nestedPresentationOwnsItsCanvasAcrossTheRetainedBoundary() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ChatDisplayPreferencesState(appearanceDirectory: root.appendingPathComponent("Appearance"))
        let file = root.appendingPathComponent("source.png"); try png(pattern(), at: file)
        await state.importWallpaper(file)
        let parent = NSHostingView(rootView: Text("Parent").padding(20).workbenchPanel()
            .workbenchPresentation(state: state))
        parent.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        let parentWindow = NSWindow(contentRect: parent.frame, styleMask: [.titled], backing: .buffered, defer: false)
        parentWindow.isReleasedWhenClosed = false; parentWindow.contentView = parent
        for _ in 0..<40 { parent.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let child = NSHostingView(rootView: RetainedContentHost(content:
            Text("Nested sheet").padding(20).workbenchPanel().workbenchPresentation(), visible: true, identifier: "nested")
                .environment(\.workbenchAppearanceState, state))
        child.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let childWindow = NSWindow(contentRect: child.frame, styleMask: [.titled], backing: .buffered, defer: false)
        childWindow.isReleasedWhenClosed = false; childWindow.contentView = child
        defer { childWindow.contentView = nil; childWindow.close(); parentWindow.contentView = nil; parentWindow.close() }
        // No await or run-loop turn: the sheet must already have pixels when
        // its native canvas is first laid out, not after an appearance task.
        child.layoutSubtreeIfNeeded()
        func views(_ v: NSView) -> [WorkbenchBackgroundNSView] {
            v.subviews.flatMap { ($0 as? WorkbenchBackgroundNSView).map { [$0] } ?? views($0) }
        }
        let parentCanvas = try #require(views(parent).first { $0.isCanvas }), childCanvas = try #require(views(child).first { $0.isCanvas })
        let parentOwner = try #require(parentCanvas.owner), childOwner = try #require(childCanvas.owner)
        #expect(parentOwner !== childOwner)
        #expect(parentOwner.root === parentCanvas && childOwner.root === childCanvas)
        #expect(parentCanvas.window !== childCanvas.window)
        #expect(parentOwner.key == childOwner.key && parentOwner.image != nil && childOwner.image != nil)
        #expect(views(child).allSatisfy { $0.owner === childOwner })
        #expect(parentOwner.decodeCount == 1 && childOwner.decodeCount == 0)
        #expect(parentOwner.image === childOwner.image && parentOwner.blurred === childOwner.blurred)
        let bitmap = try #require(childCanvas.bitmapImageRepForCachingDisplay(in: childCanvas.bounds))
        childCanvas.cacheDisplay(in: childCanvas.bounds, to: bitmap)
        #expect(childOwner.drawCount > 0 && childOwner.image != nil)
        childOwner.load(nil) // closing one presentation must not discard the shared prepared pair
        #expect(parentOwner.image != nil && state.backgroundTextures.entry != nil)
        childOwner.load(state.wallpaperURL(), cache: state.backgroundTextures)
        #expect(childOwner.image === parentOwner.image && childOwner.decodeCount == 0)
    }

    @Test func backgroundCacheSeparatesOwnersAndRejectsLatePreparation() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png")
        try png(pattern(), at: a); try png(pattern(1), at: b)
        let first = WorkbenchBackgroundTextures(), second = WorkbenchBackgroundTextures()
        let owner = WorkbenchBackgroundOwner(); owner.load(a, cache: first)
        for _ in 0..<500 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        let prepared = try #require(owner.image)
        owner.load(a, cache: second)
        #expect(owner.image == nil, "A different appearance owner must not borrow the previous cache")
        for _ in 0..<500 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner.image !== prepared && second.entry != nil && owner.decodeCount == 2)
        owner.load(a, blur: false, cache: second)
        #expect(owner.blurred == nil)
        for _ in 0..<500 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner.image != nil && owner.blurred == nil && second.entry?.blur == false)
        owner.load(b, cache: second)
        #expect(owner.image == nil, "A different full resource URL must not show the old image")
        second.clear() // Invalidate a pending read, even before a view updates its owner.
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.image == nil && second.entry == nil)
        owner.load(nil)
        #expect(owner.retainedBytes == 0)
    }

    @Test func solidCanvasDefaultAndExplicitImageSurviveColdRead() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "D.LocalGlassTests." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite)); defer { settings.removePersistentDomain(forName: suite) }
        let directory = root.appendingPathComponent("Appearance")
        let state = ChatDisplayPreferencesState(settings: settings, appearanceDirectory: directory)
        #expect(state.wallpaperURL() == nil && state.preferences.appearance?.local?.wallpaper == nil)
        #expect(state.preferences.appearance?.local?.material == .glass && state.preferences.appearance?.local?.strength == 0.55)
        try #require(state.update(state.preferences))
        let plain = ChatDisplayPreferencesState(settings: settings, appearanceDirectory: directory)
        #expect(plain.preferences == state.preferences && plain.wallpaperURL() == nil)
        let source = root.appendingPathComponent("my-image.png"); try png(pattern(), at: source)
        let original = try Data(contentsOf: source)
        await state.importWallpaper(source)
        var chosen = state.preferences; chosen.appearance?.local?.strength = 0.85
        try #require(state.update(chosen))
        let cold = ChatDisplayPreferencesState(settings: settings, appearanceDirectory: directory)
        #expect(cold.preferences == chosen && cold.wallpaperURL() == state.wallpaperURL())
        #expect(cold.wallpaperURL() != nil && cold.backgroundTextures.entry == nil)
        let owner = WorkbenchBackgroundOwner(); owner.load(cold.wallpaperURL(), cache: cold.backgroundTextures)
        for _ in 0..<500 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(owner.image != nil && cold.backgroundTextures.entry != nil)
        try #require(cold.restoreSolidCanvas())
        #expect(cold.backgroundTextures.entry == nil)
        let restored = ChatDisplayPreferencesState(settings: settings, appearanceDirectory: directory)
        #expect(restored.wallpaperURL() == nil && restored.preferences.appearance?.local?.material == .glass)
        #expect(restored.preferences.appearance?.local?.strength == 0.85)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [false, true]) func externalIsExcludedButInternalPatternChanges(alpha: Bool) throws {
        let a = try pattern(alpha: alpha), b = try pattern(1, alpha: alpha)
        let red = try render(a), blue = try render(a, external: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        #expect(red == blue)
        #expect(red != (try render(b)))
        #expect(stride(from: 3, to: red.count, by: 4).allSatisfy { red[$0] == 255 })
        // Nonuniform interior: excludes a single average/tint masquerading as sampling.
        #expect(Set(stride(from: 20*4, to: red.count, by: 4).map { red[$0] }).count > 10)
    }
    @Test func productionBlurAndRefractionHaveDistinctPixelEffects() throws {
        let raw = try pattern()
        let blurred = try #require(WorkbenchLocalRenderer.blur(raw))
        let a = try render(raw, refract: false), b = try render(blurred, refract: false), c = try render(blurred)
        #expect(a != b); #expect(b != c)
        // Refraction is restricted to the rim, rather than filtering the content interior.
        for y in 16..<44 { for x in 16..<64 {
            let i = (y * 80 + x) * 4
            #expect(Array(b[i..<i+4]) == Array(c[i..<i+4]))
        } }
        let edgeDifferences = zip(b,c).filter { $0 != $1 }.count
        #expect(edgeDifferences > 100)
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try png(blurred, at: root.appendingPathComponent("production-blur.png"))
    }
    @Test(arguments:[0.0,0.55,1.0]) func translucentUniformSourceDoesNotAccumulateAtRefractionRim(strength:Double) throws {
        let source = try #require(WorkbenchLocalRenderer.bitmap(width:80,height:60))
        source.setFillColor(CGColor(srgbRed:1,green:0,blue:0,alpha:0.5)); source.fill(CGRect(x:0,y:0,width:80,height:60))
        let image = try #require(source.makeImage())
        let c = try #require(WorkbenchLocalRenderer.bitmap(width:80,height:60))
        WorkbenchLocalRenderer.draw(in:c,size:CGSize(width:80,height:60),rect:CGRect(x:0,y:0,width:80,height:60),
            viewport:CGSize(width:80,height:60),image:image,canvas:"#111D1A",panel:"#1D2B25",strength:strength,glass:true)
        let p = try #require(c.data).assumingMemoryBound(to:UInt8.self)
        let first = Array(UnsafeBufferPointer(start:p,count:4))
        for i in stride(from:0,to:80*60*4,by:4) { #expect(Array(UnsafeBufferPointer(start:p+i,count:4)) == first) }
    }
    @Test(arguments: [0.4, 1.0, 2.0, 3.0]) func commonMappingDoesNotScaleWallpaperPerNode(zoom: Double) throws {
        let image = try pattern()
        let viewport = CGSize(width: 320, height: 200)
        let mapped = WorkbenchLocalRenderer.mapping(image: CGSize(width: 160, height: 100), viewport: viewport)
        #expect(mapped == CGRect(x: 0, y: 0, width: 320, height: 200))
        let x = max(0, Int(30 * zoom)), width = 40
        let left = try render(image, rect: CGRect(x: x, y: 10, width: width, height: 40), viewport: viewport, glass: false)
        let union = try render(image, rect: CGRect(x: 0, y: 10, width: 200, height: 40), viewport: viewport, glass: false)
        for y in 0..<40 { for col in 0..<width {
            #expect(left[(y*width+col)*4] == union[(y*200+x+col)*4])
        } }
    }
    @Test(arguments: [CGSize(width: 1, height: 1), CGSize(width: 4, height: 80), CGSize(width: 512, height: 320)])
    func edgesAndTransparentImagesStayOpaque(size: CGSize) throws {
        let pixels = try render(pattern(alpha: true), rect: CGRect(x: -100, y: -100, width: size.width, height: size.height))
        #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
    }
    @Test func oldNewFutureAndDamagedPreferencesAreDistinct() throws {
        let name = "D.LocalGlassTests." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: name)); defer { settings.removePersistentDomain(forName: name) }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(ChatDisplayPreferencesState(settings: settings, appearanceDirectory: root).preferences.appearance?.local?.material == .glass)
        var old = ChatDisplayPreferences(); var oldAppearance = WorkbenchAppearance(); oldAppearance.backgroundTransparency = 0.83
        old.appearance = oldAppearance
        settings.set(try JSONEncoder().encode(old), forKey: ChatDisplayPreferences.storageKey)
        let legacy = ChatDisplayPreferencesState(settings: settings, appearanceDirectory: root)
        #expect(legacy.preferences.resolvedAppearance.local == nil)
        #expect(legacy.preferences.resolvedAppearance.backgroundTransparency == 0.83)
        var future = old; var local = WorkbenchLocalAppearance(); local.version = 99; future.appearance?.local = local
        let bytes = try JSONEncoder().encode(future); settings.set(bytes, forKey: ChatDisplayPreferences.storageKey)
        let protected = ChatDisplayPreferencesState(settings: settings, appearanceDirectory: root)
        #expect(protected.hasInvalidStoredRecord && !protected.update(old))
        #expect(settings.data(forKey: ChatDisplayPreferences.storageKey) == bytes)
        settings.set(Data("broken".utf8), forKey: ChatDisplayPreferences.storageKey)
        #expect(!legacy.update(old))
    }
    @Test func importColdReadReplaceAndRestorePreserveOriginalAndUnknownFiles() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("source.png"); try png(pattern(alpha: true), at: original)
        let originalBytes = try Data(contentsOf: original)
        let owned = root.appendingPathComponent("Appearance"); let state = ChatDisplayPreferencesState(appearanceDirectory: owned)
        await state.importWallpaper(original)
        #expect(!state.wallpaperIssue)
        let a = try #require(state.wallpaperURL()); #expect(a != original)
        #expect(FileManager.default.fileExists(atPath: a.path))
        let unknown = owned.appendingPathComponent("unknown.txt"); try Data("preserve".utf8).write(to: unknown)
        await state.importWallpaper(original)
        let b = try #require(state.wallpaperURL()); #expect(a != b)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(state.restoreSolidCanvas())
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try String(contentsOf: unknown, encoding: .utf8) == "preserve")
    }
    @Test(arguments: ["cancel", "change", "invalid", "symlink"])
    func staleOrFailedPreparationDoesNotPublish(mode: String) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png"); try png(pattern(), at: source)
        let owned = root.appendingPathComponent("Appearance")
        let state = ChatDisplayPreferencesState(appearanceDirectory: owned)
        if mode == "invalid" { try Data("not a PNG".utf8).write(to: source) }
        if mode == "symlink" { try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: root) }
        let task = Task { await state.importWallpaper(source) }
        if mode == "cancel" || mode == "change" {
            while !state.wallpaperPreparing { await Task.yield() }
            if mode == "cancel" { state.cancelWallpaperPreparation() }
            else { var next = state.preferences; next.textPointSize = 19; state.update(next) }
        }
        await task.value
        #expect(state.preferences.appearance?.local?.wallpaper == nil)
        #expect(state.wallpaperURL() == nil)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasSuffix(".png") && $0 != "source.png" })
    }
    @Test func decodeDownsamplesRejectsMalformedAndNormalizesDirection() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("large.png")
        let c = try #require(WorkbenchLocalRenderer.bitmap(width: 3000, height: 40)); c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0,y: 0,width: 3000,height: 40))
        try png(#require(c.makeImage()), at: large)
        let data = try WorkbenchWallpaperDecoder.prepareFile(large)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2048 && image.height <= 40)
        let oriented = root.appendingPathComponent("oriented.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(oriented as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try pattern(width: 80,height: 40), [kCGImagePropertyOrientation: 6] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let normalized = try WorkbenchWallpaperDecoder.prepareFile(oriented)
        let normalizedSource = try #require(CGImageSourceCreateWithData(normalized as CFData, nil))
        let upright = try #require(CGImageSourceCreateImageAtIndex(normalizedSource,0,nil))
        #expect(upright.width == 40 && upright.height == 80)
        let multi = root.appendingPathComponent("multi.tiff")
        let frames = try #require(CGImageDestinationCreateWithURL(multi as CFURL, UTType.tiff.identifier as CFString, 2,nil))
        for _ in 0..<2 { CGImageDestinationAddImage(frames,try pattern(),nil) }
        try #require(CGImageDestinationFinalize(frames))
        #expect(throws:(any Error).self) { try WorkbenchWallpaperDecoder.prepareFile(multi) }
        let empty = root.appendingPathComponent("empty.png"); try Data().write(to: empty)
        #expect(throws: (any Error).self) { try WorkbenchWallpaperDecoder.prepareFile(empty) }
    }
    @Test func sharedCacheDoesNotGrowWithPanelsMovementAndReleasesOnClear() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png"); try png(pattern(), at: source)
        let owner = WorkbenchBackgroundOwner(); owner.load(source)
        for _ in 0..<500 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner.image != nil && owner.blurred != nil)
        let bytes = owner.retainedBytes
        var views: [WorkbenchBackgroundNSView] = []
        for i in 0..<100 {
            let view = WorkbenchBackgroundNSView(frame: CGRect(x:i,y:i,width:80,height:60))
            view.owner = owner; owner.surfaces.add(view); views.append(view)
            owner.load(source)
        }
        #expect(owner.decodeCount == 1 && owner.blurCount == 1 && owner.retainedBytes == bytes)
        #expect(bytes <= 160*100*4*2)
        owner.load(nil); #expect(owner.retainedBytes == 0)
        #expect(views.count == 100)
    }
    @Test func persistedCopyColdLoadsAndMissingFileFallsBackOnce() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "D.LocalGlassTests." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite)); defer { settings.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("source.png"); try png(pattern(), at: source)
        let state = ChatDisplayPreferencesState(settings: settings, appearanceDirectory: root.appendingPathComponent("Appearance"))
        await state.importWallpaper(source)
        let cold = ChatDisplayPreferencesState(settings: settings, appearanceDirectory: state.appearanceDirectory)
        #expect(cold.preferences == state.preferences)
        let url = try #require(cold.wallpaperURL()); try FileManager.default.removeItem(at: url)
        let owner = WorkbenchBackgroundOwner(); var failures = 0; owner.failure = { failures += 1 }
        owner.load(url)
        for _ in 0..<100 where failures == 0 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<100 { owner.load(url) }
        #expect(failures == 1 && owner.image == nil && owner.retainedBytes == 0)
        #expect(settings.data(forKey: ChatDisplayPreferences.storageKey) != nil)
    }
    @Test func rapidSourceChangesAndClearRejectLateTexture() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png")
        try png(pattern(), at: a); try png(pattern(1), at: b)
        let owner = WorkbenchBackgroundOwner()
        for _ in 0..<20 { owner.load(a); owner.load(b) }
        for _ in 0..<500 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner.key == b && owner.image != nil && owner.decodeCount == 1)
        owner.load(a); owner.load(nil)
        try await Task.sleep(for: .milliseconds(40))
        #expect(owner.image == nil && owner.blurred == nil && owner.retainedBytes == 0)
    }
    @Test func externalPreferenceChangePreservesOldSelectionAndNoExtraFiles() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "D.LocalGlassTests." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite)); defer { settings.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("source.png"); try png(pattern(), at: source)
        let state = ChatDisplayPreferencesState(settings: settings, appearanceDirectory: root.appendingPathComponent("Appearance"))
        await state.importWallpaper(source)
        let original = try #require(state.wallpaperURL()), bytes = try Data(contentsOf: original)
        let task = Task { await state.importWallpaper(source) }
        while !state.wallpaperPreparing { await Task.yield() }
        settings.set(Data("external damaged record".utf8), forKey: ChatDisplayPreferences.storageKey)
        await task.value
        #expect(state.wallpaperURL() == original)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path).count == 1)
        #expect(settings.data(forKey: ChatDisplayPreferences.storageKey) == Data("external damaged record".utf8))
    }
    @Test func productionPixelsAndCacheCountersAreExportable() async throws {
        guard let path = ProcessInfo.processInfo.environment["D_GLASS_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = try pattern(width: 640, height: 400), b = try pattern(1, width: 640, height: 400)
        try png(a, at: root.appendingPathComponent("background-A.png")); try png(b, at: root.appendingPathComponent("background-B.png"))
        try png(pattern(alpha: true), at: root.appendingPathComponent("transparent-image.png"))
        let start = ProcessInfo.processInfo.systemUptime
        for (name, raw) in [("A", a), ("B", b)] {
            let blurred = try #require(WorkbenchLocalRenderer.blur(raw))
            for refract in [false, true] {
                let c = try #require(WorkbenchLocalRenderer.bitmap(width: 640, height: 400))
                WorkbenchLocalRenderer.draw(in: c, size: CGSize(width: 640,height: 400), rect: CGRect(x:0,y:0,width:640,height:400),
                    viewport: CGSize(width:640,height:400), image: blurred, canvas:"#111D1A",panel:"#1D2B25",strength:0.55,glass:true,refraction:refract)
                try png(#require(c.makeImage()), at: root.appendingPathComponent("production-"+name+(refract ? "-refraction" : "-blur")+".png"))
            }
        }
        let owner = WorkbenchBackgroundOwner(); let file = root.appendingPathComponent("background-A.png")
        let loadStart = ProcessInfo.processInfo.systemUptime; owner.load(file)
        for _ in 0..<500 where owner.image == nil { try await Task.sleep(for:.milliseconds(10)) }
        try #require(owner.image != nil)
        let bytes = owner.retainedBytes
        for _ in 0..<500 { owner.load(file); owner.invalidate() }
        let report: [String: Any] = ["source":"production CoreImage/CoreGraphics renderer, CPU offscreen; not an App screenshot",
            "sourcePixels":[640,400],"decodeCount":owner.decodeCount,"blurCount":owner.blurCount,
            "sharedImageBytes":bytes,"legacyImageBytes":0,"repeatedSameSourceUpdates":500,
            "prepareAndDeliverySeconds":ProcessInfo.processInfo.systemUptime-loadStart,
            "twoPatternsFourExportsSeconds":loadStart-start,"frameTiming":"NOT_MEASURED"]
        owner.load(nil); #expect(owner.retainedBytes == 0)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("render-metrics.json"))
    }

    @Test(arguments: [false, true]) func atomicPublicationOwnsPartialWritesAndRefusesReplacement(partial: Bool) throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(UUID().uuidString+".png")
        if partial {
            #expect(throws:(any Error).self) {
                try WorkbenchWallpaperPublication.publish(Data("prepared".utf8), to: target) { bytes, url in
                    try bytes.prefix(2).write(to:url); throw WorkbenchWallpaperError.saveFailed
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        } else {
            try Data("existing".utf8).write(to:target)
            #expect(throws:(any Error).self) { try WorkbenchWallpaperPublication.publish(Data("new".utf8),to:target) }
            #expect(try String(contentsOf:target,encoding:.utf8) == "existing")
            #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).count == 1)
        }
    }
    @Test(arguments: [false, true]) func preferenceFlushFailureRestoresChoiceBeforeRetiringCopy(restore: Bool) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "D.LocalGlassTests."+UUID().uuidString
        let settings = try #require(UserDefaults(suiteName:suite)); defer { settings.removePersistentDomain(forName:suite) }
        let source = root.appendingPathComponent("source.png"); try png(pattern(),at:source)
        let initial = ChatDisplayPreferencesState(settings:settings,appearanceDirectory:root.appendingPathComponent("Appearance"))
        await initial.importWallpaper(source)
        let old = try #require(initial.wallpaperURL()), oldBytes = try Data(contentsOf:old)
        var flushes = 0
        let failed = ChatDisplayPreferencesState(settings:settings,appearanceDirectory:initial.appearanceDirectory,
            commitAppearance: { _ in flushes += 1; return flushes != 1 })
        let owner = WorkbenchBackgroundOwner(); owner.load(old, cache: failed.backgroundTextures)
        for _ in 0..<500 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        let prepared = try #require(owner.image)
        if restore { #expect(!failed.restoreSolidCanvas()) }
        else { await failed.importWallpaper(source) }
        owner.load(old, cache: failed.backgroundTextures)
        #expect(owner.image === prepared && owner.decodeCount == 1,
                "A failed save retains the warm original; opening settings must not flash a fallback")
        #expect(flushes == 2 && failed.wallpaperIssue)
        #expect(failed.wallpaperURL() == old)
        #expect(try Data(contentsOf:old) == oldBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath:old.deletingLastPathComponent().path).count == 1)
        #expect(ChatDisplayPreferencesState(settings:settings).preferences == initial.preferences)
    }

    /// Hidden native hosts exercise the actual four Quick consumers without
    /// activating any window. This is hosted evidence, not desktop acceptance.
    @Test(arguments: QuickCategory.allCases) func realQuickConsumersShareBackgroundAndRetainMediaAndInput(category: QuickCategory) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = try await ProjectStore.create(at:root.appendingPathComponent("Test.dproject"),name:"Synthetic local glass")
        let suite = "D.LocalGlassTests."+UUID().uuidString
        let settings = try #require(UserDefaults(suiteName:suite)); defer { settings.removePersistentDomain(forName:suite) }
        let model = WorkbenchModel(sessionFactory:{ _ in throw WorkflowIssue("No inference") },settings:settings,
            appearanceDirectory:root.appendingPathComponent("Appearance"))
        let wallpaper = root.appendingPathComponent("source.png"); try png(pattern(),at:wallpaper)
        await model.chatDisplaySettings.importWallpaper(wallpaper)
        let operation = try #require(WorkflowRegistry.standard.definitions.first {
            QuickCategory.category(for:$0.id) == category && $0.fields.contains { ["task","promptText"].contains($0.id) }
        })
        var node = operation.makeNode(); node.parameters["modelID"] = .text("fixture:no-model")
        let draft = QuickDraft(id:"fixture-"+category.rawValue,node:node)
        let extensionName = category == .video ? "synthetic.mp4" : category == .audio ? "synthetic.wav" : "transparent-image.png"
        let bytes: Data, mediaType: String
        if category == .video || category == .audio {
            let evidence = try #require(ProcessInfo.processInfo.environment["D_GLASS_EVIDENCE_DIR"])
            bytes = try Data(contentsOf:URL(fileURLWithPath:evidence).appendingPathComponent(extensionName))
            mediaType = category == .video ? "video/mp4" : "audio/wav"
        } else if category == .image { bytes = try Data(contentsOf:wallpaper); mediaType = "image/png" }
        else { bytes = Data(String(repeating:"合成阅读段落，原文不被背景处理。\n",count:20).utf8); mediaType = "text/plain" }
        let reference: WorkflowAssetReference
        if category == .video {
            let staged = root.appendingPathComponent("synthetic.mp4"); try bytes.write(to:staged)
            reference = try await store.importWorkflowMediaFile(at:staged).record.reference
        } else {
            reference = try await store.publishWorkflowAsset(data:bytes,mediaType:mediaType,
                metadata:category == .image ? .init(width:160,height:100) : .init(),
                name:"Synthetic result",operationID:"fixture.local-glass").record.reference
        }
        var record = QuickCreationState(); record.drafts = [draft]; record.selectedDraftID = draft.id
        record.navigation = .init(selected:category,lastDrafts:[category.rawValue:draft.id])
        record.runs = [QuickRunRecord(id:UUID(),draft:draft,createdAt:Date(),status:.completed,
            outputs:["result":.asset(reference)],candidates:[],issue:nil)]
        _ = try await store.saveQuickCreationState(record,expectedRevision:record.revision)
        let quick = QuickGenerationController(store:store) { throw WorkflowIssue("No inference") }
        await quick.load()
        let sidebars = WorkbenchSidebarState(); sidebars.trailing = true
        func content() -> some View {
            QuickGenerationView(quick:quick,model:model,selectedResults:.constant([category:reference]),
                onChooseModel:{},onSettingsToCanvas:{_ in},onResultToCanvas:{_ in},onValueToCanvas:{_ in})
                .modifier(WorkbenchCanvasModifier(state:model.chatDisplaySettings))
                .environment(\.chatDisplayPreferences,model.chatDisplaySettings.preferences)
                .environment(\.workbenchSidebars,sidebars)
        }
        var mediaReads = 0
        WorkbenchCategoryUpdateProbe.phaseObserver = { if $0 == "media-prepare-start" { mediaReads += 1 } }
        defer { WorkbenchCategoryUpdateProbe.phaseObserver = nil }
        let host = NSHostingView(rootView:content()); host.frame = CGRect(x:0,y:0,width:1200,height:800)
        let window = NSWindow(contentRect:host.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view:NSView)->[NSView] { view.subviews.flatMap { [$0]+descendants($0) } }
        func settle() async throws { for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(10)) } }
        try await settle()
        let surfaces = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }
        let canvas = try #require(surfaces.first { $0.isCanvas }), owner = try #require(canvas.owner)
        try #require(owner.image != nil && surfaces.count >= 4)
        #expect(surfaces.allSatisfy { $0.owner === owner })
        let nativeInputs = descendants(host).compactMap { $0 as? NSTextView }
        let nativePlayers = descendants(host).filter { String(describing:type(of:$0)).contains("AVPlayer") }
        let players = descendants(host).compactMap { ($0 as? AVPlayerView)?.player }
        #expect(!nativeInputs.isEmpty)
        if category == .video || category == .audio { #expect(!nativePlayers.isEmpty) }
        if category == .image || category == .video { #expect(mediaReads == 1) }
        let reads = mediaReads
        let pixels = owner.retainedBytes, decodes = owner.decodeCount
        var updated = model.chatDisplaySettings.preferences; updated.appearance?.local?.strength = 0.9
        #expect(model.chatDisplaySettings.update(updated)); host.rootView = content()
        window.setContentSize(CGSize(width:1080,height:700)); try await settle()
        let after = descendants(host)
        #expect(nativeInputs.allSatisfy { input in after.contains { $0 === input } })
        #expect(nativePlayers.allSatisfy { player in after.contains { $0 === player } })
        let afterPlayers = after.compactMap { ($0 as? AVPlayerView)?.player }
        #expect(players.allSatisfy { player in afterPlayers.contains { $0 === player } })
        #expect(owner.decodeCount == decodes && owner.retainedBytes == pixels)
        #expect(mediaReads == reads)
        #expect(try await store.workflowData(reference) == bytes)
        #expect(quick.state.runs.count == 1)
        try await store.close()
    }

    @Test(arguments: [CGFloat(1), CGFloat(-1)])
    func productionWheelBurstRetainsEveryStepBeforeNativeLayout(direction: CGFloat) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Wheel.dproject"), name: "Wheel fixture")
        let runtime = WorkbenchSession(engine: LocalGlassNoInference(), backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let controller = WorkflowController(services: .init(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }))
        await controller.load(); controller.addExample("template")
        let graph = try #require(controller.graph)
        let undoBefore = controller.canUndo
        let state = ChatDisplayPreferencesState(appearanceDirectory: root.appendingPathComponent("Appearance"))
        let wallpaper = root.appendingPathComponent("pattern.png"); try png(pattern(width: 1024, height: 768), at: wallpaper)
        await state.importWallpaper(wallpaper)
        func content() -> some View {
            WorkflowCanvasView(controller: controller, onTextModel: {}, onImageModel: {},
                onImport: { _ in }, onDestination: {}, onPublishText: {}, onReturnText: { _ in })
                .modifier(WorkbenchCanvasModifier(state: state))
                .environment(\.chatDisplayPreferences, state.preferences)
        }
        let host = NSHostingView(rootView: content()); host.frame = CGRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        for _ in 0..<25 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let probe = try #require(descendants(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first)
        let scroll = try #require(probe.enclosingScrollView)
        let scope = try #require(probe.interactionScope)
        let wheel = try #require(probe.wheelZoom)
        let size = scroll.contentView.bounds.size
        let original = try #require(probe.wheelLayout(size))
        let offset = scroll.contentView.bounds.origin, mouse = CGPoint(x: 310, y: 210)
        let anchor = original.rawPoint(screenPoint: mouse, offset: offset)
        let surfaces = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }
        let owner = try #require(surfaces.first(where: { $0.isCanvas })?.owner)
        try #require(surfaces.contains(where: { $0.usesContinuousGlass }))
        let buildsBefore = owner.glassFields.builds
        var glassUpdates: [String: Int] = [:]
        WorkbenchGlassUpdateProbe.event = { glassUpdates[$0, default: 0] += 1 }
        defer { WorkbenchGlassUpdateProbe.event = nil }
        let began = ProcessInfo.processInfo.systemUptime
        let callback = probe.onWheel // Keep this exact production closure throughout the burst.
        var bodies: [UUID: Int] = [:], menus: [UUID: Int] = [:]
        WorkflowCanvasUpdateProbe.nodeBody = { bodies[$0, default: 0] += 1 }
        WorkflowCanvasUpdateProbe.nodeMenuBuild = { menus[$0, default: 0] += 1 }
        defer { WorkflowCanvasUpdateProbe.nodeBody = nil; WorkflowCanvasUpdateProbe.nodeMenuBuild = nil }
        let delta = direction * CGFloat(log(1.1) / 0.015)
        for _ in 0..<4 { callback(delta, mouse, offset, size) }
        let zoom = (0..<4).reduce(original.zoom) { value, _ in value * CGFloat(exp(Double(delta) * 0.015)) }
        #expect(abs(zoom - original.zoom * pow(1.1, direction * 4)) < 1e-10)
        let target = WorkflowCanvasViewportGeometry(graphSize: original.graphSize,
            viewportSize: size, zoom: zoom, translation: original.translation)
        let pending = try #require(wheel.offset(in: target, scope: scope))
        let actual = target.rawPoint(screenPoint: mouse, offset: pending)
        #expect(abs(actual.x - anchor.x) < 1e-6 && abs(actual.y - anchor.y) < 1e-6)
        #expect(wheel.takeReadyOffset(scope: scope, declaredLayout: original,
            contentSize: original.contentSize, viewport: size) == nil)
        // Let the real parent @State publish and the native document/clip catch up.
        for _ in 0..<25 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let ready = try #require(probe.wheelLayout(size))
        #expect(abs(ready.zoom - zoom) < 1e-10)
        let nativeAnchor = ready.rawPoint(screenPoint: mouse, offset: scroll.contentView.bounds.origin)
        #expect(abs(nativeAnchor.x - anchor.x) < 1 && abs(nativeAnchor.y - anchor.y) < 1)
        #expect(wheel.offset(in: target, scope: scope) == nil, "Only the matching final layout consumes the wheel offset")
        print("WHEEL_NODE_MENUS direction=\(direction) bodies=\(bodies.values.reduce(0,+)) menus=\(menus.values.reduce(0,+)) nodes=\(bodies.count)")
        #expect(bodies.count == graph.nodes.count && bodies.values.allSatisfy { $0 > 0 })
        #expect(menus == bodies, "Each real zoom body shares one fresh menu across popup, context menu and accessibility")
        print("WHEEL_GLASS direction=\(direction) work=\(glassUpdates) builds=\(owner.glassFields.builds-buildsBefore) wall_ms=\((ProcessInfo.processInfo.systemUptime-began)*1000)")
        #expect(glassUpdates["refresh", default: 0] < 80,
            "Four accumulated events must not rebuild the optical background at every intermediate native notification")
        let finalSurfaces = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }.filter { $0.usesContinuousGlass }
        try #require(!finalSurfaces.isEmpty)
        for surface in finalSurfaces {
            let parameters = try #require(surface.continuousGlassParameters)
            #expect(parameters.size == surface.bounds.size && parameters.rect == owner.coordinates(for:surface).rect)
            #expect(surfaces.contains { $0 === surface }, "Zoom retains native decorative hosts")
        }
        #expect(owner.decodeCount == 1)
        #expect(controller.graph == graph && controller.canUndo == undoBefore)
        try await store.close()
    }

    /// Fixed production content; timing is CPU submission/layout, never screen FPS.
    @Test(arguments: [4, 20, 100])
    func renderingWorkspaceLayerBaseline(nodeCount: Int) async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProjectStore.create(at: directory.appendingPathComponent("Baseline.dproject"), name: "Rendering fixture")
        let runtime = WorkbenchSession(engine: LocalGlassNoInference(), backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let controller = WorkflowController(services: .init(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }))
        await controller.load(); controller.addExample("template")
        for i in 4..<nodeCount { controller.addNode(operationID: "d.text.input", x: 20_000 + Double(i % 10) * 300, y: 20_000 + Double(i / 10) * 240) }
        let graph = try #require(controller.graph), beforeUndo = controller.canUndo
        let state = ChatDisplayPreferencesState(appearanceDirectory: directory.appendingPathComponent("Appearance"))
        let wallpaper = directory.appendingPathComponent("pattern.png"); try png(pattern(width: 1024, height: 768), at: wallpaper)
        await state.importWallpaper(wallpaper)
        func content(_ zoom: CGFloat) -> some View {
            WorkflowGraphSurface(controller: controller, graph: controller.graph,
                zoom: .constant(zoom), tool: .constant(.pointer), navigationRequest: .constant(nil),
                viewportInteractionLocked: .constant(false), viewContext: .init(projectID: controller.projectID, rootGraphID: graph.id, bodyPath: []),
                pendingConnection: .constant(nil), selectedConnectionID: .constant(nil), readOnly: false, onPlan: { _, _ in })
                .modifier(WorkbenchCanvasModifier(state: state)).environment(\.chatDisplayPreferences, state.preferences)
        }
        let host = NSHostingView(rootView: content(1)); host.frame = .init(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let surfaces = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }
        let canvas = try #require(surfaces.first { $0.isCanvas }), owner = try #require(canvas.owner)
        let probe = try #require(descendants(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first)
        let scroll = try #require(probe.enclosingScrollView)
        let layout = try #require(probe.wheelLayout(scroll.contentView.bounds.size))
        scroll.contentView.scroll(to: layout.centeredOffset(on: CGPoint(x: 550, y: 350)))
        host.layoutSubtreeIfNeeded()
        let visible = surfaces.filter { !$0.isCanvas && !$0.isGeometryOnly && !$0.visibleRect.isEmpty && $0.bounds.width > 0 && $0.bounds.height > 0 }
        try #require(!visible.isEmpty)
        let contexts = try visible.map { try #require(WorkbenchLocalRenderer.bitmap(width: Int(ceil($0.bounds.width * 2)), height: Int(ceil($0.bounds.height * 2)))) }
        let image = try #require(owner.glassImage(canvas: "#111D1A"))
        let geometries = visible.map { _ in WorkbenchLocalRenderer.RefractionGeometry() }
        var rows: [[String: Any]] = []
        for mode in ["A0-solid", "A1-background", "A2-refraction", "A4-readability"] {
            for v in visible { v.readability = .init(enabled: mode == "A4-readability", amount: 0.35) }
            for movement in ["pan", "zoom", "single-surface"] {
                var samples: [Double] = []
                for repeatID in 0..<3 { for tick in 0..<12 {
                    let start = ProcessInfo.processInfo.systemUptime
                    for (index, pair) in zip(visible, contexts).enumerated() {
                        if movement == "single-surface" && index != 0 { continue }
                        let (plate, c) = pair, coordinates = owner.coordinates(for: plate)
                        var rect = coordinates.rect
                        if movement == "zoom" { rect.size.width *= 1 + CGFloat(tick) / 12; rect.size.height *= 1 + CGFloat(tick) / 12 }
                        else { rect.origin.x += CGFloat(tick * 4); rect.origin.y += CGFloat(tick * 2) }
                        c.saveGState(); c.scaleBy(x: 2, y: 2)
                        WorkbenchLocalRenderer.draw(in: c, size: plate.bounds.size, rect: rect, viewport: .init(width: 1100, height: 760),
                            image: mode == "A0-solid" ? nil : image, canvas: "#111D1A", panel: "#1D2B25", strength: 0.55,
                            glass: mode != "A0-solid", refraction: mode != "A1-background", contour: plate.contour, geometry: geometries[index], opaqueSource: true)
                        if mode == "A4-readability" { WorkbenchReadabilityRegistry.paint(owner.readability.effect(for: plate), in: c, view: plate) }
                        c.restoreGState()
                    }
                    samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    _ = repeatID
                } }
                let ordered = samples.sorted()
                rows.append(["mode": mode, "movement": movement, "nodes": nodeCount, "visiblePlates": visible.count,
                    "samples_ms": samples, "p50_ms": ordered[ordered.count/2], "p95_ms": ordered[Int(Double(ordered.count-1)*0.95)],
                    "p99_ms": ordered.last!, "kind": "Legacy CG manual background draws, not current GPU or FPS", "sourceBytes": owner.retainedBytes])
            }
        }
        if let destination = ProcessInfo.processInfo.environment["D_GLASS_EVIDENCE_DIR"] {
            let url = URL(fileURLWithPath: destination); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: url.appendingPathComponent("layers-\(nodeCount).json"))
            let layers = descendants(host).map { view in ["type": String(describing: type(of: view)), "bounds": NSStringFromRect(view.bounds),
                "frame": NSStringFromRect(view.frame), "contentsScale": String(describing: view.layer?.contentsScale),
                "rasterized": String(describing: view.layer?.shouldRasterize), "rasterScale": String(describing: view.layer?.rasterizationScale)] }
            try JSONSerialization.data(withJSONObject: layers, options: [.prettyPrinted, .sortedKeys]).write(to: url.appendingPathComponent("layers-host-\(nodeCount).json"))
        }
        #expect(controller.graph == graph && controller.canUndo == beforeUndo && owner.decodeCount == 1)
        try await store.close()
    }

    @Test func realWorkflowNodesCrossRetainedHostAndKeepViewportMapping() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = try await ProjectStore.create(at:root.appendingPathComponent("Test.dproject"),name:"Synthetic nodes")
        let runtime = WorkbenchSession(engine:LocalGlassNoInference(),backendID:"never",
            status:{ .init(activeRunID:nil,phase:nil,queuedRunIDs:[]) },shutdown:{},cleanup:{},validateModel:{ _ in })
        let controller = WorkflowController(services:.init(store:store,session:runtime,
            resolveText:{ throw WorkflowIssue("No model") },resolveImage:{ throw WorkflowIssue("No model") }))
        await controller.load(); controller.addExample("template")
        let graph = try #require(controller.graph)
        let state = ChatDisplayPreferencesState(appearanceDirectory:root.appendingPathComponent("Appearance"))
        let wallpaper = root.appendingPathComponent("source.png"); try png(pattern(width: 1024, height: 768),at:wallpaper)
        await state.importWallpaper(wallpaper)
        func content(_ zoom:CGFloat) -> some View {
            RetainedContentHost(content:WorkflowGraphSurface(controller:controller,graph:controller.graph,
                zoom:.constant(zoom),tool:.constant(.pointer),navigationRequest:.constant(nil),
                viewportInteractionLocked:.constant(false),viewContext:.init(projectID:controller.projectID,
                    rootGraphID:controller.rootGraph?.id,bodyPath:[]),pendingConnection:.constant(nil),
                selectedConnectionID:.constant(nil),readOnly:false,onPlan:{ _,_ in }),visible:true,identifier:"glass-workflow")
                .modifier(WorkbenchCanvasModifier(state:state)).environment(\.chatDisplayPreferences,state.preferences)
        }
        let host = NSHostingView(rootView:content(1)); host.frame = CGRect(x:0,y:0,width:1100,height:760)
        let window = NSWindow(contentRect:host.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view:NSView)->[NSView] { view.subviews.flatMap { [$0]+descendants($0) } }
        func settle() async throws { for _ in 0..<35 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(10)) } }
        try await settle()
        let surfaces = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }
        let canvas = try #require(surfaces.first { $0.isCanvas }), owner = try #require(canvas.owner)
        let node = try #require(surfaces.first { !$0.isCanvas })
        try #require(owner.image != nil && surfaces.count >= graph.nodes.count + 1)
        #expect(surfaces.allSatisfy { $0.owner === owner })
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.max {
            ($0.documentView?.bounds.width ?? 0) < ($1.documentView?.bounds.width ?? 0)
        })
        let plates = surfaces.filter { !$0.isCanvas && !$0.isGeometryOnly && $0.bounds.width > 0 && $0.bounds.height > 0 }
        let bitmaps = try plates.map { try #require(WorkbenchLocalRenderer.bitmap(width: Int(ceil($0.bounds.width * 2)), height: Int(ceil($0.bounds.height * 2)))) }
        let started = Date()
        NSGraphicsContext.saveGraphicsState()
        for tick in 0..<60 {
            scroll.contentView.scroll(to: CGPoint(x: tick % 30,y: tick % 20))
            for (plate, bitmap) in zip(plates, bitmaps) {
                bitmap.saveGState(); bitmap.scaleBy(x: 2,y: 2)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
                plate.draw(plate.bounds); bitmap.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        print("REAL_NODE_PAN nodes=\(graph.nodes.count) plates=\(plates.count) ticks=60 seconds=\(Date().timeIntervalSince(started))")
        #expect(graph.nodes.count == 4 && controller.graph == graph)
        let bytes = owner.retainedBytes
        for zoom:CGFloat in [0.5,1,1.5,2,4] {
            host.rootView = content(zoom); try await settle()
            let current = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }
            #expect(current.contains { $0 === node })
            let wireLayers = descendants(host).compactMap { $0 as? WorkflowConnectionDrawingView }
            try #require(wireLayers.count == 1)
            let wires = try #require(wireLayers.first)
            #expect(wires.drawing.strokes.count == graph.connections.count)
            #expect(wires.drawing.bounds.width <= scroll.contentView.bounds.width + 1)
            #expect(wires.drawing.bounds.height <= scroll.contentView.bounds.height + 1)
            #expect(wires.layer?.contents == nil, "The large layout wrapper must not own a raster image")
            let rect = node.convert(node.bounds,to:canvas)
            #expect(rect.width > 0 && rect.height > 0)
            let effective = WorkflowCanvasLayoutPolicy.clampedInteractiveZoom(zoom,current:zoom)
            #expect(abs(rect.width / node.bounds.width - 1) < 0.02, "Native content must not be stretched by an ancestor raster transform")
            let plates = descendants(host).compactMap { $0 as? WorkflowNodePlateView }
            #expect(plates.count == graph.nodes.count)
            for plate in plates {
                #expect(abs(plate.bounds.width - 240 * effective) < 0.5)
                #expect(abs(plate.convert(plate.bounds, to: canvas).width / plate.bounds.width - 1) < 0.02)
            }
            window.setFrameOrigin(CGPoint(x:100+zoom*10,y:100))
            #expect(node.convert(node.bounds,to:canvas) == rect)
        }
        #expect(controller.graph == graph)
        #expect(owner.decodeCount == 1 && owner.blurCount == 1 && owner.retainedBytes == bytes)
        try await store.close()
    }

    @Test(arguments: ["rounded", "capsule", "circle", "rectangle"], [0.0, 0.55, 1.0])
    func boundedRefractionMatchesOriginalPixels(shape: String, strength: Double) throws {
        let raw = try pattern(alpha: true)
        let prepared = try #require(WorkbenchLocalRenderer.opaqueSource(raw, canvas: "#111D1A"))
        let geometry = WorkbenchLocalRenderer.RefractionGeometry()
        let contour: (CGRect, CGFloat) -> CGPath = { rect, inset in
            let box = rect.insetBy(dx: inset, dy: inset)
            switch shape {
            case "rectangle": return CGPath(rect: box, transform: nil)
            case "circle": return CGPath(ellipseIn: box, transform: nil)
            case "capsule": return CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil)
            default: return CGPath(roundedRect: box, cornerWidth: 16, cornerHeight: 16, transform: nil)
            }
        }
        for size in [CGSize(width: 22, height: 22), CGSize(width: 42, height: 22), CGSize(width: 100, height: 80)] {
        for image in [raw, prepared] {
        for zoom: CGFloat in [0.5, 1, 2] {
            for origin in [CGPoint(x: 20.25, y: 10.75), CGPoint(x: -12.5, y: 52.25)] {
                let rect = CGRect(origin: origin, size: CGSize(width: size.width * zoom, height: size.height * zoom))
                func render(_ optimized: Bool) throws -> [UInt8] {
                    let c = try #require(WorkbenchLocalRenderer.bitmap(width: 200, height: 160)); c.scaleBy(x: 2, y: 2)
                    WorkbenchLocalRenderer.draw(in: c, size: size, rect: rect, viewport: CGSize(width: 260, height: 180), image: image,
                        canvas: "#111D1A", panel: "#1D2B25", strength: strength, glass: true, contour: contour,
                        geometry: optimized ? geometry : nil, opaqueSource: image === prepared)
                    return Array(UnsafeBufferPointer(start: try #require(c.data).assumingMemoryBound(to: UInt8.self), count: c.bytesPerRow * c.height))
                }
                let old = try render(false), new = try render(true)
                #expect(new.elementsEqual(old), "Optimizing the excluded centre must preserve every output byte: shape=\(shape), strength=\(strength), zoom=\(zoom), origin=\(origin)")
            }
        }
        }
        }
    }

    @Test(arguments: [false, true])
    func geometryChangesRedrawOnlyVisibleWallpaperConsumers(wallpaper: Bool) async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let owner = WorkbenchBackgroundOwner()
        let root = WorkbenchBackgroundNSView(frame: .init(x: 0,y: 0,width: 640,height: 480))
        root.owner = owner; root.isCanvas = true; owner.root = root
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.contentView = nil; window.close() }
        let scroll = NSScrollView(frame: root.bounds); root.addSubview(scroll)
        let document = WorkbenchBackgroundNSView(frame: .init(x: 0,y: 0,width: 30_000,height: 20_000))
        document.isGeometryOnly = true; scroll.documentView = document
        let inside = WorkbenchBackgroundNSView(frame: .init(x: 100,y: 100,width: 150,height: 80))
        let outside = WorkbenchBackgroundNSView(frame: .init(x: 15_000,y: 10_000,width: 150,height: 80))
        for plate in [inside,outside] { plate.owner = owner; document.addSubview(plate); owner.surfaces.add(plate) }
        let front = WorkbenchBackgroundNSView(frame:.init(x:110,y:110,width:100,height:50))
        front.owner = owner; front.readability = .init(enabled:true,amount:1)
        root.addSubview(front); owner.surfaces.add(front)
        window.contentView?.layoutSubtreeIfNeeded()
        if wallpaper {
            // A uniform source isolates overlap from wallpaper-complexity patches.
            let bitmap = try #require(WorkbenchLocalRenderer.bitmap(width:16,height:16))
            bitmap.setFillColor(NSColor.gray.cgColor); bitmap.fill(.init(x:0,y:0,width:16,height:16))
            let file = directory.appendingPathComponent("source.png"); try png(#require(bitmap.makeImage()),at: file)
            owner.load(file)
            for _ in 0..<100 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
            try #require(owner.image != nil)
        }
        for _ in 0..<5 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let counts = [inside,outside,root].map(\.geometryInvalidationCount)
        let before = owner.drawCount
        #expect(!owner.readability.effect(for:front).patches.isEmpty)
        scroll.contentView.scroll(to: .init(x: 12,y: 8))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        #expect(inside.geometryInvalidationCount == counts[0] + (wallpaper ? 1 : 0))
        #expect(outside.geometryInvalidationCount == counts[1] && root.geometryInvalidationCount == counts[2])
        #expect(owner.drawCount == before, "Notifications do not synchronously draw")
        let once = inside.geometryInvalidationCount
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        #expect(inside.geometryInvalidationCount == once, "Duplicate geometry does not re-invalidate")
        scroll.contentView.scroll(to: .init(x: 15_000,y: 10_000))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        #expect(outside.geometryInvalidationCount == counts[1] + (wallpaper ? 1 : 0))
        #expect(inside.geometryInvalidationCount == once)
        #expect(owner.readability.effect(for:front).patches.isEmpty,
            "Leaving the viewport removes overlap synchronously, before deferred optical layout")
        root.layoutSubtreeIfNeeded()
        #expect(!inside.usesContinuousGlass)
        if wallpaper {
            let parameters = try #require(outside.continuousGlassParameters)
            #expect(parameters.rect == owner.coordinates(for:outside).rect)
        }
        scroll.contentView.scroll(to:.zero)
        NotificationCenter.default.post(name:NSView.boundsDidChangeNotification,object:scroll.contentView)
        #expect(!owner.readability.effect(for:front).patches.isEmpty)
        root.layoutSubtreeIfNeeded()
        if wallpaper { #expect(inside.usesContinuousGlass && !outside.usesContinuousGlass) }
        owner.load(nil, blur: false)
        #expect(owner.image == nil)
        print("GEOMETRY_INVALIDATIONS wallpaper=\(wallpaper) visible=\(inside.geometryInvalidationCount-counts[0]) entered=\(outside.geometryInvalidationCount-counts[1]) root=\(root.geometryInvalidationCount-counts[2])")

    }

    @Test(arguments: [false, true])
    func glassZoomAndRepeatedUpdatesProfile(zooming: Bool) throws {
        let image = try pattern(width: 640, height: 480)
        let size = CGSize(width: 320, height: 240)
        let geometry = WorkbenchLocalRenderer.RefractionGeometry()
        let contour: (CGRect, CGFloat) -> CGPath = { rect, inset in
            RoundedRectangle(cornerRadius: 24, style: .continuous).inset(by: inset).path(in: rect).cgPath
        }
        let context = try #require(WorkbenchLocalRenderer.bitmap(width: 640, height: 480))
        context.scaleBy(x: 2, y: 2)
        let start = Date()
        for tick in 0..<60 {
            let zoom = zooming ? 0.65 + CGFloat(tick % 30) * 0.02 : 1
            WorkbenchLocalRenderer.draw(in: context, size: size,
                rect: CGRect(x: CGFloat(100 + tick), y: 60, width: size.width * zoom, height: size.height * zoom),
                viewport: CGSize(width: 1100, height: 760), image: image,
                canvas: "#111D1A", panel: "#1D2B25", strength: 0.55, glass: true,
                contour: contour, geometry: geometry)
        }
        print("ZOOM_GLASS_PROFILE zooming=\(zooming) frames=60 seconds=\(Date().timeIntervalSince(start))")
        #expect(context.makeImage() != nil)
    }

    @Test func canvasPanKeepsDisabledReadabilityIdle() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pan.png"); try png(pattern(width: 1024, height: 768), at: file)
        let owner = WorkbenchBackgroundOwner()
        let root = WorkbenchBackgroundNSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        root.isCanvas = true; root.owner = owner; owner.root = root
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.contentView = nil; window.close() }
        let scroll = NSScrollView(frame: root.bounds); root.addSubview(scroll)
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 2200, height: 1400)); scroll.documentView = document
        var plates: [WorkbenchBackgroundNSView] = []
        for row in 0..<2 { for column in 0..<2 {
            let plate = WorkbenchBackgroundNSView(frame: CGRect(x: 100 + column * 400, y: 100 + row * 280, width: 320, height: 240))
            plate.owner = owner; plate.contour = { rect, inset in CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: 16, cornerHeight: 16, transform: nil) }
            document.addSubview(plate); owner.surfaces.add(plate); plates.append(plate)
        } }
        owner.load(file)
        for _ in 0..<100 where owner.blurred == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(owner.blurred != nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let before = owner.readability.geometryUpdates, decode = owner.decodeCount, blur = owner.blurCount
        let context = try #require(WorkbenchLocalRenderer.bitmap(width: 640, height: 480))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.scaleBy(x: 2, y: 2)
        let start = Date()
        print("PAN_PROFILE_START pid=\(ProcessInfo.processInfo.processIdentifier)")
        for tick in 1...120 {
            scroll.contentView.scroll(to: CGPoint(x: tick % 60, y: tick % 30))
            for plate in plates { plate.draw(plate.bounds) }
        }
        print("PAN_PROFILE seconds=\(Date().timeIntervalSince(start)) geometry=\(owner.readability.geometryUpdates - before) draws=\(owner.drawCount)")
        #expect(owner.readability.geometryUpdates == before, "Disabled enhancement must not maintain the overlap spatial index while panning")
        #expect(owner.decodeCount == decode && owner.blurCount == blur)
        #expect(plates.allSatisfy { $0.owner === owner && !$0.readability.enabled })
    }

    @Test func changingAppearanceOwnerWithSameFilenameRefreshesOnlyBackground() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let name = UUID().uuidString+".png"
        var states: [ChatDisplayPreferencesState] = []
        for i in 0..<2 {
            let directory = root.appendingPathComponent("owner-\(i)")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try png(pattern(i),at:directory.appendingPathComponent(name))
            let state = ChatDisplayPreferencesState(appearanceDirectory:directory)
            var value = state.preferences; value.appearance?.local?.wallpaper = name
            try #require(state.update(value)); states.append(state)
        }
        func content(_ state:ChatDisplayPreferencesState) -> some View {
            Text("Stable content").frame(width:200,height:100).workbenchPanel()
                .modifier(WorkbenchCanvasModifier(state:state)).environment(\.chatDisplayPreferences,state.preferences)
        }
        let host = NSHostingView(rootView:content(states[0])); host.frame = CGRect(x:0,y:0,width:400,height:300)
        func descendants(_ view:NSView)->[NSView] { view.subviews.flatMap { [$0]+descendants($0) } }
        func settle() async throws { for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(10)) } }
        try await settle()
        let canvas = try #require(descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }.first { $0.isCanvas })
        let owner = try #require(canvas.owner); try #require(owner.key == states[0].wallpaperURL() && owner.image != nil)
        let first = owner.image
        host.rootView = content(states[1]); try await settle()
        #expect(canvas.owner === owner && owner.key == states[1].wallpaperURL())
        #expect(owner.image != nil && owner.image !== first && owner.decodeCount == 2)
    }
    @Test func reviewSeedIsConsumedAndResetDoesNotResurrectIt() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let suite = "D.LocalGlassTests."+UUID().uuidString
        let settings = try #require(UserDefaults(suiteName:suite)); defer { settings.removePersistentDomain(forName:suite) }
        var seed = ChatDisplayPreferences(); var appearance = WorkbenchAppearance(); appearance.local = WorkbenchLocalAppearance()
        appearance.local?.strength = 0.9; seed.appearance = appearance
        try JSONEncoder().encode(seed).write(to:root.appendingPathComponent("initial-preferences.json"))
        let state = ChatDisplayPreferencesState(settings:settings,appearanceDirectory:root)
        #expect(state.preferences == seed)
        state.reset()
        let cold = ChatDisplayPreferencesState(settings:settings,appearanceDirectory:root)
        #expect(cold.preferences.appearance?.local?.strength == 0.55)
    }

    @Test(arguments:["solid","lightweight","reduced-transparency","high-contrast"])
    func fallbackKeepsWallpaperButDoesNotPrepareBlur(mode:String) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("source.png"); try png(pattern(),at:source)
        let state = ChatDisplayPreferencesState(appearanceDirectory:root.appendingPathComponent("Appearance"))
        await state.importWallpaper(source)
        var value = state.preferences
        if mode == "solid" { value.appearance?.local?.material = .solid }
        if mode == "lightweight" { value.appearance?.lightweight = true }
        try #require(state.update(value))
        let appearance = state.preferences.resolvedAppearance
        let policy = WorkbenchEffectsPolicy(appearance:appearance,reduceMotion:false,
            reduceTransparency:mode == "reduced-transparency",increasedContrast:mode == "high-contrast")
        let shouldBlur = appearance.local?.material == .glass && policy.usesCanvasBlend
        #expect(!shouldBlur)
        // The SDK's accessibility environment entries are read-only. Inject into
        // the same policy/owner path; never change the user's system preferences.
        if mode == "reduced-transparency" || mode == "high-contrast" {
            let owner = WorkbenchBackgroundOwner(); owner.load(state.wallpaperURL(),blur:shouldBlur)
            for _ in 0..<100 where owner.image == nil { try await Task.sleep(for:.milliseconds(10)) }
            #expect(owner.image != nil && owner.blurred == nil && owner.blurCount == 0)
            return
        }
        let host = NSHostingView(rootView:Text("Readable").frame(width:200,height:100).workbenchPanel()
            .modifier(WorkbenchCanvasModifier(state:state)).environment(\.chatDisplayPreferences,state.preferences))
        host.frame = CGRect(x:0,y:0,width:400,height:300)
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(10)) }
        func descendants(_ view:NSView)->[NSView] { view.subviews.flatMap { [$0]+descendants($0) } }
        let surfaces = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }
        let owner = try #require(surfaces.first { $0.isCanvas }?.owner)
        #expect(owner.image != nil && owner.blurred == nil && owner.blurCount == 0)
        #expect(surfaces.filter { !$0.isCanvas }.allSatisfy { !$0.drawsGlass })
    }

    @Test func localDecorationDoesNotReceiveInputAndBridgeKeepsOwner() {
        let view = WorkbenchBackgroundNSView(frame: CGRect(x:0,y:0,width:100,height:100))
        #expect(view.hitTest(CGPoint(x:50,y:50)) == nil)
        #expect(view.isOpaque)
        let owner = WorkbenchBackgroundOwner()
        let root = RetainedContentRoot(content: Text("unchanged"), lifecycle: MetadataEditorLifecycle(), background: owner)
        #expect(root.background === owner)
    }
}

extension WorkbenchLocalGlassTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func featureGuideOwnsItsWindowGlassAndPreservesSearch(scheme: ColorScheme) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ChatDisplayPreferencesState(appearanceDirectory: root.appendingPathComponent("Appearance"))
        let source = root.appendingPathComponent("fixture.png"); try png(pattern(), at: source)
        await state.importWallpaper(source)
        let parent = NSHostingView(rootView: Text("Parent").frame(width: 700,height: 500).workbenchPresentation(state: state))
        let main = NSWindow(contentRect: .init(x: 0,y: 0,width: 700,height: 500),styleMask: [.titled],backing: .buffered,defer: false)
        main.isReleasedWhenClosed = false; main.contentView = parent
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        func settle(_ v: NSView) async throws { for _ in 0..<20 { v.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) } }
        try await settle(parent)
        let parentCanvas = try #require(descendants(parent).compactMap { $0 as? WorkbenchBackgroundNSView }.first { $0.isCanvas })
        let parentOwner = try #require(parentCanvas.owner); try #require(parentOwner.image != nil)
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"]), help = WorkbenchHelpStore()
        let presentation = WorkbenchHelpPresentation(featureID: nil, token: nil, context: nil)
        func content() -> some View {
            WorkbenchFeatureGuide(presentation: presentation, store: help)
                .environment(\.workbenchAppearanceState, state).environment(\.workbenchBackground,parentOwner)
                .environment(\.chatDisplayPreferences,state.preferences).environment(\.dLanguageStore,language)
                .environment(\.colorScheme,scheme)
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 800,height: 600),styleMask: [.titled],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close(); main.contentView = nil; main.close() }
        try await settle(host)
        let surfaces = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }
        let canvas = try #require(surfaces.first { $0.isCanvas })
        let owner = try #require(canvas.owner), image = try #require(owner.image)
        #expect(owner !== parentOwner && owner.root === canvas && owner.root?.window === window)
        #expect(image === parentOwner.image && owner.blurred === parentOwner.blurred)
        #expect(surfaces.filter { !$0.isGeometryOnly }.allSatisfy { $0.owner === owner })
        let input = try #require(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        input.stringValue = "用户说明 / Save"
        for strength in [0.0, 0.55, 1.0] {
            var value = state.preferences; value.appearance?.local?.strength = strength
            try #require(state.update(value)); try language.select(strength == 0 ? "en" : "zh-Hans")
            host.rootView = content(); try await settle(host)
            let current = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }
            #expect(current.contains { $0 === canvas } && owner.image === image)
            #expect(current.filter { !$0.isCanvas && !$0.isGeometryOnly }.allSatisfy { abs($0.strength - strength)<0.001 })
            #expect(descendants(host).contains { $0 === input } && input.stringValue == "用户说明 / Save")
        }
        #expect(help.presentation == nil && owner.decodeCount == 0 && owner.blurCount == 0)
    }

    // Recording/replay is deliberate: an AA preference in the source context
    // cannot be the correctness condition for fractional coverage at a lens edge.
    @Test(arguments: ["circle", "capsule", "rounded"], [0.0, 0.5, 1.0])
    func recordedSmallGlassHasNoRepeatedDarkArcs(shape: String, alpha: Double) async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(WorkbenchLocalRenderer.bitmap(width: 160, height: 100))
        source.setFillColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: alpha))
        source.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        let file = directory.appendingPathComponent("uniform.png"); try png(#require(source.makeImage()), at: file)
        let owner = WorkbenchBackgroundOwner()
        let root = WorkbenchBackgroundNSView(frame: CGRect(x: 0,y: 0,width: 160,height: 100))
        root.isCanvas = true; root.owner = owner; owner.root = root
        let plate = WorkbenchBackgroundNSView(frame: CGRect(x: 40,y: 40,width: shape == "capsule" ? 42 : 22,height: 22))
        plate.owner = owner; plate.strength = 1; plate.palette = .defaultDark; root.addSubview(plate)
        plate.contour = { rect, inset in
            switch shape {
            case "circle": return Circle().inset(by: inset).path(in: rect).cgPath
            case "capsule": return Capsule().inset(by: inset).path(in: rect).cgPath
            default: return RoundedRectangle(cornerRadius: 5,style: .continuous).inset(by: inset).path(in: rect).cgPath
            }
        }
        owner.load(file)
        for _ in 0..<100 where owner.blurred == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(owner.blurred != nil)
        for zoom: CGFloat in [0.5, 0.81, 1.13] {
            let bytes = NSMutableData(); var page = CGRect(x: 0,y: 0,width: 128,height: 96)
            let consumer = try #require(CGDataConsumer(data: bytes))
            let recording = try #require(CGContext(consumer: consumer, mediaBox: &page, nil))
            recording.beginPDFPage(nil)
            recording.translateBy(x: 12.375,y: 12.125); recording.scaleBy(x: 2 * zoom,y: 2 * zoom)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: recording, flipped: true)
            plate.refreshGlass()
            let parameters=try #require(plate.continuousGlassParameters)
            let optical=try ContinuousGlassPixelProbe.image(parameters,density:2*zoom)
            // Record the actual Metal pixels once under the original exact clip.
            // A direct NSView.draw cannot record its separate Shader child.
            recording.addPath(plate.contour!(plate.bounds,0));recording.clip()
            recording.draw(optical,in:plate.bounds)
            NSGraphicsContext.restoreGraphicsState()
            recording.endPDFPage(); recording.closePDF()
            let replay = try #require(WorkbenchLocalRenderer.bitmap(width: 128,height: 96))
            let provider = try #require(CGDataProvider(data: bytes))
            let document = try #require(CGPDFDocument(provider))
            replay.drawPDFPage(try #require(document.page(at: 1)))
            let pixels = try #require(replay.data).assumingMemoryBound(to: UInt8.self)
            let centerX = Int(12.375 + plate.bounds.midX * 2 * zoom)
            let centerY = 95 - Int(12.125 + plate.bounds.midY * 2 * zoom)
            let center = (centerY * 128 + centerX) * 4
            var largestDifference = 0
            for y in 0..<96 { for x in 0..<128 {
                let point = CGPoint(x: (CGFloat(x) + 0.5 - 12.375) / (2 * zoom),
                                    y: (95.5 - CGFloat(y) - 12.125) / (2 * zoom))
                guard plate.contour!(plate.bounds, 1.5).contains(point) else { continue }
                let offset = (y * 128 + x) * 4
                for channel in 0..<3 { largestDifference = max(largestDifference, abs(Int(pixels[offset + channel]) - Int(pixels[center + channel]))) }
                #expect(pixels[offset + 3] == 255)
            } }
            #expect(largestDifference <= 2, "Uniform glass must stay uniform through recorded curved clips: \(shape), alpha=\(alpha), zoom=\(zoom), deviation=\(largestDifference)")
            if let evidence = ProcessInfo.processInfo.environment["D_GLASS_EVIDENCE_DIR"] {
                try png(#require(replay.makeImage()), at: URL(fileURLWithPath: evidence).appendingPathComponent("recorded-\(shape)-\(alpha)-\(zoom).png"))
            }
        }
    }

    @Test func preparedGlassCacheIsBoundedAndFollowsSourceAndCanvas() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.png"), b = directory.appendingPathComponent("b.png")
        try png(pattern(alpha: true), at: a); try png(pattern(1), at: b)
        let owner = WorkbenchBackgroundOwner(); owner.load(a)
        for _ in 0..<100 where owner.blurred == nil { try await Task.sleep(for: .milliseconds(10)) }
        let raw = try #require(owner.image), blurred = try #require(owner.blurred)
        let originalBytes = owner.retainedBytes
        let prepared = try #require(owner.glassImage(canvas: "#111D1A"))
        #expect(prepared.alphaInfo == .noneSkipLast)
        let boundedBytes = originalBytes + prepared.bytesPerRow * prepared.height
        for _ in 0..<100 {
            owner.invalidate()
            #expect(owner.glassImage(canvas: "#111D1A") === prepared)
        }
        #expect(owner.glassPreparationCount == 1 && owner.retainedBytes == boundedBytes)
        let light = try #require(owner.glassImage(canvas: "#EEEEEE"))
        #expect(light !== prepared && owner.glassPreparationCount == 2 && owner.retainedBytes == boundedBytes)
        #expect(owner.image === raw && owner.blurred === blurred, "Canvas and titlebar retain their original sources")
        owner.load(b)
        #expect(owner.retainedBytes == 0 && owner.glassImage(canvas: "#EEEEEE") == nil)
        for _ in 0..<100 where owner.blurred == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner.glassImage(canvas: "#EEEEEE") !== light && owner.glassPreparationCount == 3)
        owner.load(b, blur: false)
        #expect(owner.glassImage(canvas: "#EEEEEE") == nil && owner.retainedBytes == 0)
        for _ in 0..<100 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner.blurred == nil && owner.glassImage(canvas: "#EEEEEE") == nil)
        owner.load(directory.appendingPathComponent("missing.png"))
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner.retainedBytes == 0 && owner.glassImage(canvas: "#EEEEEE") == nil)
        owner.load(nil); #expect(owner.retainedBytes == 0)
    }

    @Test(arguments: ["left", "right", "top", "bottom"], [0.0, 0.5, 1.0])
    func recordedViewportEdgesMatchSingleUnclippedSample(side: String, alpha: Double) throws {
        let canvas = "#0D0D0D", bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        let source = try #require(WorkbenchLocalRenderer.bitmap(width: 100, height: 100))
        source.setFillColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: alpha))
        source.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let raw = try #require(source.makeImage())
        let image = try #require(WorkbenchLocalRenderer.opaqueSource(raw, canvas: canvas))
        let rect: CGRect
        switch side {
        case "left": rect = bounds.offsetBy(dx: -30, dy: 20)
        case "right": rect = bounds.offsetBy(dx: 90, dy: 20)
        case "top": rect = bounds.offsetBy(dx: 20, dy: -30)
        default: rect = bounds.offsetBy(dx: 20, dy: 90)
        }
        func target(_ m: CGFloat) -> CGRect {
            CGRect(x: 20 + (-rect.minX - 20) * m, y: 20 + (-rect.minY - 20) * m,
                   width: 100 * m, height: 100 * m)
        }
        let outline: (CGRect, CGFloat) -> CGPath = { r, inset in
            RoundedRectangle(cornerRadius: 8).inset(by: inset).path(in: r).cgPath
        }
        func recorded(singleSample: CGFloat?) throws -> [UInt8] {
            let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 192, height: 192)
            let consumer = try #require(CGDataConsumer(data: data))
            let c = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            c.beginPDFPage(nil); c.translateBy(x: 4.375, y: 4.125); c.scaleBy(x: 4, y: 4)
            if let m = singleSample {
                // Independent reference: one source image over one canvas,
                // without refraction rings, reused pixels or transparency groups.
                c.setFillColor(WorkbenchLocalRenderer.color(canvas)); c.fill(bounds)
                let box = target(m)
                c.saveGState(); c.translateBy(x: box.minX, y: box.maxY); c.scaleBy(x: 1, y: -1)
                c.draw(image, in: CGRect(origin: .zero, size: box.size)); c.restoreGState()
                c.setFillColor(WorkbenchLocalRenderer.color(canvas).copy(alpha: 0.18)!); c.fill(bounds)
            } else {
                WorkbenchLocalRenderer.draw(in: c, size: bounds.size, rect: rect, viewport: CGSize(width: 100, height: 100),
                    image: image, canvas: canvas, panel: canvas, strength: 1, glass: true,
                    contour: outline, geometry: .init(), opaqueSource: true)
            }
            c.endPDFPage(); c.closePDF()
            let provider = try #require(CGDataProvider(data: data)), pdf = try #require(CGPDFDocument(provider))
            let replay = try #require(WorkbenchLocalRenderer.bitmap(width: 192, height: 192))
            replay.drawPDFPage(try #require(pdf.page(at: 1)))
            let p = try #require(replay.data).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: p, count: replay.bytesPerRow * replay.height))
        }
        let actual = try recorded(singleSample: nil)
        var deviation = 0, compared = 0, sourceEdgePixels = 0
        for i in 0..<12 {
            let m = 1 + sin((CGFloat(i) + 0.5) / 12 * .pi) * 5.5 / 20
            let expected = try recorded(singleSample: m), box = target(m)
            let outer = outline(bounds, CGFloat(i) * 10 / 12)
            let inner = outline(bounds, CGFloat(i + 1) * 10 / 12)
            for y in 0..<192 { for x in 0..<192 {
                let point = CGPoint(x: (CGFloat(x) + 0.5 - 4.375) / 4, y: (191.5 - CGFloat(y) - 4.125) / 4)
                let corners = [-0.126, 0.126].flatMap { dx in [-0.126, 0.126].map { dy in
                    CGPoint(x: point.x + dx, y: point.y + dy)
                } }
                // Whole device pixels inside one ring must equal that one
                // unclipped sample, including the source image's own edge.
                // Curved fractional ring coverage is tested by uniform replay.
                guard corners.allSatisfy({ outer.contains($0) && !inner.contains($0) }) else { continue }
                compared += 1
                if [abs(point.x - box.minX), abs(point.x - box.maxX),
                    abs(point.y - box.minY), abs(point.y - box.maxY)].min()! <= 0.25 { sourceEdgePixels += 1 }
                for channel in 0..<4 { let offset = (y * 192 + x) * 4 + channel
                    deviation = max(deviation, abs(Int(actual[offset]) - Int(expected[offset])))
                }
            } }
        }
        #expect(compared > 1000 && sourceEdgePixels > 0, "Reference must include image boundaries, not skip them")
        #expect(deviation <= 2, "Every fully covered ring pixel must equal one sample: \(side), alpha=\(alpha), deviation=\(deviation)")
    }

}
