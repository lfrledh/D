import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite("Workbench appearance preferences")
@MainActor struct WorkbenchAppearanceTests {
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
}
