import AppKit
import AVKit
import DInference
@testable import DWorkbench
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import UI

private actor LocalGlassNoInference: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw WorkflowIssue("Local glass fixture never submits inference")
    }
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
    private func titlebarPixel(_ canvas: WorkbenchBackgroundNSView, external: CGColor) throws -> [UInt8] {
        let surface = try #require(canvas.titlebar?.surface)
        try #require(surface.superview === canvas.window?.contentView && !surface.isHidden)
        let c = try #require(WorkbenchLocalRenderer.bitmap(width: Int(surface.bounds.width), height: Int(surface.bounds.height)))
        c.setFillColor(external); c.fill(surface.bounds)
        c.translateBy(x: 0, y: CGFloat(c.height)); c.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        surface.draw(surface.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(c.data).assumingMemoryBound(to: UInt8.self)
        let offset = Int(surface.bounds.midY) * c.bytesPerRow + Int(surface.bounds.midX) * 4
        return Array(UnsafeBufferPointer(start: data + offset, count: 4))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func titlebarKeepsLegacyColorBlendWithoutMigratingPreferences(scheme: ColorScheme) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ChatDisplayPreferencesState(appearanceDirectory: root)
        var value = state.preferences; value.appearance?.local = nil
        try #require(state.update(value))
        func content() -> some View {
            Text("Legacy").frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(WorkbenchCanvasModifier(state: state, stylesWindowTitlebar: true))
                .environment(\.colorScheme, scheme)
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        var images: [[UInt8]] = []
        for blend in [0.0, 0.83, 1.0] {
            value.appearance?.backgroundTransparency = blend; try #require(state.update(value))
            host.rootView = content()
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let canvas = try #require(children(host).compactMap { $0 as? WorkbenchBackgroundNSView }.first { $0.isCanvas })
            #expect(canvas.legacyTitlebarBlend == blend && !canvas.drawsGlass)
            #expect(state.preferences == value && state.preferences.appearance?.local == nil)
            let pixel = try titlebarPixel(canvas, external: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            let expected = try #require(NSColor(canvas.palette.panelFill(canvasBlend: blend)).usingColorSpace(.sRGB))
            for (actual, expected) in zip(pixel.prefix(3), [expected.redComponent, expected.greenComponent, expected.blueComponent]) {
                #expect(abs(Double(actual) - Double(expected) * 255) <= 1)
            }
            #expect(pixel[3] == 255); images.append(pixel)
        }
        #expect(images[0] != images[1] && images[1] != images[2])
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func titlebarUsesCanvasMaterialWithoutMovingContentOrReplacingControls(scheme: ColorScheme) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ChatDisplayPreferencesState(appearanceDirectory: root.appendingPathComponent("Appearance"))
        let source = root.appendingPathComponent("source.png"); try png(pattern(), at: source)
        await state.importWallpaper(source)
        func content() -> some View {
            TextField("Top input", text: .constant("Native content"))
                .frame(height: 32).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .modifier(WorkbenchCanvasModifier(state: state, stylesWindowTitlebar: true))
                .environment(\.colorScheme, scheme).environment(\.chatDisplayPreferences, state.preferences)
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "D native title"
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0) }
        let movable = window.isMovableByWindowBackground, visibility = window.titleVisibility
        let appearance = window.appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        func settle() async throws {
            for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        try await settle()
        let canvas = try #require(children(host).compactMap { $0 as? WorkbenchBackgroundNSView }.first { $0.isCanvas })
        let chrome = try #require(canvas.titlebar), owner = try #require(canvas.owner)
        let input = try #require(children(host).compactMap { $0 as? NSTextField }.first)
        #expect(window.makeFirstResponder(input))
        let responder = window.firstResponder
        #expect(window.titlebarAppearsTransparent && window.styleMask.contains(.fullSizeContentView) && window.isOpaque)
        #expect(window.titlebarSeparatorStyle == .none && window.titleVisibility == visibility && window.title == "D native title")
        #expect(window.isMovableByWindowBackground == movable && window.contentView === host && window.appearance === appearance)
        #expect(zip(buttons, [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]).allSatisfy { $0 === window.standardWindowButton($1) })
        try #require(owner.image != nil && owner.blurred != nil)
        func checkGeometry() throws {
            let band = chrome.frame(in: canvas)
            #expect(!band.isEmpty && !band.isNull)
            let nativeBand = canvas.convert(band, to: nil)
            #expect(abs(nativeBand.minY - window.contentLayoutRect.maxY) < 1)
            #expect(abs(nativeBand.maxY - host.convert(host.bounds, to: nil).maxY) < 1)
            #expect(input.convert(input.bounds, to: nil).maxY <= window.contentLayoutRect.maxY,
                "Only the background extends into the native titlebar; input stays below it")
            #expect(canvas.hitTest(band.origin) == nil)
        }
        try checkGeometry()
        var images: [[UInt8]] = []
        for strength in [0.0, 0.55, 1.0] {
            var value = state.preferences; value.appearance?.local?.strength = strength
            try #require(state.update(value)); host.rootView = content(); try await settle()
            #expect(children(host).contains { $0 === canvas } && children(host).contains { $0 === input })
            #expect(window.firstResponder === responder && canvas.strength == strength)
            #expect(canvas.palette == (scheme == .dark ? .defaultDark : .defaultLight))
            let a = try titlebarPixel(canvas, external: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            let b = try titlebarPixel(canvas, external: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            #expect(a == b && a[3] == 255, "Titlebar pixels exclude anything behind D")
            images.append(a)
        }
        #expect(images[0] != images[1] && images[1] != images[2], "Titlebar follows the continuous glass setting: \(images), band \(chrome.frame(in: canvas)), bounds \(canvas.bounds)")
        window.setContentSize(CGSize(width: 840, height: 520)); try await settle(); try checkGeometry()
        #expect(owner.decodeCount == 1 && owner.blurCount == 1)
        var value = state.preferences; value.appearance?.local?.material = .solid
        try #require(state.update(value)); host.rootView = content(); try await settle()
        #expect(!canvas.drawsGlass && window.isOpaque)
        canvas.releaseTitlebar()
        #expect(!window.titlebarAppearsTransparent && !window.styleMask.contains(.fullSizeContentView))
        #expect(window.contentView === host && window.firstResponder === responder)
    }

    @Test func titlebarEscapesClippedCanvasAndMaintainsOwnedChrome() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 400)); window.contentView = host
        let clip = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 350)); clip.clipsToBounds = true; host.addSubview(clip)
        let canvas = WorkbenchBackgroundNSView(frame: clip.bounds); canvas.isCanvas = true; canvas.stylesWindowTitlebar = true
        let owner = WorkbenchBackgroundOwner(); canvas.owner = owner; owner.root = canvas; clip.addSubview(canvas)
        canvas.synchronizeTitlebar()
        let chrome = try #require(canvas.titlebar)
        #expect(chrome.frame(in: canvas).isEmpty || chrome.frame(in: canvas).isNull)
        #expect(chrome.surface.superview === host && chrome.surface.frame.height > 0 && !chrome.surface.isHidden)
        #expect(chrome.surface.convert(chrome.surface.bounds, to: nil).minY == window.contentLayoutRect.maxY)
        #expect(chrome.surface.hitTest(.zero) == nil && owner.coordinateRoot(in: window) === host)
        #expect(!host.isFlipped)
        #expect(owner.coordinates(for: chrome.surface).rect.minY == 0)
        #expect(owner.coordinates(for: canvas).rect.minY == host.bounds.maxY - canvas.convert(canvas.bounds, to: host).maxY)
        let button = window.standardWindowButton(.closeButton)
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        canvas.synchronizeTitlebar()
        #expect(window.titlebarAppearsTransparent && window.styleMask.contains(.fullSizeContentView))
        #expect(window.standardWindowButton(.closeButton) === button && window.contentView === host)
        let pixel = try titlebarPixel(canvas, external: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(pixel[3] == 255)
        canvas.releaseTitlebar(); #expect(chrome.surface.superview == nil)
    }

    @Test func titlebarOwnershipIsLocalAndRestoresOnlyChrome() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        for w in [window, other, panel] { w.isReleasedWhenClosed = false }
        defer { for w in [window, other, panel] { w.contentView = nil; w.close() } }
        let color = window.backgroundColor, separator = window.titlebarSeparatorStyle
        let view = WorkbenchBackgroundNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 250))
        view.isCanvas = true; window.contentView = view
        #expect(view.titlebar == nil && !window.titlebarAppearsTransparent)
        view.stylesWindowTitlebar = true; view.synchronizeTitlebar()
        #expect(view.titlebar?.window === window && window.titlebarAppearsTransparent)
        #expect(!other.titlebarAppearsTransparent && !other.styleMask.contains(.fullSizeContentView))
        #expect(WorkbenchWindowTitlebar(window: panel, invalidate: {}) == nil)
        // Detachment releases the first window before attachment to the next.
        window.contentView = nil; other.contentView = view
        #expect(!window.titlebarAppearsTransparent && !window.styleMask.contains(.fullSizeContentView))
        #expect(window.backgroundColor == color && window.titlebarSeparatorStyle == separator)
        #expect(view.titlebar?.window === other && other.titlebarAppearsTransparent)
        other.title = "Unrelated new title"; other.backgroundColor = .orange
        view.releaseTitlebar(); view.releaseTitlebar()
        #expect(other.title == "Unrelated new title" && other.backgroundColor == .orange)
        #expect(!other.titlebarAppearsTransparent && !other.styleMask.contains(.fullSizeContentView))
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
        for zoom:CGFloat in [0.5,1,2] {
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
            #expect(abs(rect.width / node.bounds.width - effective) < 0.02)
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
        window.contentView?.layoutSubtreeIfNeeded()
        if wallpaper {
            let file = directory.appendingPathComponent("source.png"); try png(pattern(),at: file)
            owner.load(file)
            for _ in 0..<100 where owner.image == nil { try await Task.sleep(for: .milliseconds(10)) }
            try #require(owner.image != nil)
        }
        for _ in 0..<5 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let counts = [inside,outside,root].map(\.geometryInvalidationCount)
        let before = owner.drawCount
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
        owner.load(nil, blur: false)
        #expect(owner.image == nil)
        print("GEOMETRY_INVALIDATIONS wallpaper=\(wallpaper) visible=\(inside.geometryInvalidationCount-counts[0]) entered=\(outside.geometryInvalidationCount-counts[1]) root=\(root.geometryInvalidationCount-counts[2])")

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
            plate.draw(plate.bounds)
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
