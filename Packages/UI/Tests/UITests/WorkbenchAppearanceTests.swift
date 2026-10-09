import AppKit
import Foundation
@testable import SwiftStreamingMarkdown
import SwiftUI
import Testing
@testable import UI

@Suite("Workbench appearance preferences")
@MainActor struct WorkbenchAppearanceTests {
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

    @Test func materialPolicyUsesOpaqueFallbackForAccessibilityAndLightweight() {
        let appearance = WorkbenchAppearance()
        let normal = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: false,
                                            reduceTransparency: false, increasedContrast: false)
        #expect(normal.usesMaterial)
        #expect(normal.duration == 0.225)

        let transparent = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: false,
                                                 reduceTransparency: true, increasedContrast: false)
        #expect(!transparent.usesMaterial)
        #expect(transparent.duration == normal.duration)

        let contrast = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: false,
                                              reduceTransparency: false, increasedContrast: true)
        #expect(!contrast.usesMaterial)

        var lightweight = appearance
        lightweight.lightweight = true
        let light = WorkbenchEffectsPolicy(appearance: lightweight, reduceMotion: false,
                                           reduceTransparency: false, increasedContrast: false)
        #expect(!light.usesMaterial)
        #expect(light.duration == nil)
    }

    @Test func motionPolicyDisablesDecorationWithoutChangingSavedPreferences() {
        var appearance = WorkbenchAppearance()
        appearance.motion = 1
        let reduced = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: true,
                                             reduceTransparency: false, increasedContrast: false)
        #expect(reduced.usesMaterial)
        #expect(reduced.duration == nil)
        #expect(appearance.motion == 1)

        appearance.motion = 0
        let disabled = WorkbenchEffectsPolicy(appearance: appearance, reduceMotion: false,
                                              reduceTransparency: false, increasedContrast: false)
        #expect(disabled.duration == nil)
        #expect(disabled.usesMaterial)
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
