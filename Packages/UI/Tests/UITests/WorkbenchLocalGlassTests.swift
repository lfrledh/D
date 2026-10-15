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
        await controller.load(); controller.addExample("text")
        let graph = try #require(controller.graph)
        let state = ChatDisplayPreferencesState(appearanceDirectory:root.appendingPathComponent("Appearance"))
        let wallpaper = root.appendingPathComponent("source.png"); try png(pattern(),at:wallpaper)
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
        let bytes = owner.retainedBytes
        for zoom:CGFloat in [0.5,1,2] {
            host.rootView = content(zoom); try await settle()
            let current = descendants(host).compactMap { $0 as? WorkbenchBackgroundNSView }
            #expect(current.contains { $0 === node })
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
