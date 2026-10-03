import CryptoKit
import Darwin
import Foundation

public struct ProjectBackupInput: Sendable {
    public let relativePath: String
    public let sourceURL: URL?
    public let data: Data?
    public let sha256: String
    public let byteCount: UInt64
    public init(relativePath: String, sourceURL: URL?, data: Data?, sha256: String, byteCount: UInt64) {
        self.relativePath = relativePath; self.sourceURL = sourceURL; self.data = data
        self.sha256 = sha256; self.byteCount = byteCount
    }
}

public struct ProjectBackupModelDependency: Sendable {
    public let catalogID: String
    public let revision: String
    public let files: [ModelFile]
    public init(catalogID: String, revision: String, files: [ModelFile]) {
        self.catalogID = catalogID; self.revision = revision; self.files = files
    }
}

public struct ProjectBackupPlan: Sendable {
    public let projectID: UUID
    public let revision: UInt64
    public let files: [ProjectBackupInput]
    public let modelDependencies: [ProjectBackupModelDependency]
    public let missing: [String]
    public init(projectID: UUID, revision: UInt64, files: [ProjectBackupInput],
                modelDependencies: [ProjectBackupModelDependency] = [], missing: [String] = []) {
        self.projectID = projectID; self.revision = revision; self.files = files
        self.modelDependencies = modelDependencies; self.missing = missing
    }
}

public struct ProjectBackupReceipt: Sendable {
    public let id: UUID
    public let directory: URL
    public let complete: Bool
    public let fileCount: Int
    public let byteCount: UInt64
    public let missing: [String]
    public init(id: UUID, directory: URL, complete: Bool, fileCount: Int, byteCount: UInt64, missing: [String]) {
        self.id = id; self.directory = directory; self.complete = complete
        self.fileCount = fileCount; self.byteCount = byteCount; self.missing = missing
    }
}

public enum ProjectBackupError: LocalizedError, Sendable {
    public struct POSIXFailure: Sendable {
        public let operation: String
        public let code: Int32
        public let published: Bool
    }
    public struct FoundationFailure: Sendable {
        public let operation: String
        public let domain: String
        public let code: Int
        public let underlyingDomain: String?
        public let underlyingCode: Int?
    }

    case unsafePath(String)
    case alreadyExists(String)
    case invalidPackage(String)
    case integrity(String)
    case insufficientSpace
    case io(String)
    case posix(POSIXFailure)
    case foundation(FoundationFailure)

    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "备份位置或文件路径不安全。请重新选择有效位置。"
        case .alreadyExists: return "目标位置已有文件。请选择其他名称，现有文件未被覆盖。"
        case .invalidPackage: return "备份包无效或不完整。请检查备份来源。"
        case .integrity: return "备份文件核对失败。请检查原文件或备份包。"
        case .insufficientSpace: return "目标磁盘空间不足。请释放空间后重试。"
        case .io(let detail): return "备份或恢复失败：\(detail)"
        case .posix(let failure):
            let state = failure.published
                ? "结果可能已发布并保留，请先检查所选位置，勿直接重试。"
                : "结果未发布，现有文件未被覆盖。"
            let action: String
            switch failure.code {
            case EACCES, EPERM: action = "请检查所选位置的访问权限。"
            case ENOSPC: action = "请释放目标磁盘空间。"
            case ENOENT: action = "请确认所选磁盘或文件仍已连接。"
            case EROFS: action = "请选择可写位置。"
            default: action = "请检查所选位置和磁盘状态。"
            }
            return "备份或恢复失败（\(failure.operation)，POSIX \(failure.code)：\(String(cString: strerror(failure.code)))）。\(state)\(action)"
        case .foundation(let failure):
            let underlying = failure.underlyingDomain.map { "；底层 \($0) \(failure.underlyingCode ?? 0)" } ?? ""
            return "备份清单处理失败（\(failure.operation)，\(failure.domain) \(failure.code)\(underlying)）。请检查备份包或原文件。"
        }
    }
}

public enum ProjectBackup {
    public static func create(_ plan: ProjectBackupPlan, at destination: URL,
                              allowIncomplete: Bool = false) async throws -> ProjectBackupReceipt {
        try await create(plan, at: destination, allowIncomplete: allowIncomplete, checkpoint: { _ in })
    }

    // Internal seam: deterministic cancellation and source mutation tests without a public hook.
    static func create(_ plan: ProjectBackupPlan, at destination: URL, allowIncomplete: Bool = false,
                       checkpoint: @escaping @Sendable (Int) throws -> Void,
                       markerCheckpoint: @escaping @Sendable () throws -> Void = {}) async throws -> ProjectBackupReceipt {
        let work = Task.detached(priority: .userInitiated) {
            try createSync(plan, at: destination, allowIncomplete: allowIncomplete,
                           checkpoint: checkpoint, markerCheckpoint: markerCheckpoint)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    public static func verify(at backup: URL) async throws -> ProjectBackupReceipt {
        let work = Task.detached(priority: .userInitiated) { try verifySync(at: backup) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    public static func restore(at backup: URL, to destination: URL,
                               allowIncomplete: Bool = false) async throws -> ProjectBackupReceipt {
        try await restore(at: backup, to: destination, allowIncomplete: allowIncomplete, prepare: { _ in })
    }

    // The descriptor is borrowed for this synchronous call. The helper owns and closes it.
    static func restore(at backup: URL, to destination: URL, allowIncomplete: Bool = false,
                        prepare: @escaping @Sendable (Int32) throws -> Void) async throws -> ProjectBackupReceipt {
        let work = Task.detached(priority: .userInitiated) {
            try restoreSync(at: backup, to: destination, allowIncomplete: allowIncomplete, prepare: prepare)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

private extension ProjectBackup {
    static let manifestName = "manifest.json"
    static let markerName = "complete.sha256"
    static let maxManifestBytes = 32 * 1024 * 1024
    static let maxEntries = 32_768
    static let chunkSize = 1024 * 1024

    struct Entry: Codable { let path: String; let sha256: String; let byteCount: UInt64 }
    struct DependencyFile: Codable { let path: String; let size: UInt64; let digest: String; let algorithm: String }
    struct Dependency: Codable { let catalogID: String; let revision: String; let files: [DependencyFile] }
    struct Manifest: Codable {
        let version: Int
        let id: UUID
        let projectID: UUID
        let revision: UInt64
        let createdAt: Date
        let files: [Entry]
        let modelDependencies: [Dependency]
        let missing: [String]
    }
    struct Identity: Equatable {
        let device: dev_t; let inode: ino_t; let size: off_t
        let mtimeSec: Int; let mtimeNsec: Int
        let ctimeSec: Int; let ctimeNsec: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            mtimeSec = value.st_mtimespec.tv_sec; mtimeNsec = value.st_mtimespec.tv_nsec
            ctimeSec = value.st_ctimespec.tv_sec; ctimeNsec = value.st_ctimespec.tv_nsec
        }
    }
    struct DirectoryIdentity: Equatable {
        let device: dev_t; let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }

    static func createSync(_ plan: ProjectBackupPlan, at destination: URL, allowIncomplete: Bool,
                           checkpoint: @Sendable (Int) throws -> Void,
                           markerCheckpoint: @Sendable () throws -> Void) throws -> ProjectBackupReceipt {
        try Task.checkCancellation()
        let target = try absolute(destination)
        let manifest = try makeManifest(plan, allowIncomplete: allowIncomplete)
        let parent = try directory(target.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try absent(target.lastPathComponent, in: parent)
        for input in plan.files where input.sourceURL != nil {
            let source = try absolute(input.sourceURL!)
            if source.path == target.path || source.path.hasPrefix(target.path + "/") || target.path.hasPrefix(source.path + "/") {
                throw ProjectBackupError.unsafePath(source.path)
            }
        }
        try capacity(for: manifest.files, in: parent)
        let stageName = ".d-backup-\(UUID().uuidString).partial"
        guard mkdirat(parent, stageName, 0o700) == 0 else { throw io("create staging directory") }
        let stage = try childDirectory(stageName, in: parent)
        defer { Darwin.close(stage) }
        let ownedStage = try directoryIdentity(stage)
        var markerFD: Int32 = -1
        var published = false
        defer {
            // Keep partial evidence. Remove only the marker created by this invocation.
            if markerFD >= 0 {
                if !published {
                    var owned = stat(), named = stat()
                    if fstat(markerFD, &owned) == 0,
                       fstatat(stage, markerName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                       owned.st_dev == named.st_dev, owned.st_ino == named.st_ino,
                       named.st_mode & S_IFMT == S_IFREG {
                        if unlinkat(stage, markerName, 0) == 0 { _ = fsync(stage) }
                    }
                }
                Darwin.close(markerFD)
            }
        }
        guard fsync(parent) == 0 else { throw io("sync staging parent") }
        for (index, input) in plan.files.enumerated() {
            try Task.checkCancellation()
            let (folder, name) = try createParent(input.relativePath, in: stage)
            defer { Darwin.close(folder) }
            let output = try exclusiveFile(name, in: folder)
            do {
                if let data = input.data {
                    guard UInt64(data.count) == input.byteCount, digest(data) == input.sha256 else {
                        throw ProjectBackupError.integrity(input.relativePath)
                    }
                    try write(data, to: output)
                } else if let sourceURL = input.sourceURL {
                    let source = try sourceFile(sourceURL)
                    defer { Darwin.close(source) }
                    let before = try identity(source)
                    guard before.size >= 0, UInt64(before.size) == input.byteCount else {
                        throw ProjectBackupError.integrity(input.relativePath)
                    }
                    let copied = try transfer(source, to: output, expectedSize: input.byteCount)
                    try checkpoint(index)
                    guard copied == input.sha256,
                          try identity(source) == before,
                          try digestFile(source, expectedSize: input.byteCount) == input.sha256,
                          try identity(source) == before else { throw ProjectBackupError.integrity(input.relativePath) }
                    let current = try sourceFile(sourceURL)
                    defer { Darwin.close(current) }
                    guard try identity(current) == before else { throw ProjectBackupError.integrity(input.relativePath) }
                }
                guard fsync(output) == 0 else { throw io("sync backup file") }
            } catch {
                Darwin.close(output)
                throw error
            }
            Darwin.close(output)
            guard fsync(folder) == 0 else { throw io("sync backup directory") }
        }
        let bytes: Data
        do { bytes = try JSONEncoder.backupEncoder.encode(manifest) }
        catch { throw foundation("encode backup manifest", error) }
        guard bytes.count <= maxManifestBytes else { throw ProjectBackupError.invalidPackage("manifest too large") }
        try writeSmall(bytes, named: manifestName, in: stage)
        try Task.checkCancellation()
        _ = try inspect(manifest: manifest, in: stage, directory: target, verifyFiles: true)
        try absent(target.lastPathComponent, in: parent)
        try Task.checkCancellation()
        // All file and manifest validation precedes the marker. A failed partial is never complete.
        let marker = try exclusiveFile(markerName, in: stage)
        markerFD = marker
        try write(Data(digest(bytes).utf8), to: marker)
        guard fsync(marker) == 0 else { throw io("sync completion marker") }
        guard fsync(stage) == 0 else { throw io("sync completion directory") }
        try markerCheckpoint()
        try Task.checkCancellation()
        try checkPublicationRoute(parent: parent, parentURL: target.deletingLastPathComponent(),
                                  stage: stage, stageName: stageName, stageIdentity: ownedStage)
        guard renameatx_np(parent, stageName, parent, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            let failure = errno
            if failure == EEXIST { throw ProjectBackupError.alreadyExists(target.path) }
            throw io("publish backup package", code: failure)
        }
        published = true
        try checkPublishedTarget(target.lastPathComponent, in: parent, expected: ownedStage)
        guard fsync(parent) == 0 else { throw io("sync published backup parent", published: true) }
        return receipt(manifest, at: target)
    }

    static func verifySync(at backup: URL) throws -> ProjectBackupReceipt {
        let location = try absolute(backup)
        try rejectPartial(location)
        let root = try directory(location)
        defer { Darwin.close(root) }
        let manifest = try loadManifest(in: root)
        return try inspect(manifest: manifest, in: root, directory: location, verifyFiles: true)
    }

    static func restoreSync(at backup: URL, to destination: URL, allowIncomplete: Bool,
                            prepare: @Sendable (Int32) throws -> Void) throws -> ProjectBackupReceipt {
        try Task.checkCancellation()
        let source = try absolute(backup), target = try absolute(destination)
        try rejectPartial(source)
        guard source.path != target.path, !source.path.hasPrefix(target.path + "/"),
              !target.path.hasPrefix(source.path + "/") else { throw ProjectBackupError.unsafePath(target.path) }
        let backupFD = try directory(source)
        defer { Darwin.close(backupFD) }
        let manifest = try loadManifest(in: backupFD)
        let verified = try inspect(manifest: manifest, in: backupFD, directory: source, verifyFiles: true)
        guard verified.complete || allowIncomplete else { throw ProjectBackupError.invalidPackage("incomplete backup requires opt-in") }
        let parent = try directory(target.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try absent(target.lastPathComponent, in: parent)
        try capacity(for: manifest.files, in: parent)
        let stageName = ".d-restore-\(UUID().uuidString).partial"
        guard mkdirat(parent, stageName, 0o700) == 0 else { throw io("create restore staging directory") }
        let stage = try childDirectory(stageName, in: parent)
        defer { Darwin.close(stage) }
        let ownedStage = try directoryIdentity(stage)
        guard fsync(parent) == 0 else { throw io("sync restore staging parent") }
        for entry in manifest.files {
            try Task.checkCancellation()
            let input = try relativeFile(entry.path, in: backupFD)
            defer { Darwin.close(input) }
            let before = try identity(input)
            let (folder, name) = try createParent(entry.path, in: stage)
            defer { Darwin.close(folder) }
            let output = try exclusiveFile(name, in: folder)
            do {
                guard try transfer(input, to: output, expectedSize: entry.byteCount) == entry.sha256,
                      try identity(input) == before else { throw ProjectBackupError.integrity(entry.path) }
                guard fsync(output) == 0 else { throw io("sync restored file") }
            } catch { Darwin.close(output); throw error }
            Darwin.close(output)
            guard fsync(folder) == 0 else { throw io("sync restore directory") }
        }
        // Check all original bytes before ProjectStore intentionally changes project.json.
        _ = try inspect(manifest: manifest, in: stage, directory: target, verifyFiles: true)
        try Task.checkCancellation()
        try checkPublicationRoute(parent: parent, parentURL: target.deletingLastPathComponent(),
                                  stage: stage, stageName: stageName, stageIdentity: ownedStage)
        try prepare(stage)
        try Task.checkCancellation()
        guard fsync(stage) == 0 else { throw io("sync restore package") }
        try checkPublicationRoute(parent: parent, parentURL: target.deletingLastPathComponent(),
                                  stage: stage, stageName: stageName, stageIdentity: ownedStage)
        guard renameatx_np(parent, stageName, parent, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            let failure = errno
            if failure == EEXIST { throw ProjectBackupError.alreadyExists(target.path) }
            throw io("publish restore", code: failure)
        }
        try checkPublishedTarget(target.lastPathComponent, in: parent, expected: ownedStage)
        guard fsync(parent) == 0 else { throw io("sync published restore parent", published: true) }
        return receipt(manifest, at: target)
    }

    static func makeManifest(_ plan: ProjectBackupPlan, allowIncomplete: Bool) throws -> Manifest {
        guard plan.files.count <= maxEntries, plan.missing.count <= maxEntries,
              plan.modelDependencies.count <= maxEntries else { throw ProjectBackupError.invalidPackage("too many entries") }
        guard plan.missing.isEmpty || allowIncomplete else { throw ProjectBackupError.invalidPackage("incomplete backup requires opt-in") }
        var paths = Set<String>()
        var entries = [Entry]()
        var total: UInt64 = 0
        for file in plan.files {
            try validRelative(file.relativePath)
            guard (file.sourceURL == nil) != (file.data == nil), validSHA(file.sha256),
                  paths.insert(file.relativePath.lowercased()).inserted else {
                throw ProjectBackupError.invalidPackage("invalid or duplicate file input")
            }
            let (sum, overflow) = total.addingReportingOverflow(file.byteCount)
            guard !overflow else { throw ProjectBackupError.invalidPackage("byte count overflow") }
            total = sum
            entries.append(Entry(path: file.relativePath, sha256: file.sha256, byteCount: file.byteCount))
        }
        try validateTree(entries.map(\.path))
        for path in plan.missing { try validRelative(path) }
        var dependencies = [Dependency]()
        var count = 0
        for item in plan.modelDependencies {
            guard validLabel(item.catalogID), validLabel(item.revision) else { throw ProjectBackupError.invalidPackage("invalid model identity") }
            count += item.files.count
            guard count <= maxEntries else { throw ProjectBackupError.invalidPackage("too many model files") }
            let files = try item.files.map { file -> DependencyFile in
                try validRelative(file.path)
                guard (file.digestAlgorithm == .sha256 && validSHA(file.sha256)) ||
                        (file.digestAlgorithm == .gitBlobSHA1 && validHex(file.sha256, length: 40)) else {
                    throw ProjectBackupError.invalidPackage("invalid model digest")
                }
                return DependencyFile(path: file.path, size: file.size, digest: file.sha256,
                                      algorithm: file.digestAlgorithm.rawValue)
            }
            dependencies.append(Dependency(catalogID: item.catalogID, revision: item.revision, files: files))
        }
        return Manifest(version: 1, id: UUID(), projectID: plan.projectID, revision: plan.revision,
                        createdAt: Date(), files: entries, modelDependencies: dependencies, missing: plan.missing)
    }

    static func loadManifest(in root: Int32) throws -> Manifest {
        let marker = try readSmall(markerName, in: root, limit: 64)
        let bytes = try readSmall(manifestName, in: root, limit: maxManifestBytes)
        guard marker == Data(digest(bytes).utf8) else { throw ProjectBackupError.integrity("completion marker") }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: bytes) }
        catch { throw foundation("decode backup manifest", error) }
        guard manifest.version == 1, manifest.files.count <= maxEntries,
              manifest.missing.count <= maxEntries, manifest.modelDependencies.count <= maxEntries else {
            throw ProjectBackupError.invalidPackage("unsupported or oversized manifest")
        }
        var total: UInt64 = 0
        for item in manifest.files {
            try validRelative(item.path)
            guard validSHA(item.sha256) else { throw ProjectBackupError.invalidPackage("invalid file digest") }
            let (sum, overflow) = total.addingReportingOverflow(item.byteCount)
            guard !overflow else { throw ProjectBackupError.invalidPackage("byte count overflow") }
            total = sum
        }
        try validateTree(manifest.files.map(\.path))
        for path in manifest.missing { try validRelative(path) }
        var modelCount = 0
        for dependency in manifest.modelDependencies {
            guard validLabel(dependency.catalogID), validLabel(dependency.revision) else { throw ProjectBackupError.invalidPackage("model identity") }
            modelCount += dependency.files.count
            guard modelCount <= maxEntries else { throw ProjectBackupError.invalidPackage("too many model files") }
            for file in dependency.files {
                try validRelative(file.path)
                guard (file.algorithm == "sha256" && validSHA(file.digest)) ||
                        (file.algorithm == "gitBlobSHA1" && validHex(file.digest, length: 40)) else {
                    throw ProjectBackupError.invalidPackage("model digest")
                }
            }
        }
        return manifest
    }

    static func inspect(manifest: Manifest, in root: Int32, directory: URL, verifyFiles: Bool) throws -> ProjectBackupReceipt {
        if verifyFiles {
            for item in manifest.files {
                try Task.checkCancellation()
                let fd = try relativeFile(item.path, in: root)
                defer { Darwin.close(fd) }
                let before = try identity(fd)
                guard before.size >= 0, UInt64(before.size) == item.byteCount,
                      try digestFile(fd, expectedSize: item.byteCount) == item.sha256,
                      try identity(fd) == before else { throw ProjectBackupError.integrity(item.path) }
            }
        }
        return receipt(manifest, at: directory)
    }

    static func receipt(_ manifest: Manifest, at url: URL) -> ProjectBackupReceipt {
        ProjectBackupReceipt(id: manifest.id, directory: url, complete: manifest.missing.isEmpty,
                             fileCount: manifest.files.count,
                             byteCount: manifest.files.reduce(0) { $0 + $1.byteCount }, missing: manifest.missing)
    }

    static func validRelative(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0"),
              path == path.precomposedStringWithCanonicalMapping else { throw ProjectBackupError.unsafePath(path) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
              parts.first != Substring(manifestName), parts.first != Substring(markerName) else {
            throw ProjectBackupError.unsafePath(path)
        }
    }

    static func validateTree(_ paths: [String]) throws {
        let names = paths.map { $0.lowercased() }
        let unique = Set(names)
        guard unique.count == names.count else { throw ProjectBackupError.invalidPackage("duplicate paths") }
        for path in names {
            var parts = path.split(separator: "/")
            while parts.count > 1 {
                parts.removeLast()
                guard !unique.contains(parts.joined(separator: "/")) else {
                    throw ProjectBackupError.invalidPackage("file and directory collision")
                }
            }
        }
    }

    static func validHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validSHA(_ value: String) -> Bool { validHex(value, length: 64) }
    static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func absolute(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path else {
            throw ProjectBackupError.unsafePath(url.path)
        }
        if url.path != "/" { try validAbsoluteComponents(url.path) }
        return url
    }
    static func validAbsoluteComponents(_ path: String) throws {
        for part in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part != ".", part != "..", !part.contains("\\"), !part.contains("\0") else {
                throw ProjectBackupError.unsafePath(path)
            }
        }
    }
    static func directory(_ url: URL) throws -> Int32 {
        let location = try absolute(url)
        var current = Darwin.open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw io("open root") }
        if location.path == "/" { return current }
        for component in location.path.dropFirst().split(separator: "/") {
            let next = openat(current, String(component), O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(current)
            guard next >= 0 else { throw io("open directory", code: failure) }
            current = next
        }
        return current
    }
    static func childDirectory(_ name: String, in parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw io("open child directory") }
        return fd
    }
    static func directoryIdentity(_ fd: Int32) throws -> DirectoryIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw io("stat directory") }
        guard value.st_mode & S_IFMT == S_IFDIR else { throw ProjectBackupError.unsafePath("non-directory") }
        return DirectoryIdentity(value)
    }
    static func namedDirectoryIdentity(_ name: String, in parent: Int32,
                                       published: Bool = false) throws -> DirectoryIdentity {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw io("stat named directory", published: published)
        }
        guard value.st_mode & S_IFMT == S_IFDIR else { throw ProjectBackupError.unsafePath(name) }
        return DirectoryIdentity(value)
    }
    static func checkPublicationRoute(parent: Int32, parentURL: URL, stage: Int32,
                                      stageName: String, stageIdentity: DirectoryIdentity) throws {
        let route = try directory(parentURL)
        defer { Darwin.close(route) }
        guard try directoryIdentity(route) == directoryIdentity(parent),
              try directoryIdentity(stage) == stageIdentity,
              try namedDirectoryIdentity(stageName, in: parent) == stageIdentity else {
            throw ProjectBackupError.integrity("staging directory or destination parent changed")
        }
    }
    static func checkPublishedTarget(_ name: String, in parent: Int32,
                                     expected: DirectoryIdentity) throws {
        guard try namedDirectoryIdentity(name, in: parent, published: true) == expected else {
            throw ProjectBackupError.integrity("published directory identity changed; result retained")
        }
    }
    static func rejectPartial(_ url: URL) throws {
        let name = url.lastPathComponent
        guard !((name.hasPrefix(".d-backup-") || name.hasPrefix(".d-restore-")) && name.hasSuffix(".partial")) else {
            throw ProjectBackupError.invalidPackage("staging directory is incomplete")
        }
    }
    static func createParent(_ path: String, in root: Int32) throws -> (Int32, String) {
        var parts = path.split(separator: "/").map(String.init)
        let name = parts.removeLast()
        var current = dup(root)
        guard current >= 0 else { throw io("duplicate directory") }
        for component in parts {
            if mkdirat(current, component, 0o700) == 0 {
                if fsync(current) != 0 {
                    let failure = errno
                    Darwin.close(current)
                    throw io("sync new directory entry", code: failure)
                }
            } else {
                let failure = errno
                if failure != EEXIST {
                    Darwin.close(current)
                    throw io("create backup directory", code: failure)
                }
            }
            let next = openat(current, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(current)
            guard next >= 0 else { throw io("open backup directory", code: failure) }
            current = next
        }
        return (current, name)
    }
    static func relativeFile(_ path: String, in root: Int32) throws -> Int32 {
        try validRelative(path)
        var parts = path.split(separator: "/").map(String.init)
        let name = parts.removeLast()
        var current = dup(root)
        guard current >= 0 else { throw io("duplicate directory") }
        for part in parts {
            let next = openat(current, part, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(current)
            guard next >= 0 else { throw io("open package directory", code: failure) }
            current = next
        }
        let fd = openat(current, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let failure = errno
        Darwin.close(current)
        guard fd >= 0 else { throw io("open package file", code: failure) }
        do { _ = try identity(fd); return fd } catch { Darwin.close(fd); throw error }
    }
    static func sourceFile(_ url: URL) throws -> Int32 {
        let location = try absolute(url)
        let parent = try directory(location.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let fd = openat(parent, location.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw io("open source file") }
        do { _ = try identity(fd); return fd } catch { Darwin.close(fd); throw error }
    }
    static func identity(_ fd: Int32) throws -> Identity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw io("stat file") }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_size >= 0 else {
            throw ProjectBackupError.unsafePath("nonregular or linked file")
        }
        return Identity(value)
    }
    static func absent(_ name: String, in parent: Int32) throws {
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { throw ProjectBackupError.alreadyExists(name) }
        let failure = errno
        guard failure == ENOENT else { throw io("check destination", code: failure) }
    }
    static func exclusiveFile(_ name: String, in folder: Int32) throws -> Int32 {
        let fd = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw io("create backup file") }
        return fd
    }
    static func writeSmall(_ data: Data, named name: String, in folder: Int32) throws {
        let fd = try exclusiveFile(name, in: folder)
        do { try write(data, to: fd); guard fsync(fd) == 0 else { throw io("sync metadata") } }
        catch { Darwin.close(fd); throw error }
        Darwin.close(fd)
        guard fsync(folder) == 0 else { throw io("sync metadata directory") }
    }
    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(chunkSize, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                if count < 0 { throw io("write file") }
                guard count > 0 else { throw ProjectBackupError.io("write file returned zero bytes") }
                offset += count
            }
        }
    }
    static func transfer(_ source: Int32, to target: Int32, expectedSize: UInt64) throws -> String {
        guard lseek(source, 0, SEEK_SET) == 0 else { throw io("seek source") }
        var hasher = SHA256(), total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw io("read source") }
            if count == 0 { break }
            let (sum, overflow) = total.addingReportingOverflow(UInt64(count))
            guard !overflow, sum <= expectedSize else { throw ProjectBackupError.integrity("source size changed") }
            total = sum
            hasher.update(data: Data(buffer.prefix(count)))
            try write(Data(buffer.prefix(count)), to: target)
        }
        guard total == expectedSize else { throw ProjectBackupError.integrity("source size changed") }
        return hex(hasher.finalize())
    }
    static func digestFile(_ fd: Int32, expectedSize: UInt64) throws -> String {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw io("seek file") }
        var hasher = SHA256(), total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw io("read file") }
            if count == 0 { break }
            let (sum, overflow) = total.addingReportingOverflow(UInt64(count))
            guard !overflow, sum <= expectedSize else { throw ProjectBackupError.integrity("file size changed") }
            total = sum
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard total == expectedSize else { throw ProjectBackupError.integrity("file size changed") }
        return hex(hasher.finalize())
    }
    static func readSmall(_ name: String, in root: Int32, limit: Int) throws -> Data {
        let fd = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw io("open package metadata") }
        defer { Darwin.close(fd) }
        let before = try identity(fd)
        guard before.size <= limit else { throw ProjectBackupError.invalidPackage("metadata too large") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw io("read metadata") }
            if count == 0 { break }
            guard data.count <= limit - count else { throw ProjectBackupError.invalidPackage("metadata too large") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard try identity(fd) == before else { throw ProjectBackupError.integrity("metadata changed") }
        return data
    }
    static func capacity(for files: [Entry], in fd: Int32) throws {
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0 else { throw io("check free space") }
        let needed = files.reduce(UInt64(0)) { $0 + $1.byteCount }
        let (required, requiredOverflow) = needed.addingReportingOverflow(UInt64(maxManifestBytes))
        let (available, overflow) = UInt64(volume.f_bavail).multipliedReportingOverflow(by: UInt64(volume.f_bsize))
        guard !requiredOverflow, !overflow, available >= required else { throw ProjectBackupError.insufficientSpace }
    }
    static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func io(_ action: String, code: Int32 = errno, published: Bool = false) -> ProjectBackupError {
        .posix(.init(operation: action, code: code, published: published))
    }
    static func foundation(_ action: String, _ error: Error) -> ProjectBackupError {
        let primary = error as NSError
        let underlying = primary.userInfo[NSUnderlyingErrorKey] as? NSError
        return .foundation(.init(operation: action, domain: primary.domain, code: primary.code,
                                 underlyingDomain: underlying?.domain, underlyingCode: underlying?.code))
    }
}

private extension JSONEncoder {
    static var backupEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
