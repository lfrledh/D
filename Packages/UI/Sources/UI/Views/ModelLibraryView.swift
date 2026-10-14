import DWorkbench
import SwiftUI

/// One application-owned inventory and queue. Local view state only controls presentation.
public struct ModelLibraryView: View {
    @Bindable private var model: ModelLibraryModel
    private let selectedModelID: ModelID?
    private let canSelect: Bool
    private let onSelect: @MainActor (ModelID) async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dLanguageStore) private var language
    @State private var acquireVisible = false
    @State private var importVisible = false
    @State private var importCatalogID = ""
    @State private var importKind: WorkflowModelKind = .text
    @State private var importStorage: ModelStorageKind = .external
    @State private var settingsVisible = false
    @State private var downloadSelection: Set<String> = []
    @State private var registerAfterDownload = false
    @State private var narrowDetail = false
    @State private var confirmation: Confirmation?
    private enum Confirmation: Identifiable {
        case unregister(ModelResource), delete(ModelResource), clear(ModelDownloadTask), discard(ModelDownloadTask)
        var id: String {
            switch self {
            case .unregister(let value): "unregister-" + value.id.description
            case .delete(let value): "delete-" + value.id.description
            case .clear(let value): "clear-" + value.id.uuidString
            case .discard(let value): "discard-" + value.id.uuidString
            }
        }
    }
    public init(model: ModelLibraryModel, selectedModelID: ModelID? = nil, canSelect: Bool = false,
                onPrepare: (@MainActor (ModelID, URL) async throws -> Void)? = nil,
                onSelect: @escaping @MainActor (ModelID) async -> Void = { _ in }) {
        self.model = model; self.selectedModelID = selectedModelID; self.canSelect = canSelect; self.onSelect = onSelect
    }
    private func text(_ key: String, _ fallback: String) -> String {
        workflowText(language, "modelManagement." + key, fallback: fallback)
    }
    private var resources: [ModelResource] {
        (model.snapshot?.resources ?? []).filter { resource in
            let record = resource.record
            let search = model.resourceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = search.isEmpty || [model.presentationEntry(for: record)?.title, record.revision, record.directory?.path]
                .compactMap { $0 }.contains { $0.localizedStandardContains(search) }
            let include: Bool
            switch model.resourceFilter {
            case "registered": include = record.registrationState == .registered
            case "unregistered": include = record.registrationState != .registered
            case "attention": include = resource.control.fileState != .verified || record.state == .preparationRequired || record.error != nil
            case "unavailable": include = record.availability != .available
            default: include = true
            }
            return matches && include
        }
    }
    private var downloads: [ModelDownloadTask] {
        (model.snapshot?.downloads ?? []).filter { task in
            (model.taskSearch.isEmpty || (model.catalog.first { $0.id == task.catalogID }?.title ?? task.catalogID).localizedStandardContains(model.taskSearch)) &&
            (model.taskFilter == "all" || (model.taskFilter == "active" ? !task.state.isTerminal : task.state.isTerminal))
        }
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("title", "模型与下载")).font(.title2.bold())
                Spacer()
                Button(text("acquire", "获取模型…")) { acquireVisible = true }.accessibilityIdentifier("model-manager-acquire")
                Button(text("import", "登记已有…")) { importVisible = true }.accessibilityIdentifier("model-manager-import")
                Button(text("settings", "存储与访问…")) { settingsVisible = true }
                Button(text("close", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Picker(text("workspace", "工作面"), selection: Binding(get: { model.workspace }, set: { model.workspace = $0; narrowDetail = false })) {
                Text(text("resources", "模型与文件")).tag("resources")
                Text(text("downloads", "下载任务")).tag("downloads")
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 14)
                .accessibilityIdentifier("model-manager-workspace")
            if let error = model.errorMessage ?? model.snapshot?.queueError {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(error).textSelection(.enabled); Spacer(); Button(text("dismiss", "收起")) { model.clearError() } }
                    .font(.callout).padding(12).background(.orange.opacity(0.1))
            }
            if let notice = model.preparationNotice { Text(notice).font(.callout).padding(8) }
            if let operation = model.globalOperation {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(text("operation." + String(describing: operation), operation.title))
                    if operation == .preparing { Button(text("cancel", "取消")) { model.cancelPreparation() } }
                    if operation == .copying || operation == .registering { Button(text("cancel", "取消")) { model.cancelImport() } }
                    Spacer()
                }.padding(12)
            }
            controls
            Divider()
            GeometryReader { geometry in
                if geometry.size.width >= 980 {
                    HStack(spacing: 0) {
                        inventoryList.frame(width: geometry.size.width * 0.54)
                        Divider()
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if narrowDetail {
                    VStack(alignment: .leading, spacing: 0) {
                        Button(text("back", "返回列表"), systemImage: "chevron.left") { narrowDetail = false }.padding(12)
                        detail
                    }
                } else { inventoryList }
            }
            Divider()
            HStack {
                Text(text("background", "关闭面板后任务继续；退出后等待下次明确恢复。"))
                Spacer()
                Text(text("logical", "大小为逻辑文件字节，不保证等量释放空间。"))
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .presentationSizing(.fitted)
        .frame(minWidth: 760, idealWidth: 1080, maxWidth: .infinity,
               minHeight: 560, idealHeight: 740, maxHeight: .infinity)
        .accessibilityIdentifier("model-manager")
        .task { model.loadInventory(); await model.refresh() }
        .onDisappear { model.clearSelectionContext() }
        .sheet(isPresented: $acquireVisible) { acquisition }
        .sheet(isPresented: $importVisible) { localImport }
        .sheet(isPresented: $settingsVisible) { settings }
        .alert(text("confirm", "确认操作"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { action in
            Button(confirmationTitle(action), role: .destructive) { Task { await confirm(action) } }
            Button(text("keep", "保留"), role: .cancel) { }
        } message: { action in Text(confirmationMessage(action)) }
    }
    private var controls: some View {
        HStack {
            if model.workspace == "resources" {
                TextField(text("searchResources", "搜索名称、版本或位置"), text: $model.resourceSearch)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("model-manager-resource-search")
                Picker(text("filter", "筛选"), selection: $model.resourceFilter) {
                    Text(text("all", "全部")).tag("all"); Text(text("registered", "已登记")).tag("registered"); Text(text("unregistered", "未登记／待处理")).tag("unregistered")
                    Text(text("attention", "需要处理")).tag("attention"); Text(text("unavailable", "暂不可访问")).tag("unavailable")
                }.frame(width: 190)
            } else {
                TextField(text("searchDownloads", "搜索下载任务"), text: $model.taskSearch).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("model-manager-task-search")
                Picker(text("filter", "筛选"), selection: $model.taskFilter) {
                    Text(text("all", "全部")).tag("all"); Text(text("pending", "待处理")).tag("active"); Text(text("history", "历史")).tag("history")
                }.frame(width: 150)
                Text(text("queue." + (model.snapshot?.queueState.rawValue ?? "waitingForResume"), "等待你恢复")).font(.caption)
                if model.snapshot?.queueState == .running {
                    Button(text("pauseQueue", "暂停队列")) { Task { await model.pauseQueue() } }
                } else {
                    Button(text("resumeQueue", "继续队列") + " (\(model.snapshot?.downloads.filter { $0.state == .queued || $0.state == .waitingRetry }.count ?? 0))") { Task { await model.resumeQueue() } }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    @ViewBuilder private var inventoryList: some View {
        if model.workspace == "resources" {
            List(selection: $model.selectedResource) {
                ForEach(resources) { resource in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(resourceTitle(resource)).font(.headline)
                        Text(model.presentationEntry(for: resource.record).map { catalogText($0, field: "spec") } ?? text("unrecordedVariant", "此版本规格未记录")).font(.caption)
                        HStack {
                            Text(fileState(resource)); Text("·"); Text(registration(resource.record.registrationState)); Text("·"); Text(preparation(resource)); Spacer()
                            Text(ModelLibraryModel.formatBytes(resource.record.totalBytes))
                        }.font(.caption).foregroundStyle(.secondary)
                        Text((model.presentationEntry(for: resource.record)?.repository ?? "") + " · " + shortLocation(resource)).font(.caption).lineLimit(1).truncationMode(.middle)
                    }.padding(.vertical, 7).tag(resource.id).contentShape(Rectangle())
                        .onTapGesture { model.selectedResource = resource.id; narrowDetail = true }
                }
                if !model.readOnlyConfigurations.isEmpty {
                    Section(text("configured", "已有配置 · 只读")) {
                        ForEach(model.readOnlyConfigurations.filter { model.resourceSearch.isEmpty || $0.title.localizedStandardContains(model.resourceSearch) || $0.identity.localizedStandardContains(model.resourceSearch) }) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.headline)
                                WorkflowTechnicalDetails(value: item.identity)
                                Text(item.location?.path ?? text("locationUnread", "位置尚未读取")).font(.caption).textSelection(.enabled)
                                Text(text("readOnlyHelp", "保留既有能力；此配置不由下载库直接管理。无文件扫描或虚构下载历史。")).font(.caption).foregroundStyle(.secondary)
                                if item.selectable, let action = model.configurationSelectionAction {
                                    Button(text("useTarget", "用于：") + (model.currentSelectionTitle ?? text("targetUnavailable", "目标已改变，请重新选择"))) { Task { await action(item) } }.disabled(model.currentSelectionTitle == nil)
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }.listStyle(.inset).scrollPosition($model.resourceListScroll).accessibilityIdentifier("model-manager-resources")
                .overlay { if resources.isEmpty && model.readOnlyConfigurations.isEmpty { ContentUnavailableView(text("noResources", "没有匹配资源"), systemImage: "shippingbox") } }
        } else {
            List(selection: $model.selectedTask) {
                ForEach(0..<4) { group in
                  let tasks = downloads.filter { taskGroup($0) == group }
                  if !tasks.isEmpty {
                    Section(text("group.\(group)", "下载任务") + " (\(tasks.count))") {
                      ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.catalog.first { $0.id == task.catalogID }?.title ?? task.catalogID).font(.headline)
                        Text(model.snapshot?.resources.first(where: { $0.id == task.resourceID }).map(shortLocation) ?? text("unknownLocation", "位置尚未确认")).font(.caption).lineLimit(1)
                        HStack { Text(downloadState(task.state)); Spacer(); Text(task.postAction == .register ? text("downloadRegister", "下载后登记") : text("filesOnly", "仅下载文件")) }.font(.caption)
                        if let resource = model.snapshot?.resources.first(where: { $0.id == task.resourceID }) {
                            ProgressView(value: Double(resource.record.downloadedBytes), total: Double(max(1, resource.record.totalBytes)))
                            Text(ModelLibraryModel.formatBytes(resource.record.downloadedBytes) + " / " + ModelLibraryModel.formatBytes(resource.record.totalBytes)).font(.caption.monospacedDigit())
                        }
                    }.padding(.vertical, 7).tag(task.id).contentShape(Rectangle())
                        .onTapGesture { model.selectedTask = task.id; narrowDetail = true }
                      }
                    }
                  }
                }
            }.listStyle(.inset).scrollPosition($model.taskListScroll).accessibilityIdentifier("model-manager-downloads")
                .overlay { if downloads.isEmpty { ContentUnavailableView(text("noDownloads", "没有匹配下载任务"), systemImage: "arrow.down.circle") } }
        }
    }
    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.workspace == "resources", let resource = model.snapshot?.resources.first(where: { $0.id == model.selectedResource }) {
                    resourceDetail(resource)
                } else if model.workspace == "downloads", let task = model.snapshot?.downloads.first(where: { $0.id == model.selectedTask }) {
                    downloadDetail(task)
                } else { ContentUnavailableView(text("selectDetail", "选择一项查看详情"), systemImage: "sidebar.right") }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollPosition(model.workspace == "resources" ? $model.resourceDetailScroll : $model.taskDetailScroll).accessibilityIdentifier("model-manager-detail")
    }
    private func resourceDetail(_ resource: ModelResource) -> some View {
        let record = resource.record, entry = model.presentationEntry(for: resource.record)
        return VStack(alignment: .leading, spacing: 16) {
            Text(resourceTitle(resource)).font(.title2.bold())
            LabeledContent(text("files", "文件"), value: fileState(resource))
            LabeledContent(text("registration", "登记"), value: registration(record.registrationState))
            LabeledContent(text("preparation", "准备"), value: preparation(resource))
            Text(entry.map { catalogText($0, field: "spec") } ?? "").font(.callout)
            Text(entry.map { catalogText($0, field: "memory") } ?? "").font(.caption).foregroundStyle(.secondary)
            field("location", "位置", resourceLocation(resource))
            field("ownership", "文件控制", record.storage == .managed ? text("managed", "D 管理的确切副本") : text("external", "外部原件：不提供直接删除"))
            field("origin", "取得方式", text("origin." + resource.control.origin.rawValue, resource.control.origin.rawValue))
            field("repository", "内容来源", entry?.repository ?? text("unknown", "未知"))
            Divider()
            Text(text("knownScope", "当前已知资源与引用；未扫描所有历史项目。")).font(.caption).foregroundStyle(.secondary)
            if record.activeLeaseCount > 0 { Text(text("inUse", "正在运行、排队、准备或备份中，文件受到保护。")) }
            if let error = record.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            VStack(alignment: .leading, spacing: 10) {
                if let _ = record.directory {
                    Button(text("finder", "在 Finder 中显示")) { model.reveal(resource) }.disabled(record.availability != .available)
                }
                if resource.control.fileState == .verified || resource.control.fileState == .invalid {
                    Button(text("reverify", "重新校验文件")) { Task { await model.reverify(resource) } }.disabled(record.activeLeaseCount > 0 || model.hasActiveWork || model.globalOperation != nil)
                }
                if resource.control.fileState == .deleted {
                    Button(text("getSame", "获取同版本文件…")) { downloadSelection = [record.catalogID]; acquireVisible = true }
                }
                if record.registrationState != .registered {
                    Button(text("register", "登记此资源")) { Task { await model.registerResource(resource) } }
                        .disabled(resource.control.fileState != .verified || record.state == .preparationRequired || model.globalOperation != nil)
                } else {
                    Button(text("unregister", "解除登记…")) { confirmation = .unregister(resource) }.disabled(record.activeLeaseCount > 0)
                }
                if record.state == .preparationRequired {
                    Button(text("prepare", "准备独立执行包…")) { Task { await model.prepareResource(record.id) } }.disabled(!model.canChooseRoot)
                }
                if resource.control.fileState == .partial || record.state == .failed {
                    Button(text("continue", "继续保留的下载")) { Task { await model.continueResource(resource) } }.disabled(record.storage != .managed)
                    Button(text("restart", "重新下载并丢弃现有进度…")) { Task { await model.restart(record.id) } }.disabled(record.storage != .managed)
                }
                if record.storage == .external {
                    if resource.control.role != .execution {
                        Button(model.rootURL == nil ? text("chooseRootThenCopy", "选择模型库后复制…") : text("copy", "复制到 D 模型库…")) { Task { await model.copyExisting(record.id) } }.disabled(!model.canChooseRoot)
                    }
                    Button(text("relink", "重新定位或授权…")) { Task { await model.relink(record.id) } }.disabled(!model.canChooseRoot)
                } else if record.availability != .available {
                    Button(text("relink", "重新定位或授权…")) { Task { await model.chooseRoot() } }.disabled(!model.canChooseRoot)
                }
                if record.storage == .managed, resource.control.fileState != .deleted {
                    Button(text("delete", "删除这份受管理文件…"), role: .destructive) { confirmation = .delete(resource) }.disabled(record.activeLeaseCount > 0 || model.hasActiveWork)
                }
                if (canSelect || model.selectionAction != nil), record.registrationState == .registered, record.state == .installed,
                   record.availability == .available {
                    Button(model.selectionAction == nil ? text("selectResource", "选择此资源") : text("useTarget", "用于：") + (model.currentSelectionTitle ?? text("targetUnavailable", "目标已改变，请重新选择"))) { Task { if let action = model.selectionAction { await action(record.id) } else { await onSelect(record.id) } } }
                        .disabled(record.id == (model.selectionID ?? selectedModelID) || (model.selectionAction != nil && model.currentSelectionTitle == nil))
                }
            }.buttonStyle(.bordered)
            if record.registrationState != .registered { Text(text("registrationHelp", "文件完整不等于已接入执行；登记不会改变当前节点或运行模型。")).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup(text("technical", "身份与来源详情")) {
            WorkflowTechnicalDetails(value: resource.id.description + "\n" + record.revision + "\n" + resourceLocation(resource))
            field("resourceID", "资源身份", resource.id.description)
            field("revision", "精确版本", record.revision)
            field("recipe", "准备配方", resource.control.preparationRecipe ?? text("notRequired", "不需要"))
            field("executionRevision", "执行副本版本", resource.control.executionRevision ?? text("unknown", "未知"))
            if let parent = resource.control.parentResourceID { field("parent", "原始资源", parent.description) }
            field("verified", "最后完整核验", resource.control.lastVerified?.formatted() ?? text("unknown", "未知"))
            field("knownFiles", "必要文件数量", String(resource.control.requiredPaths?.count ?? entry?.files.count ?? 0))
            if let paths = resource.control.requiredPaths {
                field("actualPaths", "此副本已记录的必要文件", paths.joined(separator: "\n"))
            }
            if let entry {
                Text(text("sourceRecipeFiles", "源配方组件及摘要（不代表准备输出的摘要）")).font(.caption)
                ForEach(entry.files, id: \.path) { file in
                    Text(file.path).font(.caption.bold()).textSelection(.enabled)
                    WorkflowTechnicalDetails(value: file.sha256 + "\n" + String(describing: file.digestAlgorithm))
                    Text((file.sourceRepository ?? entry.repository) + " @ " + (file.sourceRevision ?? entry.revision) + " / " + (file.remotePath ?? file.path)).font(.caption).textSelection(.enabled)
                }
            }
            }
            ForEach(resource.control.events.reversed()) { event in
                Text(text("event." + event.action, event.action) + " · " + (event.date?.formatted() ?? text("unknown", "未知"))).font(.caption)
            }
        }
    }
    private func downloadDetail(_ task: ModelDownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.catalog.first { $0.id == task.catalogID }?.title ?? task.catalogID).font(.title2.bold())
            Text(downloadState(task.state)).font(.headline)
            if let resource = model.snapshot?.resources.first(where: { $0.id == task.resourceID }) {
                ProgressView(value: Double(resource.record.downloadedBytes), total: Double(max(1, resource.record.totalBytes)))
                Text(ModelLibraryModel.formatBytes(resource.record.downloadedBytes) + " / " + ModelLibraryModel.formatBytes(resource.record.totalBytes)).font(.caption.monospacedDigit())
            }
            field("postAction", "下载完成后", task.postAction == .filesOnly ? text("filesOnly", "仅下载文件") : text("downloadRegister", "下载后登记"))
            if let deadline = task.earliestRetry { field("earliest", "最早重试", deadline.formatted()) }
            if let first = task.firstError { field("firstError", "最初错误", first) }
            if let error = task.error { field("latestError", "最近错误", error) }
            if let error = task.postActionError { field("postError", "文件已完成，后续动作待处理", error) }
            field("location", "来源与目标", taskLocation(task))
            if task.state == .queued && task.attempts == 0 {
                HStack {
                    Button(text("up", "上移")) { Task { await model.move(task.id, by: -1) } }
                    Button(text("down", "下移")) { Task { await model.move(task.id, by: 1) } }
                    Button(text("next", "移到下一项")) { Task { await model.moveNext(task.id) } }
                }
            }
            if let resource = model.snapshot?.resources.first(where: { $0.id == task.resourceID }) {
                Button(text("viewResource", "查看资源与登记")) { model.selectedResource = resource.id; model.workspace = "resources"; narrowDetail = true }
            }
            if !task.state.isTerminal {
                if task.state != .paused { Button(text("pauseTask", "暂停此项")) { Task { await model.pauseTask(task.id) } } }
                Button(text("cancelKeep", "取消并保留断点")) { Task { await model.cancelTask(task.id, keepPartial: true) } }
                Button(text("cancelDiscard", "取消并清理本项暂存…"), role: .destructive) { confirmation = .discard(task) }
            }
            if task.state == .paused || task.state == .failed || task.state == .cancelled {
                Button(text("continue", "继续保留的下载")) {
                    if let resource = model.snapshot?.resources.first(where: { $0.id == task.resourceID }) { Task { await model.continueResource(resource) } }
                }
            }
            if task.state.isTerminal { Button(text("clearHistory", "清除此下载记录…")) { confirmation = .clear(task) } }
            WorkflowTechnicalDetails(value: ["Task: " + task.id.uuidString, "Resource: " + task.resourceID.description, "Attempt: " + task.attemptID.uuidString, "Attempts: " + String(task.attempts), "Generation: " + task.generation.uuidString].joined(separator: "\n"))

        }.buttonStyle(.bordered)
    }
    private var acquisition: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(text("acquire", "获取模型…")).font(.title2.bold()); Spacer(); Button(text("close", "完成")) { acquireVisible = false } }
            Text(text("frozenCatalog", "仅显示当前版本已支持的固定配方。模型资格与令牌需自行确认；不会自动选用或推理。")).font(.callout)
            List(model.catalog) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(entry.title, isOn: Binding(get: { downloadSelection.contains(entry.id) }, set: { if $0 { downloadSelection.insert(entry.id) } else { downloadSelection.remove(entry.id) } }))
                    Text(catalogText(entry, field: "spec") + " · " + ModelLibraryModel.formatBytes(entry.totalBytes)).font(.caption)
                    WorkflowTechnicalDetails(value: entry.id + "\n" + entry.revision)
                    Text(catalogText(entry, field: "memory")).font(.caption).foregroundStyle(.secondary)
                    Text(entry.repository).font(.caption)
                    Text(acquisitionState(entry)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            Text(model.rootURL?.path ?? text("noRoot", "尚未选择模型库位置")).font(.caption).textSelection(.enabled)
            Text(text("newTasks", "需新增任务") + ": \(newDownloads.count) · " + text("newBytes", "新增下载字节上限") + ": " + ModelLibraryModel.formatBytes(newDownloads.reduce(0) { $0 + additionalBytes($1) })).font(.callout)
            Text(text("spaceHelp", "空间在提交及传输时再次核对；下载、校验及准备可能需要额外空间。已有完整包和任务会复用。")).font(.caption)
            Toggle(text("downloadRegister", "下载后登记"), isOn: $registerAfterDownload)
            Text(text("downloadDefault", "默认仅下载。需要准备的原始包会保留为待处理，队列继续其他项目。")).font(.caption)
            HStack {
                if model.rootURL == nil { Button(text("chooseRoot", "选择存储位置…")) { Task { await model.chooseRoot() } } }
                Spacer()
                Button(text("enqueue", "确认获取意图") + " (\(newDownloads.count))") {
                    let ids = model.catalog.filter { downloadSelection.contains($0.id) }.map(\.id)
                    Task { await model.enqueue(ids, register: registerAfterDownload); if model.errorMessage == nil { acquireVisible = false; model.workspace = "downloads" } }
                }.disabled(downloadSelection.isEmpty || model.rootURL == nil)
            }
        }.padding(22).frame(minWidth: 620, idealWidth: 760, minHeight: 500, idealHeight: 620)
    }
    private var localImport: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(text("import", "登记已有…")).font(.title2.bold()); Spacer(); Button(text("close", "完成")) { importVisible = false } }
            Picker(text("configuration", "配置"), selection: $importCatalogID) {
                Text(text("existingRoute", "已有引擎支持的精确配置")).tag("")
                ForEach(model.catalog) { Text($0.title).tag($0.id) }
            }
            if importCatalogID.isEmpty {
                Picker(text("kind", "用途"), selection: $importKind) {
                    ForEach([WorkflowModelKind.text, .image, .music, .video], id: \.rawValue) { kind in Text(text("kind." + kind.rawValue, kind.rawValue)).tag(kind) }
                }
                Text(text("importExactHelp", "沿用现有引擎的精确校验。保留原位置，不自动选用，不创建下载任务。")).font(.callout)
                Button(text("chooseFolder", "选择准确文件夹…")) { Task { await model.importConfiguration(kind: importKind) } }.disabled(model.explicitRegistration == nil || model.globalOperation != nil)
            } else {
                Picker(text("storageMode", "文件位置"), selection: $importStorage) {
                    Text(text("keepLocation", "保留原位置")).tag(ModelStorageKind.external)
                    Text(text("copyIntoLibrary", "复制进模型库")).tag(ModelStorageKind.managed)
                }.pickerStyle(.radioGroup)
                if importStorage == .managed {
                    Text(model.rootURL?.path ?? text("noRoot", "尚未选择模型库位置"))
                    Text(text("copySpace", "复制保留原件；逻辑大小不等于实际新增磁盘占用。")).font(.caption)
                    if model.rootURL == nil { Button(text("chooseRoot", "选择存储位置…")) { Task { await model.chooseRoot() } } }
                }
                Button(text("chooseFolder", "选择准确文件夹…")) { Task { await model.registerExisting(catalogID: importCatalogID, storage: importStorage) } }
                    .disabled(model.hasActiveWork || model.globalOperation != nil || (importStorage == .managed && model.rootURL == nil))
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(24).frame(width: 650)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(text("settings", "存储与凭据…")).font(.title2.bold())
            Text(model.rootURL?.path ?? text("noRoot", "尚未选择模型库位置")).textSelection(.enabled)
            Button(text("chooseRoot", "选择存储位置…")) { Task { await model.chooseRoot() } }.disabled(!model.canChooseRoot)
            Text(text("rootHelp", "重新定位仅支持原模型库在同卷移动；不扫描或迁移其他目录。")).font(.caption)
            Divider()
            Text(model.downloadCredentialConnected ? text("credentialConnected", "已连接令牌文件") : text("credentialMissing", "未连接令牌文件"))
            Button(text("credentialChoose", "连接令牌文件…")) { Task { await model.chooseDownloadCredential() } }.disabled(!model.canChangeDownloadCredential)
            if model.downloadCredentialConnected { Button(text("credentialRemove", "断开令牌文件")) { Task { await model.removeDownloadCredential() } }.disabled(!model.canChangeDownloadCredential) }
            Text(text("credentialHelp", "只保存文件授权。不会展示或导出令牌，也不新增账号存储。")).font(.caption)
            HStack { Spacer(); Button(text("close", "完成")) { settingsVisible = false } }
        }.padding(24).frame(width: 600)
    }
    private func field(_ key: String, _ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(text(key, title)).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout).textSelection(.enabled) }
    }
    private func registration(_ state: ModelRegistrationState) -> String { text("registration." + state.rawValue, state.rawValue) }
    private func fileState(_ resource: ModelResource) -> String {
        if resource.control.fileState == .deleted || resource.control.fileState == .deleting { return text("files." + resource.control.fileState.rawValue, resource.control.fileState.rawValue) }
        if resource.record.availability != .available { return text("availability." + resource.record.availability.rawValue, resource.record.availability.rawValue) }
        return text("files." + resource.control.fileState.rawValue, resource.control.fileState.rawValue)
    }
    private func downloadState(_ state: ModelDownloadState) -> String { text("task." + state.rawValue, state.rawValue) }
    private func resourceLocation(_ resource: ModelResource) -> String {
        if resource.control.fileState == .partial, resource.record.storage == .managed, let root = model.rootURL {
            return root.appendingPathComponent(".d-model-library/Staging/" + resource.record.id.description + "/Content").path
        }
        return resource.record.directory?.path ?? text("unknownLocation", "位置尚未确认")
    }
    private func taskLocation(_ task: ModelDownloadTask) -> String {
        let source = model.catalog.first { $0.id == task.catalogID }?.repository ?? task.catalogID
        let location = model.snapshot?.resources.first { $0.id == task.resourceID }.map(resourceLocation) ?? text("unknownLocation", "位置尚未确认")
        return source + " · " + location
    }
    private func taskGroup(_ task: ModelDownloadTask) -> Int {
        switch task.state {
        case .downloading, .verifying, .publishing: 0
        case .queued, .waitingRetry: 1
        case .paused, .failed: 2
        case .completed, .cancelled: 3
        }
    }
    private func existingResource(_ entry: ModelCatalogEntry) -> ModelResource? {
        model.snapshot?.resources.first { $0.record.catalogID == entry.id && $0.record.revision == entry.revision && $0.record.storage == .managed && $0.control.fileState != .deleted && $0.control.fileState != .deleting }
    }
    private func existingTask(_ entry: ModelCatalogEntry) -> ModelDownloadTask? {
        guard let resource = existingResource(entry) else { return nil }
        return model.snapshot?.downloads.first { $0.resourceID == resource.id && !$0.state.isTerminal }
    }
    private var newDownloads: [ModelCatalogEntry] {
        model.catalog.filter { downloadSelection.contains($0.id) && existingResource($0)?.control.fileState != .verified && existingTask($0) == nil }
    }
    private func additionalBytes(_ entry: ModelCatalogEntry) -> UInt64 {
        let saved = existingResource(entry)?.record.downloadedBytes ?? 0
        return entry.totalBytes > saved ? entry.totalBytes - saved : 0
    }
    private func acquisitionState(_ entry: ModelCatalogEntry) -> String {
        if existingResource(entry)?.control.fileState == .verified { return text("reuseComplete", "已有完整副本：复用文件，可另行登记或查看") }
        if existingTask(entry) != nil { return text("reuseTask", "已有任务：保留原任务及完成后动作") }
        return text("newDownload", "需要新增下载任务")
    }
    private func resourceTitle(_ resource: ModelResource) -> String {
        let base = model.presentationEntry(for: resource.record)?.title ?? text("recordedResource", "已登记资源")
        let peers = (model.snapshot?.resources ?? []).filter {
            (model.presentationEntry(for: $0.record)?.title ?? text("recordedResource", "已登记资源")) == base
        }.sorted { $0.id.description < $1.id.description }
        guard peers.count > 1, let index = peers.firstIndex(where: { $0.id == resource.id }) else { return base }
        return base + " · " + text("copyAlias", "副本") + " \(index + 1)"
    }
    private func shortLocation(_ resource: ModelResource) -> String {
        resource.record.storage == .managed ? text("managedLocation", "D 模型库 · 受管理副本") : text("externalLocation", "外部目录 · 原件")
    }
    private func preparation(_ resource: ModelResource) -> String {
        if resource.control.role == .execution {
            return text("executionCopy", "独立执行副本（仍需文件与登记有效）")
        }
        guard let entry = model.presentationEntry(for: resource.record) else { return text("unknownPreparation", "准备要求未知") }
        return entry.preparation == .required ? text("needsPreparation", "需要准备") : text("notRequired", "不需要")
    }
    private func catalogText(_ entry: ModelCatalogEntry, field: String) -> String {
        text("catalog." + entry.id + "." + field, field == "spec" ? entry.modelSpec : entry.memoryGuidance)
    }
    private func confirmationTitle(_ action: Confirmation) -> String {
        switch action {
        case .unregister: text("unregister", "解除登记，保留文件")
        case .delete: text("delete", "删除这份本地副本…")
        case .clear: text("clearHistory", "清除下载历史，保留文件")
        case .discard: text("cancelDiscard", "取消任务并清理未完成文件…")
        }
    }
    private func confirmationMessage(_ action: Confirmation) -> String {
        let resource: ModelResource?, consequence: String
        switch action {
        case .unregister(let value): resource = value; consequence = text("confirmUnregister", "解除后新的提交不能取得此资源。保留文件、身份、作品及下载历史。")
        case .delete(let value): resource = value; consequence = text("confirmDelete", "永久删除这份确切文件，不是移到废纸篓；可能需要重新下载。保留登记、其他副本、作品与历史；登记将不可用。")
        case .clear(let task): resource = model.snapshot?.resources.first { $0.id == task.resourceID }; consequence = text("confirmClear", "仅清除此终态下载任务。保留文件、登记、来源及继续断点所需的控制记录。")
        case .discard(let task): resource = model.snapshot?.resources.first { $0.id == task.resourceID }; consequence = text("confirmDiscard", "取消后等待写入停止，再永久删除本项确切暂存文件，不进废纸篓。保留登记与历史；已保存进度将丢失，可能需要重新下载。")
        }
        guard let resource else { return consequence + "\n" + text("unknownLocation", "位置尚未确认") }
        let children = model.snapshot?.resources.filter { $0.control.parentResourceID == resource.id && $0.control.fileState != .deleted }.count ?? 0
        return (model.presentationEntry(for: resource.record)?.title ?? resource.record.catalogID) + " · " + resource.record.revision + "\n" + resourceLocation(resource)
            + "\n" + text("oneObject", "影响对象：1") + " · " + text("knownLeases", "当前占用") + ": \(resource.record.activeLeaseCount) · " + text("preparedChildren", "已知准备副本") + ": \(children)"
            + "\n" + text("role." + resource.control.role.rawValue, resource.control.role.rawValue) + "\n\n" + consequence
    }
    private func confirm(_ action: Confirmation) async {
        switch action {
        case .unregister(let resource): await model.unregisterResource(resource)
        case .delete(let resource): await model.deleteResource(resource)
        case .clear(let task): await model.clearTask(task.id)
        case .discard(let task): await model.cancelTask(task.id, keepPartial: false)
        }
    }
}
