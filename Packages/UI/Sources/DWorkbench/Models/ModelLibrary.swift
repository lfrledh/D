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
        var recipeIdentity: String?
        var precedingRecipeIdentity: String?
        var needsWanTokenizerUpgrade: Bool?
        var files: [String: FileProgress] = [:]
        var verifiedFiles: [String: ModelFileIdentity] = [:]
        var verifiedDirectories: [String: ModelFileIdentity]?
        var verifiedRoot: ModelFileIdentity?
        var publicationRoot: ModelFileIdentity?
        var control: ModelResourceControl?
        var deletion: DeletionIntent?
        var retiredLocations: [RetiredLocation]?
    }
    private struct RetiredLocation: Codable, Sendable { let url: URL; let root: ModelFileIdentity? }
    private struct DeletionIntent: Codable, Sendable {
        let path: String
        let root: ModelFileIdentity
        let files: [String: ModelFileIdentity]
    }
    private struct DiskState: Codable {
        var schemaVersion = 2
        var libraryID = UUID()
        var revision: UInt64 = 0
        var rootBookmark: Data?
        var rootURL: URL?
        var rootIdentity: ModelFileIdentity?
        var downloadCredentialBookmark: Data?
        var downloadCredentialAccount: String?
        var records: [StoredRecord] = []
        var downloads: [ModelDownloadTask]?
        var queueState: ModelDownloadQueueState?
    }
    private let now: @Sendable () -> Date
    private let sleepUntil: @Sendable (Date) async throws -> Void
    private let credentialServices: ModelCredentialServices
    private let checkpoint: @Sendable (String) throws -> Void
    private let wanPreparation: ModelWanPreparation.Converter?
    private let stateDirectory: ModelDirectory
    private let stateLock: ModelFileHandle
    private let catalog: [ModelCatalogEntry]
    private let transport: any ModelRangeTransport
    private let sourceBaseURL: URL?
    private let availableBytesOverride: UInt64?
    private var inlineDownloadCredential: ModelDownloadCredential?
    private var credentialIntent = UUID()
    private var disk: DiskState { didSet { stateDidChange() } }
    private var rootScope: ModelScopedLocation?
    private var libraryRoot: ModelDirectory?
    private var libraryLock: ModelFileHandle?
    private var externalScopes: [ModelID: ModelScopedLocation] = [:]
    private var workers: [ModelID: Task<Void, Never>] = [:]
    private var leases: [UUID: ModelUsageLease] = [:] { didSet { stateDidChange() } }
    private var preparationJobs: [ModelID: (job: Task<URL, any Error>, lease: ModelUsageLease, scope: ModelScopedLocation)] = [:]
    private var accepting = true
    private var queueError: String? { didSet { stateDidChange(urgent: true) } }
    private var retryWake: Task<Void, Never>?
    private var activeDownload: (task: UUID, attempt: UUID, generation: UUID, resource: ModelID)?
    private var queuePausing = false
    private var cleanupReservations: Set<ModelID> = []
    private var cancelledOperations: Set<ModelID> = []
    private var copyJob: Task<[String: ModelFileIdentity], any Error>?
    private var currentCopy: ModelCopyProgress? { didSet { stateDidChange() } }
    private var copyKnownFiles: [String: ModelFileIdentity] = [:]
    private static let chunkBytes: UInt64 = 16 * 1024 * 1024

    public init(stateDirectory: URL, wanPreparation: (@Sendable (URL, URL) async throws -> Void)? = nil) async throws {
        try await self.init(stateDirectory: stateDirectory, catalog: ModelCatalog.entries(), wanPreparation: wanPreparation)
    }

    /// Internal seams use tiny deterministic catalogs and loopback HTTP; production is fixed and HTTPS-only.
    init(stateDirectory: URL, catalog: [ModelCatalogEntry],
         transport: any ModelRangeTransport = URLSessionModelRangeTransport(), sourceBaseURL: URL? = nil, availableBytesOverride: UInt64? = nil, wanPreparation: ModelWanPreparation.Converter? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         sleepUntil: @escaping @Sendable (Date) async throws -> Void = { deadline in try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) },
         credentialServices: ModelCredentialServices = .init(),
         checkpoint: @escaping @Sendable (String) throws -> Void = { _ in }) async throws {
        try Self.validateCatalog(catalog)
        if let sourceBaseURL {
            guard let components = URLComponents(url: sourceBaseURL, resolvingAgainstBaseURL: false),
                  components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
                  components.path.isEmpty || components.path == "/",
                  components.scheme == "https" ||
                    (components.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(components.host ?? "")) else {
                throw ModelLibraryError.invalidCatalog("下载来源 URL 不安全。")
            }
        }
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let directory = try ModelDirectory(ModelDirectory.canonicalURL(stateDirectory))
        self.stateDirectory = directory
        stateLock = try Self.lock(in: directory, path: "model-library.lock")
        self.catalog = catalog; self.transport = transport; self.sourceBaseURL = sourceBaseURL
        self.availableBytesOverride = availableBytesOverride
        self.wanPreparation = wanPreparation
        self.now = now; self.sleepUntil = sleepUntil; self.checkpoint = checkpoint; self.credentialServices = credentialServices
        let originalIndex = try Self.exists("index.json", in: directory) ? directory.read("index.json", maximum: 32 * 1024 * 1024) : nil
        if let originalIndex {
            disk = try JSONDecoder().decode(DiskState.self, from: originalIndex)
            guard [1, 2].contains(disk.schemaVersion), Set(disk.records.map(\.record.id)).count == disk.records.count else {
                throw ModelLibraryError.integrity("模型库索引版本无效或记录重复，原文件已保留。")
            }
        } else { disk = DiskState() }
        var migratedWanIDs = Set<ModelID>()
        var correctedACESourceIDs = Set<ModelID>()
        for index in disk.records.indices {
            let value = disk.records[index]
            guard let entry = catalog.first(where: { $0.id == value.record.catalogID }), entry.revision == value.record.revision,
                  value.files.allSatisfy({ path, progress in entry.files.contains { $0.path == path && progress.completed <= $0.size } }) else {
                throw ModelLibraryError.integrity("模型索引与固定目录不一致。")
            }
            let identity = try Self.recipeIdentity(entry)
            if let recorded = value.recipeIdentity {
                if recorded != identity {
                    if try Self.isACESourceCorrection(from: recorded, to: entry) {
                        correctedACESourceIDs.insert(value.record.id)
                        disk.records[index].precedingRecipeIdentity = recorded
                        disk.records[index].recipeIdentity = identity
                    } else {
                    guard try Self.isWanTokenizerUpgrade(from: recorded, to: entry) else {
                        throw ModelLibraryError.integrity("固定下载配方已改变；保留已有文件，拒绝混合断点。")
                    }
                    migratedWanIDs.insert(value.record.id)
                    disk.records[index].precedingRecipeIdentity = recorded
                    disk.records[index].recipeIdentity = identity
                    disk.records[index].needsWanTokenizerUpgrade = true
                    disk.records[index].control = value.control ?? .init(fileState: .partial, origin: .legacy)
                    if value.deletion == nil, ![.deleted, .deleting].contains(value.control?.fileState) {
                        if value.control?.role != .execution {
                            disk.records[index].record = value.record.replacingTotalBytes(entry.totalBytes)
                        }
                        disk.records[index].record.state = .paused
                        disk.records[index].record.error = value.record.error
                        disk.records[index].control?.fileState = .partial
                        disk.records[index].control?.requiresTokenizerUpgrade = true
                    }
                    }
                }
            } else {
                // v1 persisted only Klein's fixed single-repository SHA-256 recipe.
                guard let legacy = try? ModelCatalog.flux2(), entry.id == ModelCatalog.flux2ID,
                      entry.repository == "mzbac/FLUX.2-klein-4B-q8",
                      entry.revision == "ef52ee019fd1d0e75ae4deb40476ba65989716d7",
                      entry.files == legacy.files,
                      entry.files.allSatisfy({ $0.digestAlgorithm == .sha256 && $0.sourceRepository == nil && $0.sourceRevision == nil && $0.remotePath == nil }) else {
                    throw ModelLibraryError.integrity("旧索引缺少下载配方身份，拒绝恢复。")
                }
                disk.records[index].recipeIdentity = identity
            }
            if disk.records[index].control == nil {
                let complete = [.installed, .preparationRequired].contains(value.record.state)
                disk.records[index].control = .init(fileState: complete ? .verified : .partial,
                    origin: value.record.storage == .external ? .local : .legacy)
            }
            disk.records[index].record.activeLeaseCount = 0
            if !migratedWanIDs.contains(value.record.id), [.queued, .downloading, .pausing, .verifying, .publishing].contains(value.record.state) {
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
        if !migratedWanIDs.isEmpty, let originalIndex {
            try checkpoint("wanTokenizerMigration.backup")
            let backup = "index.wan-tokenizer-v1.backup.json"
            if try Self.exists(backup, in: directory) {
                guard try directory.read(backup, maximum: 32 * 1024 * 1024) == originalIndex else {
                    throw ModelLibraryError.integrity("Wan 升级备份已存在且内容不同，未修改索引。")
                }
            } else { try directory.atomicWrite(originalIndex, to: backup) }
        }
        if !correctedACESourceIDs.isEmpty, let originalIndex {
            try checkpoint("aceSourceCorrection.backup")
            let backup = "index.ace-source-v1.backup.json"
            if try Self.exists(backup, in: directory) {
                guard try directory.read(backup, maximum: 32 * 1024 * 1024) == originalIndex else {
                    throw ModelLibraryError.integrity("ACE source backup differs; existing files and index were not replaced.")
                }
            } else { try directory.atomicWrite(originalIndex, to: backup) }
        }
        if disk.schemaVersion == 1, let originalIndex {
            try checkpoint("migration.backup")
            let backup = "index.v1.backup.json"
            if try Self.exists(backup, in: directory) {
                guard try directory.read(backup, maximum: 32 * 1024 * 1024) == originalIndex else {
                    throw ModelLibraryError.integrity("旧索引备份已存在且内容不同；原索引未修改。")
                }
            } else { try directory.atomicWrite(originalIndex, to: backup) }
        }
        disk.schemaVersion = 2
        disk.downloads = disk.downloads ?? []
        guard Set(disk.downloads!.map(\.id)).count == disk.downloads!.count else {
            throw ModelLibraryError.integrity("下载任务身份重复。")
        }
        for index in disk.downloads!.indices {
            var task = disk.downloads![index]
            let resource = try stored(task.resourceID.modelID)
            if migratedWanIDs.contains(task.resourceID.modelID) || correctedACESourceIDs.contains(task.resourceID.modelID), task.recipeIdentity == resource.precedingRecipeIdentity,
               !task.state.isTerminal, let recipe = resource.recipeIdentity {
                task = task.upgradingRecipe(recipe); task.state = .paused
                disk.downloads![index] = task
                mutate(task.resourceID.modelID) { $0.control?.downloadOwner = .init(task) }
            }
            guard task.catalogID == resource.record.catalogID,
                  task.recipeIdentity == resource.recipeIdentity || (task.state.isTerminal && task.recipeIdentity == resource.precedingRecipeIdentity),
                  task.attempts >= 0, (0...3).contains(task.automaticRetries) else {
                throw ModelLibraryError.integrity("下载任务与资源配方不符。")
            }
            if task.state.isActive { disk.downloads![index].state = .queued }
        }
        // Legacy unfinished requests still own their work. Terminal-only history
        // cannot prove which attempt last handled the files, so remains unknown.
        for index in disk.records.indices where disk.records[index].control?.downloadOwner == nil {
            let tasks = disk.downloads!.filter { $0.resourceID.modelID == disk.records[index].record.id && !$0.state.isTerminal }
            guard tasks.count <= 1 else { throw ModelLibraryError.integrity("同一文件存在多个未结束的下载任务。") }
            if let task = tasks.first { disk.records[index].control?.downloadOwner = .init(task) }
        }
        disk.queueState = .waitingForResume
        try persist()
    }

    // One owner, no lifecycle timer. Subscription and initial memory snapshot are
    // installed in the same actor turn. A bounded newest buffer preserves current
    // terminal state even when a consumer is busy reconciling a previous update.
    private var observers: [UUID: AsyncStream<ModelLibrarySnapshot>.Continuation] = [:]
    private var publication: Task<Void, Never>?
    private var publicationIsUrgent = false
    private var progressMutation = false
    private var lastPublished: ModelLibrarySnapshot?
    private var availabilityCheck: Task<ModelLibrarySnapshot, Never>?
    private var requestedChecks: Set<ModelID> = []
    private var checkAll = false
    // Internal, constant-size counters for targeted regression tests (no logging).
    private(set) var statePublicationCount = 0
    private(set) var availabilityCheckCount = 0
    var observationCount: Int { observers.count }

    public func changes() -> AsyncStream<ModelLibrarySnapshot> {
        let id = UUID()
        let pair = AsyncStream<ModelLibrarySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        pair.continuation.yield(snapshot())
        return pair.stream
    }
    private func removeObserver(_ id: UUID) {
        observers[id] = nil
        if observers.isEmpty {
            publication?.cancel(); publication = nil; publicationIsUrgent = false; lastPublished = nil
        }
    }
    private func stateDidChange(urgent: Bool = false) {
        guard !observers.isEmpty else { return }
        let immediate = urgent || !progressMutation
        if publication != nil {
            guard immediate && !publicationIsUrgent else { return }
            publication?.cancel()
        }
        publicationIsUrgent = immediate
        publication = Task { [weak self] in
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.publishState()
        }
    }
    private func publishState() {
        publication = nil; publicationIsUrgent = false
        let current = snapshot()
        guard current != lastPublished else { return }
        lastPublished = current; statePublicationCount += 1
        for observer in observers.values { observer.yield(current) }
    }

    /// Explicit display availability check. Concurrent requests merge their exact
    /// resource scope before one actor-isolated pass. The pass has no suspension:
    /// root/record replacement cannot interleave or accept a stale result. Admission
    /// (resolve/acquire/register/delete) retains its stronger, independent checks.
    public func checkAvailability(ids: Set<ModelID>? = nil) async -> ModelLibrarySnapshot {
        if let ids { requestedChecks.formUnion(ids) } else { checkAll = true }
        if let availabilityCheck { return await availabilityCheck.value }
        let task = Task { [weak self] in
            await Task.yield()
            guard let self else { preconditionFailure("Model library released during an owned check") }
            return await self.performAvailabilityCheck()
        }
        availabilityCheck = task
        return await task.value
    }
    private func performAvailabilityCheck() -> ModelLibrarySnapshot {
        let ids: Set<ModelID>? = checkAll ? nil : requestedChecks
        requestedChecks.removeAll(); checkAll = false
        checkAvailabilityNow(ids: ids)
        availabilityCheck = nil
        return snapshot()
    }
    private func checkAvailabilityNow(ids: Set<ModelID>?) {
        availabilityCheckCount += 1
        for index in disk.records.indices {
            let stored = disk.records[index]
            guard ids == nil || ids!.contains(stored.record.id) else { continue }
            var availability = stored.record.availability
            var location = stored.record.directory
            // Viewing never hashes files, adopts legacy identities, or mutates registration.
            // Full required-tree verification stays at explicit admission/verification.
            if stored.control?.fileState == .deleted || stored.deletion != nil { availability = .unavailable }
            else if stored.record.storage == .managed {
                do {
                    guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库不可用。") }
                    try root.validateLocation(); availability = .available
                    if let expected = stored.verifiedRoot {
                        let directory = try root.child("Installations/" + stored.record.id.description)
                        guard expected.sameNode(directory.identity) else { throw ModelLibraryError.integrity("模型位置已改变。") }
                        guard try stored.verifiedFiles.allSatisfy({ try directory.fileIdentity($0.key) == $0.value }) else {
                            throw ModelLibraryError.integrity("已知模型文件改变。")
                        }
                        location = directory.url
                    }
                } catch { availability = .unavailable }
            } else if let scope = externalScopes[stored.record.id] {
                do {
                    let directory = try ModelDirectory(scope.url)
                    if let expected = stored.verifiedRoot, !expected.sameNode(directory.identity) {
                        throw ModelLibraryError.integrity("模型位置已改变。")
                    }
                    if !stored.verifiedFiles.isEmpty {
                        let current = try directory.requiredTree(paths: Set(stored.verifiedFiles.keys))
                        guard current.files == stored.verifiedFiles,
                              stored.verifiedDirectories == nil || current.directories == stored.verifiedDirectories else {
                            throw ModelLibraryError.integrity("已知模型文件或父目录改变。")
                        }
                    }
                    location = scope.url; availability = .available
                } catch { availability = .unavailable }
            } else { availability = .needsAuthorization }
            if availability != stored.record.availability || location != stored.record.directory {
                disk.records[index].record.availability = availability
                disk.records[index].record.directory = location
                disk.revision &+= 1
            }
        }
    }

    /// Memory only; never walks directories or checks file identities.
    public func snapshot() -> ModelLibrarySnapshot {
        let leaseCounts = Dictionary(grouping: leases.values, by: \.modelID).mapValues(\.count)
        let records = disk.records.map { stored -> ModelRecord in
            var record = stored.record
            record.activeLeaseCount = leaseCounts[record.id, default: 0]
            if record.storage == .managed, stored.control?.fileState == .partial,
               stored.verifiedRoot == nil, let selectedRoot = disk.rootURL {
                // A root attachment's future Installations path is not a published
                // resource. Projection uses the existing ownership ledger, no I/O.
                record.directory = selectedRoot.appendingPathComponent(".d-model-library/Staging/" + record.id.description + "/Content")
            }
            return record
        }
        return .init(revision: disk.revision, rootURL: rootScope?.url ?? disk.rootURL, catalog: catalog,
                     records: records, downloadCredentialConnected: disk.downloadCredentialBookmark != nil || disk.downloadCredentialAccount != nil || inlineDownloadCredential != nil,
                     copyProgress: currentCopy,
                     resources: zip(records, disk.records).map { .init(record: $0.0, control: $0.1.control ?? .init(fileState: .unchecked, origin: .local)) },
                     downloads: disk.downloads ?? [], queueState: disk.queueState ?? .waitingForResume, queueError: queueError)
    }

    public func checkDownloadAccess(taskID: UUID) async throws {
        try requireAdmission()
        guard let task = disk.downloads?.first(where: { $0.id == taskID }),
              let entry = catalog.first(where: { $0.id == task.catalogID }), !entry.files.isEmpty, sourceBaseURL == nil else {
            throw ModelLibraryError.accessDenied("当前任务没有可核对的固定模型来源。")
        }
        try await checkCatalogAccess(catalogID: entry.id)
        guard disk.downloads?.contains(where: { $0.id == task.id && $0.generation == task.generation && $0.attemptID == task.attemptID }) == true else {
            throw ModelLibraryError.busy("下载任务已改变；请重新选择当前任务。")
        }
    }

    /// Explicit access recheck before enqueue. Never called by rendering or progress projection.
    public func checkCatalogAccess(catalogID: String) async throws {
        try requireAdmission()
        let entry = try catalogEntry(catalogID)
        guard !entry.files.isEmpty, sourceBaseURL == nil else { throw ModelLibraryError.accessDenied("当前配置没有可核对的固定模型来源。") }
        let intent = credentialIntent, credential = downloadCredential
        let groups = Dictionary(grouping: entry.files) { ($0.source?.rawValue ?? "huggingFace") + ":" + ($0.sourceRepository ?? entry.repository) + "@" + ($0.sourceRevision ?? entry.revision) }
        for key in groups.keys.sorted() {
            guard let file = groups[key]?.max(by: { $0.size < $1.size }) else { continue }
            try await ModelSourceAccessProbe.check(sourceURL(entry: entry, file: file, start: 0), credential: file.source == .githubRaw ? nil : credential)
            try Task.checkCancellation(); try requireAdmission()
            guard intent == credentialIntent, try catalogEntry(catalogID) == entry else { throw CancellationError() }
        }
    }

    public func connectDownloadToken(_ token: String, saveToKeychain: Bool) async throws {
        try requireAdmission(); try requireIdleWorker()
        let token = try ModelDownloadCredential.validated(token)
        let intent = UUID(); credentialIntent = intent
        try await credentialServices.validate(token)
        try Task.checkCancellation(); try requireAdmission(); try requireIdleWorker()
        guard credentialIntent == intent else { throw CancellationError() }
        let account = saveToKeychain ? credentialSlots.first(where: { $0 != disk.downloadCredentialAccount }) : nil
        if let account {
            // Fixed two slots make even a failed rollback cleanup discoverable
            // after reopening, without scanning credentials or storing tokens.
            try credentialServices.remove(account)
            try credentialServices.insert(token, account)
        }
        do { try replaceDownloadCredential(bookmark: nil, account: account, inline: account == nil ? try ModelDownloadCredential(token: token) : nil) }
        catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            // A cleanup error after publication must never delete the current token.
            if disk.downloadCredentialAccount == account, account != nil { throw error }
            if let account {
                do { try credentialServices.remove(account) }
                catch let cleanup {
                    throw ModelLibraryError.unavailable(error.localizedDescription + "\n" + cleanup.localizedDescription)
                }
            }
            throw error
        }
    }
    private var credentialSlots: [String] { [0, 1].map { disk.libraryID.uuidString.lowercased() + ".download-token.\($0)" } }
    private func clearInactiveCredentials(previous: String? = nil) throws {
        let accounts = Set(credentialSlots + (previous.map { [$0] } ?? []))
        for account in accounts.sorted() where account != disk.downloadCredentialAccount { try credentialServices.remove(account) }
    }
    public func connectDownloadCredential(at selected: URL) throws {
        try Task.checkCancellation(); try requireAdmission(); try requireIdleWorker()
        let credential = try ModelDownloadCredential.choose(selected)
        _ = try credential.token()
        credentialIntent = UUID()
        try replaceDownloadCredential(bookmark: credential.bookmark, account: nil, inline: nil)
    }
    public func disconnectDownloadCredential() throws {
        try Task.checkCancellation(); try requireAdmission(); try requireIdleWorker()
        credentialIntent = UUID()
        try replaceDownloadCredential(bookmark: nil, account: nil, inline: nil)
    }
    private func replaceDownloadCredential(bookmark: Data?, account: String?, inline: ModelDownloadCredential?) throws {
        let oldDisk = disk, oldAccount = disk.downloadCredentialAccount, oldInline = inlineDownloadCredential
        disk.downloadCredentialBookmark = bookmark; disk.downloadCredentialAccount = account; inlineDownloadCredential = inline
        disk.revision &+= 1
        do { try persist() }
        catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error {
                // The new reference is already durable. Keep both fixed slots
                // until a later explicit connection/removal retries cleanup.
                throw error
            }
            disk = oldDisk; inlineDownloadCredential = oldInline; throw error
        }
        try clearInactiveCredentials(previous: oldAccount)
    }
    private var downloadCredential: ModelDownloadCredential? {
        if let inlineDownloadCredential { return inlineDownloadCredential }
        if let account = disk.downloadCredentialAccount { return .init(keychainAccount: account, read: credentialServices.read) }
        return disk.downloadCredentialBookmark.map { .init(bookmark: $0) }
    }

    public func configureRoot(at selected: URL) throws {
        try requireAdmission()
        guard workers.isEmpty, preparationJobs.isEmpty, copyJob == nil, leases.isEmpty else { throw ModelLibraryError.busy("模型正在下载、校验或用于任务；请等待结束后更换模型库位置。") }
        let scope = try ModelScopedLocation(selected)
        let hasManaged = disk.records.contains { $0.record.storage == .managed }
        let candidate = try ModelDirectory(scope.url)
        if hasManaged, !(try Self.exists(".d-model-library/owner.json", in: candidate)) {
            throw ModelLibraryError.busy("已有受管理模型。当前仅支持原模型库在同一磁盘卷内移动；请选择包含原模型库的位置，不会接管跨卷复制的内容。")
        }
        let previousDisk = disk, previousRoot = libraryRoot, previousScope = rootScope, previousLock = libraryLock
        do {
            try attachRoot(scope, create: !hasManaged)
            checkAvailabilityNow(ids: Set(disk.records.filter { $0.record.storage == .managed }.map { $0.record.id }))
            try persist()
        }
        catch {
            disk = previousDisk; libraryRoot = previousRoot; rootScope = previousScope; libraryLock = previousLock
            throw error
        }
    }

    /// Compatibility entry point for existing explicit install-and-register callers.
    public func install(catalogID: String = ModelCatalog.flux2ID) throws -> ModelID {
        if let existing = disk.records.first(where: { $0.record.catalogID == catalogID && $0.record.storage == .managed && $0.control?.fileState == .verified && $0.deletion == nil }) {
            if existing.record.state == .installed { try registerResource(.init(rawValue: existing.record.id.rawValue)) }
            return existing.record.id
        }
        return try enqueueDownloads([catalogID], postAction: .register)[0].resourceID.modelID
    }

    public func pause(_ id: ModelID) async throws {
        try requireAdmission()
        if let task = downloadForResource(id), !task.state.isTerminal {
            try await pauseDownload(task.id); return
        }
        guard let worker = workers[id] else { return }
        setState(id, .pausing)
        worker.cancel()
        var persistenceFailure: (any Error)?
        do { try persist() } catch { persistenceFailure = error }
        await worker.value
        if let persistenceFailure { throw persistenceFailure }
    }
    public func resume(_ id: ModelID) throws {
        try requireAdmission()
        if try stored(id).record.storage == .managed {
            _ = try continuePartial(.init(rawValue: id.rawValue), postAction: .register); return
        }
        try requireIdleWorker()
        let value = try stored(id)
        guard value.record.state != .installed && value.record.state != .preparationRequired else { return }
        if value.record.storage == .external {
            guard let scope = externalScopes[id] else { throw ModelLibraryError.unavailable("请重新授权模型文件夹。") }
            launchVerification(id, scope: scope)
        } else {
            guard libraryRoot != nil else { throw ModelLibraryError.unavailable("模型库磁盘不可用，请重新定位。") }
            setState(id, .queued); try persist(); launchInstallation(id)
        }
    }
    public func retry(_ id: ModelID) throws { try resume(id) }

    public func restart(_ id: ModelID, resumeQueue: Bool = true) async throws {
        try requireAdmission()
        guard !cleanupReservations.contains(id), !leases.values.contains(where: { $0.modelID == id }) else { throw ModelLibraryError.busy("该模型仍用于任务，不能重新安装。") }
        if workers[id] != nil { try await pause(id) }
        try requireIdleWorker()
        let value = try stored(id)
        guard value.record.storage == .managed,
              value.record.state != .installed && value.record.state != .preparationRequired else {
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
        // Redownloading changes bytes, not the user's registration intent.
        // If history was cleared, conservatively default to files-only.
        let postAction = downloadForResource(id)?.postAction ?? .filesOnly
        try content.removeKnownFiles(actual)
        mutate(id) { $0.files = [:]; $0.record.downloadedBytes = 0; $0.publicationRoot = nil }
        try persist()
        _ = try continuePartial(.init(rawValue: id.rawValue), postAction: postAction, resumeQueue: resumeQueue)
    }

    public func registerExisting(at selected: URL, catalogID: String = ModelCatalog.flux2ID,
                                 storage: ModelStorageKind = .external) async throws -> ModelID {
        let sourceID = try await registerExternal(at: selected, catalogID: catalogID)
        return storage == .managed ? try await copyExistingToLibrary(sourceID) : sourceID
    }

    private func registerExternal(at selected: URL, catalogID: String) async throws -> ModelID {
        try requireAdmission(); try requireIdleWorker()
        let entry = try catalogEntry(catalogID)
        let scope = try ModelScopedLocation(selected)
        let directory = try ModelDirectory(scope.url)
        guard !disk.records.contains(where: { $0.record.storage == .managed &&
            $0.verifiedRoot?.sameNode(directory.identity) == true }) else {
            throw ModelLibraryError.busy("所选目录已属于 D 管理的安装，请使用现有记录。")
        }
        if let existing = disk.records.first(where: { $0.record.catalogID == catalogID &&
            $0.record.storage == .external && $0.verifiedRoot?.sameNode(directory.identity) == true }) {
            _ = try resolved(existing)
            if existing.record.state == .installed { try registerResource(.init(rawValue: existing.record.id.rawValue)) }
            return existing.record.id
        }
        let id = ModelID()
        disk.records.append(StoredRecord(record: .init(id: id, catalogID: catalogID, revision: entry.revision,
            storage: .external, state: .registered, availability: .available, downloadedBytes: 0,
            totalBytes: entry.totalBytes, error: nil, directory: scope.url, activeLeaseCount: 0,
            registrationState: .pending), bookmark: scope.bookmark,
            recipeIdentity: try Self.recipeIdentity(entry)))
        externalScopes[id] = scope
        do { try persist() } catch { disk.records.removeAll { $0.record.id == id }; externalScopes[id] = nil; throw error }
        launchVerification(id, scope: scope)
        let worker = workers[id]
        await withTaskCancellationHandler { await worker?.value } onCancel: { worker?.cancel() }
        try Task.checkCancellation()
        let completed = try stored(id)
        if cancelledOperations.contains(id) { throw ModelLibraryError.operationPaused }
        guard completed.record.state == .installed || completed.record.state == .preparationRequired else {
            throw ModelLibraryError.integrity(completed.record.error ?? "模型校验未完成。")
        }
        let verifiedRecord = try stored(id)
        mutate(id) { $0.record.registrationState = entry.preparation == .none ? .registered : .unregistered }
        do { try persist(purpose: "registration") }
        catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            mutate(id) { $0 = verifiedRecord }; throw error
        }
        return id
    }

    /// Creates a separate installation ID. The source registration and its bookmark
    /// remain available; the copy contains only fixed catalog files.
    public func copyExistingToLibrary(_ sourceID: ModelID) async throws -> ModelID {
        try await copyExistingToLibrary(sourceID, checkpoint: { _ in })
    }

    func copyExistingToLibrary(_ sourceID: ModelID,
                               checkpoint: @escaping @Sendable (UInt64) throws -> Void,
                               afterIndexRename: @escaping @Sendable () throws -> Void = {}) async throws -> ModelID {
        try requireAdmission(); try requireIdleWorker(); try Task.checkCancellation()
        let original = try stored(sourceID)
        guard original.record.storage == .external,
              [.installed, .preparationRequired].contains(original.record.state) else {
            throw ModelLibraryError.unavailable("请先校验保留原位置的模型，再复制到模型库。")
        }
        if let existing = disk.records.first(where: { $0.record.catalogID == original.record.catalogID && $0.record.storage == .managed }) {
            guard [.installed, .preparationRequired].contains(existing.record.state) else {
                throw ModelLibraryError.busy("已有同版本受管理安装尚未完成，请先处理该记录。")
            }
            _ = try resolved(existing)
            return existing.record.id
        }
        let entry = try entry(for: sourceID)
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("复制前请先选择模型库位置。") }
        try root.validateLocation(); try requireSpace(entry.totalBytes)
        let source = try resolved(original)
        let verifiedSource = try stored(sourceID)
        let expected = ModelRequiredTree(files: verifiedSource.verifiedFiles, directories: verifiedSource.verifiedDirectories ?? [:])
        guard try source.requiredTree(paths: Set(entry.files.map(\.path))) == expected else {
            throw ModelLibraryError.integrity("原始模型必要文件已改变，请重新校验。")
        }
        let id = ModelID()
        copyKnownFiles = [:]
        let staging = try root.child("Staging")
        guard !(try Self.exists(id.description, in: staging)) else { throw ModelLibraryError.busy("暂存标识冲突，请重试。") }
        let stage = try staging.child(id.description, create: true)
        let marker = Data((disk.libraryID.uuidString + "\n" + id.description + "\n" + entry.revision).utf8)
        let content: ModelDirectory
        do {
            try stage.atomicWrite(marker, to: "owner", replace: false)
            content = try stage.child("Content", create: true)
        } catch {
            let setupError = error
            do {
                if try Self.exists("owner", in: stage) {
                    let unfinished = try Self.exists("Content", in: stage) ? stage.child("Content") : nil
                    try cleanupCopyStage(stage: stage, staging: staging, marker: marker, content: unfinished)
                } else {
                    guard try stage.entries(expectedPaths: []).isEmpty,
                          unlinkat(staging.descriptor, id.description, AT_REMOVEDIR) == 0 else {
                        throw ModelLibraryError.unsafePath("复制暂存目录含未知文件，已保留。")
                    }
                }
            } catch {
                throw ModelLibraryError.storage("复制未开始，暂存清理未完成：\(error.localizedDescription)")
            }
            throw setupError
        }
        let lease = ModelUsageLease(id: UUID(), modelID: sourceID,
                                    reference: .init(directory: source.url, revision: entry.revision))
        leases[lease.id] = lease; disk.revision &+= 1
        currentCopy = .init(sourceID: sourceID, copiedBytes: 0, totalBytes: entry.totalBytes)
        defer {
            release(lease); copyJob = nil; currentCopy = nil; copyKnownFiles = [:]
            scheduleDownloads()
            disk.revision &+= 1
        }
        let job = Task.detached { [self] in
            try await content.copyRequired(entry.files, from: source, expected: expected) { path, bytes, identity in
                await self.noteCopy(path: path, bytes: bytes, identity: identity, sourceID: sourceID, total: entry.totalBytes)
                try checkpoint(bytes)
            }
            try Task.checkCancellation()
            return try content.verify(entry.files)
        }
        copyJob = job
        var publishedFiles: [String: ModelFileIdentity]?
        var indexPublished = false
        do {
            let verified = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            guard try source.requiredTree(paths: Set(entry.files.map(\.path))) == expected,
                  try content.entries(expectedPaths: Set(entry.files.map(\.path))) == verified else {
                throw ModelLibraryError.integrity("发布前原始文件或复制内容已改变。")
            }
            let installations = try root.child("Installations")
            try root.validateLocation(); try content.validateLocation()
            guard renameatx_np(stage.descriptor, "Content", installations.descriptor, id.description, UInt32(RENAME_EXCL)) == 0 else {
                throw ModelDirectory.failure("原子发布复制模型")
            }
            publishedFiles = verified
            guard fsync(installations.descriptor) == 0, fsync(stage.descriptor) == 0 else {
                throw ModelDirectory.failure("同步复制模型发布目录")
            }
            try Task.checkCancellation()
            let installed = try installations.child(id.description)
            guard installed.identity.sameNode(content.identity),
                  try installed.entries(expectedPaths: Set(entry.files.map(\.path))) == verified else {
                throw ModelLibraryError.integrity("发布后复制文件已改变，已保留原件。")
            }
            let previous = disk
            disk.records.append(StoredRecord(record: .init(id: id, catalogID: entry.id, revision: entry.revision,
                storage: .managed, state: entry.preparation == .required ? .preparationRequired : .installed,
                availability: .available, downloadedBytes: entry.totalBytes, totalBytes: entry.totalBytes,
                error: nil, directory: installed.url, activeLeaseCount: 0, registrationState: original.record.registrationState),
                recipeIdentity: try Self.recipeIdentity(entry), verifiedFiles: verified,
                verifiedRoot: installed.identity, publicationRoot: installed.identity,
                control: .init(fileState: .verified, origin: .local)))
            do { try persist(afterRename: afterIndexRename) }
            catch {
                if case ModelAtomicWriteError.publishedButUnsynced(let reason) = error {
                    indexPublished = true
                    throw ModelLibraryError.storage("复制模型及索引已发布，但索引目录同步未确认；已保留完整复制目录：\(installed.url.path)。\(reason.localizedDescription)")
                }
                disk = previous
                throw error
            }
            try? cleanupCopyStage(stage: stage, staging: staging, marker: marker, content: nil)
            return id
        } catch {
            if indexPublished {
                // The replacement index is already visible. Removing the copy would
                // leave a durable record pointing at missing content after reopen.
                try? cleanupCopyStage(stage: stage, staging: staging, marker: marker, content: nil)
                throw error
            }
            if let publishedFiles {
                let installations = try root.child("Installations")
                let installed = try installations.child(id.description)
                guard installed.identity.sameNode(content.identity),
                      try installed.entries(expectedPaths: Set(entry.files.map(\.path))) == publishedFiles else {
                    throw ModelLibraryError.unsafePath("复制目录发布后发生变化，未回退；原件与索引未覆盖。")
                }
                try installed.removeKnownFiles(publishedFiles)
                guard unlinkat(installations.descriptor, id.description, AT_REMOVEDIR) == 0,
                      fsync(installations.descriptor) == 0 else { throw ModelDirectory.failure("回退未登记的复制目录") }
                do { try cleanupCopyStage(stage: stage, staging: staging, marker: marker, content: nil) }
                catch { throw ModelLibraryError.storage("复制未登记，发布内容已回退；暂存清理未完成：\(error.localizedDescription)") }
            } else {
                do { try cleanupCopyStage(stage: stage, staging: staging, marker: marker, content: content) }
                catch { throw ModelLibraryError.storage("复制未登记，原件保留；暂存清理未完成：\(error.localizedDescription)") }
            }
            throw error
        }
    }

    private func noteCopy(path: String, bytes: UInt64, identity: ModelFileIdentity,
                          sourceID: ModelID, total: UInt64) {
        progressMutation = true
        defer { progressMutation = false }
        copyKnownFiles[path] = identity
        currentCopy = .init(sourceID: sourceID, copiedBytes: bytes, totalBytes: total)
        disk.revision &+= 1
    }

    private func cleanupCopyStage(stage: ModelDirectory, staging: ModelDirectory, marker: Data,
                                  content: ModelDirectory?) throws {
        guard try stage.read("owner") == marker else { throw ModelLibraryError.unsafePath("复制暂存所有权已改变，保留文件。") }
        if let content {
            let actual = try content.entries(expectedPaths: Set(copyKnownFiles.keys))
            guard actual == copyKnownFiles else { throw ModelLibraryError.unsafePath("复制暂存文件已改变，保留文件。") }
            try content.removeKnownFiles(actual)
            guard unlinkat(stage.descriptor, "Content", AT_REMOVEDIR) == 0 else { throw ModelDirectory.failure("移除空复制暂存目录") }
        }
        let owner = try stage.fileIdentity("owner")
        try stage.removeKnownFiles(["owner": owner])
        guard unlinkat(staging.descriptor, stage.url.lastPathComponent, AT_REMOVEDIR) == 0,
              fsync(staging.descriptor) == 0 else { throw ModelDirectory.failure("移除空复制暂存任务") }
    }

    public func rebind(_ id: ModelID, to selected: URL,
        preparedValidator: (@Sendable (URL) async throws -> ModelReference)? = nil) async throws {
        try requireAdmission(); try requireIdleWorker()
        // Rebinding also owns the heavy-operation slot. Downloads enqueued while
        // its validator runs must be reconsidered after either outcome drains.
        defer { scheduleDownloads() }
        guard !leases.values.contains(where: { $0.modelID == id }) else { throw ModelLibraryError.busy("模型仍用于运行或排队任务，不能重新定位。") }
        let previous = try stored(id)
        guard !(previous.needsWanTokenizerUpgrade == true && previous.control?.role == .execution) else {
            throw ModelLibraryError.unavailable("旧 Wan 执行包缺少独立分词资源。请补齐原始资源并重新准备执行包；旧文件未修改。")
        }
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
                let entry = try await self.entry(for: id)
                let directory = try ModelDirectory(candidate.url)
                let verified: ModelRequiredTree
                if previous.control?.role == .execution {
                    guard let preparedValidator else { throw ModelLibraryError.unavailable("执行包验证引擎尚不可用。") }
                    let reference = try await preparedValidator(directory.url)
                    guard reference.directory.standardizedFileURL == directory.url.standardizedFileURL,
                          reference.revision?.isEmpty == false,
                          previous.control?.executionRevision == nil || previous.control?.executionRevision == reference.revision else {
                        throw ModelLibraryError.integrity("执行包身份与原记录不符。")
                    }
                    verified = try directory.requiredTree(paths: Set(previous.control?.requiredPaths ?? []))
                } else {
                    let job = Task.detached { try Self.verifyExternal(directory, entry: entry) }
                    verified = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                }
                try Task.checkCancellation()
                await self.commitRebinding(id, scope: candidate, directory: directory, tree: verified, previous: previous, previousScope: previousScope)
            } catch { await self.rollbackRebinding(id, previous: previous, scope: previousScope, error: error) }
        }
        await workers[id]?.value
        if cancelledOperations.contains(id) { throw ModelLibraryError.operationPaused }
        guard try stored(id).record.error == nil else {
            throw ModelLibraryError.integrity(try stored(id).record.error ?? "重新定位未完成。")
        }
    }

    private func commitRebinding(_ id: ModelID, scope: ModelScopedLocation, directory: ModelDirectory,
                                 tree: ModelRequiredTree, previous: StoredRecord, previousScope: ModelScopedLocation?) {
        externalScopes[id] = scope
        mutate(id) {
            if let old = previous.record.directory, old.standardizedFileURL != directory.url.standardizedFileURL || previous.verifiedRoot?.sameNode(directory.identity) != true {
                $0.retiredLocations = (previous.retiredLocations ?? []) + [.init(url: old, root: previous.verifiedRoot)]
            }
            $0.bookmark = scope.bookmark
        }
        verified(id, directory: directory, files: tree.files, directories: tree.directories)
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

    public func profile(for id: ModelID) throws -> ImageModelProfile {
        guard let profile = try entry(for: id).imageProfile else {
            throw ModelLibraryError.unavailable("所选模型没有已接线的旧图像推理配置。")
        }
        return profile
    }
    public func catalogEntry(for id: ModelID) throws -> ModelCatalogEntry { try entry(for: id) }
    public func resolve(_ id: ModelID) throws -> ModelReference {
        try requireAdmission()
        let value = try stored(id)
        guard value.record.registrationState == .registered, value.deletion == nil,
              value.control?.fileState != .deleted else {
            throw ModelLibraryError.unavailable("该资源未登记或文件已删除；请在模型与下载中处理。")
        }
        guard value.record.state == .installed else {
            if value.record.state == .preparationRequired {
                throw ModelLibraryError.unavailable("模型原始文件已校验，但仍需准备执行引擎；当前不能用于任务。")
            }
            throw ModelLibraryError.unavailable("模型尚未完成安装和完整校验。")
        }
        let directory = try resolved(value)
        return .init(directory: directory.url, revision: value.control?.executionRevision ?? value.record.revision)
    }
    public func canPrepareVideo(_ id: ModelID) throws -> Bool {
        try stored(id).record.state == .preparationRequired && (ModelVideoPreparation.profile(for: entry(for: id)) != nil || (wanPreparation != nil && ModelWanPreparation.supports(entry(for: id))))
    }
    /// A separate prepared copy is returned for the existing explicit-model
    /// registration path. Raw download records deliberately remain raw resources.
    public func prepareVideo(_ id: ModelID, in selectedParent: URL) async throws -> URL {
        try await prepareVideo(id, in: selectedParent, checkpoint: { _ in })
    }
    func prepareVideo(_ id: ModelID, in selectedParent: URL, checkpoint: @escaping @Sendable (Int) throws -> Void) async throws -> URL {
        try requireAdmission(); try requireIdleWorker()
        guard try canPrepareVideo(id) else { throw ModelLibraryError.unavailable("此模型暂未提供原生准备操作。") }
        let original = try stored(id), entry = try entry(for: id)
        let source = try resolved(original)
        let scope = try ModelScopedLocation(selectedParent)
        let parent = try ModelDirectory(scope.url)
        let lease = ModelUsageLease(id: UUID(), modelID: id, reference: .init(directory: source.url, revision: entry.revision))
        leases[lease.id] = lease; disk.revision &+= 1
        let name = entry.id + "-" + UUID().uuidString
        let converter = wanPreparation
        let conversion = Task.detached {
            if ModelWanPreparation.supports(entry), let converter {
                return try await ModelWanPreparation.prepare(source: source, entry: entry, parent: parent, name: name,
                    externalRawProjection: original.record.storage == .external && ModelWanPreparation.allowsExternalRawProjection(entry), converter: converter)
            }
            return try ModelVideoPreparation.prepare(source: source, entry: entry, parent: parent, name: name, checkpoint: checkpoint)
        }
        let job = Task { [weak self] in
            try await withTaskCancellationHandler {
                let url = try await conversion.value
                guard let self else { throw CancellationError() }
                // The tracked operation includes inventory publication, so shutdown
                // drains this commit before releasing scopes and the source lease.
                try await self.recordPreparedOutput(url, parentID: id)
                return url
            } onCancel: { conversion.cancel() }
        }
        preparationJobs[id] = (job, lease, scope)
        let result = await withTaskCancellationHandler { await job.result } onCancel: { job.cancel() }
        finishPreparation(id, lease: lease, result: result)
        return try result.get()
    }
    private func finishPreparation(_ id: ModelID, lease: ModelUsageLease, result: Result<URL, any Error>) {
        if case .failure(let error) = result,
           case .resourceCleanupUnconfirmed = error as? InferenceFailure {
            // Retain the task, source lease and destination scope. A returned
            // error is not proof that the child process stopped using files.
            mutate(id) { $0.record.error = error.localizedDescription }
            return
        }
        if preparationJobs[id]?.lease.id == lease.id { preparationJobs.removeValue(forKey: id) }
        release(lease)
        scheduleDownloads()
    }
    public func acquire(_ id: ModelID) throws -> ModelUsageLease {
        let reference = try resolve(id)
        let lease = ModelUsageLease(id: UUID(), modelID: id, reference: reference)
        leases[lease.id] = lease; disk.revision &+= 1
        return lease
    }
    /// Pins an unchanged, verified raw installation for an optional backup.
    /// Preparation-required resources are valid backup sources, not inference inputs.
    public func acquireForBackup(_ id: ModelID) throws -> ModelUsageLease {
        try requireAdmission()
        let value = try stored(id)
        guard value.control?.role != .execution else {
            throw ModelLibraryError.unavailable("Prepared execution-package backup is not supported by this backup format. The original package can be backed up separately.")
        }
        guard value.deletion == nil, value.control?.fileState != .deleted, [.installed, .preparationRequired].contains(value.record.state) else {
            throw ModelLibraryError.unavailable("模型尚未完成安装和完整校验，不能备份。")
        }
        let directory = try resolved(value)
        let lease = ModelUsageLease(id: UUID(), modelID: id,
                                    reference: .init(directory: directory.url, revision: value.record.revision))
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
            disk.downloads?.removeAll { $0.resourceID.modelID == id }
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
        disk.downloads?.removeAll { $0.resourceID.modelID == id }
        do { try persist(); workers.removeValue(forKey: id) }
        catch { disk.records = previous; workerEnded(id, error: error) }
    }

    public func shutdown() async throws {
        accepting = false
        retryWake?.cancel(); retryWake = nil
        disk.queueState = .waitingForResume
        do {
            let preparing = preparationJobs
            for task in preparing.values { task.job.cancel() }
            for (id, task) in preparing {
                let result = await task.job.result
                finishPreparation(id, lease: task.lease, result: result)
            }
            let pending = Array(workers.values)
            for worker in pending { worker.cancel() }
            for worker in pending { await worker.value }
            if let copyJob {
                copyJob.cancel()
                _ = await copyJob.result
                while self.copyJob != nil { await Task.yield() }
            }
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
                let entry = try await self.entry(for: id)
                let directory = try ModelDirectory(scope.url)
                let job = Task.detached { try Self.verifyExternal(directory, entry: entry) }
                let verified = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                try Task.checkCancellation()
                await self.verified(id, directory: directory, files: verified.files, directories: verified.directories)
                await self.workerEnded(id, error: nil)
            } catch { await self.workerEnded(id, error: error) }
        }
    }
    private static func verifyExternal(_ directory: ModelDirectory, entry: ModelCatalogEntry) throws -> ModelRequiredTree {
        try directory.verifyRequired(entry.files)
    }

    private func verified(_ id: ModelID, directory: ModelDirectory, files: [String: ModelFileIdentity],
                          directories: [String: ModelFileIdentity]? = nil) {
        let needsPreparation = (try? entry(for: id).preparation) == .required
        mutate(id) {
            $0.needsWanTokenizerUpgrade = nil
            $0.control?.requiresTokenizerUpgrade = nil
            $0.verifiedRoot = directory.identity; $0.verifiedFiles = files; $0.verifiedDirectories = directories
            $0.record.directory = directory.url; $0.record.downloadedBytes = $0.record.totalBytes
            $0.record.state = needsPreparation && $0.control?.role != .execution ? .preparationRequired : .installed
            $0.record.error = nil; $0.record.availability = .available
            if $0.control == nil { $0.control = .init(fileState: .verified, origin: .local) }
            $0.control?.fileState = .verified; $0.control?.lastVerified = Date()

        }
    }
    private func workerEnded(_ id: ModelID, error: (any Error)?) {
        if let active = activeDownload, active.resource == id {
            finishDownload(active.task, attempt: active.attempt, generation: active.generation, error: error)
            return
        }
        if let error {
            if error is CancellationError { cancelledOperations.insert(id) }
            setState(id, error is CancellationError ? .paused : .failed)
            mutate(id) { $0.record.error = error is CancellationError ? nil : error.localizedDescription }
        }
        do { try persist() }
        catch { mutate(id) { $0.record.error = [$0.record.error, "状态保存失败：" + error.localizedDescription].compactMap { $0 }.joined(separator: "\n") } }
        workers.removeValue(forKey: id)
        scheduleDownloads()
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
            if try stored(id).needsWanTokenizerUpgrade == true {
                let stored = try stored(id)
                guard ModelWanPreparation.supports(entry), stored.record.storage == .managed,
                      stored.control?.role != .execution, !leases.values.contains(where: { $0.modelID == id }),
                      let previous = stored.precedingRecipeIdentity,
                      try Self.isWanTokenizerUpgrade(from: previous, to: entry) else {
                    throw ModelLibraryError.integrity("此旧执行包或外部资源需重新校验并准备；未写入原始目录。")
                }
                let existing = try candidate.entries(expectedPaths: Set(entry.files.map(\.path)))
                for (path, identity) in existing {
                    if let progress = stored.files[path], let file = entry.files.first(where: { $0.path == path }), progress.completed < file.size {
                        guard progress.identity.sameNode(identity), identity.size >= 0,
                              UInt64(identity.size) >= progress.completed,
                              UInt64(identity.size) <= min(file.size, progress.completed + Self.chunkBytes) else {
                            throw ModelLibraryError.integrity("Wan 分词资源断点已改变，未写入。")
                        }
                    } else {
                        guard let expected = stored.files[path]?.identity ?? stored.verifiedFiles[path], expected == identity else {
                            throw ModelLibraryError.integrity("Wan 升级前资源身份已改变，未写入。")
                        }
                    }
                }
                try requireSpace(entry.totalBytes - min(entry.totalBytes, stored.record.downloadedBytes))
                for file in entry.files {
                    if self.disk.records.first(where: { $0.record.id == id })?.files[file.path] == nil {
                        if let old = stored.verifiedFiles[file.path], old == existing[file.path] {
                            mutate(id) { $0.files[file.path] = .init(completed: file.size, identity: old) }
                        } else {
                            guard file.path.hasPrefix("google/umt5-xxl/"), existing[file.path] == nil else {
                                throw ModelLibraryError.integrity("Wan 升级只允许补充固定分词资源，未重写权重。")
                            }
                            try createDownloadLeaf(file.path, model: id, content: candidate)
                        }
                        try persist()
                    }
                }
                setState(id, .downloading); try persist()
                for file in entry.files { try await download(file, model: id, content: candidate, entry: entry) }
                try checkpoint("wanTokenizerUpgrade.directorySync")
                for path in ["google/umt5-xxl", "google"] {
                    let directory = try candidate.child(path)
                    guard fsync(directory.descriptor) == 0 else { throw ModelDirectory.failure("保存分词资源目录") }
                }
                guard fsync(candidate.descriptor) == 0 else { throw ModelDirectory.failure("保存模型目录") }
            }
            setState(id, .verifying)
            let job = Task.detached { try candidate.verify(entry.files) }
            let files = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
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
            try createDownloadLeaf(file.path, model: id, content: content)
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

    private func createDownloadLeaf(_ path: String, model id: ModelID, content: ModelDirectory) throws {
        let descriptor = try content.openFile(path, writing: true, create: true)
        let identity = try ModelDirectory.identity(descriptor, regular: true)
        Darwin.close(descriptor)
        mutate(id) { $0.files[path] = .init(completed: 0, identity: identity) }
        do {
            try checkpoint("download.createdLeaf")
            try persist()
        } catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            // This ledger was not published. Remove it even when unlink succeeded
            // but directory synchronization fails; never persist a ghost offset.
            mutate(id) { $0.files[path] = nil }
            do { try content.removeCreatedEmptyFile(path, expected: identity) }
            catch let cleanup { throw ModelLibraryError.storage(error.localizedDescription + "\n" + cleanup.localizedDescription) }
            throw error
        }
    }

    private func download(_ file: ModelFile, model id: ModelID, content: ModelDirectory, entry: ModelCatalogEntry) async throws {
        var offset = try stored(id).files[file.path]!.completed
        if offset == file.size {
            let fd = try content.openFile(file.path, writing: false); defer { Darwin.close(fd) }
            guard try ModelDirectory.identity(fd, regular: true) == stored(id).files[file.path]?.identity else {
                throw ModelLibraryError.integrity("完整模型文件身份已改变，未重新写入：\(file.path)")
            }
            return
        }
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
            let url = sourceURL(entry: entry, file: file, start: offset)
            var range = ModelByteRange(url: url, start: offset, end: end, total: file.size)
            if sourceBaseURL == nil, file.source != .githubRaw, let credential = downloadCredential {
                range.credential = credential
                range.authorizedPath = url.path
            }
            try await transport.download(range, to: fd)
            try Task.checkCancellation()
            try content.validateLocation()
            offset = end + 1
            let current = try ModelDirectory.identity(fd, regular: true)
            guard current.sameNode(expected.identity), current.size == offset else { throw ModelLibraryError.integrity("下载文件发生变化。") }
            progressMutation = true
            defer { progressMutation = false }
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
            let next = root.url.appendingPathComponent("Installations/" + disk.records[index].record.id.description)
            if let old = disk.records[index].record.directory, old.standardizedFileURL != next.standardizedFileURL {
                let prior = RetiredLocation(url: old, root: disk.records[index].verifiedRoot)
                disk.records[index].retiredLocations = (disk.records[index].retiredLocations ?? []) + [prior]
            }
            disk.records[index].record.directory = next
        }
    }

    /// Relocation preserves the actual directory, not merely a copied owner marker.
    /// Older v1 indexes are upgraded after checking their existing installation/file identities.
    private func validateRootIdentity(_ root: ModelDirectory) throws {
        let managed = disk.records.filter { $0.record.storage == .managed && $0.control?.fileState != .deleted && $0.deletion == nil }
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
        guard let identity = stored.verifiedRoot, identity.sameNode(directory.identity) else {
            throw ModelLibraryError.integrity("模型文件已改变或位置不符，请重新校验。")
        }
        let entry = try entry(for: stored.record.id)
        if stored.record.storage == .external {
            let current = try directory.requiredTree(paths: stored.control?.role == .execution ? Set(stored.verifiedFiles.keys) : Set(entry.files.map(\.path)))
            // Earlier external records tracked the exact root and leaves but no
            // parent map. Rehash those fixed leaves once before adopting parents.
            if stored.control?.role != .execution && (stored.verifiedDirectories?.isEmpty ?? true) && !current.directories.isEmpty {
                let verified = try directory.verifyRequired(entry.files)
                guard verified.files == stored.verifiedFiles,
                      verified == current else {
                    throw ModelLibraryError.integrity("旧模型记录的必要文件已改变，请重新校验。")
                }
                guard let index = disk.records.firstIndex(where: { $0.record.id == stored.record.id }) else {
                    throw ModelLibraryError.unavailable("模型记录不存在。")
                }
                let previous = disk.records[index].verifiedDirectories
                disk.records[index].verifiedDirectories = verified.directories
                do { try persist() }
                catch {
                    if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
                    disk.records[index].verifiedDirectories = previous
                    throw error
                }
            }
            let directories = disk.records.first(where: { $0.record.id == stored.record.id })?.verifiedDirectories ?? [:]
            guard current == ModelRequiredTree(files: stored.verifiedFiles, directories: directories) else {
                throw ModelLibraryError.integrity("模型必要文件或目录已改变，请重新校验。")
            }
        } else {
            guard try directory.entries(expectedPaths: Set(stored.verifiedFiles.keys)) == stored.verifiedFiles else {
                throw ModelLibraryError.integrity("模型文件已改变或位置不符，请重新校验。")
            }
        }
        return directory
    }
    private func sourceURL(entry: ModelCatalogEntry, file: ModelFile, start: UInt64) -> URL {
        if sourceBaseURL == nil, file.source == .githubRaw {
            return URL(string: "https://raw.githubusercontent.com")!
                .appendingPathComponent(file.sourceRepository ?? entry.repository)
                .appendingPathComponent(file.sourceRevision ?? entry.revision)
                .appendingPathComponent(file.remotePath ?? file.path)
        }
        let base = sourceBaseURL ?? URL(string: "https://huggingface.co")!
        var url = base.appendingPathComponent(file.sourceRepository ?? entry.repository).appendingPathComponent("resolve")
            .appendingPathComponent(file.sourceRevision ?? entry.revision).appendingPathComponent(file.remotePath ?? file.path)
        if sourceBaseURL == nil { url.append(queryItems: [.init(name: "download", value: "true"), .init(name: "d_range", value: String(start))]) }
        return url
    }
    private func requireSpace(_ remaining: UInt64) throws {
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库未配置。") }
        var status = statvfs()
        guard fstatvfs(root.descriptor, &status) == 0 else { throw ModelDirectory.failure("检查磁盘空间") }
        let available = availableBytesOverride ?? UInt64(status.f_bavail) * UInt64(status.f_frsize)
        let (required, overflow) = remaining.addingReportingOverflow(64 * 1024 * 1024)
        guard !overflow else { throw ModelLibraryError.invalidCatalog("模型总大小溢出。") }
        guard available >= required else { throw ModelLibraryError.insufficientSpace(required: required, available: available) }
    }
    private func persist(purpose: String = "state", afterRename: (@Sendable () throws -> Void)? = nil) throws {
        disk.revision &+= 1
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do {
            try checkpoint(purpose + ".beforeWrite")
            let checkpoint = self.checkpoint
            try stateDirectory.atomicWrite(encoder.encode(disk), to: "index.json", afterRename: {
                try checkpoint(purpose + ".afterRename"); try afterRename?()
            })
        }
        catch { queueError = "状态保存失败；队列已停止：" + error.localizedDescription; retryWake?.cancel(); throw error }
    }
    private func requireAdmission() throws { if !accepting { throw ModelLibraryError.busy("模型库正在关闭，请等待应用退出。") } }
    private func requireIdleWorker(allowingCleanup: ModelID? = nil) throws { if !workers.isEmpty || !preparationJobs.isEmpty || copyJob != nil || cleanupReservations.contains(where: { $0 != allowingCleanup }) { throw ModelLibraryError.busy("请先等待或暂停当前模型操作。") } }
    private func stored(_ id: ModelID) throws -> StoredRecord {
        guard let result = disk.records.first(where: { $0.record.id == id }) else { throw ModelLibraryError.unavailable("模型记录不存在。") }; return result
    }
    private func mutate(_ id: ModelID, _ body: (inout StoredRecord) -> Void) {
        if let index = disk.records.firstIndex(where: { $0.record.id == id }) { body(&disk.records[index]); disk.revision &+= 1 }
    }
    private func setState(_ id: ModelID, _ state: ModelInstallationState) {
        mutate(id) { $0.record.state = state; $0.record.error = nil }
        if let active = activeDownload, active.resource == id,
           let index = disk.downloads?.firstIndex(where: { $0.id == active.task }),
           let phase = ModelDownloadState(rawValue: state.rawValue), disk.downloads![index].state.isActive {
            disk.downloads![index].state = phase
        }
    }
    private func catalogEntry(_ id: String) throws -> ModelCatalogEntry {
        guard let value = catalog.first(where: { $0.id == id }) else { throw ModelLibraryError.invalidCatalog("不支持的模型目录条目。") }; return value
    }
    private func entry(for id: ModelID) throws -> ModelCatalogEntry { try catalogEntry(stored(id).record.catalogID) }
    private static func isWanTokenizerUpgrade(from recorded: String, to entry: ModelCatalogEntry) throws -> Bool {
        guard let frozen = try ModelCatalog.entries().first(where: { $0.id == "wan21-t2v-1.3b-bf16" }),
              entry == frozen, entry.files.count == 7 else { return false }
        let old = ModelCatalogEntry(id: entry.id, title: entry.title, repository: entry.repository, revision: entry.revision,
            files: Array(entry.files.prefix(3)), workflowProfileID: entry.workflowProfileID,
            workflowIdentity: entry.workflowIdentity, preparation: entry.preparation)
        return try recipeIdentity(old) == recorded
    }

    /// Only the eleven fixed companion-file URLs change. Local paths, bytes,
    /// digests, model identity and preparation are identical; no content rewrite.
    static func legacyACESourceEntry(_ entry: ModelCatalogEntry) -> ModelCatalogEntry {
        let files = entry.files.map { file in
            guard file.sourceRepository == "ACE-Step/Ace-Step1.5", let remote = file.remotePath else { return file }
            return ModelFile(path: file.path, size: file.size, sha256: file.sha256, digestAlgorithm: file.digestAlgorithm,
                sourceRepository: file.sourceRepository, sourceRevision: file.sourceRevision,
                remotePath: "checkpoints/" + remote, source: file.source)
        }
        return .init(id: entry.id, title: entry.title, repository: entry.repository, revision: entry.revision,
            files: files, imageProfile: entry.imageProfile, workflowProfileID: entry.workflowProfileID,
            workflowIdentity: entry.workflowIdentity, preparation: entry.preparation)
    }
    private static func isACESourceCorrection(from recorded: String, to entry: ModelCatalogEntry) throws -> Bool {
        guard entry.id == "ace-step-1.5-xl-sft-f32-no-lm",
              let frozen = try ModelCatalog.entries().first(where: { $0.id == entry.id }), entry == frozen else { return false }
        return try recipeIdentity(legacyACESourceEntry(entry)) == recorded
    }

    private static func recipeIdentity(_ entry: ModelCatalogEntry) throws -> String {
        struct Recipe: Encodable {
            let id: String
            let repository: String
            let revision: String
            let files: [ModelFile]
            let preparation: ModelPreparation
            let workflowProfileID: String?
            let workflowIdentity: String?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let recipe = Recipe(id: entry.id, repository: entry.repository, revision: entry.revision,
                            files: entry.files, preparation: entry.preparation,
                            workflowProfileID: entry.workflowProfileID, workflowIdentity: entry.workflowIdentity)
        return SHA256.hash(data: try encoder.encode(recipe)).map { String(format: "%02x", $0) }.joined()
    }
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
            guard validRepository(entry.repository), validRevision(entry.revision),
                  !entry.id.isEmpty, !entry.title.isEmpty,
                  !entry.files.isEmpty, entry.files.count <= 16_384,
                  Set(entry.files.map(\.path)).count == entry.files.count else { throw ModelLibraryError.invalidCatalog("模型版本或文件清单无效。") }
            let paths = Set(entry.files.map(\.path))
            var total: UInt64 = 0
            for file in entry.files {
                let parts = try ModelDirectory.parts(file.path)
                let (next, overflow) = total.addingReportingOverflow(file.size)
                total = next
                let digestLength = file.digestAlgorithm == .sha256 ? 64 : 40
                guard file.size > 0, file.size <= UInt64(Int64.max), !overflow, total <= UInt64(Int64.max),
                      file.sha256.count == digestLength, file.sha256.allSatisfy({ $0.isHexDigit }),
                      (file.sourceRepository == nil || validRepository(file.sourceRepository!)),
                      (file.sourceRevision == nil || validRevision(file.sourceRevision!)),
                      validRemotePath(file.remotePath ?? file.path),
                      !(1..<parts.count).contains(where: { paths.contains(parts.prefix($0).joined(separator: "/")) }) else {
                    throw ModelLibraryError.invalidCatalog("模型文件大小、摘要或路径冲突。")
                }
            }
        }
    }
    private static func validRepository(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." &&
            part.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
                ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 95 }
        }
    }
    private static func validRevision(_ revision: String) -> Bool {
        revision.count == 40 && revision.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
    private static func validRemotePath(_ path: String) -> Bool {
        guard (try? ModelDirectory.parts(path)) != nil else { return false }
        return path.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
            ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 47 || $0 == 95 }
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

// Resource commands and the single persistent download scheduler share the existing
// library lock, file ledger and atomic index. Views never own these tasks.
extension ModelLibrary {
    private func downloadForResource(_ id: ModelID) -> ModelDownloadTask? {
        guard let owner = disk.records.first(where: { $0.record.id == id })?.control?.downloadOwner else { return nil }
        return (disk.downloads ?? []).first { $0.resourceID.modelID == id && owner.matches($0) }
    }
    private func taskIndex(_ id: UUID) throws -> Int {
        guard let index = disk.downloads?.firstIndex(where: { $0.id == id }) else {
            throw ModelLibraryError.unavailable("下载任务已不存在。")
        }
        return index
    }
    private func event(_ id: ModelID, _ action: String, result: String? = nil) {
        mutate(id) {
            if $0.control == nil { $0.control = .init(fileState: .unchecked, origin: .local) }
            $0.control?.events.append(.init(action: action, date: now(), result: result))
            if ($0.control?.events.count ?? 0) > 24 { $0.control?.events.removeFirst() }
        }
    }
    public func enqueueDownloads(_ catalogIDs: [String], postAction: ModelDownloadPostAction = .filesOnly, startIfIdle: Bool = true) throws -> [ModelDownloadTask] {
        try requireAdmission()
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("请先选择模型库位置。") }
        try root.validateLocation()
        let previous = disk
        let wasEmpty = (disk.downloads ?? []).allSatisfy { $0.state.isTerminal }
        var result: [ModelDownloadTask] = []
        var registerExisting: [ModelResourceID] = []
        do {
        for catalogID in catalogIDs {
            let entry = try catalogEntry(catalogID), recipe = try Self.recipeIdentity(entry)
            let existing = disk.records.first { $0.record.storage == .managed && $0.record.catalogID == catalogID && $0.recipeIdentity == recipe && $0.control?.fileState != .deleted && $0.deletion == nil }
            let id: ModelID
            if let existing {
                guard !cleanupReservations.contains(existing.record.id) else { throw ModelLibraryError.busy("这份模型文件正在清理，请稍后重试。") }
                id = existing.record.id
            } else {
                try requireSpace(entry.totalBytes)
                id = ModelID()
                disk.records.append(StoredRecord(record: .init(id: id, catalogID: entry.id, revision: entry.revision,
                    storage: .managed, state: .queued, availability: .available, downloadedBytes: 0,
                    totalBytes: entry.totalBytes, error: nil, directory: nil, activeLeaseCount: 0,
                    registrationState: .unregistered), recipeIdentity: recipe,
                    control: .init(fileState: .partial, origin: .download)))
            }
            if let deadline = try stored(id).control?.retryNotBefore, deadline > now() {
                throw ModelLibraryError.busy("来源要求等待至 \(deadline.formatted()) 后再试。")
            }
            if let current = downloadForResource(id), !current.state.isTerminal {
                result.append(current); continue
            }
            if try stored(id).control?.fileState == .verified {
                if postAction == .register { registerExisting.append(.init(rawValue: id.rawValue)) }
                if let prior = downloadForResource(id) { result.append(prior) }
                continue // do not invent another successful download for existing files
            }
            let task = ModelDownloadTask(resourceID: .init(rawValue: id.rawValue), catalogID: catalogID, recipeIdentity: recipe, postAction: postAction, createdAt: now(), acquisitionSnapshot: try .init(entry: entry, recipeIdentity: recipe))
            disk.downloads = (disk.downloads ?? []) + [task]; result.append(task)
            mutate(id) { $0.control?.downloadOwner = .init(task) }
            event(id, "downloadRequested")
        }
        if startIfIdle, wasEmpty, disk.queueState == .waitingForResume { disk.queueState = .running }
        try persist(purpose: "enqueue")
        } catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            disk = previous; throw error
        }
        for id in registerExisting { try registerResource(id) }
        scheduleDownloads()
        return result
    }
    public func registerResource(_ resource: ModelResourceID) throws { try registerResource(resource, clearingTask: nil) }
    private func registerResource(_ resource: ModelResourceID, clearingTask: UUID?) throws {
        try requireAdmission()
        let id = resource.modelID, value = try stored(id)
        guard value.deletion == nil, value.control?.role != .execution, value.control?.fileState == .verified, value.record.state == .installed else {
            throw ModelLibraryError.unavailable("文件须完整校验并完成必要准备，才能登记。")
        }
        _ = try resolved(value)
        let previous = try stored(id), previousTasks = disk.downloads
        mutate(id) { $0.record.registrationState = .registered }
        event(id, "registered")
        if let clearingTask { disk.downloads![try taskIndex(clearingTask)].postActionError = nil }
        do { try persist(purpose: "registration") }
        catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            // Roll back the event together with registration. A later unrelated
            // save must not persist a success event for this failed command.
            mutate(id) { $0 = previous }; disk.downloads = previousTasks; throw error
        }
    }
    public func unregister(_ id: ModelID) throws {
        try requireAdmission()
        let value = try stored(id)
        guard !leases.values.contains(where: { $0.modelID == id }), workers[id] == nil,
              preparationJobs[id] == nil, currentCopy?.sourceID != id else {
            throw ModelLibraryError.busy("该资源正在使用、排队或准备，不能解除登记。")
        }
        mutate(id) { $0.record.registrationState = .unregistered }
        event(id, "unregistered")
        do { try persist() }
        catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            mutate(id) { $0 = value }; throw error
        }
    }
    /// Old URL caches must obey revocation too. Locate the exact known copy first;
    /// a missing/stale revision is never an escape from that copy's registration.
    public func acquireKnownResource(_ reference: ModelReference) throws -> ModelUsageLease? {
        try requireAdmission()
        let url = reference.directory.standardizedFileURL
        let physical = try? ModelDirectory(url).identity
        guard let value = disk.records.first(where: {
            $0.record.directory?.standardizedFileURL == url ||
                (physical != nil && $0.verifiedRoot?.sameNode(physical!) == true)
        }) else {
            if disk.records.contains(where: { value in
                (value.retiredLocations ?? []).contains { $0.url.standardizedFileURL == url || (physical != nil && $0.root?.sameNode(physical!) == true) }
            }) { throw ModelLibraryError.unavailable("This resource location was retired. Select the registered copy explicitly.") }
            return nil
        }
        let entry = try entry(for: value.record.id)
        let exactPitchContent = ModelCatalog.isPitch(entry) && value.record.revision == ModelCatalog.pitchSourceRevision
            && value.control?.role != .execution && reference.revision == PitchAnalysisRequest.modelSHA256
        guard exactPitchContent || reference.revision == (value.control?.executionRevision ?? value.record.revision) else {
            throw ModelLibraryError.unavailable("已知模型资源的版本引用不符。")
        }
        return try acquire(value.record.id)
    }
    public func clearDownloadHistory(_ ids: Set<UUID>) throws {
        try requireAdmission()
        for id in ids {
            guard (disk.downloads ?? []).first(where: { $0.id == id })?.state.isTerminal == true, activeDownload?.task != id,
                  !(disk.downloads ?? []).contains(where: { $0.id == id && cleanupReservations.contains($0.resourceID.modelID) }) else {
                throw ModelLibraryError.busy("只能清除已完成、失败或取消的下载记录。")
            }
        }
        let previous = disk.downloads
        disk.downloads?.removeAll { ids.contains($0.id) }
        do { try persist() } catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            disk.downloads = previous; throw error
        }
    }
    @discardableResult public func continueWanTokenizerUpgrade(_ resource: ModelResourceID) throws -> ModelDownloadTask {
        let value = try stored(resource.modelID)
        guard value.needsWanTokenizerUpgrade == true, value.control?.requiresTokenizerUpgrade == true,
              value.control?.role != .execution, let old = value.precedingRecipeIdentity,
              try Self.isWanTokenizerUpgrade(from: old, to: entry(for: resource.modelID)) else {
            throw ModelLibraryError.unavailable("该资源没有待补齐的分词资源。")
        }
        return try continuePartial(resource, resumeQueue: false)
    }
    @discardableResult public func continuePartial(_ resource: ModelResourceID, postAction: ModelDownloadPostAction? = nil, resumeQueue: Bool = true) throws -> ModelDownloadTask {
        try requireAdmission()
        let value = try stored(resource.modelID)
        guard !cleanupReservations.contains(resource.modelID), value.record.storage == .managed, value.deletion == nil, value.control?.fileState != .deleted else {
            throw ModelLibraryError.unavailable("该资源没有可继续的受管理下载。")
        }
        if let deadline = value.control?.retryNotBefore, deadline > now() {
            throw ModelLibraryError.busy("来源要求等待至 \(deadline.formatted()) 后再试。")
        }
        if let current = downloadForResource(resource.modelID), current.state.isActive { return current }
        let previous = disk
        do {
        let index: Int
        if let current = downloadForResource(resource.modelID), !current.state.isTerminal {
            index = try taskIndex(current.id)
            if let earliest = current.earliestRetry, earliest > now() {
                throw ModelLibraryError.busy("来源要求等待至 \(earliest.formatted()) 后再试。")
            }
            disk.downloads![index].state = .queued
            disk.downloads![index].automaticRetries = 0
            disk.downloads![index].earliestRetry = nil
        } else {
            var task = ModelDownloadTask(resourceID: resource, catalogID: value.record.catalogID,
                recipeIdentity: value.recipeIdentity!, postAction: postAction ?? downloadForResource(resource.modelID)?.postAction ?? .filesOnly, createdAt: now(),
                acquisitionSnapshot: downloadForResource(resource.modelID)?.acquisitionSnapshot)
            if value.control?.fileState == .verified { task.state = .completed; task.completedAt = now() }
            if let earliest = downloadForResource(resource.modelID)?.earliestRetry, earliest > now() {
                throw ModelLibraryError.busy("来源要求等待至 \(earliest.formatted()) 后再试。")
            }
            disk.downloads = (disk.downloads ?? []) + [task]; index = disk.downloads!.count - 1
        }
        let owner = ModelDownloadOwnership(disk.downloads![index])
        mutate(resource.modelID) { $0.control?.downloadOwner = owner }
        if resumeQueue { disk.queueState = .running }
        if disk.downloads![index].state == .queued { setState(resource.modelID, .queued) }
        try persist(); if resumeQueue { queueError = nil }
        let task = disk.downloads![index]
        if task.state == .completed { finishPostAction(task.id) }
        scheduleDownloads(); return task
        } catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            disk = previous; throw error
        }
    }
    /// A row owns an exact attempt. It may enqueue only that request, never resume
    /// a globally paused queue or silently target a newer attempt on the same files.
    @discardableResult public func continueDownload(_ id: UUID, expectedGeneration: UUID) throws -> ModelDownloadTask {
        let task = disk.downloads![try taskIndex(id)]
        guard task.generation == expectedGeneration, downloadForResource(task.resourceID.modelID)?.id == id,
              [.paused, .failed, .cancelled].contains(task.state) else {
            throw ModelLibraryError.busy("下载任务已改变，请重新查看当前任务。")
        }
        let resource = try stored(task.resourceID.modelID)
        guard resource.control?.fileState != .verified,
              ![.installed, .preparationRequired].contains(resource.record.state) else {
            throw ModelLibraryError.busy("模型文件已经完成；请到模型管理查看，不会重新开始旧下载记录。")
        }
        return try continuePartial(task.resourceID, postAction: task.postAction, resumeQueue: false)
    }
    public func restartDownload(_ id: UUID, expectedGeneration: UUID) async throws {
        try requireAdmission()
        let task = disk.downloads![try taskIndex(id)]
        guard task.generation == expectedGeneration, downloadForResource(task.resourceID.modelID)?.id == id,
              task.state == .failed || task.state == .cancelled,
              !cleanupReservations.contains(task.resourceID.modelID) else {
            throw ModelLibraryError.busy("下载任务已改变；未停止或清理其他任务。")
        }
        try await restart(task.resourceID.modelID, resumeQueue: false)
    }
    public func retryDownloadRegistration(_ id: UUID, expectedGeneration: UUID) throws {
        try requireAdmission()
        let index = try taskIndex(id), task = disk.downloads![index]
        guard task.generation == expectedGeneration, downloadForResource(task.resourceID.modelID)?.id == id,
              task.state == .completed, task.postAction == .register,
              !cleanupReservations.contains(task.resourceID.modelID) else { throw ModelLibraryError.busy("下载记录已改变。") }
        try registerResource(task.resourceID, clearingTask: id)
    }

    public func deleteDownload(_ id: UUID, expectedGeneration: UUID, cleanupPartial: Bool = false) async throws {
        try requireAdmission()
        let captured = disk.downloads![try taskIndex(id)]
        let resource = captured.resourceID
        guard captured.generation == expectedGeneration else { throw ModelLibraryError.busy("下载任务已改变，请重新查看。") }
        guard !cleanupReservations.contains(resource.modelID) else { throw ModelLibraryError.busy("这项任务正在处理文件。") }
        cleanupReservations.insert(resource.modelID)
        defer { cleanupReservations.remove(resource.modelID); scheduleDownloads() }
        func validatePartial() throws {
            let current = disk.downloads![try taskIndex(id)], value = try stored(resource.modelID)
            guard current.resourceID == resource, current.recipeIdentity == captured.recipeIdentity,
                  current.generation == captured.generation, current.attemptID == captured.attemptID,
                  downloadForResource(resource.modelID)?.id == captured.id, current.state != .completed, value.record.storage == .managed,
                  ([.partial, .invalid, .deleted].contains(value.control?.fileState) && value.deletion == nil ||
                   value.control?.fileState == .deleting && value.deletion?.path == "Staging/" + resource.modelID.description + "/Content"),
                  !leases.values.contains(where: { $0.modelID == resource.modelID }),
                  !(disk.downloads ?? []).contains(where: { $0.id != id && $0.resourceID == resource && !$0.state.isTerminal }),
                  let root = libraryRoot,
                  !(try Self.exists("Installations/" + resource.modelID.description, in: root)) else {
                throw ModelLibraryError.busy("文件已完成、正在使用或状态已改变。未删除文件或记录，请重新查看。")
            }
        }
        if cleanupPartial { try validatePartial() }
        if !captured.state.isTerminal { try await stopDownload(id, state: .cancelled) }
        if cleanupPartial {
            try validatePartial()
            do { try await deleteOwnedCopy(resource) }
            catch { throw ModelLibraryError.storage("未完成文件清理尚未完成，下载记录已保留。\n" + error.localizedDescription) }
        }
        // clearDownloadHistory also rejects our reservation. Remove only our own
        // reservation after all writes and optional cleanup have ended.
        cleanupReservations.remove(resource.modelID)
        do { try clearDownloadHistory([id]) } catch {
            guard cleanupPartial else { throw error }
            if case ModelAtomicWriteError.publishedButUnsynced = error {
                throw ModelLibraryError.storage("未完成文件已清理；记录删除后的同步未完成，请重新查看。\n" + error.localizedDescription)
            }
            throw ModelLibraryError.storage("未完成文件已清理，下载记录尚未删除。请重试删除记录。\n" + error.localizedDescription)
        }
    }
    public func moveWaitingDownload(_ id: UUID, before next: UUID?) throws {
        try requireAdmission()
        let index = try taskIndex(id), value = disk.downloads![index]
        guard value.state == .queued, value.attempts == 0 else { throw ModelLibraryError.busy("只有未开始的等待项可排序。") }
        if let next {
            let other = disk.downloads![try taskIndex(next)]
            guard other.id != id, other.state == .queued, other.attempts == 0 else { throw ModelLibraryError.busy("目标不是未开始的等待项。") }
        }
        disk.downloads!.remove(at: index)
        let destination = next.flatMap { next in disk.downloads!.firstIndex { $0.id == next } } ?? disk.downloads!.endIndex
        disk.downloads!.insert(value, at: destination); try persist()
    }
    public func pauseDownload(_ id: UUID) async throws {
        try await stopDownload(id, state: .paused)
    }
    public func cancelDownload(_ id: UUID, keepPartial: Bool = true) async throws {
        let resource = disk.downloads![try taskIndex(id)].resourceID
        if !keepPartial { cleanupReservations.insert(resource.modelID) }
        defer { if !keepPartial { cleanupReservations.remove(resource.modelID); scheduleDownloads() } }
        try await stopDownload(id, state: .cancelled)
        if !keepPartial {
            let task = disk.downloads![try taskIndex(id)]
            try await deleteOwnedCopy(task.resourceID)
        }
    }
    private func stopDownload(_ id: UUID, state: ModelDownloadState) async throws {
        try requireAdmission()
        let index = try taskIndex(id), task = disk.downloads![index]
        guard !task.state.isTerminal else { throw ModelLibraryError.busy("该任务已经结束。") }
        disk.downloads![index].state = state
        let worker = workers[task.resourceID.modelID]
        worker?.cancel()
        retryWake?.cancel(); retryWake = nil
        var failure: (any Error)?
        do { try persist() } catch { failure = error }
        await worker?.value
        if let failure { throw failure }
        scheduleDownloads()
    }
    public func pauseQueue() async throws {
        try requireAdmission()
        disk.queueState = .paused; queuePausing = true
        retryWake?.cancel(); retryWake = nil
        let worker = activeDownload.flatMap { workers[$0.resource] }
        worker?.cancel()
        var failure: (any Error)?
        do { try persist() } catch { failure = error }
        await worker?.value
        queuePausing = false
        if let failure { throw failure }
    }
    public func resumeQueue(includePaused: Bool = false) throws {
        try requireAdmission()
        guard !queuePausing else { throw ModelLibraryError.busy("队列仍在暂停，请等待写入结束。") }
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库磁盘不可用。") }
        try root.validateLocation()
        let previous = disk
        do {
            if includePaused {
                for index in (disk.downloads ?? []).indices where disk.downloads![index].state == .paused {
                    let id = disk.downloads![index].resourceID.modelID
                    let deadline = max(disk.downloads![index].earliestRetry ?? .distantPast, try stored(id).control?.retryNotBefore ?? .distantPast)
                    disk.downloads![index].state = deadline > now() ? .waitingRetry : .queued
                    disk.downloads![index].earliestRetry = deadline > now() ? deadline : nil
                    setState(id, .queued)
                }
            }
            disk.queueState = .running
            try persist()
        } catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            disk = previous; throw error
        }
        queueError = nil; scheduleDownloads()
    }
    private func scheduleDownloads() {
        retryWake?.cancel(); retryWake = nil
        guard accepting, queueError == nil, disk.queueState == .running, workers.isEmpty,
              preparationJobs.isEmpty, copyJob == nil, cleanupReservations.isEmpty else { return }
        let currentTime = now()
        if let index = disk.downloads?.firstIndex(where: { $0.state == .queued || ($0.state == .waitingRetry && ($0.earliestRetry ?? .distantFuture) <= currentTime) }) {
            let task = disk.downloads![index], id = task.resourceID.modelID
            let previous = disk
            do {
                guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库磁盘不可用，队列等待重新定位。") }
                try root.validateLocation()
                let record = try stored(id)
                guard record.deletion == nil, record.control?.fileState != .deleted, record.recipeIdentity == task.recipeIdentity,
                      record.control?.downloadOwner?.matches(task) == true else {
                    throw ModelLibraryError.integrity("下载资源已改变。")
                }
                disk.downloads![index].state = .downloading
                disk.downloads![index].attemptID = UUID(); disk.downloads![index].generation = UUID()
                disk.downloads![index].attempts += 1
                disk.downloads![index].earliestRetry = nil
                let owner = ModelDownloadOwnership(disk.downloads![index])
                mutate(id) { $0.control?.downloadOwner = owner }
                try persist(purpose: "dispatch")
                let started = disk.downloads![index]
                activeDownload = (started.id, started.attemptID, started.generation, id)
                launchInstallation(id)
            } catch {
                if case ModelAtomicWriteError.publishedButUnsynced = error {
                    // No worker was started. Keep the published identity, but make
                    // explicit queue recovery able to persist and dispatch it again.
                    disk.downloads![index].state = .queued
                } else { disk = previous }
                queueError = "队列等待处理：" + error.localizedDescription; disk.revision &+= 1
            }
            return
        }
        if let next = disk.downloads?.filter({ $0.state == .waitingRetry }).compactMap(\.earliestRetry).min() {
            let sleepUntil = self.sleepUntil
            retryWake = Task { [weak self] in
                do { try await sleepUntil(next) }
                catch { return }
                await self?.scheduleDownloads()
            }
        }
    }
    private func finishDownload(_ taskID: UUID, attempt: UUID, generation: UUID, error: (any Error)?) {
        guard let active = activeDownload, active.task == taskID, active.attempt == attempt, active.generation == generation,
              let index = disk.downloads?.firstIndex(where: { $0.id == taskID && $0.attemptID == attempt && $0.generation == generation && $0.resourceID.modelID == active.resource }) else { return }
        let id = active.resource
        if [.paused, .cancelled].contains(disk.downloads![index].state) {
            setState(id, .paused)
        } else if let error {
            if error is CancellationError {
                disk.downloads![index].state = queuePausing || !accepting ? .queued : .paused
                setState(id, .paused)
            } else {
                let message = error.localizedDescription
                disk.downloads![index].error = message
                if disk.downloads![index].firstError == nil { disk.downloads![index].firstError = message }
                disk.downloads![index].state = .failed
                if let deadline = (error as? ModelTransientDownloadError)?.retryAfter {
                    disk.downloads![index].earliestRetry = deadline
                    mutate(id) { value in
                        let previous = value.control?.retryNotBefore ?? .distantPast
                        value.control?.retryNotBefore = max(previous, deadline)
                    }
                }
                if let transient = error as? ModelTransientDownloadError, disk.downloads![index].automaticRetries < 3 {
                    let count = disk.downloads![index].automaticRetries
                    let deadline = max(now().addingTimeInterval([2.0, 5.0, 15.0][count]), transient.retryAfter ?? .distantPast)
                    disk.downloads![index].earliestRetry = deadline
                    if deadline.timeIntervalSince(now()) <= 3600 {
                        disk.downloads![index].automaticRetries += 1
                        disk.downloads![index].state = .waitingRetry
                    }
                }
                setState(id, .failed)
                mutate(id) { $0.record.error = message }
            }
        } else {
            disk.downloads![index].state = .completed; disk.downloads![index].completedAt = now()
            disk.downloads![index].error = nil
            event(id, "downloadCompleted")
        }
        var saved = false
        do { try persist(purpose: "completion"); saved = true }
        catch {
            if disk.downloads![index].state == .completed {
                disk.downloads![index].state = .paused
                disk.downloads![index].completedAt = nil
                disk.downloads![index].error = "文件已保留；完成状态保存未获确认，请继续核验。"
            }
        }
        workers.removeValue(forKey: id); activeDownload = nil
        if saved, disk.downloads![index].state == .completed { finishPostAction(taskID) }
        scheduleDownloads()
    }
    private func finishPostAction(_ id: UUID) {
        guard let index = try? taskIndex(id), disk.downloads![index].state == .completed,
              disk.downloads![index].postAction == .register else { return }
        do { try registerResource(disk.downloads![index].resourceID); disk.downloads![index].postActionError = nil }
        catch {
            disk.downloads![index].postActionError = error.localizedDescription
            mutate(disk.downloads![index].resourceID.modelID) { $0.record.registrationState = .pending }
        }
        do { try persist() } catch { /* download remains completed; secondary persistence error gates queue */ }
    }
    public func deleteOwnedCopy(_ resource: ModelResourceID) async throws {
        try requireAdmission(); try requireIdleWorker(allowingCleanup: resource.modelID)
        let id = resource.modelID, value = try stored(id)
        guard value.record.storage == .managed, !leases.values.contains(where: { $0.modelID == id }),
              !(disk.downloads ?? []).contains(where: { $0.resourceID == resource && !$0.state.isTerminal && $0.state != .paused }),
              !disk.records.contains(where: { $0.control?.parentResourceID == resource && $0.control?.fileState != .deleted }) else {
            throw ModelLibraryError.busy("该副本不受 D 管理，或仍有任务、准备副本及使用引用。")
        }
        guard value.control?.fileState != .deleted else { return }
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库磁盘不可用。") }
        if value.deletion == nil {
            let published = try Self.exists("Installations/" + id.description, in: root)
            let directory = published ? try resolved(value) : try stagingContent(id, create: true)
            let files = try directory.entries(expectedPaths: Set(try entry(for: id).files.map(\.path)))
            if !published {
                guard files.allSatisfy({ value.files[$0.key]?.identity.sameNode($0.value) == true }) else {
                    throw ModelLibraryError.unsafePath("暂存中有未知文件；未删除。")
                }
            }
            mutate(id) {
                $0.deletion = .init(path: published ? "Installations/" + id.description : "Staging/" + id.description + "/Content", root: directory.identity, files: files)
                $0.control?.fileState = .deleting; $0.record.availability = .unavailable
            }
            do { try persist(purpose: "deleteIntent") }
            catch {
                if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
                mutate(id) { $0 = value }; throw error
            } // no unlink is permitted until the intent is durable
        }
        try persist(purpose: "deleteIntent") // retries must also confirm durability before unlink
        let intent = try stored(id).deletion!
        // Actor does not yield through the destructive phase; no new lease/worker can enter.
        do {
            if try Self.exists(intent.path, in: root) {
                let directory = try root.child(intent.path)
                guard intent.root.sameNode(directory.identity) else { throw ModelLibraryError.unsafePath("删除目标身份已改变。") }
                try directory.removeRemainingKnownFiles(intent.files) { try checkpoint("delete.unlink." + $0) }
                let (parent, name) = try root.parent(intent.path); defer { Darwin.close(parent) }
                guard unlinkat(parent, name, AT_REMOVEDIR) == 0, fsync(parent) == 0 else { throw ModelDirectory.failure("删除空副本目录") }
            }
            mutate(id) { $0.control?.fileState = .deleted; $0.deletion = nil; $0.record.availability = .unavailable; $0.record.error = nil }
            event(id, "filesDeleted"); try persist(purpose: "deleteResult")
        } catch {
            mutate(id) { $0.record.error = "副本删除未完成：" + error.localizedDescription }
            try? persist(); throw error
        }
        scheduleDownloads()
    }
}


extension ModelLibrary {
    private func recordPreparedOutput(_ url: URL, parentID: ModelID) throws {
        let parent = try stored(parentID), scope = try ModelScopedLocation(url), directory = try ModelDirectory(scope.url)
        let files = try directory.entries()
        let tree = try directory.requiredTree(paths: Set(files.keys))
        let id = ModelID()
        var control = ModelResourceControl(fileState: .verified, origin: .prepared)
        control.role = .execution; control.parentResourceID = .init(rawValue: parentID.rawValue)
        control.preparationRecipe = parent.recipeIdentity; control.lastVerified = now(); control.requiredPaths = files.keys.sorted()
        // The preparer owns publication. Inventory conservatively treats the output
        // as external; this command never authorizes arbitrary output deletion.
        disk.records.append(StoredRecord(record: .init(id: id, catalogID: parent.record.catalogID, revision: parent.record.revision,
            storage: .external, state: .installed, availability: .available,
            downloadedBytes: files.values.reduce(0) { $0 + UInt64(max(0, $1.size)) },
            totalBytes: files.values.reduce(0) { $0 + UInt64(max(0, $1.size)) }, error: nil, directory: scope.url,
            activeLeaseCount: 0, registrationState: .unregistered), bookmark: scope.bookmark,
            recipeIdentity: parent.recipeIdentity, verifiedFiles: tree.files, verifiedDirectories: tree.directories,
            verifiedRoot: directory.identity, control: control))
        externalScopes[id] = scope; event(id, "prepared")
        try persist(purpose: "prepared")
    }
    public func registerPreparedResource(_ resource: ModelResourceID,
        validate: @escaping @Sendable (URL) async throws -> ModelReference) async throws {
        try requireAdmission(); try requireIdleWorker()
        let id = resource.modelID, original = try stored(id)
        guard original.control?.role == .execution, original.control?.fileState == .verified else {
            throw ModelLibraryError.unavailable("该资源不是已确认的执行包。")
        }
        let directory = try resolved(original)
        let lease = ModelUsageLease(id: UUID(), modelID: id, reference: .init(directory: directory.url, revision: original.record.revision))
        leases[lease.id] = lease
        // Keep the heavy-operation slot until adapter validation and persistence finish.
        workers[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let reference = try await validate(directory.url)
                try Task.checkCancellation()
                try await self.commitPreparedRegistration(id, reference: reference, original: original)
            } catch { await self.preparedRegistrationFailed(id, error: error) }
            await self.release(lease)
            await self.preparedRegistrationEnded(id)
        }
        let worker = workers[id]
        await withTaskCancellationHandler { await worker?.value } onCancel: { worker?.cancel() }
        if let error = try stored(id).record.error { throw ModelLibraryError.unavailable(error) }
    }
    private func commitPreparedRegistration(_ id: ModelID, reference: ModelReference, original: StoredRecord) throws {
        let current = try resolved(original)
        guard reference.directory.standardizedFileURL == current.url.standardizedFileURL, reference.revision?.isEmpty == false else {
            throw ModelLibraryError.integrity("执行包验证返回错误的资源身份。")
        }
        mutate(id) { $0.control?.executionRevision = reference.revision; $0.record.registrationState = .registered; $0.record.error = nil }
        event(id, "registered")
        do { try persist(purpose: "registration") }
        catch {
            if case ModelAtomicWriteError.publishedButUnsynced = error { throw error }
            mutate(id) { $0 = original }; throw error
        }
    }
    private func preparedRegistrationFailed(_ id: ModelID, error: any Error) {
        mutate(id) { $0.record.error = error.localizedDescription }; try? persist()
    }
    private func preparedRegistrationEnded(_ id: ModelID) { workers[id] = nil; scheduleDownloads() }
}

extension ModelLibrary {
    /// Explicit full verification, separate from registration and selection.
    public func reverifyResource(_ resource: ModelResourceID,
        preparedValidator: (@Sendable (URL) async throws -> ModelReference)? = nil) async throws {
        try requireAdmission(); try requireIdleWorker()
        let id = resource.modelID, original = try stored(id)
        guard !leases.values.contains(where: { $0.modelID == id }), original.deletion == nil,
              (original.control?.fileState != .partial || (original.needsWanTokenizerUpgrade == true && original.record.storage == .external && original.control?.role != .execution)),
              original.control?.fileState != .deleted else {
            throw ModelLibraryError.busy("资源正在使用、未完成或已删除，不能完整校验。")
        }
        // External rebind already verifies and preserves the original registration.
        if original.record.storage == .external {
            guard let url = original.record.directory else { throw ModelLibraryError.unavailable("原位置尚不可用。") }
            try await rebind(id, to: url, preparedValidator: preparedValidator)
            return
        }
        guard let root = libraryRoot else { throw ModelLibraryError.unavailable("模型库不可用。") }
        try root.validateLocation()
        let directory = try root.child("Installations/" + id.description)
        guard original.verifiedRoot?.sameNode(directory.identity) == true else { throw ModelLibraryError.unsafePath("原副本身份已改变。") }
        let entry = try entry(for: id)
        setState(id, .verifying); try persist()
        workers[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let job = Task.detached { try Self.verifyExternal(directory, entry: entry) }
                let tree = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                try Task.checkCancellation()
                await self.verified(id, directory: directory, files: tree.files, directories: tree.directories)
                await self.workerEnded(id, error: nil)
            } catch { await self.workerEnded(id, error: error) }
        }
        await workers[id]?.value
        if let error = try stored(id).record.error { throw ModelLibraryError.integrity(error) }
    }
    public func checkKnownResourceRegistration(_ reference: ModelReference) throws {
        if let lease = try acquireKnownResource(reference) { release(lease) }
    }
}
