import DInference
import CryptoKit
import Darwin
import Foundation

/// Placement is separate from the immutable workflow content/version and from tags.
public enum AssetImportMode: String, Sendable, CaseIterable { case reference, copy }
public enum AssetLocationRole: String, Codable, Sendable { case externalOriginal, independentCopy, projectCopy }
public enum AssetLocationStatus: String, Codable, Sendable {
    case verified, pendingVerification, offline, needsAuthorization, missing, changed, corrupt, previewOnly
}
public struct AssetFileFingerprint: Codable, Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let byteCount: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; byteCount = s.st_size
        modifiedSeconds = Int64(s.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(s.st_mtimespec.tv_nsec)
        changedSeconds = Int64(s.st_ctimespec.tv_sec); changedNanoseconds = Int64(s.st_ctimespec.tv_nsec)
    }
}
public struct AssetFileLocation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var libraryID: UUID
    public var libraryName: String
    public var role: AssetLocationRole
    /// Private local location data; backup projects strip it, portable manifests never encode it.
    public var url: URL?
    public var bookmark: Data?
    public var fingerprint: AssetFileFingerprint?
    public var registeredAt: Date
    public var lastVerifiedAt: Date?
    public var contentCreatedAt: Date?
    public init(id: UUID = UUID(), libraryID: UUID = UUID(), libraryName: String, role: AssetLocationRole,
                url: URL? = nil, bookmark: Data? = nil, fingerprint: AssetFileFingerprint? = nil,
                registeredAt: Date = Date(), lastVerifiedAt: Date? = nil, contentCreatedAt: Date? = nil) {
        self.id = id; self.libraryID = libraryID; self.libraryName = libraryName; self.role = role
        self.url = url; self.bookmark = bookmark; self.fingerprint = fingerprint
        self.registeredAt = registeredAt; self.lastVerifiedAt = lastVerifiedAt; self.contentCreatedAt = contentCreatedAt
    }
}
public struct AssetFileLocations: Codable, Sendable, Equatable {
    public var sha256: String
    public var byteCount: UInt64
    public var preferredLocationID: UUID
    public var locations: [AssetFileLocation]
    public init(sha256: String, byteCount: UInt64, preferredLocationID: UUID, locations: [AssetFileLocation]) {
        self.sha256 = sha256; self.byteCount = byteCount; self.preferredLocationID = preferredLocationID; self.locations = locations
    }
    func validate() throws {
        guard PitchSourceIdentity.isDigest(sha256), byteCount <= UInt64(Int.max), !locations.isEmpty, locations.count <= 64,
              Set(locations.map(\.id)).count == locations.count,
              locations.contains(where: { $0.id == preferredLocationID }),
              locations.allSatisfy({ !$0.libraryName.isEmpty && ($0.role == .projectCopy || ($0.url?.isFileURL == true && $0.bookmark != nil)) }) else {
            throw ProjectStoreError.invalidProject("素材位置记录损坏，未覆盖。")
        }
    }
}
public struct AssetLocationInspection: Sendable, Identifiable {
    public var id: UUID { location.id }
    public let location: AssetFileLocation
    public let status: AssetLocationStatus
    public let reason: String?
    public let resolvedURL: URL?
}
public struct AssetLocationOverview: Sendable {
    public let asset: ProjectAsset
    public let contentSHA256: String?
    public let byteCount: UInt64?
    public let locations: [AssetLocationInspection]
    public let selectedLocationID: UUID?
    public let knownUseCount: Int
    public let knownUses: [AssetKnownUse]
}
public struct AssetKnownUse: Sendable, Identifiable {
    public enum Kind: Sendable, Equatable { case graph, derivedAsset, run }
    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let graphID: UUID?
    public let nodeID: UUID?
    public let assetID: UUID?
}
public struct AssetLibraryAvailability: Sendable, Identifiable {
    public var id: UUID { libraryID }
    public let libraryID: UUID
    public let name: String
    public let offline: Int
    public let needsAuthorization: Int
    public let missing: Int
}
public struct ProjectFileOverview: Sendable {
    public let projectID: UUID
    public let revision: UInt64
    public let assets: [AssetLocationOverview]
    public let bytesToCollect: UInt64
    public let externalCount: Int
    public let libraryAvailability: [AssetLibraryAvailability]
}
public struct AssetRelocationResult: Sendable, Identifiable {
    public let id: UUID
    public let matched: Bool
    public let message: String
}

/// Opens only a user-selected file, never enumerates ancestors or follows links.
/// A read is a fixed bounded snapshot, verified before publication/use.
enum AssetLocationFiles {
    struct Read: Sendable { let data: Data; let fingerprint: AssetFileFingerprint }
    static func fingerprint(_ url: URL) throws -> AssetFileFingerprint {
        let parent = try ProjectFiles.openDirectory(url.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let fd = try ProjectFiles.openRelativeFile(url.lastPathComponent, in: parent)
        defer { Darwin.close(fd) }
        var opened = stat(), path = stat()
        guard fstat(fd, &opened) == 0,
              fstatat(parent, url.lastPathComponent, &path, AT_SYMLINK_NOFOLLOW) == 0,
              AssetFileFingerprint(opened) == AssetFileFingerprint(path) else {
            throw ProjectStoreError.externalModification
        }
        return .init(opened)
    }
    static func read(_ url: URL, maximum: Int) throws -> Read {
        let parent = try ProjectFiles.openDirectory(url.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let fd = try ProjectFiles.openRelativeFile(url.lastPathComponent, in: parent)
        defer { Darwin.close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_size >= 0, before.st_size <= maximum else {
            throw ProjectStoreError.invalidProject("素材大小无法读取或超过格式预算。")
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n == 0 { break }
            if n < 0 { if errno == EINTR { continue }; throw ProjectFiles.error() }
            guard data.count <= maximum - n else { throw ProjectStoreError.invalidProject("读取期间素材变大。") }
            data.append(contentsOf: buffer[..<n])
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0,
              fstatat(parent, url.lastPathComponent, &path, AT_SYMLINK_NOFOLLOW) == 0,
              AssetFileFingerprint(before) == AssetFileFingerprint(after),
              AssetFileFingerprint(after) == AssetFileFingerprint(path), data.count == after.st_size else {
            throw ProjectStoreError.externalModification
        }
        return .init(data: data, fingerprint: .init(after))
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func register(_ url: URL, read: Read, role: AssetLocationRole) throws -> AssetFileLocation {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        // The explicitly selected parent is this registered location's root. Aliases of the
        // same directory group together, without scanning or creating a second index.
        let fd = try ProjectFiles.openDirectory(url.deletingLastPathComponent()); defer { Darwin.close(fd) }
        var s = stat(); guard fstat(fd, &s) == 0 else { throw ProjectFiles.error() }
        let key = hash(Data("d.asset-library.v1:\(s.st_dev):\(s.st_ino)".utf8))
        let hex = String(key.prefix(32)); let pieces = [8, 4, 4, 4, 12]
        var cursor = hex.startIndex
        let uuidText = pieces.map { count -> String in let end = hex.index(cursor, offsetBy: count); defer { cursor = end }; return String(hex[cursor..<end]) }.joined(separator: "-")
        guard let libraryID = UUID(uuidString: uuidText) else { throw ProjectStoreError.invalidProject("位置身份无效。") }
        return .init(libraryID: libraryID, libraryName: url.deletingLastPathComponent().lastPathComponent,
                     role: role, url: url, bookmark: bookmark, fingerprint: read.fingerprint,
                     lastVerifiedAt: Date(), contentCreatedAt: created)
    }
    static func withResolved<T>(_ location: AssetFileLocation, _ body: (URL) throws -> T) throws -> T {
        guard let bookmark = location.bookmark else { throw ProjectStoreError.io("此位置需要重新授权。") }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw ProjectStoreError.io("此位置授权已过期，请重新定位。") }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
    static func inspect(_ location: AssetFileLocation, expected: AssetFileLocations, deep: Bool, maximum: Int) -> AssetLocationInspection {
        do {
            return try withResolved(location) { url in
                var s = stat()
                if lstat(url.path, &s) != 0 {
                    let code = errno
                    let status: AssetLocationStatus
                    if code == EACCES || code == EPERM { status = .needsAuthorization }
                    else if let original = location.url, original.path.hasPrefix("/Volumes/"), original.pathComponents.count > 2,
                            !FileManager.default.fileExists(atPath: "/Volumes/" + original.pathComponents[2]) { status = .offline }
                    else { status = .missing }
                    return .init(location: location, status: status, reason: String(cString: strerror(code)), resolvedURL: url)
                }
                guard s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1 else { return .init(location: location, status: .corrupt, reason: "位置不是独立普通文件。", resolvedURL: url) }
                if !deep {
                    let status: AssetLocationStatus = location.lastVerifiedAt != nil && location.fingerprint == AssetFileFingerprint(s) ? .verified : .pendingVerification
                    return .init(location: location, status: status, reason: status == .verified ? nil : "文件身份变化，使用前需核对内容。", resolvedURL: url)
                }
                let current = try read(url, maximum: maximum)
                let valid = current.data.count == expected.byteCount && hash(current.data) == expected.sha256
                return .init(location: location, status: valid ? .verified : .changed,
                             reason: valid ? nil : "当前字节与登记版本不同；旧版本未改。", resolvedURL: url)
            }
        } catch {
            var status: AssetLocationStatus = .needsAuthorization
            if let original = location.url {
                var s = stat()
                let result = lstat(original.path, &s)
                if result != 0, errno == ENOENT {
                    status = .missing
                    if original.path.hasPrefix("/Volumes/"), original.pathComponents.count > 2,
                       !FileManager.default.fileExists(atPath: "/Volumes/" + original.pathComponents[2]) { status = .offline }
                } else if result == 0, s.st_mode & S_IFMT != S_IFREG { status = .corrupt }
            }
            if error as? ProjectStoreError == .externalModification { status = .changed }
            return .init(location: location, status: status, reason: error.localizedDescription, resolvedURL: location.url)
        }
    }
}
