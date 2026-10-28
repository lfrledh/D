import AppKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

/// Two peers share real services and assets; navigation does not own inference.
public struct DualWorkbenchView: View {
    public enum Entry: String, CaseIterable { case quick, workflow }
    let model: WorkbenchModel
    let automaticQuickModel: WorkbenchModel
    let automaticQuick: QuickGenerationController
    @State private var quickPreviewSelections: [String: [QuickCategory: WorkflowAssetReference]] = [:]
    @State private var useProjectQuick = true
    @State private var modelPickerCategory: QuickCategory?
    private var quickUsesTemporaryChat: Bool { quick.category == .text && quick.textPresentation == .chat && automaticQuickModel.temporaryChatModel != nil }
    private var usesTemporaryChat: Bool { entry == .quick && quickUsesTemporaryChat }
    private var chatModel: WorkbenchModel { quickUsesTemporaryChat ? (automaticQuickModel.temporaryChatModel ?? quickModel) : quickModel }
    private var selectionModel: WorkbenchModel { usesTemporaryChat ? chatModel : quickModel }
    private var chat: ChatController? { chatModel.projectSession.chat }
    @State private var temporaryChatChanging = false
    private func captureChatReading() {
        guard entry == .quick, quick.category == .text, quick.textPresentation == .chat,
              let chat else { return }
        chatModel.readingState(for: chat).capture(chat)
    }
    private func changeTemporaryChat() {
        guard !temporaryChatChanging else { return }
        captureChatReading()
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
    @State private var libraryMetadata: [String: ProjectAssetMetadataSnapshot] = [:]
    @State private var libraryRefreshGeneration = UUID()
    @State private var fullLibraryState = SharedLibraryBrowserState()
    @State private var canvasLibraryStates: [WorkflowCanvasLibraryMode:SharedLibraryBrowserState] =
        Dictionary(uniqueKeysWithValues: [WorkflowCanvasLibraryMode.nodes,.programs,.assets,.text,.image,.video,.audio,.data].map { ($0,SharedLibraryBrowserState()) })
    private struct LibraryNavigationState {
        let modes: [WorkflowCanvasLibraryMode: SharedLibraryBrowserState]
        let full: SharedLibraryBrowserState
    }
    @State private var libraryNavigationOwner: UUID?
    @State private var libraryNavigationHistory: [UUID: LibraryNavigationState] = [:]
    @State private var libraryNavigationOrder: [UUID] = []
    private func changeLibraryNavigationOwner(_ next: UUID?) {
        guard next != libraryNavigationOwner else { return }
        if let old = libraryNavigationOwner {
            libraryNavigationHistory[old] = .init(modes: canvasLibraryStates, full: fullLibraryState)
            libraryNavigationOrder.removeAll { $0 == old }; libraryNavigationOrder.append(old)
        }
        if let next, let saved = libraryNavigationHistory[next] {
            canvasLibraryStates = saved.modes; fullLibraryState = saved.full
        } else {
            canvasLibraryStates = Dictionary(uniqueKeysWithValues: [WorkflowCanvasLibraryMode.nodes,.programs,.assets,.text,.image,.video,.audio,.data].map { ($0,SharedLibraryBrowserState()) })
            fullLibraryState = SharedLibraryBrowserState()
        }
        libraryNavigationOwner = next
        while libraryNavigationOrder.count > 4 { libraryNavigationHistory.removeValue(forKey: libraryNavigationOrder.removeFirst()) }
    }
    @State private var pendingLegacyPreview:SharedLibraryBrowserEntry?
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
    private enum LibraryDestination { case asset(LibraryAssetPreview), info(SharedLibraryBrowserEntry), models, modelSelection(@MainActor () -> Void) }
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
    @State private var libraryProjection = SharedLibraryProjectionCache()
    private var entries: [SharedLibraryBrowserEntry] {
        libraryProjection.entries(models: quickModel.projectSession.explicitModelChoices,
            readiness: quickModel.projectSession.explicitModelReadiness,
            tools: canvasModel.projectSession.workflow?.tools ?? [], projects: projects, language: language, metadata: libraryMetadata, tags: nodeTags)
    }

    @State private var commandScope = WorkbenchCommandScope()
    @State private var windowFullScreen = false
    @State private var sidebarState = WorkbenchSidebarState()
    @Environment(\.isEnabled) private var controlsEnabled
    private func selectCategory(_ category: QuickCategory) {
        guard controlsEnabled, !quickOwnerIsChanging, quick.category != category else { return }
        captureChatReading(); quick.selectCategory(category)
        #if DEBUG
        WorkbenchCategoryUpdateProbe.phase("category-changed")
        #endif
    }
    @State private var entry: Entry = .quick
    @State private var navigationIntent = UUID()
    @State private var previewNavigationRequest = UUID()
    @State private var libraryVisible = false
    @State private var expandedLibraryMode: WorkflowCanvasLibraryMode = .nodes
    @State private var expandedLibraryForCanvas = false
    @State private var legacyInstance: UUID?
    @State private var legacyName = ""
    @State private var expandedContainerNavigation: WorkflowContainerNavigation?
    @State private var expandedLibraryContext: WorkflowLibraryContext?
    @State private var clearExpandedContext: () -> Void = {}
    private var quickImportTitle: String { quickModel === automaticQuickModel ? layoutText(language, "independent") : (quickModel.manifest?.name ?? "—") }
    private var displayedOwner: WorkbenchModel { entry == .workflow ? canvasModel : chatModel }
    private var displayedTitle: String {
        if usesTemporaryChat { return layoutText(language, "temporary") }
        if displayedOwner === automaticQuickModel { return layoutText(language, "independent") }
        return displayedOwner.manifest?.name ?? layoutText(language, "independent")
    }
    private var expandedLibraryNavigation: WorkflowContainerNavigation? {
        guard expandedLibraryForCanvas, let navigation = expandedContainerNavigation else { return nil }
        return .init(reveal: { context in expandedLibraryContext = context }, source: { call in
            libraryVisible = false; navigation.source(call)
        })
    }
    private func openLibrary(_ mode: WorkflowCanvasLibraryMode, forCanvas: Bool, context: WorkflowLibraryContext? = nil, clearContext: @escaping () -> Void = {}) {
        expandedLibraryContext = context; clearExpandedContext = clearContext
        expandedLibraryMode = mode; expandedLibraryForCanvas = forCanvas
        modelPickerCategory = nil; libraryVisible = true
    }
    private func openModelChoices(_ category: QuickCategory) {
        expandedLibraryMode = .nodes; expandedLibraryForCanvas = false; expandedLibraryContext = nil; clearExpandedContext = {}
        canvasLibraryStates[.nodes]?.modelPathMigrated = true
        canvasLibraryStates[.nodes]?.modelModality = CreatorMode(rawValue: category.rawValue)
        modelPickerCategory = category; libraryVisible = true
    }
    private func openLegacy() {
        guard let manifest = model.manifest, !model.isChangingProject else { return }
        legacyInstance = manifest.effectiveInstanceID; legacyName = manifest.name; compatibilityVisible = true
    }
    @State private var projectsVisible = false
    @State private var compatibilityVisible = false
    @State private var languageVisible = false
    @State private var settingsVisible = false
    @State private var settingsSection = "appearance"
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
    @State private var issueValue: WorkflowIssue?
    private var issue: String? {
        get { issueValue?.reason }
        nonmutating set { issueValue = newValue.map { WorkflowIssue($0) } }
    }
    @State private var failedAssetRoute: FilesRoute?
    @Environment(\.dLanguageStore) private var language
    private var canvasModel: WorkbenchModel { model.manifest == nil ? automaticQuickModel : model }
    private var installationStates: [String] {
        library.installationStates
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
    @State private var featureHelp = WorkbenchHelpStore()
    @State private var noticesVisible = false
    public init(model: WorkbenchModel, quickModel: WorkbenchModel, quick: QuickGenerationController,
                library: ModelLibraryModel, nodeTags: ModelNodeTagStore, metadata: SharedLibraryStore?, metadataIssue: String? = nil, settingsRequest: Binding<UUID?> = .constant(nil), windowHasSheet: Bool = false) {
        self._settingsRequest = settingsRequest
        self.windowHasSheet = windowHasSheet
        self.model = model; self.automaticQuickModel = quickModel; self.automaticQuick = quick; self.library = library; self.nodeTags = nodeTags; self.metadata = metadata; self.metadataIssue = metadataIssue
    }
    private func t(_ key: String) -> String { workflowText(language, "refinement.shell." + key) }
    private var canPresentSettings: Bool {
        !noticesVisible && featureHelp.presentation == nil && !windowHasSheet && !settingsVisible && !libraryVisible && !projectsVisible && !compatibilityVisible && !languageVisible
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
    private func presentSettings(section: String = "appearance") {
        guard canPresentSettings else { return }
        let owner = entry == .quick ? quickModel : canvasModel
        let files = owner.manifest.flatMap { manifest in owner.projectSession.currentStore.map {
            FilesRoute(store: $0, instanceID: manifest.effectiveInstanceID, assetID: nil)
        } }
        // Match the owner Quick/Text will actually display, including temporary chat.
        let searchOwner = chatModel
        let target = searchOwner.projectSession.chat
        settingsContext = .init(owner: owner, files: files, searchOwner: searchOwner, search: target,
            searchSessionID: target?.state.selectedSessionID,
            searchTitle: target.map { (searchOwner.manifest?.name ?? t("workspace")) + " · " + ($0.selectedSession?.title ?? t("newConversation")) })
        settingsSection = section
        settingsVisible = true
    }
    private func finishSettingsDismissal() { settingsContext = nil }
    private func requestSettingsFiles(_ context: SettingsContext) {
        guard let window = commandScope.window else { return }
        WorkbenchChildPanels.navigate(on: window) {
            guard commandScope.window === window else { return }
            if let route = context.files {
                guard context.owner.projectSession.currentStore === route.store,
                      context.owner.manifest?.effectiveInstanceID == route.instanceID else {
                    issue = t("targetChanged"); return
                }
                filesRoute = route
            } else {
                guard context.owner.projectSession.currentStore == nil else { issue = t("targetChanged"); return }
                projectsVisible = true
            }
        }
    }

    private func navigate(to destination: Entry) {
        guard destination != entry else { return }
        captureChatReading(); navigationIntent = UUID()
        entry = destination
    }
    private func presentQuickModelSelection(expectedIdentity: String? = nil) {
        let owner = selectionModel.projectSession, temporary = usesTemporaryChat, controller = quick
        let store = owner.currentStore
        let selectedDraftID = controller.draft?.id, selectedChatID = chat?.state.selectedSessionID
        let selectedIdentity = quickModelIdentity, selectedConfiguration = chat?.selectedSession?.configuration
        let intent = navigationIntent, sourceEntry = entry
        library.presentSelection(selected: owner.workflowInstallationID(for: quickModelIdentity), identity: expectedIdentity) { id in
            do {
                guard !quickOwnerIsChanging, selectionModel.projectSession === owner, owner.currentStore === store,
                      temporary == usesTemporaryChat, quick === controller,
                      controller.draft?.id == selectedDraftID, chat?.state.selectedSessionID == selectedChatID,
                      quickModelIdentity == selectedIdentity, chat?.selectedSession?.configuration == selectedConfiguration,
                      navigationIntent == intent, entry == sourceEntry else {
                    throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。"))
                }
                let choice = try await owner.selectWorkflowInstallation(id: id) { choice in
                    guard expectedIdentity == nil || choice.id == expectedIdentity,
                          !quickOwnerIsChanging, selectionModel.projectSession === owner, owner.currentStore === store,
                          temporary == usesTemporaryChat, quick === controller,
                          controller.draft?.id == selectedDraftID, chat?.state.selectedSessionID == selectedChatID,
                          quickModelIdentity == selectedIdentity, chat?.selectedSession?.configuration == selectedConfiguration,
                          navigationIntent == intent, entry == sourceEntry else {
                        throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。"))
                    }
                    guard let operation = WorkflowModelRoutes.operation(for: choice),
                          !temporary || [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38].contains(operation) else { throw WorkflowIssue(library.managementText("noRoute", "此配置没有可用的共享操作。")) }
                }
                guard !quickOwnerIsChanging, selectionModel.projectSession === owner, owner.currentStore === store,
                      temporary == usesTemporaryChat, quick === controller,
                      controller.draft?.id == selectedDraftID, chat?.state.selectedSessionID == selectedChatID,
                      quickModelIdentity == selectedIdentity, chat?.selectedSession?.configuration == selectedConfiguration,
                      navigationIntent == intent, entry == sourceEntry else {
                    throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。"))
                }
                guard let operation = WorkflowModelRoutes.operation(for: choice) else { throw WorkflowIssue(library.managementText("noRoute", "此配置没有可用的共享操作。")) }
                try selectModel(operation: operation, identity: choice.id)
                returnToLibrary = false; library.isPresented = false
                await refreshLibrary(checkModels: false)
            } catch is CancellationError { } catch { library.errorMessage = error.localizedDescription }
        }
        let targetTitle = (selectionModel.manifest?.name ?? "D") + " · " + t("quickMode") + " · " + (controller.draft?.node.title ?? t("chat"))
        library.captureSelectionPresentation(targetTitle) {
            !quickOwnerIsChanging && selectionModel.projectSession === owner && owner.currentStore === store
                && temporary == usesTemporaryChat && quick === controller
                && controller.draft?.id == selectedDraftID && chat?.state.selectedSessionID == selectedChatID
                && quickModelIdentity == selectedIdentity && chat?.selectedSession?.configuration == selectedConfiguration
                && navigationIntent == intent && entry == sourceEntry
        }
        library.configurationSelectionAction = { item in
            do {
                guard expectedIdentity == nil || item.identity == expectedIdentity,
                      !quickOwnerIsChanging, selectionModel.projectSession === owner, owner.currentStore === store,
                      temporary == usesTemporaryChat, quick === controller,
                      controller.draft?.id == selectedDraftID, chat?.state.selectedSessionID == selectedChatID,
                      quickModelIdentity == selectedIdentity, chat?.selectedSession?.configuration == selectedConfiguration,
                      navigationIntent == intent, entry == sourceEntry,
                      item.selectable, try owner.modelInventoryConfigurations().contains(item),
                      let prefix = item.identity.split(separator: ":").first,
                      let kind = WorkflowModelKind(rawValue: String(prefix)) else { throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。")) }
                let choice = WorkflowModelChoice(id: item.identity, kind: kind, displayName: item.title)
                guard let operation = WorkflowModelRoutes.operation(for: choice) else { throw WorkflowIssue(library.managementText("noRoute", "此配置没有可用的共享操作。")) }
                try selectModel(operation: operation, identity: choice.id)
                returnToLibrary = false; library.isPresented = false
                await refreshLibrary(checkModels: false)
            } catch { library.errorMessage = error.localizedDescription }
        }
    }

    private var textWorkspaceMenu: some View {
        let owner = quick
        let destination = automaticQuickModel.temporaryChatModel ?? quickModel
        let target = destination.projectSession.chat
        let presentation = owner.textPresentation
        let temporary = automaticQuickModel.temporaryChatModel
        let sessionID = target?.state.selectedSessionID
        let current = {
            entry == .quick && quick === owner && owner.category == .text && owner.textPresentation == presentation
                && (automaticQuickModel.temporaryChatModel ?? quickModel) === destination
                && destination.projectSession.chat === target && target?.state.selectedSessionID == sessionID
                && !quickOwnerIsChanging && !temporaryChatChanging && !destination.projectSession.isChangingProject
                && target?.isDiscarding != true
        }
        let unavailable = temporaryChatChanging || quickOwnerIsChanging || destination.projectSession.isChangingProject || target?.isDiscarding == true
        return WorkbenchMenu {
            quickTextWorkspaceRows(presentation: presentation, temporary: temporary != nil,
                language: language, enabled: !unavailable, current: current,
                temporaryAction: changeTemporaryChat, switchAction: {
                    captureChatReading(); owner.selectTextPresentation(presentation == .chat ? .single : .chat)
                })
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Circle())
        }.buttonStyle(WorkbenchIconButtonStyle())
            .accessibilityLabel(workflowText(language, "quick.textWorkspace.more"))
            .accessibilityIdentifier("quick-text-internal-menu")
            .help(unavailable ? workflowText(language, "quick.textWorkspace.unavailable") : workflowText(language, "quick.textWorkspace.more"))
            .environment(\.workbenchMenuContext, "text:\(ObjectIdentifier(owner)):\(ObjectIdentifier(destination)):\(presentation):\(sessionID)")
    }
    private var singleTextActions: some View {
        let owner = quick
        // A temporary owner survives a visit to single generation. New conversation
        // must be created in the owner that will actually be visible on return.
        let destination = automaticQuickModel.temporaryChatModel ?? quickModel
        let target = destination.projectSession.chat
        return HStack(spacing: 8) {
            Button(workflowText(language, "quick.textWorkspace.newConversation"), systemImage: "plus") {
                guard entry == .quick, quick === owner, owner.category == .text, owner.textPresentation == .single,
                      (automaticQuickModel.temporaryChatModel ?? quickModel) === destination,
                      destination.projectSession.chat === target, let target,
                      !quickOwnerIsChanging, !temporaryChatChanging, !destination.projectSession.isChangingProject,
                      target.isLoaded, !target.isDiscarding, target.saveIssue == nil else { return }
                do {
                    try target.newSession()
                    owner.selectTextPresentation(.chat)
                } catch { issue = error.localizedDescription }
            }.disabled(target == nil || target?.saveIssue != nil || target?.isLoaded != true || target?.isDiscarding == true || destination.projectSession.isChangingProject || temporaryChatChanging || quickOwnerIsChanging)
                .help(target?.saveIssue ?? (target?.isLoaded != true ? (target?.error.map { ChatErrorText.display($0, language: language) } ?? workflowText(language, "chat.loading")) : (quickOwnerIsChanging || temporaryChatChanging || destination.projectSession.isChangingProject || target?.isDiscarding == true) ? workflowText(language, "quick.textWorkspace.unavailable") : workflowText(language, "quick.textWorkspace.newConversation")))
                .accessibilityIdentifier("single-text-new-conversation")
            textWorkspaceMenu
        }
    }

    private var saveCommand: WorkbenchGenerationCommand {
        if entry == .workflow, let controller = canvasModel.projectSession.workflow {
            return .init(title: consistencyText(language, "FLOW-SAVE"), isEnabled: canPresentSettings && controller.readOnlyReason == nil && !controller.isSaving && !canvasModel.isChangingProject) {
                guard commandScope.permitsCommands, canPresentSettings, entry == .workflow, canvasModel.projectSession.workflow === controller, controller.readOnlyReason == nil, !controller.isSaving, !canvasModel.isChangingProject else { return }
                Task { await controller.save() }
            }
        }
        let owner = quick
        let activeChat = quick.category == .text && quick.textPresentation == .chat ? chat : nil
        return .init(title: t("saveDraft"), isEnabled: canPresentSettings && !quickOwnerIsChanging) {
            guard commandScope.permitsCommands, canPresentSettings, entry == .quick, quick === owner, !quickOwnerIsChanging else { return }
            Task {
                do {
                    if let activeChat { guard chat === activeChat else { return }; try await activeChat.flush() }
                    else { try await owner.flush() }
                } catch { issue = error.localizedDescription }
            }
        }
    }
    private var workspaceCommands: WorkbenchWorkspaceCommands {
        let owner = displayedOwner, instance = displayedOwner.manifest?.effectiveInstanceID
        let store = owner.projectSession.currentStore, epoch = owner.projectSession.navigationEpoch
        let capturedEntry = entry, intent = navigationIntent, originalQuick = quick
        let projectQuick = model.projectSession.projectQuick, targetInstance = model.manifest?.effectiveInstanceID
        let targetName = model.manifest?.name
        func action(_ title: String, enabled: Bool = true, _ perform: @escaping () -> Void) -> WorkbenchGenerationCommand {
            let admitted = enabled && controlsEnabled && !owner.isChangingProject
            return .init(title: title, isEnabled: admitted) {
                guard admitted, commandScope.permitsNavigation else { return }
                WorkbenchChildPanels.navigate(on: commandScope.window) {
                guard canPresentSettings, controlsEnabled,
                      entry == capturedEntry, navigationIntent == intent, displayedOwner === owner,
                      owner.manifest?.effectiveInstanceID == instance, owner.projectSession.currentStore === store,
                      owner.projectSession.navigationEpoch == epoch, !owner.isChangingProject else {
                    issue = systemMenuText(language, "stale"); return
                }
                perform()
                }
            }
        }
        var destinations: [WorkbenchChoiceCommand] = []
        if entry == .quick {
            if let targetName, let projectQuick {
                destinations.append(.init(action(layoutText(language, "currentProject", arguments: ["name": targetName]), enabled: !usesTemporaryChat) {
                    guard model.manifest?.effectiveInstanceID == targetInstance, model.projectSession.projectQuick === projectQuick, quick === originalQuick else { return }
                    captureChatReading(); useProjectQuick = true
                }, selected: quick === projectQuick))
            }
            destinations.append(.init(action(layoutText(language, "independent"), enabled: !usesTemporaryChat) {
                guard quick === originalQuick else { return }; captureChatReading(); useProjectQuick = false
            }, selected: quick === automaticQuick))
            if projectQuick == nil, targetName != nil {
                destinations.append(.init(action(layoutText(language, "enableQuick"), enabled: !usesTemporaryChat) {
                    guard model.manifest?.effectiveInstanceID == targetInstance else { return }
                    captureChatReading()
                    Task { await model.projectSession.enableProjectQuick()
                        if model.manifest?.effectiveInstanceID == targetInstance { useProjectQuick = true; navigate(to: .quick) }
                    }
                }, selected: false))
            }
        }
        return .init(workflow: entry == .workflow, chat: entry == .quick && quick.category == .text && quick.textPresentation == .chat, scope: commandScope,
            save: saveCommand,
            newProject: action(consistencyText(language, "menu.file.new")) { Task { if await model.newProject() { navigate(to: .workflow) } } },
            openProject: action(consistencyText(language, "menu.file.open")) { Task { if await model.openProject() { navigate(to: .workflow) } } },
            recent: model.recentProjects.map { project in action(project.name) { Task { if await model.openRecentProject(id: project.id) { navigate(to: .workflow) } } } },
            files: action(layoutText(language, owner === automaticQuickModel ? "workspaceFiles" : "projectFiles"), enabled: !usesTemporaryChat && store != nil && instance != nil) {
                if let store, let instance { filesRoute = .init(store: store, instanceID: instance, assetID: nil) }
            }, quickDestination: destinations,
            importAsset: action(systemMenuText(language, "import"), enabled: quickModel.projectSession.currentStore != nil && (entry != .workflow || canvasModel.projectSession.workflow?.canEditCanvas == true)) { beginLibraryImport(forCanvas: capturedEntry == .workflow) },
            legacy: action(layoutText(language, "legacy"), enabled: targetName != nil) { guard model.manifest?.effectiveInstanceID == targetInstance else { return }; openLegacy() },
            modes: Entry.allCases.map { mode in .init(action(layoutText(language, mode == .quick ? "quick" : "workflow")) { navigate(to: mode) }, selected: entry == mode) },
            sidebars: [action(systemMenuText(language, sidebarState.leading ? "hideLeft" : "showLeft")) { sidebarState.leading.toggle() },
                       action(systemMenuText(language, sidebarState.trailing ? "hideRight" : "showRight")) { sidebarState.trailing.toggle() }],
            help: action(systemMenuText(language, "guide")) { featureHelp.presentation = .init(featureID: nil, token: nil, context: nil) },
            thirdPartyNotices: action(workflowText(language, "notices.title")) { noticesVisible = true },
            stop: entry == .quick && (quick.category != .text || quick.textPresentation == .single) ? action(systemMenuText(language, "stop"), enabled: originalQuick.isRunning) { Task { await originalQuick.cancel() } } : nil,
            retrySave: entry == .quick && (originalQuick.pendingSaveRunID != nil || originalQuick.saveIssue != nil) ? action(systemMenuText(language, "retrySave"), enabled: !originalQuick.isRunning) { Task { await originalQuick.retrySave() } } : nil)
    }
    @State private var modeSize = CGSize(width: 232, height: 52)
    @State private var navigationTop: CGFloat = 48
    @State private var windowControlSize = CGSize(width: 80, height: 32)
    private var modeSwitcher: some View {
        WorkbenchGlassSegments(title: t("workspaceMode"), selection: Binding(get: { entry }, set: { navigate(to: $0) }),
            choices: [(Entry.quick, layoutText(language, "quick")), (.workflow, layoutText(language, "workflow"))],
            owner: AnyHashable("\(displayedOwner.manifest?.effectiveInstanceID.uuidString ?? "none"):\(displayedOwner.projectSession.navigationEpoch)"),
            standard: true, minimumItemLength: 108)
            .fixedSize(horizontal: true, vertical: false).frame(height: 52)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { modeSize = $0 }
            .accessibilityIdentifier("workbench-entry").workbenchHelp("APP-MODE")
    }

    @ViewBuilder private var workspaceContent: some View {
        #if DEBUG
        let _ = WorkbenchCategoryUpdateProbe.workbenchBody?()
        #endif
        VStack(spacing: 0) {
            if entry == .quick {
                Color.clear.frame(height: 52).allowsHitTesting(false)
            }
            if entry == .quick, let identity = quickModelIdentity,
               quickModel.projectSession.explicitModelChecking.contains(identity) {
                Text(t("checkingModel"))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 4)
            } else if entry == .workflow,
                      !canvasModel.projectSession.explicitModelChecking.isDisjoint(with: graphModelIdentities) {
                Text(t("checkingWorkflow"))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 4)
            }
            ZStack {
                RetainedContentHost(content: Group {
                        if quick.category == .text, let chat {
                            VStack(spacing: 0) {
                                if quick.textPresentation == .chat {
                                    ChatWorkbenchView(chat: chat, model: chatModel,
                                        onChooseModel: { openModelChoices(.text) },
                                        onOpenLibrary: { openLibrary(.assets, forCanvas: false) },
                                        onImportAsset: { beginLibraryImport(forCanvas: false) },
                    importTargetTitle: quickImportTitle,
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
                                        }, textWorkspaceActions: AnyView(textWorkspaceMenu))
                                        .id(chat.store.rootURL.standardizedFileURL.path)
                                        .disabled(quickOwnerIsChanging || chat.isDiscarding || chatModel.projectSession.isChangingProject)
                                } else { quickSurface }
                            }
                        } else { quickSurface }
                }.workbenchTheme(paintsCanvas: false).environment(\.dLanguageStore, language)
                    .preferredColorScheme(automaticQuickModel.chatDisplaySettings.preferences.preferredColorScheme)
                    .environment(\.chatDisplayPreferences, automaticQuickModel.chatDisplaySettings.preferences),
                    visible: entry == .quick, identifier: "quick-retained-surface",
                    fallbackSize: CGSize(width: 760, height: 500))
                    .transaction { $0.animation = nil }
                    .accessibilityHidden(entry != .quick)
                RetainedContentHost(content: WorkflowHostView(model: canvasModel, nodeTags: nodeTags, metadata: metadata, library: library, onQuickUse: useNode,
                    libraryContent: canvasLibraryContent,
                    libraryHeaderContent: { mode in AnyView(libraryBrowser(compact: true, at: { nil }, canvasMode: mode, forCanvas: true, headerOnly: true)) },
                    onExpandLibrary: { mode, context, clear, navigation in
                        expandedContainerNavigation = navigation
                        openLibrary(mode, forCanvas: true, context: context, clearContext: clear)
                    },
                    onImportLibraryAsset: { beginLibraryImport(forCanvas: true) },
                    onSharedAssetDrop: acceptSharedAssetDrop,
                    acceptsLegacyAsset: { projectID, assetID in
                        guard let instance = SharedLibraryProjection.resolvedInstanceID(projectID: projectID,
                            instanceID: nil, projects: projects) else { return false }
                        return canvasModel.projectSession.workflow?.projectInstanceID == instance &&
                            projects.contains(where: { $0.effectiveInstanceID == instance && $0.assets.contains(where: { $0.id == assetID }) })
                    }).workbenchTheme(paintsCanvas: false).environment(\.dLanguageStore, language)
                    .preferredColorScheme(automaticQuickModel.chatDisplaySettings.preferences.preferredColorScheme)
                    .environment(\.chatDisplayPreferences, automaticQuickModel.chatDisplaySettings.preferences),
                    visible: entry == .workflow, identifier: "workflow-retained-surface",
                    fallbackSize: CGSize(width: 760, height: 500))
                    .transaction { $0.animation = nil }
                    .accessibilityHidden(entry != .workflow)
            }

        }
        .frame(minWidth: WorkbenchSidebarLayout.minimumWindowWidth, minHeight: 580)
        .background(WorkbenchTopNavigationMeasure { navigationTop = $0 })
        .environment(\.workbenchQuickContentTop, max(0, navigationTop + 40 + 8 - 52))
        .overlay(alignment: .top) {
            if entry == .quick {
                let dragOwner = quick
                let dragStore = quickModel.projectSession.currentStore
                WorkbenchCategoryPicker(selection: quick.category, owner: ObjectIdentifier(quick), enabled: !quickOwnerIsChanging) { category in
                    guard entry == .quick, quick === dragOwner, quickModel.projectSession.currentStore === dragStore else { return }
                    selectCategory(category)
                }.workbenchHelp("QUICK-MODALITY")
                    .frame(width: 264, height: 40).padding(.top, navigationTop)
            }
        }
        .environment(\.workbenchModeSize, modeSize)
        .environment(\.workbenchWindowControlSize, windowFullScreen ? CGSize(width: 80, height: 32) : windowControlSize)
        .overlay(alignment: .topLeading) {
            WorkbenchNativeWindowControls(fullScreen: $windowFullScreen, size: $windowControlSize).padding(.leading, 16).padding(.top, 8)
        }
        .overlay(alignment: .topTrailing) {
            WorkbenchWindowDragRegion().frame(width: 120, height: 28).padding(.trailing, 16).padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) { modeSwitcher.padding(.trailing, 16).padding(.bottom, 16) }
    }
    private var menuContext: String {
        let instance = canvasModel.manifest?.effectiveInstanceID.uuidString ?? "none"
        return "workbench:\(entry.rawValue):\(ObjectIdentifier(quick)):\(instance)"
    }
    private var workspacePanels: some View {
        workspaceContent
        .background(WorkbenchCommandWindow(scope: commandScope))
        .focusedSceneValue(\.workbenchWorkspace, workspaceCommands)
        .focusedSceneValue(\.workbenchSave, canPresentSettings ? saveCommand : nil)
        .environment(\.workbenchSaveAction, canPresentSettings ? saveCommand : nil)
        .environment(\.workbenchHelpStore, featureHelp)
        .workbenchSheet(item: $featureHelp.presentation, title: workflowText(language, "childPanel.name.help")) { presentation in
            WorkbenchFeatureGuide(presentation: presentation, store: featureHelp)
                .environment(\.dLanguageStore, language)
        }
        .workbenchSheet(isPresented: $noticesVisible, title: workflowText(language, "notices.title")) { WorkbenchThirdPartyNotices().environment(\.dLanguageStore, language) }
        .environment(\.workbenchSidebars, sidebarState)
        .environment(\.workbenchMenuContext, menuContext)
        .environment(\.openWorkbenchSettings, { section in presentSettings(section: section) })
        .workbenchTheme(paintsCanvas: false)
        .ignoresSafeArea(.container, edges: windowFullScreen ? [] : .top)
        .modifier(WorkbenchCanvasModifier(state: automaticQuickModel.chatDisplaySettings, stylesWindowTitlebar: true))
        .environment(\.chatDisplayPreferences, automaticQuickModel.chatDisplaySettings.preferences)
        .preferredColorScheme(automaticQuickModel.chatDisplaySettings.preferences.preferredColorScheme)
        .onAppear { consumeSettingsRequest() }
        .onChange(of: canvasModel.manifest?.effectiveInstanceID, initial: true) { _, owner in changeLibraryNavigationOwner(owner) }
        .onChange(of: settingsRequest) { _, _ in consumeSettingsRequest() }
        .onChange(of: canPresentSettings) { _, ready in if ready { consumeSettingsRequest() } }
        .workbenchSheet(isPresented: $settingsVisible, title: workflowText(language, "childPanel.name.settings"), onDismiss: finishSettingsDismissal) {
            if let language, let context = settingsContext {
                WorkbenchSettingsView(model: context.owner, library: library, language: language,
                    projectPath: context.files?.store.rootURL.path, searchTargetLabel: context.searchTitle,
                    onProjectFiles: { requestSettingsFiles(context) },
                    onSearchSettings: nil, chat: context.search, initialSection: settingsSection,
                    isChatContextValid: {
                        guard let target = context.search else { return false }
                        return context.searchOwner.projectSession.chat === target
                            && context.searchOwner.projectSession.currentStore === target.store
                            && target.state.selectedSessionID == context.searchSessionID
                            && !context.searchOwner.projectSession.isChangingProject
                    }).workbenchPresentation(state: context.owner.chatDisplaySettings)
            }
        }
        .onChange(of: libraryVisible) { _, shown in if shown { navigationIntent = UUID() } }
        .workbenchSheet(isPresented: $libraryVisible, title: workflowText(language, "childPanel.name.library"),
            size: .init(width: expandedLibraryMode == .nodes ? 1160 : 840), onDismiss: finishLibraryDismissal) {
            VStack(spacing: 0) {
                if !quickModel.projectSession.explicitModelChecking.isEmpty {
                    Text(t("checkingModel"))
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                }
                if let context = expandedLibraryContext, let controller = canvasModel.projectSession.workflow {
                    HStack {
                        Text(context.displayName(in: controller, language: language))
                        Button { expandedLibraryContext = nil; clearExpandedContext() } label: { Image(systemName: "xmark.circle") }
                            .help(workspaceText(language, "removeRelated"))
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                }
                libraryBrowser(compact: false, at: { CGPoint(x: 160, y: 140) }, canvasMode: expandedLibraryMode, forCanvas: expandedLibraryForCanvas)
                    .environment(\.workflowLibraryContext, expandedLibraryContext)
                    .environment(\.workflowContainerNavigation, expandedLibraryNavigation)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await refreshLibrary(checkModels: true) }
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .workbenchSheet(isPresented: $projectsVisible, title: workflowText(language, "childPanel.name.projects")) {
            VStack(spacing: 0) {
                HStack { Button(baselineText(language, "label.572cf45ba436")) { projectsVisible = false }.keyboardShortcut(.cancelAction); Text(baselineText(language, "label.79f326be4409")).font(.headline); Spacer() }.padding()
                ProjectChooserView(recentProjects: model.recentProjects, isBusy: model.isChangingProject,
                    onNew: { Task { if await model.newProject() { projectsVisible = false; navigate(to: .workflow) } } },
                    onOpen: { Task { if await model.openProject() { projectsVisible = false; navigate(to: .workflow) } } },
                    onRecent: { id in Task { if await model.openRecentProject(id: id) { projectsVisible = false; navigate(to: .workflow) } } },
                    onModels: { presentQuickModelSelection() })
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .workbenchSheet(item: $filesRoute, title: workflowText(language, "childPanel.name.files")) { route in
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
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
    }
    private var presentedWorkspace: some View {
        workspacePanels
        .workbenchSheet(isPresented: $compatibilityVisible, title: workflowText(language, "childPanel.name.legacy")) {
            VStack(spacing: 0) {
                HStack { Button(baselineText(language, "label.572cf45ba436")) { compatibilityVisible = false }.keyboardShortcut(.cancelAction); Text(layoutText(language, "legacy") + " · " + legacyName); Spacer() }.padding()
                if model.manifest?.effectiveInstanceID == legacyInstance {
                    WorkbenchView(model: model, library: library, nodeTags: nodeTags, metadata: metadata)
                } else { Text(layoutText(language, "legacyChanged")).padding(24) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .workbenchSheet(isPresented: Binding(get: { library.isPresented }, set: { library.isPresented = $0 }), title: workflowText(language, library.workspace == "downloads" ? "modelManagement.downloadTitle" : "modelManagement.modelTitle"), size: .init(download: true), onDismiss: restoreLibraryIfNeeded) {
            ModelLibraryView(model: library)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }

        .workbenchSheet(isPresented: $languageVisible, title: workflowText(language, "childPanel.name.language")) {
            VStack {
                HStack { Button(baselineText(language, "label.572cf45ba436")) { languageVisible = false }.keyboardShortcut(.cancelAction); Spacer() }
                if let language { LanguageSettingsView(store: language) }
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .workbenchConfirmation(consistencyText(language, "error.incomplete"), isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil; failedAssetRoute = nil } })) {
            Button(baselineText(language, "label.f867f3417859")) { issue = nil; failedAssetRoute = nil }.keyboardShortcut(.defaultAction)
            if let failedAssetRoute {
                Button(baselineText(language, "files.inspect", fallback: "查看文件位置")) {
                    issue = nil; self.failedAssetRoute = nil
                    if libraryVisible { returnToLibrary = true; pendingFilesRoute = failedAssetRoute; libraryVisible = false }
                    else { filesRoute = failedAssetRoute }
                }
            }
        } message: { WorkbenchIssueText(raw: issue ?? "", key: issueValue?.code) }
        .task {
            if quick.state.drafts.isEmpty && quick.state.navigation == nil { quick.select(operationID: "d.model.language", modelID: "") }
            await refreshLibrary(checkModels: false)
            #if DEBUG
            WorkbenchCategoryUpdateProbe.phase("initial-library-ready")
            #endif
        }
        // Draft autosaves do not change installed models or assets. Refresh at
        // result/publication boundaries, not on every typing pause.
        .onChange(of: quick.isRunning) { _, running in if !running { Task { await refreshLibrary(checkModels: false) } } }
        .onChange(of: quick.pendingSaveRunID) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .onChange(of: library.isPresented) { _, presented in if !presented { Task { await refreshLibrary(checkModels: false) } } }
        .onChange(of: installationStates) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .onChange(of: model.manifest?.effectiveInstanceID) { _, _ in useProjectQuick = true; model.viewers.reconcile() }
        .onChange(of: automaticQuickModel.manifest?.effectiveInstanceID) { _,_ in automaticQuickModel.viewers.reconcile() }
        .workbenchConfirmation(workspaceText(language, "pinLegacy"),isPresented:Binding(get:{pendingLegacyPreview != nil},set:{if !$0 {pendingLegacyPreview=nil}})) {
            if let value=pendingLegacyPreview {
                Button(workspaceText(language, "pinAndView")) {
                    pendingLegacyPreview=nil;Task { await previewLibraryEntry(value,allowPin:true) }
                }.keyboardShortcut(.defaultAction)
            }
            Button(workspaceText(language, "cancel"),role:.cancel) { pendingLegacyPreview=nil }.keyboardShortcut(.cancelAction)
        } message: { Text(workspaceText(language, "pinExplanation")) }
        .onChange(of: model.manifest?.revision) { _, _ in Task { await refreshLibrary(checkModels: false) } }


    }
    public var body: some View {
        presentedWorkspace
        .workbenchSheet(item: $previewAsset, title: workflowText(language, "childPanel.name.preview"), onDismiss: {
            if let pendingFilesRoute {
                returnToLibrary = false; filesRoute = pendingFilesRoute; self.pendingFilesRoute = nil
            }
            else { restoreLibraryIfNeeded() }
        }) { value in
            VStack {
                HStack { Button(baselineText(language, "label.572cf45ba436")) { previewAsset = nil }.keyboardShortcut(.cancelAction); Spacer() }
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
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .workbenchSheet(item: $libraryInfo, title: workflowText(language, "childPanel.name.details"), onDismiss: restoreLibraryIfNeeded) { value in
            VStack(alignment: .leading, spacing: 14) { HStack { Button(baselineText(language, "label.572cf45ba436")) { libraryInfo = nil }; Text(value.item.title).font(.title2); Spacer() }
                Text(value.item.detail); ForEach(value.facts, id: \.self) { Text($0).textSelection(.enabled) }
                if case .unavailable = value.selection { Button(baselineText(language, "label.32d818ead29f")) { returnToLibrary = false; libraryInfo = nil; libraryVisible = false; openLegacy() } }
            }.padding(24).frame(minWidth: 550, minHeight: 280)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .environment(\.metadataEditorLifecycle, MetadataEditorLifecycle(begin: model.beginEditing, end: model.endEditing))
        .focusedSceneValue(\.workbenchGeneration, WorkbenchGenerationCommand(title: t("quickAction"), isEnabled: quickCommandEnabled,
            action: { if commandScope.permitsCommands && quickCommandEnabled { quick.start() } }))
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
        case .models: library.presentManagement()
        case .modelSelection(let open): open()
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
    private func canvasLibraryContent(_ mode: WorkflowCanvasLibraryMode,
                                      _ point: @escaping () -> CGPoint?,
                                      _ close: @escaping () -> Void) -> AnyView {
        AnyView(libraryBrowser(compact: true, at: point, onBack: close, canvasMode: mode, forCanvas: true))
    }

    @ViewBuilder private func libraryBrowser(compact: Bool, at point: @escaping () -> CGPoint?, onBack: (() -> Void)? = nil, canvasMode: WorkflowCanvasLibraryMode? = nil, forCanvas: Bool = false, headerOnly: Bool = false) -> some View {
        if let metadata {
            let sourceEntries: [SharedLibraryBrowserEntry] = {
                if forCanvas, let category = canvasMode?.resourceCategory {
                    return workspaceAssetEntries.filter { $0.item.kind == .asset && category.contains($0.item.contentKind) }
                }
                _ = entries // Refresh the complete semantic inputs before selecting.
                let candidates = libraryProjection.selection(canvasMode: canvasMode, family: nil)
                guard !forCanvas, let family = modelPickerCategory else { return candidates }
                return candidates.filter { value in
                    guard case .operation(let operation, let identity) = value.selection, let identity else { return false }
                    return selectionModel.projectSession.supportsQuick(operationID: operation, identity: identity,
                        category: family, conversation: family == .text && quick.textPresentation == .chat)
                }
            }()
            let collectAction: (([SharedLibraryBrowserEntry], Bool) -> Void)? = !forCanvas || canvasMode?.resourceCategory == nil ? nil : { values, collect in collectLibraryEntries(values, collect) }
            SharedLibraryBrowser(entries: sourceEntries, store: metadata, compact: compact, allowsImport: canvasMode?.resourceCategory != nil, canvasMode:canvasMode,
                scopeDescription: ([!forCanvas ? modelPickerCategory.map { workflowText(language, "quick.requiredTask." + $0.rawValue) } : nil, model.manifest?.name, automaticQuickModel.manifest == nil ? nil : layoutText(language, "independent")].compactMap { $0 }).joined(separator: " · "),
                importTargetDescription: forCanvas ? canvasModel.manifest?.name ?? "—" : quickImportTitle,
                state: canvasMode.flatMap { canvasLibraryStates[$0] } ?? (compact ? compactLibraryState : fullLibraryState),
                onCollect: collectAction,
                onUse: useLibraryEntry, onAdd: { value in
                    guard let insertionPoint = point() else { return }
                    beginAddingLibraryEntry(value, at: insertionPoint)
                },
                onPreview: { value in Task { await previewLibraryEntry(value) } },
                onExternalCopy: { value in Task { await openExternalLibraryCopy(value) } },
                onExport: { value, current in Task { await exportLibraryAsset(value, isCurrent: current) } }, readPreview: readLibraryPreview,
                onLocation: { value in Task { await showAssetLocation(value) } },
                onPrepare: { value in Task { await prepareModel(value) } },
                onImport: { beginLibraryImport(forCanvas: forCanvas) }, onClose: { if let onBack { onBack() } else { libraryVisible = false } }, tagValidation: libraryTagValidation,
                queryContext: libraryQueryContext(forCanvas: forCanvas),
                annotationSave: libraryAnnotationSave)
                .importingFiles { canvasMode?.resourceCategory != nil ? captureLibraryImport(forCanvas: forCanvas) : nil }
                .headerActionsOnly(headerOnly)
                .environment(\.workflowLibraryInsertionController, canvasModel.projectSession.workflow)
        } else {
            VStack(alignment: .leading) {
                Button(baselineText(language, "label.572cf45ba436"), systemImage: "chevron.left") {
                    if let onBack { onBack() } else { libraryVisible = false }
                }
                Text(metadataIssue ?? consistencyText(language, "error.organization")).textSelection(.enabled)
                Button(baselineText(language, "label.17bb056515cd")) { libraryVisible = false; library.presentManagement() }
            }.padding()
        }
    }
    private var workspaceAssetEntries:[SharedLibraryBrowserEntry] {
        guard let controller = canvasModel.projectSession.workflow else { return [] }
        let saved = entries.filter { $0.item.kind == .asset && $0.metadataSnapshot?.projectID == controller.projectID && $0.metadataSnapshot?.instanceID == controller.projectInstanceID }
        let references=Set(saved.compactMap { $0.metadataSnapshot?.record?.reference })
        let projected=WorkflowLibraryValue.entries(controller,language:language,excludingSaved:references,library:metadata,indexedSaved:saved.compactMap(\.metadataSnapshot))
        let regular = (saved + projected).map { entry in
            var result = entry
            if let snapshot = entry.metadataSnapshot {
                result.collected = controller.assetCollection?.contains(asset: snapshot.asset) ?? true
                result.collectionSource = snapshot.record.map { .asset($0.reference) }
            } else if let runtime = entry.runtimeValue, let record = controller.runs.first(where: { $0.id == runtime.call.address.runID })?.planCheckpoint?.records.first(where: { $0.id == runtime.call.stepID }),
                      let source = try? WorkflowRuntimeAssetSource.capture(record, port: runtime.port) {
                result.collectionSource = runtime.reference.map(WorkflowLibrarySource.asset) ?? .runtime(source)
                result.collected = result.collectionSource.map(controller.isCollected) ?? false
            }
            return result
        }
        let visibleSources = Set(regular.compactMap { $0.collectionSource?.key })
        return regular + WorkflowLibraryValue.collectedEntries(controller, language: language, library: metadata).filter { !visibleSources.contains($0.collectionSource?.key ?? "") }
    }
    private func collectLibraryEntries(_ values: [SharedLibraryBrowserEntry], _ collect: Bool) {
        guard let controller = canvasModel.projectSession.workflow, let owner = controller.assetLibraryOwner else { return }
        let validations = values.map(libraryTagValidation)
        Task {
            do {
                var sources: [WorkflowLibrarySource] = []
                for (value, validate) in zip(values, validations) {
                    try validate()
                    if let source = value.collectionSource { sources.append(source) }
                    else if let asset = value.metadataSnapshot {
                        sources.append(.asset(try await controller.services.store.pinWorkflowAsset(asset.asset.id)))
                    } else { throw WorkflowIssue(workflowText(language, "container.stale")) }
                }
                for validate in validations { try validate() }
                try await controller.setCollected(sources, collected: collect, owner: owner)
                await refreshLibrary(checkModels: false)
            } catch { controller.errorMessage = error.localizedDescription }
        }
    }
    private func libraryTagValidation(_ value: SharedLibraryBrowserEntry) -> () throws -> Void {
        let intent = navigationIntent
        if let runtime = value.runtimeValue {
            let owner = canvasModel.projectSession, controller = canvasModel.projectSession.workflow
            let store = owner.currentStore, epoch = owner.navigationEpoch
            return {
                guard navigationIntent == intent, owner.canEditLibraryMetadata, owner.currentStore === store,
                      owner.navigationEpoch == epoch, let controller, owner.workflow === controller,
                      runtime.isCurrent(in: controller) else { throw SharedLibraryError.staleAnnotation }
            }
        }
        if let identity = assetIdentity(value.selection) {
            let sessions = [model.projectSession, automaticQuickModel.projectSession]
            let matches = sessions.filter { session in
                session.manifest?.id == identity.0 && (identity.1 == nil || session.manifest?.effectiveInstanceID == identity.1)
            }
            guard let owner = matches.first, let store = owner.currentStore,
                  Set(matches.compactMap { $0.manifest?.effectiveInstanceID }).count == 1 else {
                return { throw WorkflowIssue("Metadata target unavailable / 素材所属实例不可访问。") }
            }
            let instance = owner.manifest?.effectiveInstanceID, epoch = owner.navigationEpoch
            return {
                guard navigationIntent == intent, owner.canEditLibraryMetadata,
                      owner.currentStore === store, owner.navigationEpoch == epoch,
                      owner.manifest?.effectiveInstanceID == instance,
                      owner.manifest?.assets.contains(where: { $0.id == identity.2 }) == true else {
                    throw WorkflowIssue("Metadata target changed / 所属项目实例或页面已改变，草稿未提交。")
                }
            }
        }
        return { guard navigationIntent == intent else { throw WorkflowIssue("Library page changed / 资料库页面已改变，草稿未提交。") } }
    }
    private func libraryQueryContext(forCanvas: Bool) -> SharedLibraryQueryContext {
        let owner = forCanvas || entry == .workflow ? canvasModel : quickModel
        return .init(projectID: owner.manifest?.id, instanceID: owner.manifest?.effectiveInstanceID)
    }
    private func libraryAnnotationSave(_ value: SharedLibraryBrowserEntry) -> SharedLibraryAnnotationSave? {
        guard let identity = assetIdentity(value.selection), let snapshot = value.metadataSnapshot else { return nil }
        let sessions = [model.projectSession, automaticQuickModel.projectSession]
        guard let session = sessions.first(where: { $0.manifest?.effectiveInstanceID == snapshot.instanceID && $0.manifest?.id == identity.0 }),
              let owner = session.currentStore else { return nil }
        let validation = libraryTagValidation(value)
        return { expected, name, note, favorite in
            try validation()
            try await session.saveAssetAnnotations(owner: owner, expected: expected, name: name, note: note, isFavorite: favorite)
            await refreshLibrary(checkModels: false)
        }
    }
    private func refreshLibrary(checkModels: Bool) async {
        let generation = UUID(); libraryRefreshGeneration = generation
        quickModel.projectSession.refreshWorkflowModels()
        if model.projectSession !== quickModel.projectSession { model.projectSession.refreshWorkflowModels() }
        let installationSnapshot = await library.library.snapshot()
        let quickDemand = Set([quickModelIdentity].compactMap { $0 }.filter { !$0.isEmpty })
        quickModel.projectSession.observeModelAvailability(installationSnapshot,
            demanded: quickDemand.union(quickModel.projectSession.openGraphModelIdentities))
        if model.projectSession !== quickModel.projectSession {
            model.projectSession.observeModelAvailability(installationSnapshot, demanded: model.projectSession.openGraphModelIdentities)
        }
        if checkModels { await checkDemandReadiness() }

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
        var projected: [String: ProjectAssetMetadataSnapshot] = [:]
        var owners = [automaticQuick.store]
        if let otherStore, otherStore !== automaticQuick.store { owners.append(otherStore) }
        for owner in owners {
            if let values = try? await owner.libraryMetadataSnapshots() {
                let current = await owner.snapshot()
                guard snapshots.contains(where: { $0.effectiveInstanceID == current.effectiveInstanceID && $0.revision == current.revision }) else { return }
                for value in values { projected["asset-instance:" + value.instanceID.uuidString + ":" + value.asset.id.uuidString] = value }
            }
        }
        guard !Task.isCancelled, libraryRefreshGeneration == generation, model.projectSession.currentStore === otherStore else { return }
        // This projection owns at most the currently open project and automatic quick project.
        // A newer refresh, project switch, or closing instance replaces the entire map.
        projects = snapshots; libraryMetadata = projected

    }
    private var quickSurface: some View {
        let owner = quick.store.rootURL.standardizedFileURL.path
        let installations: [String: ModelID] = quickModelIdentity.flatMap { identity in
            quickModel.projectSession.workflowInstallationID(for: identity).map { [identity: $0] }
        } ?? [:]
        return QuickGenerationView(quick: quick, model: quickModel,
                    selectedResults: Binding(get: { quickPreviewSelections[owner] ?? [:] },
                        set: { quickPreviewSelections[owner] = $0 }), onChooseModel: { openModelChoices(quick.category) },
                    onSettingsToCanvas: { draft in let source = quick.store; Task { await settingsToCanvas(draft, from: source) } },
                    onResultToCanvas: { ref in let source = quick.store; Task { await resultToCanvas(ref, from: source) } },
                    onValueToCanvas: { value in let source = quick.store; Task { await valueToCanvas(value, from: source) } },
                    onOpenLibrary: { openLibrary(.assets, forCanvas: false) },
                    onImportAsset: { beginLibraryImport(forCanvas: false) },
                    importTargetTitle: quickImportTitle,
            onAssetsChanged: { Task { await refreshLibrary(checkModels: false) } },
                    onResolveSharedAsset: { projectID, instanceID, assetID in
                        let source = try await store(for: projectID, instanceID: instanceID)
                        let manifest = await source.snapshot()
                        guard let asset = manifest.assets.first(where: { $0.id == assetID }) else {
                            throw WorkflowIssue("源素材已不存在。")
                        }
                        return (source, try await source.pinWorkflowAsset(assetID), asset.name)
                    }, textWorkspaceActions: AnyView(singleTextActions))
                    .environment(\.workflowModelPreparation, library.nodePreparationPresentation)
                    .environment(\.workflowModelInstallations, installations)
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
        guard selectionModel.projectSession.supportsQuick(operationID: node.operationID, identity: node.parameters["modelID"]?.string ?? "", category: .text, conversation: true) else {
            // The selected legacy model has single-turn semantics. Show its real
            // surface rather than silently retaining a different chat model.
            captureChatReading()
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
            guard selectionModel.projectSession.supportsQuick(operationID: operation, identity: identity, category: .text, conversation: true),
                  var node = WorkflowRegistry.standard.operation(operation)?.definition.makeNode() else {
                throw WorkflowIssue("临时聊天需要支持有序消息的文字模型；其他能力请返回普通快速生成。")
            }
            node.parameters["modelID"] = .text(identity); node.parameters["outputMode"] = .text("text")
            try chat.selectModelConfiguration(node, sessionID: try chat.state.selectedSessionID ?? chat.newSession())
            return
        }
        captureChatReading()
        quick.select(operationID: operation, modelID: identity); applySelectedModelToChat()
    }
    private func useLibraryEntry(_ value: SharedLibraryBrowserEntry) {
        guard !quickOwnerIsChanging else { issue = "项目正在切换，当前快速草稿未改变。"; return }
        guard case .operation(let operation, let id) = value.selection,
              let id, WorkflowRegistry.standard.operation(operation)?.definition.modelKind != nil else { presentLibraryDestination(.info(value)); return }
        if let family = modelPickerCategory,
           !selectionModel.projectSession.supportsQuick(operationID: operation, identity: id, category: family,
                conversation: family == .text && quick.textPresentation == .chat) { issue = workflowText(language, "quick.incompatibleTask"); return }
        do { try selectModel(operation: operation, identity: id) }
        catch { issue = error.localizedDescription; return }
        navigate(to: .quick)
        let owner = selectionModel.projectSession
        if owner.explicitModelReadiness[id] != .available || (library.snapshot?.runnableResources(identity: id).count ?? 0) > 1 {
            // A catalog identity chooses a draft, not an installed copy. Keep the
            // explicit copy picker reachable from ordinary Chat/Quick selection.
            // Capture before the catalog closes; never retarget during dismissal.
            let store = owner.currentStore, controller = quick, draftID = quick.draft?.id
            let sessionID = chat?.state.selectedSessionID, temporary = usesTemporaryChat, intent = navigationIntent
            presentLibraryDestination(.modelSelection {
                guard !quickOwnerIsChanging, navigationIntent == intent,
                      selectionModel.projectSession === owner, owner.currentStore === store,
                      quick === controller, quick.draft?.id == draftID,
                      chat?.state.selectedSessionID == sessionID, usesTemporaryChat == temporary,
                      quickModelIdentity == id else { issue = t("targetChanged"); return }
                presentQuickModelSelection(expectedIdentity: id)
            })
            returnToLibrary = false
        } else { libraryVisible = false }
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
    private func previewLibraryEntry(_ value: SharedLibraryBrowserEntry, allowPin:Bool=false) async {
        guard let previewWindow = commandScope.window, previewWindow.isKeyWindow else { return }
        if let runtime=value.runtimeValue {
            guard let controller=canvasModel.projectSession.workflow,runtime.isCurrent(in:controller) else { issue=t("runtimeUnavailable");return }
            do { canvasModel.viewers.library=metadata;try canvasModel.viewers.open(.init(title:value.item.title,subtitle:value.item.detail,value:runtime.value,call:runtime.call,port:runtime.port,usesCallTitle: true,runtimeSource:runtime.source),model:canvasModel,language:language,ownerWindow:previewWindow) }
            catch { issue=error.localizedDescription }
            return
        }
        let request = UUID(); previewNavigationRequest = request
        let intent = navigationIntent
        failedAssetRoute = nil
        guard let identity = assetIdentity(value.selection) else { presentLibraryDestination(.info(value)); return }
        let owners = [model.projectSession, automaticQuickModel.projectSession].filter {
            $0.manifest?.id == identity.0 && (identity.1 == nil || $0.manifest?.effectiveInstanceID == identity.1)
        }
        guard Set(owners.compactMap { $0.manifest?.effectiveInstanceID }).count == 1,
              let owner = owners.first, let source = owner.currentStore else {
            issue = "所属项目实例已关闭或不明确，请重新打开。 / Source instance unavailable or ambiguous."; return
        }
        let epoch = owner.navigationEpoch
        @MainActor func current() -> Bool {
            !Task.isCancelled && navigationIntent == intent && previewNavigationRequest == request &&
                owner.currentStore === source && owner.navigationEpoch == epoch && owner.canEditLibraryMetadata
        }
        do {
            guard current() else { return }
            let content = try await source.readOnlyAsset(id: identity.2, reference: value.metadataSnapshot?.record?.reference)
            guard current(), content.token.projectID == identity.0,
                  identity.1 == nil || content.token.instanceID == identity.1 else { return }
            guard let owningModel = [model,automaticQuickModel].first(where: { $0.projectSession === owner }) else { return }
            owningModel.viewers.library = metadata
            try owningModel.viewers.open(.init(title:value.item.title, subtitle:value.item.detail, resource:content.token), model:owningModel, language:language, ownerWindow:previewWindow)
        } catch {
            guard current() else { return }
            let snapshot = await source.snapshot()
            guard current() else { return }
            if snapshot.assets.contains(where: { $0.id == identity.2 }) {
                failedAssetRoute = .init(store: source, instanceID: snapshot.effectiveInstanceID, assetID: identity.2)
            }
            issue = error.localizedDescription
        }
    }
    private func readLibraryPreview(_ value: SharedLibraryBrowserEntry) async throws -> ProjectReadOnlyContent {
        if let runtime = value.runtimeValue {
            guard let controller = canvasModel.projectSession.workflow, runtime.isCurrent(in: controller),
                  let reference = runtime.reference else { throw WorkflowIssue(t("noRuntimeFile")) }
            let source = try await store(for: runtime.projectID, instanceID: runtime.instanceID)
            let result = try await source.readOnlyAsset(id: reference.assetID, reference: reference)
            guard runtime.isCurrent(in: controller), canvasModel.projectSession.workflow === controller else { throw WorkflowIssue(t("resultChanged")) }
            try Task.checkCancellation(); return result
        }
        guard let identity = assetIdentity(value.selection) else { throw WorkflowIssue(t("noFilePreview")) }
        let source = try await store(for: identity.0, instanceID: identity.1)
        let result = try await source.readOnlyAsset(id: identity.2, reference: value.metadataSnapshot?.record?.reference)
        _ = try await store(for: result.token.projectID, instanceID: result.token.instanceID)
        try Task.checkCancellation()
        return result
    }
    private func exportLibraryAsset(_ value: SharedLibraryBrowserEntry, isCurrent: @escaping () -> Bool) async {
        let intent = navigationIntent, owner = displayedOwner, epoch = displayedOwner.projectSession.navigationEpoch
        do {
            guard isCurrent() else { throw WorkflowIssue(systemMenuText(language, "stale")) }
            let content = try await readLibraryPreview(value)
            let source = try await store(for: content.token.projectID, instanceID: content.token.instanceID)
            guard isCurrent(), navigationIntent == intent, displayedOwner === owner, owner.projectSession.navigationEpoch == epoch else { throw WorkflowIssue(systemMenuText(language, "stale")) }
            let panel = NSSavePanel(); panel.title = systemMenuText(language, "export")
            panel.nameFieldStringValue = content.metadata.asset.name
            if let type = UTType(mimeType: content.token.mediaType), let suffix = type.preferredFilenameExtension {
                panel.allowedContentTypes = [type]; panel.nameFieldStringValue = suggestedExternalCopyName(content.metadata.asset.name, suffix: suffix)
            }
            guard await panel.begin() == .OK, let destination = panel.url else { return }
            guard isCurrent(), navigationIntent == intent, displayedOwner === owner, owner.projectSession.navigationEpoch == epoch else { throw WorkflowIssue(systemMenuText(language, "stale")) }
            _ = try await store(for: content.token.projectID, instanceID: content.token.instanceID)
            try await source.exportReadOnlyCopy(content.token, to: destination)
        } catch { issue = error.localizedDescription }
    }
    private func openExternalLibraryCopy(_ value: SharedLibraryBrowserEntry) async {
        do {
            let content = try await readLibraryPreview(value)
            let source = try await store(for: content.token.projectID, instanceID: content.token.instanceID)
            let extensions = ["text/plain":"txt", "text/markdown":"md", "image/png":"png", "image/jpeg":"jpg",
                "video/mp4":"mp4", "audio/wav":"wav", "audio/x-caf":"caf", "application/pdf":"pdf",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document":"docx"]
            guard let suffix = extensions[content.token.mediaType] else {
                throw WorkflowIssue(t("externalUnsupported"))
            }
            let panel = NSSavePanel(); panel.title = workspaceText(language, "externalCopy")
            panel.nameFieldStringValue = suggestedExternalCopyName(content.metadata.asset.name, suffix: suffix)
            if let type = UTType(filenameExtension: suffix) { panel.allowedContentTypes = [type] }
            guard await panel.begin() == .OK, let destination = panel.url else { return }
            _ = try await store(for: content.token.projectID, instanceID: content.token.instanceID)
            try await source.exportReadOnlyCopy(content.token, to: destination)
            guard NSWorkspace.shared.open(destination) else { throw WorkflowIssue("副本已保存，但外部应用未能打开；文件保留在：" + destination.path) }
        } catch { issue = error.localizedDescription }
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
        guard case .operation(let id, let modelID) = value.selection, let kind = WorkflowRegistry.standard.operation(id)?.definition.modelKind else { presentLibraryDestination(.info(value)); return }
        if let modelID, let catalog = ModelLibraryModel.nodeDownloadEntry(operationID: id, identity: modelID, catalog: library.catalog) {
            let owner = selectionModel.projectSession, controller = quick, store = selectionModel.projectSession.currentStore
            let draft = controller.draft, temporary = usesTemporaryChat, selectedChatID = chat?.state.selectedSessionID
            let configuration = chat?.selectedSession?.configuration, intent = navigationIntent, sourceEntry = entry
            let identity = quickModelIdentity, presentation = controller.textPresentation, category = controller.category
            let selectedOperation = category == .text && presentation == .chat ? configuration?.operationID ?? draft?.node.operationID : draft?.node.operationID
            let matchesDraft = sourceEntry == .quick && !temporary && selectedOperation == id && identity == modelID
            let isCurrent: @MainActor () -> Bool = {
                !quickOwnerIsChanging && !temporaryChatChanging && selectionModel.projectSession === owner && owner.currentStore === store && quick === controller
                    && temporary == usesTemporaryChat && controller.draft?.id == draft?.id && quickModelIdentity == identity
                    && chat?.state.selectedSessionID == selectedChatID && chat?.selectedSession?.configuration == configuration
                    && navigationIntent == intent && entry == sourceEntry && controller.textPresentation == presentation && controller.category == category
            }
            presentLibraryDestination(.modelSelection {
                if matchesDraft {
                    Task {
                        await library.requestNodeAcquisition(operationID: id, identity: modelID, title: value.item.title, isCurrent: isCurrent) { installation, authorized in
                            guard authorized(), isCurrent() else { throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。")) }
                            _ = try await owner.selectWorkflowInstallation(id: installation) { choice in
                                guard authorized(), isCurrent(), choice.id == modelID, choice.kind == kind else { throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。")) }
                            }
                            // The draft already names this exact variant. Do not select a different draft or infer.
                        }
                    }
                } else { library.requestAcquisition(catalogIDs: [catalog.id]) }
            })
            return
        }
        guard !usesTemporaryChat else {
            issue = t("temporaryModelUnavailable")
            return
        }
        let owner = quickModel.projectSession, controller = quick
        let draftID = controller.draft?.id
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = t("registerMessage")
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
    /// Capture at the command boundary, before any file-panel suspension.
    private func beginLibraryImport(forCanvas: Bool) {
        guard let command = captureLibraryImport(forCanvas: forCanvas) else { return }
        Task { @MainActor in
            do { _ = try await command.perform(choose: { await NativeAssetImportPanel.choose(language: language) }) }
            catch { issue = error.localizedDescription }
        }
    }
    private func captureLibraryImport(forCanvas: Bool) -> WorkbenchAssetImportCommand? {
        let owner = forCanvas ? canvasModel : quickModel
        let session = owner.projectSession, epoch = owner.projectSession.navigationEpoch
        let store = session.currentStore, instance = owner.manifest?.effectiveInstanceID
        let controller = forCanvas ? session.workflow : nil
        let originalQuick = quick
        guard let store, instance != nil, !owner.isChangingProject,
              !forCanvas || controller?.canEditCanvas == true else { return nil }
        let current: @MainActor () -> Bool = {
            let displayed = forCanvas ? canvasModel : quickModel
            return (entry == .workflow) == forCanvas && displayed === owner && session.currentStore === store
                && owner.manifest?.effectiveInstanceID == instance && session.navigationEpoch == epoch && !owner.isChangingProject
                && (forCanvas ? session.workflow === controller && controller?.canEditCanvas == true : quick === originalQuick)
        }
        return WorkbenchAssetImportCommand(store: store, controller: controller,
            staleMessage: layoutText(language, "staleImport"), isCurrent: current,
            didImport: { await refreshLibrary(checkModels: false) })
    }

    private func beginAddingLibraryEntry(_ value: SharedLibraryBrowserEntry, at point: CGPoint) {
        let owner = canvasModel.projectSession
        let intent = navigationIntent, wasLibraryVisible = libraryVisible
        guard let controller = owner.workflow else {
            // Opening is presentation only. A second explicit Add captures the now visible target.
            Task { await owner.openWorkflow(); if canvasModel.projectSession === owner, navigationIntent == intent, libraryVisible == wasLibraryVisible { navigate(to: .workflow) } }
            issue = t("openWorkflowBeforeAdd")
            return
        }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { return }
        Task { await addLibraryEntry(value, at: point, owner: owner, controller: controller, scope: scope, navigationIntent: intent, wasLibraryVisible: wasLibraryVisible) }
    }
    private func addLibraryEntry(_ value: SharedLibraryBrowserEntry, at point: CGPoint,
                                 owner: ProjectSession, controller: WorkflowController, scope: WorkflowCanvasInsertionTarget, navigationIntent intent: UUID, wasLibraryVisible: Bool) async {
        guard canvasModel.projectSession === owner, owner.workflow === controller, controller.isCurrent(scope) else { return }
        do {
            if let source = value.collectionSource, let libraryOwner = controller.assetLibraryOwner {
                try libraryTagValidation(value)()
                try await controller.insertLibrarySources([source], owner: libraryOwner, target: scope, x: point.x, y: point.y)
                if canvasModel.projectSession === owner, owner.workflow === controller, navigationIntent == intent, libraryVisible == wasLibraryVisible { libraryVisible = false; navigate(to: .workflow) }
                return
            }
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
                guard canvasModel.projectSession === owner, owner.workflow === controller else { throw WorkflowIssue("目标项目已改变。") }
                try await controller.insertQuickResult(copied, target: scope, x: point.x, y: point.y)
            case .unavailable(let reason): throw WorkflowIssue(reason)
            }
            try await controller.saveExplicitEdits()
            if canvasModel.projectSession === owner, owner.workflow === controller, navigationIntent == intent, libraryVisible == wasLibraryVisible { libraryVisible = false; navigate(to: .workflow) }
        } catch { issueValue = .init(presenting: error, fallbackCode: "container.issue.actionFailed") }
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

/// Preserve display names, including dotted version labels. Only avoid adding
/// a format suffix that is already present (or has an equivalent UTType).
func suggestedExternalCopyName(_ name: String, suffix: String) -> String {
    let existing = (name as NSString).pathExtension
    if existing.caseInsensitiveCompare(suffix) == .orderedSame { return name }
    if let current = UTType(filenameExtension: existing), let expected = UTType(filenameExtension: suffix),
       current == expected { return name }
    return name + "." + suffix
}

/// The same captured commands feed the internal menu and component checks.
@MainActor @WorkbenchMenuBuilder
func quickTextWorkspaceRows(presentation: QuickTextPresentation, temporary: Bool,
    language: UILanguageStore?, enabled: Bool, current: @escaping () -> Bool,
    temporaryAction: @escaping () -> Void, switchAction: @escaping () -> Void) -> WorkbenchMenuRows {
    if presentation == .chat {
        WorkbenchMenuAction(workflowText(language, temporary ? "quick.textWorkspace.endTemporary" : "quick.textWorkspace.newTemporary"), id: "chat-temporary-toggle") {
            guard current() else { return }; temporaryAction()
        }.disabled(!enabled).validation(current)
        WorkbenchMenuDivider()
    }
    WorkbenchMenuAction(workflowText(language, presentation == .chat ? "quick.textWorkspace.toSingle" : "quick.textWorkspace.toChat"), id: "text-presentation-switch") {
        guard current() else { return }; switchAction()
    }.disabled(!enabled).validation(current)
}
