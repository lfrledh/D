import DInference
import Darwin
import Foundation
import ImageIO

/// Owns durable project records and media. Its actor keeps file I/O off the UI executor.
/// The lock prevents two application sessions from silently replacing each other's manifest.
public actor ProjectStore {
    public nonisolated let rootURL: URL
    public nonisolated var artifactDirectory: URL { rootURL.appendingPathComponent("Tasks", isDirectory: true) }
    public static let manifestFilename = "project.json"
    private let rootFD: Int32
    private let lockFD: Int32
    private var manifest: ProjectManifest
    private var isClosed = false

    private init(rootURL: URL, rootFD: Int32, lockFD: Int32, manifest: ProjectManifest) {
        self.rootURL = rootURL
        self.rootFD = rootFD
        self.lockFD = lockFD
        self.manifest = manifest
    }

    deinit { if !isClosed { Darwin.close(lockFD); Darwin.close(rootFD) } }

    public static func create(at url: URL, name: String) async throws -> ProjectStore {
        let root = try ProjectFiles.projectURL(url)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectStoreError.invalidProject("项目名称不能为空。")
        }
        let parent = try ProjectFiles.openDirectory(root.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        guard mkdirat(parent, root.lastPathComponent, 0o700) == 0 else {
            if errno == EEXIST { throw ProjectStoreError.alreadyExists(root.path) }
            throw ProjectFiles.error()
        }
        let descriptor = openat(parent, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProjectFiles.error() }
        do {
            let lock = try ProjectFiles.lock(in: descriptor)
            do {
                guard mkdirat(descriptor, "Tasks", 0o700) == 0 else { throw ProjectFiles.error() }
                let initial = ProjectManifest(name: name)
                try ProjectFiles.writeManifest(initial, in: descriptor, replacing: false)
                return ProjectStore(rootURL: root, rootFD: descriptor, lockFD: lock, manifest: initial)
            } catch { Darwin.close(lock); throw error }
        } catch { Darwin.close(descriptor); throw error }
    }

    public static func open(at url: URL) async throws -> ProjectStore {
        let root = try ProjectFiles.projectURL(url)
        let descriptor = try ProjectFiles.openDirectory(root)
        var lock: Int32 = -1
        var transferred = false
        defer {
            if !transferred {
                if lock >= 0 { Darwin.close(lock) }
                Darwin.close(descriptor)
            }
        }
        lock = try ProjectFiles.lock(in: descriptor)
                let data = try ProjectFiles.read(relative: manifestFilename, in: descriptor, limit: 32 * 1_024 * 1_024)
                struct Header: Decodable { let schemaVersion: Int }
                let decoder = JSONDecoder()
                let header: Header
                do { header = try decoder.decode(Header.self, from: data) }
                catch { throw ProjectStoreError.invalidProject("项目清单不是有效的 JSON。") }
                guard header.schemaVersion == ProjectManifest.currentSchemaVersion else {
                    throw ProjectStoreError.unsupportedSchema(header.schemaVersion)
                }
                let loaded: ProjectManifest
                do { loaded = try decoder.decode(ProjectManifest.self, from: data) }
                catch { throw ProjectStoreError.invalidProject("项目清单缺少必要字段或已经损坏。") }
                try ProjectFiles.validate(loaded)
                let tasks = try ProjectFiles.openRelativeDirectory("Tasks", in: descriptor)
                Darwin.close(tasks)
                let store = ProjectStore(rootURL: root, rootFD: descriptor, lockFD: lock, manifest: loaded)
                // Ownership of both descriptors has moved to the actor before recovery can throw.
                transferred = true
                return try await store.recoverOnOpen()
    }

    public func snapshot() -> ProjectManifest { manifest }

    public func saveDraft(_ draft: ProjectDraft) throws -> ProjectManifest {
        guard !isClosed else { throw ProjectStoreError.io("项目会话已关闭，请重新打开项目") }
        guard manifest.draft != draft else { return manifest }
        var candidate = manifest
        candidate.draft = draft
        try commit(candidate)
        return manifest
    }

    /// Recognize the same directory after a Finder move without trusting its displayed name
    /// or a copied manifest UUID. The caller must hold access to the newly selected location.
    public func matchesLocation(_ url: URL) throws -> Bool {
        guard !isClosed else { throw ProjectStoreError.io("项目会话已关闭，请重新打开项目") }
        let directory = try ProjectFiles.openDirectory(ProjectFiles.projectURL(url))
        defer { Darwin.close(directory) }
        return try sameDirectory(directory)
    }

    /// Transfers a drained session to the same physical directory at its new authorized URL.
    /// An arbitrary project copy cannot take over the lock or unsaved terminal result records.
    public func relocated(to url: URL) throws -> ProjectStore {
        guard !isClosed else { throw ProjectStoreError.io("项目会话已关闭，请重新打开项目") }
        let location = try ProjectFiles.projectURL(url)
        let directory = try ProjectFiles.openDirectory(location)
        var transferred = false
        defer { if !transferred { Darwin.close(directory) } }
        guard try sameDirectory(directory) else {
            throw ProjectStoreError.invalidProject("所选目录不是当前项目的移动后位置，请选择原项目。")
        }
        try verifyUnchangedManifest()
        guard fsync(rootFD) == 0 else { throw ProjectFiles.error() }
        let lock = dup(lockFD)
        guard lock >= 0 else { throw ProjectFiles.error() }
        let replacement = ProjectStore(rootURL: location, rootFD: directory, lockFD: lock, manifest: manifest)
        transferred = true
        Darwin.close(lockFD)
        Darwin.close(rootFD)
        isClosed = true
        return replacement
    }

    public func enqueue(request: InferenceRequest) throws -> ProjectManifest {
        try request.validate()
        guard !manifest.jobs.contains(where: { $0.id == request.id }) else {
            throw ProjectStoreError.invalidProject("任务编号重复。")
        }
        var candidate = manifest
        candidate.jobs.append(ProjectJob(id: request.id, request: request))
        try commit(candidate)
        return manifest
    }

    public func updateJob(id: UUID, state: JobState, error: String? = nil) throws -> ProjectManifest {
        guard let index = manifest.jobs.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingJob }
        let current = manifest.jobs[index]
        guard !current.state.isTerminal || current.state == state else { throw ProjectStoreError.invalidTransition }
        guard current.state != state || current.error != error else { return manifest }
        var candidate = manifest
        candidate.jobs[index].state = state
        candidate.jobs[index].error = error
        try commit(candidate)
        return manifest
    }

    /// Only an authoritative runtime completion may make a task completed. Every PNG is decoded
    /// and the complete candidate manifest is durable before the caller receives success.
    public func complete(id: UUID, result: InferenceResult) throws -> ProjectManifest {
        guard let index = manifest.jobs.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingJob }
        guard !manifest.jobs[index].state.isTerminal else { throw ProjectStoreError.invalidTransition }
        guard !result.artifacts.isEmpty else { throw ProjectStoreError.invalidProject("生成任务没有交付图片。") }
        try checkLocation()
        var candidate = manifest
        for artifact in result.artifacts {
            guard artifact.mediaType == "image/png" else {
                throw ProjectStoreError.invalidProject("当前工作台只登记 PNG 生成结果。")
            }
            let relative = try ProjectFiles.relativeArtifact(artifact.url, root: rootURL, jobID: id)
            guard !candidate.assets.contains(where: { $0.relativePath == relative }) else {
                throw ProjectStoreError.invalidProject("图片已登记，不能重复引用。")
            }
            let metadata = try readPNG(relative: relative, job: candidate.jobs[index])
            let asset = ProjectAsset(jobID: id, relativePath: relative, metadata: metadata)
            candidate.assets.append(asset)
            candidate.jobs[index].artifactIDs.append(asset.id)
        }
        candidate.jobs[index].state = .completed
        candidate.jobs[index].error = nil
        candidate.jobs[index].resultMetadata = result.metadata
        try commit(candidate)
        return manifest
    }

    /// Reconcile only published PNGs in a recorded task's precisely named private directory.
    /// Never starts inference, deletes media, follows a symlink, or adopts an unknown task.
    public func recoverPublishedArtifacts() throws -> ProjectManifest {
        try recover(markInterrupted: false)
    }

    public func assetURL(for asset: ProjectAsset) throws -> URL {
        guard let registered = manifest.assets.first(where: { $0.id == asset.id }), registered == asset else {
            throw ProjectStoreError.missingAsset
        }
        try checkLocation()
        let file = try ProjectFiles.openRelativeFile(asset.relativePath, in: rootFD)
        Darwin.close(file)
        return rootURL.appendingPathComponent(asset.relativePath)
    }

    /// Export is a byte-for-byte copy. A temporary sibling is published with RENAME_EXCL;
    /// an existing destination is never truncated, even if it appears during the copy.
    public func export(assetID: UUID, to destination: URL) throws {
        guard let asset = manifest.assets.first(where: { $0.id == assetID }) else { throw ProjectStoreError.missingAsset }
        try checkLocation()
        guard destination.isFileURL, destination.path.hasPrefix("/"),
              !destination.lastPathComponent.isEmpty else { throw ProjectStoreError.unsafePath(destination.path) }
        let source = try ProjectFiles.openRelativeFile(asset.relativePath, in: rootFD)
        defer { Darwin.close(source) }
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publish(in: parent, name: destination.lastPathComponent, replacing: false) { target in
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = Darwin.read(source, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProjectFiles.error()
                }
                try buffer.withUnsafeBytes { bytes in
                    try ProjectFiles.writeAll(UnsafeRawBufferPointer(rebasing: bytes[..<count]), to: target)
                }
            }
        }
    }

    public func flush() throws {
        try checkLocation()
        // Each mutation is already durable. Verify the manifest still exists; a disconnected
        // volume must not be mistaken for a successful close merely because state is in memory.
        try verifyUnchangedManifest()
        guard fsync(rootFD) == 0 else { throw ProjectFiles.error() }
    }

    private func verifyUnchangedManifest() throws {
        let data = try ProjectFiles.read(relative: Self.manifestFilename, in: rootFD, limit: 32 * 1_024 * 1_024)
        let current: ProjectManifest
        do { current = try JSONDecoder().decode(ProjectManifest.self, from: data) }
        catch { throw ProjectStoreError.externalModification }
        guard current == manifest else {
            throw ProjectStoreError.externalModification
        }
    }

    /// The host calls this only after all jobs have drained and terminal records are saved.
    /// Failure leaves the session open, so the user can reconnect the drive and retry.
    /// A host with no pending outcome or changed draft may explicitly preserve an external
    /// edit while releasing its session. This never writes the in-memory snapshot over it.
    public func close(preserveExternalChanges: Bool = false) throws {
        guard !isClosed else { return }
        do { try flush() }
        catch ProjectStoreError.externalModification where preserveExternalChanges {
            try checkLocation()
            guard fsync(rootFD) == 0 else { throw ProjectFiles.error() }
        }
        Darwin.close(lockFD)
        Darwin.close(rootFD)
        isClosed = true
    }

    private func recoverOnOpen() throws -> ProjectStore {
        _ = try recover(markInterrupted: true)
        return self
    }

    private func recover(markInterrupted: Bool) throws -> ProjectManifest {
        try checkLocation()
        var candidate = manifest
        if markInterrupted {
            for index in candidate.jobs.indices where !candidate.jobs[index].state.isTerminal {
                candidate.jobs[index].state = .interrupted
                candidate.jobs[index].error = "上次运行未正常结束。已保留记录，不会自动重新生成。"
            }
        }
        let taskFD = try ProjectFiles.openRelativeDirectory("Tasks", in: rootFD)
        defer { Darwin.close(taskFD) }
        let names = try ProjectFiles.directoryNames(taskFD)
        for name in names.sorted() {
            guard let jobID = ProjectFiles.taskOwner(name),
                  let index = candidate.jobs.firstIndex(where: { $0.id == jobID }) else { continue }
            let relative = "Tasks/\(name)/image.png"
            guard !candidate.assets.contains(where: { $0.relativePath == relative }) else { continue }
            do {
                // Inspect the final entry through a safely opened directory descriptor as well;
                // AT_SYMLINK_NOFOLLOW alone does not protect intermediate path components.
                let publishedDirectory = try ProjectFiles.openRelativeDirectory(name, in: taskFD)
                var info = stat()
                let status = fstatat(publishedDirectory, "image.png", &info, AT_SYMLINK_NOFOLLOW)
                let failure = errno
                Darwin.close(publishedDirectory)
                // Partial directories are normal after interruption. Missing image.png is not an error.
                if status != 0, failure == ENOENT { continue }
                guard status == 0 else { throw ProjectStoreError.io(String(cString: strerror(failure))) }
                let metadata = try readPNG(relative: relative, job: candidate.jobs[index])
                let asset = ProjectAsset(jobID: jobID, relativePath: relative, metadata: metadata)
                candidate.assets.append(asset)
                candidate.jobs[index].artifactIDs.append(asset.id)
                if candidate.jobs[index].state != .completed {
                    candidate.jobs[index].state = .interrupted
                    candidate.jobs[index].error = "已恢复生成后尚未登记的图片；任务完整结束记录缺失，请检查作品。"
                }
            } catch {
                // Keep both the original file and job record for diagnosis. Never turn corrupt
                // or redirected files into artwork just to make project opening succeed.
                candidate.jobs[index].error = "发现未登记的图片，但无法安全恢复：\(error.localizedDescription)"
            }
        }
        if candidate != manifest { try commit(candidate) }
        return manifest
    }

    private func readPNG(relative: String, job: ProjectJob) throws -> MediaMetadata {
        let data = try ProjectFiles.read(relative: relative, in: rootFD, limit: 64 * 1_024 * 1_024)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.starts(with: signature),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              width * height <= 100_000_000 else { throw ProjectStoreError.invalidImage(relative) }
        if case .image(let request) = job.request.input {
            guard width == request.width, height == request.height else { throw ProjectStoreError.invalidImage(relative) }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == width, image.height == height else { throw ProjectStoreError.invalidImage(relative) }
        return MediaMetadata(width: width, height: height,
                             bitDepth: properties[kCGImagePropertyDepth as String] as? Int,
                             colorSpace: properties[kCGImagePropertyProfileName as String] as? String)
    }

    private func checkLocation() throws {
        guard !isClosed else { throw ProjectStoreError.io("项目会话已关闭，请重新打开项目") }
        let current = try ProjectFiles.openDirectory(rootURL)
        defer { Darwin.close(current) }
        guard try sameDirectory(current) else {
            throw ProjectStoreError.io("项目位置已改变，请重新定位项目")
        }
    }

    private func sameDirectory(_ descriptor: Int32) throws -> Bool {
        var expected = stat(), actual = stat()
        guard fstat(rootFD, &expected) == 0, fstat(descriptor, &actual) == 0 else { throw ProjectFiles.error() }
        return expected.st_dev == actual.st_dev && expected.st_ino == actual.st_ino
    }

    private func commit(_ value: ProjectManifest) throws {
        try checkLocation()
        // flock protects cooperating sessions; also detect an editor that ignores the lock.
        // This is an optimistic check, not a promise of exclusion against hostile concurrent writes.
        try verifyUnchangedManifest()
        guard manifest.revision < UInt64.max else {
            throw ProjectStoreError.invalidProject("项目修订编号已经达到上限，无法安全保存更多更改。")
        }
        var candidate = value
        candidate.revision = manifest.revision + 1
        candidate.updatedAt = Date()
        try ProjectFiles.validate(candidate)
        try ProjectFiles.writeManifest(candidate, in: rootFD, replacing: true)
        manifest = candidate
    }
}

private enum ProjectFiles {
    static func error() -> ProjectStoreError { .io(String(cString: strerror(errno))) }

    static func projectURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), url.pathExtension.lowercased() == "dproject",
              url.standardizedFileURL.path == url.path else { throw ProjectStoreError.unsafePath(url.path) }
        _ = try components(String(url.path.dropFirst()))
        return url.standardizedFileURL
    }

    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw ProjectStoreError.unsafePath(path)
        }
        return parts
    }

    /// Walk every component using directory descriptors; a renamed/symlinked ancestor cannot
    /// redirect a write outside the project between a path check and the actual operation.
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ProjectStoreError.unsafePath(url.path) }
        // A security-scoped grant covers the selected project, not directory listings of
        // every ancestor. O_SEARCH permits anchored traversal without requesting
        // those unrelated listings, while O_NOFOLLOW still rejects every symlink.
        let descriptor = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw error() }
        if url.path == "/" { return descriptor }
        do {
            let result = try descend(try components(String(url.path.dropFirst())), from: descriptor, leafFlags: O_SEARCH)
            Darwin.close(descriptor)
            return result
        } catch { Darwin.close(descriptor); throw error }
    }

    static func descend(_ parts: [String], from parent: Int32, leafFlags: Int32 = O_RDONLY) throws -> Int32 {
        var current = dup(parent)
        guard current >= 0 else { throw error() }
        for (index, part) in parts.enumerated() {
            let access = index == parts.count - 1 ? leafFlags : O_SEARCH
            let next = openat(current, part, access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(current)
            guard next >= 0 else {
                if failure == ELOOP || failure == ENOTDIR { throw ProjectStoreError.unsafePath(part) }
                throw ProjectStoreError.io("\(part)：\(String(cString: strerror(failure)))")
            }
            current = next
        }
        return current
    }

    static func openRelativeDirectory(_ relative: String, in root: Int32) throws -> Int32 {
        try descend(components(relative), from: root)
    }

    static func openRelativeFile(_ relative: String, in root: Int32) throws -> Int32 {
        var parts = try components(relative)
        let filename = parts.removeLast()
        let parent = try descend(parts, from: root)
        defer { Darwin.close(parent) }
        let descriptor = openat(parent, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw error() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw ProjectStoreError.unsafePath(relative)
        }
        return descriptor
    }

    static func read(relative: String, in root: Int32, limit: Int) throws -> Data {
        let descriptor = try openRelativeFile(relative, in: root)
        defer { Darwin.close(descriptor) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw error()
            }
            guard result.count <= limit - count else { throw ProjectStoreError.invalidProject("文件超过当前工作台的安全读取上限。") }
            result.append(contentsOf: buffer[..<count])
        }
    }

    static func lock(in root: Int32) throws -> Int32 {
        let descriptor = openat(root, ".project.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw error() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw ProjectStoreError.unsafePath(".project.lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ProjectStoreError.io("此项目已被另一窗口或应用实例打开")
        }
        return descriptor
    }

    static func writeManifest(_ manifest: ProjectManifest, in root: Int32, replacing: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= 32 * 1_024 * 1_024 else {
            throw ProjectStoreError.invalidProject("项目清单超过当前工作台的 32 MiB 上限，请新建项目；本次更改尚未写入。")
        }
        try publish(in: root, name: ProjectStore.manifestFilename, replacing: replacing) { descriptor in
            try data.withUnsafeBytes { try writeAll($0, to: descriptor) }
        }
    }

    static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw error() }
            offset += count
        }
    }

    static func publish(in parent: Int32, name: String, replacing: Bool, write: (Int32) throws -> Void) throws {
        let temporary = ".d-\(UUID().uuidString).partial"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw error() }
        defer { Darwin.close(descriptor); unlinkat(parent, temporary, 0) }
        try write(descriptor)
        guard fsync(descriptor) == 0 else { throw error() }
        if replacing {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw ProjectStoreError.unsafePath(name) }
            guard renameat(parent, temporary, parent, name) == 0 else { throw error() }
        } else {
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw ProjectStoreError.alreadyExists(name) }
                throw error()
            }
        }
        guard fsync(parent) == 0 else { throw error() }
    }

    static func taskOwner(_ name: String) -> UUID? {
        guard name.count == 73 else { return nil }
        let separator = name.index(name.startIndex, offsetBy: 36)
        guard name[separator] == "-", UUID(uuidString: String(name[name.index(after: separator)...])) != nil else { return nil }
        return UUID(uuidString: String(name[..<separator]))
    }

    static func relativeArtifact(_ url: URL, root: URL, jobID: UUID) throws -> String {
        let prefix = root.path + "/"
        guard url.isFileURL, url.path.hasPrefix(prefix), url.standardizedFileURL.path == url.path else {
            throw ProjectStoreError.unsafePath(url.path)
        }
        let relative = String(url.path.dropFirst(prefix.count))
        let parts = try components(relative)
        guard parts.count == 3, parts[0] == "Tasks", taskOwner(parts[1]) == jobID, parts[2] == "image.png" else {
            throw ProjectStoreError.unsafePath(relative)
        }
        return relative
    }

    static func directoryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw error() }
        guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw error() }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw error() }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }

    static func validate(_ value: ProjectManifest) throws {
        guard value.schemaVersion == ProjectManifest.currentSchemaVersion else { throw ProjectStoreError.unsupportedSchema(value.schemaVersion) }
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(value.jobs.map(\.id)).count == value.jobs.count,
              Set(value.assets.map(\.id)).count == value.assets.count,
              Set(value.assets.map(\.relativePath)).count == value.assets.count else {
            throw ProjectStoreError.invalidProject("项目名称为空或包含重复的任务、作品编号。")
        }
        let jobs = Dictionary(uniqueKeysWithValues: value.jobs.map { ($0.id, $0) })
        let assets = Dictionary(uniqueKeysWithValues: value.assets.map { ($0.id, $0) })
        for job in value.jobs {
            guard job.id == job.request.id, Set(job.artifactIDs).count == job.artifactIDs.count,
                  job.artifactIDs.allSatisfy({ assets[$0]?.jobID == job.id }),
                  job.state != .completed || !job.artifactIDs.isEmpty else {
                throw ProjectStoreError.invalidProject("任务与作品的对应关系已损坏。")
            }
            try job.request.validate()
        }
        for asset in value.assets {
            _ = try components(asset.relativePath)
            if let jobID = asset.jobID {
                guard let job = jobs[jobID], job.artifactIDs.contains(asset.id) else {
                    throw ProjectStoreError.invalidProject("作品缺少对应的任务记录。")
                }
            }
            if asset.role == .result {
                let parts = try components(asset.relativePath)
                guard asset.jobID != nil, parts.count == 3, parts[0] == "Tasks", taskOwner(parts[1]) == asset.jobID,
                      parts[2] == "image.png", asset.mediaType == "image/png" else {
                    throw ProjectStoreError.unsafePath(asset.relativePath)
                }
            }
            for dimension in [asset.metadata.width, asset.metadata.height, asset.metadata.bitDepth].compactMap({ $0 }) {
                guard dimension > 0 else { throw ProjectStoreError.invalidProject("媒体元数据包含无效尺寸或位深。") }
            }
        }
    }
}
