import Darwin
import Foundation

/// One process-wide observation per installed copy. Execution still uses the
/// ordinary resolver, which reacquires and validates the model for each run.
@MainActor enum WorkflowModelReadiness {
    struct Key: Hashable {
        let library: ObjectIdentifier?
        let installation: ModelID?
        let bookmark: Data?
        let identity: String
        init(library: ObjectIdentifier, installation: ModelID, identity: String) {
            self.library = library; self.installation = installation; bookmark = nil; self.identity = identity
        }
        init(bookmark: Data, identity: String) {
            library = nil; installation = nil; self.bookmark = bookmark; self.identity = identity
        }
    }

    struct FileStamp: Equatable {
        let path: String
        let size: Int
        let modified: Date?
        let fileID: String
        let changedSeconds: Int64?
        let changedNanoseconds: Int64?
    }

    private struct Pending {
        let token: UUID
        let stamps: [FileStamp]
        let task: Task<Void, Error>
    }
    private static var successful: [Key: [FileStamp]] = [:]
    private static var pending: [Key: Pending] = [:]

    /// Metadata is deliberately cheap; ModelLibrary owns the strict file and
    /// installation checks. A missing file cannot match a cached success.
    static func stamps(for record: ModelRecord, in snapshot: ModelLibrarySnapshot) throws -> [FileStamp] {
        guard record.state == .installed, record.availability == .available,
              let directory = record.directory,
              let entry = snapshot.catalog.first(where: { $0.id == record.catalogID }) else {
            throw WorkflowIssue(record.state == .preparationRequired
                ? "模型原始文件已校验，仍需准备执行引擎。" : "模型安装或位置当前不可用。")
        }
        return try entry.files.map { file in
            let url = directory.appendingPathComponent(file.path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
                                                          .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw WorkflowIssue("模型必要文件缺失或不是普通文件。")
            }
            return FileStamp(path: file.path, size: size, modified: values.contentModificationDate,
                             fileID: values.fileResourceIdentifier.map { String(describing: $0) } ?? "",
                             changedSeconds: nil, changedNanoseconds: nil)
        }
    }

    static func stamps(in directory: URL) throws -> [FileStamp] {
        func stamp(_ url: URL) throws -> FileStamp {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR) else {
                throw WorkflowIssue("模型目录含不可检查的文件或链接。")
            }
            return FileStamp(path: String(url.path.dropFirst(directory.path.count)), size: Int(info.st_size),
                             modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) +
                                 Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                             fileID: "\(info.st_dev):\(info.st_ino):\(info.st_mode & S_IFMT)",
                             changedSeconds: Int64(info.st_ctimespec.tv_sec),
                             changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
        }
        var result = [try stamp(directory)]
        var traversalError: Error?
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                         errorHandler: { _, error in traversalError = error; return false }) else {
            throw WorkflowIssue("模型目录当前无法检查。")
        }
        while let url = files.nextObject() as? URL { result.append(try stamp(url)) }
        if let traversalError { throw traversalError }
        return result.sorted { $0.path < $1.path }
    }

    static func hasSuccess(_ key: Key, stamps: [FileStamp]) -> Bool { successful[key] == stamps }

    static func rememberSuccess(_ key: Key, stamps: [FileStamp]) { successful[key] = stamps }

    static func invalidate(_ key: Key) {
        successful[key] = nil
        pending[key] = nil // An old waiter may finish, but cannot publish into the cache.
    }

    static func invalidate(_ key: Key, matching stamps: [FileStamp]) {
        if successful[key] == stamps { successful[key] = nil }
        if pending[key]?.stamps == stamps { pending[key] = nil }
    }

    static func check(_ key: Key, stamps: [FileStamp], force: Bool,
                      validate: @escaping @MainActor () async throws -> Void) async throws {
        if !force, successful[key] == stamps { return }
        if let current = pending[key], current.stamps == stamps {
            try await current.task.value
            return
        }
        successful[key] = nil
        let token = UUID()
        let task = Task { try await validate() }
        pending[key] = Pending(token: token, stamps: stamps, task: task)
        do {
            try await task.value
            if pending[key]?.token == token {
                pending[key] = nil
                successful[key] = stamps
            }
        } catch {
            if pending[key]?.token == token { pending[key] = nil }
            throw error
        }
    }
}
