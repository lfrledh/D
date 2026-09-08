import DInference
import Darwin
import Foundation
import ImageIO
import zlib

/// Internal fault injection points exercise actual durable migration boundaries in CPU tests.
enum ProjectMigrationCheckpoint: Sendable { case backupDurable, beforePublication, publicationDurable }
enum ProjectExportCheckpoint: Sendable { case contentDurable(URL), published(URL) }

/// Owns durable project records and media. Its actor keeps file I/O off the UI executor.
/// The lock prevents two application sessions from silently replacing each other's manifest.
public actor ProjectStore {
    public nonisolated let rootURL: URL
    public nonisolated var artifactDirectory: URL { rootURL.appendingPathComponent("Tasks", isDirectory: true) }
    public static let manifestFilename = "project.json"
    public static let versionOneBackupFilename = "project.v1.backup.json"
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
        try await open(at: url, migrationCheckpoint: nil)
    }

    static func open(at url: URL, migrationCheckpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) async throws -> ProjectStore {
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
        guard header.schemaVersion == 1 || header.schemaVersion == ProjectManifest.currentSchemaVersion else {
            throw ProjectStoreError.unsupportedSchema(header.schemaVersion)
        }
        var loaded: ProjectManifest
        do { loaded = try decoder.decode(ProjectManifest.self, from: data) }
        catch { throw ProjectStoreError.invalidProject("项目清单缺少必要字段或已经损坏。") }
        let tasks = try ProjectFiles.openRelativeDirectory("Tasks", in: descriptor)
        Darwin.close(tasks)
        if loaded.schemaVersion == 1 {
            loaded = try ProjectFiles.migrateVersionOne(loaded, original: data, in: descriptor,
                                                      checkpoint: migrationCheckpoint)
        } else { try ProjectFiles.validate(loaded) }
        let store = ProjectStore(rootURL: root, rootFD: descriptor, lockFD: lock, manifest: loaded)
        // Ownership of both descriptors has moved to the actor before recovery can throw.
        transferred = true
        return try await store.recoverOnOpen()
    }

    public func snapshot() -> ProjectManifest { manifest }

    public func saveDraft(_ draft: ProjectDraft, documentID: UUID? = nil) throws -> ProjectManifest {
        let index = try documentIndex(documentID ?? manifest.activeDocumentID)
        guard manifest.documents[index].draft != draft else { return manifest }
        var candidate = manifest
        candidate.documents[index].draft = draft
        try commit(candidate)
        return manifest
    }

    public func createDocument(name: String, draft: ProjectDraft = .init(), sourceAssetID: UUID? = nil) throws -> ProjectManifest {
        try checkLocation()
        if let sourceAssetID, !manifest.assets.contains(where: { $0.id == sourceAssetID }) {
            throw ProjectStoreError.missingAsset
        }
        let document = ProjectDocument(name: name, draft: draft, sourceAssetID: sourceAssetID,
                                       selectedAssetID: sourceAssetID)
        var candidate = manifest
        candidate.documents.append(document)
        candidate.activeDocumentID = document.id
        try commit(candidate)
        return manifest
    }

    public func selectDocument(id: UUID) throws -> ProjectManifest {
        _ = try documentIndex(id)
        guard manifest.activeDocumentID != id else { return manifest }
        var candidate = manifest
        candidate.activeDocumentID = id
        try commit(candidate)
        return manifest
    }

    public func renameDocument(id: UUID, name: String) throws -> ProjectManifest {
        let index = try documentIndex(id)
        guard manifest.documents[index].name != name else { return manifest }
        var candidate = manifest
        candidate.documents[index].name = name
        try commit(candidate)
        return manifest
    }

    public func setSelectedAsset(_ id: UUID?, documentID: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard manifest.documents[index].selectedAssetID != id else { return manifest }
        var candidate = manifest
        candidate.documents[index].selectedAssetID = id
        try commit(candidate)
        return manifest
    }

    /// Adoption is an explicit creative choice. Generating, selecting, favoriting or recovering
    /// a candidate never silently replaces the document's adopted result.
    public func adoptAsset(id: UUID?, documentID: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard manifest.documents[index].adoptedAssetID != id else { return manifest }
        var candidate = manifest
        candidate.documents[index].adoptedAssetID = id
        try commit(candidate)
        return manifest
    }

    public func updateAsset(id: UUID, name: String? = nil, note: String? = nil, isFavorite: Bool? = nil) throws -> ProjectManifest {
        try checkLocation()
        guard let index = manifest.assets.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingAsset }
        var candidate = manifest
        if let name { candidate.assets[index].name = name }
        if let note { candidate.assets[index].note = note }
        if let isFavorite { candidate.assets[index].isFavorite = isFavorite }
        if candidate != manifest { try commit(candidate) }
        return manifest
    }

    private func documentIndex(_ id: UUID) throws -> Int {
        guard !isClosed else { throw ProjectStoreError.io("项目会话已关闭，请重新打开项目") }
        guard let index = manifest.documents.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingDocument }
        return index
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

    public func enqueue(request: InferenceRequest, documentID: UUID? = nil) throws -> ProjectManifest {
        try request.validate()
        let index = try documentIndex(documentID ?? manifest.activeDocumentID)
        guard !manifest.jobs.contains(where: { $0.id == request.id }) else {
            throw ProjectStoreError.invalidProject("任务编号重复。")
        }
        var candidate = manifest
        candidate.jobs.append(ProjectJob(id: request.id, documentID: manifest.documents[index].id, request: request))
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
            let asset = ProjectAsset(jobID: id, relativePath: relative, metadata: metadata,
                                     name: "候选 \(candidate.assets.count + 1)")
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

    /// Export is a byte-for-byte copy staged in the system's same-volume replacement
    /// directory. A Save panel grants the destination file, not permission to create siblings.
    /// RENAME_EXCL publishes atomically without replacing a destination that appeared meanwhile.
    public func export(assetID: UUID, to destination: URL) throws {
        try export(assetID: assetID, to: destination, checkpoint: nil)
    }

    func export(assetID: UUID, to destination: URL,
                checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?) throws {
        guard let asset = manifest.assets.first(where: { $0.id == assetID }) else { throw ProjectStoreError.missingAsset }
        try checkLocation()
        guard destination.isFileURL, destination.path.hasPrefix("/"),
              !destination.lastPathComponent.isEmpty else { throw ProjectStoreError.unsafePath(destination.path) }
        let source = try ProjectFiles.openRelativeFile(asset.relativePath, in: rootFD)
        defer { Darwin.close(source) }
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: checkpoint) { target in
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

    /// Capture a persisted run, never the current parameter panel. This version identifies
    /// the new export snapshot; schema2 did not record historical asset versions.
    public func prepareRecipePNG(assetID: UUID, disclosure: RecipeDisclosure) throws -> Data {
        try checkLocation()
        try verifyUnchangedManifest()
        guard let asset = manifest.assets.first(where: { $0.id == assetID }),
              let job = manifest.jobs.first(where: { $0.id == asset.jobID }),
              job.state == .completed, job.artifactIDs.contains(asset.id),
              case .image(let input) = job.request.input else { throw ProjectStoreError.missingAsset }
        let png = try ProjectFiles.read(relative: asset.relativePath, in: rootFD, limit: 32 * 1024 * 1024)
        _ = try Self.validateRecipePNG(png)
        func field(_ value: String?) -> RecipeField<String> {
            guard let value, !value.isEmpty, value != "unrecorded" else { return .unknown }
            return .value(value)
        }
        let recipe = GenerationRecipe(assetID: asset.id, assetVersion: UUID(), runID: job.id,
            modelSource: field(job.resultMetadata["modelRepository"]),
            modelRevision: field(job.resultMetadata["modelRevision"] ?? job.request.model.revision),
            weightsManifestSHA256: .unknown, prompt: .value(input.prompt), structuredInputRevision: .notApplicable,
            seed: .value(String(input.seed)), steps: .value(input.steps), guidance: .value(Double(input.guidanceScale)),
            width: .value(input.width), height: .value(input.height), scheduler: .unknown,
            computePrecision: .unknown, quantization: .unknown, implementationVersion: .unknown,
            mediaPayloadSHA256: .unknown, parents: [], claim: .callerDeclared)
        return try PNGRecipeCodec.embedding(recipe, in: png, disclosure: disclosure)
    }

    /// Open only the explicitly selected regular file, with the same no-follow walk as projects.
    public static func readRecipePNG(at url: URL) throws -> (Data, PNGRecipeInspection) {
        guard url.isFileURL else { throw ProjectStoreError.unsafePath(url.path) }
        let parent = try ProjectFiles.openDirectory(url.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let data = try ProjectFiles.read(relative: url.lastPathComponent, in: parent, limit: 32 * 1024 * 1024)
        return (data, try validateRecipePNG(data))
    }

    public static func publishRecipePNG(_ data: Data, to destination: URL) throws {
        try publishRecipePNG(data, to: destination, checkpoint: nil)
    }

    static func publishRecipePNG(_ data: Data, to destination: URL,
                                 checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?) throws {
        let inspection = try validateRecipePNG(data)
        guard inspection.recipe != nil else { throw PNGRecipeError.invalidRecipe }
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.lastPathComponent.isEmpty else {
            throw ProjectStoreError.unsafePath(destination.path)
        }
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: checkpoint) { target in
            try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: target) }
        }
    }

    /// Source metadata is displayed separately. Only editable prompt/seed enter a NEW draft.
    public func createRecipeDocument(_ recipe: GenerationRecipe) throws -> ProjectManifest {
        _ = try GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive)
        guard case .value(let prompt) = recipe.prompt else { throw PNGRecipeError.invalidRecipe }
        let seed: String?
        if case .value(let value) = recipe.seed { seed = value } else { seed = nil }
        return try createDocument(name: "来自 PNG 配方", draft: .init(prompt: prompt, randomSeed: seed == nil, seedText: seed ?? "0"))
    }

    private static func validateRecipePNG(_ data: Data) throws -> PNGRecipeInspection {
        let inspection = try PNGRecipeCodec.inspect(data)
        // Decode bounded pixels without sending compressed profiles, EXIF or arbitrary text
        // to ImageIO. Original chunks remain byte-exact in the actual exported data.
        let bytes = [UInt8](data)
        var pixels = Data(bytes.prefix(8)); var compressed = Data(); var header: [UInt8] = []; var offset = 8
        while offset < bytes.count {
            let length = bytes[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            let type = String(bytes: bytes[offset+4..<offset+8], encoding: .ascii)!
            let end = offset + 12 + length
            if type == "IHDR" { header = Array(bytes[offset+8..<end-4]) }
            if type == "IDAT" { compressed.append(contentsOf: bytes[offset+8..<end-4]) }
            if ["IHDR", "PLTE", "IDAT", "IEND", "tRNS"].contains(type) { pixels.append(contentsOf: bytes[offset..<end]) }
            offset = end
        }
        try verifyPNGScanlines(compressed, header: header)
        guard let source = CGImageSourceCreateWithData(pixels as CFData, nil),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == inspection.width, image.height == inspection.height else {
            throw ProjectStoreError.invalidImage("PNG")
        }
        return inspection
    }

    /// ImageIO can repair invalid zlib streams. Require exact filtered scanline bytes first,
    /// with a 64KiB output window, declared pixel budget and no compressed metadata parsing.
    private static func verifyPNGScanlines(_ compressed: Data, header: [UInt8]) throws {
        let width = header[0..<4].reduce(0) { $0 << 8 | Int($1) }
        let height = header[4..<8].reduce(0) { $0 << 8 | Int($1) }
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][Int(header[9])]!
        let bits = channels * Int(header[8])
        let passes: [(Int, Int, Int, Int)] = header[12] == 0
            ? [(0, 0, 1, 1)]
            : [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        var rowStarts = Set<Int>(); var expected = 0
        for (x, y, dx, dy) in passes where width > x && height > y {
            let columns = (width - x + dx - 1) / dx
            let rows = (height - y + dy - 1) / dy
            let rowBytes = (columns * bits + 7) / 8 + 1
            for _ in 0..<rows { rowStarts.insert(expected); expected += rowBytes }
        }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ProjectStoreError.invalidImage("PNG 压缩流")
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 64 * 1024)
        try compressed.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            var produced = 0
            while true {
                let previousIn = stream.avail_in
                let status: Int32 = output.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = output.count - Int(stream.avail_out)
                guard produced + count <= expected else { throw ProjectStoreError.invalidImage("PNG 像素数据超长") }
                for offset in 0..<count where rowStarts.contains(produced + offset) {
                    guard output[offset] <= 4 else { throw ProjectStoreError.invalidImage("PNG 滤波数据") }
                }
                produced += count
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, produced == expected else { throw ProjectStoreError.invalidImage("PNG 压缩流长度") }
                    break
                }
                guard status == Z_OK, count > 0 || stream.avail_in < previousIn else { throw ProjectStoreError.invalidImage("PNG 压缩流损坏") }
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
                let asset = ProjectAsset(jobID: jobID, relativePath: relative, metadata: metadata,
                                         name: "候选 \(candidate.assets.count + 1)")
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

    /// Back up the exact v1 bytes durably before publishing v2. The backup is immutable;
    /// its equality to the still-current v1 manifest is the restart marker. A crash before
    /// publication leaves a readable v1 project, and a crash afterwards leaves valid v2.
    static func migrateVersionOne(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                  checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        var migrated = legacy
        migrated.schemaVersion = ProjectManifest.currentSchemaVersion
        guard migrated.revision < UInt64.max else {
            throw ProjectStoreError.invalidProject("项目修订编号已经达到上限，无法安全升级。")
        }
        migrated.revision += 1
        migrated.updatedAt = Date()
        try validate(migrated)
        let backup = ProjectStore.versionOneBackupFilename
        var info = stat()
        if fstatat(root, backup, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard try read(relative: backup, in: root, limit: 32 * 1_024 * 1_024) == original else {
                throw ProjectStoreError.invalidProject("已有的 v1 备份与当前项目不同，已保留两者；请检查后再升级。")
            }
        } else {
            guard errno == ENOENT else { throw error() }
            try publish(in: root, name: backup, replacing: false) { descriptor in
                try original.withUnsafeBytes { try writeAll($0, to: descriptor) }
            }
        }
        try checkpoint?(.backupDurable)
        guard try read(relative: ProjectStore.manifestFilename, in: root, limit: 32 * 1_024 * 1_024) == original else {
            throw ProjectStoreError.externalModification
        }
        try checkpoint?(.beforePublication)
        try writeManifest(migrated, in: root, replacing: true)
        try checkpoint?(.publicationDurable)
        return migrated
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

    static func publishExport(to destination: URL, parent: Int32,
                              checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?,
                              write: (Int32) throws -> Void) throws {
        _ = try components(destination.lastPathComponent)
        // Apple documents this API for atomic safe-save on the destination's volume:
        // https://developer.apple.com/documentation/foundation/filemanager/url(for:in:appropriatefor:create:)
        let temporary = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: destination, create: true)
        // Only the OS-created temporary directory is canonicalized. User-selected destination
        // components still go through the unchanged O_NOFOLLOW descriptor walk above.
        guard let resolved = realpath(temporary.path, nil) else { throw error() }
        defer { free(resolved) }
        let location = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let directory = try openDirectory(location)
        defer { Darwin.close(directory) }
        var temporaryInfo = stat(), destinationInfo = stat()
        guard fstat(directory, &temporaryInfo) == 0, fstat(parent, &destinationInfo) == 0 else { throw error() }
        defer {
            // Remove only this operation's empty directory, never recursively delete content
            // whose ownership is unknown. The temporary filename is handled by its own defer.
            if let owner = try? openDirectory(location.deletingLastPathComponent()) {
                var current = stat()
                if fstatat(owner, location.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == temporaryInfo.st_dev, current.st_ino == temporaryInfo.st_ino {
                    _ = unlinkat(owner, location.lastPathComponent, AT_REMOVEDIR)
                }
                Darwin.close(owner)
            }
        }
        guard temporaryInfo.st_dev == destinationInfo.st_dev else {
            throw ProjectStoreError.io("系统未能提供与导出目标同卷的临时位置，无法安全完成原子导出")
        }
        let name = "export-\(UUID().uuidString).partial"
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw error() }
        defer { Darwin.close(descriptor); _ = unlinkat(directory, name, 0) }
        try write(descriptor)
        guard fsync(descriptor) == 0 else { throw error() }
        try checkpoint?(.contentDurable(location.appendingPathComponent(name)))
        guard renameatx_np(directory, name, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ProjectStoreError.alreadyExists(destination.path) }
            throw error()
        }
        try checkpoint?(.published(destination))
        // After publication no failure path deletes the delivered file. In particular, a
        // disconnected volume during directory synchronization must not trigger a rollback.
        guard fsync(parent) == 0 else {
            throw ProjectStoreError.io("导出文件已发布并保留，但无法确认目标目录已同步：\(String(cString: strerror(errno)))")
        }
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
              !value.documents.isEmpty,
              Set(value.documents.map(\.id)).count == value.documents.count,
              value.documents.contains(where: { $0.id == value.activeDocumentID }),
              Set(value.jobs.map(\.id)).count == value.jobs.count,
              Set(value.assets.map(\.id)).count == value.assets.count,
              Set(value.assets.map(\.relativePath)).count == value.assets.count else {
            throw ProjectStoreError.invalidProject("项目名称为空，文档选择无效，或包含重复的文档、任务、作品编号。")
        }
        let documents = Set(value.documents.map(\.id))
        let jobs = Dictionary(uniqueKeysWithValues: value.jobs.map { ($0.id, $0) })
        let assets = Dictionary(uniqueKeysWithValues: value.assets.map { ($0.id, $0) })
        for job in value.jobs {
            guard documents.contains(job.documentID), job.id == job.request.id,
                  Set(job.artifactIDs).count == job.artifactIDs.count,
                  job.artifactIDs.allSatisfy({ assets[$0]?.jobID == job.id }),
                  job.state != .completed || !job.artifactIDs.isEmpty else {
                throw ProjectStoreError.invalidProject("任务与作品的对应关系已损坏。")
            }
            try job.request.validate()
        }
        for asset in value.assets {
            guard !asset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectStoreError.invalidProject("作品名称不能为空。")
            }
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
        for document in value.documents {
            guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectStoreError.invalidProject("探索文档名称不能为空。")
            }
            if let source = document.sourceAssetID, assets[source] == nil {
                throw ProjectStoreError.invalidProject("探索文档引用的来源作品不存在。")
            }
            func isCandidate(_ id: UUID) -> Bool {
                guard let asset = assets[id], asset.role == .result, let jobID = asset.jobID else { return false }
                return jobs[jobID]?.documentID == document.id
            }
            if let adopted = document.adoptedAssetID, !isCandidate(adopted) {
                throw ProjectStoreError.invalidProject("采用的作品不属于该探索文档。")
            }
            if let selected = document.selectedAssetID,
               !(isCandidate(selected) || selected == document.sourceAssetID) {
                throw ProjectStoreError.invalidProject("选中的作品不属于该探索文档或其来源。")
            }
        }
    }
}
