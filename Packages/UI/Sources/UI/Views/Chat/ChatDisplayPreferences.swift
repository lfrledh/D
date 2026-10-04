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

    var preferredColorScheme: ColorScheme? {
        switch theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var isValid: Bool {
        (12...28).contains(textPointSize) && (480...1100).contains(transcriptWidth)
    }
}

/// An invalid stored record remains untouched until the user explicitly resets it.
@MainActor @Observable
final class ChatDisplayPreferencesState {
    private let settings: UserDefaults?
    private(set) var preferences = ChatDisplayPreferences()
    private(set) var hasInvalidStoredRecord = false

    init(settings: UserDefaults? = nil) {
        self.settings = settings
        guard let settings, let stored = settings.object(forKey: ChatDisplayPreferences.storageKey) else { return }
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

    func reset() {
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
