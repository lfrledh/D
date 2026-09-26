import Darwin
import Foundation
import Testing
@testable import UI

@Suite(.serialized) @MainActor
struct UILocalizationTests {
    @Test
    func builtInsFollowSupportedLanguagesAndFallBackToEnglish() throws {
        let chinese = UILanguageStore(preferredLanguages: ["zh-CN"])
        #expect(chinese.selection == UILanguageStore.systemIdentifier)
        #expect(chinese.effectiveLanguageIdentifier == "zh-Hans")
        #expect(chinese.text("workflow.action.save", fallback: "fallback") == "保存")
        #expect(chinese.diagnostics.isEmpty)

        let unsupported = UILanguageStore(preferredLanguages: ["eo-001"])
        #expect(unsupported.effectiveLanguageIdentifier == "en")
        #expect(unsupported.text("workflow.action.save", fallback: "fallback") == "Save")
        #expect(unsupported.text("missing.key", fallback: "caller fallback") == "caller fallback")
        #expect(unsupported.diagnostics.isEmpty)
    }

    @Test
    func externalPackFallsBackAndNeverUsesUnknownKeys() throws {
        let store = UILanguageStore(preferredLanguages: ["en"])
        let data = pack(locale: "fr", displayName: "Français", strings: [
            "workflow.action.save": "Enregistrer",
            "unknown.valid-key": "must not be displayed",
        ])
        #expect(try store.importPack(data: data) == "fr")
        try store.select("fr")
        #expect(store.text("workflow.action.save", fallback: "save") == "Enregistrer")
        #expect(store.text("workflow.action.cancel", fallback: "cancel") == "Cancel")
        #expect(store.text("unknown.valid-key", fallback: "safe fallback") == "safe fallback")
        #expect(store.diagnostics.contains { $0.contains("unknown.valid-key") })
    }

    @Test
    func invalidVersionPlaceholderAndSizeLeaveSelectionAndPreferenceUnchanged() throws {
        let suiteName = "D.UILocalization.Invalid.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let store = UILanguageStore(settings: settings, preferredLanguages: ["en"])
        try store.select("en")
        let originalPreference = settings.string(forKey: UILanguageStore.selectionDefaultsKey)

        expectFailure { try store.importPack(data: pack(
            schemaVersion: 2, locale: "fr", displayName: "Français", strings: [:]
        )) }
        expectFailure { try store.importPack(data: pack(
            locale: "fr", displayName: "Français",
            strings: ["localization.test.message": "Bonjour {name}"]
        )) }
        expectFailure { try store.importPack(data: Data([0xFF, 0xFE, 0x00])) }
        expectFailure { try store.importPack(data: Data("""
            {"schemaVersion":1,"locale":"fr","displayName":"Français","strings":{"workflow.action.save":42}}
            """.utf8)) }
        expectFailure {
            try store.importPack(data: Data(repeating: 0x20, count: LanguagePackLimits.maximumBytes + 1))
        }

        #expect(store.selection == "en")
        #expect(settings.string(forKey: UILanguageStore.selectionDefaultsKey) == originalPreference)
        #expect(!store.availableLanguages.contains { $0.id == "fr" })
    }

    @Test
    func duplicateImportDoesNotReplaceOldFilePackOrPreference() throws {
        let fixture = try fixture("Duplicate")
        defer { fixture.cleanup() }
        let store = UILanguageStore(settings: fixture.settings, directory: fixture.directory,
                                    preferredLanguages: ["en"])
        let original = pack(locale: "fr-FR", displayName: "Français", strings: [
            "workflow.action.save": "Enregistrer",
            "future.module.title": "Conservé mais inutilisé",
        ])
        #expect(try store.importPack(data: original) == "fr-FR")
        try store.select("fr-FR")
        let preference = fixture.settings.string(forKey: UILanguageStore.selectionDefaultsKey)
        let destination = fixture.directory.appendingPathComponent("fr-FR.json")

        let replacement = pack(locale: "fr-FR", displayName: "Remplacement", strings: [
            "workflow.action.save": "Remplacer",
        ])
        expectFailure { try store.importPack(data: replacement) }

        #expect(try Data(contentsOf: destination) == original)
        #expect(store.text("workflow.action.save", fallback: "save") == "Enregistrer")
        #expect(store.selection == "fr-FR")
        #expect(fixture.settings.string(forKey: UILanguageStore.selectionDefaultsKey) == preference)
    }

    @Test
    func selectionAndPackSurviveReopenButSuitesRemainIsolated() throws {
        let fixture = try fixture("Reopen")
        defer { fixture.cleanup() }
        let first = UILanguageStore(settings: fixture.settings, directory: fixture.directory,
                                    preferredLanguages: ["en"])
        _ = try first.importPack(data: pack(locale: "fr", displayName: "Français", strings: [
            "workflow.action.save": "Enregistrer",
        ]))
        try first.select("fr")

        let reopenedSettings = try #require(UserDefaults(suiteName: fixture.suiteName))
        let reopened = UILanguageStore(settings: reopenedSettings, directory: fixture.directory,
                                       preferredLanguages: ["en"])
        #expect(reopened.selection == "fr")
        #expect(reopened.effectiveLanguageIdentifier == "fr")
        #expect(reopened.text("workflow.action.save", fallback: "save") == "Enregistrer")

        let isolatedName = "D.UILocalization.Isolated.\(UUID().uuidString)"
        let isolatedSettings = try #require(UserDefaults(suiteName: isolatedName))
        defer { isolatedSettings.removePersistentDomain(forName: isolatedName) }
        let isolated = UILanguageStore(settings: isolatedSettings, preferredLanguages: ["en"])
        #expect(isolated.selection == UILanguageStore.systemIdentifier)
        #expect(!isolated.availableLanguages.contains { $0.id == "fr" })
    }

    @Test
    func unicodePercentAndPlaceholderValuesAreInsertedOnce() throws {
        let store = UILanguageStore(preferredLanguages: ["en"])
        _ = try store.importPack(data: pack(locale: "fr", displayName: "Français", strings: [
            "localization.test.message": "Bienvenue {name} : {count} à 100%",
        ]))
        try store.select("fr")
        let rendered = store.text(
            "localization.test.message",
            fallback: "fallback {name} {count}",
            arguments: ["name": "👩🏽‍🎨 {count}", "count": "7%"]
        )
        #expect(rendered == "Bienvenue 👩🏽‍🎨 {count} : 7% à 100%")
    }

    @Test
    func corruptSavedPackIsReportedAndNotDeleted() throws {
        let fixture = try fixture("Corrupt")
        defer { fixture.cleanup() }
        let damaged = fixture.directory.appendingPathComponent("damaged.json")
        let bytes = Data("{not-json".utf8)
        try bytes.write(to: damaged, options: .withoutOverwriting)

        let store = UILanguageStore(settings: fixture.settings, directory: fixture.directory,
                                    preferredLanguages: ["en"])
        #expect(store.effectiveLanguageIdentifier == "en")
        #expect(store.diagnostics.contains { $0.contains("damaged.json") })
        #expect(try Data(contentsOf: damaged) == bytes)
    }

    @Test
    func boundedNativeReaderRejectsOversizeAndSymlinkThenAcceptsRegularFile() throws {
        let fixture = try fixture("BoundedNative")
        defer { fixture.cleanup() }
        let store = UILanguageStore(settings: fixture.settings, directory: fixture.directory,
                                    preferredLanguages: ["en"])
        try store.select("en")
        let originalPreference = fixture.settings.string(forKey: UILanguageStore.selectionDefaultsKey)
        let originalLanguages = store.availableLanguages

        let oversized = fixture.directory.appendingPathComponent("oversized-native.json")
        try Data(repeating: 0x20, count: LanguagePackLimits.maximumBytes + 1)
            .write(to: oversized, options: .withoutOverwriting)
        expectFailure { _ = try LanguagePackFileReader.read(from: oversized) }
        #expect(store.selection == "en")
        #expect(store.availableLanguages == originalLanguages)
        #expect(fixture.settings.string(forKey: UILanguageStore.selectionDefaultsKey) == originalPreference)

        let valid = fixture.directory.appendingPathComponent("native-input.json")
        let validData = pack(locale: "fr", displayName: "Français", strings: [
            "workflow.action.save": "Enregistrer",
        ])
        try validData.write(to: valid, options: .withoutOverwriting)
        #expect(try LanguagePackFileReader.read(from: valid) == validData)

        let symbolic = fixture.directory.appendingPathComponent("native-link.json")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: valid)
        expectFailure { _ = try LanguagePackFileReader.read(from: symbolic) }
        let fifo = fixture.directory.appendingPathComponent("native-fifo.json")
        try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
        expectFailure { _ = try LanguagePackFileReader.read(from: fifo) }
        #expect(store.availableLanguages == originalLanguages)

        #expect(try store.importPack(data: LanguagePackFileReader.read(from: valid)) == "fr")
        #expect(store.availableLanguages.contains { $0.id == "fr" })
    }

    @Test
    func oversizedSavedPackIsDiagnosedInPlaceWithoutChangingPreference() throws {
        let fixture = try fixture("OversizedSaved")
        defer { fixture.cleanup() }
        fixture.settings.set("en", forKey: UILanguageStore.selectionDefaultsKey)
        let preference = fixture.settings.string(forKey: UILanguageStore.selectionDefaultsKey)
        let oversized = fixture.directory.appendingPathComponent("oversized-saved.json")
        let bytes = Data(repeating: 0x20, count: LanguagePackLimits.maximumBytes + 1)
        try bytes.write(to: oversized, options: .withoutOverwriting)

        let store = UILanguageStore(settings: fixture.settings, directory: fixture.directory,
                                    preferredLanguages: ["zh-Hans"])
        #expect(store.selection == "en")
        #expect(store.effectiveLanguageIdentifier == "en")
        #expect(store.diagnostics.contains { $0.contains("oversized-saved.json") })
        #expect(fixture.settings.string(forKey: UILanguageStore.selectionDefaultsKey) == preference)
        #expect(try Data(contentsOf: oversized) == bytes)
    }

    @Test
    func regularSavedPackLoadsThroughBoundedReader() throws {
        let fixture = try fixture("RegularSaved")
        defer { fixture.cleanup() }
        fixture.settings.set("fr", forKey: UILanguageStore.selectionDefaultsKey)
        let saved = pack(locale: "fr", displayName: "Français", strings: [
            "workflow.action.save": "Enregistrer",
        ])
        try saved.write(to: fixture.directory.appendingPathComponent("fr.json"),
                        options: .withoutOverwriting)

        let store = UILanguageStore(settings: fixture.settings, directory: fixture.directory,
                                    preferredLanguages: ["en"])
        #expect(store.selection == "fr")
        #expect(store.text("workflow.action.save", fallback: "save") == "Enregistrer")
        #expect(store.diagnostics.isEmpty)
    }

    @Test
    func reservedSystemLocaleIsRejectedBeforeFileStateOrPreferenceChanges() throws {
        let fixture = try fixture("ReservedSystem")
        defer { fixture.cleanup() }
        let store = UILanguageStore(settings: fixture.settings, directory: fixture.directory,
                                    preferredLanguages: ["en"])
        try store.select("en")
        let preference = fixture.settings.string(forKey: UILanguageStore.selectionDefaultsKey)
        let languages = store.availableLanguages
        let reserved = pack(locale: UILanguageStore.systemIdentifier, displayName: "Collision", strings: [
            "workflow.action.save": "Reserved",
        ])

        expectFailure { _ = try store.importPack(data: reserved) }
        #expect(store.selection == "en")
        #expect(store.availableLanguages == languages)
        #expect(store.availableLanguages.filter { $0.id == UILanguageStore.systemIdentifier }.count == 1)
        #expect(fixture.settings.string(forKey: UILanguageStore.selectionDefaultsKey) == preference)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("system.json").path
        ))
    }

    private func expectFailure(_ operation: () throws -> Void) {
        var failed = false
        do { try operation() } catch { failed = true }
        #expect(failed)
    }

    private func pack(
        schemaVersion: Int = 1,
        locale: String,
        displayName: String,
        strings: [String: String]
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion,
            "locale": locale,
            "displayName": displayName,
            "strings": strings,
        ], options: [.sortedKeys])
    }

    private func fixture(_ name: String) throws -> LocalizationFixture {
        let suiteName = "D.UILocalization.\(name).\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        let approvedRoot = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let directory = URL(fileURLWithPath: approvedRoot, isDirectory: true)
            .appendingPathComponent("d-language-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return LocalizationFixture(suiteName: suiteName, settings: settings, directory: directory)
    }
}

private struct LocalizationFixture {
    let suiteName: String
    let settings: UserDefaults
    let directory: URL

    func cleanup() {
        settings.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
