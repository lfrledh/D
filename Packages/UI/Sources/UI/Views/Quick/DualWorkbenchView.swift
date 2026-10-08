import AppKit
import DWorkbench
import SwiftUI

/// Two peers share real services and assets; navigation does not own inference.
public struct DualWorkbenchView: View {
    public enum Entry: String, CaseIterable { case quick, workflow }
    let model: WorkbenchModel
    let automaticQuickModel: WorkbenchModel
    let automaticQuick: QuickGenerationController
    @State private var quickPreviewSelections: [String: [QuickCategory: WorkflowAssetReference]] = [:]
    @State private var useProjectQuick = true
    @State private var modelPickerCategory: QuickCategory?
    private var usesTemporaryChat: Bool { entry == .quick && quick.category == .text && quick.textPresentation == .chat && automaticQuickModel.temporaryChatModel != nil }
    private var chatModel: WorkbenchModel { usesTemporaryChat ? (automaticQuickModel.temporaryChatModel ?? quickModel) : quickModel }
    private var selectionModel: WorkbenchModel { usesTemporaryChat ? chatModel : quickModel }
    private var chat: ChatController? { chatModel.projectSession.chat }
    @State private var temporaryChatChanging = false
    private func changeTemporaryChat() {
        guard !temporaryChatChanging else { return }
        temporaryChatChanging = true
        Task { @MainActor in
            defer { temporaryChatChanging = false }
            do {
                if automaticQuickModel.temporaryChatModel == nil { try await automaticQuickModel.startTemporaryChat() }
                else { try await automaticQuickModel.endTemporaryChat() }
            } catch { issue = error.localizedDescription }
        }
    }
    private var quick: QuickGenerationController {
        useProjectQuick ? (model.projectSession.projectQuick ?? automaticQuick) : automaticQuick
    }
    private var quickModel: WorkbenchModel {
        useProjectQuick && model.projectSession.projectQuick != nil ? model : automaticQuickModel
    }
    private var quickOwnerIsChanging: Bool {
        quickModel.projectSession.isChangingProject || (useProjectQuick && model.projectSession.isChangingProject)
    }
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
    private struct LibraryAssetPreview: Identifiable {
        let store: ProjectStore
        let reference: WorkflowAssetReference
        let chatTarget: ChatController?
        let chatSessionID: UUID?
        let chatChoice: ChatProjectAttachmentChoice?
        var id: WorkflowAssetReference { reference }
    }
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
    @State private var settingsVisible = false
    @Binding private var settingsRequest: UUID?
    private let windowHasSheet: Bool
    private struct SettingsContext {
        let owner: WorkbenchModel
        let files: FilesRoute?
        let searchOwner: WorkbenchModel
        let search: ChatController?
        let searchSessionID: UUID?
        let searchTitle: String?
    }
    @State private var settingsContext: SettingsContext?
    @State private var openToolsRequest: ChatToolsNavigationRequest?
    @State private var settingsDestination: String?
    @State private var issue: String?
    @State private var failedAssetRoute: FilesRoute?
    @Environment(\.dLanguageStore) private var language
    private var canvasModel: WorkbenchModel { model.manifest == nil ? automaticQuickModel : model }
    private var installationStates: [String] {
        library.records.map { "\($0.id):\($0.state.rawValue):\($0.availability.rawValue)" }.sorted()
    }
    private var quickModelIdentity: String? {
        if quick.category == .text, quick.textPresentation == .chat, let modelID = chat?.selectedSession?.configuration?.parameters["modelID"]?.string {
            return modelID
        }
        return quick.draft?.node.parameters["modelID"]?.string
    }
    private var graphModelIdentities: Set<String> {
        canvasModel.projectSession.openGraphModelIdentities
    }
    public init(model: WorkbenchModel, quickModel: WorkbenchModel, quick: QuickGenerationController,
                library: ModelLibraryModel, nodeTags: ModelNodeTagStore, metadata: SharedLibraryStore?, metadataIssue: String? = nil, settingsRequest: Binding<UUID?> = .constant(nil), windowHasSheet: Bool = false) {
        self._settingsRequest = settingsRequest
        self.windowHasSheet = windowHasSheet
        self.model = model; self.automaticQuickModel = quickModel; self.automaticQuick = quick; self.library = library; self.nodeTags = nodeTags; self.metadata = metadata; self.metadataIssue = metadataIssue
    }
    private func t(_ key: String, _ en: String, _ zh: String) -> String {
        workflowText(language, "refinement.shell." + key,
            fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en)
    }
    private var canPresentSettings: Bool {
        !windowHasSheet && !settingsVisible && !libraryVisible && !projectsVisible && !compatibilityVisible && !languageVisible
            && filesRoute == nil && previewAsset == nil && libraryInfo == nil
            && pendingLibraryDestination == nil && pendingFilesRoute == nil
            && !library.isPresented && !library.isChoosingLocation && !model.hasPendingEditor
            && !quickOwnerIsChanging && !canvasModel.projectSession.isChangingProject
    }
    private func consumeSettingsRequest() {
        guard settingsRequest != nil else { return }
        if settingsVisible { settingsRequest = nil; return }
        guard canPresentSettings else { return }
        settingsRequest = nil
        presentSettings()
    }
    private func presentSettings() {
        guard canPresentSettings else { return }
        let owner = entry == .quick ? quickModel : canvasModel
        let files = owner.manifest.flatMap { manifest in owner.projectSession.currentStore.map {
            FilesRoute(store: $0, instanceID: manifest.effectiveInstanceID, assetID: nil)
        } }
        // Match the owner Quick/Text will actually display, including temporary chat.
        let searchOwner = automaticQuickModel.temporaryChatModel ?? quickModel
        let target = searchOwner.projectSession.chat
        settingsContext = .init(owner: owner, files: files, searchOwner: searchOwner, search: target,
            searchSessionID: target?.state.selectedSessionID,
            searchTitle: target.map { (searchOwner.manifest?.name ?? t("workspace", "Workspace", "工作区")) + " · " + ($0.selectedSession?.title ?? t("newConversation", "New conversation", "新会话")) })
        settingsDestination = nil
        settingsVisible = true
    }
    private func finishSettingsDismissal() {
        let context = settingsContext
        let destination = settingsDestination
        settingsContext = nil; settingsDestination = nil
        guard let context, let destination else { return }
        if destination == "files" {
            guard let route = context.files else { projectsVisible = true; return }
            guard context.owner.projectSession.currentStore === route.store,
                  context.owner.manifest?.effectiveInstanceID == route.instanceID else {
                issue = t("targetChanged", "The settings target changed. Open Settings again from the intended workspace.", "设置目标已改变，请回到目标工作区后重新打开设置。")
                return
            }
            filesRoute = route
        } else if destination == "search" {
            let expected = automaticQuickModel.temporaryChatModel ?? quickModel
            guard expected === context.searchOwner, let target = context.search,
                  expected.projectSession.chat === target,
                  target.state.selectedSessionID == context.searchSessionID,
                  !expected.projectSession.isChangingProject else {
                issue = t("targetChanged", "The settings target changed. Open Settings again from the intended workspace.", "设置目标已改变，请回到目标工作区后重新打开设置。")
                return
            }
            do {
                // Only this explicit action, not opening Settings, may create a session.
                if target.state.selectedSessionID == nil { _ = try target.newSession() }
                navigate(to: .quick); quick.selectCategory(.text); quick.selectTextPresentation(.chat)
                openToolsRequest = ChatToolsNavigationRequest(chat: target)
            } catch { issue = error.localizedDescription }
        }
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
            HStack(spacing: 12) {
                Button(action: goBack) { Image(systemName: "chevron.left") }
                    .disabled(entryHistory.isEmpty).help(t("back", "Back", "返回")).accessibilityIdentifier("workbench-back")
                Text("D").font(.title2.bold())
                Menu {
                    Button(t("projects", "Projects…", "项目…")) { projectsVisible = true }
                    if model.projectSession.projectQuick != nil {
                        Picker(t("draftLocation", "Quick draft location", "快速草稿位置"), selection: $useProjectQuick) {
                            Text(t("thisProject", "This project: ", "本项目：") + (model.manifest?.name ?? t("project", "Project", "项目"))).tag(true)
                            Text(t("globalQuick", "Global Quick workspace", "全局快速创作")).tag(false)
                        }
                    } else if model.manifest != nil {
                        Button(t("enableProjectQuick", "Enable Quick in this project", "在当前项目中快速创作")) { Task { await model.projectSession.enableProjectQuick(); useProjectQuick = true; navigate(to: .quick) } }
                    }
                    if let manifest = (entry == .quick ? quickModel.manifest : canvasModel.manifest),
                       let store = (entry == .quick ? quickModel.projectSession.currentStore : canvasModel.projectSession.currentStore) {
                        Button(t("projectFiles", "Project files and backups…", "项目文件与备份…")) { filesRoute = .init(store: store, instanceID: manifest.effectiveInstanceID, assetID: nil) }
                    }
                    Button(t("legacyEditors", "Documents and existing editors…", "创作文稿与原有编辑器…")) { compatibilityVisible = true }
                    Button(t("models", "Model downloads and installation…", "模型下载与安装…")) { library.isPresented = true }
                } label: { Image(systemName: "folder") }.help(t("projectsAndFiles", "Projects and files", "项目与文件"))
                Button { modelPickerCategory = nil; libraryVisible = true } label: { Image(systemName: "square.stack.3d.up") }
                    .help(t("library", "Library", "资料库")).accessibilityLabel(t("library", "Library", "资料库")).accessibilityIdentifier("shared-library-open")
                Spacer(minLength: 8)
                if entry == .quick {
                    Picker(t("category", "Creation category", "创作分类"), selection: Binding(get: { quick.category }, set: { quick.selectCategory($0) })) {
                        Text(workflowText(language, "quick.category.text", fallback: "文字")).tag(QuickCategory.text)
                        Text(workflowText(language, "quick.category.image", fallback: "图像")).tag(QuickCategory.image)
                        Text(workflowText(language, "quick.category.video", fallback: "视频")).tag(QuickCategory.video)
                        Text(workflowText(language, "quick.category.audio", fallback: "音频")).tag(QuickCategory.audio)
                    }.pickerStyle(.segmented).frame(width: 340)
                        .disabled(quickOwnerIsChanging).accessibilityIdentifier("quick-category")
                        .workbenchMotion(value: quick.category)
                } else { Text(t("workflow", "Node workflow", "节点工作流")).font(.headline).frame(width: 340) }
                Spacer(minLength: 8)
                Button { navigate(to: entry == .quick ? .workflow : .quick) } label: {
                    Image(systemName: entry == .quick ? "rectangle.3.group" : "bolt.fill").frame(width: 30, height: 30)
                        .contentTransition(.symbolEffect(.replace))
                }.buttonStyle(.bordered).buttonBorderShape(.circle)
                    .help(entry == .quick ? t("quickSwitch", "Quick generation · Switch to workflow", "快速生成 · 切换到工作流") : t("workflowSwitch", "Workflow · Switch to Quick generation", "工作流 · 切换到快速生成"))
                    .accessibilityLabel(entry == .quick ? t("switchToWorkflow", "Switch to workflow", "切换到工作流") : t("switchToQuick", "Switch to Quick generation", "切换到快速生成")).accessibilityIdentifier("workbench-entry").workbenchMotion(value: entry)
                Button(action: presentSettings) label: { Image(systemName: "gearshape").frame(width: 30, height: 30) }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).help(t("settings", "Settings", "设置")).accessibilityLabel(t("settings", "Settings", "设置"))
                    .accessibilityIdentifier("workbench-settings").disabled(!canPresentSettings)
            }.padding(.horizontal, 20).padding(.vertical, 12).workbenchPanel(cornerRadius: 0)
            Divider()
            if entry == .quick, let identity = quickModelIdentity,
               quickModel.projectSession.explicitModelChecking.contains(identity) {
                Text(t("checkingModel", "Checking selected model files and execution adapter…", "正在核验所选模型文件与执行适配…"))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 4)
            } else if entry == .workflow,
                      !canvasModel.projectSession.explicitModelChecking.isDisjoint(with: graphModelIdentities) {
                Text(t("checkingWorkflow", "Checking models used by this workflow…", "正在核验当前流程使用的模型…"))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 4)
            }
            ZStack {
                Group {
                    if entry == .quick {
                        if quick.category == .text, let chat {
                            VStack(spacing: 0) {
                                Picker(workflowText(language, "chat.textSurface", fallback: "文字工作面"),
                                    selection: Binding(get: { quick.textPresentation }, set: { quick.selectTextPresentation($0) })) {
                                    Text(workflowText(language, "chat.conversation", fallback: "聊天")).tag(QuickTextPresentation.chat)
                                    Text(workflowText(language, "chat.single", fallback: "单次生成与旧记录")).tag(QuickTextPresentation.single)
                                }.pickerStyle(.segmented).frame(maxWidth: 300).padding(.horizontal, 20)
                                    .accessibilityIdentifier("quick-text-surface")
                                if quick.textPresentation == .chat {
                                    HStack {
                                        Button(chat.isTemporary ? "End temporary chat / 结束临时会话" : "Temporary chat / 临时会话", action: changeTemporaryChat)
                                            .disabled(temporaryChatChanging).accessibilityIdentifier("chat-temporary-toggle")
                                        if chat.isTemporary {
                                            Text("Temporary cache only; no history, memory or normal backup. Explicit exports and remote tools may retain copies. / 仅临时缓存；不入长期历史、记忆或普通备份。显式导出与外部工具可能留存。")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(.horizontal, 20)
                                    ChatWorkbenchView(chat: chat, model: chatModel,
                                        onChooseModel: { modelPickerCategory = .text; libraryVisible = true },
                                        openToolsRequest: openToolsRequest,
                                        onToolsOpened: { id in if openToolsRequest?.id == id { openToolsRequest = nil } },
                                        onSavedAsset: { reference in
                                            Task {
                                                do {
                                                    if chat.isTemporary, let destination = automaticQuickModel.projectSession.currentStore {
                                                        let saved = try await chat.retainTemporaryText(reference, in: destination)
                                                        await resultToCanvas(saved, from: destination)
                                                    } else { await resultToCanvas(reference, from: chat.store) }
                                                } catch { issue = error.localizedDescription }
                                            }
                                        },
                                        onRetainTemporary: { reference, useInWorkflow, activity in
                                            guard let destination = automaticQuickModel.projectSession.currentStore else { throw WorkflowIssue("长期工作区不可用。") }
                                            let saved = try await chat.retainTemporaryText(reference, in: destination, admittedActivity: activity)
                                            await refreshLibrary(checkModels: false)
                                            try Task.checkCancellation()
                                            if useInWorkflow { await resultToCanvas(saved, from: destination) }
                                        },
                                        onAssetsChanged: { Task { await refreshLibrary(checkModels: false) } },
                                        onSavedValue: { value, activity in
                                            try Task.checkCancellation()
                                            if chat.isTemporary {
                                                guard let destination = automaticQuickModel.projectSession.currentStore,
                                                      case .record(let schema, var fields) = value,
                                                      case .asset(let source)? = fields["source"] else { throw WorkflowIssue("字段来源不可用。") }
                                                fields["source"] = .asset(try await chat.retainTemporaryText(source, in: destination, admittedActivity: activity))
                                                try Task.checkCancellation()
                                                await valueToCanvas(.record(schema: schema, fields: fields), from: destination)
                                            } else { await valueToCanvas(value, from: chat.store) }
                                        },
                                        onResolveSharedAsset: { projectID, instanceID, assetID in
                                            let source = try await store(for: projectID, instanceID: instanceID)
                                            let manifest = await source.snapshot()
                                            guard let asset = manifest.assets.first(where: { $0.id == assetID }) else { throw WorkflowIssue("源素材已不存在。") }
                                            let reference = try await source.pinWorkflowAsset(assetID)
                                            return (source, reference, asset.name)
                                        })
                                        .id(chat.store.rootURL.standardizedFileURL.path)
                                        .disabled(quickOwnerIsChanging || chat.isDiscarding || chatModel.projectSession.isChangingProject)
                                } else { quickSurface }
                            }
                        } else { quickSurface }
                    }
                }
                RetainedContentHost(content: WorkflowHostView(model: canvasModel, nodeTags: nodeTags, onQuickUse: useNode,
                    libraryContent: { point, close in AnyView(libraryBrowser(compact: true, at: point, onBack: close)) },
                    onSharedAssetDrop: acceptSharedAssetDrop,
                    acceptsLegacyAsset: { projectID, assetID in
                        guard let instance = SharedLibraryProjection.resolvedInstanceID(projectID: projectID,
                            instanceID: nil, projects: projects) else { return false }
                        return canvasModel.projectSession.workflow?.projectInstanceID == instance &&
                            projects.contains(where: { $0.effectiveInstanceID == instance && $0.assets.contains(where: { $0.id == assetID }) })
                    }).workbenchTheme().environment(\.dLanguageStore, language)
                    .preferredColorScheme(automaticQuickModel.chatDisplaySettings.preferences.preferredColorScheme)
                    .environment(\.chatDisplayPreferences, automaticQuickModel.chatDisplaySettings.preferences),
                    visible: entry == .workflow, identifier: "workflow-retained-surface",
                    fallbackSize: CGSize(width: 760, height: 500))
                    .transaction { $0.animation = nil }
                    .accessibilityHidden(entry != .workflow)
            }

        }
        .frame(minWidth: 860, minHeight: 580)
        .workbenchTheme()
        .environment(\.chatDisplayPreferences, automaticQuickModel.chatDisplaySettings.preferences)
        .preferredColorScheme(automaticQuickModel.chatDisplaySettings.preferences.preferredColorScheme)
        .onAppear { consumeSettingsRequest() }
        .onChange(of: settingsRequest) { _, _ in consumeSettingsRequest() }
        .onChange(of: canPresentSettings) { _, ready in if ready { consumeSettingsRequest() } }
        .sheet(isPresented: $settingsVisible, onDismiss: finishSettingsDismissal) {
            if let language, let context = settingsContext {
                WorkbenchSettingsView(model: context.owner, library: library, language: language,
                    projectPath: context.files?.store.rootURL.path, searchTargetLabel: context.searchTitle,
                    onProjectFiles: { settingsDestination = "files"; settingsVisible = false },
                    onSearchSettings: context.search == nil ? nil : { settingsDestination = "search"; settingsVisible = false })
            }
        }
        .sheet(isPresented: $libraryVisible, onDismiss: finishLibraryDismissal) {
            VStack(spacing: 0) {
                if !quickModel.projectSession.explicitModelChecking.isEmpty {
                    Text("正在核验模型文件与执行适配…")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                }
                libraryBrowser(compact: false, at: CGPoint(x: 160, y: 140))
            }
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
                    (automaticQuickModel.projectSession.currentStore === route.store &&
                     automaticQuickModel.manifest?.effectiveInstanceID == route.instanceID) },
                modelLibrary: library.library,
                onContentsChanged: { changedStore, instanceID, refreshMedia in
                    let primary = model.projectSession
                    let quickOwner = automaticQuickModel.projectSession
                    if primary.currentStore === changedStore {
                        await primary.refreshAfterFileOperation(store: changedStore, instanceID: instanceID,
                            refreshMedia: refreshMedia)
                    }
                    if quickOwner !== primary, quickOwner.currentStore === changedStore {
                        await quickOwner.refreshAfterFileOperation(store: changedStore, instanceID: instanceID,
                            refreshMedia: refreshMedia)
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
                    let quickOwner = automaticQuickModel.projectSession
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
                    if automaticQuick.store === captured && automaticQuick.isLoaded { try await automaticQuick.flush() }
                    try Task.checkCancellation()
                    guard (primary.currentStore === captured && primary.manifest?.effectiveInstanceID == instanceID) ||
                          (quickOwner.currentStore === captured && quickOwner.manifest?.effectiveInstanceID == instanceID) else {
                        throw WorkflowIssue("项目已切换；备份未创建。")
                    }
                },
                onOpenRestored: { url in
                    await model.openProject(at: url)
                    if model.projectSession.currentStore?.rootURL.standardizedFileURL == url.standardizedFileURL {
                        filesRoute = nil; useProjectQuick = true
                        navigate(to: model.projectSession.projectQuick == nil ? .workflow : .quick)
                        await refreshLibrary(checkModels: false)
                        return nil
                    }
                    return model.errorMessage ?? "无法打开已恢复项目；请使用项目入口重新选择。"
                }, onOpenGraph: { graphID, nodeID in
                    guard ((model.projectSession.currentStore === route.store &&
                            model.manifest?.effectiveInstanceID == route.instanceID) ||
                           (automaticQuickModel.projectSession.currentStore === route.store &&
                            automaticQuickModel.manifest?.effectiveInstanceID == route.instanceID)),
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
            ModelLibraryView(model: library, selectedModelID: selectionModel.projectSession.workflowInstallationID(for: quickModelIdentity), canSelect: true, onPrepare: { id, parent in
                // Preparing resources does not navigate or replace a newer draft.
                _ = try await quickModel.projectSession.prepareWorkflowVideo(id: id, in: parent)
                await refreshLibrary(checkModels: false)
            }) { id in
                let owner = selectionModel.projectSession
                let temporary = usesTemporaryChat
                let controller = quick
                let selectedDraftID = controller.draft?.id
                let selectedChatID = chat?.state.selectedSessionID
                do {
                    guard !quickOwnerIsChanging else { throw WorkflowIssue("项目正在切换；模型选择未应用。") }
                    let choice = try await owner.selectWorkflowInstallation(id: id)
                    guard !quickOwnerIsChanging, selectionModel.projectSession === owner, temporary == usesTemporaryChat,
                          quick === controller, controller.draft?.id == selectedDraftID,
                          chat?.state.selectedSessionID == selectedChatID else {
                        throw WorkflowIssue("快速草稿或所属项目已切换；模型选择未应用。")
                    }
                    guard let operation = WorkflowModelRoutes.operation(for: choice) else { throw WorkflowIssue("此模型没有可用的共享操作。") }
                    try selectModel(operation: operation, identity: choice.id)
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
            if quick.state.drafts.isEmpty && quick.state.navigation == nil { quick.select(operationID: "d.model.language", modelID: "") }
            await refreshLibrary(checkModels: false)
        }
        // Draft autosaves do not change installed models or assets. Refresh at
        // result/publication boundaries, not on every typing pause.
        .onChange(of: quick.isRunning) { _, running in if !running { Task { await refreshLibrary(checkModels: false) } } }
        .onChange(of: quick.pendingSaveRunID) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .onChange(of: library.isPresented) { _, presented in if !presented { Task { await refreshLibrary(checkModels: false) } } }
        .onChange(of: installationStates) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .onChange(of: model.manifest?.effectiveInstanceID) { _, _ in useProjectQuick = true }
        .onChange(of: model.manifest?.revision) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .onChange(of: quickModelIdentity) { _, _ in Task { await checkDemandReadiness() } }
        .onChange(of: graphModelIdentities) { _, _ in Task { await checkDemandReadiness() } }
        .sheet(item: $previewAsset, onDismiss: {
            if let pendingFilesRoute {
                returnToLibrary = false; filesRoute = pendingFilesRoute; self.pendingFilesRoute = nil
            }
            else { restoreLibraryIfNeeded() }
        }) { value in
            VStack {
                HStack { Button(baselineText(language, "label.572cf45ba436", fallback: "返回")) { previewAsset = nil }.keyboardShortcut(.cancelAction); Spacer() }
                QuickAssetPreview(store: value.store, reference: value.reference, compact: false)
                if let target = value.chatTarget, let sessionID = value.chatSessionID, let choice = value.chatChoice {
                    ChatLibraryAttachmentButton(chat: target, sessionID: sessionID, source: value.store, choice: choice,
                        isCurrent: { chat === target && target.state.selectedSessionID == sessionID && !quickOwnerIsChanging },
                        wording: { en, zh in language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en },
                        onAdopted: { returnToLibrary = false; previewAsset = nil; Task { await refreshLibrary(checkModels: false) } })
                }
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
        entry == .quick && (quick.category != .text || quick.textPresentation == .single) && !quickOwnerIsChanging && quick.canStart && !libraryVisible && !projectsVisible && !compatibilityVisible &&
        !languageVisible && !settingsVisible && !library.isPresented && previewAsset == nil && libraryInfo == nil &&
        filesRoute == nil && pendingFilesRoute == nil
    }
    @ViewBuilder private func libraryBrowser(compact: Bool, at point: CGPoint, onBack: (() -> Void)? = nil) -> some View {
        if let metadata {
            SharedLibraryBrowser(entries: entries.filter { value in
                guard !compact, let family = modelPickerCategory else { return true }
                guard case .operation(let operation, _) = value.selection else { return false }
                return QuickCategory.category(for: operation) == family
            }, store: metadata, compact: compact, state: compact ? compactLibraryState : fullLibraryState,
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
        else { await checkDemandReadiness() }
        let otherStore = model.projectSession.currentStore
        var snapshots = [await automaticQuick.store.snapshot()]
        if let otherStore, otherStore !== automaticQuick.store {
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
    private var quickSurface: some View {
        let owner = quick.store.rootURL.standardizedFileURL.path
        return QuickGenerationView(quick: quick, model: quickModel,
                    selectedResults: Binding(get: { quickPreviewSelections[owner] ?? [:] },
                        set: { quickPreviewSelections[owner] = $0 }), onChooseModel: { modelPickerCategory = quick.category; libraryVisible = true },
                    onSettingsToCanvas: { draft in let source = quick.store; Task { await settingsToCanvas(draft, from: source) } },
                    onResultToCanvas: { ref in let source = quick.store; Task { await resultToCanvas(ref, from: source) } },
                    onValueToCanvas: { value in let source = quick.store; Task { await valueToCanvas(value, from: source) } },
                    onOpenLibrary: { modelPickerCategory = nil; libraryVisible = true },
            onAssetsChanged: { Task { await refreshLibrary(checkModels: false) } },
                    onResolveSharedAsset: { projectID, instanceID, assetID in
                        let source = try await store(for: projectID, instanceID: instanceID)
                        let manifest = await source.snapshot()
                        guard let asset = manifest.assets.first(where: { $0.id == assetID }) else {
                            throw WorkflowIssue("源素材已不存在。")
                        }
                        return (source, try await source.pinWorkflowAsset(assetID), asset.name)
                    })
                    .id(quick.store.rootURL.standardizedFileURL.path)
                    .disabled(quickOwnerIsChanging)
    }

    private func checkDemandReadiness() async {
        let quickIDs = Set([quickModelIdentity].compactMap { $0 }.filter { !$0.isEmpty })
        let quickOwner = selectionModel.projectSession
        let canvasOwner = canvasModel.projectSession
        if quickOwner === canvasOwner {
            await quickOwner.checkExplicitModelReadiness(for: quickIDs.union(graphModelIdentities))
        } else {
            let canvasIDs = graphModelIdentities
            async let quickCheck: Void = quickOwner.checkExplicitModelReadiness(for: quickIDs)
            async let canvasCheck: Void = canvasOwner.checkExplicitModelReadiness(for: canvasIDs)
            _ = await (quickCheck, canvasCheck)
        }
    }
    /// Only an explicit model/settings selection changes the future chat configuration.
    private func applySelectedModelToChat() {
        guard quick.category == .text, let node = quick.draft?.node else { return }
        guard [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38].contains(node.operationID) else {
            // The selected legacy model has single-turn semantics. Show its real
            // surface rather than silently retaining a different chat model.
            quick.selectTextPresentation(.single)
            return
        }
        guard quick.textPresentation == .chat, let chat else { return }
        do {
            let sessionID = try chat.state.selectedSessionID ?? chat.newSession()
            try chat.selectModelConfiguration(node, sessionID: sessionID)
        } catch { issue = error.localizedDescription }
    }

    /// Temporary selection never writes the ordinary Quick draft or its navigation.
    private func selectModel(operation: String, identity: String) throws {
        if usesTemporaryChat, let chat {
            guard [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38].contains(operation),
                  var node = WorkflowRegistry.standard.operation(operation)?.definition.makeNode() else {
                throw WorkflowIssue("临时聊天需要支持有序消息的文字模型；其他能力请返回普通快速生成。")
            }
            node.parameters["modelID"] = .text(identity); node.parameters["outputMode"] = .text("text")
            try chat.selectModelConfiguration(node, sessionID: try chat.state.selectedSessionID ?? chat.newSession())
            return
        }
        quick.select(operationID: operation, modelID: identity); applySelectedModelToChat()
    }
    private func useLibraryEntry(_ value: SharedLibraryBrowserEntry) {
        guard !quickOwnerIsChanging else { issue = "项目正在切换，当前快速草稿未改变。"; return }
        guard case .operation(let operation, let id) = value.selection,
              let id, WorkflowRegistry.standard.operation(operation)?.definition.modelKind != nil else { presentLibraryDestination(.info(value)); return }
        do { try selectModel(operation: operation, identity: id) }
        catch { issue = error.localizedDescription; return }
        libraryVisible = false; navigate(to: .quick)
    }
    private func useNode(_ node: WorkflowNode) {
        guard !quickOwnerIsChanging else { issue = "项目正在切换，当前快速草稿未改变。"; return }
        guard let controller = canvasModel.projectSession.workflow else { return }
        // Connected values are not silently guessed from stale history; the graph is untouched.
        guard controller.graph?.connections.contains(where: { $0.targetNode == node.id }) != true else {
            issue = "此节点包含连线输入。请先把所需结果存为素材，再在快速界面显式选择；未忽略连线或修改原节点。"; return
        }
        quick.useSettings(node); applySelectedModelToChat(); navigate(to: .quick)
    }
    private func store(for projectID: UUID, instanceID: UUID? = nil) async throws -> ProjectStore {
        var candidates: [(ProjectStore, ProjectManifest)] = [(automaticQuick.store, await automaticQuick.store.snapshot())]
        if let current = model.projectSession.currentStore, current !== automaticQuick.store {
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
        let target = entry == .quick && quick.category == .text && quick.textPresentation == .chat ? chat : nil
        let targetSession = target?.state.selectedSessionID
        do { let source = try await store(for: identity.0, instanceID: identity.1)
            let ref = try await source.pinWorkflowAsset(identity.2)
            let manifest = await source.snapshot()
            let choice = [.text, .image, .video, .document].contains(ref.kind)
                ? ChatProjectAttachmentChoice(name: value.item.title, reference: ref, instanceID: manifest.effectiveInstanceID) : nil
            presentLibraryDestination(.asset(.init(store: source, reference: ref,
                chatTarget: target, chatSessionID: targetSession, chatChoice: choice)))
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
            if let current = automaticQuickModel.projectSession.currentStore {
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
                  (automaticQuickModel.projectSession.currentStore === source &&
                   automaticQuickModel.manifest?.effectiveInstanceID == snapshot.effectiveInstanceID) ||
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
        guard !usesTemporaryChat else {
            issue = language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? "此模型不能用于临时聊天；请在模型库选择已支持的聊天模型。" : "This model is not available for temporary chat. Choose a supported chat model in the model library."
            return
        }
        let owner = quickModel.projectSession, controller = quick
        let draftID = controller.draft?.id
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "登记已有模型的原位置；不会复制、移动或删除权重。"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            guard !quickOwnerIsChanging, quickModel.projectSession === owner,
                  quick === controller, controller.draft?.id == draftID else { throw WorkflowIssue("快速草稿已切换，未登记模型。") }
            let choice = try await owner.registerExplicitModel(at: url, kind: kind)
            guard !quickOwnerIsChanging, quickModel.projectSession === owner,
                  quick === controller, controller.draft?.id == draftID else { throw WorkflowIssue("快速草稿已切换，已登记的模型未替换当前草稿。") }
            controller.select(operationID: id, modelID: choice.id)
            applySelectedModelToChat()
            await refreshLibrary(checkModels: true)
        } catch { issue = error.localizedDescription }
    }
    private func importLibraryAsset() async {
        let destination = quick.store
        guard let (url, mode) = await NativeAssetImportPanel.choose(language: language) else { return }
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do { _ = try await destination.importWorkflowMediaFile(at: url, mode: mode); await refreshLibrary(checkModels: false) }
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
    private func copiedReference(_ reference: WorkflowAssetReference, from source: ProjectStore, to destination: ProjectStore) async throws -> WorkflowAssetReference {
        if destination === source { return reference }
        return try await destination.copyWorkflowAsset(reference, from: source)
    }
    private func copiedDatum(_ value: WorkflowDatum, from source: ProjectStore, to destination: ProjectStore) async throws -> WorkflowDatum {
        try value.validate()
        var copies: [WorkflowAssetReference: WorkflowAssetReference] = [:]
        for ref in value.assetReferences where copies[ref] == nil {
            copies[ref] = try await copiedReference(ref, from: source, to: destination)
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
    private func settingsToCanvas(_ draft: QuickDraft, from source: ProjectStore) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { issue = "流程当前不可编辑"; return }
        do {
            var copy = draft
            for (port, value) in copy.inputs {
                guard let datum = value.datum else { throw WorkflowIssue("请先选择单项输入，不能隐式复制候选集合。") }
                copy.inputs[port] = .data(try await copiedDatum(datum, from: source, to: controller.services.store))
            }
            guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变，未放入其他流程。") }
            try await controller.insertQuickSettings(copy, target: scope)
            navigate(to: .workflow)
        } catch { issue = error.localizedDescription }
    }
    private func resultToCanvas(_ ref: WorkflowAssetReference, from source: ProjectStore) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard !Task.isCancelled else { return }
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { issue = "流程当前不可编辑"; return }
        do {
            try Task.checkCancellation()
            let copy = try await copiedReference(ref, from: source, to: controller.services.store)
            try Task.checkCancellation()
            guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变。") }
            try await controller.insertQuickResult(copy, target: scope)
            try Task.checkCancellation()
            navigate(to: .workflow)
        } catch { issue = error.localizedDescription }
    }
    private func valueToCanvas(_ value: WorkflowDatum, from source: ProjectStore) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard !Task.isCancelled else { return }
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { issue = "流程当前不可编辑"; return }
        do {
            try Task.checkCancellation()
            let copy = try await copiedDatum(value, from: source, to: controller.services.store)
            try Task.checkCancellation()
            guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变。") }
            try await controller.insertQuickValue(copy, target: scope)
            try Task.checkCancellation()
            navigate(to: .workflow)
        } catch { issue = error.localizedDescription }
    }
}
