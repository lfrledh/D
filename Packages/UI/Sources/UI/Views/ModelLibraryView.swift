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
    @State private var featureHelp = WorkbenchHelpStore()
    @State private var acquireVisible = false
    @State private var importVisible = false
    @State private var importCatalogID = ""
    @State private var importKind: WorkflowModelKind = .text
    @State private var importStorage: ModelStorageKind = .external
    @State private var acquisitionSearch = ""
    @State private var deletingTask: ModelDownloadTask?
    @State private var cleanupPartial = false
    @State private var downloadSelection: Set<String> = []
    @State private var registerAfterDownload = false
    @State private var narrowDetail = false
    @State private var preparableResource: ModelID?
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
                Text(text(model.workspace == "downloads" ? "downloadTitle" : "modelTitle", "模型管理")).font(.title2.bold())
                Spacer()
                WorkbenchFeatureGuideButton(store: featureHelp)
                Button(text("close", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
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
                if model.workspace == "downloads" {
                    Text(text("queue." + (model.snapshot?.queueState.rawValue ?? "waitingForResume"), "等待队列开始"))
                    Spacer()
                    Text(text("background", "关闭面板后，下载继续。"))
                } else { Text(text("logical", "大小为逻辑文件字节，不保证等量释放空间。")); Spacer() }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        }
        .presentationSizing(.fitted)
        .frame(minWidth: 760, idealWidth: 1080, maxWidth: .infinity,
               minHeight: 560, idealHeight: 740, maxHeight: .infinity)
        .accessibilityIdentifier("model-manager")
        .environment(\.workbenchHelpStore, featureHelp)
        .sheet(item: $featureHelp.presentation) { WorkbenchFeatureGuide(presentation: $0, store: featureHelp).environment(\.dLanguageStore, language) }
        .environment(\.workbenchMenuContext, "models:\(ObjectIdentifier(model)):\(ObjectIdentifier(model.library)):\(model.rootURL?.standardizedFileURL.path ?? "none"):\(model.workspace)")
        .task { model.loadInventory(); await model.refresh() }
        .onDisappear { model.clearSelectionContext() }
        .sheet(isPresented: $acquireVisible) { acquisition }
        .sheet(isPresented: $importVisible) { localImport }
        .sheet(item: $deletingTask) { task in deleteConfirmation(task) }
        .alert(text("confirm", "确认操作"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { action in
            Button(confirmationTitle(action), role: .destructive) { Task { await confirm(action) } }
            Button(text("keep", "保留"), role: .cancel) { }
        } message: { action in Text(confirmationMessage(action)) }
    }
    private var controls: some View {
        HStack(spacing: 8) {
            if model.workspace == "resources" {
                Button(text("import", "登记模型…")) { importVisible = true }.accessibilityIdentifier("model-manager-import")
            }
            Button(text("acquire", "新建下载…")) { downloadSelection = []; registerAfterDownload = false; acquisitionSearch = ""; acquireVisible = true }
                .accessibilityIdentifier("model-manager-acquire")
            if model.workspace == "downloads" {
                Button(text(model.queueIsRunning ? "pauseQueue" : "resumeQueue", "开始全部")) {
                    Task { if model.queueIsRunning { await model.pauseQueue() } else { await model.resumeQueue() } }
                }.disabled(model.rootURL == nil || model.queueCommandPending)
            }
            Spacer(minLength: 8)
            if model.workspace == "resources" {
                TextField(text("searchResources", "搜索模型"), text: $model.resourceSearch).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("model-manager-resource-search")
                WorkbenchPicker(text("filter", "筛选"), selection: $model.resourceFilter) {
                    WorkbenchChoice(text("all", "全部"), value: "all"); WorkbenchChoice(text("registered", "已登记"), value: "registered")
                    WorkbenchChoice(text("unregistered", "未登记"), value: "unregistered"); WorkbenchChoice(text("attention", "需要处理"), value: "attention")
                    WorkbenchChoice(text("unavailable", "暂不可访问"), value: "unavailable")
                }.frame(width: 150)
            } else {
                TextField(text("searchDownloads", "搜索下载任务"), text: $model.taskSearch).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("model-manager-task-search")
                WorkbenchPicker(text("filter", "筛选"), selection: $model.taskFilter) {
                    WorkbenchChoice(text("all", "全部"), value: "all"); WorkbenchChoice(text("pending", "进行中"), value: "active")
                    WorkbenchChoice(text("history", "已结束"), value: "history")
                }.frame(width: 130)
            }
        }.buttonStyle(.bordered).controlSize(.regular).frame(minHeight: 32).padding(.horizontal, 20).padding(.bottom, 12)
    }
    @ViewBuilder private var inventoryList: some View {
        if model.workspace == "resources" {
            List(selection: $model.selectedResource) {
                ForEach(resources) { resource in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(resourceTitle(resource)).font(.headline)
                        ModelSpecificationFields(descriptor: descriptor(model.presentationEntry(for: resource.record)), font: .caption)
                        HStack {
                            Text(fileState(resource)); Text("·"); Text(registration(resource.record.registrationState)); Text("·"); Text(preparation(resource)); Spacer()
                            Text(ModelLibraryModel.formatBytes(resource.record.totalBytes))
                        }.font(.caption).foregroundStyle(.secondary)
                        Text((model.presentationEntry(for: resource.record)?.repository ?? "") + " · " + shortLocation(resource)).font(.caption).lineLimit(1).truncationMode(.middle)
                    }.padding(.vertical, 7).tag(resource.id).contentShape(Rectangle())
                        .onTapGesture { model.selectedResource = resource.id; narrowDetail = true }
                }
                if model.resourceFilter == "all", !model.readOnlyConfigurations.isEmpty {
                    Section(text("configured", "已有配置 · 只读")) {
                        ForEach(model.readOnlyConfigurations.filter { model.resourceSearch.isEmpty || $0.title.localizedStandardContains(model.resourceSearch) || $0.identity.localizedStandardContains(model.resourceSearch) }) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.headline)
                                ModelSpecificationFields(descriptor: ModelNodeCatalog.entries.first { $0.id == item.identity }, font: .caption)
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
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            let entry = model.catalog.first { $0.id == task.catalogID }
                            Text(entry?.title ?? task.catalogID).font(.headline).lineLimit(1).help(entry?.title ?? task.catalogID)
                            ModelSpecificationFields(descriptor: descriptor(entry), font: .caption)
                            if let resource = model.snapshot?.resources.first(where: { $0.id == task.resourceID }) {
                                ProgressView(value: Double(resource.record.downloadedBytes), total: Double(max(1, resource.record.totalBytes)))
                                Text(ModelLibraryModel.formatBytes(resource.record.downloadedBytes) + " / " + ModelLibraryModel.formatBytes(resource.record.totalBytes)).font(.caption.monospacedDigit())
                            }
                            Text(taskStatus(task)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .onTapGesture { model.selectedTask = task.id; narrowDetail = true }
                        taskPrimary(task)
                        taskMenu(task)
                    }.padding(.vertical, 7).tag(task.id)

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
            ModelSpecificationSummary(descriptor: descriptor(entry))
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
                if resource.control.fileState == .verified || resource.control.fileState == .invalid {
                    Button(text("reverify", "重新校验文件")) { Task { await model.reverify(resource) } }.disabled(record.activeLeaseCount > 0 || model.hasActiveWork || model.globalOperation != nil)
                }
                if resource.control.fileState == .deleted {
                    Button(text("getSame", "新建下载…")) { downloadSelection = [record.catalogID]; registerAfterDownload = false; acquisitionSearch = ""; acquireVisible = true }
                }
                if record.registrationState != .registered {
                    Button(text("register", "登记此资源")) { Task { await model.registerResource(resource) } }.workbenchHelp("MODELS-REGISTER", unavailableReason: model.globalOperation != nil ? consistencyText(language, "help.reason.modelOperation") : resource.control.fileState != .verified ? consistencyText(language, "help.reason.unverified") : record.state == .preparationRequired ? consistencyText(language, "help.reason.prepare") : nil, target: "resource:\(resource.id):\(record.revision)")
                        .disabled(resource.control.fileState != .verified || record.state == .preparationRequired || model.globalOperation != nil)
                }
                if record.state == .preparationRequired, preparableResource == record.id {
                    Button(text("prepare", "准备独立执行包…")) { Task { await model.prepareResource(record.id) } }.disabled(!model.canChooseRoot)
                }
                if let task = model.snapshot?.downloads.last(where: { $0.resourceID == resource.id }) {
                    Button(text("viewDownload", "查看下载任务")) { model.selectedTask = task.id; model.workspace = "downloads"; narrowDetail = true }
                }
                if record.storage == .external {
                    if resource.control.role != .execution {
                        Button(model.rootURL == nil ? text("chooseRootThenCopy", "选择模型库后复制…") : text("copy", "复制到 D 模型库…")) { Task { await model.copyExisting(record.id) } }.disabled(!model.canChooseRoot)
                    }
                    Button(text("relink", "重新定位或授权…")) { Task { await model.relink(record.id) } }.disabled(!model.canChooseRoot)
                } else if record.availability != .available {
                    Button(text("relink", "重新定位或授权…")) { Task { await model.chooseRoot() } }.disabled(!model.canChooseRoot)
                }
                if (canSelect || model.selectionAction != nil), record.registrationState == .registered, record.state == .installed,
                   record.availability == .available {
                    Button(model.selectionAction == nil ? text("selectResource", "选择此资源") : text("useTarget", "用于：") + (model.currentSelectionTitle ?? text("targetUnavailable", "目标已改变，请重新选择"))) { Task { if let action = model.selectionAction { await action(record.id) } else { await onSelect(record.id) } } }
                        .disabled(record.id == (model.selectionID ?? selectedModelID) || (model.selectionAction != nil && model.currentSelectionTitle == nil))
                }
                WorkbenchMenu(consistencyText(language, "copy.more"), systemImage: "ellipsis.circle") {
                    WorkbenchMenuAction(consistencyText(language, "menu.model.locate")) { model.reveal(resource) }.featureHelp("MENU-MODEL-LOCATE", language: language).disabled(record.directory == nil || record.availability != .available)
                    WorkbenchMenuDivider()
                    if record.registrationState == .registered {
                        WorkbenchMenuAction(consistencyText(language, "menu.model.unregister")) { confirmation = .unregister(resource) }.featureHelp("MODELS-UNREGISTER", language: language, unavailableReason: record.activeLeaseCount > 0 ? consistencyText(language, "help.reason.leased") : nil).disabled(record.activeLeaseCount > 0)
                    }
                    WorkbenchMenuDivider()
                    if record.storage == .managed, resource.control.fileState != .deleted {
                        WorkbenchMenuAction(consistencyText(language, "menu.model.delete"), role: .destructive) { confirmation = .delete(resource) }.featureHelp("MODELS-DELETE", language: language, unavailableReason: record.activeLeaseCount > 0 ? consistencyText(language, "help.reason.leased") : model.hasActiveWork ? consistencyText(language, "help.reason.modelOperation") : nil).disabled(record.activeLeaseCount > 0 || model.hasActiveWork)
                    }
                }.environment(\.workbenchMenuContext, "resource:\(ObjectIdentifier(model)):\(resource.id)")
            }.buttonStyle(WorkbenchGlassButtonStyle())
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
        }.task(id: "\(record.id):\(record.state):\(resource.control.fileState)") {
            preparableResource = nil
            let supported = (try? await model.library.canPrepareVideo(record.id)) == true
            guard !Task.isCancelled, model.selectedResource == resource.id, model.workspace == "resources" else { return }
            preparableResource = supported ? record.id : nil
        }
    }
    private func downloadDetail(_ task: ModelDownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.catalog.first { $0.id == task.catalogID }?.title ?? task.catalogID).font(.title2.bold())
            Text(taskStatus(task)).font(.headline)
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
            HStack { taskPrimary(task); taskMenu(task) }
            if let resource = model.snapshot?.resources.first(where: { $0.id == task.resourceID }) {
                Button(text("viewResource", "查看对应模型")) { model.selectedResource = resource.id; model.workspace = "resources"; narrowDetail = true }
                if task.state == .completed, task.postActionError != nil, resource.record.registrationState != .registered {
                    Button(text("retryRegistration", "重试登记")) { Task { await model.retryRegistration(task) } }
                        .disabled(resource.record.state == .preparationRequired || model.globalOperation != nil)
                }
            }
            WorkflowTechnicalDetails(value: ["Task: " + task.id.uuidString, "Resource: " + task.resourceID.description, "Attempt: " + task.attemptID.uuidString, "Attempts: " + String(task.attempts), "Generation: " + task.generation.uuidString].joined(separator: "\n"))

        }.buttonStyle(.bordered)
    }
    private var acquisition: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(text("acquire", "新建下载…")).font(.title2.bold())
            TextField(text("searchCatalog", "搜索支持的模型"), text: $acquisitionSearch).textFieldStyle(.roundedBorder)
            List(model.catalog.filter { acquisitionSearch.isEmpty || $0.title.localizedStandardContains(acquisitionSearch) }) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(entry.title, isOn: Binding(get: { downloadSelection.contains(entry.id) }, set: { if $0 { downloadSelection.insert(entry.id) } else { downloadSelection.remove(entry.id) } }))
                        .disabled(existingResource(entry)?.control.fileState == .verified || existingTask(entry) != nil || retryDeadline(entry) != nil)
                    ModelSpecificationFields(descriptor: descriptor(entry), font: .caption)
                    Text(ModelLibraryModel.formatBytes(entry.totalBytes)).font(.caption)
                    Text(acquisitionState(entry)).font(.caption).foregroundStyle(.secondary)
                    if let resource = existingResource(entry), resource.control.fileState == .verified {
                        Button(text("viewResource", "查看对应模型")) { model.selectedResource = resource.id; model.workspace = "resources"; narrowDetail = true; acquireVisible = false }
                    } else if let task = existingTask(entry) {
                        Button(text("viewDownload", "查看下载任务")) { model.selectedTask = task.id; model.workspace = "downloads"; narrowDetail = true; acquireVisible = false }
                    }
                    DisclosureGroup(text("technical", "身份与来源详情")) {
                        Text(entry.repository).textSelection(.enabled)
                        WorkflowTechnicalDetails(value: entry.id + "\n" + entry.revision)
                        Text(catalogText(entry, field: "memory")).font(.caption)
                    }
                }.padding(.vertical, 6)
            }
            HStack {
                Text(model.rootURL?.path ?? text("noRoot", "尚未选择模型库位置")).font(.caption).textSelection(.enabled)
                Spacer()
                Button(text("chooseRoot", "选择文件夹…")) { Task { await model.chooseRoot() } }.disabled(!model.canChooseRoot)
            }
            Toggle(text("downloadRegister", "下载完成后自动登记模型"), isOn: $registerAfterDownload)
            Text(text("newTasks", "需要下载") + ": \(newDownloads.count) · " + text("newBytes", "预计新增下载量") + ": " + additionalBytesLabel).font(.callout)
            if !model.queueIsRunning { Text(text("queuePausedHelp", "下载已暂停，开始全部后将继续。")).font(.caption) }
            if let error = model.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button(text("cancel", "取消")) { acquireVisible = false }
                Spacer()
                Button(workflowText(language, "modelManagement." + (model.queueIsRunning ? "enqueue" : "enqueuePaused"), arguments: ["count": String(newDownloads.count)])) {
                    let ids = newDownloads.map(\.id)
                    Task { await model.enqueue(ids, register: registerAfterDownload); if model.errorMessage == nil { acquireVisible = false; model.workspace = "downloads"; narrowDetail = false } }
                }.disabled(newDownloads.isEmpty || model.rootURL == nil || !model.pendingCatalogIDs.isEmpty)
            }
        }.buttonStyle(.bordered).padding(20).frame(minWidth: 620, idealWidth: 760, minHeight: 500, idealHeight: 620)
    }
    private var localImport: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(text("import", "登记已有…")).font(.title2.bold()); Spacer(); Button(text("close", "完成")) { importVisible = false } }
            WorkbenchPicker(text("configuration", "配置"), selection: $importCatalogID) {
                WorkbenchChoice(text("existingRoute", "已有引擎支持的精确配置"), value:"")
                WorkbenchChoiceForEach(model.catalog) { WorkbenchChoice($0.title, value:$0.id) }
            }
            if importCatalogID.isEmpty {
                WorkbenchPicker(text("kind", "用途"), selection: $importKind) {
                    WorkbenchChoiceForEach([WorkflowModelKind.text, .image, .music, .video], id: \.rawValue) { kind in WorkbenchChoice(text("kind." + kind.rawValue, kind.rawValue), value:kind) }
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
    private func descriptor(_ entry: ModelCatalogEntry?) -> ModelNodeDescriptor? {
        guard let entry else { return nil }
        return ModelNodeCatalog.entries.first { $0.revision == entry.revision && ($0.id == entry.workflowIdentity || $0.modelIdentity == entry.repository) }
    }
    private func taskStatus(_ task: ModelDownloadTask) -> String {
        if let pending = model.pendingActions[task.resourceID.modelID] { return text("pending." + String(describing: pending), pending.title) }
        if task.state == .queued, !model.queueIsRunning { return text("waitingQueue", "等待队列开始") }
        if task.state == .completed, task.postActionError != nil, model.snapshot?.resources.first(where: { $0.id == task.resourceID })?.record.registrationState != .registered { return text("registrationIncomplete", "下载完成 · 登记未完成") }
        return downloadState(task.state)
    }
    @ViewBuilder private func taskPrimary(_ task: ModelDownloadTask) -> some View {
        if model.pendingActions[task.resourceID.modelID] != nil { ProgressView().controlSize(.small) }
        else {
            switch task.state {
            case .downloading, .verifying, .publishing:
                Button(text("pauseTask", "暂停")) { Task { await model.pauseTask(task.id) } }.help(text("pauseHelp", "暂时暂停，可继续下载。"))
            case .paused, .cancelled, .failed:
                Button(text(!model.queueIsRunning ? "queueOne" : task.state == .paused ? "continue" : task.state == .failed ? "retry" : "start", "继续")) { Task { await model.continueTask(task) } }
                    .disabled((task.earliestRetry ?? .distantPast) > Date())
            case .completed:
                let resource = model.snapshot?.resources.first { $0.id == task.resourceID }
                Button(text("showFile", "查看文件")) { if let resource { model.reveal(resource) } }
                    .disabled(resource?.record.directory == nil || resource?.record.availability != .available)
            case .queued, .waitingRetry: EmptyView()
            }
        }
    }
    private func taskMenu(_ task: ModelDownloadTask) -> some View {
        WorkbenchMenu(consistencyText(language, "copy.more"), systemImage: "ellipsis") {
            if !task.state.isTerminal {
                WorkbenchMenuAction(text("stop", "停止")) { Task { await model.cancelTask(task.id, keepPartial: true) } }.help(text("stopHelp", "结束本次下载，保留已下载部分。"))
            }
            if task.state == .queued && task.attempts == 0 {
                WorkbenchMenuAction(text("up", "上移")) { Task { await model.move(task.id, by: -1) } }
                WorkbenchMenuAction(text("down", "下移")) { Task { await model.move(task.id, by: 1) } }
            }
            if task.state == .failed {
                WorkbenchMenuAction(text("viewError", "查看错误")) { model.selectedTask = task.id; narrowDetail = true }
            }
            if task.state == .failed || task.state == .cancelled {
                WorkbenchMenuAction(text("restart", "重新下载…")) { Task { await model.restartTask(task) } }
            }
            if task.state == .completed, let resource = model.snapshot?.resources.first(where: { $0.id == task.resourceID }) {
                WorkbenchMenuAction(text("viewResource", "查看对应模型")) { model.selectedResource = resource.id; model.workspace = "resources"; narrowDetail = true }
            }
            WorkbenchMenuDivider()
            WorkbenchMenuAction(text(task.state == .completed ? "deleteRecord" : "deleteTask", "删除…"), role: .destructive) {
                cleanupPartial = false; deletingTask = task
            }
        }.disabled(model.pendingActions[task.resourceID.modelID] != nil)
            .environment(\.workbenchMenuContext, "download:\(task.id):\(task.generation):\(task.state)")
            .buttonStyle(.plain)
    }
    private func canCleanPartial(_ task: ModelDownloadTask) -> Bool {
        guard task.state != .completed, let resource = model.snapshot?.resources.first(where: { $0.id == task.resourceID }) else { return false }
        return resource.record.storage == .managed && ([.partial, .invalid].contains(resource.control.fileState) || resource.control.fileState == .deleting && ![.installed, .preparationRequired].contains(resource.record.state)) && resource.record.activeLeaseCount == 0
    }
    private func deleteConfirmation(_ task: ModelDownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(text("deleteTaskTitle", "删除这条下载记录？")).font(.title2.bold())
            Text(model.catalog.first(where: { $0.id == task.catalogID })?.title ?? task.catalogID)
            Text(text("deleteTaskHelp", "不会删除已完成的模型文件。"))
            if !task.state.isTerminal { Text(text("deleteActiveHelp", "此任务会先停止，正在写入的内容处理结束后再删除记录。")) }
            if canCleanPartial(task) { Toggle(text("cleanupPartial", "同时删除这项任务未完成的下载文件"), isOn: $cleanupPartial) }
            if let error = model.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button(text("cancel", "取消")) { deletingTask = nil }
                Spacer()
                Button(text("deleteConfirm", "删除"), role: .destructive) {
                    let clean = cleanupPartial
                    Task { await model.deleteTask(task, cleanupPartial: clean); if model.errorMessage == nil { deletingTask = nil } }
                }.disabled(model.pendingActions[task.resourceID.modelID] != nil)
            }
        }.padding(24).frame(width: 520).buttonStyle(.bordered)
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
        model.catalog.filter { downloadSelection.contains($0.id) && existingResource($0)?.control.fileState != .verified && existingTask($0) == nil && retryDeadline($0) == nil }
    }
    private func retryDeadline(_ entry: ModelCatalogEntry) -> Date? {
        guard let date = existingResource(entry)?.control.retryNotBefore, date > Date() else { return nil }
        return date
    }
    private var additionalBytesLabel: String {
        let values = newDownloads.map { ModelLibraryModel.additionalDownloadBytes($0, resource: existingResource($0)) }
        guard values.allSatisfy({ $0 != nil }) else { return text("unknownAdditionalBytes", "待核实；已有进度尚未通过完整校验") }
        return ModelLibraryModel.formatBytes(values.compactMap { $0 }.reduce(0, +))
    }
    private func acquisitionState(_ entry: ModelCatalogEntry) -> String {
        if let deadline = retryDeadline(entry) { return workflowText(language, "modelManagement.retryAfter", arguments: ["time": deadline.formatted()]) }
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

/// The settings destination owns preferences only; inventory and queue stay in
/// their explicit manager routes and share the same application service.
struct ModelStorageDownloadSettings: View {
    @Bindable var model: ModelLibraryModel
    @Environment(\.dLanguageStore) private var language
    private func text(_ key: String) -> String { workflowText(language, "modelManagement." + key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(text("storageTitle")).font(.headline)
            Text(model.rootURL?.path ?? text("noRoot")).textSelection(.enabled)
            Button(text("chooseRoot")) { Task { await model.chooseRoot() } }.disabled(!model.canChooseRoot)
            Text(text("rootHelp")).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(text("accessToken")).font(.headline)
            Text(model.downloadCredentialConnected ? text("credentialConnected") : text("credentialMissing"))
            Button(text("credentialChoose")) { Task { await model.chooseDownloadCredential() } }.disabled(!model.canChangeDownloadCredential)
            if model.downloadCredentialConnected { Button(text("credentialRemove")) { Task { await model.removeDownloadCredential() } }.disabled(!model.canChangeDownloadCredential) }
            Text(text("credentialHelp")).font(.caption).foregroundStyle(.secondary)
            if let error = model.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }.buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
    }
}
