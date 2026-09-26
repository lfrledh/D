import Foundation
import Observation
import SwiftUI

public struct UILanguage: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum UILanguageError: Error, LocalizedError, Equatable {
    case unavailableLanguage(String)
    case builtInLocale(String)
    case reservedLocale(String)
    case duplicateLocale(String)
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .unavailableLanguage(let identifier): "Language is not available: \(identifier)."
        case .builtInLocale(let identifier): "External packs cannot replace built-in language: \(identifier)."
        case .reservedLocale(let identifier): "Language identifier is reserved: \(identifier)."
        case .duplicateLocale(let identifier): "A language pack already exists: \(identifier)."
        case .persistenceFailed: "The language pack could not be saved without replacing existing data."
        }
    }
}

@MainActor @Observable
public final class UILanguageStore {
    public static let systemIdentifier = "system"
    static let selectionDefaultsKey = "D.UILanguage.Selection"

    public private(set) var selection: String
    public private(set) var diagnostics: [String] = []
    private var contentRevision: UInt64 = 0

    @ObservationIgnored private let settings: UserDefaults?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let preferredLanguages: [String]
    @ObservationIgnored private var builtIns: [String: LanguagePack] = [:]
    @ObservationIgnored private var externalPacks: [String: LanguagePack] = [:]

    public var effectiveLanguageIdentifier: String {
        _ = contentRevision
        if selection != Self.systemIdentifier {
            return resolvedIdentifier(for: selection) ?? "en"
        }
        for preferred in preferredLanguages {
            if let resolved = resolvedIdentifier(for: preferred) { return resolved }
        }
        return "en"
    }

    public var availableLanguages: [UILanguage] {
        _ = contentRevision
        let systemName = text("language.system", fallback: "跟随系统")
        let packs = (Array(builtIns.values) + Array(externalPacks.values))
            .map { UILanguage(id: $0.locale, displayName: $0.displayName) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return [UILanguage(id: Self.systemIdentifier, displayName: systemName)] + packs
    }

    public init(
        settings: UserDefaults? = nil,
        directory: URL? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.settings = settings
        self.directory = directory
        self.preferredLanguages = preferredLanguages
        self.selection = settings?.string(forKey: Self.selectionDefaultsKey) ?? Self.systemIdentifier
        loadBuiltIns()
        loadExternalPacks()
        if selection != Self.systemIdentifier {
            if let exact = exactIdentifier(for: selection) {
                selection = exact
            } else {
                diagnostics.append("The saved language is unavailable; following the system language instead.")
                selection = Self.systemIdentifier
            }
        }
    }

    public func select(_ identifier: String) throws {
        let selected: String
        if identifier == Self.systemIdentifier {
            selected = Self.systemIdentifier
        } else if let resolved = exactIdentifier(for: identifier) {
            selected = resolved
        } else {
            throw UILanguageError.unavailableLanguage(identifier)
        }
        selection = selected
        settings?.set(selected, forKey: Self.selectionDefaultsKey)
    }

    public func text(
        _ key: String,
        fallback: String,
        arguments: [String: String] = [:]
    ) -> String {
        _ = contentRevision
        let identifier = effectiveLanguageIdentifier
        let selectedPack = externalPacks[identifier] ?? builtIns[identifier]
        let builtInIdentifier = builtInFallbackIdentifier(for: identifier)
        let template: String
        if builtIns["en"]?.strings[key] != nil {
            template = selectedPack?.strings[key]
                ?? builtIns[builtInIdentifier]?.strings[key]
                ?? builtIns["en"]?.strings[key]
                ?? fallback
        } else {
            template = fallback
        }
        return LanguagePackCodec.render(template, arguments: arguments)
    }

    @discardableResult
    public func importPack(data: Data) throws -> String {
        let english = builtIns["en"]
        let pack = try LanguagePackCodec.decode(data, english: english)
        guard pack.locale != Self.systemIdentifier else { throw UILanguageError.reservedLocale(pack.locale) }
        guard builtIns[pack.locale] == nil else { throw UILanguageError.builtInLocale(pack.locale) }
        guard externalPacks[pack.locale] == nil else { throw UILanguageError.duplicateLocale(pack.locale) }

        if let directory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(pack.locale).appendingPathExtension("json")
                let temporary = directory.appendingPathComponent(".language-pack-\(UUID().uuidString).tmp")
                do {
                    try data.write(to: temporary, options: .withoutOverwriting)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
            } catch {
                throw UILanguageError.persistenceFailed
            }
        }

        externalPacks[pack.locale] = pack
        reportUnknownKeys(in: pack)
        contentRevision &+= 1
        return pack.locale
    }

    private func loadBuiltIns() {
        for resource in ["en", "zh-Hans"] {
            let url = Bundle.module.url(forResource: resource, withExtension: "json")
                ?? Bundle.module.url(forResource: resource, withExtension: "json", subdirectory: "Localization")
            guard let url, let data = try? Data(contentsOf: url) else {
                diagnostics.append("Built-in language resource is unavailable: \(resource).")
                continue
            }
            do {
                let english = resource == "en" ? nil : builtIns["en"]
                let pack = try LanguagePackCodec.decode(data, english: english)
                if let english, Set(pack.strings.keys) != Set(english.strings.keys) {
                    diagnostics.append("Built-in language resource has incomplete keys: \(resource).")
                    continue
                }
                builtIns[pack.locale] = pack
            } catch {
                diagnostics.append("Built-in language resource is invalid: \(resource).")
            }
        }
    }

    private func loadExternalPacks() {
        guard let directory else { return }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            if (error as? CocoaError)?.code == .fileReadNoSuchFile { return }
            diagnostics.append("Saved language packs could not be listed.")
            return
        }
        for url in urls {
            do {
                let data = try LanguagePackFileReader.read(from: url)
                let pack = try LanguagePackCodec.decode(data, english: builtIns["en"])
                guard pack.locale != Self.systemIdentifier else {
                    diagnostics.append("A saved pack used the reserved language identifier: \(pack.locale).")
                    continue
                }
                guard builtIns[pack.locale] == nil else {
                    diagnostics.append("A saved pack tried to replace built-in language: \(pack.locale).")
                    continue
                }
                guard externalPacks[pack.locale] == nil else {
                    diagnostics.append("Duplicate saved language pack: \(pack.locale).")
                    continue
                }
                externalPacks[pack.locale] = pack
                reportUnknownKeys(in: pack)
            } catch {
                diagnostics.append("Saved language pack is invalid: \(url.lastPathComponent).")
            }
        }
    }

    private func reportUnknownKeys(in pack: LanguagePack) {
        guard let english = builtIns["en"] else { return }
        let unknown = Set(pack.strings.keys).subtracting(english.strings.keys).sorted()
        guard !unknown.isEmpty else { return }
        diagnostics.append("Language \(pack.locale) contains unused keys: \(unknown.joined(separator: ", ")).")
    }

    // Explicit selections are exact; only Follow System may use language-family fallback.
    private func exactIdentifier(for requested: String) -> String? {
        guard let normalized = try? LanguagePackCodec.normalizedLocale(requested),
              builtIns[normalized] != nil || externalPacks[normalized] != nil else { return nil }
        return normalized
    }

    private func resolvedIdentifier(for requested: String) -> String? {
        guard let normalized = try? LanguagePackCodec.normalizedLocale(requested) else { return nil }
        let identifiers = Set(builtIns.keys).union(externalPacks.keys)
        if identifiers.contains(normalized) { return normalized }
        let language = normalized.split(separator: "-").first.map(String.init)
        if language == "zh", identifiers.contains("zh-Hans") { return "zh-Hans" }
        if language == "en", identifiers.contains("en") { return "en" }
        return identifiers.sorted().first { $0.split(separator: "-").first.map(String.init) == language }
    }

    private func builtInFallbackIdentifier(for identifier: String) -> String {
        let language = identifier.split(separator: "-").first
        if language == "zh" { return "zh-Hans" }
        return "en"
    }
}

private struct DLanguageStoreKey: EnvironmentKey {
    static let defaultValue: UILanguageStore? = nil
}

public extension EnvironmentValues {
    var dLanguageStore: UILanguageStore? {
        get { self[DLanguageStoreKey.self] }
        set { self[DLanguageStoreKey.self] = newValue }
    }
}
