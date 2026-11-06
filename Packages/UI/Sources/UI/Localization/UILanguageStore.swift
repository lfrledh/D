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

/// Stable causes are retained; summaries resolve in the currently selected language.
/// English literals are emergency fallbacks when the built-in resources themselves fail.
public struct UILanguageDiagnostic: Equatable, Sendable {
    public enum Reason: String, CaseIterable, Sendable {
        case savedUnavailable, builtInRead, builtInIncomplete, builtInInvalid, externalList, reservedIdentifier, builtInConflict, duplicate, externalInvalid, unknownKeys
    }
    public let reason: Reason
    public let name: String?
    public let detail: String?
    init(_ reason: Reason, name: String? = nil, detail: String? = nil) {
        self.reason = reason; self.name = name; self.detail = detail
    }
    public var technicalDetails: String {
        [name, detail].compactMap { $0 }.joined(separator: "\n")
    }
    @MainActor public func summary(_ store: UILanguageStore) -> String {
        let fallback: String
        switch reason {
        case .savedUnavailable: fallback = "The previously selected language is unavailable. The interface now follows the system language."
        case .builtInRead: fallback = "The built-in language file could not be read: {name}."
        case .builtInIncomplete: fallback = "The built-in language file is missing required interface text: {name}."
        case .builtInInvalid: fallback = "The built-in language file cannot be used: {name}."
        case .externalList: fallback = "The list of saved language packs could not be read."
        case .reservedIdentifier: fallback = "The language pack “{name}” uses an identifier that is not allowed for custom languages and was not loaded."
        case .builtInConflict: fallback = "The language pack “{name}” conflicts with a built-in language and was not loaded."
        case .duplicate: fallback = "The language pack “{name}” is duplicated. The duplicate was skipped."
        case .externalInvalid: fallback = "The language pack “{name}” cannot be used. Check the file or import it again."
        case .unknownKeys: fallback = "The language pack “{name}” contains text entries that this version does not use. Other entries are unaffected."
        }
        return store.text("language.diagnostic." + reason.rawValue, fallback: fallback,
                          arguments: name.map { ["name": $0] } ?? [:])
    }
}

@MainActor @Observable
public final class UILanguageStore {
    public static let systemIdentifier = "system"
    static let selectionDefaultsKey = "D.UILanguage.Selection"

    public private(set) var selection: String
    public private(set) var diagnostics: [UILanguageDiagnostic] = []
    private var contentRevision: UInt64 = 0
    // UI projection caches must also invalidate when a pack changes in place.
    var presentationRevision: UInt64 { contentRevision }

    @ObservationIgnored private let settings: UserDefaults?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let preferredLanguages: [String]
    @ObservationIgnored private var builtIns: [String: LanguagePack] = [:]
    @ObservationIgnored private var externalPacks: [String: LanguagePack] = [:]
    // One resolution per selection/pack revision, owned by this store. Do not
    // cache rendered text: arguments and caller fallbacks remain per invocation.
    @ObservationIgnored private var languageResolution: LanguageResolution?

    private struct LanguageResolution {
        let selection: String
        let revision: UInt64
        let identifier: String
        let builtInFallback: String
    }

    var presentationContentRevision: UInt64 { contentRevision }

    public var effectiveLanguageIdentifier: String {
        resolvedLanguage.identifier
    }

    private var resolvedLanguage: LanguageResolution {
        // Read observable inputs even on a cache hit. Retained pages must still
        // observe language selection and successful language-pack changes.
        let selected = selection
        let revision = contentRevision
        if let cached = languageResolution,
           cached.selection == selected, cached.revision == revision { return cached }
        let identifier: String
        if selected != Self.systemIdentifier {
            identifier = resolvedIdentifier(for: selected) ?? "en"
        } else {
            identifier = preferredLanguages.lazy.compactMap { self.resolvedIdentifier(for: $0) }.first ?? "en"
        }
        let resolved = LanguageResolution(selection: selected, revision: revision, identifier: identifier,
                                          builtInFallback: builtInFallbackIdentifier(for: identifier))
        languageResolution = resolved
        return resolved
    }

    public var availableLanguages: [UILanguage] {
        _ = contentRevision
        let systemName = text("language.system", fallback: "跟随系统")
        let packs = (Array(builtIns.values) + Array(externalPacks.values))
            .map { UILanguage(id: $0.locale, displayName: $0.displayName) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return [UILanguage(id: Self.systemIdentifier, displayName: systemName)] + packs
    }

    public convenience init(
        settings: UserDefaults? = nil,
        directory: URL? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.init(settings: settings, directory: directory, preferredLanguages: preferredLanguages,
                  builtInData: Self.bundledData)
    }

    init(settings: UserDefaults?, directory: URL?, preferredLanguages: [String],
         builtInData: (String) throws -> Data
    ) {
        self.settings = settings
        self.directory = directory
        self.preferredLanguages = preferredLanguages
        self.selection = settings?.string(forKey: Self.selectionDefaultsKey) ?? Self.systemIdentifier
        loadBuiltIns(builtInData)
        loadExternalPacks()
        if selection != Self.systemIdentifier {
            if let exact = exactIdentifier(for: selection) {
                selection = exact
            } else {
                diagnostics.append(.init(.savedUnavailable, name: selection))
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
        let language = resolvedLanguage
        let selectedPack = externalPacks[language.identifier] ?? builtIns[language.identifier]
        let builtInIdentifier = language.builtInFallback
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

    /// The supported Chinese source pack supplies the final readable fallback for
    /// presentation helpers. This does not change text()'s selected-language chain.
    func sourceFallback(_ key: String, fallback: String) -> String {
        _ = contentRevision
        return builtIns["zh-Hans"]?.strings[key] ?? fallback
    }

    #if DEBUG
    /// Component fixture injection; never writes preferences or user packs.
    func testingBuiltIn(_ pack: LanguagePack) {
        builtIns[pack.locale] = pack
        contentRevision &+= 1
    }
    #endif

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

    private static func bundledData(_ resource: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json")
            ?? Bundle.module.url(forResource: resource, withExtension: "json", subdirectory: "Localization") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
    private func loadBuiltIns(_ read: (String) throws -> Data) {
        for resource in ["en", "zh-Hans"] {
            let data: Data
            do { data = try read(resource) }
            catch {
                diagnostics.append(.init(.builtInRead, name: resource, detail: String(describing: error)))
                continue
            }
            do {
                let english = resource == "en" ? nil : builtIns["en"]
                let pack = try LanguagePackCodec.decodeBuiltIn(data, english: english)
                if let english, Set(pack.strings.keys) != Set(english.strings.keys) {
                    let missing = Set(english.strings.keys).subtracting(pack.strings.keys)
                    let extra = Set(pack.strings.keys).subtracting(english.strings.keys)
                    diagnostics.append(.init(missing.isEmpty ? .builtInInvalid : .builtInIncomplete, name: resource,
                        detail: "missing: " + missing.sorted().joined(separator: ", ") +
                            "\nextra: " + extra.sorted().joined(separator: ", ")))
                    continue
                }
                builtIns[pack.locale] = pack
            } catch {
                diagnostics.append(.init(.builtInInvalid, name: resource, detail: String(describing: error)))
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
            diagnostics.append(.init(.externalList, name: directory.lastPathComponent, detail: String(describing: error)))
            return
        }
        for url in urls {
            do {
                let data = try LanguagePackFileReader.read(from: url)
                let pack = try LanguagePackCodec.decode(data, english: builtIns["en"])
                guard pack.locale != Self.systemIdentifier else {
                    diagnostics.append(.init(.reservedIdentifier, name: pack.locale, detail: url.lastPathComponent))
                    continue
                }
                guard builtIns[pack.locale] == nil else {
                    diagnostics.append(.init(.builtInConflict, name: pack.locale, detail: url.lastPathComponent))
                    continue
                }
                guard externalPacks[pack.locale] == nil else {
                    diagnostics.append(.init(.duplicate, name: pack.locale, detail: url.lastPathComponent))
                    continue
                }
                externalPacks[pack.locale] = pack
                reportUnknownKeys(in: pack)
            } catch {
                diagnostics.append(.init(.externalInvalid, name: url.lastPathComponent, detail: String(describing: error)))
            }
        }
    }

    private func reportUnknownKeys(in pack: LanguagePack) {
        guard let english = builtIns["en"] else { return }
        let unknown = Set(pack.strings.keys).subtracting(english.strings.keys).sorted()
        guard !unknown.isEmpty else { return }
        diagnostics.append(.init(.unknownKeys, name: pack.locale,
            detail: unknown.map { $0 + " = " + (pack.strings[$0] ?? "") }.joined(separator: "\n")))
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
