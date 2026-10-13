import AppKit
import DWorkbench
import DInference
import Foundation
import Observation
import SwiftUI

/// Native presentation for the model library. The actor owns installation tasks and leases;
/// dismissing a sheet does not cancel, pause, or detach any of that work.
@MainActor @Observable
public final class ModelLibraryModel {
    public var isPresented = false
    public var workspace = "resources"
    public var resourceSearch = ""
    public var taskSearch = ""
    public var resourceFilter = "all"
    public var taskFilter = "all"
    public var resourceListScroll = ScrollPosition()
    public var taskListScroll = ScrollPosition()
    public var resourceDetailScroll = ScrollPosition()
    public var taskDetailScroll = ScrollPosition()
    public var selectedResource: ModelResourceID?
    public var selectedTask: UUID?
    public var selectionID: ModelID?
    public private(set) var readOnlyConfigurations: [ModelReadOnlyConfiguration] = []
    @ObservationIgnored public var inventoryProvider: (@MainActor () throws -> [ModelReadOnlyConfiguration])?
    @ObservationIgnored public var explicitRegistration: (@MainActor (URL, WorkflowModelKind) async throws -> Void)?
    @ObservationIgnored public var configurationSelectionAction: (@MainActor (ModelReadOnlyConfiguration) async -> Void)?
    @ObservationIgnored public var selectionAction: (@MainActor (ModelID) async -> Void)?
    @ObservationIgnored public var preparedValidator: (@Sendable (URL) async throws -> ModelReference)?
    @ObservationIgnored private let language: UILanguageStore?
    public var errorMessage: String?
    public private(set) var preparationNotice: String?
    public private(set) var snapshot: ModelLibrarySnapshot?
    public private(set) var isChoosingLocation = false
    public private(set) var globalOperation: GlobalOperation?
    public private(set) var pendingActions: [ModelID: PendingAction] = [:]
    public private(set) var pendingCatalogIDs: Set<String> = []

    @ObservationIgnored public let library: ModelLibrary
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    public enum GlobalOperation: Sendable {
        case choosingRoot, choosingCredential, registering, copying, preparing

        public var title: String {
            switch self {
            case .choosingRoot: "正在连接模型库…"
            case .choosingCredential: "正在连接下载令牌…"
            case .registering: "正在校验本地模型…"
            case .copying: "正在校验并复制必要模型文件…"
            case .preparing: "正在准备并校验独立执行包…"
            }
        }
    }

    public enum PendingAction: Sendable {
        case pausing, resuming, retrying, restarting, relinking, removing

        public var title: String {
            switch self {
            case .pausing: "正在暂停…"
            case .resuming: "正在恢复下载…"
            case .retrying: "正在重试…"
            case .restarting: "正在重新下载…"
            case .relinking: "正在校验新位置…"
            case .removing: "正在移除…"
            }
        }
    }

    public init(library: ModelLibrary, language: UILanguageStore? = nil) { self.library = library; self.language = language }

    public var records: [ModelRecord] { snapshot?.records ?? [] }
    public var catalog: [ModelCatalogEntry] { snapshot?.catalog ?? [] }
    public var rootURL: URL? { snapshot?.rootURL }
    public var downloadCredentialConnected: Bool { snapshot?.downloadCredentialConnected ?? false }
    public var copyProgress: ModelCopyProgress? { snapshot?.copyProgress }
    public var hasActiveWork: Bool { activityCount > 0 }
    public var activityCount: Int { Self.activityCount(in: snapshot) }
    static func activityCount(in snapshot: ModelLibrarySnapshot?) -> Int {
        // Waiting records are not executing work. They can remain queued after
        // queue pause or cancellation; treating them as busy blocks recovery UI.
        // Conversely, the scheduler can own an active task before its legacy
        // record phase changes. Count either source once per resource.
        let recordIDs = (snapshot?.records ?? []).compactMap { record -> ModelID? in
            switch record.state {
            case .downloading, .pausing, .verifying, .publishing: record.id
            default: nil
            }
        }
        let downloadIDs = (snapshot?.downloads ?? []).filter { $0.state.isActive }
            .map { $0.resourceID.modelID }
        return Set(recordIDs + downloadIDs).count + (snapshot?.copyProgress == nil ? 0 : 1)
    }
    public var failedCount: Int { records.filter { $0.state == .failed }.count }
    public var isInUse: Bool { records.contains { $0.activeLeaseCount > 0 } }
    public var canChooseRoot: Bool {
        !isChoosingLocation && globalOperation == nil && pendingActions.isEmpty && !hasActiveWork && !isInUse
    }
    public var canChangeDownloadCredential: Bool {
        !isChoosingLocation && globalOperation == nil && pendingActions.isEmpty && !hasActiveWork
    }

    public func chooseDownloadCredential() async {
        guard canChangeDownloadCredential else { return }
        isChoosingLocation = true
        let panel = NSOpenPanel()
        panel.title = managementText("tokenTitle", "选择 Hugging Face 下载令牌文件")
        panel.message = managementText("tokenMessage", "选择只包含一个令牌的纯文本文件。D 仅保存文件授权，下载时读取令牌；不会保存令牌内容。")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let response = await panel.begin()
        isChoosingLocation = false
        guard !Task.isCancelled else { return }
        guard response == .OK, let url = panel.url else { return }
        globalOperation = .choosingCredential
        defer { globalOperation = nil }
        do { try await library.connectDownloadCredential(at: url) }
        catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            report(error, context: managementText("tokenConnectFailed", "未能连接下载令牌"))
        }
        guard !Task.isCancelled else { return }
        await refresh()
    }

    public func removeDownloadCredential() async {
        guard canChangeDownloadCredential else { return }
        globalOperation = .choosingCredential
        defer { globalOperation = nil }
        do { try await library.disconnectDownloadCredential() }
        catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            report(error, context: managementText("tokenDisconnectFailed", "未能移除下载令牌连接"))
        }
        guard !Task.isCancelled else { return }
        await refresh()
    }

    /// Called by the app composition root, independently of a manager sheet's lifetime.
    public func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard self != nil, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
        }
    }

    public func stop() { poller?.cancel(); poller = nil }

    public func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let updated = await library.snapshot()
        guard generation == refreshGeneration, updated.revision >= (snapshot?.revision ?? 0) else { return }
        // Keep native menu tracking intact while idle. Compare all visible values,
        // including transient copy progress, so real readiness changes still publish.
        guard snapshot != updated else { return }
        snapshot = updated
    }

    public func clearError() { errorMessage = nil }

    public func chooseRoot() async {
        guard canChooseRoot else { return }
        isChoosingLocation = true
        let panel = NSOpenPanel()
        let reconnecting = records.contains { $0.storage == .managed }
        panel.title = reconnecting ? managementText("relocateTitle", "重新定位模型库") : managementText("rootTitle", "选择模型库位置")
        panel.message = reconnecting
            ? managementText("relocateMessage", "选择包含原有模型库的文件夹。当前支持原模型库在同一磁盘卷内移动后重新定位；跨盘搬迁尚未支持。")
            : managementText("rootMessage", "D 会在此文件夹内建立自己的模型库。建议选择空间充足的外置 SSD。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        let response = await panel.begin()
        isChoosingLocation = false
        guard response == .OK, let url = panel.url else { return }
        await configureRoot(at: url)
    }

    public func configureRoot(at url: URL) async {
        guard canChooseRoot else { return }
        globalOperation = .choosingRoot
        defer { globalOperation = nil }
        do { try await library.configureRoot(at: url) }
        catch { report(error, context: managementText("rootFailed", "无法连接这个模型库位置")) }
        await refresh()
    }

    public func registerExisting(catalogID: String = ModelCatalog.flux2ID,
                                 storage: ModelStorageKind = .external) async {
        guard !isChoosingLocation, globalOperation == nil, !hasActiveWork else { return }
        guard let entry = catalog.first(where: { $0.id == catalogID }) else {
            errorMessage = "所选模型不在固定目录中。"; return
        }
        isChoosingLocation = true
        let panel = NSOpenPanel()
        panel.title = managementText("importPrefix", "登记已有模型") + ": " + entry.title
        panel.message = storage == .external
            ? managementText("importExternalMessage", "选择此模型的准确文件夹；校验必要文件并保留原位置。")
            : managementText("importCopyMessage", "选择此模型的准确文件夹；校验后复制到模型库，保留原件。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let response = await panel.begin()
        isChoosingLocation = false
        guard response == .OK, let url = panel.url else { return }
        await registerExisting(at: url, catalogID: catalogID, storage: storage)
    }

    public func registerExisting(at url: URL, catalogID: String = ModelCatalog.flux2ID,
                                 storage: ModelStorageKind = .external) async {
        guard !isChoosingLocation, globalOperation == nil, !hasActiveWork else { return }
        globalOperation = storage == .external ? .registering : .copying
        let task = Task { @MainActor in
            do { _ = try await library.registerExisting(at: url, catalogID: catalogID, storage: storage) }
            catch is CancellationError { }
            catch ModelLibraryError.operationPaused { }
            catch { report(error, context: managementText("importFailed", "未能登记此模型，请确认文件完整且属于受支持的版本")) }
        }
        importTask = task
        await task.value
        importTask = nil; globalOperation = nil
        await refresh()
    }

    public func copyExisting(_ id: ModelID) async {
        guard !isChoosingLocation, globalOperation == nil, !hasActiveWork else { return }
        if rootURL == nil { await chooseRoot() }
        guard rootURL != nil else { return }
        globalOperation = .copying
        let task = Task { @MainActor in
            do { _ = try await library.copyExistingToLibrary(id) }
            catch is CancellationError { }
            catch { report(error, context: managementText("copyFailed", "复制未完成；原位置登记仍保留")) }
        }
        importTask = task
        await task.value
        importTask = nil; globalOperation = nil
        await refresh()
    }

    public func cancelImport() { importTask?.cancel() }

    public func prepareVideo(_ id: ModelID, action: @escaping @MainActor (ModelID, URL) async throws -> Void) async {
        guard canChooseRoot else { return }
        isChoosingLocation = true
        do {
            guard try await library.canPrepareVideo(id) else {
                throw ModelLibraryError.unavailable("当前应用没有该模型的完整准备引擎，或原始文件尚未校验；请使用本阶段的完整开发资源重新构建。原文件未修改。")
            }
        } catch {
            isChoosingLocation = false
            report(error, context: managementText("prepareNotAvailable", "执行包准备尚不可用"))
            return
        }
        let panel = NSOpenPanel()
        panel.title = managementText("preparedTitle", "选择执行包存放位置")
        panel.message = managementText("preparedMessage", "D 将创建独立执行包并校验文件，保留原始模型。优先使用同一 APFS 外盘；不会加载模型。")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        let response = await panel.begin(); isChoosingLocation = false
        guard response == .OK, let parent = panel.url else { return }
        globalOperation = .preparing; preparationNotice = nil
        let task = Task { @MainActor in
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
            do {
                try await action(id, parent)
                try Task.checkCancellation()
                preparationNotice = managementText("preparedNotice", "独立执行包已准备并保留。请另行登记后选用；原始文件保留。")
            }
            catch is CancellationError { }
            catch { self.report(error, context: managementText("prepareFailed", "执行包准备未完成")) }
        }
        preparation = task
        await task.value
        preparation = nil; globalOperation = nil
        await refresh()
    }
    public func cancelPreparation() { preparation?.cancel() }
    public func install(catalogID: String) async {
        guard !isChoosingLocation, rootURL != nil, globalOperation == nil, !pendingCatalogIDs.contains(catalogID) else { return }
        pendingCatalogIDs.insert(catalogID)
        defer { pendingCatalogIDs.remove(catalogID) }
        do { _ = try await library.install(catalogID: catalogID) }
        catch { report(error, context: managementText("installFailed", "未能开始安装")) }
        await refresh()
    }

    public func pause(_ id: ModelID) async {
        await perform(.pausing, id: id) { try await self.library.pause(id) }
    }

    public func resume(_ id: ModelID) async {
        await perform(.resuming, id: id) { try await self.library.resume(id) }
    }

    public func retry(_ id: ModelID) async {
        await perform(.retrying, id: id) { try await self.library.retry(id) }
    }

    public func restart(_ id: ModelID) async {
        guard !isChoosingLocation, pendingActions[id] == nil, let record = records.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = managementText("restartTitle", "从头下载这个模型？")
        alert.informativeText = managementText("restartMessage", "清除本项已保存进度后从头下载。已保存字节：") + Self.formatBytes(record.downloadedBytes)
        alert.addButton(withTitle: managementText("restartButton", "重新下载"))
        alert.addButton(withTitle: managementText("keepProgress", "保留当前进度"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await perform(.restarting, id: id) { try await self.library.restart(id) }
    }

    public func relink(_ id: ModelID) async {
        guard !isChoosingLocation, globalOperation == nil, pendingActions[id] == nil,
              let record = records.first(where: { $0.id == id }), record.activeLeaseCount == 0 else { return }
        if record.storage == .managed {
            await chooseRoot()
            return
        }
        isChoosingLocation = true
        let panel = NSOpenPanel()
        panel.title = managementText("relinkTitle", "重新定位模型")
        panel.message = managementText("relinkMessage", "选择这个模型当前所在的文件夹。D 会重新校验内容，保留模型在项目中的身份。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = record.directory?.deletingLastPathComponent()
        let response = await panel.begin()
        isChoosingLocation = false
        guard response == .OK, let url = panel.url else { return }
        await perform(.relinking, id: id) { try await self.library.rebind(id, to: url, preparedValidator: self.preparedValidator) }
    }

    public func remove(_ id: ModelID) async {
        guard !isChoosingLocation, pendingActions[id] == nil,
              let record = records.first(where: { $0.id == id }), record.activeLeaseCount == 0 else { return }
        let managed = record.storage == .managed
        let alert = NSAlert()
        alert.messageText = managed ? "移除模型或下载文件？" : "取消这个模型的登记？"
        alert.informativeText = managed
            ? "这份模型由 D 管理的已安装文件或未完成下载将被移除。作品和生成记录会保留；以后重新安装时需要再次下载。"
            : "仅从 D 的模型库中取消登记。原文件、作品和生成记录都会保留。"
        alert.addButton(withTitle: managed ? "移除模型或下载文件" : "取消登记")
        alert.addButton(withTitle: "保留")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await perform(.removing, id: id) { try await self.library.remove(id) }
    }

    public func entry(for record: ModelRecord) -> ModelCatalogEntry? {
        catalog.first { $0.id == record.catalogID }
    }

    public func canUse(_ record: ModelRecord) -> Bool {
        ModelLibrarySelection.canUse(record, entry: entry(for: record),
                                     hasPendingAction: pendingActions[record.id] != nil)
    }

    public func status(for record: ModelRecord) -> String {
        if let action = pendingActions[record.id] { return action.title }
        if record.availability == .needsAuthorization { return "需要重新授权" }
        if record.availability == .unavailable { return "存放位置不可用" }
        switch record.state {
        case .registered: return "已登记，等待校验"
        case .queued: return "等待下载"
        case .downloading: return "正在下载"
        case .pausing: return "正在暂停，等待写入结束"
        case .paused: return "已暂停"
        case .verifying: return "正在校验完整性"
        case .publishing: return "正在完成安装"
        case .installed: return "文件已校验；执行引擎需单独验证"
        case .preparationRequired: return "原始文件已校验；仍需准备"
        case .failed: return "操作未完成"
        }
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func perform(_ action: PendingAction, id: ModelID,
                         operation: () async throws -> Void) async {
        guard !isChoosingLocation, pendingActions[id] == nil, globalOperation != .choosingRoot else { return }
        pendingActions[id] = action
        defer { pendingActions.removeValue(forKey: id) }
        do { try await operation() }
        catch ModelLibraryError.operationPaused { }
        catch { report(error, context: managementText("operationFailed", "模型操作未完成")) }
        await refresh()
    }

    private func report(_ error: Error, context: String) {
        errorMessage = "\(context)。\n\(error.localizedDescription)"
    }
}

extension ModelLibraryModel {
    public func clearSelectionContext() { selectionAction = nil; configurationSelectionAction = nil; selectionID = nil }
    public func presentManagement() {
        clearSelectionContext()
        loadInventory()
        isPresented = true
    }
    public func loadInventory() {
        do { readOnlyConfigurations = try inventoryProvider?() ?? [] } catch { errorMessage = error.localizedDescription }
    }
    public func presentSelection(selected: ModelID? = nil, action: @escaping @MainActor (ModelID) async -> Void) {
        clearSelectionContext(); loadInventory()
        selectionAction = action; selectionID = selected; isPresented = true
    }
    public func importConfiguration(kind: WorkflowModelKind) async {
        guard !isChoosingLocation, globalOperation == nil, let register = explicitRegistration else { return }
        isChoosingLocation = true
        let panel = NSOpenPanel()
        panel.title = managementText("importExact", "登记已有精确配置…")
        panel.message = managementText("importExactHelp", "沿用现有引擎的精确校验。保留原位置，不自动选用，不创建下载任务。")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        let response = await panel.begin(); isChoosingLocation = false
        guard response == .OK, let url = panel.url else { return }
        globalOperation = .registering
        defer { globalOperation = nil }
        let task = Task { @MainActor in await command { try await register(url, kind) } }
        importTask = task
        await task.value
        importTask = nil
        loadInventory()
    }
    public func move(_ id: UUID, by offset: Int) async {
        let waiting = snapshot?.downloads.filter { $0.state == .queued && $0.attempts == 0 } ?? []
        guard let index = waiting.firstIndex(where: { $0.id == id }), waiting.indices.contains(index + offset) else { return }
        let before = offset < 0 ? waiting[index - 1].id : (index + 2 < waiting.count ? waiting[index + 2].id : nil)
        await command { try await self.library.moveWaitingDownload(id, before: before) }
    }
    public func reverify(_ resource: ModelResource) async {
        await command { try await self.library.reverifyResource(resource.id, preparedValidator: self.preparedValidator) }
    }
    public func reveal(_ resource: ModelResource) {
        guard let url = resource.record.directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    public func enqueue(_ entries: [String], register: Bool) async {
        await command { _ = try await self.library.enqueueDownloads(entries, postAction: register ? .register : .filesOnly) }
    }
    public func registerResource(_ resource: ModelResource) async {
        await command {
            if resource.control.role == .execution {
                guard let validate = self.preparedValidator else { throw ModelLibraryError.unavailable(self.managementText("prepareUnavailable", "执行包验证引擎尚不可用。")) }
                try await self.library.registerPreparedResource(resource.id, validate: validate)
            } else { try await self.library.registerResource(resource.id) }
        }
    }
    public func unregisterResource(_ resource: ModelResource) async {
        await command { try await self.library.unregister(resource.record.id); self.preparationNotice = self.managementText("unregisteredReceipt", "已解除登记。文件仍在原位置；作品和生成记录保留。") }
    }
    public func deleteResource(_ resource: ModelResource) async {
        await command { try await self.library.deleteOwnedCopy(resource.id); self.preparationNotice = self.managementText("deletedReceipt", "已删除此副本。登记保留但不可用；其他副本及作品保留。") }
    }
    public func continueResource(_ resource: ModelResource) async {
        await command { _ = try await self.library.continuePartial(resource.id) }
    }
    public func pauseTask(_ id: UUID) async { await command { try await self.library.pauseDownload(id) } }
    public func cancelTask(_ id: UUID, keepPartial: Bool) async { await command { try await self.library.cancelDownload(id, keepPartial: keepPartial) } }
    public func clearTask(_ id: UUID) async { await command { try await self.library.clearDownloadHistory([id]); self.preparationNotice = self.managementText("clearedReceipt", "已清除一条下载历史。文件、登记和资源来源信息保留。") } }
    public func pauseQueue() async { await command { try await self.library.pauseQueue() } }
    public func resumeQueue() async { await command { try await self.library.resumeQueue() } }
    public func moveNext(_ id: UUID) async {
        let next = snapshot?.downloads.first { $0.id != id && $0.state == .queued && $0.attempts == 0 }?.id
        await command { try await self.library.moveWaitingDownload(id, before: next) }
    }
    public func prepareResource(_ id: ModelID) async {
        await prepareVideo(id) { id, parent in _ = try await self.library.prepareVideo(id, in: parent) }
    }
    private func command(_ body: () async throws -> Void) async {
        errorMessage = nil
        do { try await body() } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        await refresh()
    }
    func managementText(_ key: String, _ fallback: String) -> String {
        language?.text("modelManagement." + key, fallback: fallback) ?? fallback
    }
}
