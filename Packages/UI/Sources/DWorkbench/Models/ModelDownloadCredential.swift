import Darwin
import Foundation

/// A bookmark to one user-selected token file. Token bytes are never stored in the library index.
struct ModelDownloadCredential: Sendable {
    static let maximumBytes = 4096
    let bookmark: Data

    static func choose(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Do not follow a selected symlink when making the persistent connection.
        var information = stat()
        guard lstat(url.path, &information) == 0, (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size > 0, information.st_size <= maximumBytes else {
            throw invalidFile
        }
        do {
            return Self(bookmark: try url.bookmarkData(options: [.withSecurityScope],
                includingResourceValuesForKeys: nil, relativeTo: nil))
        } catch { throw invalidFile }
    }

    func token() throws -> String {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw Self.invalidFile }
        guard !stale, url.isFileURL else { throw Self.invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Self.read(at: url)
    }

    static func read(at url: URL) throws -> String {
        guard url.isFileURL else { throw invalidFile }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalidFile }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= maximumBytes else { throw invalidFile }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var readCount = 0
        let expectedCount = bytes.count
        while readCount < bytes.count {
            let result = bytes.withUnsafeMutableBytes { pointer in
                Darwin.read(descriptor, pointer.baseAddress!.advanced(by: readCount), expectedCount - readCount)
            }
            guard result > 0 else { throw invalidFile }
            readCount += result
        }
        var extra: UInt8 = 0
        var after = stat()
        var pathAfter = stat()
        guard Darwin.read(descriptor, &extra, 1) == 0, fstat(descriptor, &after) == 0,
              lstat(url.path, &pathAfter) == 0, (pathAfter.st_mode & S_IFMT) == S_IFREG,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_dev == pathAfter.st_dev, before.st_ino == pathAfter.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw invalidFile }
        guard let token = String(bytes: bytes, encoding: .utf8),
              !token.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }),
              !token.isEmpty else { throw invalidFile }
        return token
    }

    private static var invalidFile: ModelLibraryError {
        .accessDenied("所选令牌文件不可用或内容无效；请重新选择单个纯文本令牌文件。")
    }
}
