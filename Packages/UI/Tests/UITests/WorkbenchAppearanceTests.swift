import AppKit
import Foundation
@testable import SwiftStreamingMarkdown
import SwiftUI
import Testing
@testable import UI

@Suite("Workbench appearance preferences")
@MainActor struct WorkbenchAppearanceTests {
    @Test func morphHasFiniteShortDurationAndNonlinearVelocity() throws {
        for strength in [0.01, 0.5, 1.0] {
            var appearance = WorkbenchAppearance(); appearance.motion = strength
            let policy = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: false,
                reduceTransparency: false, increasedContrast: false)
            let duration = try #require(policy.morphDuration)
            #expect(duration >= 0.18 && duration <= 0.22)
            if strength == 0.5 { #expect(abs(duration - 0.2) < 0.00001) }
            let curve = policy.morphCurve
            #expect(curve.value(at: 0) == 0 && curve.value(at: 1) == 1)
            #expect(curve.velocity(at: 0.05) < curve.velocity(at: 0.35))
            #expect(abs(curve.velocity(at: 0.95)) < curve.velocity(at: 0.35))
            #expect(abs(curve.value(at: 0.5) - 0.5) > 0.1)
        }
    }

    @Test func reboundPreservesTravelAndRecoversPreviousSpringPeak() {
        for strength in [0.01, 0.5, 1.0] {
            let motion = WorkbenchRebound(duration: 0.18 + 0.04 * strength, strength: strength)
            var peak = 0.0
            for tick in 0...1000 {
                let t = Double(tick) / 1000
                let original = WorkbenchRebound.curve.value(at: t)
                let revised = motion.progress(at: t)
                if original <= 1 { #expect(original == revised) }
                peak = max(peak, revised)
            }
            #expect(abs(peak - 1 - motion.peakOvershoot) < 0.0001)
            #expect(peak > 1.01 && peak < 1.05)
            #expect(motion.progress(at: 1) == 1)
        }
    }

    @Test func sidebarReboundKeepsTallPlateFiniteAndDropletCentered() {
        let motion = WorkbenchRebound(duration: 0.22, strength: 1)
        for height: CGFloat in [500, 1000, 1600] {
            for tick in 0...1000 {
                let phase = motion.progress(at: Double(tick) / 1000)
                for progress in [phase, 1 - phase] {
                    let size = WorkbenchSidebarPlate.size(progress: progress, width: 288, height: height)
                    #expect(size.height.isFinite && size.height >= 34 && size.height <= height + 6)
                    #expect(size.width >= 34 && size.width < 302)
                }
            }
        }
    }

    /// Split native host events prove there is no category commit before release.
    /// This remains a component test, not desktop-pointer acceptance.
    @Test func categoryLensDragDefersCommitAndCancelsWithoutTakingFocus() throws {
        let application = NSApplication.shared
        let oldPolicy = application.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(oldPolicy) }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 100))
        let receiver = WorkbenchCategoryDragView(frame: CGRect(x: 10, y: 40, width: 256, height: 36))
        let editor = NSTextView(frame: CGRect(x: 280, y: 0, width: 140, height: 90))
        root.addSubview(receiver); root.addSubview(editor)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        defer { receiver.cancel(); window.close() }
        try #require(window.isKeyWindow)
        editor.string = "保留草稿"; editor.allowsUndo = true
        try #require(window.makeFirstResponder(editor))
        editor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let owner = NSObject(); receiver.owner = ObjectIdentifier(owner)
        var previews: [CGFloat?] = [], commits: [Int] = []
        receiver.onPreview = { previews.append($0) }; receiver.onCommit = { commits.append($0) }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: receiver.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 120, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        // Start 1pt inside the visible lens edge, not its center.
        let start = CGPoint(x: 1, y: 18), target = CGPoint(x: 194.5, y: 18)
        try #require(root.hitTest(receiver.convert(start, to: root)) === receiver)
        try send(.leftMouseDown, start)
        #expect(commits.isEmpty && previews.last! == 0)
        try send(.leftMouseDragged, target)
        #expect(commits.isEmpty && previews.last! == 3)
        #expect(window.firstResponder === editor && editor.hasMarkedText())
        try send(.leftMouseUp, target)
        #expect(commits == [3] && previews.last! == nil)
        try send(.leftMouseUp, target)
        #expect(commits == [3], "Only one commit per gesture")
        try send(.leftMouseDown, start); try send(.leftMouseDragged, target)
        try send(.leftMouseUp, CGPoint(x: 194.5, y: 90))
        #expect(commits == [3] && previews.last! == nil)
        try send(.leftMouseDown, start); try send(.leftMouseDragged, target)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try send(.leftMouseUp, target)
        #expect(commits == [3] && previews.last! == nil)
        try send(.leftMouseDown, start)
        receiver.enabled = false
        try send(.leftMouseDragged, target); try send(.leftMouseUp, target)
        #expect(commits == [3] && previews.last! == nil)
        receiver.enabled = true
        try send(.leftMouseDown, start)
        let replacement = NSObject(); receiver.owner = ObjectIdentifier(replacement)
        try send(.leftMouseUp, target)
        #expect(commits == [3] && previews.last! == nil)
        #expect(window.firstResponder === editor && editor.hasMarkedText())
        #expect(root.hitTest(receiver.convert(CGPoint(x: 150, y: 18), to: root)) !== receiver,
            "Other category buttons must remain reachable")
        // A new press during settling grabs the actual visible lens, not the
        // integer target or its old location, and continues without a position jump.
        receiver.selection = 3; receiver.presentationSelection = 1.5
        receiver.presentation = CGRect(x: 1.5 * 64.5, y: 0, width: 62.5, height: 36)
        let middle = CGPoint(x: 128, y: 18)
        try #require(root.hitTest(receiver.convert(middle, to: root)) === receiver)
        try send(.leftMouseDown, middle)
        #expect(previews.last! == 1.5)
        try send(.leftMouseDragged, CGPoint(x: 160.25, y: 18))
        #expect(previews.last! == 2 && commits == [3])
        try send(.leftMouseUp, CGPoint(x: 160.25, y: 18))
        #expect(commits == [3, 2])
    }

    @Test func sidebarPlateContainsWholeButtonAndDisappearsWhenCollapsed() throws {
        let button = CGRect(x: 8, y: 8, width: 40, height: 40)
        let renderer = ImageRenderer(content: WorkbenchSidebarPlate(progress: 1,
            expandedWidth: 260, expandedHeight: 500, leading: true))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        // Entire circular button plus 4pt breathing room must lie inside opaque plate.
        for tick in 0..<120 {
            let angle = Double(tick) * .pi / 60
            let x = Int(button.midX + 24 * cos(angle)), y = Int(button.midY + 24 * sin(angle))
            #expect(try #require(bitmap.colorAt(x: x, y: y)).alphaComponent == 1)
        }
        for leading in [true, false] {
            let size = WorkbenchSidebarPlate.size(progress: 0, width: 288, height: 500)
            #expect(size == CGSize(width: 40, height: 40))
            #expect(WorkbenchSidebarPlate.origin(progress: 0, size: size, leading: leading)
                == CGPoint(x: leading ? 8 : -8, y: 8))
        }
        let collapsed = ImageRenderer(content: WorkbenchSidebarPlate(progress: 0,
            expandedWidth: 260, expandedHeight: 500, leading: true).padding(20))
        collapsed.scale = 1
        let empty = NSBitmapImageRep(cgImage: try #require(collapsed.cgImage))
        for y in 0..<empty.pixelsHigh {
            for x in 0..<empty.pixelsWide { #expect(try #require(empty.colorAt(x: x, y: y)).alphaComponent == 0) }
        }
    }

    @Test func categoryRefractionSamplesRealContentAndPreservesTransparency() throws {
        func pixels(enabled: Bool, offset: CGFloat) throws -> [NSColor] {
            let probe = Canvas { context, _ in
                for x in stride(from: CGFloat(0), to: 256, by: 8) {
                    context.fill(Path(CGRect(x: x + offset, y: 0, width: 2, height: 36)), with: .color(.black))
                }
            }.frame(width: 256, height: 36)
                .modifier(WorkbenchCategoryRefraction(origin: 64.5, enabled: enabled))
            let renderer = ImageRenderer(content: probe); renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            return try (0..<72).flatMap { y in try (0..<512).map { x in try #require(bitmap.colorAt(x: x, y: y)) } }
        }
        let plain = try pixels(enabled: false, offset: 0)
        let bent = try pixels(enabled: true, offset: 0)
        let moved = try pixels(enabled: true, offset: 2)
        let changed = plain.indices.filter { plain[$0] != bent[$0] }
        #expect(changed.count > 60, "The actual shader must bend source pixels, not just add a rim")
        #expect(changed.allSatisfy { (129...254).contains($0 % 512) }, "No effect outside the selected lens")
        let interior = (20..<52).flatMap { y in (150..<232).map { y * 512 + $0 } }
        #expect(interior.filter { bent[$0].alphaComponent < 0.05 }.count > 500,
                "Clear source must remain transmissive, not become an opaque replacement plate")
        #expect(interior.contains { bent[$0] != moved[$0] }, "Refraction must follow changed source content")
    }

    @Test func categoryHoverChangesInkWithoutPaintingAnotherPlate() throws {
        func pixels(selection: CGFloat, hovered: Int?, scheme: ColorScheme) throws -> [NSColor] {
            let renderer = ImageRenderer(content: WorkbenchCategoryLensTrack(selection: selection,
                titles: ["文本", "图像", "视频", "音频"], hovered: hovered)
                .environment(\.colorScheme, scheme))
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            return try (0..<36).flatMap { y in try (0..<256).map { x in try #require(bitmap.colorAt(x: x, y: y)) } }
        }
        for scheme: ColorScheme in [.light, .dark] {
            for selection: CGFloat in [0, 1] {
                let rest = try pixels(selection: selection, hovered: nil, scheme: scheme)
                let hover = try pixels(selection: selection, hovered: 1, scheme: scheme)
                let changed = rest.indices.filter { rest[$0] != hover[$0] }
                #expect(!changed.isEmpty, "Both the normal and magnified label need visible ink feedback")
                #expect(changed.allSatisfy { (76...118).contains($0 % 256) && (7...29).contains($0 / 256) },
                    "Hover may change text pixels only, not a second capsule's padding or rim")
            }
        }
    }

    @Test func localGlassInteriorHasNoPaintedLightGradient() throws {
        for scheme: ColorScheme in [.light, .dark] {
            let renderer = ImageRenderer(content: Color.clear.frame(width: 180, height: 300)
                .workbenchGlassPlate(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .environment(\.colorScheme, scheme))
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            let pixels = try [30, 150, 270].map { try #require(bitmap.colorAt(x: 90, y: $0)) }
            #expect(pixels.allSatisfy { $0 == pixels[0] && $0.alphaComponent == 1 })
        }
    }

    /// Production lens paint samples for inspecting glyph alignment and the
    /// reduced-effects selection marker. This is not a native-window screenshot.
    @Test func categoryLensPaintSamples() throws {
        let titles = ["文本", "图像", "视频", "音频"]
        var lightweight = ChatDisplayPreferences()
        lightweight.appearance = WorkbenchAppearance(lightweight: true)
        let samples = HStack(spacing: 20) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                VStack(spacing: 16) {
                    ForEach([CGFloat(0), 1, 1.5, 2, 3], id: \.self) { position in
                        WorkbenchCategoryLensTrack(selection: position, titles: titles)
                            .padding(4).workbenchPanel(in: Capsule())
                    }
                    WorkbenchCategoryLensTrack(selection: 2, titles: titles)
                        .padding(4).workbenchPanel(in: Capsule())
                        .environment(\.chatDisplayPreferences, lightweight)
                    WorkbenchCategoryLensTrack(selection: 0, titles: titles, hovered: 1)
                        .padding(4).workbenchPanel(in: Capsule())
                    WorkbenchCategoryLensTrack(selection: 1, titles: titles, hovered: 1)
                        .padding(4).workbenchPanel(in: Capsule())
                }.padding(20).workbenchTheme().environment(\.colorScheme, scheme)
            }
        }
        let renderer = ImageRenderer(content: samples)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width > 1000 && image.height > 500)
        if let directory = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] {
            let bitmap = NSBitmapImageRep(cgImage: image)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("lens-paint-samples.png"))
        }
    }

    /// A rectangular content probe must not change the plate's outer shadow.
    /// This isolates painting only; native host clipping still needs window review.
    @Test func capsuleBoundaryAndShadowExcludeContentLayers() throws {
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        for size in [CGSize(width: 312, height: 80), CGSize(width: 400, height: 208)] {
            func render(rectangularContent: Bool) throws -> NSBitmapImageRep {
                let content = Rectangle().fill(rectangularContent ? Color.black : .clear)
                    .frame(width: size.width, height: size.height)
                    .workbenchPanel(in: Capsule())
                    .padding(24)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1; renderer.isOpaque = false
                return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            }
            let plate = try render(rectangularContent: false)
            let withContent = try render(rectangularContent: true)
            let width = Int(size.width), height = Int(size.height)
            func alpha(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> CGFloat {
                try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
            }
            #expect(try alpha(plate, 24, 24) < 0.02, "No filled rectangle outside the capsule")
            #expect(try alpha(plate, 24 + width / 2, 24 + height / 2) == 1)
            #expect(try alpha(plate, 22, 24 + height / 2) > 0, "Outer shadow remains visible")
            for (x, y) in [(22, 28), (22, 24 + height / 2),
                           (26 + width, 28), (24 + width / 2, 26 + height)] {
                #expect(try alpha(plate, x, y) == alpha(withContent, x, y),
                        "Content must not cast an independent rectangular shadow")
            }
        }
    }

    /// Render the production paint without a window or desktop capture. This
    /// proves pixel alpha/backdrop independence, not native window acceptance.
    @Test func panelPixelsAreOpaqueAndIndependentOfExternalBackground() throws {
        // These accessibility values are read-only environment inputs. Do not
        // change system preferences to obtain a desired rendering result.
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        func pixels(appearance: WorkbenchAppearance, scheme: ColorScheme,
                    behind: Color = .clear) throws -> [UInt8] {
            var preferences = ChatDisplayPreferences()
            preferences.appearance = appearance
            let content = Color.clear.frame(width: 80, height: 80)
                .workbenchPanel(cornerRadius: 12)
                .environment(\.chatDisplayPreferences, preferences)
                .environment(\.colorScheme, scheme)
                .background(behind)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            renderer.isOpaque = false
            renderer.colorMode = .nonLinear
            let image = try #require(renderer.cgImage)
            try #require(image.width == 80 && image.height == 80)
            // Normalize by drawing into explicit sRGB bytes, not NSColor's
            // calibrated conversion of NSBitmapImageRep.colorAt values.
            var rgba = [UInt8](repeating: 0, count: 80 * 80 * 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: 80, height: 80,
                    bitsPerComponent: 8, bytesPerRow: 80 * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 80))
            }
            return rgba
        }
        func check(_ rgba: [UInt8], expected: [Double]) {
            // Center and the inner left/top padding, not only a single center pixel.
            for (x, y) in [(40, 40), (3, 40), (40, 3)] {
                let offset = (y * 80 + x) * 4
                #expect(rgba[offset + 3] == 255)
                for channel in 0..<3 {
                    #expect(abs(Double(rgba[offset + channel]) - expected[channel]) <= 1)
                }
            }
        }
        for scheme: ColorScheme in [.light, .dark] {
            // Independent default palette fixtures, without calling panelFill.
            let panel: [Double] = scheme == .light ? [250, 252, 249] : [29, 43, 37]
            let canvas: [Double] = scheme == .light ? [237, 242, 235] : [17, 29, 26]
            for blend in [0.0, 0.5, 1.0] {
                var appearance = WorkbenchAppearance()
                appearance.backgroundTransparency = blend
                let expected = zip(panel, canvas).map { $0 * (1 - blend) + $1 * blend }
                for background in [Color.clear, .red, .blue] {
                    check(try pixels(appearance: appearance, scheme: scheme, behind: background), expected: expected)
                }
            }
        }
        // Lightweight fallback remains panel color at full canvas blend.
        // Accessibility flag combinations are covered by the pure policy test;
        // motion alone must not alter the rendered color.
        var appearance = WorkbenchAppearance()
        appearance.backgroundTransparency = 1
        appearance.lightweight = true
        check(try pixels(appearance: appearance, scheme: .light), expected: [250, 252, 249])
        appearance.lightweight = false
        appearance.motion = 0
        check(try pixels(appearance: appearance, scheme: .light), expected: [237, 242, 235])
    }

    /// Host-process mouse events exercise styles; this is not foreground/native acceptance.
    @Test func buttonBodiesReceivePaddingEdgesAndCancelOutsideRelease() throws {
        var calls = [String: Int]()
        func root(disabled: Bool = false) -> some View {
            VStack(spacing: 20) {
                HStack(spacing: 30) {
                    Button { calls["circle", default: 0] += 1 } label: { Image(systemName: "gearshape") }
                        .buttonStyle(WorkbenchIconButtonStyle(diameter: 40, panel: true))
                        .accessibilityIdentifier("circle")
                    Button { calls["icon", default: 0] += 1 } label: { Image(systemName: "mic") }
                        .buttonStyle(WorkbenchIconButtonStyle())
                        .accessibilityIdentifier("icon")
                }
                Button("Send") { calls["primary", default: 0] += 1 }
                    .buttonStyle(WorkbenchPrimaryButtonStyle()).accessibilityIdentifier("primary")
                Button { calls["row", default: 0] += 1 } label: {
                    HStack { Text("Conversation"); Spacer() }.frame(width: 180).padding(9)
                }.buttonStyle(WorkbenchRowButtonStyle()).accessibilityIdentifier("row")
            }.disabled(disabled).frame(width: 360, height: 280)
        }
        let host = NSHostingView(rootView: root())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 280),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        settle()
        // Never interpret an invalid fixture as a successful hit test.
        try #require(window.isVisible && window.isKeyWindow && host.window === window)
        func element(_ id: String) throws -> any NSAccessibilityProtocol {
            var pending: [NSObject] = [host], seen = Set<ObjectIdentifier>()
            while let object = pending.popLast(), seen.count < 2000 {
                guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
                if let value = object as? any NSAccessibilityProtocol {
                    if value.accessibilityIdentifier() == id { return value }
                    pending += (value.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
                }
                if let view = object as? NSView { pending += view.subviews }
            }
            throw NSError(domain: "Missing hosted button " + id, code: 1)
        }
        for id in ["circle", "icon", "primary", "row"] {
            let button = try element(id)
            let frame = button.accessibilityFrame()
            try #require(frame.width > 20 && frame.height > 20)
            if let width: CGFloat = ["circle": 40, "icon": 28, "row": 198][id] {
                try #require(abs(frame.width - width) < 1)
            }
            // Centers plus four points 1 pt inside the visible body's cardinal edges.
            var points = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1 / frame.width, y: 0.5),
                CGPoint(x: 1 - 1 / frame.width, y: 0.5), CGPoint(x: 0.5, y: 1 / frame.height),
                CGPoint(x: 0.5, y: 1 - 1 / frame.height)]
            if id == "circle" { points += [CGPoint(x: 0.18, y: 0.18), CGPoint(x: 0.82, y: 0.82)] }
            for point in points {
                var expected = calls
                expected[id, default: 0] += 1
                try #require(HostingControlClick.send(to: button, in: host, unitPoint: point))
                settle()
                #expect(calls == expected)
            }
            let before = calls
            try #require(HostingControlClick.send(to: button, in: host, unitPoint: CGPoint(x: 1 + 3 / frame.width, y: 0.5)))
            settle()
            #expect(calls == before)
            try #require(HostingControlClick.send(to: button, in: host, releaseAt: CGPoint(x: 1.8, y: 0.5)))
            settle()
            #expect(calls == before)
        }
        let enabledCalls = calls
        host.rootView = root(disabled: true)
        settle()
        for id in ["circle", "icon", "primary", "row"] {
            try #require(HostingControlClick.send(to: element(id), in: host))
            settle()
        }
        #expect(calls == enabledCalls)
    }

    @Test func oldRecordDecodesWithoutAppearance() throws {
        let old = Data(#"{"theme":"dark","textPointSize":18,"transcriptWidth":760,"wrapsCode":true,"sendShortcut":"return"}"#.utf8)
        let preferences = try JSONDecoder().decode(ChatDisplayPreferences.self, from: old)
        #expect(preferences.appearance == nil)
        #expect(preferences.resolvedAppearance == WorkbenchAppearance())
        #expect(preferences.theme == .dark && preferences.wrapsCode)
        #expect(preferences.isValid)
    }

    @Test func damagedAppearanceRecordIsProtectedFromOverwrite() throws {
        let suiteName = "appearance-damaged-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        var preference = ChatDisplayPreferences()
        var appearance = WorkbenchAppearance()
        appearance.light.foreground = "#broken"
        preference.appearance = appearance
        let original = try JSONEncoder().encode(preference)
        settings.set(original, forKey: ChatDisplayPreferences.storageKey)

        let state = ChatDisplayPreferencesState(settings: settings)
        #expect(state.hasInvalidStoredRecord)
        #expect(!state.update(ChatDisplayPreferences()))
        #expect(settings.data(forKey: ChatDisplayPreferences.storageKey) == original)
    }

    @Test func externalDamageIsNotOverwrittenByPaletteEdit() throws {
        let suiteName = "appearance-race-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let state = ChatDisplayPreferencesState(settings: settings)
        let original = Data("invalid saved bytes".utf8)
        settings.set(original, forKey: ChatDisplayPreferences.storageKey)
        var candidate = state.preferences
        candidate.appearance = WorkbenchAppearance()
        #expect(!state.update(candidate))
        #expect(state.hasInvalidStoredRecord)
        #expect(settings.data(forKey: ChatDisplayPreferences.storageKey) == original)
    }

    @Test func palettesPersistSeparatelyAndSelectedResetKeepsOtherChoices() throws {
        let suiteName = "appearance-palettes-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let state = ChatDisplayPreferencesState(settings: settings)
        var candidate = state.preferences
        candidate.textPointSize = 22
        candidate.theme = .system
        var appearance = candidate.resolvedAppearance
        appearance.light.accent = "#154A3B"
        appearance.dark.accent = "#B6E0CB"
        appearance.lightweight = true
        appearance.backgroundTransparency = 0.4
        candidate.appearance = appearance
        #expect(state.update(candidate))
        let loaded = ChatDisplayPreferencesState(settings: settings).preferences
        #expect(loaded.resolvedAppearance.palette(for: .light).accent == "#154A3B")
        #expect(loaded.resolvedAppearance.palette(for: .dark).accent == "#B6E0CB")

        var reset = loaded
        var resetAppearance = reset.resolvedAppearance
        resetAppearance.resetPalette(for: .light)
        reset.appearance = resetAppearance
        #expect(state.update(reset))
        #expect(state.preferences.resolvedAppearance.light == .defaultLight)
        #expect(state.preferences.resolvedAppearance.dark == appearance.dark)
        #expect(state.preferences.resolvedAppearance.lightweight)
        #expect(state.preferences.resolvedAppearance.backgroundTransparency == 0.4)
        #expect(state.preferences.textPointSize == 22 && state.preferences.theme == .system)
    }

    @Test func hexValidationAndCompositeContrast() {
        #expect(WorkbenchPalette.isValidHex("#a0B1c2"))
        #expect(!WorkbenchPalette.isValidHex("#FFF"))
        #expect(!WorkbenchPalette.isValidHex("#12GG34"))
        #expect(WorkbenchPalette.defaultLight.hasSufficientContrast(backgroundTransparency: 0.12))
        #expect(WorkbenchPalette.defaultDark.hasSufficientContrast(backgroundTransparency: 0.12))

        let highAgainstOpaquePanel = WorkbenchPalette(
            foreground: "#FFFFFF", secondary: "#FFFFFF", canvas: "#FFFFFF",
            panel: "#000000", accent: "#FFFFFF")
        #expect(!highAgainstOpaquePanel.contrastIssues(backgroundTransparency: 0).contains("foreground on panel"))
        #expect(highAgainstOpaquePanel.contrastIssues(backgroundTransparency: 0.5).contains("foreground on panel"))
    }

    @Test func opaquePanelFallbackContrastIsReportedAtFullTransparency() {
        let palette = WorkbenchPalette(
            foreground: "#000000", secondary: "#000000", canvas: "#FFFFFF",
            panel: "#000000", accent: "#000000")
        let issues = palette.contrastIssues(backgroundTransparency: 1)
        #expect(issues.contains("foreground on opaque panel"))
        #expect(issues.contains("secondary on opaque panel"))
        #expect(issues.contains("accent on opaque panel"))
        #expect(!palette.hasSufficientContrast(backgroundTransparency: 1))
    }

    @Test func outOfRangeEffectsCannotBeStored() {
        var preferences = ChatDisplayPreferences()
        var appearance = WorkbenchAppearance()
        appearance.motion = .infinity
        preferences.appearance = appearance
        #expect(!preferences.isValid)
        appearance.motion = 0.5
        appearance.backgroundTransparency = -0.01
        preferences.appearance = appearance
        #expect(!preferences.isValid)
    }

    @Test func canvasBlendPolicyUsesOpaqueFallbackForAccessibilityAndLightweight() {
        let appearance = WorkbenchAppearance()
        let normal = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: false,
                                            reduceTransparency: false, increasedContrast: false)
        #expect(normal.usesCanvasBlend)
        #expect(normal.duration == 0.225)

        let transparent = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: false,
                                                 reduceTransparency: true, increasedContrast: false)
        #expect(!transparent.usesCanvasBlend)
        #expect(transparent.duration == normal.duration)

        let contrast = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: false,
                                              reduceTransparency: false, increasedContrast: true)
        #expect(!contrast.usesCanvasBlend)

        var lightweight = appearance
        lightweight.lightweight = true
        let light = WorkbenchEffectsPolicy(appearance: lightweight, reduceMotion: false,
                                           reduceTransparency: false, increasedContrast: false)
        #expect(!light.usesCanvasBlend)
        #expect(light.duration == nil)
        #expect(light.morphAnimation == nil)
        #expect(light.morphDuration == nil)
    }

    @Test func motionPolicyDisablesDecorationWithoutChangingSavedPreferences() {
        var appearance = WorkbenchAppearance()
        appearance.motion = 1
        let reduced = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: true,
                                             reduceTransparency: false, increasedContrast: false)
        #expect(reduced.usesCanvasBlend)
        #expect(reduced.duration == nil)
        #expect(reduced.morphAnimation == nil)
        #expect(reduced.morphDuration == nil)
        #expect(appearance.motion == 1)

        appearance.motion = 0
        let disabled = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: false,
                                              reduceTransparency: false, increasedContrast: false)
        #expect(disabled.duration == nil)
        #expect(disabled.morphAnimation == nil)
        #expect(disabled.morphDuration == nil)
        #expect(disabled.usesCanvasBlend)
    }

    @Test func parsedMarkdownUsesActiveForegroundAndLinkPalette() async throws {
        let text = "Palette sample [link](https://example.com)"
        for palette in [WorkbenchPalette.defaultLight, WorkbenchPalette.defaultDark] {
            let doc = await ChatMarkdownPresentation.parse(text, palette: palette)
            let content = try #require(doc.attributedStrings.first { $0.string.contains("Palette sample") })
            let ink = try #require(content.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            let expected = try #require(NSColor(palette.foregroundColor).usingColorSpace(.sRGB))
            let actual = try #require(ink.usingColorSpace(.sRGB))
            #expect(abs(actual.redComponent - expected.redComponent) < 0.001)
            #expect(abs(actual.greenComponent - expected.greenComponent) < 0.001)
            #expect(abs(actual.blueComponent - expected.blueComponent) < 0.001)
            let range = (content.string as NSString).range(of: "link")
            let link = try #require(content.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
            let accent = try #require(NSColor(palette.accentColor).usingColorSpace(.sRGB))
            #expect(abs((link.usingColorSpace(.sRGB)?.greenComponent ?? -1) - accent.greenComponent) < 0.001)
        }
    }

}
