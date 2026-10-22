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
    private var usesTemporaryChat: Bool { entry == .quick && quick.category == .text && quick.textPresentation == .chat && automaticQuickModel.temporaryChatModel != nil }
    private var chatModel: WorkbenchModel { usesTemporaryChat ? (automaticQuickModel.temporaryChatModel ?? quickModel) : quickModel }
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
    @State private var libraryProjection = SharedLibraryProjectionCache()
    private var entries: [SharedLibraryBrowserEntry] {
        libraryProjection.entries(models: quickModel.projectSession.explicitModelChoices,
            readiness: quickModel.projectSession.explicitModelReadiness,
            tools: canvasModel.projectSession.workflow?.tools ?? [], projects: projects, language: language, metadata: libraryMetadata, tags: nodeTags)
    }

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
    @State private var entryHistory: [Entry] = []
    @State private var navigationIntent = UUID()
    @State private var previewNavigationRequest = UUID()
    @State private var libraryVisible = false
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
    @State private var featureHelp = WorkbenchHelpStore()
    public init(model: WorkbenchModel, quickModel: WorkbenchModel, quick: QuickGenerationController,
                library: ModelLibraryModel, nodeTags: ModelNodeTagStore, metadata: SharedLibraryStore?, metadataIssue: String? = nil, settingsRequest: Binding<UUID?> = .constant(nil), windowHasSheet: Bool = false) {
        self._settingsRequest = settingsRequest
        self.windowHasSheet = windowHasSheet
        self.model = model; self.automaticQuickModel = quickModel; self.automaticQuick = quick; self.library = library; self.nodeTags = nodeTags; self.metadata = metadata; self.metadataIssue = metadataIssue
    }
    private func t(_ key: String) -> String { workflowText(language, "refinement.shell." + key) }
    private var canPresentSettings: Bool {
        featureHelp.presentation == nil && !windowHasSheet && !settingsVisible && !libraryVisible && !projectsVisible && !compatibilityVisible && !languageVisible
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
        settingsDestination = nil
        settingsSection = section
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
                issue = t("targetChanged")
                return
            }
            filesRoute = route
        }
    }

    private func navigate(to destination: Entry) {
        guard destination != entry else { return }
        captureChatReading(); navigationIntent = UUID()
        entryHistory.append(entry); entry = destination
    }
    private func goBack() {
        guard let previous = entryHistory.popLast() else { return }
        captureChatReading(); navigationIntent = UUID()
        entry = previous
    }
    private func presentQuickModelSelection() {
        let owner = selectionModel.projectSession, temporary = usesTemporaryChat, controller = quick
        let store = owner.currentStore
        let selectedDraftID = controller.draft?.id, selectedChatID = chat?.state.selectedSessionID
        library.presentSelection(selected: owner.workflowInstallationID(for: quickModelIdentity)) { id in
            do {
                guard !quickOwnerIsChanging, selectionModel.projectSession === owner, owner.currentStore === store,
                      temporary == usesTemporaryChat, quick === controller,
                      controller.draft?.id == selectedDraftID, chat?.state.selectedSessionID == selectedChatID else {
                    throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。"))
                }
                let choice = try await owner.selectWorkflowInstallation(id: id) { choice in
                    guard !quickOwnerIsChanging, selectionModel.projectSession === owner, owner.currentStore === store,
                          temporary == usesTemporaryChat, quick === controller,
                          controller.draft?.id == selectedDraftID, chat?.state.selectedSessionID == selectedChatID else {
                        throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。"))
                    }
                    guard let operation = WorkflowModelRoutes.operation(for: choice),
                          !temporary || [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38].contains(operation) else { throw WorkflowIssue(library.managementText("noRoute", "此配置没有可用的共享操作。")) }
                }
                guard !quickOwnerIsChanging, selectionModel.projectSession === owner, owner.currentStore === store,
                      temporary == usesTemporaryChat, quick === controller,
                      controller.draft?.id == selectedDraftID, chat?.state.selectedSessionID == selectedChatID else {
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
        }
        library.configurationSelectionAction = { item in
            do {
                guard !quickOwnerIsChanging, selectionModel.projectSession === owner, owner.currentStore === store,
                      temporary == usesTemporaryChat, quick === controller,
                      controller.draft?.id == selectedDraftID, chat?.state.selectedSessionID == selectedChatID,
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

    private var saveCommand: WorkbenchGenerationCommand {
        if entry == .workflow, let controller = canvasModel.projectSession.workflow {
            return .init(title: consistencyText(language, "FLOW-SAVE"), isEnabled: !controller.isSaving && !canvasModel.isChangingProject) {
                guard entry == .workflow, canvasModel.projectSession.workflow === controller else { return }
                Task { await controller.save() }
            }
        }
        let owner = quick
        let activeChat = quick.category == .text && quick.textPresentation == .chat ? chat : nil
        return .init(title: t("saveDraft"), isEnabled: !quickOwnerIsChanging) {
            guard entry == .quick, quick === owner, !quickOwnerIsChanging else { return }
            Task {
                do {
                    if let activeChat { guard chat === activeChat else { return }; try await activeChat.flush() }
                    else { try await owner.flush() }
                } catch { issue = error.localizedDescription }
            }
        }
    }
    private var applicationToolbar: some View {
        HStack(spacing: 12) {
            Button(action: goBack) { Image(systemName: "chevron.left") }
                .disabled(entryHistory.isEmpty).help(t("back")).accessibilityIdentifier("workbench-back")
            Text("D").font(.title2.bold())
            WorkbenchMenu(consistencyText(language, "APP-PROJECT")) {
                WorkbenchMenuAction(t("projects")) { projectsVisible = true }
                WorkbenchMenuAction(consistencyText(language, "menu.file.new")) { Task { if await model.newProject() { navigate(to: .workflow) } } }.featureHelp("MENU-FILE-NEW", language: language)
                WorkbenchMenuAction(consistencyText(language, "menu.file.open")) { Task { if await model.openProject() { navigate(to: .workflow) } } }.featureHelp("MENU-FILE-OPEN", language: language)
            } label: {
                HStack(spacing: 4) {
                    Text((entry == .quick ? quickModel.manifest?.name : canvasModel.manifest?.name) ?? t("independentDraft"))
                        .lineLimit(2)
                    Image(systemName: "chevron.down").font(.caption)
                }
            }.accessibilityIdentifier("app-project").workbenchHelp("APP-PROJECT").frame(maxWidth: 260, alignment: .leading)
            WorkbenchMenu(consistencyText(language, "APP-FILE")) {
                WorkbenchMenuAction(consistencyText(language, "menu.file.new")) { Task { if await model.newProject() { navigate(to: .workflow) } } }.featureHelp("MENU-FILE-NEW", language: language).keyboardShortcut("n")
                WorkbenchMenuAction(consistencyText(language, "menu.file.open")) { Task { if await model.openProject() { navigate(to: .workflow) } } }.featureHelp("MENU-FILE-OPEN", language: language).keyboardShortcut("o")
                let command = saveCommand
                WorkbenchMenuAction(command.title, action: command.action).featureHelp("MENU-FILE-SAVE", language: language).disabled(!command.isEnabled).keyboardShortcut("s")
                WorkbenchMenuDivider()
                WorkbenchMenuAction(consistencyText(language, "menu.file.import")) { let forCanvas = entry == .workflow; Task { await importLibraryAsset(forCanvas: forCanvas) } }.featureHelp("MENU-FILE-IMPORT", language: language)
                if entry == .workflow, let controller = canvasModel.projectSession.workflow {
                    WorkbenchMenuAction(consistencyText(language, "menu.file.export")) {
                        Task { await WorkflowHostView.chooseDestination(controller, model: canvasModel, language: language) }
                    }.featureHelp("MENU-FILE-EXPORT", language: language).disabled(controller.readOnlyReason != nil || canvasModel.isBusy || canvasModel.isChangingProject).help(controller.destinationDescription)
                } else {
                    WorkbenchMenuAction(consistencyText(language, "menu.file.export")) { compatibilityVisible = true }.featureHelp("MENU-FILE-EXPORT", language: language)
                }
                if let manifest = (entry == .quick ? quickModel.manifest : canvasModel.manifest),
                   let store = (entry == .quick ? quickModel.projectSession.currentStore : canvasModel.projectSession.currentStore) {
                    WorkbenchMenuAction(consistencyText(language, "menu.file.backups")) { filesRoute = .init(store: store, instanceID: manifest.effectiveInstanceID, assetID: nil) }.featureHelp("MENU-FILE-BACKUPS", language: language)
                }
            }.accessibilityIdentifier("app-file").workbenchHelp("APP-FILE")
            WorkbenchMenu(consistencyText(language, "APP-RESOURCES")) {
                WorkbenchMenuAction(consistencyText(language, "menu.resources.library")) { modelPickerCategory = nil; libraryVisible = true }.featureHelp("MENU-RESOURCES-LIBRARY", language: language)
                WorkbenchMenuAction(consistencyText(language, "menu.resources.models")) { library.presentManagement() }.featureHelp("MENU-RESOURCES-MODELS", language: language).keyboardShortcut("m", modifiers: [.command,.shift])
            }.accessibilityIdentifier("app-resources").workbenchHelp("APP-RESOURCES")
            if entry == .quick {
                if model.projectSession.projectQuick != nil {
                    WorkbenchPicker(t("draftLocation"), selection: Binding(get: { useProjectQuick }, set: { captureChatReading(); useProjectQuick = $0 })) {
                        WorkbenchChoice(model.manifest?.name ?? t("project"), value: true)
                        WorkbenchChoice(t("independentDraft"), value: false)
                    }.labelsHidden().frame(maxWidth: 160)
                } else if model.manifest != nil {
                    Button(t("enableProjectQuick")) { captureChatReading(); Task { await model.projectSession.enableProjectQuick(); useProjectQuick = true; navigate(to: .quick) } }
                }
            }
            Button { featureHelp.presentation = .init(featureID: nil, token: nil, context: nil) } label: { Image(systemName: "questionmark.circle") }
                .help(consistencyText(language, "help.open")).accessibilityLabel(consistencyText(language, "help.title"))
                .accessibilityIdentifier("workbench-feature-guide").disabled(!canPresentSettings)
            Spacer(minLength: 8)
            WorkbenchGlassSegments(title: t("workspaceMode"), selection: Binding(get: { entry }, set: { navigate(to: $0) }), choices: [
                (Entry.quick, consistencyText(language, "APP-MODE-QUICK")), (Entry.workflow, consistencyText(language, "APP-MODE-WORKFLOW"))])
                .frame(width: 180).accessibilityIdentifier("workbench-entry").workbenchHelp("APP-MODE")
            Button { presentSettings() } label: { Image(systemName: "gearshape").frame(width: 30,height: 30) }
                .buttonStyle(WorkbenchIconButtonStyle(diameter: 40,panel: true))
                .help(t("settings")).accessibilityLabel(t("settings"))
                .accessibilityIdentifier("workbench-settings").workbenchHelp("APP-SETTINGS").disabled(!canPresentSettings)
        }.buttonStyle(WorkbenchGlassButtonStyle()).padding(.horizontal,16).padding(.vertical,8)
    }

    public var body: some View {
        #if DEBUG
        let _ = WorkbenchCategoryUpdateProbe.workbenchBody?()
        #endif
        VStack(spacing: 0) {
            applicationToolbar
            if entry == .quick {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    let dragOwner = quick
                    let dragStore = quickModel.projectSession.currentStore
                    WorkbenchCategoryPicker(selection: quick.category, owner: ObjectIdentifier(quick), enabled: !quickOwnerIsChanging) { category in
                        guard entry == .quick, quick === dragOwner, quickModel.projectSession.currentStore === dragStore else { return }
                        selectCategory(category)
                    }.workbenchHelp("QUICK-MODALITY")
                if entry == .quick, quick.category == .text {
                    WorkbenchMenu {
                        WorkbenchPickerOptions(workflowText(language, "chat.textSurface"),
                            selection: Binding(get: { quick.textPresentation }, set: { captureChatReading(); quick.selectTextPresentation($0) })) {
                            WorkbenchChoice(workflowText(language, "chat.conversation"), value:QuickTextPresentation.chat)
                            WorkbenchChoice(workflowText(language, "chat.single"), value:QuickTextPresentation.single)
                        }
                        if quick.textPresentation == .chat {
                            WorkbenchMenuDivider()
                            WorkbenchMenuAction(chat?.isTemporary == true ? t("endTemporary") : t("temporary"), action: changeTemporaryChat)
                                .disabled(temporaryChatChanging).accessibilityIdentifier("chat-temporary-toggle")
                        }
                    } label: {
                        Label(quick.textPresentation == .single ? t("singleShort") :
                            (chat?.isTemporary == true ? t("temporary") : t("chat")),
                            systemImage: chat?.isTemporary == true ? "bubble.left.and.text.bubble.right" : "bubble.left")
                    }.fixedSize().accessibilityIdentifier("quick-text-surface")
                }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 16).padding(.bottom, 8)
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
                Group {
                    if entry == .quick {
                        if quick.category == .text, let chat {
                            VStack(spacing: 0) {
                                if quick.textPresentation == .chat {
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
                RetainedContentHost(content: WorkflowHostView(model: canvasModel, nodeTags: nodeTags, metadata: metadata, library: library, onQuickUse: useNode,
                    libraryContent: canvasLibraryContent,
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
        .focusedSceneValue(\.workbenchSave, saveCommand)
        .environment(\.workbenchHelpStore, featureHelp)
        .sheet(item: $featureHelp.presentation) { presentation in
            WorkbenchFeatureGuide(presentation: presentation, store: featureHelp)
                .environment(\.dLanguageStore, language)
        }
        .environment(\.workbenchSidebars, sidebarState)
        .environment(\.workbenchMenuContext, "workbench:\(entry.rawValue):\(ObjectIdentifier(quick)):\(canvasModel.manifest?.effectiveInstanceID.uuidString ?? "none")")
        .environment(\.openWorkbenchSettings, { section in presentSettings(section: section) })
        .workbenchTheme(paintsCanvas: false)
        .modifier(WorkbenchCanvasModifier(state: automaticQuickModel.chatDisplaySettings, stylesWindowTitlebar: true))
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
        .onChange(of: libraryVisible) { _, _ in navigationIntent = UUID() }
        .sheet(isPresented: $libraryVisible, onDismiss: finishLibraryDismissal) {
            VStack(spacing: 0) {
                if !quickModel.projectSession.explicitModelChecking.isEmpty {
                    Text(t("checkingModel"))
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                }
                libraryBrowser(compact: false, at: { CGPoint(x: 160, y: 140) })
            }
            .frame(minWidth: 820, minHeight: 540)
            .task { await refreshLibrary(checkModels: true) }
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .sheet(isPresented: $projectsVisible) {
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
            }.frame(minWidth: 640, minHeight: 420)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
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
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .sheet(isPresented: $compatibilityVisible) {
            VStack(spacing: 0) {
                HStack { Button(baselineText(language, "label.572cf45ba436")) { compatibilityVisible = false }.keyboardShortcut(.cancelAction); Text(baselineText(language, "label.6f5cabc6a134")); Spacer() }.padding()
                WorkbenchView(model: model, library: library, nodeTags: nodeTags, metadata: metadata)
            }.frame(minWidth: 960, minHeight: 650)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .sheet(isPresented: Binding(get: { library.isPresented }, set: { library.isPresented = $0 }), onDismiss: restoreLibraryIfNeeded) {
            ModelLibraryView(model: library)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }

        .sheet(isPresented: $languageVisible) {
            VStack {
                HStack { Button(baselineText(language, "label.572cf45ba436")) { languageVisible = false }.keyboardShortcut(.cancelAction); Spacer() }
                if let language { LanguageSettingsView(store: language) }
            }.padding().frame(width: 560, height: 440)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .alert(consistencyText(language, "error.incomplete"), isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil; failedAssetRoute = nil } })) {
            Button(baselineText(language, "label.f867f3417859")) { issue = nil; failedAssetRoute = nil }
            if let failedAssetRoute {
                Button(baselineText(language, "files.inspect", fallback: "查看文件位置")) {
                    issue = nil; self.failedAssetRoute = nil
                    if libraryVisible { returnToLibrary = true; pendingFilesRoute = failedAssetRoute; libraryVisible = false }
                    else { filesRoute = failedAssetRoute }
                }
            }
        } message: { Text(WorkbenchOwnedIssue.alertMessage(issue ?? "", language: language)) }
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
        .onChange(of: model.manifest?.effectiveInstanceID) { _, _ in useProjectQuick = true; model.viewers.reconcile() }
        .onChange(of: automaticQuickModel.manifest?.effectiveInstanceID) { _,_ in automaticQuickModel.viewers.reconcile() }
        .alert(workspaceText(language, "pinLegacy"),isPresented:Binding(get:{pendingLegacyPreview != nil},set:{if !$0 {pendingLegacyPreview=nil}})) {
            if let value=pendingLegacyPreview {
                Button(workspaceText(language, "pinAndView")) {
                    pendingLegacyPreview=nil;Task { await previewLibraryEntry(value,allowPin:true) }
                }
            }
            Button(workspaceText(language, "cancel"),role:.cancel) { pendingLegacyPreview=nil }
        } message: { Text(workspaceText(language, "pinExplanation")) }
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
        .sheet(item: $libraryInfo, onDismiss: restoreLibraryIfNeeded) { value in
            VStack(alignment: .leading, spacing: 14) { HStack { Button(baselineText(language, "label.572cf45ba436")) { libraryInfo = nil }; Text(value.item.title).font(.title2); Spacer() }
                Text(value.item.detail); ForEach(value.facts, id: \.self) { Text($0).textSelection(.enabled) }
                if case .unavailable = value.selection { Button(baselineText(language, "label.32d818ead29f")) { returnToLibrary = false; libraryInfo = nil; libraryVisible = false; compatibilityVisible = true } }
            }.padding(24).frame(minWidth: 550, minHeight: 280)
            .workbenchPresentation(state: automaticQuickModel.chatDisplaySettings)
        }
        .environment(\.metadataEditorLifecycle, MetadataEditorLifecycle(begin: model.beginEditing, end: model.endEditing))
        .focusedSceneValue(\.workbenchGeneration, WorkbenchGenerationCommand(title: t("quickAction"), isEnabled: quickCommandEnabled,
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
        case .models: library.presentManagement()
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
        AnyView(libraryBrowser(compact: true, at: point, onBack: close, canvasMode: mode))
    }

    @ViewBuilder private func libraryBrowser(compact: Bool, at point: @escaping () -> CGPoint?, onBack: (() -> Void)? = nil, canvasMode: WorkflowCanvasLibraryMode? = nil) -> some View {
        if let metadata {
            let sourceEntries: [SharedLibraryBrowserEntry] = {
                if let category = canvasMode?.resourceCategory {
                    return workspaceAssetEntries.filter { $0.item.kind == .asset && category.contains($0.item.contentKind) }
                }
                _ = entries // Refresh the complete semantic inputs before selecting.
                return libraryProjection.selection(canvasMode: canvasMode, family: compact ? nil : modelPickerCategory)
            }()
            SharedLibraryBrowser(entries: sourceEntries, store: metadata, compact: compact, allowsImport: canvasMode == nil || canvasMode?.resourceCategory != nil, canvasMode:canvasMode,
                state: canvasMode.flatMap { canvasLibraryStates[$0] } ?? (compact ? compactLibraryState : fullLibraryState),
                onUse: useLibraryEntry, onAdd: { value in
                    guard let insertionPoint = point() else { return }
                    beginAddingLibraryEntry(value, at: insertionPoint)
                },
                onPreview: { value in Task { await previewLibraryEntry(value) } },
                onExternalCopy: { value in Task { await openExternalLibraryCopy(value) } }, readPreview: readLibraryPreview,
                onLocation: { value in Task { await showAssetLocation(value) } },
                onPrepare: { value in Task { await prepareModel(value) } },
                onImport: { Task { await importLibraryAsset(forCanvas: canvasMode != nil) } }, onClose: { if let onBack { onBack() } else { libraryVisible = false } }, tagValidation: libraryTagValidation,
                queryContext: libraryQueryContext(forCanvas: canvasMode != nil),
                annotationSave: libraryAnnotationSave)
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
        let saved=entries.filter { $0.item.kind == .asset }
        guard let controller=canvasModel.projectSession.workflow else { return saved }
        let references=Set(saved.compactMap { $0.metadataSnapshot?.record?.reference })
        let projected=WorkflowLibraryValue.entries(controller,language:language,excludingSaved:references,library:metadata,indexedSaved:saved.compactMap(\.metadataSnapshot))
        return saved+projected
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
            guard [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38].contains(operation),
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
    private func previewLibraryEntry(_ value: SharedLibraryBrowserEntry, allowPin:Bool=false) async {
        if let runtime=value.runtimeValue {
            guard let controller=canvasModel.projectSession.workflow,runtime.isCurrent(in:controller) else { issue=t("runtimeUnavailable");return }
            do { canvasModel.viewers.library=metadata;try canvasModel.viewers.open(.init(title:value.item.title,subtitle:value.item.detail,value:runtime.value,call:runtime.call,port:runtime.port,usesCallTitle: true),model:canvasModel,language:language) }
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
            try owningModel.viewers.open(.init(title:value.item.title, subtitle:value.item.detail, resource:content.token), model:owningModel, language:language)
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
        guard case .operation(let id, _) = value.selection, let kind = WorkflowRegistry.standard.operation(id)?.definition.modelKind else { presentLibraryDestination(.info(value)); return }
        if kind == .pitch { await refreshLibrary(checkModels: true); presentLibraryDestination(.info(value)); return }
        if [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38, WorkflowModelRoutes.fluxDev,
            WorkflowModelRoutes.ace, "d.image.generate", "d.music.generate"].contains(id) {
            presentLibraryDestination(.models); return
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
    private func importLibraryAsset(forCanvas: Bool = false) async {
        let owner = forCanvas ? canvasModel.projectSession : quickModel.projectSession
        let destination = forCanvas ? owner.currentStore : quick.store
        let controller = forCanvas ? owner.workflow : nil
        guard let destination, !forCanvas || controller?.canEditCanvas == true else { return }
        guard let (url, mode) = await NativeAssetImportPanel.choose(language: language) else { return }
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            if forCanvas {
                guard let controller, owner.currentStore === destination, owner.workflow === controller,
                      controller.canEditCanvas else { throw WorkflowIssue("目标项目已改变或当前不可编辑，未导入素材。") }
                await controller.importLibraryFile(url, mode: mode)
            } else { _ = try await destination.importWorkflowMediaFile(at: url, mode: mode) }
            await refreshLibrary(checkModels: false)
        }
        catch { issue = error.localizedDescription }
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

/// Preserve display names, including dotted version labels. Only avoid adding
/// a format suffix that is already present (or has an equivalent UTType).
func suggestedExternalCopyName(_ name: String, suffix: String) -> String {
    let existing = (name as NSString).pathExtension
    if existing.caseInsensitiveCompare(suffix) == .orderedSame { return name }
    if let current = UTType(filenameExtension: existing), let expected = UTType(filenameExtension: suffix),
       current == expected { return name }
    return name + "." + suffix
}
