import Darwin
import Foundation

public enum TextSourceReader {
    public static func read(at url: URL) throws -> TextSourceSnapshot {
        let path = try validatedPath(for: url)
        let descriptor = try openReadOnly(path: path)
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw fileError() }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw TextSourcesError.file("文字资料必须是普通文件。")
        }
        guard before.st_size > 0 else {
            throw TextSourcesError.limit("单份文字资料必须为 1 字节至 512 KiB。")
        }
        guard before.st_size <= TextSourcesLimits.sourceBytes else {
            throw TextSourcesError.limit("单份文字资料必须为 1 字节至 512 KiB。")
        }

        var bytes = Data()
        bytes.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var exceededLimit = false
        while !exceededLimit {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw fileError()
            }
            if count > TextSourcesLimits.sourceBytes - bytes.count {
                exceededLimit = true
            } else {
                bytes.append(contentsOf: buffer[..<count])
            }
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw fileError() }
        guard sameReadState(before, after), Int64(bytes.count) == after.st_size else {
            throw TextSourcesError.file("读取期间文字资料已经改变，请重新选择。")
        }
        guard !exceededLimit else {
            throw TextSourcesError.limit("单份文字资料必须为 1 字节至 512 KiB。")
        }

        let snapshot = try TextSourceSnapshot(displayName: path.last!, bytes: bytes)
        _ = try snapshot.validatedText()
        return snapshot
    }

    public static func excerpt(from source: TextSourceSnapshot,
                               range: NSRange? = nil) throws -> TextSourceExcerpt {
        let text = try source.validatedText()
        let selectedRange = range ?? NSRange(location: 0, length: text.utf16.count)
        let excerpt = try TextSourceExcerpt(source: source, range: selectedRange)
        try excerpt.validate(against: source)
        return excerpt
    }

    private static func validatedPath(for url: URL) throws -> [String] {
        guard url.isFileURL, url.baseURL == nil, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil,
              url.host == nil || url.host == "",
              url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
              url.standardizedFileURL.path == url.path else {
            throw TextSourcesError.file("请选择明确的绝对本地文字文件。")
        }

        let components = String(url.path.dropFirst())
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." &&
                      !$0.contains("\\") && !$0.contains("\0")
              }) else {
            throw TextSourcesError.file("文字资料路径无效。")
        }

        let suffix = (components.last! as NSString).pathExtension.lowercased()
        guard ["txt", "md", "markdown"].contains(suffix) else {
            throw TextSourcesError.invalid("仅支持本地 TXT 和 Markdown 文字资料。")
        }
        return components
    }

    private static func openReadOnly(path: [String]) throws -> Int32 {
        var current = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw fileError() }

        for component in path.dropLast() {
            let next = Darwin.openat(current, component,
                                     O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(current)
            guard next >= 0 else {
                if failure == ELOOP || failure == ENOTDIR {
                    throw TextSourcesError.file("文字资料路径不能包含符号链接。")
                }
                throw fileError(failure)
            }
            current = next
        }

        let descriptor = Darwin.openat(current, path.last!,
                                       O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let failure = errno
        Darwin.close(current)
        guard descriptor >= 0 else {
            if failure == ELOOP || failure == ENOTDIR {
                throw TextSourcesError.file("文字资料路径不能包含符号链接。")
            }
            throw fileError(failure)
        }
        return descriptor
    }

    private static func sameReadState(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev &&
            before.st_ino == after.st_ino &&
            before.st_size == after.st_size &&
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            after.st_mode & S_IFMT == S_IFREG
    }

    private static func fileError(_ code: Int32 = errno) -> TextSourcesError {
        .file(String(cString: strerror(code)))
    }
}
