import AppKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

enum ProjectFilesPresentation {
    static func selectedStatus(_ item: AssetLocationOverview) -> AssetLocationStatus? {
        item.locations.first(where: { $0.id == item.selectedLocationID })?.status
    }
    static func allSucceeded(_ values: [AssetRelocationResult]) -> Bool {
        values.allSatisfy(\.matched)
    }
}

@MainActor
enum NativeAssetImportPanel {
    static func choose(language: UILanguageStore?) async -> (URL, AssetImportMode)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = language?.text("files.import.title", fallback: "导入素材") ?? "导入素材"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28))
        picker.addItems(withTitles: [
            language?.text("files.import.copy", fallback: "复制到项目（默认）") ?? "复制到项目（默认）",
            language?.text("files.import.reference", fallback: "引用原位置") ?? "引用原位置"
        ])
        let note = NSTextField(labelWithString: language?.text("files.import.warning",
            fallback: "引用需要保留原文件和磁盘连接；不会移动或删除原件。") ?? "引用需要保留原文件和磁盘连接；不会移动或删除原件。")
        note.lineBreakMode = .byWordWrapping
        let accessory = NSStackView(views: [picker, note])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        accessory.frame = NSRect(x: 0, y: 0, width: 350, height: 64)
        panel.accessoryView = accessory
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        return (url, picker.indexOfSelectedItem == 1 ? .reference : .copy)
    }
}

/// The sheet owns only presentation state. Every operation captures its original Store and
/// discards completion UI when the active project has changed.
@MainActor
struct ProjectFilesView: View {
    let store: ProjectStore
    let instanceID: UUID
    let isActive: () -> Bool
    let modelLibrary: ModelLibrary
    let onContentsChanged: @MainActor (ProjectStore, UUID) async -> Void
    let onOpenRestored: (URL) async -> String?
    let onClose: () -> Void
    var initialAssetID: UUID? = nil

    @Environment(\.dLanguageStore) private var language
    @State private var overview: ProjectFileOverview?
    @State private var selectedAssetID: UUID?
    @State private var message: String?
    @State private var results: [AssetRelocationResult] = []
    @State private var receipt: ProjectBackupReceipt?
    @State private var restoredURL: URL?
    @State private var models: [ModelRecord] = []
    @State private var modelTitles: [String: String] = [:]
    @State private var chosenModels: Set<ModelID> = []
    @State private var pendingBackup: (URL, [ModelID], [String])?
    @State private var pendingRestore: (URL, URL)?
    @State private var job: Task<Void, Never>?
    @State private var busy = false

    private func word(_ key: String, _ fallback: String) -> String {
        language?.text("files." + key, fallback: fallback) ?? fallback
    }
    private var selected: AssetLocationOverview? { overview?.assets.first { $0.asset.id == selectedAssetID } }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
    private func date(_ value: Date?) -> String { value?.formatted(date: .abbreviated, time: .shortened) ?? word("unknown", "未知") }
    private func role(_ value: AssetLocationRole) -> String {
        switch value {
        case .externalOriginal: word("role.original", "外部原件")
        case .independentCopy: word("role.library", "独立资料库副本")
        case .projectCopy: word("role.project", "项目内副本")
        }
    }
    private func status(_ value: AssetLocationStatus) -> String {
        switch value {
        case .verified: word("status.verified", "已核对")
        case .pendingVerification: word("status.pending", "待核对")
        case .offline: word("status.offline", "磁盘离线")
        case .needsAuthorization: word("status.authorization", "需要授权")
        case .missing: word("status.missing", "文件缺失")
        case .changed: word("status.changed", "内容已变")
        case .corrupt: word("status.corrupt", "位置无效")
        case .previewOnly: word("status.preview", "仅预览")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(word("back", "返回"), action: onClose).keyboardShortcut(.cancelAction)
                Text(word("title", "项目文件与位置")).font(.title2.bold())
                Spacer()
                if busy { ProgressView() }
                Button(word("cancel", "取消当前操作")) { job?.cancel() }.disabled(!busy)
            }
            if let overview {
                Text("\(word("external", "外部引用")) \(overview.externalCount) · \(word("collectBytes", "收纳需复制")) \(bytes(overview.bytesToCollect))")
                    .font(.headline)
                HStack(alignment: .top, spacing: 14) {
                    List(overview.assets, id: \.asset.id, selection: $selectedAssetID) { item in
                        VStack(alignment: .leading) {
                            Text(item.asset.name)
                            Text(ProjectFilesPresentation.selectedStatus(item).map(status) ?? word("unknown", "未知"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(item.asset.id)
                    }.frame(minWidth: 220)
                    ScrollView { if let selected { inspector(selected) } else { Text(word("choose", "选择素材查看位置")) } }
                        .frame(minWidth: 370, maxWidth: .infinity)
                }
                HStack {
                    Button(word("collectAll", "收纳项目媒体…")) { collectAll() }.disabled(busy || overview.externalCount == 0)
                    Button(word("findFolder", "从所选文件夹定位…")) { relocateFolder() }.disabled(busy)
                    Spacer()
                    Button(word("backup", "创建手动备份…")) { prepareBackup() }.disabled(busy)
                    Button(word("restore", "恢复手动备份…")) { prepareRestore() }.disabled(busy)
                }
            } else { ProgressView(word("loading", "读取项目文件…")) }
            if !models.isEmpty {
                DisclosureGroup(word("models", "可选：包含模型资源（默认不选）")) {
                    ForEach(models, id: \.id) { record in
                        let eligible = (record.state == .installed || record.state == .preparationRequired)
                            && record.availability == .available
                        Toggle(isOn: Binding(get: { chosenModels.contains(record.id) }, set: { enabled in
                            if enabled { chosenModels.insert(record.id) } else { chosenModels.remove(record.id) }
                        })) {
                            Text("\(modelTitles[record.catalogID] ?? record.catalogID) · \(bytes(record.totalBytes))")
                        }.disabled(!eligible || busy)
                        if record.state == .preparationRequired {
                            Text(word("rawUnavailable", "原始资源可随备份保留；恢复后仍需准备才能用于推理。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(word("modelsNote", "恢复后 Models 文件夹不会自动登记；请在模型库正常登记。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !results.isEmpty {
                Text(word("results", "逐项结果")).font(.headline)
                ForEach(results) { result in Text("\(result.matched ? "✓" : "⚠") \(result.message)").textSelection(.enabled) }
            }
            if let receipt {
                Text(receipt.complete ? word("backupComplete", "备份／恢复完成") : word("backupPartial", "不完整备份／恢复"))
                    .font(.headline)
                Text(receipt.directory.path).textSelection(.enabled)
                Text("\(receipt.fileCount) · \(bytes(receipt.byteCount))")
                ForEach(receipt.missing, id: \.self) { Text($0).textSelection(.enabled) }
            }
            if let restoredURL {
                Button(word("openRestored", "打开已恢复项目")) {
                    Task { if let error = await onOpenRestored(restoredURL) { message = error } }
                }
                    .disabled(busy)
            }
            if let message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(20).frame(minWidth: 760, minHeight: 520)
        .task(id: instanceID) { await refresh(deep: false); await loadModels() }
        .onDisappear { job?.cancel() }
        .alert(word("incomplete", "备份缺少文件"), isPresented: Binding(get: { pendingBackup != nil }, set: { if !$0 { pendingBackup = nil } })) {
            Button(word("cancel", "取消"), role: .cancel) { pendingBackup = nil }
            Button(word("continueIncomplete", "明确创建不完整备份")) {
                if let pendingBackup { runBackup(at: pendingBackup.0, models: pendingBackup.1, allowIncomplete: true) }
                pendingBackup = nil
            }
        } message: { Text(pendingBackup?.2.joined(separator: "\n") ?? "") }
        .alert(word("restoreIncomplete", "恢复可能缺少文件"), isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button(word("cancel", "取消"), role: .cancel) { pendingRestore = nil }
            Button(word("continueIncomplete", "明确恢复不完整备份")) {
                if let pendingRestore { runRestore(from: pendingRestore.0, to: pendingRestore.1, allowIncomplete: true) }
                pendingRestore = nil
            }
        } message: { Text(word("restoreWarning", "仅显式继续才会保留缺失项；结果将标为不完整。")) }
    }
    @ViewBuilder private func inspector(_ item: AssetLocationOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.asset.name).font(.headline)
            Text("\(word("knownUse", "本项目已知图与历史使用")) \(item.knownUseCount)")
            Text("SHA-256: \(item.contentSHA256 ?? word("unknown", "未知"))").font(.caption.monospaced()).textSelection(.enabled)
            Text("\(word("size", "已知字节")): \(item.byteCount.map(bytes) ?? word("unknown", "未知"))")
            ForEach(item.locations) { location in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(location.id == item.selectedLocationID ? "●" : "○")
                        Text(location.location.libraryName).bold()
                        Text(role(location.location.role))
                        Spacer()
                        Text(status(location.status))
                    }
                    Text(location.resolvedURL?.path ?? location.location.url?.path ?? word("unknown", "未知"))
                        .font(.caption).textSelection(.enabled)
                    if let reason = location.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
                    Text("\(word("registered", "登记")): \(date(location.location.registeredAt)) · \(word("verified", "上次核对")): \(date(location.location.lastVerifiedAt)) · \(word("created", "文件创建")): \(date(location.location.contentCreatedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    if location.id != item.selectedLocationID {
                        Button(word("useLocation", "核对并使用此位置")) { useLocation(item.asset.id, location.id) }.disabled(busy)
                    }
                }.padding(8).background(Color.secondary.opacity(0.08)).cornerRadius(8)
            }
            HStack {
                Button(word("verify", "核对内容")) { start(deepRefresh: true) { store in
                    _ = try await store.assetLocationOverview(item.asset.id, deep: true)
                    return word("verifiedNow", "内容核对完成；位置状态已刷新。")
                } }.disabled(busy)
                Button(word("findFile", "定位同内容文件…")) { relocateFile(item.asset.id) }.disabled(busy)
                Button(word("collectOne", "复制入项目…")) { start { store in
                    try await store.collectAsset(item.asset.id)
                    return word("collected", "已复制入项目；原件保留。")
                } }.disabled(busy)
                Button(word("copyLibrary", "复制到独立资料库…")) { collectToFolder(item.asset.id) }.disabled(busy)
            }
            Text(word("changedNote", "若字节不同，请作为新素材导入；旧记录不会自动替换。"))
                .font(.caption).foregroundStyle(.secondary)
            Button(word("importNew", "作为新素材导入…")) {
                Task {
                    guard let (url, mode) = await NativeAssetImportPanel.choose(language: language) else { return }
                    start { store in
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        _ = try await store.importWorkflowMediaFile(at: url, mode: mode)
                        return word("importedNew", "已登记新素材；原记录保留。")
                    }
                }
            }.disabled(busy)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func refresh(deep: Bool) async {
        do {
            let value = try await store.projectFileOverview(deep: deep)
            guard isActive() else { return }
            overview = value
            if selectedAssetID == nil { selectedAssetID = initialAssetID ?? value.assets.first?.asset.id }
        } catch { if isActive() { message = error.localizedDescription } }
    }
    private func loadModels() async {
        let snapshot = await modelLibrary.snapshot()
        guard isActive() else { return }
        models = snapshot.records
        modelTitles = Dictionary(uniqueKeysWithValues: snapshot.catalog.map { ($0.id, $0.title) })
    }
    private func start(deepRefresh: Bool = false,
                       _ operation: @escaping @MainActor (ProjectStore) async throws -> String) {
        guard !busy, isActive() else { return }
        busy = true; message = nil; results = []
        let captured = store
        job = Task {
            do {
                let text = try await operation(captured)
                if isActive() { message = text }
            } catch is CancellationError { if isActive() { message = word("cancelled", "操作已取消；请查看刷新后的状态确认已完成项。") } }
            catch { if isActive() { message = error.localizedDescription } }
            await onContentsChanged(captured, instanceID)
            if isActive() { await refresh(deep: deepRefresh) }
            busy = false; job = nil
        }
    }
    private func chooseFolder(_ title: String) async -> URL? {
        let panel = NSOpenPanel(); panel.title = title
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        return await panel.begin() == .OK ? panel.url : nil
    }
    private func relocateFile(_ id: UUID) {
        Task {
            let panel = NSOpenPanel(); panel.title = word("findFile", "定位同内容文件…")
            panel.canChooseDirectories = false
            guard await panel.begin() == .OK, let url = panel.url else { return }
            start { store in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await store.relocateAsset(id, to: url)
                return word("relocated", "已核对同一内容版本。")
            }
        }
    }
    private func relocateFolder() {
        Task {
            guard let url = await chooseFolder(word("findFolder", "从所选文件夹定位…")) else { return }
            start { store in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try await store.relocateAssets(in: url)
                if isActive() { results = values }
                return ProjectFilesPresentation.allSucceeded(values) ? word("relocated", "已核对同一内容版本。") : word("partial", "部分项目未匹配，原位置保留。")
            }
        }
    }
    private func useLocation(_ id: UUID, _ location: UUID) {
        start { store in try await store.useAssetLocation(id, locationID: location); return word("locationChosen", "已使用核对通过的位置。") }
    }
    private func collectToFolder(_ id: UUID) {
        Task {
            guard let url = await chooseFolder(word("copyLibrary", "复制到独立资料库…")) else { return }
            start { store in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await store.collectAsset(id, to: url)
                return word("libraryCopied", "独立副本已登记；原件保留。")
            }
        }
    }
    private func collectAll() {
        start { store in
            let values = try await store.collectProjectMedia()
            if isActive() { results = values }
            return ProjectFilesPresentation.allSucceeded(values) ? word("collected", "已复制入项目；原件保留。") : word("partial", "部分素材未收纳；查看逐项结果。")
        }
    }
    private func prepareBackup() {
        Task {
            let panel = NSSavePanel(); panel.title = word("backup", "创建手动备份…")
            panel.nameFieldStringValue = "D-Backup.dbackup"
            panel.canCreateDirectories = true
            guard await panel.begin() == .OK, let url = panel.url else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else { message = word("exists", "目标已存在；请选择新名称。"); return }
            let ids = Array(chosenModels)
            busy = true
            job = Task {
                do {
                    let plan = try await store.backupPlan()
                    guard isActive() else { busy = false; job = nil; return }
                    busy = false; job = nil
                    if !plan.missing.isEmpty { pendingBackup = (url, ids, plan.missing) }
                    else { runBackup(at: url, models: ids, allowIncomplete: false) }
                } catch is CancellationError {
                    if isActive() { message = word("cancelled", "操作已取消。") }
                    busy = false; job = nil
                } catch {
                    if isActive() { message = error.localizedDescription }
                    busy = false; job = nil
                }
            }
        }
    }
    private func runBackup(at url: URL, models ids: [ModelID], allowIncomplete: Bool) {
        start { store in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let value = try await store.createBackup(at: url, modelLibrary: modelLibrary,
                includingModels: ids, allowIncomplete: allowIncomplete)
            if isActive() { receipt = value }
            return value.complete ? word("backupComplete", "备份完成") : word("backupPartial", "不完整备份已创建")
        }
    }
    private func prepareRestore() {
        Task {
            let source = NSOpenPanel(); source.title = word("restore", "恢复手动备份…")
            source.canChooseFiles = false; source.canChooseDirectories = true
            guard await source.begin() == .OK, let backup = source.url else { return }
            let destination = NSSavePanel(); destination.title = word("restoreDestination", "选择新的 .dproject 位置")
            destination.nameFieldStringValue = "Restored.dproject"
            destination.allowedContentTypes = [UTType(filenameExtension: "dproject") ?? .package]
            guard await destination.begin() == .OK, let target = destination.url else { return }
            guard !FileManager.default.fileExists(atPath: target.path) else { message = word("exists", "目标已存在；请选择新名称。"); return }
            runRestore(from: backup, to: target, allowIncomplete: false)
        }
    }
    private func runRestore(from backup: URL, to target: URL, allowIncomplete: Bool) {
        guard !busy, isActive() else { return }
        busy = true; message = nil
        job = Task {
            let sourceAccess = backup.startAccessingSecurityScopedResource()
            let targetAccess = target.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { backup.stopAccessingSecurityScopedResource() }
                if targetAccess { target.stopAccessingSecurityScopedResource() }
                busy = false; job = nil
            }
            do {
                let value = try await ProjectStore.restoreBackup(at: backup, to: target,
                    allowIncomplete: allowIncomplete)
                guard isActive() else { return }
                receipt = value
                restoredURL = target
                message = value.complete ? word("restoreComplete", "恢复完成。可打开独立项目；模型权重请在模型库登记。")
                    : word("restorePartial", "不完整恢复已保留；请检查缺失项。")
            } catch is CancellationError { if isActive() { message = word("cancelled", "操作已取消。") } }
            catch ProjectBackupError.invalidPackage(let reason) where !allowIncomplete && reason.contains("incomplete backup") {
                if isActive() { pendingRestore = (backup, target) }
            } catch { if isActive() { message = error.localizedDescription } }
        }
    }
}
