import DInference
import DWorkbench
import SwiftUI

/// Existing project documents and their native editors. Generation continues in
/// Quick/Canvas; this panel owns no second project, inventory or execution service.
public struct ProjectDocumentsView: View {
    @Environment(\.dLanguageStore) private var language
    @Environment(\.dLanguageStore) private var legacyLanguage
    @Bindable private var model: WorkbenchModel
    private let library: ModelLibraryModel?
    private let onContinueInQuick: (() -> Void)?
    private var layoutProbe: ((String, CGRect) -> Void)?
    @State private var audioRangeState = AudioCreationRangeState()
    @State private var showingPitchAnalysis = false
    @State private var showingTasks = false
    @State private var expandTasks = true
    @State private var namingContext: DocumentNameContext?
    @State private var detailsAsset: ProjectAsset?
    @State private var editingAsset: ProjectAsset?
    @State private var transferring = false
    @State private var commandScope = WorkbenchCommandScope()

    public init(model: WorkbenchModel, library: ModelLibraryModel? = nil, onContinueInQuick: (() -> Void)? = nil) {
        self.model = model; self.library = library; self.onContinueInQuick = onContinueInQuick
    }
    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self; copy.layoutProbe = observer; return copy
    }
    private var blockedAudioInput: Bool {
        model.projectSession.audio?.navigationBlockMessage != nil || audioRangeState.pendingMessage != nil
    }
    private var saveEdits: (() async throws -> Void)? {
        guard !blockedAudioInput, let id = model.activeDocumentID else { return nil }
        let owner = model.projectSession, epoch = owner.navigationEpoch
        return { try await owner.saveDocumentEdits(documentID: id, navigationEpoch: epoch) }
    }
    public var body: some View {
        VStack(spacing: 12) {
            if model.manifest != nil {
                HStack {
                    Text(model.manifest?.name ?? "D").font(.headline); Spacer()
                    Button(workflowText(language, "childPanel.name.tasks")) { showingTasks = true }
                        .accessibilityIdentifier("project-document-tasks")
                    Button(workflowText(language, "layoutInteraction.save")) {
                        guard commandScope.permitsVisibleCommands, let save = saveEdits else { return }
                        let owner = model.projectSession, documentID = model.activeDocumentID
                        let epoch = owner.navigationEpoch
                        Task {
                            do { try await save() }
                            catch {
                                guard model.projectSession === owner, owner.navigationEpoch == epoch,
                                      owner.activeDocumentID == documentID else { return }
                                model.errorMessage = error.localizedDescription
                            }
                        }
                    }.keyboardShortcut("s", modifiers: .command)
                     .disabled(saveEdits == nil || model.isBusy || transferring)
                }.padding(.horizontal, 16)
                HStack(spacing: 12) {
                    VStack(spacing: 8) {
                        Picker(workflowText(language, "workbench.view"), selection: Binding(get: { model.creatorMode }, set: { mode in
                            Task { await model.switchCreatorMode(mode) }
                        })) {
                            ForEach(model.availableCreatorModes, id: \.self) { mode in
                                Text(consistencyText(language, "mode." + mode.rawValue)).tag(mode)
                            }
                        }.pickerStyle(.menu).padding(.horizontal, 12)
                        ModalityDocumentList(documents: model.documents, mode: model.creatorMode,
                            selectedDocumentID: model.presentedDocument?.id,
                            onSelect: { id in Task { await model.switchDocument(to: id) } }, onCreate: createDocument)
                        if let document = model.presentedDocument {
                            Button(workflowText(language, "consistency.legacy.WorkbenchView.8")) {
                                model.beginEditing(); namingContext = .init(documentID: document.id, name: document.name)
                            }.accessibilityIdentifier("rename-document-\(document.id.uuidString)")
                        }
                        if model.creatorMode == .audio, let audio = model.projectSession.audio {
                            AudioCaptureEntry(model: model, audio: audio).frame(maxHeight: 240)
                        }
                    }.frame(width: 224)
                    Divider()
                    workspaceEditor.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProjectChooserView(recentProjects: model.recentProjects, isBusy: model.isChangingProject,
                    onNew: { Task { await model.newProject() } }, onOpen: { Task { await model.openProject() } },
                    onRecent: { id in Task { await model.openRecentProject(id: id) } }, onModels: { library?.presentManagement() })
            }
        }.padding(.vertical, 12).frame(minWidth: 760, minHeight: 480)
        .background(WorkbenchCommandWindow(scope: commandScope))
        .onChange(of: model.projectURL) { _, _ in model.invalidateComparison() }
        .disabled(model.isChangingProject || transferring)
        .workbenchCloseProtection(isDirty: model.projectSession.hasUnsavedDocumentEdits || blockedAudioInput,
            isSaving: transferring || model.projectSession.isTextWorking || model.projectSession.text?.isSaving == true
                || model.projectSession.text?.isRecordingRewrite == true || model.projectSession.textSources?.isSaving == true
                || model.projectSession.audio?.isBusy == true || model.projectSession.pitchIsBusy,
            allowsDiscard: false, save: saveEdits)
        .environment(\.metadataEditorLifecycle, MetadataEditorLifecycle(begin: model.beginEditing, end: model.endEditing))
        .workbenchPopover(isPresented: $showingTasks, title: workflowText(language, "childPanel.name.tasks")) {
            VStack(alignment: .leading, spacing: 12) {
                WorkbenchTasks(model: model, isExpanded: $expandTasks)
                Button(workflowText(language, "consistency.legacy.WorkbenchView.7")) {
                    let owner = model.projectSession, store = model.projectSession.currentStore
                    Task {
                        guard model.projectSession === owner, owner.currentStore === store else { return }
                        await model.recoverArtifacts()
                    }
                }.disabled(model.isBusy || model.isChangingProject)
                 .accessibilityIdentifier("project-document-recover-results")
            }.padding(16).frame(width: 600)
        }
        .workbenchSheet(item: $namingContext, title: workflowText(language, "childPanel.name.metadata"), onDismiss: { model.endEditing() }) { context in
            DocumentNameEditor(model: model, context: context)
        }
        .workbenchSheet(item: $detailsAsset, title: workflowText(language, "childPanel.name.details")) { asset in
            ScrollView { ProjectImageCandidateDetails(model: model, asset: model.manifest?.assets.first { $0.id == asset.id } ?? asset) {
                model.beginEditing(); editingAsset = asset
            }.padding(20) }
        }
        .workbenchSheet(item: $editingAsset, title: workflowText(language, "childPanel.name.metadata"), onDismiss: { model.endEditing() }) { asset in
            ProjectImageMetadataEditor(model: model, asset: asset, isPresented: Binding(get: { editingAsset != nil }, set: { if !$0 { editingAsset = nil } }))
        }
        .workbenchConfirmation(consistencyText(language, "error.incomplete"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
            Button(workflowText(language, "common.done")) { model.clearError() }
        } message: { Text(model.errorMessage ?? "") }
        .workbenchSheet(isPresented: Binding(get: { library?.isPresented ?? false }, set: { library?.isPresented = $0 }),
            title: workflowText(language, "modelManagement.modelTitle")) {
            if let library { ModelLibraryView(model: library) }
        }
    }
    private func continueInQuick() {
        guard !transferring, let onContinueInQuick, let id = model.activeDocumentID else { return }
        let owner = model.projectSession, store = owner.currentStore, epoch = owner.navigationEpoch
        transferring = true
        Task {
            defer { transferring = false }
            do {
                let appendedID = try await owner.continueDocumentInQuick(documentID: id, navigationEpoch: epoch)
                guard model.projectSession === owner, owner.currentStore === store,
                      owner.activeDocumentID == id, owner.navigationEpoch == epoch,
                      owner.projectQuick?.draft?.id == appendedID else { return }
                transferring = false
                onContinueInQuick()
            } catch {
                guard model.projectSession === owner, owner.currentStore === store,
                      owner.activeDocumentID == id, owner.navigationEpoch == epoch else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }
    private func createDocument() {
        if model.creatorMode == .image {
            model.beginEditing()
            namingContext = DocumentNameContext(documentID: nil, name: workflowText(language, "workbench.native.documentDefault"))
        } else { Task { await model.createVisibleDocument() } }
    }

    @ViewBuilder private var workspaceEditor: some View {
        if model.presentedDocument == nil {
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
                    if onContinueInQuick != nil && (model.creatorMode == .image || model.creatorMode == .video) {
                        Button(baselineText(language, "library.quickUse")) { continueInQuick() }
                            .disabled(model.isBusy || transferring)
                            .accessibilityIdentifier("project-document-continue-quick")
                            .audioMeasured("project-document-continue-quick", probe: layoutProbe)
                    }
                    if model.creatorMode == .image {
                        RecipeHandoffButton(model: model)
                        if let asset = model.selectedAsset {
                            Button(workflowText(language, "childPanel.name.details")) { detailsAsset = asset }
                                .accessibilityIdentifier("project-image-details")
                        }
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
            videoWorkspace
        } else if !model.showingAllArtworks, model.activeDocument?.audioCreation != nil,
           model.projectSession.audioCreationDraft != nil {
            audioWorkspace(presentation: .complete)
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
                        if let library, model.projectSession.hasPitchEngine {
                            Button(workflowText(legacyLanguage, "workflow.action.chooseModel")) {
                                let owner = model.projectSession
                                let documentID = owner.activeDocumentID, contextID = audio.contextID
                                library.presentSelection { id in
                                    do {
                                        _ = try await owner.selectWorkflowInstallation(id: id) { choice in
                                            guard model.projectSession === owner, owner.activeDocumentID == documentID,
                                                  owner.audio?.contextID == contextID, choice.kind == .pitch,
                                                  !owner.pitchIsBusy else {
                                                throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。"))
                                            }
                                        }
                                        library.isPresented = false
                                    } catch { library.errorMessage = error.localizedDescription }
                                }
                                library.captureSelectionPresentation("SwiftF0") {
                                    model.projectSession === owner && owner.activeDocumentID == documentID
                                        && owner.audio?.contextID == contextID && !owner.pitchIsBusy
                                }
                            }
                            .disabled(model.projectSession.pitchIsBusy)
                            .accessibilityIdentifier("pitch-choose-model")
                            .padding(.horizontal, 20)
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
            textWorkspace(presentation: .complete)
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

    @ViewBuilder private var videoWorkspace: some View {
        if let document = model.presentedDocument, let draft = model.projectSession.videoCreationDraft {
            let session = model.projectSession, context = session.videoCreationContextID
            ProjectVideoCandidatesView(draft: draft,
                candidates: session.videoCreationCandidates,
                selectedAssetID: document.selectedAssetID, adoptedAssetID: document.adoptedAssetID,
                isBusy: session.isBusy || session.isRegisteringVideoModel || model.isChangingProject,
                previewURL: session.videoPreviewURL, previewIdentity: session.videoPreviewIdentity,
                actions: model.videoCreationActions(contextID: context, documentID: document.id))
                .id(document.id)
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
                    onGenerate: { Task { if project.navigationEpoch == epoch && project.activeDocumentID == id { await project.rewriteText() } } },
                    onCancel: { Task { if project.navigationEpoch == epoch && project.activeDocumentID == id { await project.cancelTextRewrite() } } },
                    onAccept: { if project.navigationEpoch == epoch && project.activeDocumentID == id { project.acceptTextRewrite() } }, onReject: { if project.navigationEpoch == epoch && project.activeDocumentID == id { text.reject() } }, onUndo: { if project.navigationEpoch == epoch && project.activeDocumentID == id { project.undoTextRewrite() } },
                    onSave: { Task { if project.navigationEpoch == epoch && project.activeDocumentID == id { await project.saveText() } } },
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
