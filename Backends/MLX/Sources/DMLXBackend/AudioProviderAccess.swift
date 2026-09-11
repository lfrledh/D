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
                        }) throws -> AudioProviderAccess {
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
        let fd = Darwin.openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw InferenceFailure.backendFailed("Cannot open the private audio access bootstrap.")
        }
        defer { Darwin.close(fd) }
        var statValue = stat()
        guard Darwin.fstat(fd, &statValue) == 0 else {
            throw InferenceFailure.backendFailed("Cannot identify the private audio access bootstrap.")
        }
        // The parent is private and exclusively created; the writer itself refuses replacement.
        try AudioFileSystem.writeExclusive(data, to: manifest)
        let identity = try AudioFileSystem.regularFile(manifest, label: "Audio access manifest",
                                                       maximumBytes: 64 * 1024)
        guard identity.mode & 0o777 == 0o600 else {
            throw InferenceFailure.backendFailed("Audio access manifest is not private.")
        }
        return AudioProviderAccess(directory: directory, manifest: manifest,
            directoryDevice: Int64(statValue.st_dev), directoryInode: UInt64(statValue.st_ino),
            manifestIdentity: identity)
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
