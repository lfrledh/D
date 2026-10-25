import DInference
import DWorkbench
import SwiftUI

/// The workbench presents saved project values and application actions, never model objects.
public struct WorkbenchView: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Bindable private var model: WorkbenchModel
    private let library: ModelLibraryModel?
    private let nodeTags: ModelNodeTagStore
    private let metadata: SharedLibraryStore?
    @State private var nodePresentation = ModelNodePresentation()
    private var layoutProbe: ((String, CGRect) -> Void)?
    @State private var audioRangeState = AudioCreationRangeState()
    private var pane: WorkspacePane {
        get { nodePresentation.pane }
        nonmutating set { nodePresentation.selectPane(newValue) }
    }
    private var selectedNodeID: String? {
        get { nodePresentation.selectedNodeID }
        nonmutating set { nodePresentation.selectNode(newValue) }
    }
    @Environment(\.dLanguageStore) private var language
    @State private var languageSettingsVisible = false
    private func label(_ key: String, _ fallback: String) -> String { language?.text(key, fallback: fallback) ?? fallback }
    @State private var workflowVisible = false
    @State private var showTasks = false
    @State private var showingPitchAnalysis = false
    @State private var expandTasks = true
    @State private var namingContext: DocumentNameContext?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: WorkbenchModel, library: ModelLibraryModel? = nil, nodeTags: ModelNodeTagStore? = nil, metadata: SharedLibraryStore? = nil) {
        self.model = model
        self.library = library
        self.nodeTags = nodeTags ?? ModelNodeTagStore()
        self.metadata = metadata
    }

    /// Inject the actual presentation owner for hosting regressions; no alternate command path.
    func withNodePresentation(_ presentation: ModelNodePresentation) -> Self {
        var copy = self
        copy._nodePresentation = State(initialValue: presentation)
        return copy
    }

    /// Internal rendered-geometry observation; no foreground or accessibility claim.
    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    public var body: some View {
        Group {
            if model.manifest != nil {
                VStack(spacing: 0) {
                    HStack {
                        Text(model.manifest?.name ?? "D").font(.headline)
                        Spacer()
                        WorkbenchGlassSegments(title: label("workbench.view", "工作视图"), selection: $workflowVisible,
                            choices: [(true, label("workbench.canvas", "流程画布")), (false, label("workbench.creation", "创作与资料"))], owner: AnyHashable(model.manifest?.effectiveInstanceID))
                            .frame(maxWidth: 300)
                        Button(label("workbench.projects", "返回项目")) { Task { await model.closeProject() } }
                    }.padding(10).background(.bar)
                    Divider()
                    if workflowVisible {
                        WorkflowHostView(model: model, nodeTags: nodeTags, metadata: metadata, library: library,
                            acceptsLegacyAsset: { projectID, assetID in
                                guard let manifest = model.manifest,
                                      manifest.id == projectID,
                                      manifest.effectiveInstanceID == projectID else { return false }
                                return manifest.assets.contains(where: { $0.id == assetID })
                            })
                    } else { projectWorkbench }
                }
            } else {
                ProjectChooserView(recentProjects: model.recentProjects, isBusy: model.isChangingProject,
                    onNew: { Task { await model.newProject() } },
                    onOpen: { Task { await model.openProject() } },
                    onRecent: { id in Task { await model.openRecentProject(id: id) } },
                    onModels: { library?.presentManagement() })
            }
        }
        .toolbar {
            if language != nil {
                Button { languageSettingsVisible = true } label: {
                    Label(label("language.settings", "显示语言"), systemImage: "globe")
                }.accessibilityIdentifier("display-language-settings")
            }
        }
        .workbenchSheet(isPresented: $languageSettingsVisible, title: workflowText(legacyLanguage, "childPanel.name.language")) {
            if let language {
                VStack(spacing: 0) {
                    LanguageSettingsView(store: language)
                    HStack { Spacer(); Button(label("common.done", "完成")) { languageSettingsVisible = false }.keyboardShortcut(.defaultAction) }
                        .padding()
                }.frame(minWidth: 420, idealWidth: 540, minHeight: 380)
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .onChange(of: model.projectURL) { _, _ in
            model.invalidateComparison(); nodePresentation.projectChanged()
        }
        .onChange(of: model.creatorMode) { _, _ in
            nodePresentation.modalityChanged()
        }
        .environment(\.metadataEditorLifecycle, MetadataEditorLifecycle(begin: model.beginEditing, end: model.endEditing))
        .focusedSceneValue(\.workbenchGeneration, visibleGenerationCommand)
        .focusedSceneValue(\.workbenchSave, WorkbenchGenerationCommand(
            title: language?.text("command.text.save", fallback: "保存文稿") ?? "Save Document",
            isEnabled: model.creatorMode == .text && model.projectSession.text != nil && !model.isChangingProject,
            action: { let owner = model.projectSession; Task { guard model.projectSession === owner else { return }; await owner.saveText() } }))
        .disabled(model.isChangingProject)
        .overlay {
            if model.isChangingProject {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.1")).font(.callout)
                }
                .padding(24)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.10), radius: 20, y: 8)
            }
        }
        .alert(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.2"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.3"), role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .workbenchSheet(isPresented: Binding(
            get: { library?.isPresented ?? false },
            set: { library?.isPresented = $0 }
        ), title: workflowText(legacyLanguage, library?.workspace == "downloads" ? "modelManagement.downloadTitle" : "modelManagement.modelTitle"), size: .init(download: library?.workspace == "downloads")) {
            if let library {
                ModelLibraryView(model: library)
            }
        }
    }

    private var visibleGenerationEnabled: Bool {
        guard pane != .nodes, model.canRunVisibleGeneration else { return false }
        guard model.creatorMode == .audio else { return true }
        guard let draft = model.projectSession.audioCreationDraft,
              audioRangeState.contextID == model.projectSession.audioCreationContextID else { return false }
        return AudioCreationButtonHandler.canSubmit(draft, source: model.projectSession.audioCreationSource,
            hostAllowsGeneration: model.projectSession.canGenerateAudioCreation,
            hasPendingRangeInput: draft.operation == .inpaint && audioRangeState.pendingMessage != nil)
    }

    private var visibleGenerationCommand: WorkbenchGenerationCommand {
        if workflowVisible {
            WorkbenchGenerationCommand(title: workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.4"), isEnabled: false, action: {})
        } else {
            nodePresentation.generationCommand(model: model, enabled: { visibleGenerationEnabled })
        }
    }

    private var projectWorkbench: some View {
        ProjectWorkspaceShell(projectName: model.manifest?.name ?? "D", mode: model.creatorMode,
            availableModes: model.availableCreatorModes,
            hasInspector: pane != .nodes && model.presentedDocument != nil && (model.creatorMode != .audio || model.projectSession.audioCreationDraft != nil),
            taskCount: model.projectSession.activeJobIDs.count + (model.projectSession.isTextWorking ? 1 : 0),
            onMode: { mode in Task { await model.switchCreatorMode(mode) } },
            onBack: { Task { await model.closeProject() } },
            onTasks: { showTasks = true }, onModels: { library?.presentManagement() }, sidebarWidth: 264) {
                workspaceSidebar
            } editor: {
                workspaceEditor
            } inspector: {
                switch model.creatorMode {
                case .image: GenerationInspector(model: model, library: library)
                case .text: textWorkspace(presentation: .parameters)
                case .audio: audioWorkspace(presentation: .parameters)
                case .video: videoWorkspace(presentation: .parameters)
                }
            }
        .observingLayout { layoutProbe?($0, $1) }
        .workbenchPopover(isPresented: $showTasks, title: workflowText(legacyLanguage, "childPanel.name.tasks")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.5")).font(.headline)
                if model.manifest?.jobs.isEmpty == true { Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.6")).foregroundStyle(.secondary) }
                WorkbenchTasks(model: model, isExpanded: $expandTasks)
                Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.7")) { Task { await model.recoverArtifacts() } }.disabled(model.isBusy)
            }.padding(16).frame(width: 600)
        }
        .workbenchSheet(item: $namingContext, title: workflowText(legacyLanguage, "childPanel.name.metadata"), onDismiss: { model.endEditing() }) { context in
            DocumentNameEditor(model: model, context: context)
        }
    }

    private var workspaceSidebar: some View {
        VStack(spacing: 8) {
            WorkbenchGlassSegments(title: label("workbench.view", "工作视图"), selection: Binding(get: { pane }, set: { pane = $0 }),
                choices: WorkspacePane.allCases.map { ($0, $0.title) },
                identifiers: WorkspacePane.allCases.map { "workspace-\($0.rawValue)" }, owner: AnyHashable(model.manifest?.effectiveInstanceID))
                .padding(.horizontal, 12).padding(.top, 8)

            if pane == .nodes {
                ModelNodeList(entries: visibleNodes, selectedID: selectedNodeID, onSelect: { selectedNodeID = $0 })
            } else if pane == .assets, let manifest = model.manifest {
                ProjectResourceBrowser(manifest: manifest, mode: model.creatorMode,
                    availableModes: model.availableCreatorModes,
                    assetURL: { model.assetURLs[$0] },
                    onOpenDocument: { id in Task { await model.switchDocument(to: id) } })
            } else {
                ModalityDocumentList(documents: model.documents, mode: model.creatorMode,
                    selectedDocumentID: model.presentedDocument?.id,
                    onSelect: { id in Task { await model.switchDocument(to: id) } }, onCreate: createDocument)
                if let document = model.presentedDocument {
                    Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.8")) {
                        model.beginEditing()
                        namingContext = DocumentNameContext(documentID: document.id, name: document.name)
                    }
                    .accessibilityIdentifier("rename-document-\(document.id.uuidString)")
                    .padding(.horizontal, 12).padding(.bottom, 16)
                }
                if model.creatorMode == .audio, let audio = model.projectSession.audio {
                    AudioCaptureEntry(model: model, audio: audio)
                        .frame(maxHeight: 240)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleNodes: [ModelNodeDescriptor] {
        ModelNodeCatalog.entries.filter { $0.modality == model.creatorMode }
    }

    private func createDocument() {
        if model.creatorMode == .image {
            model.beginEditing()
            namingContext = DocumentNameContext(documentID: nil, name: "新创作")
        } else { Task { await model.createVisibleDocument() } }
    }

    @ViewBuilder private var workspaceEditor: some View {
        if pane == .nodes {
            if let node = visibleNodes.first(where: { $0.id == selectedNodeID }) {
                let legacy = SharedLibraryTagTarget.legacy(nodeTags.readState(for: node.id))
                ModelNodeDetail(node: node, tagState: nodeTags.readState(for: node.id),
                    onTagsChange: { _ in workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.9") },
                    organizationTags: AnyView(SharedLibraryTagSection(store: metadata,
                        target: .init(key: node.id, title: node.title, legacy: legacy.names, legacyFailure: legacy.failure),
                        validateTarget: nodePresentation.tagValidation(node: node, model: model))))
                .id(node.id)
            } else {
                ContentUnavailableView(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.10"), systemImage: "square.stack.3d.up",
                    description: Text(consistencyText(legacyLanguage, "copy.WorkbenchView.0", arguments: ["v0": String(describing: consistencyText(legacyLanguage, "mode." + model.creatorMode.rawValue))])))
            }
        } else if model.presentedDocument == nil {
            ContentUnavailableView {
                Label(consistencyText(legacyLanguage, "copy.WorkbenchView.1", arguments: ["v0": String(describing: consistencyText(legacyLanguage, "mode." + model.creatorMode.rawValue))]), systemImage: model.creatorMode.symbol)
            } description: {
                Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.11"))
            } actions: {
                Button(consistencyText(legacyLanguage, "newCreation." + model.creatorMode.rawValue), action: createDocument).buttonStyle(WorkbenchPrimaryButtonStyle())
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(model.presentedDocument?.name ?? "").font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    if model.creatorMode == .image {
                        RecipeHandoffButton(model: model)
                        Button {
                            guard let job = model.selectedJob else { return }
                            Task { await model.copySettings(from: job.id) }
                        } label: { Image(systemName: "arrow.branch") }
                        .disabled(model.selectedJob == nil).help(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.12"))
                        .accessibilityLabel(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.12")).accessibilityIdentifier("copy-settings")
                        .audioMeasured("copy-settings", probe: layoutProbe)
                        Button { Task { await model.exportSelected() } } label: { Image(systemName: "square.and.arrow.up") }
                            .disabled(model.selectedAsset == nil).help(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.13"))
                            .accessibilityLabel(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.14")).accessibilityIdentifier("export-artwork")
                            .audioMeasured("export-artwork", probe: layoutProbe)
                    }
                }.padding(12)
                Divider()
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.creatorMode == .image && !model.visibleAssets.isEmpty {
                    Divider()
                    ImageCandidateTray(model: model).frame(height: 130)
                }
            }
        }
    }

    @ViewBuilder private var canvas: some View {
        if model.creatorMode == .video, !model.showingAllArtworks, model.presentedDocument != nil {
            videoWorkspace(presentation: .content)
        } else if !model.showingAllArtworks, model.activeDocument?.audioCreation != nil,
           model.projectSession.audioCreationDraft != nil {
            audioWorkspace(presentation: .content)
        } else if !model.showingAllArtworks, model.activeDocument?.kind == .audio,
           let audio = model.projectSession.audio {
            VStack(spacing: 0) {
                if let assetID = model.activeDocument?.audioDraft?.assetID {
                    HStack {
                        Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.15"), systemImage: "waveform.badge.plus") {
                            Task { await model.createAudioCreation(sourceAssetID: assetID) }
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("audio-create-from-original")
                        Spacer()
                    }.padding(.horizontal, 20).padding(.top, 12)
                }
                if model.projectSession.hasPitchEngine || model.presentedDocument?.pitchAnalysis != nil {
                    WorkbenchGlassSegments(title: workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.16"), selection: $showingPitchAnalysis,
                        choices: [(false, workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.17")), (true, workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.18"))], owner: AnyHashable(model.presentedDocument?.id)).padding(.horizontal, 20)
                        .accessibilityIdentifier("audio-analysis-mode")
                }
                if showingPitchAnalysis && (model.projectSession.hasPitchEngine || model.presentedDocument?.pitchAnalysis != nil) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(audio.document?.selectedClipID == nil ? workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.19") : workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.20"))
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                        if model.projectSession.pitchResult == nil, model.projectSession.pitchResultAssetID != nil,
                           !model.projectSession.pitchHasSaved {
                            Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.21")) { Task { await model.projectSession.decidePitchAnalysis(accept: false) } }
                                .disabled(model.projectSession.pitchIsBusy).padding(.horizontal, 20)
                                .accessibilityIdentifier("pitch-reject-unreadable")
                        }
                        PitchAnalysisView(result: model.projectSession.pitchResult,
                            isBusy: model.projectSession.pitchIsBusy,
                            isStale: model.projectSession.pitchIsStale,
                            status: model.projectSession.pitchStatus,
                            hasSaved: model.projectSession.pitchHasSaved,
                            canAnalyze: model.projectSession.canAnalyzePitch,
                            onAnalyze: { Task { await model.projectSession.analyzePitch() } },
                            onCancel: { Task { await model.projectSession.cancelPitchAnalysis() } },
                            onSave: { Task { await model.projectSession.decidePitchAnalysis(accept: true) } },
                            onReject: { Task { await model.projectSession.decidePitchAnalysis(accept: false) } },
                            onExport: { Task { await model.exportPitchAnalysis() } })
                    }
                } else {
                    AudioWorkbenchView(controller: audio,
                                   recordingEnabled: model.audioRecordingEnabled,
                                   navigationInProgress: model.projectSession.isChangingProject,
                                   actions: audioActions)
                    .observingLayout { id, rectangle in layoutProbe?(id, rectangle) }
                    .id(audio.contextID)
                }
                Color.clear.frame(height: 0)
                    .task(id: model.presentedDocument?.pitchAnalysis?.selectedAssetID) {
                        await model.projectSession.refreshPitchAnalysis()
                    }
            }
        } else if !model.showingAllArtworks, model.projectSession.text != nil {
            textWorkspace(presentation: .editor)
        } else if model.isComparing {
            ArtworkComparison(model: model)
        } else if let asset = model.selectedAsset, let url = model.assetURLs[asset.id] {
            ArtworkCanvas(url: url, label: workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.22"))
        } else if model.selectedAsset != nil {
            ContentUnavailableView(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.23"), systemImage: "externaldrive.badge.exclamationmark",
                description: Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.24")))
        } else {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                ContentUnavailableView {
                    Label(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.25"), systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.26"))
                }
            }
        }
    }

    @ViewBuilder private func videoWorkspace(presentation: VideoCreationPresentation) -> some View {
        if let document = model.presentedDocument, let draft = model.projectSession.videoCreationDraft {
            let session = model.projectSession, context = session.videoCreationContextID
            let epoch = session.navigationEpoch
            let jobID = session.documentJobs.last(where: { session.activeJobIDs.contains($0.id) })?.id
            VideoCreationView(draft: Binding(
                get: { session.videoCreationDraft ?? draft },
                set: { session.updateVideoCreationDraft($0, contextID: context, documentID: document.id, navigationEpoch: epoch) }),
                candidates: session.videoCreationCandidates,
                selectedAssetID: document.selectedAssetID, adoptedAssetID: document.adoptedAssetID,
                modelStatus: session.videoModelStatus, canGenerate: session.canGenerateVideoCreation,
                isBusy: session.isBusy || session.isRegisteringVideoModel || model.isChangingProject,
                progress: jobID.flatMap { session.progress[$0] },
                status: jobID.flatMap { session.phaseCodes[$0].map { workspaceText(legacyLanguage, "phase." + $0) } ?? session.phases[$0] } ?? session.videoCreationSaveStatus,
                previewURL: session.videoPreviewURL, previewIdentity: session.videoPreviewIdentity,
                defaultMemoryBudgetBytes: session.defaultMemoryBudgetBytes,
                actions: model.videoCreationActions(contextID: context, documentID: document.id))
                .presenting(presentation).id(document.id)
        }
    }

    @ViewBuilder private func audioWorkspace(presentation: AudioCreationPresentation) -> some View {
        if let document = model.presentedDocument, let draft = model.projectSession.audioCreationDraft {
            let session = model.projectSession
            let context = session.audioCreationContextID
            let jobID = session.documentJobs.last(where: { session.activeJobIDs.contains($0.id) })?.id
            AudioCreationView(draft: Binding(
                get: { session.audioCreationDraft ?? draft },
                set: { session.updateAudioCreationDraft($0, contextID: context, documentID: document.id) }),
                source: session.audioCreationSource, candidates: session.audioCreationCandidates,
                selectedAssetID: document.selectedAssetID, adoptedAssetID: document.adoptedAssetID,
                modelStatus: session.audioModelStatus, canGenerate: session.canGenerateAudioCreation,
                isBusy: session.isBusy || session.isRegisteringAudioModel,
                progress: jobID.flatMap { session.progress[$0] },
                status: jobID.flatMap { session.phaseCodes[$0].map { workspaceText(legacyLanguage, "phase." + $0) } ?? session.phases[$0] } ?? session.audioCreationSaveStatus,
                transport: session.audioCreationTransport,
                actions: model.audioCreationActions(contextID: context, documentID: document.id))
                .presenting(presentation, rangeState: audioRangeState, contextID: context)
                .supportingMusic(session.musicCreationAvailable)
                .capabilitySummary(session.audioCreationDraft?.profile == .conditionedMusic
                    ? session.musicCapability : session.audioCapability)
                .id(document.id)
        }
    }

    @ViewBuilder private func textWorkspace(presentation: TextWorkbenchPresentation) -> some View {
        if let text = model.projectSession.text {
            let project = model.projectSession
            let id = text.editor.document.id
            let epoch = project.navigationEpoch
            VStack(spacing: 0) {
                if project.textSourcesEnabled && presentation != .parameters {
                    WorkbenchGlassSegments(title: workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.27"), selection: $model.showingTextSources,
                        choices: [(false, workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.28")), (true, workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.29"))], owner: AnyHashable(model.presentedDocument?.id)).padding(8)
                }
                if model.showingTextSources && presentation != .parameters, let sources = project.textSources {
                    HStack {
                        Text(project.textModelStatus).font(.caption)
                        Spacer()
                        Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.30")) { Task { await model.chooseTextModel() } }.buttonStyle(WorkbenchGlassButtonStyle())
                            .disabled(project.isBusy || project.isRegisteringTextModel)
                    }.padding(8)
                    if let pending = sources.unsavedCompletedRecord {
                        Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.31") + pending.answer)
                            .font(.caption).textSelection(.enabled).lineLimit(6).padding(8)
                    }
                    TextSourcesView(notebook: sources.notebook, partialAnswer: sources.partialAnswer,
                        isRunning: project.isTextWorking, isCancelling: sources.isCancelling,
                        isSaving: sources.isSaving, canAsk: project.canAskTextSources, canUndo: sources.canUndo,
                        errorMessage: sources.errorMessage,
                        canAccept: { sources.canAccept($0) && !project.isBusy }, citationSummary: sources.citationSummary,
                        actions: .init(
                            importSource: { Task { await model.importTextSource(documentID: id, epoch: epoch) } },
                            removeSource: { if project.navigationEpoch == epoch { sources.removeSource(id: $0) } },
                            useExcerpt: { source, range in if project.navigationEpoch == epoch { sources.useExcerpt(sourceID: source, range: range) } },
                            changeQuestion: { if project.navigationEpoch == epoch { sources.changeQuestion($0) } },
                            ask: { Task { if project.navigationEpoch == epoch { await project.askTextSources() } } },
                            cancel: { Task { if project.navigationEpoch == epoch { await project.cancelTextRewrite() } } },
                            accept: { record in Task { if project.navigationEpoch == epoch { await project.acceptTextSources(id: record) } } },
                            reject: { record in Task { if project.navigationEpoch == epoch { await sources.reject(id: record) } } },
                            undo: { Task { if project.navigationEpoch == epoch { await project.undoTextSources() } } },
                            save: { Task { if project.navigationEpoch == epoch { await project.saveText() } } }))
                    .id(id)
                } else {
                if !model.showingTextSources && project.isTextWorking && !text.editor.isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.32"))
                        Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.33")) { Task { await project.cancelTextRewrite() } }
                    }.padding(8)
                }
                TextWorkbenchView(session: text.editor, selection: text.selection,
                    instruction: Binding(get: { text.instruction }, set: { text.instruction = $0 }),
                    modelStatus: project.textModelStatus, canGenerate: project.canRewriteText,
                    canAccept: text.canAccept, canUndo: text.canUndo,
                    isSaving: text.isSaving, saveStatus: text.saveStatus,
                    onEdit: { if project.navigationEpoch == epoch { project.editText($0, documentID: id) } },
                    onSelection: { if project.navigationEpoch == epoch { project.selectText($0, documentID: id) } },
                    onGenerate: { Task { await project.rewriteText() } },
                    onCancel: { Task { await project.cancelTextRewrite() } },
                    onAccept: { project.acceptTextRewrite() }, onReject: { text.reject() }, onUndo: { project.undoTextRewrite() },
                    onSave: { Task { await project.saveText() } },
                    onChooseModel: { Task { await model.chooseTextModel() } })
                    .presenting(presentation)
                    .questionParameters(model.showingTextSources)
                    .generationControls(capability: project.textCapability,
                        recommendation: model.executionRecommendations,
                        configurationError: project.textConfigurationError,
                        onChange: { value in
                            guard project.navigationEpoch == epoch else { return }
                            project.updateTextGenerationSettings(value, documentID: id)
                        }, onEditingError: { error in
                            guard project.navigationEpoch == epoch else { return }
                            project.setParameterEditingError(error, for: .text, documentID: id)
                        })
                .id(id)
                .disabled(project.textSources?.isSaving == true)
                }
            }
        }
    }

    private var audioActions: AudioWorkbenchProductionActions {
        let contextID = model.projectSession.audio?.contextID
        let documentID = model.activeDocumentID
        return AudioWorkbenchProductionActions(
            importOriginal: contextID.map { model.audioImportAction(contextID: $0, documentID: documentID) } ?? {},
            startRecording: { Task { await model.startAudioRecording() } },
            finishRecording: { Task { await model.finishAudioRecording() } },
            refreshInspection: { contextID, documentID in
                await model.projectSession.refreshActiveAudioInspection(
                    contextID: contextID, documentID: documentID
                )
            },
            saveNote: { contextID, documentID in
                await model.projectSession.saveAudioNote(
                    contextID: contextID, documentID: documentID
                )
            },
            addClip: { contextID, documentID in
                await model.projectSession.addAudioClip(
                    contextID: contextID, documentID: documentID
                )
            },
            discardInput: { contextID, documentID in
                model.projectSession.discardAudioEditorInput(
                    contextID: contextID, documentID: documentID
                )
            },
            selectClip: { id, contextID, documentID in
                if let id {
                    await model.projectSession.selectAudioClip(
                        id: id, contextID: contextID, documentID: documentID
                    )
                } else {
                    await model.projectSession.selectFullAudio(
                        contextID: contextID, documentID: documentID
                    )
                }
            },
            prepareRange: { range, contextID, documentID in
                await model.projectSession.prepareAudioPlayback(
                    range: range, contextID: contextID, documentID: documentID
                )
            },
            exportOriginal: { contextID, documentID in
                Task {
                    await model.exportOriginalAudio(
                        contextID: contextID, documentID: documentID
                    )
                }
            },
            exportSavedClip: { id, contextID, documentID in
                Task {
                    await model.exportSavedAudioClip(
                        id: id, contextID: contextID, documentID: documentID
                    )
                }
            },
            exportRange: { range, revision, contextID, documentID in
                Task {
                    await model.exportAudioRange(
                        range, editorRevision: revision,
                        contextID: contextID, documentID: documentID
                    )
                }
            },
            retryCapture: { id, contextID, renderDocumentID in
                Task {
                    await model.retryPendingAudioCapture(
                        id: id, contextID: contextID,
                        renderDocumentID: renderDocumentID
                    )
                }
            },
            keepCapture: { id, contextID, renderDocumentID in
                model.keepPendingAudioCaptureForRecovery(
                    id: id, contextID: contextID,
                    renderDocumentID: renderDocumentID
                )
            }
        )
    }
}

private struct AudioCaptureEntry: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Bindable var model: WorkbenchModel
    let audio: ProjectAudioController
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 8) { entries }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 16) } }
    @ViewBuilder private var entries: some View {
        let contextID = audio.contextID
        let renderDocumentID = model.activeDocumentID
        Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.34")).font(.caption.weight(.semibold))
        Button(action: model.audioImportAction(contextID: contextID, documentID: renderDocumentID)) {
            Label(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.35"), systemImage: "waveform.badge.plus")
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .disabled(model.isChangingProject || audio.isBusy)
        .accessibilityIdentifier("sidebar-audio-import")
        if audio.transport.state == .recording || audio.transport.state == .requestingPermission {
            Button {
                Task { await model.finishAudioRecording() }
            } label: {
                Label(audio.transport.state == .recording ? workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.36") : workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.37"),
                      systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .accessibilityIdentifier("sidebar-audio-record-finish")
        } else {
            Button {
                Task { await model.startAudioRecording() }
            } label: {
                Label(model.audioRecordingEnabled ? workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.38") : workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.39"),
                      systemImage: model.audioRecordingEnabled ? "mic.fill" : "mic.slash")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .disabled(!model.audioRecordingEnabled)
            .accessibilityIdentifier("sidebar-audio-record-start")
            Text(model.audioRecordingEnabled
                 ? workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.40")
                 : workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.41"))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
        }
        ForEach(audio.pendingCaptures) { capture in
            VStack(alignment: .leading, spacing: 4) {
                Text(consistencyText(legacyLanguage, "copy.WorkbenchView.2", arguments: ["v0": String(describing: capture.name)])).font(.caption).lineLimit(1)
                HStack {
                    Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.42")) {
                        Task {
                            await model.retryPendingAudioCapture(
                                id: capture.id, contextID: contextID,
                                renderDocumentID: renderDocumentID
                            )
                        }
                    }
                    Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.43")) {
                        model.keepPendingAudioCaptureForRecovery(
                            id: capture.id, contextID: contextID,
                            renderDocumentID: renderDocumentID
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .accessibilityIdentifier("sidebar-audio-recovery-\(capture.id.uuidString)")
        }
    }

}

private struct ImageCandidateTray: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Bindable var model: WorkbenchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.44")).font(.caption.weight(.semibold))
                Spacer()
                Button(consistencyText(legacyLanguage, "copy.WorkbenchView.3", arguments: ["v0": String(describing: model.comparisonSelection.count)])) { model.beginComparison() }
                    .disabled(model.comparisonSelection.count != 2)
                    .accessibilityIdentifier("compare-artworks")
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) { ForEach(model.visibleAssets) { asset in candidateRow(asset).frame(width: 240) } }
            }.accessibilityIdentifier("artwork-list")
        }.padding(10)
    }
    private func candidateRow(_ asset: ProjectAsset) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.selectAsset(asset.id) }
            } label: {
                HStack(spacing: 8) {
                    ArtworkThumbnail(url: model.assetURLs[asset.id])
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.name).font(.callout.weight(model.selectedAssetID == asset.id ? .semibold : .regular))
                            .lineLimit(2)
                        HStack(spacing: 4) {
                            if asset.isFavorite { Image(systemName: "star.fill").accessibilityLabel(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.45")) }
                            if model.documents.contains(where: { $0.adoptedAssetID == asset.id }) {
                                Label(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.46"), systemImage: "checkmark.seal.fill")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .disabled(model.isComparing)
            .accessibilityLabel(asset.name)
            .accessibilityIdentifier("artwork-\(asset.id.uuidString)")
            .accessibilityAddTraits(model.selectedAssetID == asset.id ? .isSelected : [])
            Button {
                model.toggleComparisonCandidate(asset.id)
            } label: {
                Image(systemName: model.comparisonSelection.contains(asset.id) ? "checkmark.circle.fill" : "circle")
            }
            .disabled(!model.comparisonSelection.contains(asset.id) && model.comparisonSelection.count == 2)
            .help(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.47"))
            .accessibilityLabel(consistencyText(legacyLanguage, "copy.WorkbenchView.4", arguments: ["v0": String(describing: asset.name)]))
            .accessibilityValue(model.comparisonSelection.contains(asset.id) ? workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.48") : workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.49"))
            .accessibilityIdentifier("compare-select-\(asset.id.uuidString)")
        }
        .padding(8)
        .background(model.selectedAssetID == asset.id ? Color.accentColor.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
    }
}

/// One immutable presentation value prevents the sheet from capturing mismatched
/// mode/name state when it is first presented.
private struct DocumentNameContext: Identifiable {
    let id = UUID()
    let documentID: UUID?
    let name: String
    var title: String { documentID == nil ? "新建创作" : "重命名创作" }
}

private struct DocumentNameEditor: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Bindable var model: WorkbenchModel
    let context: DocumentNameContext
    @State private var name: String
    @State private var saving = false
    @State private var saveError: String?
    @WorkbenchDismiss private var dismiss

    init(model: WorkbenchModel, context: DocumentNameContext) {
        self.model = model
        self.context = context
        _name = State(initialValue: context.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(context.title).font(.headline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(context.title)
                .accessibilityIdentifier("document-name-title")
            TextField(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.52"), text: $name)
                .textFieldStyle(WorkbenchGlassTextFieldStyle())
                .accessibilityIdentifier("document-name")
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            if model.editorCloseAttempted {
                Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.53"))
                    .font(.caption).accessibilityIdentifier("pending-editor-close")
            }
            HStack {
                Spacer()
                Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.33"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.54")) {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await saveDraft(); $dismiss() }
                        catch { saveError = error.localizedDescription }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("save-document-name")
            }
        }.padding(24).frame(width: 320)
            .disabled(saving).interactiveDismissDisabled()
            .workbenchCloseProtection(isDirty: name != context.name, isSaving: saving, save: { try await saveDraft() })
    }
    private func saveDraft() async throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousCount = model.documents.count
        if let id = context.documentID { await model.renameDocument(id: id, name: value) }
        else { await model.createDocument(name: value) }
        let saved = context.documentID.map { identifier in model.documents.contains { $0.id == identifier && $0.name == value } }
            ?? (model.documents.count > previousCount && model.activeDocument?.name == value)
        guard saved else { throw WorkflowIssue(model.errorMessage ?? workflowText(legacyLanguage, "consistency.legacy.WorkbenchView.55")) }
    }

}
