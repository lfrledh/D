import Darwin
import DInference
import Foundation

/// Private transport of already-held directory access to the fixed bundled provider.
/// This file is never a project artifact or a durable application bookmark store.
struct AudioProviderAccess: Sendable {
    let directory: URL
    let manifest: URL
    private let directoryDevice: Int64
    private let directoryInode: UInt64
    private let manifestIdentity: AudioFileSystem.Identity

    static func prepare(root: URL, runID: UUID, directories: [URL],
                        bookmark: (URL) throws -> Data = {
                            try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
                        }, write: ((Int32, Data) throws -> Void)? = nil) throws -> AudioProviderAccess {
        struct Grant: Encodable { let path: String; let bookmark: String }
        struct Manifest: Encodable { let schemaVersion = 1; let runID: String; let grants: [Grant] }
        let root = try AudioFileSystem.absoluteLocal(root, label: "Audio access bootstrap root")
        guard (1...4).contains(directories.count) else {
            throw InferenceFailure.invalidRequest("Audio access requires one to four exact directories.")
        }
        let rootFD = try AudioFileSystem.openDirectory(root, label: "Audio access bootstrap root")
        defer { Darwin.close(rootFD) }
        var paths = Set<String>()
        var grants: [Grant] = []
        for input in directories {
            let url = try AudioFileSystem.absoluteLocal(input, label: "Audio access directory")
            guard url.path != "/", !AudioFileSystem.overlaps(root, url) else {
                throw InferenceFailure.invalidRequest("Audio bootstrap must be separate from granted directories.")
            }
            try AudioFileSystem.validateDirectory(url, label: "Audio access directory")
            guard paths.insert(url.path).inserted else { continue }
            let data: Data
            do { data = try bookmark(url) }
            catch { throw InferenceFailure.backendFailed("Cannot prepare existing audio directory access.") }
            guard !data.isEmpty, data.count <= 16 * 1024 else {
                throw InferenceFailure.backendFailed("Audio directory access data has an invalid bounded size.")
            }
            grants.append(Grant(path: url.path, bookmark: data.base64EncodedString()))
        }
        guard (1...4).contains(grants.count) else {
            throw InferenceFailure.invalidRequest("Audio access requires one to four exact directories.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Manifest(runID: runID.uuidString.lowercased(), grants: grants))
        guard data.count <= 64 * 1024 else {
            throw InferenceFailure.backendFailed("Audio access manifest exceeds its bounded size.")
        }
        let name = runID.uuidString.lowercased() + "-" + UUID().uuidString.lowercased()
        guard Darwin.mkdirat(rootFD, name, 0o700) == 0 else {
            throw InferenceFailure.backendFailed("Cannot create a private audio access bootstrap.")
        }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let manifest = directory.appendingPathComponent("access.json")
        var directoryStat = stat()
        guard Darwin.fstatat(rootFD, name, &directoryStat, AT_SYMLINK_NOFOLLOW) == 0,
              directoryStat.st_mode & S_IFMT == S_IFDIR else {
            throw InferenceFailure.backendFailed("Private audio bootstrap identity is unavailable; retained at \(directory.path).")
        }
        var fd: Int32 = -1
        var fileFD: Int32 = -1
        defer {
            if fileFD >= 0 { Darwin.close(fileFD) }
            if fd >= 0 { Darwin.close(fd) }
        }
        do {
            fd = Darwin.openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var opened = stat()
            guard fd >= 0, Darwin.fstat(fd, &opened) == 0,
                  opened.st_dev == directoryStat.st_dev, opened.st_ino == directoryStat.st_ino else {
                throw InferenceFailure.backendFailed("Cannot open the owned audio access bootstrap.")
            }
            fileFD = Darwin.openat(fd, "access.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fileFD >= 0 else {
                throw InferenceFailure.backendFailed("Cannot create the private audio access manifest.")
            }
            if let write { try write(fileFD, data) } else { try writeManifest(fileFD, data: data) }
            var file = stat()
            guard Darwin.fstat(fileFD, &file) == 0, file.st_mode & 0o777 == 0o600,
                  file.st_mode & S_IFMT == S_IFREG, file.st_size == data.count else {
                throw InferenceFailure.backendFailed("Audio access manifest failed its private-file checks.")
            }
            return AudioProviderAccess(directory: directory, manifest: manifest,
                directoryDevice: Int64(directoryStat.st_dev), directoryInode: UInt64(directoryStat.st_ino),
                manifestIdentity: AudioFileSystem.Identity(file))
        } catch {
            var named = stat()
            var safe = Darwin.fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0
                && named.st_dev == directoryStat.st_dev && named.st_ino == directoryStat.st_ino
                && named.st_mode & S_IFMT == S_IFDIR
            if safe, fileFD >= 0 {
                var owned = stat(), namedFile = stat()
                safe = fd >= 0 && Darwin.fstat(fileFD, &owned) == 0
                    && Darwin.fstatat(fd, "access.json", &namedFile, AT_SYMLINK_NOFOLLOW) == 0
                    && namedFile.st_dev == owned.st_dev && namedFile.st_ino == owned.st_ino
                    && namedFile.st_mode & S_IFMT == S_IFREG
                if safe { safe = Darwin.unlinkat(fd, "access.json", 0) == 0 }
            }
            if safe { safe = Darwin.unlinkat(rootFD, name, AT_REMOVEDIR) == 0 }
            if !safe {
                throw InferenceFailure.backendFailed("Audio access preparation failed; changed or nonempty bootstrap retained at \(directory.path).")
            }
            // Do not forward arbitrary bookmark/FFI or injected writer details to diagnostics.
            throw InferenceFailure.backendFailed("Cannot prepare private audio access; owned bootstrap was removed.")
        }
    }

    private static func writeManifest(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw InferenceFailure.backendFailed("Cannot write audio access manifest.") }
                offset += count
            }
        }
        guard Darwin.fsync(fd) == 0 else {
            throw InferenceFailure.backendFailed("Cannot flush audio access manifest.")
        }
    }

    /// Call only after the owned provider and its pipe readers have actually stopped.
    /// Refuses unknown/replaced objects; it never recursively removes a directory.
    func finish() throws {
        let parentFD = try AudioFileSystem.openDirectory(directory.deletingLastPathComponent(),
                                                         label: "Audio bootstrap parent")
        defer { Darwin.close(parentFD) }
        let fd = Darwin.openat(parentFD, directory.lastPathComponent,
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw InferenceFailure.backendFailed("Audio access cleanup directory is unavailable.") }
        defer { Darwin.close(fd) }
        var d = stat()
        guard Darwin.fstat(fd, &d) == 0, Int64(d.st_dev) == directoryDevice,
              UInt64(d.st_ino) == directoryInode else {
            throw InferenceFailure.backendFailed("Audio access cleanup refused a changed directory.")
        }
        var file = stat()
        guard Darwin.fstatat(fd, "access.json", &file, AT_SYMLINK_NOFOLLOW) == 0,
              AudioFileSystem.Identity(file) == manifestIdentity else {
            throw InferenceFailure.backendFailed("Audio access cleanup refused a changed manifest.")
        }
        guard Darwin.unlinkat(fd, "access.json", 0) == 0 else {
            throw InferenceFailure.backendFailed("Cannot remove the owned audio access manifest.")
        }
        // Recheck the named directory so a replacement cannot be removed after an fd-based unlink.
        var named = stat()
        guard Darwin.fstatat(parentFD, directory.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Int64(named.st_dev) == directoryDevice, UInt64(named.st_ino) == directoryInode,
              Darwin.unlinkat(parentFD, directory.lastPathComponent, AT_REMOVEDIR) == 0 else {
            throw InferenceFailure.backendFailed("Audio bootstrap is not empty or changed; it was retained.")
        }
    }
}
