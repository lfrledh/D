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
    private(set) var selectionTitle: String?
    @ObservationIgnored private var selectionIsCurrent: (() -> Bool)?
    var currentSelectionTitle: String? { selectionIsCurrent?() == true ? selectionTitle : nil }
    func captureSelectionPresentation(_ title: String, isCurrent: @escaping () -> Bool) {
        selectionTitle = title; selectionIsCurrent = isCurrent
    }
    func presentationEntry(for record: ModelRecord) -> ModelCatalogEntry? {
        catalog.first { $0.id == record.catalogID && $0.revision == record.revision }
    }
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

    /// Only explicit node-button requests live here. Never inferred from a draft
    /// or restored across launch; the existing queue remains the work owner.
    private struct NodePreparation {
        let token = UUID()
        let entry: ModelCatalogEntry
        let resource: ModelResourceID
        let isCurrent: @MainActor () -> Bool
        let bind: @MainActor (ModelID, @escaping @MainActor () -> Bool) async throws -> Void
    }
    @ObservationIgnored private var nodePreparations: [String: NodePreparation] = [:]
    @ObservationIgnored private var reconcilingNodePreparations = false
    @ObservationIgnored private var nodePreparationRevocations: [ModelResourceID: UInt64] = [:]
    private(set) var preparingNodeIdentities: Set<String> = []
    let nodePreparationPresentation = WorkflowModelPreparationState()

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
        if snapshot != updated { snapshot = updated }
        updateNodePreparationPresentation(updated)
        await reconcileNodePreparations(updated)
    }

    private func updateNodePreparationPresentation(_ snapshot: ModelLibrarySnapshot) {
        let resources = Dictionary(grouping: snapshot.resources, by: { $0.record.catalogID + "@" + $0.record.revision })
        let tasks = Dictionary(grouping: snapshot.downloads, by: \.resourceID)
        var values: [String: WorkflowModelPreparation] = [:]
        var byResource: [ModelID: WorkflowModelPreparation] = [:]
        for entry in snapshot.catalog {
            guard let identity = entry.workflowIdentity else { continue }
            let candidates = resources[entry.id + "@" + entry.revision] ?? []
            for resource in candidates {
                byResource[resource.record.id] = .make(record: resource.record, control: resource.control,
                    task: tasks[resource.id]?.last, requiresPreparation: entry.preparation != .none)
            }
            if let requested = nodePreparations[identity]?.resource {
                values[identity] = byResource[requested.modelID] ?? .init(resource: requested, taskID: nil, attemptID: nil,
                    phase: "copyUnavailable", completed: nil, total: nil, issue: nil)
            } else if candidates.count == 1, let resource = candidates.first { values[identity] = byResource[resource.record.id] }
            else if candidates.count > 1 { values[identity] = .init(resource: nil, taskID: nil, attemptID: nil, phase: "ambiguousCopies", completed: nil, total: nil, issue: nil) }
        }
        nodePreparationPresentation.replace(values, resources: byResource)
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
        alert.messageText = managed ? managementText("removeManagedTitle") : managementText("removeExternalTitle")
        alert.informativeText = managed
            ? managementText("removeManagedMessage")
            : managementText("removeExternalMessage")
        alert.addButton(withTitle: managed ? managementText("removeManaged") : managementText("removeExternal"))
        alert.addButton(withTitle: managementText("keep"))
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
    public func clearSelectionContext() { selectionTitle = nil; selectionIsCurrent = nil; selectionAction = nil; configurationSelectionAction = nil; selectionID = nil }
    public func presentManagement() {
        clearSelectionContext()
        workspace = "resources"
        loadInventory()
        isPresented = true
    }
    public func presentDownloads() {
        clearSelectionContext(); workspace = "downloads"; loadInventory(); isPresented = true
    }
    public func loadInventory() {
        do { readOnlyConfigurations = try inventoryProvider?() ?? [] } catch { errorMessage = error.localizedDescription }
    }
    public func presentSelection(selected: ModelID? = nil, action: @escaping @MainActor (ModelID) async -> Void) {
        clearSelectionContext(); workspace = "resources"; loadInventory()
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

    static func nodeDownloadEntry(operationID: String, identity: String,
                                  catalog: [ModelCatalogEntry]) -> ModelCatalogEntry? {
        guard let choice = WorkflowModelRoutes.draftChoice(operationID: operationID, modelID: identity),
              WorkflowRegistry.standard.operation(operationID)?.definition.modelKind == choice.kind else { return nil }
        let matches = catalog.filter { $0.workflowIdentity == identity && $0.workflowProfileID == operationID }
        return matches.count == 1 ? matches.first : nil
    }

    func prepareNode(operationID: String, identity: String,
                     isCurrent: @escaping @MainActor () -> Bool,
                     bind: @escaping @MainActor (ModelID, @escaping @MainActor () -> Bool) async throws -> Void) async {
        guard isCurrent(), !preparingNodeIdentities.contains(identity) else { return }
        preparingNodeIdentities.insert(identity)
        let revocations = nodePreparationRevocations
        defer { if nodePreparations[identity] == nil { preparingNodeIdentities.remove(identity) } }
        do {
            await refresh()
            guard isCurrent(), let entry = Self.nodeDownloadEntry(operationID: operationID, identity: identity, catalog: catalog) else {
                throw WorkflowIssue(nodeText("unavailable", "此配置没有内置下载，或目标已改变。已有文件和节点保留。"))
            }
            if rootURL == nil { await chooseRoot() }
            guard isCurrent(), rootURL != nil else { return }
            guard !isChoosingLocation, globalOperation == nil else {
                throw WorkflowIssue(nodeText("busy", "请等待当前模型库操作完成后重试。"))
            }
            // Initialization can suspend in refresh or directory authorization.
            // Until the exact copy is known, any explicit revocation invalidates
            // this pending request before enqueue can register an existing copy.
            guard nodePreparationRevocations == revocations else { return }
            // The original queue/post-action remains authoritative. An existing
            // files-only task is not silently rewritten by enqueueDownloads.
            let tasks = try await library.enqueueDownloads([entry.id], postAction: .register)
            let current = await library.snapshot()
            guard isCurrent() else { throw WorkflowIssue(nodeText("targetChanged", "目标已改变；下载和文件保留，未绑定到其他节点。")) }
            let candidates = current.resources.filter {
                $0.record.catalogID == entry.id && $0.record.revision == entry.revision
                    && $0.record.storage == .managed && $0.control.role == .original
                    && $0.control.fileState != .deleted && $0.control.fileState != .deleting
            }
            let resource = tasks.first?.resourceID ?? (candidates.count == 1 ? candidates.first?.id : nil)
            guard let resource, candidates.contains(where: { $0.id == resource }) else {
                throw WorkflowIssue(nodeText("copyChanged", "模型副本无法唯一确认；资源保留，请在模型与下载中检查。"))
            }
            guard nodePreparationRevocations[resource, default: 0] == revocations[resource, default: 0] else { return }
            nodePreparations[identity] = .init(entry: entry, resource: resource, isCurrent: isCurrent, bind: bind)
            selectedResource = resource; selectedTask = tasks.first?.id; workspace = "downloads"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func nodeText(_ key: String, _ fallback: String) -> String {
        workflowText(language, "workflow.node.prepare." + key, fallback: fallback)
    }
    private func reconcileNodePreparations(_ current: ModelLibrarySnapshot) async {
        guard !reconcilingNodePreparations else { return }
        reconcilingNodePreparations = true
        defer { reconcilingNodePreparations = false }
        for (identity, request) in nodePreparations {
            var finished = false
            defer {
                if finished, nodePreparations[identity]?.token == request.token {
                    nodePreparations[identity] = nil; preparingNodeIdentities.remove(identity)
                }
            }
            do {
                guard request.isCurrent() else { throw WorkflowIssue(nodeText("targetChanged", "目标已改变；下载和文件保留，未绑定到其他节点。")) }
                guard let resource = current.resources.first(where: { $0.id == request.resource }),
                      resource.record.catalogID == request.entry.id, resource.record.revision == request.entry.revision,
                      resource.control.fileState != .deleted && resource.control.fileState != .deleting else {
                    throw WorkflowIssue(nodeText("copyChanged", "模型副本无法唯一确认；资源保留，请在模型与下载中检查。"))
                }
                let download = current.downloads.last { $0.resourceID == request.resource }
                if let download, download.state == .failed || download.state == .cancelled {
                    throw WorkflowIssue(download.error ?? nodeText("stopped", "下载已停止；节点与已下载文件保留。请明确重试。"))
                }
                guard resource.control.fileState == .verified else { continue }
                if request.entry.preparation != .none {
                    preparationNotice = nodeText("needsPreparation", "文件已取得，仍须在模型与下载中准备执行包；节点尚未就绪。")
                    finished = true; continue
                }
                guard resource.record.state == .installed else { continue }
                guard nodePreparations[identity]?.token == request.token else { continue }
                if resource.record.registrationState != .registered {
                    if let error = download?.postActionError { throw WorkflowIssue(error) }
                    // Explicit authorization from this request also covers an
                    // already-running files-only task after its exact copy finishes.
                    try await library.registerResource(request.resource)
                }
                guard request.isCurrent(), nodePreparations[identity]?.token == request.token else {
                    throw WorkflowIssue(nodeText("targetChanged", "目标已改变；下载和文件保留，未绑定到其他节点。"))
                }
                try await request.bind(resource.record.id) { [weak self] in
                    self?.nodePreparations[identity]?.token == request.token && request.isCurrent()
                }
                guard nodePreparations[identity]?.token == request.token else { continue }
                preparationNotice = nodeText("ready", "此节点的模型副本已登记并通过校验；尚未运行计算。")
                finished = true
            } catch {
                errorMessage = error.localizedDescription; finished = true
            }
        }
    }

    public func registerResource(_ resource: ModelResource) async {
        await command {
            if resource.control.role == .execution {
                guard let validate = self.preparedValidator else { throw ModelLibraryError.unavailable(self.managementText("prepareUnavailable", "执行包验证引擎尚不可用。")) }
                try await self.library.registerPreparedResource(resource.id, validate: validate)
            } else { try await self.library.registerResource(resource.id) }
        }
    }
    private func revokeNodePreparation(_ resource: ModelResourceID) {
        nodePreparationRevocations[resource, default: 0] &+= 1
        for (identity, request) in nodePreparations where request.resource == resource {
            nodePreparations[identity] = nil; preparingNodeIdentities.remove(identity)
        }
    }
    public func unregisterResource(_ resource: ModelResource) async {
        revokeNodePreparation(resource.id)
        await command { try await self.library.unregister(resource.record.id); self.preparationNotice = self.managementText("unregisteredReceipt", "已解除登记。文件仍在原位置；作品和生成记录保留。") }
    }
    public func deleteResource(_ resource: ModelResource) async {
        revokeNodePreparation(resource.id)
        await command { try await self.library.deleteOwnedCopy(resource.id); self.preparationNotice = self.managementText("deletedReceipt", "已删除此副本。登记保留但不可用；其他副本及作品保留。") }
    }
    public func continueResource(_ resource: ModelResource) async {
        await command { _ = try await self.library.continuePartial(resource.id) }
    }
    public func pauseTask(_ id: UUID) async { await command { try await self.library.pauseDownload(id) } }
    public func cancelTask(_ id: UUID, keepPartial: Bool) async {
        if let resource = snapshot?.downloads.first(where: { $0.id == id })?.resourceID { revokeNodePreparation(resource) }
        await command { try await self.library.cancelDownload(id, keepPartial: keepPartial) } }
    public func clearTask(_ id: UUID) async {
        if let task = snapshot?.downloads.first(where: { $0.id == id }), task.state == .failed || task.state == .cancelled {
            revokeNodePreparation(task.resourceID)
        }
        await command { try await self.library.clearDownloadHistory([id]); self.preparationNotice = self.managementText("clearedReceipt", "已清除一条下载历史。文件、登记和资源来源信息保留。") } }
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
    func managementText(_ key: String, _ fallback: String = "") -> String {
        workflowText(language, "modelManagement." + key, fallback: fallback)
    }
}
