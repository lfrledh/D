import CryptoKit
import Darwin
import DInference
import Foundation

public actor ModelLibrary {
    private struct FileProgress: Codable, Sendable {
        var completed: UInt64
        var identity: ModelFileIdentity
    }
    private struct StoredRecord: Codable, Sendable {
        var record: ModelRecord
        var bookmark: Data?
        var files: [String: FileProgress] = [:]
        var verifiedFiles: [String: ModelFileIdentity] = [:]
        var verifiedRoot: ModelFileIdentity?
        var publicationRoot: ModelFileIdentity?
    }
    private struct DiskState: Codable {
        var schemaVersion = 1
        var libraryID = UUID()
        var revision: UInt64 = 0
        var rootBookmark: Data?
        var rootURL: URL?
        var rootIdentity: ModelFileIdentity?
        var records: [StoredRecord] = []
    }
    private let stateDirectory: ModelDirectory
    private let stateLock: ModelFileHandle
    private let catalog: [ModelCatalogEntry]
    private let transport: any ModelRangeTransport
    private let sourceBaseURL: URL?
    private let availableBytesOverride: UInt64?
    private var disk: DiskState
    private var rootScope: ModelScopedLocation?
    private var libraryRoot: ModelDirectory?
    private var libraryLock: ModelFileHandle?
    private var externalScopes: [ModelID: ModelScopedLocation] = [:]
    private var workers: [ModelID: Task<Void, Never>] = [:]
    private var leases: [UUID: ModelUsageLease] = [:]
    private var accepting = true
    private var cancelledOperations: Set<ModelID> = []
    private static let chunkBytes: UInt64 = 16 * 1024 * 1024

    public init(stateDirectory: URL) async throws {
        try await self.init(stateDirectory: stateDirectory, catalog: ModelCatalog.entries())
    }

    /// Internal seams use tiny deterministic catalogs and loopback HTTP; production is fixed and HTTPS-only.
    init(stateDirectory: URL, catalog: [ModelCatalogEntry],
         transport: any ModelRangeTransport = URLSessionModelRangeTransport(), sourceBaseURL: URL? = nil, availableBytesOverride: UInt64? = nil) async throws {
        try Self.validateCatalog(catalog)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let directory = try ModelDirectory(ModelDirectory.canonicalURL(stateDirectory))
        self.stateDirectory = directory
        stateLock = try Self.lock(in: directory, path: "model-library.lock")
        self.catalog = catalog; self.transport = transport; self.sourceBaseURL = sourceBaseURL
        self.availableBytesOverride = availableBytesOverride
        if try Self.exists("index.json", in: directory) {
            disk = try JSONDecoder().decode(DiskState.self, from: directory.read("index.json", maximum: 32 * 1024 * 1024))
            guard disk.schemaVersion == 1, Set(disk.records.map(\.record.id)).count == disk.records.count else {
                throw ModelLibraryError.integrity("模型库索引版本无效或记录重复，原文件已保留。")
            }
        } else { disk = DiskState() }
        for index in disk.records.indices {
            let value = disk.records[index]
            guard let entry = catalog.first(where: { $0.id == value.record.catalogID }), entry.revision == value.record.revision,
                  value.files.allSatisfy({ path, progress in entry.files.contains { $0.path == path && progress.completed <= $0.size } }) else {
                throw ModelLibraryError.integrity("模型索引与固定目录不一致。")
            }
            disk.records[index].record.activeLeaseCount = 0
            if [.queued, .downloading, .pausing, .verifying, .publishing].contains(value.record.state) {
                disk.records[index].record.state = .paused
                disk.records[index].record.error = "上次操作中断；请点击继续，不会自动恢复下载。"
            }
        }
        if let bookmark = disk.rootBookmark {
            do {
                let scope = try ModelScopedLocation.restore(bookmark)
                try attachRoot(scope, create: false)
            } catch { libraryRoot = nil; rootScope = nil }
        }
        for value in disk.records where value.record.storage == .external {
            if let bookmark = value.bookmark {
                do { externalScopes[value.record.id] = try ModelScopedLocation.restore(bookmark) }
                catch { }
            }
        }
        try persist()
    }

    public func snapshot() -> ModelLibrarySnapshot {
        for index in disk.records.indices {
            let stored = disk.records[index]
            var availability = stored.record.availability
            var location = stored.record.directory
            if stored.record.state == .installed {
                do { location = try resolved(stored).url; availability = .available }
                catch { availability = stored.record.storage == .external && externalScopes[stored.record.id] == nil ? .needsAuthorization : .unavailable }
            } else if stored.record.storage == .managed {
                do {
                    guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库不可用。") }
                    try root.validateLocation(); availability = .available
                } catch { availability = .unavailable }
            } else if let scope = externalScopes[stored.record.id] {
                do { _ = try ModelDirectory(scope.url); availability = .available }
                catch { availability = .unavailable }
            } else { availability = .needsAuthorization }
            if availability != stored.record.availability || location != stored.record.directory {
                disk.records[index].record.availability = availability
                disk.records[index].record.directory = location
                disk.revision &+= 1
            }
        }
        let records = disk.records.map { stored -> ModelRecord in
            var record = stored.record
            record.activeLeaseCount = leases.values.filter { $0.modelID == record.id }.count
            return record
        }
        return .init(revision: disk.revision, rootURL: rootScope?.url ?? disk.rootURL, catalog: catalog, records: records)
    }

    public func configureRoot(at selected: URL) throws {
        try requireAdmission()
        guard workers.isEmpty, leases.isEmpty else { throw ModelLibraryError.busy("模型正在下载、校验或用于任务；请等待结束后更换模型库位置。") }
        let scope = try ModelScopedLocation(selected)
        let hasManaged = disk.records.contains { $0.record.storage == .managed }
        let candidate = try ModelDirectory(scope.url)
        if hasManaged, !(try Self.exists(".d-model-library/owner.json", in: candidate)) {
            throw ModelLibraryError.busy("已有受管理模型。当前仅支持原模型库在同一磁盘卷内移动；请选择包含原模型库的位置，不会接管跨卷复制的内容。")
        }
        let previousDisk = disk, previousRoot = libraryRoot, previousScope = rootScope, previousLock = libraryLock
        do { try attachRoot(scope, create: !hasManaged); try persist() }
        catch {
            disk = previousDisk; libraryRoot = previousRoot; rootScope = previousScope; libraryLock = previousLock
            throw error
        }
    }

    public func install(catalogID: String = ModelCatalog.flux2ID) throws -> ModelID {
        try requireAdmission()
        let entry = try catalogEntry(catalogID)
        if let existing = disk.records.first(where: { $0.record.catalogID == catalogID && $0.record.storage == .managed }) {
            if existing.record.state != .installed { try resume(existing.record.id) }
            return existing.record.id
        }
        try requireIdleWorker()
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("请先选择模型库所在的本地磁盘。") }
        try root.validateLocation()
        try requireSpace(entry.totalBytes)
        let id = ModelID()
        disk.records.append(StoredRecord(record: .init(id: id, catalogID: entry.id, revision: entry.revision,
            storage: .managed, state: .queued, availability: .available, downloadedBytes: 0,
            totalBytes: entry.totalBytes, error: nil, directory: nil, activeLeaseCount: 0)))
        do { try persist() } catch { disk.records.removeAll { $0.record.id == id }; throw error }
        launchInstallation(id)
        return id
    }

    public func pause(_ id: ModelID) async throws {
        try requireAdmission()
        guard let worker = workers[id] else { return }
        setState(id, .pausing)
        worker.cancel()
        var persistenceFailure: (any Error)?
        do { try persist() } catch { persistenceFailure = error }
        await worker.value
        if let persistenceFailure { throw persistenceFailure }
    }
    public func resume(_ id: ModelID) throws {
        try requireAdmission(); try requireIdleWorker()
        let value = try stored(id)
        guard value.record.state != .installed else { return }
        if value.record.storage == .external {
            guard let scope = externalScopes[id] else { throw ModelLibraryError.unavailable("请重新授权模型文件夹。") }
            launchVerification(id, scope: scope)
        } else {
            guard libraryRoot != nil else { throw ModelLibraryError.unavailable("模型库磁盘不可用，请重新定位。") }
            setState(id, .queued); try persist(); launchInstallation(id)
        }
    }
    public func retry(_ id: ModelID) throws { try resume(id) }

    public func restart(_ id: ModelID) async throws {
        try requireAdmission()
        guard !leases.values.contains(where: { $0.modelID == id }) else { throw ModelLibraryError.busy("该模型仍用于任务，不能重新安装。") }
        if workers[id] != nil { try await pause(id) }
        try requireIdleWorker()
        let value = try stored(id)
        guard value.record.storage == .managed, value.record.state != .installed else {
            throw ModelLibraryError.busy("仅未完成的受管理安装可以重新开始。")
        }
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库不可用。") }
        guard !(try Self.exists("Installations/" + id.description, in: root)) else {
            throw ModelLibraryError.busy("该安装已有发布目录，请继续完整校验或处理移除错误；不会重新下载并遗忘原目录。")
        }
        let content = try stagingContent(id, create: true)
        let actual = try content.entries(expectedPaths: Set(try entry(for: id).files.map(\.path)))
        for (path, identity) in actual {
            guard value.files[path]?.identity.sameNode(identity) == true else {
                throw ModelLibraryError.unsafePath("暂存目录包含未知文件，未清理；请检查该模型的暂存目录。")
            }
        }
        try content.removeKnownFiles(actual)
        mutate(id) { $0.files = [:]; $0.record.downloadedBytes = 0; $0.publicationRoot = nil }
        try persist(); try resume(id)
    }

    public func registerExisting(at selected: URL, catalogID: String = ModelCatalog.flux2ID) async throws -> ModelID {
        try requireAdmission(); try requireIdleWorker()
        let entry = try catalogEntry(catalogID)
        let scope = try ModelScopedLocation(selected)
        let directory = try ModelDirectory(scope.url)
        if let existing = disk.records.first(where: { $0.record.catalogID == catalogID && $0.verifiedRoot?.sameNode(directory.identity) == true }) {
            _ = try resolve(existing.record.id)
            return existing.record.id
        }
        let id = ModelID()
        disk.records.append(StoredRecord(record: .init(id: id, catalogID: catalogID, revision: entry.revision,
            storage: .external, state: .registered, availability: .available, downloadedBytes: 0,
            totalBytes: entry.totalBytes, error: nil, directory: scope.url, activeLeaseCount: 0), bookmark: scope.bookmark))
        externalScopes[id] = scope
        do { try persist() } catch { disk.records.removeAll { $0.record.id == id }; externalScopes[id] = nil; throw error }
        launchVerification(id, scope: scope)
        await workers[id]?.value
        let completed = try stored(id)
        if cancelledOperations.contains(id) { throw ModelLibraryError.operationPaused }
        guard completed.record.state == .installed else {
            throw ModelLibraryError.integrity(completed.record.error ?? "模型校验未完成。")
        }
        return id
    }

    public func rebind(_ id: ModelID, to selected: URL) async throws {
        try requireAdmission(); try requireIdleWorker()
        guard !leases.values.contains(where: { $0.modelID == id }) else { throw ModelLibraryError.busy("模型仍用于运行或排队任务，不能重新定位。") }
        let previous = try stored(id)
        guard previous.record.storage == .external else {
            throw ModelLibraryError.busy("受管理模型请通过更换模型库位置来重新定位整个模型库。")
        }
        let candidate = try ModelScopedLocation(selected)
        let previousScope = externalScopes[id]
        cancelledOperations.remove(id)
        setState(id, .verifying)
        do { try persist() } catch { mutate(id) { $0 = previous }; throw error }
        workers[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await self.entry(for: id).files
                let directory = try ModelDirectory(candidate.url)
                let job = Task.detached { try directory.verify(files) }
                let verified = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                try Task.checkCancellation()
                await self.commitRebinding(id, scope: candidate, directory: directory, files: verified, previous: previous, previousScope: previousScope)
            } catch { await self.rollbackRebinding(id, previous: previous, scope: previousScope, error: error) }
        }
        await workers[id]?.value
        if cancelledOperations.contains(id) { throw ModelLibraryError.operationPaused }
        guard try stored(id).record.error == nil else {
            throw ModelLibraryError.integrity(try stored(id).record.error ?? "重新定位未完成。")
        }
    }

    private func commitRebinding(_ id: ModelID, scope: ModelScopedLocation, directory: ModelDirectory,
                                 files: [String: ModelFileIdentity], previous: StoredRecord, previousScope: ModelScopedLocation?) {
        externalScopes[id] = scope
        mutate(id) { $0.bookmark = scope.bookmark }
        verified(id, directory: directory, files: files)
        do { try persist(); workers.removeValue(forKey: id) }
        catch { rollbackRebinding(id, previous: previous, scope: previousScope, error: error) }
    }
    private func rollbackRebinding(_ id: ModelID, previous: StoredRecord, scope: ModelScopedLocation?, error: any Error) {
        if error is CancellationError { cancelledOperations.insert(id) }
        externalScopes[id] = scope
        mutate(id) { $0 = previous; $0.record.error = "新位置校验未完成，已保留原位置：" + error.localizedDescription }
        do { try persist() }
        catch { mutate(id) { $0.record.error = "重新定位失败且状态暂未保存；原位置和文件仍保留。" } }
        workers.removeValue(forKey: id)
    }

    public func profile(for id: ModelID) throws -> ImageModelProfile { try entry(for: id).imageProfile }
    public func resolve(_ id: ModelID) throws -> ModelReference {
        try requireAdmission()
        let value = try stored(id)
        guard value.record.state == .installed else { throw ModelLibraryError.unavailable("模型尚未完成安装和完整校验。") }
        let directory = try resolved(value)
        return .init(directory: directory.url, revision: value.record.revision)
    }
    public func acquire(_ id: ModelID) throws -> ModelUsageLease {
        let reference = try resolve(id)
        let lease = ModelUsageLease(id: UUID(), modelID: id, reference: reference)
        leases[lease.id] = lease; disk.revision &+= 1
        return lease
    }
    public func release(_ lease: ModelUsageLease) {
        guard leases[lease.id]?.modelID == lease.modelID else { return }
        leases.removeValue(forKey: lease.id); disk.revision &+= 1
    }

    public func remove(_ id: ModelID) async throws {
        try requireAdmission(); try requireIdleWorker()
        guard !leases.values.contains(where: { $0.modelID == id }) else { throw ModelLibraryError.busy("该模型仍用于运行或排队任务，不能移除。") }
        let value = try stored(id)
        if value.record.storage == .external {
            let previousRecords = disk.records, previousScope = externalScopes[id]
            disk.records.removeAll { $0.record.id == id }; externalScopes.removeValue(forKey: id)
            do { try persist() } catch { disk.records = previousRecords; externalScopes[id] = previousScope; throw error }
            return
        }
        setState(id, .verifying)
        workers[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performRemoval(id, original: value)
                await self.finishRemoval(id)
            } catch { await self.workerEnded(id, error: error) }
        }
        await workers[id]?.value
        if let failure = disk.records.first(where: { $0.record.id == id }) {
            throw ModelLibraryError.storage(failure.record.error ?? "模型未移除。")
        }
    }

    private func performRemoval(_ id: ModelID, original: StoredRecord) async throws {
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库不可用。") }
        if try Self.exists("Installations/" + id.description, in: root) {
            guard original.verifiedRoot != nil else {
                throw ModelLibraryError.unsafePath("已发布目录尚无完整校验记录，请先恢复校验；未删除或遗忘该目录。")
            }
            let directory = try resolved(original)
            let files = try entry(for: id).files
            let job = Task.detached { try directory.verify(files) }
            let verified = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            try directory.removeKnownFiles(verified)
            let installations = try root.child("Installations")
            guard unlinkat(installations.descriptor, id.description, AT_REMOVEDIR) == 0,
                  fsync(installations.descriptor) == 0 else { throw ModelDirectory.failure("移除空模型安装目录") }
        } else {
            let content = try stagingContent(id, create: true)
            let actual = try content.entries(expectedPaths: Set(try entry(for: id).files.map(\.path)))
            guard actual.allSatisfy({ path, identity in original.files[path]?.identity.sameNode(identity) == true }) else {
                throw ModelLibraryError.unsafePath("暂存目录包含未知或已替换的内容，未删除。")
            }
            try Task.checkCancellation()
            try content.removeKnownFiles(actual)
        }
        // The marker and empty staging directory are owned independently of the published model.
        if try Self.exists("Staging/" + id.description, in: root) {
            let stage = try root.child("Staging/" + id.description)
            if try Self.exists("Content", in: stage) {
                guard unlinkat(stage.descriptor, "Content", AT_REMOVEDIR) == 0 else { throw ModelDirectory.failure("清理空暂存目录") }
            }
            let expected = Data((disk.libraryID.uuidString + "\n" + id.description + "\n" + original.record.revision).utf8)
            guard try stage.read("owner") == expected else { throw ModelLibraryError.unsafePath("暂存目录所有权已改变，已停止清理。") }
            let marker = try stage.fileIdentity("owner")
            try stage.removeKnownFiles(["owner": marker])
            let staging = try root.child("Staging")
            guard unlinkat(staging.descriptor, id.description, AT_REMOVEDIR) == 0,
                  fsync(staging.descriptor) == 0 else { throw ModelDirectory.failure("清理暂存任务") }
        }
    }
    private func finishRemoval(_ id: ModelID) {
        let previous = disk.records
        disk.records.removeAll { $0.record.id == id }
        do { try persist(); workers.removeValue(forKey: id) }
        catch { disk.records = previous; workerEnded(id, error: error) }
    }

    public func shutdown() async throws {
        accepting = false
        do {
            let pending = Array(workers.values)
            for worker in pending { worker.cancel() }
            for worker in pending { await worker.value }
            guard leases.isEmpty else { throw ModelLibraryError.busy("推理任务仍持有模型，请先取消并等待资源释放。") }
            try persist()
            externalScopes = [:]; libraryRoot = nil; libraryLock = nil; rootScope = nil
        } catch {
            accepting = true
            throw error
        }
    }

    private func launchInstallation(_ id: ModelID) {
        cancelledOperations.remove(id)
        workers[id] = Task { [weak self] in
            guard let self else { return }
            do { try await self.performInstallation(id); await self.workerEnded(id, error: nil) }
            catch { await self.workerEnded(id, error: error) }
        }
    }
    private func launchVerification(_ id: ModelID, scope: ModelScopedLocation) {
        cancelledOperations.remove(id)
        setState(id, .verifying)
        workers[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await self.entry(for: id).files
                let directory = try ModelDirectory(scope.url)
                let job = Task.detached { try directory.verify(files) }
                let verified = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                try Task.checkCancellation()
                await self.verified(id, directory: directory, files: verified)
                await self.workerEnded(id, error: nil)
            } catch { await self.workerEnded(id, error: error) }
        }
    }
    private func verified(_ id: ModelID, directory: ModelDirectory, files: [String: ModelFileIdentity]) {
        mutate(id) {
            $0.verifiedRoot = directory.identity; $0.verifiedFiles = files
            $0.record.directory = directory.url; $0.record.downloadedBytes = $0.record.totalBytes
            $0.record.state = .installed; $0.record.error = nil; $0.record.availability = .available
        }
    }
    private func workerEnded(_ id: ModelID, error: (any Error)?) {
        if let error {
            if error is CancellationError { cancelledOperations.insert(id) }
            setState(id, error is CancellationError ? .paused : .failed)
            mutate(id) { $0.record.error = error is CancellationError ? nil : error.localizedDescription }
        }
        do { try persist() }
        catch { setState(id, .failed); mutate(id) { $0.record.error = "状态保存失败：\(error.localizedDescription)。已下载内容仍保留。" } }
        workers.removeValue(forKey: id)
    }

    private func performInstallation(_ id: ModelID) async throws {
        let entry = try entry(for: id)
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库磁盘不可用。") }
        let installations = try root.child("Installations", create: true)
        if try Self.exists(id.description, in: installations) {
            let candidate = try installations.child(id.description)
            guard let expected = try stored(id).publicationRoot, expected.sameNode(candidate.identity) else {
                throw ModelLibraryError.unsafePath("安装位置已有未知内容，未覆盖或删除。")
            }
            setState(id, .verifying)
            let job = Task.detached { try candidate.verify(entry.files) }
            let files = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            verified(id, directory: candidate, files: files)
            return
        }
        let content = try stagingContent(id, create: true)
        let existing = try content.entries(expectedPaths: Set(entry.files.map(\.path)))
        for (path, identity) in existing {
            guard try stored(id).files[path]?.identity.sameNode(identity) == true else {
                throw ModelLibraryError.unsafePath("暂存文件身份未知，未覆盖；请检查安装目录。")
            }
        }
        let remaining = entry.totalBytes - min(entry.totalBytes, try stored(id).record.downloadedBytes)
        try requireSpace(remaining)
        for file in entry.files where try stored(id).files[file.path] == nil {
            let descriptor = try content.openFile(file.path, writing: true, create: true)
            defer { Darwin.close(descriptor) }
            let identity = try ModelDirectory.identity(descriptor, regular: true)
            mutate(id) { $0.files[file.path] = .init(completed: 0, identity: identity) }
            try persist()
        }
        setState(id, .downloading); try persist()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<min(2, entry.files.count) {
                let file = entry.files[next]; next += 1
                group.addTask { try await self.download(file, model: id, content: content, entry: entry) }
            }
            while try await group.next() != nil {
                if next < entry.files.count {
                    let file = entry.files[next]; next += 1
                    group.addTask { try await self.download(file, model: id, content: content, entry: entry) }
                }
            }
        }
        setState(id, .verifying); try persist()
        let job = Task.detached { try content.verify(entry.files) }
        let verifiedFiles = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        try Task.checkCancellation()
        setState(id, .publishing)
        mutate(id) { $0.publicationRoot = content.identity }
        try persist()
        let stage = try root.child("Staging/" + id.description)
        try root.validateLocation(); try content.validateLocation()
        guard renameatx_np(stage.descriptor, "Content", installations.descriptor, id.description, UInt32(RENAME_EXCL)) == 0,
              fsync(installations.descriptor) == 0, fsync(stage.descriptor) == 0 else {
            throw ModelDirectory.failure("原子发布模型（不会覆盖已有内容）")
        }
        let installed = try installations.child(id.description)
        guard installed.identity.sameNode(content.identity), try installed.entries(expectedPaths: Set(entry.files.map(\.path))) == verifiedFiles else {
            throw ModelLibraryError.integrity("发布后模型身份发生变化，已保留文件。")
        }
        verified(id, directory: installed, files: verifiedFiles)
    }

    private func download(_ file: ModelFile, model id: ModelID, content: ModelDirectory, entry: ModelCatalogEntry) async throws {
        var offset = try stored(id).files[file.path]!.completed
        let fd = try content.openFile(file.path, writing: true)
        defer { Darwin.close(fd) }
        let actual = try ModelDirectory.identity(fd, regular: true)
        guard let expected = try stored(id).files[file.path], expected.identity.sameNode(actual),
              actual.size >= 0, UInt64(actual.size) >= offset, UInt64(actual.size) <= min(file.size, offset + Self.chunkBytes) else {
            throw ModelLibraryError.integrity("断点文件已被替换或大小异常：\(file.path)")
        }
        guard ftruncate(fd, off_t(offset)) == 0, lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else {
            throw ModelDirectory.failure("恢复下载断点")
        }
        while offset < file.size {
            try Task.checkCancellation(); try content.validateLocation()
            let end = min(offset + Self.chunkBytes, file.size) - 1
            let range = ModelByteRange(url: sourceURL(entry: entry, file: file, start: offset), start: offset, end: end, total: file.size)
            try await transport.download(range, to: fd)
            try content.validateLocation()
            offset = end + 1
            let current = try ModelDirectory.identity(fd, regular: true)
            guard current.sameNode(expected.identity), current.size == offset else { throw ModelLibraryError.integrity("下载文件发生变化。") }
            mutate(id) {
                $0.files[file.path] = .init(completed: offset, identity: current)
                $0.record.downloadedBytes = $0.files.values.reduce(0) { $0 + $1.completed }
            }
            try persist()
        }
    }

    private func stagingContent(_ id: ModelID, create: Bool) throws -> ModelDirectory {
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库磁盘不可用。") }
        let stage = try root.child("Staging/" + id.description, create: create)
        let marker = Data((disk.libraryID.uuidString + "\n" + id.description + "\n" + (try stored(id).record.revision)).utf8)
        if try Self.exists("owner", in: stage) {
            guard try stage.read("owner") == marker else { throw ModelLibraryError.unsafePath("暂存目录所有权不符。") }
        } else { try stage.atomicWrite(marker, to: "owner", replace: false) }
        return try stage.child("Content", create: create)
    }

    private func attachRoot(_ scope: ModelScopedLocation, create: Bool) throws {
        let selected = try ModelDirectory(scope.url)
        let root = try selected.child(".d-model-library", create: create)
        let marker = Data(disk.libraryID.uuidString.utf8)
        if try Self.exists("owner.json", in: root) {
            guard try root.read("owner.json") == marker else { throw ModelLibraryError.unsafePath("所选位置属于另一个模型库，未接管或覆盖。") }
        } else {
            guard create, try root.entries(expectedPaths: []).isEmpty else { throw ModelLibraryError.unsafePath("模型库目录含未知内容。") }
            try root.atomicWrite(marker, to: "owner.json", replace: false)
        }
        try validateRootIdentity(root)
        let lock: ModelFileHandle
        if let previous = libraryRoot, previous.identity.sameNode(root.identity), let currentLock = libraryLock {
            lock = currentLock
        } else { lock = try Self.lock(in: root, path: "library.lock") }
        _ = try root.child("Installations", create: true); _ = try root.child("Staging", create: true)
        libraryRoot = root; libraryLock = lock; rootScope = scope
        disk.rootBookmark = scope.bookmark; disk.rootURL = scope.url; disk.rootIdentity = root.identity
        for index in disk.records.indices where disk.records[index].record.storage == .managed {
            disk.records[index].record.directory = root.url.appendingPathComponent("Installations/" + disk.records[index].record.id.description)
        }
    }

    /// Relocation preserves the actual directory, not merely a copied owner marker.
    /// Older v1 indexes are upgraded after checking their existing installation/file identities.
    private func validateRootIdentity(_ root: ModelDirectory) throws {
        let managed = disk.records.filter { $0.record.storage == .managed }
        guard !managed.isEmpty else { return }
        let rejected = ModelLibraryError.unavailable("所选位置是模型库的副本或已替换的目录。当前仅支持原模型库在同一磁盘卷内移动；原位置和模型记录已保留。")
        if let expected = disk.rootIdentity ?? libraryRoot?.identity {
            guard expected.sameNode(root.identity) else { throw rejected }
            return
        }
        // Compatibility with an index written before rootIdentity existed. Copied bytes
        // cannot satisfy any persisted node identity, even on the same filesystem.
        for value in managed {
            if let expected = value.verifiedRoot {
                let directory = try root.child("Installations/" + value.record.id.description)
                guard expected.sameNode(directory.identity) else { throw rejected }
            } else if let expected = value.publicationRoot {
                let installed = "Installations/" + value.record.id.description
                let path = try Self.exists(installed, in: root) ? installed : "Staging/" + value.record.id.description + "/Content"
                guard try expected.sameNode(root.child(path).identity) else { throw rejected }
            } else if !value.files.isEmpty {
                let content = try root.child("Staging/" + value.record.id.description + "/Content")
                for (path, progress) in value.files {
                    guard try progress.identity.sameNode(content.fileIdentity(path)) else { throw rejected }
                }
            }
        }
    }

    private func resolved(_ stored: StoredRecord) throws -> ModelDirectory {
        let directory: ModelDirectory
        if stored.record.storage == .managed {
            guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库所在磁盘不可用。") }
            directory = try root.child("Installations/" + stored.record.id.description)
        } else {
            guard let scope = externalScopes[stored.record.id] else { throw ModelLibraryError.unavailable("模型目录需要重新授权。") }
            directory = try ModelDirectory(scope.url)
        }
        guard let identity = stored.verifiedRoot, identity.sameNode(directory.identity),
              try directory.entries(expectedPaths: Set(stored.verifiedFiles.keys)) == stored.verifiedFiles else {
            throw ModelLibraryError.integrity("模型文件已改变或位置不符，请重新校验。")
        }
        return directory
    }
    private func sourceURL(entry: ModelCatalogEntry, file: ModelFile, start: UInt64) -> URL {
        let base = sourceBaseURL ?? URL(string: "https://huggingface.co")!
        var url = base.appendingPathComponent(entry.repository).appendingPathComponent("resolve")
            .appendingPathComponent(entry.revision).appendingPathComponent(file.path)
        if sourceBaseURL == nil { url.append(queryItems: [.init(name: "download", value: "true"), .init(name: "d_range", value: String(start))]) }
        return url
    }
    private func requireSpace(_ remaining: UInt64) throws {
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库未配置。") }
        var status = statvfs()
        guard fstatvfs(root.descriptor, &status) == 0 else { throw ModelDirectory.failure("检查磁盘空间") }
        let available = availableBytesOverride ?? UInt64(status.f_bavail) * UInt64(status.f_frsize)
        let required = remaining + 64 * 1024 * 1024
        guard available >= required else { throw ModelLibraryError.insufficientSpace(required: required, available: available) }
    }
    private func persist() throws {
        disk.revision &+= 1
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try stateDirectory.atomicWrite(encoder.encode(disk), to: "index.json")
    }
    private func requireAdmission() throws { if !accepting { throw ModelLibraryError.busy("模型库正在关闭，请等待应用退出。") } }
    private func requireIdleWorker() throws { if !workers.isEmpty { throw ModelLibraryError.busy("请先等待或暂停当前模型操作。") } }
    private func stored(_ id: ModelID) throws -> StoredRecord {
        guard let result = disk.records.first(where: { $0.record.id == id }) else { throw ModelLibraryError.unavailable("模型记录不存在。") }; return result
    }
    private func mutate(_ id: ModelID, _ body: (inout StoredRecord) -> Void) {
        if let index = disk.records.firstIndex(where: { $0.record.id == id }) { body(&disk.records[index]); disk.revision &+= 1 }
    }
    private func setState(_ id: ModelID, _ state: ModelInstallationState) { mutate(id) { $0.record.state = state; $0.record.error = nil } }
    private func catalogEntry(_ id: String) throws -> ModelCatalogEntry {
        guard let value = catalog.first(where: { $0.id == id }) else { throw ModelLibraryError.invalidCatalog("不支持的模型目录条目。") }; return value
    }
    private func entry(for id: ModelID) throws -> ModelCatalogEntry { try catalogEntry(stored(id).record.catalogID) }
    private static func exists(_ path: String, in directory: ModelDirectory) throws -> Bool {
        let (parent, name) = try directory.parent(path); defer { Darwin.close(parent) }
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw ModelDirectory.failure("检查模型库路径")
    }
    private static func lock(in directory: ModelDirectory, path: String) throws -> ModelFileHandle {
        let descriptor = try directory.openFile(path, writing: true, create: !(try exists(path, in: directory)))
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); throw ModelLibraryError.busy("模型库正由另一个应用实例使用。")
        }
        return ModelFileHandle(descriptor)
    }
    private static func validateCatalog(_ entries: [ModelCatalogEntry]) throws {
        guard !entries.isEmpty, Set(entries.map(\.id)).count == entries.count else { throw ModelLibraryError.invalidCatalog("模型目录为空或重复。") }
        for entry in entries {
            guard entry.revision.count == 40, entry.revision.allSatisfy({ $0.isHexDigit }),
                  !entry.files.isEmpty, entry.files.count <= 1024,
                  Set(entry.files.map(\.path)).count == entry.files.count else { throw ModelLibraryError.invalidCatalog("模型版本或文件清单无效。") }
            let paths = Set(entry.files.map(\.path))
            for file in entry.files {
                let parts = try ModelDirectory.parts(file.path)
                guard file.size > 0, file.size <= 16 * 1024 * 1024 * 1024,
                      file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }),
                      !(1..<parts.count).contains(where: { paths.contains(parts.prefix($0).joined(separator: "/")) }) else {
                    throw ModelLibraryError.invalidCatalog("模型文件大小、摘要或路径冲突。")
                }
            }
        }
    }
}

private final class ModelFileHandle: Sendable {
    let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
}

private final class ModelScopedLocation: Sendable {
    let url: URL
    let bookmark: Data
    private let selected: URL
    private let active: Bool
    init(_ selected: URL) throws {
        self.selected = selected
        active = selected.startAccessingSecurityScopedResource()
        do {
            url = try ModelDirectory.canonicalURL(selected)
            _ = try ModelDirectory(url)
            bookmark = try selected.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch { if active { selected.stopAccessingSecurityScopedResource() }; throw error }
    }
    deinit { if active { selected.stopAccessingSecurityScopedResource() } }
    static func restore(_ bookmark: Data) throws -> ModelScopedLocation {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return try ModelScopedLocation(url)
    }
}
