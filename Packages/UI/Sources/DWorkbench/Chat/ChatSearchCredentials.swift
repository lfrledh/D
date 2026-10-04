import Foundation

/// Reuses the selected-file credential boundary. Only a bookmark is kept in app
/// preferences; credential bytes never enter a project, tool request or backup.
@MainActor final class ChatSearchCredentials {
    private let settings: UserDefaults?
    private var memory: [ChatSearchProvider: Data] = [:]

    init(settings: UserDefaults?) { self.settings = settings }

    func configured(_ provider: ChatSearchProvider) -> Bool { bookmark(provider) != nil }

    func choose(_ url: URL, provider: ChatSearchProvider) throws {
        do {
            let selected = try ModelDownloadCredential.choose(url)
            _ = try selected.token()
            if let settings { settings.set(selected.bookmark, forKey: key(provider)) }
            else { memory[provider] = selected.bookmark }
        } catch { throw ChatSearchError.invalidCredential }
    }

    func remove(_ provider: ChatSearchProvider) {
        settings?.removeObject(forKey: key(provider)); memory[provider] = nil
    }

    func token(_ provider: ChatSearchProvider) throws -> String {
        guard let bookmark = bookmark(provider) else { throw ChatSearchError.invalidCredential }
        do { return try ModelDownloadCredential(bookmark: bookmark).token() }
        catch { throw ChatSearchError.invalidCredential }
    }

    private func bookmark(_ provider: ChatSearchProvider) -> Data? {
        settings?.data(forKey: key(provider)) ?? memory[provider]
    }
    private func key(_ provider: ChatSearchProvider) -> String { "D.Chat.SearchCredential.\(provider.rawValue).v1" }
}
