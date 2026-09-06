import CryptoKit
import Darwin
import Foundation

struct ModelFileIdentity: Codable, Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    init(_ value: stat) {
        device = Int64(value.st_dev); inode = UInt64(value.st_ino); size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
    func sameNode(_ other: Self) -> Bool { device == other.device && inode == other.inode }
}

/// Immutable descriptor ownership; all operations remain anchored even during directory replacement.
final class ModelDirectory: Sendable {
    let url: URL
    let descriptor: Int32
    let identity: ModelFileIdentity
    private static let readFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    init(_ url: URL) throws {
        self.url = url
        descriptor = try Self.openAbsolute(self.url)
        do { identity = try Self.identity(descriptor, regular: false) }
        catch { Darwin.close(descriptor); throw error }
    }
    private init(url: URL, descriptor: Int32) throws {
        self.url = url; self.descriptor = descriptor
        do { identity = try Self.identity(descriptor, regular: false) }
        catch { Darwin.close(descriptor); throw error }
    }
    deinit { Darwin.close(descriptor) }

    static func parts(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ModelLibraryError.unsafePath("模型路径不安全：\(path)")
        }
        return parts
    }

    /// Canonicalize only an explicitly selected/state root, never a child model path.
    /// Foundation standardization aliases /private/var back to symlink /var on macOS.
    static func canonicalURL(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0"), let path = realpath(url.path, nil) else {
            throw failure("解析已授权目录")
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    static func openAbsolute(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw ModelLibraryError.unsafePath("需要本地绝对目录。")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw ModelLibraryError.unsafePath("目录路径包含非规范分量。") }
        var fd = Darwin.open("/", parts.isEmpty ? readFlags : O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("打开文件系统") }
        for (index, part) in parts.enumerated() {
            let next = Darwin.openat(fd, part, index == parts.count - 1 ? readFlags : O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            let code = errno; Darwin.close(fd)
            guard next >= 0 else { throw failure("打开目录 \(part)", code: code) }
            fd = next
        }
        return fd
    }

    func validateLocation() throws {
        let current = try Self.openAbsolute(url)
        defer { Darwin.close(current) }
        guard try identity.sameNode(Self.identity(current, regular: false)) else {
            throw ModelLibraryError.unavailable("模型目录已移动、替换或断开，请重新定位。")
        }
    }

    func child(_ path: String, create: Bool = false) throws -> ModelDirectory {
        try validateLocation()
        let fd = try openDirectory(path, create: create)
        return try ModelDirectory(url: url.appendingPathComponent(path, isDirectory: true), descriptor: fd)
    }

    func openDirectory(_ path: String, create: Bool = false) throws -> Int32 {
        var fd = Darwin.dup(descriptor)
        guard fd >= 0 else { throw Self.failure("复制目录引用") }
        do {
            for part in try Self.parts(path) {
                if create, mkdirat(fd, part, 0o700) != 0, errno != EEXIST { throw Self.failure("创建模型目录") }
                let next = Darwin.openat(fd, part, Self.readFlags)
                guard next >= 0 else { throw Self.failure("打开模型子目录") }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    func parent(_ path: String, create: Bool = false) throws -> (Int32, String) {
        let parts = try Self.parts(path)
        let fd = parts.count == 1 ? Darwin.dup(descriptor) : try openDirectory(parts.dropLast().joined(separator: "/"), create: create)
        guard fd >= 0 else { throw Self.failure("打开文件父目录") }
        return (fd, parts.last!)
    }

    func openFile(_ path: String, writing: Bool = false, create: Bool = false) throws -> Int32 {
        try validateLocation()
        let (parent, name) = try parent(path, create: create)
        defer { Darwin.close(parent) }
        let flags = (writing ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT | O_EXCL : 0)
        let fd = Darwin.openat(parent, name, flags, 0o600)
        guard fd >= 0 else { throw Self.failure("打开模型文件 \(path)") }
        do { _ = try Self.identity(fd, regular: true); return fd }
        catch { Darwin.close(fd); throw error }
    }

    func fileIdentity(_ path: String) throws -> ModelFileIdentity {
        let fd = try openFile(path); defer { Darwin.close(fd) }
        return try Self.identity(fd, regular: true)
    }

    func read(_ path: String, maximum: Int = 16 * 1024 * 1024) throws -> Data {
        let fd = try openFile(path); defer { Darwin.close(fd) }
        let before = try Self.identity(fd, regular: true)
        guard before.size >= 0, before.size <= maximum else { throw ModelLibraryError.integrity("状态文件大小异常。") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: min(max(Int(before.size), 1), 1024 * 1024))
        while result.count < before.size {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, Int(before.size) - result.count)) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Self.failure("读取完整文件") }
            result.append(contentsOf: buffer.prefix(n))
        }
        guard try Self.identity(fd, regular: true) == before else { throw ModelLibraryError.integrity("读取期间文件发生变化。") }
        return result
    }

    func atomicWrite(_ data: Data, to path: String, replace: Bool = true) throws {
        try validateLocation()
        let (parent, name) = try parent(path, create: true)
        defer { Darwin.close(parent) }
        let temporary = ".write-" + UUID().uuidString
        let fd = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("创建状态临时文件") }
        defer { Darwin.close(fd); _ = unlinkat(parent, temporary, 0) }
        try Self.write(data, to: fd)
        guard fsync(fd) == 0 else { throw Self.failure("保存状态文件") }
        if replace {
            var existing = stat()
            if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else { throw ModelLibraryError.unsafePath("拒绝替换异常状态文件。") }
            } else if errno != ENOENT { throw Self.failure("检查状态文件") }
        }
        try validateLocation()
        let flags: UInt32 = replace ? 0 : UInt32(RENAME_EXCL)
        guard renameatx_np(parent, temporary, parent, name, flags) == 0, fsync(parent) == 0 else {
            throw Self.failure("提交状态文件")
        }
    }

    func entries(expectedPaths: Set<String>? = nil) throws -> [String: ModelFileIdentity] {
        try validateLocation()
        let allowedDirectories = expectedPaths.map { paths in Set(paths.flatMap { path -> [String] in
            let parts = path.split(separator: "/")
            return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        }) }
        var result: [String: ModelFileIdentity] = [:]
        func walk(_ fd: Int32, prefix: String) throws {
            let cursor = Darwin.openat(fd, ".", Self.readFlags)
            guard cursor >= 0, let stream = fdopendir(cursor) else {
                if cursor >= 0 { Darwin.close(cursor) }; throw Self.failure("枚举模型目录")
            }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else { if errno != 0 { throw Self.failure("枚举模型目录") }; break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let path = prefix + name
                var value = stat()
                guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.failure("检查模型条目") }
                if value.st_mode & S_IFMT == S_IFDIR {
                    if let allowedDirectories, !allowedDirectories.contains(path) {
                        throw ModelLibraryError.integrity("模型目录包含清单外目录：\(path)")
                    }
                    let child = Darwin.openat(fd, name, Self.readFlags)
                    guard child >= 0 else { throw Self.failure("打开模型子目录") }
                    defer { Darwin.close(child) }
                    try walk(child, prefix: path + "/")
                } else if value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 { result[path] = ModelFileIdentity(value) }
                else { throw ModelLibraryError.unsafePath("模型目录包含符号链接或特殊文件：\(path)") }
            }
        }
        try walk(descriptor, prefix: "")
        return result
    }

    func verify(_ files: [ModelFile]) throws -> [String: ModelFileIdentity] {
        let expected = Set(files.map(\.path))
        let before = try entries(expectedPaths: expected)
        guard Set(before.keys) == expected else { throw ModelLibraryError.integrity("模型目录包含清单外文件，或缺少必要文件。") }
        for file in files {
            try Task.checkCancellation()
            let fd = try openFile(file.path); defer { Darwin.close(fd) }
            let initial = try Self.identity(fd, regular: true)
            guard initial.size >= 0, UInt64(initial.size) == file.size, initial == before[file.path] else {
                throw ModelLibraryError.integrity("模型文件大小或身份不符：\(file.path)")
            }
            var hash = SHA256(), remaining = file.size, buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while remaining > 0 {
                try Task.checkCancellation()
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, Int(min(remaining, 1024 * 1024)))) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Self.failure("读取模型进行校验") }
                hash.update(data: Data(buffer.prefix(n))); remaining -= UInt64(n)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256,
                  try Self.identity(fd, regular: true) == initial else {
                throw ModelLibraryError.integrity("SHA-256 校验失败或文件发生变化：\(file.path)")
            }
        }
        guard try entries(expectedPaths: expected) == before else { throw ModelLibraryError.integrity("模型目录在校验期间发生变化。") }
        return before
    }

    func removeKnownFiles(_ known: [String: ModelFileIdentity]) throws {
        let actual = try entries(expectedPaths: Set(known.keys))
        guard actual == known else { throw ModelLibraryError.unsafePath("目录含有未知或已改变的文件，未删除任何内容。") }
        for (path, identity) in known {
            let (parent, name) = try parent(path); defer { Darwin.close(parent) }
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  ModelFileIdentity(current) == identity, current.st_mode & S_IFMT == S_IFREG else {
                throw ModelLibraryError.unsafePath("删除前文件发生变化，已停止。")
            }
            guard unlinkat(parent, name, 0) == 0 else { throw Self.failure("移除已确认的模型文件") }
        }
        let directories = Set(known.keys.flatMap { path -> [String] in
            let p = path.split(separator: "/"); return (1..<p.count).map { p.prefix($0).joined(separator: "/") }
        }).sorted { $0.count > $1.count }
        for path in directories {
            let (parent, name) = try parent(path); defer { Darwin.close(parent) }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Self.failure("移除空模型子目录") }
        }
        guard fsync(descriptor) == 0 else { throw Self.failure("保存模型目录更改") }
    }

    static func identity(_ fd: Int32, regular: Bool) throws -> ModelFileIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == (regular ? S_IFREG : S_IFDIR),
              !regular || value.st_nlink == 1 else {
            throw failure("检查文件类型")
        }
        return ModelFileIdentity(value)
    }
    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw failure("写入文件，请检查磁盘空间") }; offset += n
            }
        }
    }
    static func failure(_ action: String, code: Int32 = errno) -> ModelLibraryError {
        .storage("\(action)：\(String(cString: strerror(code)))")
    }
}
