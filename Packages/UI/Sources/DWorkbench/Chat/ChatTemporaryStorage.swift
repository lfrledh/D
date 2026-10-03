import Darwin
import Foundation

/// A single owned cache directory, never a scan of user projects. Imported originals
/// are copies. Ordinary backup/history owners never receive this Store.
@MainActor public final class ChatTemporaryStorage {
    public let store: ProjectStore
    public let root: URL
    private let owner: URL
    private let device: dev_t
    private let inode: ino_t
    private var discarded = false

    private init(store: ProjectStore, root: URL, owner: URL, info: stat) {
        self.store = store; self.root = root; self.owner = owner
        device = info.st_dev; inode = info.st_ino
    }
    public static func create(in parent: URL) async throws -> ChatTemporaryStorage {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fd = try ProjectFiles.openDirectory(parent); defer { Darwin.close(fd) }
        let name = "TemporaryChat-" + UUID().uuidString
        guard mkdirat(fd, name, 0o700) == 0 else { throw ProjectFiles.error() }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ProjectStoreError.externalModification }
        let root = parent.appendingPathComponent(name, isDirectory: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Session.dproject"), name: "Temporary chat")
        try await store.excludeFromBackupsForTemporaryChat()
        return ChatTemporaryStorage(store: store, root: root, owner: parent, info: info)
    }
    /// Caller must stop admissions and drain all activities before closing this Store.
    public func discardClosedStore() throws {
        guard !discarded else { return }
        let parent = try ProjectFiles.openDirectory(owner); defer { Darwin.close(parent) }
        var info = stat()
        guard fstatat(parent, root.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == device, info.st_ino == inode, info.st_mode & S_IFMT == S_IFDIR else { throw ProjectStoreError.externalModification }
        let fd = openat(parent, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProjectFiles.error() }
        defer { Darwin.close(fd) }
        var opened = stat(); guard fstat(fd, &opened) == 0, opened.st_dev == device, opened.st_ino == inode else { throw ProjectStoreError.externalModification }
        try Self.removeOwnedContents(fd, depth: 0)
        guard fstatat(parent, root.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == device, info.st_ino == inode else { throw ProjectStoreError.externalModification }
        guard unlinkat(parent, root.lastPathComponent, AT_REMOVEDIR) == 0 else { throw ProjectFiles.error() }
        discarded = true
    }
    private static func removeOwnedContents(_ fd: Int32, depth: Int) throws {
        guard depth < 32 else { throw ProjectStoreError.unsafePath("Temporary directory nesting") }
        let copy = dup(fd); guard copy >= 0 else { throw ProjectFiles.error() }
        guard let directory = fdopendir(copy) else { Darwin.close(copy); throw ProjectFiles.error() }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else { if errno != 0 { throw ProjectFiles.error() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ProjectFiles.error() }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ProjectFiles.error() }
                defer { Darwin.close(child) }
                var current = stat()
                guard fstat(child, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino else { throw ProjectStoreError.externalModification }
                try removeOwnedContents(child, depth: depth + 1)
                guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino else { throw ProjectStoreError.externalModification }
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw ProjectFiles.error() }
            } else {
                // Symlinks are unlinked, never followed. No shared original is removed.
                guard unlinkat(fd, name, 0) == 0 else { throw ProjectFiles.error() }
            }
        }
    }
}
