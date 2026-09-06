import Foundation

/// Balanced security-scoped access retained for an entire project/model session.
/// Bookmark resolution and filesystem checks run away from the UI actor.
actor LocationAccess {
    private var scopes: [UUID: URL] = [:]

    struct Lease: Sendable {
        let id: UUID
        let url: URL
        let bookmark: Data
    }

    func acquire(selected url: URL) throws -> Lease {
        let active = url.startAccessingSecurityScopedResource()
        do {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            let values = try canonical.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
            guard values.isDirectory == true, values.volumeIsLocal != false else {
                throw AccessError.unavailable
            }
            // Keep the selected URL's grant, even if its canonical path differs.
            let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            let id = UUID()
            if active { scopes[id] = url }
            return Lease(id: id, url: canonical, bookmark: bookmark)
        } catch {
            if active { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func restore(_ bookmark: Data) throws -> Lease {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        // Recreating the bookmark refreshes stale grants while holding access.
        return try acquire(selected: url)
    }

    func release(_ lease: Lease?) {
        guard let lease, let url = scopes.removeValue(forKey: lease.id) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    enum AccessError: LocalizedError {
        case unavailable
        var errorDescription: String? { "此位置无法访问。请连接原来的外置磁盘，或重新选择本地文件夹以授予访问权。" }
    }
}
