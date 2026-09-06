import AppKit
import DWorkbench
import Foundation
import Observation

/// Native presentation for the model library. The actor owns installation tasks and leases;
/// dismissing a sheet does not cancel, pause, or detach any of that work.
@MainActor @Observable
public final class ModelLibraryModel {
    public var isPresented = false
    public var errorMessage: String?
    public private(set) var snapshot: ModelLibrarySnapshot?
    public private(set) var isChoosingLocation = false
    public private(set) var globalOperation: GlobalOperation?
    public private(set) var pendingActions: [ModelID: PendingAction] = [:]
    public private(set) var pendingCatalogIDs: Set<String> = []

    @ObservationIgnored public let library: ModelLibrary
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    public enum GlobalOperation: Sendable {
        case choosingRoot, registering

        public var title: String {
            switch self {
            case .choosingRoot: "正在连接模型库…"
            case .registering: "正在校验本地模型…"
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

    public init(library: ModelLibrary) { self.library = library }

    public var records: [ModelRecord] { snapshot?.records ?? [] }
    public var catalog: [ModelCatalogEntry] { snapshot?.catalog ?? [] }
    public var rootURL: URL? { snapshot?.rootURL }
    public var hasActiveWork: Bool {
        records.contains { record in
            switch record.state {
            case .queued, .downloading, .pausing, .verifying, .publishing: true
            default: false
            }
        }
    }
    public var activityCount: Int {
        records.filter { record in
            switch record.state {
            case .queued, .downloading, .pausing, .verifying, .publishing: true
            default: false
            }
        }.count
    }
    public var failedCount: Int { records.filter { $0.state == .failed }.count }
    public var isInUse: Bool { records.contains { $0.activeLeaseCount > 0 } }
    public var canChooseRoot: Bool {
        !isChoosingLocation && globalOperation == nil && pendingActions.isEmpty && !hasActiveWork && !isInUse
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
        snapshot = updated
    }

    public func clearError() { errorMessage = nil }

    public func chooseRoot() async {
        guard canChooseRoot else { return }
        isChoosingLocation = true
        let panel = NSOpenPanel()
        let reconnecting = records.contains { $0.storage == .managed }
        panel.title = reconnecting ? "重新定位模型库" : "选择模型库位置"
        panel.message = reconnecting
            ? "选择包含原有模型库的文件夹。当前支持原模型库在同一磁盘卷内移动后重新定位；跨盘搬迁尚未支持。"
            : "D 会在此文件夹内建立自己的模型库。建议选择空间充足的外置 SSD。"
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
        catch { report(error, context: "无法连接这个模型库位置") }
        await refresh()
    }

    public func registerExisting() async {
        guard !isChoosingLocation, globalOperation == nil, !hasActiveWork else { return }
        isChoosingLocation = true
        let panel = NSOpenPanel()
        panel.title = "登记已有模型"
        panel.message = "选择完整的 FLUX.2 Klein 4B q8 文件夹。D 会校验文件并保留原来的存放位置。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let response = await panel.begin()
        isChoosingLocation = false
        guard response == .OK, let url = panel.url else { return }
        await registerExisting(at: url)
    }

    public func registerExisting(at url: URL) async {
        guard !isChoosingLocation, globalOperation == nil, !hasActiveWork else { return }
        globalOperation = .registering
        defer { globalOperation = nil }
        do { _ = try await library.registerExisting(at: url) }
        catch ModelLibraryError.operationPaused { }
        catch { report(error, context: "未能登记此模型，请确认文件完整且属于受支持的版本") }
        await refresh()
    }

    public func install(catalogID: String) async {
        guard !isChoosingLocation, rootURL != nil, globalOperation == nil, !pendingCatalogIDs.contains(catalogID) else { return }
        pendingCatalogIDs.insert(catalogID)
        defer { pendingCatalogIDs.remove(catalogID) }
        do { _ = try await library.install(catalogID: catalogID) }
        catch { report(error, context: "未能开始安装") }
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
        alert.messageText = "从头下载这个模型？"
        alert.informativeText = "已下载但尚未完成安装的进度将被清除，然后重新下载 \(Self.formatBytes(record.totalBytes))。"
        alert.addButton(withTitle: "重新下载")
        alert.addButton(withTitle: "保留当前进度")
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
        panel.title = "重新定位模型"
        panel.message = "选择这个模型当前所在的文件夹。D 会重新校验内容，保留模型在项目中的身份。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = record.directory?.deletingLastPathComponent()
        let response = await panel.begin()
        isChoosingLocation = false
        guard response == .OK, let url = panel.url else { return }
        await perform(.relinking, id: id) { try await self.library.rebind(id, to: url) }
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
        record.state == .installed && record.availability == .available && pendingActions[record.id] == nil
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
        case .installed: return "已安装"
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
        catch { report(error, context: "模型操作未完成") }
        await refresh()
    }

    private func report(_ error: Error, context: String) {
        errorMessage = "\(context)。\n\(error.localizedDescription)"
    }
}
