import AppKit
import DWorkbench
import SwiftUI

/// Two peers share real services and assets; navigation does not own inference.
public struct DualWorkbenchView: View {
    public enum Entry: String, CaseIterable { case quick, workflow }
    let model: WorkbenchModel
    let quickModel: WorkbenchModel
    let quick: QuickGenerationController
    let library: ModelLibraryModel
    let nodeTags: ModelNodeTagStore
    let metadata: SharedLibraryStore?
    let metadataIssue: String?
    @State private var projects: [ProjectManifest] = []
    @State private var fullLibraryState = SharedLibraryBrowserState()
    @State private var compactLibraryState = SharedLibraryBrowserState()
    @State private var previewAsset: LibraryAssetPreview?
    private struct FilesRoute: Identifiable {
        let store: ProjectStore
        let instanceID: UUID
        let assetID: UUID?
        var id: String { instanceID.uuidString + (assetID?.uuidString ?? "project") }
    }
    @State private var filesRoute: FilesRoute?
    @State private var pendingFilesRoute: FilesRoute?
    private enum LibraryDestination { case asset(LibraryAssetPreview), info(SharedLibraryBrowserEntry), models }
    @State private var pendingLibraryDestination: LibraryDestination?
    @State private var returnToLibrary = false
    @State private var libraryInfo: SharedLibraryBrowserEntry?
    private struct LibraryAssetPreview: Identifiable { let store: ProjectStore; let reference: WorkflowAssetReference; var id: WorkflowAssetReference { reference } }
    private var entries: [SharedLibraryBrowserEntry] {
        SharedLibraryProjection.entries(models: quickModel.projectSession.explicitModelChoices,
            readiness: quickModel.projectSession.explicitModelReadiness,
            tools: canvasModel.projectSession.workflow?.tools ?? [], projects: projects, language: language)
    }
    @State private var entry: Entry = .quick
    @State private var entryHistory: [Entry] = []
    @State private var libraryVisible = false
    @State private var projectsVisible = false
    @State private var compatibilityVisible = false
    @State private var languageVisible = false
    @State private var issue: String?
    @State private var failedAssetRoute: FilesRoute?
    @Environment(\.dLanguageStore) private var language
    private var canvasModel: WorkbenchModel { model.manifest == nil ? quickModel : model }
    private var installationStates: [String] {
        library.records.map { "\($0.id):\($0.state.rawValue):\($0.availability.rawValue)" }.sorted()
    }
    public init(model: WorkbenchModel, quickModel: WorkbenchModel, quick: QuickGenerationController,
                library: ModelLibraryModel, nodeTags: ModelNodeTagStore, metadata: SharedLibraryStore?, metadataIssue: String? = nil) {
        self.model = model; self.quickModel = quickModel; self.quick = quick; self.library = library; self.nodeTags = nodeTags; self.metadata = metadata; self.metadataIssue = metadataIssue
    }
    private func navigate(to destination: Entry) {
        guard destination != entry else { return }
        entryHistory.append(entry); entry = destination
    }
    private func goBack() {
        guard let previous = entryHistory.popLast() else { return }
        entry = previous
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button(action: goBack) {
                    Label(baselineText(language, "label.572cf45ba436", fallback: "返回"), systemImage: "chevron.left")
                }
                .disabled(entryHistory.isEmpty)
                .accessibilityIdentifier("workbench-back")
                Text("D").font(.title2.bold())
                Picker(baselineText(language, "label.78d18c6b29c7", fallback: "工作方式"), selection: Binding(get: { entry }, set: navigate)) {
                    Text(baselineText(language, "label.893819bb34b0", fallback: "快速生成")).tag(Entry.quick)
                    Text(baselineText(language, "label.c71d0bca46eb", fallback: "工作流")).tag(Entry.workflow)
                }.pickerStyle(.segmented).frame(width: 230).accessibilityIdentifier("workbench-entry")
                Spacer()
                if entry == .workflow {
                    Button(canvasModel.manifest?.name ?? "流程项目") { projectsVisible = true }
                }
                if let manifest = (entry == .quick ? quickModel.manifest : canvasModel.manifest),
                   let store = (entry == .quick ? quickModel.projectSession.currentStore : canvasModel.projectSession.currentStore) {
                    Button(baselineText(language, "files.title", fallback: "项目文件")) {
                        filesRoute = .init(store: store, instanceID: manifest.effectiveInstanceID, assetID: nil)
                    }.accessibilityIdentifier("project-files-open")
                }
                Button { libraryVisible = true } label: { Label(baselineText(language, "label.433bdcb25776", fallback: "资料库"), systemImage: "square.stack.3d.up") }
                    .accessibilityIdentifier("shared-library-open")
                Menu {
                    Button(baselineText(language, "label.a6b4608f6c77", fallback: "项目…")) { projectsVisible = true }
                    if let manifest = (entry == .quick ? quickModel.manifest : canvasModel.manifest),
                       let store = (entry == .quick ? quickModel.projectSession.currentStore : canvasModel.projectSession.currentStore) {
                        Button(baselineText(language, "files.title", fallback: "项目文件…")) {
                            filesRoute = .init(store: store, instanceID: manifest.effectiveInstanceID, assetID: nil)
                        }
                    }
                    Button(baselineText(language, "label.7e060553182c", fallback: "创作文稿与原有编辑器…")) { compatibilityVisible = true }
                    Button(baselineText(language, "label.17bb056515cd", fallback: "模型下载与安装…")) { library.isPresented = true }
                    Button(baselineText(language, "label.f1df761fb2f8", fallback: "显示语言…")) { languageVisible = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            Divider()
            ZStack {
                QuickGenerationView(quick: quick, model: quickModel, onChooseModel: { libraryVisible = true },
                    onSettingsToCanvas: { draft in Task { await settingsToCanvas(draft) } },
                    onResultToCanvas: { ref in Task { await resultToCanvas(ref) } },
                    onValueToCanvas: { value in Task { await valueToCanvas(value) } },
                    onAssetsChanged: { Task { await refreshLibrary(checkModels: false) } })
                    .opacity(entry == .quick ? 1 : 0).allowsHitTesting(entry == .quick).accessibilityHidden(entry != .quick)
                WorkflowHostView(model: canvasModel, nodeTags: nodeTags, onQuickUse: useNode,
                    libraryContent: { point, close in AnyView(libraryBrowser(compact: true, at: point, onBack: close)) },
                    onSharedAssetDrop: acceptSharedAssetDrop,
                    acceptsLegacyAsset: { projectID, assetID in
                        guard let instance = SharedLibraryProjection.resolvedInstanceID(projectID: projectID,
                            instanceID: nil, projects: projects) else { return false }
                        return canvasModel.projectSession.workflow?.projectInstanceID == instance &&
                            projects.contains(where: { $0.effectiveInstanceID == instance && $0.assets.contains(where: { $0.id == assetID }) })
                    })
                    .opacity(entry == .workflow ? 1 : 0).allowsHitTesting(entry == .workflow).accessibilityHidden(entry != .workflow)
            }

        }
        .frame(minWidth: 860, minHeight: 580)
        .sheet(isPresented: $libraryVisible, onDismiss: finishLibraryDismissal) {
            libraryBrowser(compact: false, at: CGPoint(x: 160, y: 140))
                .frame(minWidth: 820, minHeight: 540)
                .task { await refreshLibrary(checkModels: true) }
        }
        .sheet(isPresented: $projectsVisible) {
            VStack(spacing: 0) {
                HStack { Button(baselineText(language, "label.572cf45ba436", fallback: "返回")) { projectsVisible = false }.keyboardShortcut(.cancelAction); Text(baselineText(language, "label.79f326be4409", fallback: "项目")).font(.headline); Spacer() }.padding()
                ProjectChooserView(recentProjects: model.recentProjects, isBusy: model.isChangingProject,
                    onNew: { Task { if await model.newProject() { projectsVisible = false; navigate(to: .workflow) } } },
                    onOpen: { Task { if await model.openProject() { projectsVisible = false; navigate(to: .workflow) } } },
                    onRecent: { id in Task { if await model.openRecentProject(id: id) { projectsVisible = false; navigate(to: .workflow) } } },
                    onModels: { library.isPresented = true })
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
                }
            }.frame(minWidth: 640, minHeight: 420)
        }
        .sheet(item: $filesRoute) { route in
            ProjectFilesView(store: route.store, instanceID: route.instanceID,
                isActive: { (canvasModel.projectSession.currentStore === route.store &&
                    canvasModel.manifest?.effectiveInstanceID == route.instanceID) ||
                    (quickModel.projectSession.currentStore === route.store &&
                     quickModel.manifest?.effectiveInstanceID == route.instanceID) },
                modelLibrary: library.library,
                onContentsChanged: { changedStore, instanceID in
                    let primary = model.projectSession
                    let quickOwner = quickModel.projectSession
                    if primary.currentStore === changedStore {
                        await primary.refreshAfterFileOperation(store: changedStore, instanceID: instanceID)
                    }
                    if quickOwner !== primary, quickOwner.currentStore === changedStore {
                        await quickOwner.refreshAfterFileOperation(store: changedStore, instanceID: instanceID)
                    }
                    guard (primary.currentStore === changedStore && primary.manifest?.effectiveInstanceID == instanceID) ||
                          (quickOwner.currentStore === changedStore && quickOwner.manifest?.effectiveInstanceID == instanceID) else { return }
                    await refreshLibrary(checkModels: false)
                },
                saveDraftsForBackup: { captured, instanceID in
                    guard captured === route.store, instanceID == route.instanceID else {
                        throw WorkflowIssue("项目已切换；备份未创建。")
                    }
                    let primary = model.projectSession
                    let quickOwner = quickModel.projectSession
                    let primaryMatches = primary.currentStore === captured && primary.manifest?.effectiveInstanceID == instanceID
                    let quickMatches = quickOwner.currentStore === captured && quickOwner.manifest?.effectiveInstanceID == instanceID
                    guard primaryMatches || quickMatches else { throw WorkflowIssue("项目已切换；备份未创建。") }
                    if primaryMatches { try await primary.saveWorkflowForBackup(store: captured, instanceID: instanceID) }
                    if quickOwner !== primary && quickMatches {
                        try await quickOwner.saveWorkflowForBackup(store: captured, instanceID: instanceID)
                    }
                    try Task.checkCancellation()
                    guard (primary.currentStore === captured && primary.manifest?.effectiveInstanceID == instanceID) ||
                          (quickOwner.currentStore === captured && quickOwner.manifest?.effectiveInstanceID == instanceID) else {
                        throw WorkflowIssue("项目已切换；备份未创建。")
                    }
                    if quick.store === captured && quick.isLoaded { try await quick.flush() }
                    try Task.checkCancellation()
                    guard (primary.currentStore === captured && primary.manifest?.effectiveInstanceID == instanceID) ||
                          (quickOwner.currentStore === captured && quickOwner.manifest?.effectiveInstanceID == instanceID) else {
                        throw WorkflowIssue("项目已切换；备份未创建。")
                    }
                },
                onOpenRestored: { url in
                    await model.openProject(at: url)
                    if model.projectSession.currentStore?.rootURL.standardizedFileURL == url.standardizedFileURL {
                        filesRoute = nil; navigate(to: .workflow); await refreshLibrary(checkModels: false)
                        return nil
                    }
                    return model.errorMessage ?? "无法打开已恢复项目；请使用项目入口重新选择。"
                }, onOpenGraph: { graphID, nodeID in
                    guard ((model.projectSession.currentStore === route.store &&
                            model.manifest?.effectiveInstanceID == route.instanceID) ||
                           (quickModel.projectSession.currentStore === route.store &&
                            quickModel.manifest?.effectiveInstanceID == route.instanceID)),
                          let controller = canvasModel.projectSession.workflow,
                          controller.projectInstanceID == route.instanceID,
                          controller.graphs.contains(where: { $0.id == graphID && $0.nodes.contains(where: { $0.id == nodeID }) }) else { return false }
                    controller.selectedGraphID = graphID; controller.selectedNodeID = nodeID
                    returnToLibrary = false; filesRoute = nil; navigate(to: .workflow)
                    return true
                }, onClose: { filesRoute = nil }, initialAssetID: route.assetID)
        }
        .sheet(isPresented: $compatibilityVisible) {
            VStack(spacing: 0) {
                HStack { Button(baselineText(language, "label.572cf45ba436", fallback: "返回")) { compatibilityVisible = false }.keyboardShortcut(.cancelAction); Text(baselineText(language, "label.6f5cabc6a134", fallback: "创作文稿与模态编辑器")); Spacer() }.padding()
                WorkbenchView(model: model, library: library, nodeTags: nodeTags)
            }.frame(minWidth: 960, minHeight: 650)
        }
        .sheet(isPresented: Binding(get: { library.isPresented }, set: { library.isPresented = $0 }), onDismiss: restoreLibraryIfNeeded) {
            ModelLibraryView(model: library, selectedModelID: quickModel.projectSession.workflowInstallationID(for: quick.draft?.node.parameters["modelID"]?.string), canSelect: true, onPrepare: { id, parent in
                // Preparing resources does not navigate or replace a newer draft.
                _ = try await quickModel.projectSession.prepareWorkflowVideo(id: id, in: parent)
                await refreshLibrary(checkModels: false)
            }) { id in
                do {
                    let choice = try await quickModel.projectSession.selectWorkflowInstallation(id: id)
                    guard let operation = WorkflowModelRoutes.operation(for: choice) else { throw WorkflowIssue("此模型没有可用的共享操作。") }
                    quick.select(operationID: operation, modelID: choice.id)
                    returnToLibrary = false; library.isPresented = false; navigate(to: .quick)
                    await refreshLibrary(checkModels: false)
                } catch is CancellationError { }
                catch { issue = error.localizedDescription }
            }
        }
        .sheet(isPresented: $languageVisible) {
            VStack {
                HStack { Button(baselineText(language, "label.572cf45ba436", fallback: "返回")) { languageVisible = false }.keyboardShortcut(.cancelAction); Spacer() }
                if let language { LanguageSettingsView(store: language) }
            }.padding().frame(width: 560, height: 440)
        }
        .alert("操作未完成", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil; failedAssetRoute = nil } })) {
            Button(baselineText(language, "label.f867f3417859", fallback: "好")) { issue = nil; failedAssetRoute = nil }
            if let failedAssetRoute {
                Button(baselineText(language, "files.inspect", fallback: "查看文件位置")) {
                    issue = nil; self.failedAssetRoute = nil
                    if libraryVisible { returnToLibrary = true; pendingFilesRoute = failedAssetRoute; libraryVisible = false }
                    else { filesRoute = failedAssetRoute }
                }
            }
        } message: { Text(issue ?? "") }
        .task {
            if quick.draft == nil { quick.select(operationID: "d.model.language", modelID: "") }
            await refreshLibrary(checkModels: false)
        }
        // Draft autosaves do not change installed models or assets. Refresh at
        // result/publication boundaries, not on every typing pause.
        .onChange(of: quick.isRunning) { _, running in if !running { Task { await refreshLibrary(checkModels: false) } } }
        .onChange(of: quick.pendingSaveRunID) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .onChange(of: library.isPresented) { _, presented in if !presented { Task { await refreshLibrary(checkModels: false) } } }
        .onChange(of: installationStates) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .onChange(of: model.manifest?.revision) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .sheet(item: $previewAsset, onDismiss: {
            if let pendingFilesRoute {
                returnToLibrary = false; filesRoute = pendingFilesRoute; self.pendingFilesRoute = nil
            }
            else { restoreLibraryIfNeeded() }
        }) { value in
            VStack {
                HStack { Button(baselineText(language, "label.572cf45ba436", fallback: "返回")) { previewAsset = nil }.keyboardShortcut(.cancelAction); Spacer() }
                QuickAssetPreview(store: value.store, reference: value.reference, compact: false)
                Button(baselineText(language, "files.inspect", fallback: "查看文件位置")) {
                    Task {
                        let snapshot = await value.store.snapshot()
                        pendingFilesRoute = .init(store: value.store, instanceID: snapshot.effectiveInstanceID,
                            assetID: value.reference.assetID)
                        previewAsset = nil
                    }
                }
            }.padding(20).frame(minWidth: 560, minHeight: 360)
        }
        .sheet(item: $libraryInfo, onDismiss: restoreLibraryIfNeeded) { value in
            VStack(alignment: .leading, spacing: 14) { HStack { Button(baselineText(language, "label.572cf45ba436", fallback: "返回")) { libraryInfo = nil }; Text(value.item.title).font(.title2); Spacer() }
                Text(value.item.detail); ForEach(value.facts, id: \.self) { Text($0).textSelection(.enabled) }
                if case .unavailable = value.selection { Button(baselineText(language, "label.32d818ead29f", fallback: "打开已有编辑器")) { returnToLibrary = false; libraryInfo = nil; libraryVisible = false; compatibilityVisible = true } }
            }.padding(24).frame(minWidth: 550, minHeight: 280)
        }
        .focusedSceneValue(\.workbenchGeneration, WorkbenchGenerationCommand(title: "快速生成", isEnabled: quickCommandEnabled,
            action: { if quickCommandEnabled { quick.start() } }))
    }
    private func presentLibraryDestination(_ value: LibraryDestination) {
        if libraryVisible {
            returnToLibrary = true; pendingLibraryDestination = value; libraryVisible = false
        } else { openLibraryDestination(value) }
    }
    private func finishLibraryDismissal() {
        if let pendingFilesRoute {
            self.pendingFilesRoute = nil; returnToLibrary = false; filesRoute = pendingFilesRoute
            return
        }
        guard let pending = pendingLibraryDestination else { return }
        pendingLibraryDestination = nil; openLibraryDestination(pending)
    }
    private func openLibraryDestination(_ value: LibraryDestination) {
        switch value {
        case .asset(let preview): previewAsset = preview
        case .info(let item): libraryInfo = item
        case .models: library.isPresented = true
        }
    }
    private func restoreLibraryIfNeeded() {
        guard returnToLibrary else { return }
        returnToLibrary = false; libraryVisible = true
    }
    private var quickCommandEnabled: Bool {
        entry == .quick && quick.canStart && !libraryVisible && !projectsVisible && !compatibilityVisible &&
        !languageVisible && !library.isPresented && previewAsset == nil && libraryInfo == nil &&
        filesRoute == nil && pendingFilesRoute == nil
    }
    @ViewBuilder private func libraryBrowser(compact: Bool, at point: CGPoint, onBack: (() -> Void)? = nil) -> some View {
        if let metadata {
            SharedLibraryBrowser(entries: entries, store: metadata, compact: compact, state: compact ? compactLibraryState : fullLibraryState,
                onUse: useLibraryEntry, onAdd: { value in Task { await addLibraryEntry(value, at: point) } },
                onPreview: { value in Task { await previewLibraryEntry(value) } },
                onLocation: { value in Task { await showAssetLocation(value) } },
                onPrepare: { value in Task { await prepareModel(value) } },
                onImport: { Task { await importLibraryAsset() } }, onClose: { if let onBack { onBack() } else { libraryVisible = false } })
        } else {
            VStack(alignment: .leading) {
                Button(baselineText(language, "label.572cf45ba436", fallback: "返回"), systemImage: "chevron.left") {
                    if let onBack { onBack() } else { libraryVisible = false }
                }
                Text(metadataIssue ?? "资料整理暂不可用，原件未改。").textSelection(.enabled)
                Button(baselineText(language, "label.17bb056515cd", fallback: "模型下载与安装…")) { libraryVisible = false; library.isPresented = true }
            }.padding()
        }
    }
    private func refreshLibrary(checkModels: Bool) async {
        quickModel.projectSession.refreshWorkflowModels()
        if model.projectSession !== quickModel.projectSession { model.projectSession.refreshWorkflowModels() }
        let installationSnapshot = await library.library.snapshot()
        quickModel.projectSession.observeModelAvailability(installationSnapshot)
        if model.projectSession !== quickModel.projectSession { model.projectSession.observeModelAvailability(installationSnapshot) }
        if checkModels { await quickModel.projectSession.checkExplicitModelReadiness() }
        let otherStore = model.projectSession.currentStore
        var snapshots = [await quick.store.snapshot()]
        if let otherStore, otherStore !== quick.store {
            let snapshot = await otherStore.snapshot()
            guard model.projectSession.currentStore === otherStore,
                  model.manifest?.effectiveInstanceID == snapshot.effectiveInstanceID else { return }
            snapshots.append(snapshot)
        }
        guard model.projectSession.currentStore === otherStore else { return }
        guard snapshots.allSatisfy({ incoming in
            projects.first(where: { $0.effectiveInstanceID == incoming.effectiveInstanceID })
                .map { incoming.revision >= $0.revision } ?? true
        }) else { return }
        projects = snapshots
        if let metadata {
            do {
                for value in entries where value.item.kind == .model || value.item.kind == .program {
                    switch nodeTags.readState(for: value.item.key) {
                    case .valid(let names): try metadata.importLegacyTags(names, for: value.item.key)
                    case .missing: break
                    case .corrupt: issue = "旧标签记录损坏，未迁移或覆盖：" + value.item.title
                    }
                }
            } catch { issue = error.localizedDescription }
        }
    }
    private func useLibraryEntry(_ value: SharedLibraryBrowserEntry) {
        guard case .operation(let operation, let id) = value.selection,
              let id, WorkflowRegistry.standard.operation(operation)?.definition.modelKind != nil else { presentLibraryDestination(.info(value)); return }
        quick.select(operationID: operation, modelID: id)
        libraryVisible = false; navigate(to: .quick)
    }
    private func useNode(_ node: WorkflowNode) {
        guard let controller = canvasModel.projectSession.workflow else { return }
        // Connected values are not silently guessed from stale history; the graph is untouched.
        guard controller.graph?.connections.contains(where: { $0.targetNode == node.id }) != true else {
            issue = "此节点包含连线输入。请先把所需结果存为素材，再在快速界面显式选择；未忽略连线或修改原节点。"; return
        }
        quick.useSettings(node); navigate(to: .quick)
    }
    private func store(for projectID: UUID, instanceID: UUID? = nil) async throws -> ProjectStore {
        var candidates: [(ProjectStore, ProjectManifest)] = [(quick.store, await quick.store.snapshot())]
        if let current = model.projectSession.currentStore, current !== quick.store {
            candidates.append((current, await current.snapshot()))
        }
        guard let resolved = SharedLibraryProjection.resolvedInstanceID(projectID: projectID,
            instanceID: instanceID, projects: candidates.map { $0.1 }),
            let found = candidates.first(where: { $0.1.effectiveInstanceID == resolved }) else {
            throw WorkflowIssue(instanceID == nil ? "旧素材拖放缺少实例身份；同一项目有多个实例，请从当前资料库重新拖放。" : "所属项目实例已关闭，请重新打开。")
        }
        return found.0
    }
    private func assetIdentity(_ selection: SharedLibraryBrowserSelection) -> (UUID, UUID?, UUID)? {
        switch selection {
        case .asset(let projectID, let assetID): return (projectID, nil, assetID)
        case .assetInstance(let projectID, let instanceID, let assetID): return (projectID, instanceID, assetID)
        default: return nil
        }
    }
    private func previewLibraryEntry(_ value: SharedLibraryBrowserEntry) async {
        failedAssetRoute = nil
        guard let identity = assetIdentity(value.selection) else { presentLibraryDestination(.info(value)); return }
        do { let source = try await store(for: identity.0, instanceID: identity.1)
            let ref = try await source.pinWorkflowAsset(identity.2)
            presentLibraryDestination(.asset(.init(store: source, reference: ref)))
        } catch {
            if let source = try? await store(for: identity.0, instanceID: identity.1) {
                let snapshot = await source.snapshot()
                if snapshot.assets.contains(where: { $0.id == identity.2 }) {
                    failedAssetRoute = .init(store: source, instanceID: snapshot.effectiveInstanceID, assetID: identity.2)
                }
            }
            issue = error.localizedDescription
        }
    }
    private func showAssetLocation(_ value: SharedLibraryBrowserEntry) async {
        guard let identity = assetIdentity(value.selection) else { return }
        do {
            var active = [(ProjectStore, ProjectManifest)]()
            if let current = quickModel.projectSession.currentStore {
                active.append((current, await current.snapshot()))
            }
            if let current = model.projectSession.currentStore,
               !active.contains(where: { $0.0 === current }) {
                active.append((current, await current.snapshot()))
            }
            guard let resolved = SharedLibraryProjection.resolvedInstanceID(projectID: identity.0,
                    instanceID: identity.1, projects: active.map { $0.1 }),
                  let source = active.first(where: { $0.1.effectiveInstanceID == resolved })?.0 else {
                throw WorkflowIssue("所属项目尚未打开，请从项目入口打开后再查看文件位置。")
            }
            let snapshot = await source.snapshot()
            guard snapshot.id == identity.0,
                  snapshot.assets.contains(where: { $0.id == identity.2 }),
                  (quickModel.projectSession.currentStore === source &&
                   quickModel.manifest?.effectiveInstanceID == snapshot.effectiveInstanceID) ||
                  (model.projectSession.currentStore === source &&
                   model.manifest?.effectiveInstanceID == snapshot.effectiveInstanceID) else {
                throw WorkflowIssue("所属项目尚未打开，请从项目入口打开后再查看文件位置。")
            }
            let route = FilesRoute(store: source, instanceID: snapshot.effectiveInstanceID, assetID: identity.2)
            if libraryVisible {
                returnToLibrary = true; pendingFilesRoute = route; libraryVisible = false
            } else { filesRoute = route }
        } catch { issue = error.localizedDescription }
    }
    private func prepareModel(_ value: SharedLibraryBrowserEntry) async {
        guard case .operation(let id, _) = value.selection, let kind = WorkflowRegistry.standard.operation(id)?.definition.modelKind else { presentLibraryDestination(.info(value)); return }
        if kind == .pitch { await refreshLibrary(checkModels: true); presentLibraryDestination(.info(value)); return }
        if [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38, WorkflowModelRoutes.fluxDev,
            WorkflowModelRoutes.ace, "d.image.generate", "d.music.generate"].contains(id) {
            presentLibraryDestination(.models); return
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "登记已有模型的原位置；不会复制、移动或删除权重。"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { let choice = try await quickModel.projectSession.registerExplicitModel(at: url, kind: kind)
            quick.select(operationID: id, modelID: choice.id)
            await refreshLibrary(checkModels: true)
        } catch { issue = error.localizedDescription }
    }
    private func importLibraryAsset() async {
        guard let (url, mode) = await NativeAssetImportPanel.choose(language: language) else { return }
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do { _ = try await quick.store.importWorkflowMediaFile(at: url, mode: mode); await refreshLibrary(checkModels: false) }
        catch { issue = error.localizedDescription }
    }
    private func addLibraryEntry(_ value: SharedLibraryBrowserEntry, at point: CGPoint) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { return }
        do {
            switch value.selection {
            case .operation(let id, let modelID): controller.addNode(operationID: id, modelID: modelID, x: point.x, y: point.y)
            case .tool(let reference):
                guard let tool = controller.tools.first(where: { $0.id == reference.id && $0.version == reference.version && (try? WorkflowPlanCompiler.digest($0)) == reference.digest }) else { throw WorkflowIssue("工具不属于当前项目的固定版本。") }
                controller.addTool(tool, x: point.x, y: point.y)
            case .asset, .assetInstance:
                guard let identity = assetIdentity(value.selection) else { throw WorkflowIssue("素材身份无效。") }
                let source = try await store(for: identity.0, instanceID: identity.1)
                let ref = try await source.pinWorkflowAsset(identity.2)
                let copied = try await copiedReference(ref, from: source, to: controller.services.store)
                guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变。") }
                try await controller.insertQuickResult(copied, target: scope, x: point.x, y: point.y)
            case .unavailable(let reason): throw WorkflowIssue(reason)
            }
            try await controller.saveExplicitEdits()
            libraryVisible = false; navigate(to: .workflow)
        } catch { issue = error.localizedDescription }
    }
    private func copiedReference(_ reference: WorkflowAssetReference, from original: ProjectStore? = nil, to destination: ProjectStore) async throws -> WorkflowAssetReference {
        let source = original ?? quick.store
        if destination === source { return reference }
        return try await destination.copyWorkflowAsset(reference, from: source)
    }
    private func copiedDatum(_ value: WorkflowDatum, to destination: ProjectStore) async throws -> WorkflowDatum {
        try value.validate()
        var copies: [WorkflowAssetReference: WorkflowAssetReference] = [:]
        for ref in value.assetReferences where copies[ref] == nil {
            copies[ref] = try await copiedReference(ref, to: destination)
        }
        func replace(_ datum: WorkflowDatum) throws -> WorkflowDatum {
            switch datum {
            case .asset(let ref):
                guard let copy = copies[ref] else { throw WorkflowIssue("缺少已复制的素材引用。") }
                return .asset(copy)
            case .record(let schema, let fields): return .record(schema: schema, fields: try fields.mapValues(replace))
            case .list(let element, let items): return .list(element: element, items: try items.map { .init(id: $0.id, value: try replace($0.value)) })
            case .result(var result): result.value = try result.value.map(replace); return .result(result)
            default: return datum
            }
        }
        return try replace(value)
    }
    private func acceptSharedAssetDrop(_ projectID: UUID, _ instanceID: UUID?, _ assetID: UUID,
                                       _ point: CGPoint, _ target: WorkflowCanvasInsertionTarget) -> Bool {
        guard let controller = canvasModel.projectSession.workflow, controller.isCurrent(target),
              let resolved = SharedLibraryProjection.resolvedInstanceID(projectID: projectID,
                  instanceID: instanceID, projects: projects),
              projects.contains(where: { $0.effectiveInstanceID == resolved && $0.assets.contains(where: { $0.id == assetID }) }) else { return false }
        let owner = canvasModel.projectSession
        Task {
            do {
                let source = try await store(for: projectID, instanceID: resolved)
                let ref = try await source.pinWorkflowAsset(assetID)
                let copied = try await copiedReference(ref, from: source, to: controller.services.store)
                guard owner.workflow === controller, controller.isCurrent(target) else { throw WorkflowIssue("拖放期间目标已改变，未插入其他流程。") }
                try await controller.insertQuickResult(copied, target: target, x: point.x, y: point.y)
            } catch { issue = error.localizedDescription }
        }
        return true
    }
    private func settingsToCanvas(_ draft: QuickDraft) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { issue = "流程当前不可编辑"; return }
        do {
            var copy = draft
            for (port, value) in copy.inputs {
                guard let datum = value.datum else { throw WorkflowIssue("请先选择单项输入，不能隐式复制候选集合。") }
                copy.inputs[port] = .data(try await copiedDatum(datum, to: controller.services.store))
            }
            guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变，未放入其他流程。") }
            try await controller.insertQuickSettings(copy, target: scope)
            navigate(to: .workflow)
        } catch { issue = error.localizedDescription }
    }
    private func resultToCanvas(_ ref: WorkflowAssetReference) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { issue = "流程当前不可编辑"; return }
        do {
            let copy = try await copiedReference(ref, to: controller.services.store)
            guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变。") }
            try await controller.insertQuickResult(copy, target: scope)
            navigate(to: .workflow)
        } catch { issue = error.localizedDescription }
    }
    private func valueToCanvas(_ value: WorkflowDatum) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { issue = "流程当前不可编辑"; return }
        do {
            let copy = try await copiedDatum(value, to: controller.services.store)
            guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变。") }
            try await controller.insertQuickValue(copy, target: scope)
            navigate(to: .workflow)
        } catch { issue = error.localizedDescription }
    }
}
