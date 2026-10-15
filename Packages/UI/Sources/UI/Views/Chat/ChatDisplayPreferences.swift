import Foundation
import Observation
import SwiftUI

/// Local presentation choices. They are never part of a chat request or project record.
struct ChatDisplayPreferences: Codable, Equatable {
    enum Theme: String, Codable, CaseIterable {
        case system, light, dark
    }

    enum SendShortcut: String, Codable, CaseIterable {
        case commandReturn, `return`
    }

    static let storageKey = "d.chat.displayPreferences.v1"
    static let defaultTextPointSize = 14
    static let defaultTranscriptWidth = 760

    var endSound: Bool? = nil
    var theme: Theme = .system
    var textPointSize = ChatDisplayPreferences.defaultTextPointSize
    var transcriptWidth = ChatDisplayPreferences.defaultTranscriptWidth
    var wrapsCode = false
    var sendShortcut: SendShortcut = .commandReturn
    var appearance: WorkbenchAppearance? = nil

    init() {}

    private enum CodingKeys: String, CodingKey {
        case endSound, theme, textPointSize, transcriptWidth, wrapsCode, sendShortcut, appearance
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endSound = try values.decodeIfPresent(Bool.self, forKey: .endSound)
        theme = try values.decode(Theme.self, forKey: .theme)
        textPointSize = try values.decode(Int.self, forKey: .textPointSize)
        transcriptWidth = try values.decode(Int.self, forKey: .transcriptWidth)
        wrapsCode = try values.decode(Bool.self, forKey: .wrapsCode)
        sendShortcut = try values.decode(SendShortcut.self, forKey: .sendShortcut)
        appearance = try values.decodeIfPresent(WorkbenchAppearance.self, forKey: .appearance)
    }

    var resolvedAppearance: WorkbenchAppearance { appearance ?? WorkbenchAppearance() }

    var preferredColorScheme: ColorScheme? {
        switch theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var isValid: Bool {
        (12...28).contains(textPointSize) && (480...1100).contains(transcriptWidth)
            && (appearance?.isValid ?? true)
    }
}

/// An invalid stored record remains untouched until the user explicitly resets it.
@MainActor @Observable
final class ChatDisplayPreferencesState {
    private static let seedConsumedKey = "D.Appearance.initialSeedConsumed"
    private let settings: UserDefaults?
    let appearanceDirectory: URL?
    @ObservationIgnored private let commitAppearance: (UserDefaults) -> Bool
    private var wallpaperRequest = UUID()
    private(set) var wallpaperPreparing = false
    private(set) var wallpaperIssue = false
    private(set) var preferences = ChatDisplayPreferences()
    private(set) var hasInvalidStoredRecord = false

    init(settings: UserDefaults? = nil, appearanceDirectory: URL? = nil,
         commitAppearance: @escaping (UserDefaults) -> Bool = { $0.synchronize() }) {
        self.settings = settings
        self.commitAppearance = commitAppearance
        self.appearanceDirectory = appearanceDirectory
        guard let settings, let stored = settings.object(forKey: ChatDisplayPreferences.storageKey) else {
            // A prepared review can seed this one new instance. Never overwrite a
            // persisted record, follow a link, or borrow another instance's suite.
            if let directory = appearanceDirectory {
                let seed = directory.appendingPathComponent("initial-preferences.json")
                if settings?.bool(forKey: Self.seedConsumedKey) != true,
                   FileManager.default.fileExists(atPath: seed.path) {
                    guard seed.resolvingSymlinksInPath().standardizedFileURL == seed.standardizedFileURL,
                          let size = try? seed.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32768,
                          let data = try? Data(contentsOf: seed),
                          let decoded = try? JSONDecoder().decode(ChatDisplayPreferences.self, from: data), decoded.isValid else {
                        hasInvalidStoredRecord = true; return
                    }
                    preferences = decoded
                    settings?.set(data, forKey: ChatDisplayPreferences.storageKey)
                    settings?.set(true, forKey: Self.seedConsumedKey)
                    return
                }
            }
            // New installations only. Decoded old records retain nil/legacy semantics.
            if appearanceDirectory != nil {
                var appearance = WorkbenchAppearance(); appearance.local = WorkbenchLocalAppearance()
                preferences.appearance = appearance
            }
            return
        }
        guard let data = stored as? Data,
              let decoded = try? JSONDecoder().decode(ChatDisplayPreferences.self, from: data),
              decoded.isValid else {
            hasInvalidStoredRecord = true
            return
        }
        preferences = decoded
    }

    /// Returns false for an invalid candidate or while a damaged record is protected.
    @discardableResult
    func update(_ candidate: ChatDisplayPreferences) -> Bool {
        guard !hasInvalidStoredRecord, candidate.isValid else { return false }
        if let settings, let stored = settings.object(forKey: ChatDisplayPreferences.storageKey) {
            guard let data = stored as? Data,
                  let decoded = try? JSONDecoder().decode(ChatDisplayPreferences.self, from: data),
                  decoded.isValid else {
                hasInvalidStoredRecord = true
                return false
            }
        }
        guard let data = try? JSONEncoder().encode(candidate) else { return false }
        settings?.set(data, forKey: ChatDisplayPreferences.storageKey)
        preferences = candidate
        return true
    }

    func cancelWallpaperPreparation() {
        wallpaperRequest = UUID(); wallpaperPreparing = false
    }

    func markWallpaperUnavailable() { wallpaperIssue = true }

    func wallpaperURL() -> URL? {
        guard let name = preferences.appearance?.local?.wallpaper else { return nil }
        return try? ownedWallpaperURL(name, createDirectory: false)
    }

    private func ownedWallpaperURL(_ name: String, createDirectory: Bool) throws -> URL {
        guard WorkbenchLocalAppearance.isOwnedName(name), let directory = appearanceDirectory,
              directory.isFileURL,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw WorkbenchWallpaperError.unavailable
        }
        if createDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let url = directory.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            throw WorkbenchWallpaperError.unavailable
        }
        return url
    }

    /// The panel grants access to this one source. A serial decoder prepares an
    /// owned sRGB preview; stale completions have no write or cleanup authority.
    func importWallpaper(_ source: URL) async {
        cancelWallpaperPreparation()
        let ticket = wallpaperRequest
        let initial = preferences
        let stored = settings?.object(forKey: ChatDisplayPreferences.storageKey) as? Data
        wallpaperPreparing = true; wallpaperIssue = false
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() }
            if wallpaperRequest == ticket { wallpaperPreparing = false } }
        do {
            let bytes = try await WorkbenchWallpaperDecoder.shared.prepare(source)
            try Task.checkCancellation()
            guard ticket == wallpaperRequest, preferences == initial,
                  (settings?.object(forKey: ChatDisplayPreferences.storageKey) as? Data) == stored,
                  !hasInvalidStoredRecord else { throw WorkbenchWallpaperError.changedOwner }
            let name = UUID().uuidString + ".png"
            let destination = try ownedWallpaperURL(name, createDirectory: true)
            try WorkbenchWallpaperPublication.publish(bytes, to: destination)
            var candidate = preferences
            var appearance = candidate.resolvedAppearance
            var local = appearance.local ?? WorkbenchLocalAppearance()
            let previous = local.wallpaper
            local.wallpaper = name; appearance.local = local; candidate.appearance = appearance
            guard update(candidate) else {
                try? FileManager.default.removeItem(at: destination)
                throw WorkbenchWallpaperError.saveFailed
            }
            if let settings, !commitAppearance(settings) {
                // Restore the previous choice in memory and preferences. If even
                // rollback cannot flush, retain both copies for safe recovery.
                if let stored { settings.set(stored, forKey: ChatDisplayPreferences.storageKey) }
                else { settings.removeObject(forKey: ChatDisplayPreferences.storageKey) }
                preferences = initial
                if commitAppearance(settings) { try? FileManager.default.removeItem(at: destination) }
                throw WorkbenchWallpaperError.saveFailed
            }
            removeRetiredWallpaper(previous)
        } catch {
            if ticket == wallpaperRequest { wallpaperIssue = true }
        }
    }

    @discardableResult func restoreSolidCanvas() -> Bool {
        cancelWallpaperPreparation()
        let previous = preferences.appearance?.local?.wallpaper
        let initial = preferences
        let stored = settings?.data(forKey: ChatDisplayPreferences.storageKey)
        var candidate = preferences
        var appearance = candidate.resolvedAppearance
        var local = appearance.local ?? WorkbenchLocalAppearance()
        local.wallpaper = nil; appearance.local = local; candidate.appearance = appearance
        guard update(candidate) else { return false }
        // Keep the old copy if the preference flush is not confirmed.
        if let settings, !commitAppearance(settings) {
            if let stored { settings.set(stored, forKey: ChatDisplayPreferences.storageKey) }
            else { settings.removeObject(forKey: ChatDisplayPreferences.storageKey) }
            preferences = initial; _ = commitAppearance(settings)
            wallpaperIssue = true; return false
        }
        wallpaperIssue = false; removeRetiredWallpaper(previous)
        return true
    }

    private func removeRetiredWallpaper(_ name: String?) {
        guard let name, name != preferences.appearance?.local?.wallpaper,
              let url = try? ownedWallpaperURL(name, createDirectory: false) else { return }
        // Exact prior owned file only. Never scan or delete unknown files.
        try? FileManager.default.removeItem(at: url)
    }

    func reset() {
        cancelWallpaperPreparation()
        settings?.removeObject(forKey: ChatDisplayPreferences.storageKey)
        preferences = ChatDisplayPreferences()
        hasInvalidStoredRecord = false
    }
}

private struct ChatDisplayPreferencesKey: EnvironmentKey {
    static let defaultValue = ChatDisplayPreferences()
}

extension EnvironmentValues {
    var chatDisplayPreferences: ChatDisplayPreferences {
        get { self[ChatDisplayPreferencesKey.self] }
        set { self[ChatDisplayPreferencesKey.self] = newValue }
    }
}
