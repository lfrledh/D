import DInference
import DWorkbench
import SwiftUI

/// The workbench presents saved project values and application actions, never model objects.
public struct WorkbenchView: View {
    @Bindable private var model: WorkbenchModel
    private let library: ModelLibraryModel?
    private var layoutProbe: ((String, CGRect) -> Void)?
    @State private var audioRangeState = AudioCreationRangeState()
    @State private var pane: WorkspacePane = .creations
    @State private var showTasks = false
    @State private var expandTasks = true
    @State private var namingContext: DocumentNameContext?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: WorkbenchModel, library: ModelLibraryModel? = nil) {
        self.model = model
        self.library = library
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
                projectWorkbench
            } else {
                ProjectChooserView(recentProjects: model.recentProjects, isBusy: model.isChangingProject,
                    onNew: { Task { await model.newProject() } },
                    onOpen: { Task { await model.openProject() } },
                    onRecent: { id in Task { await model.openRecentProject(id: id) } },
                    onModels: { library?.isPresented = true })
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .focusedSceneValue(\.workbenchGeneration, visibleGenerationCommand)
        .disabled(model.isChangingProject)
        .overlay {
            if model.isChangingProject {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在整理项目…").font(.callout)
                }
                .padding(24)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.10), radius: 20, y: 8)
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(
            get: { library?.isPresented ?? false },
            set: { library?.isPresented = $0 }
        )) {
            if let library {
                ModelLibraryView(model: library, selectedModelID: model.selectedModelID,
                    canSelect: model.manifest != nil && model.creatorMode == .image && !model.isChangingProject) { id in
                    await model.selectModel(id: id)
                    if model.selectedModelID == id {
                        library.isPresented = false
                    } else if let message = model.errorMessage {
                        library.errorMessage = message
                        model.clearError()
                    }
                }
            }
        }
    }

    private var visibleGenerationCommand: WorkbenchGenerationCommand {
        let epoch = model.projectSession.navigationEpoch
        let audio = model.creatorMode == .audio
        let validAudioRange: Bool
        if audio, let draft = model.projectSession.audioCreationDraft {
            validAudioRange = audioRangeState.contextID == model.projectSession.audioCreationContextID &&
                AudioCreationButtonHandler.canSubmit(draft, source: model.projectSession.audioCreationSource,
                    hostAllowsGeneration: model.projectSession.canGenerateAudioCreation,
                    hasPendingRangeInput: draft.operation == .inpaint && audioRangeState.pendingMessage != nil)
        } else { validAudioRange = !audio }
        let enabled = model.canRunVisibleGeneration && validAudioRange
        return WorkbenchGenerationCommand(title: model.visibleGenerationTitle, isEnabled: enabled) {
            guard enabled, epoch == model.projectSession.navigationEpoch else { return }
            Task { await model.generateVisible() }
        }
    }

    private var projectWorkbench: some View {
        ProjectWorkspaceShell(projectName: model.manifest?.name ?? "D", mode: model.creatorMode,
            availableModes: model.availableCreatorModes,
            hasInspector: model.presentedDocument != nil && (model.creatorMode != .audio || model.projectSession.audioCreationDraft != nil),
            taskCount: model.projectSession.activeJobIDs.count + (model.projectSession.isTextWorking ? 1 : 0),
            onMode: { mode in Task { await model.switchCreatorMode(mode) } },
            onBack: { Task { await model.closeProject() } },
            onTasks: { showTasks = true }, onModels: { library?.isPresented = true }) {
                workspaceSidebar
            } editor: {
                workspaceEditor
            } inspector: {
                switch model.creatorMode {
                case .image: GenerationInspector(model: model, library: library)
                case .text: textWorkspace(presentation: .parameters)
                case .audio: audioWorkspace(presentation: .parameters)
                }
            }
        .observingLayout { layoutProbe?($0, $1) }
        .onChange(of: model.projectURL) { _, _ in
            model.invalidateComparison(); pane = .creations
        }
        .onChange(of: model.creatorMode) { _, _ in pane = .creations }
        .popover(isPresented: $showTasks) {
            VStack(alignment: .leading, spacing: 12) {
                Text("项目任务").font(.headline)
                if model.manifest?.jobs.isEmpty == true { Text("还没有生成任务。").foregroundStyle(.secondary) }
                WorkbenchTasks(model: model, isExpanded: $expandTasks)
                Button("检查可恢复作品") { Task { await model.recoverArtifacts() } }.disabled(model.isBusy)
            }.padding(16).frame(width: 600)
        }
        .sheet(item: $namingContext, onDismiss: { model.endEditing() }) { context in
            DocumentNameEditor(model: model, context: context)
        }
    }

    private var workspaceSidebar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(WorkspacePane.allCases) { item in
                    Button { pane = item } label: { Text(item.title).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderless)
                        .background(pane == item ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityAddTraits(pane == item ? .isSelected : [])
                        .accessibilityIdentifier("workspace-\(item.rawValue)")
                }
            }.padding([.horizontal, .top], 10).accessibilityIdentifier("workspace-pane")
            if pane == .assets, let manifest = model.manifest {
                ProjectResourceBrowser(manifest: manifest, mode: model.creatorMode,
                    availableModes: model.availableCreatorModes,
                    assetURL: { model.assetURLs[$0] },
                    onOpenDocument: { id in Task { await model.switchDocument(to: id) } })
            } else {
                ModalityDocumentList(documents: model.documents, mode: model.creatorMode,
                    selectedDocumentID: model.presentedDocument?.id,
                    onSelect: { id in Task { await model.switchDocument(to: id) } }, onCreate: createDocument)
                if let document = model.presentedDocument {
                    Button("重命名当前创作…") {
                        model.beginEditing()
                        namingContext = DocumentNameContext(documentID: document.id, name: document.name)
                    }
                    .accessibilityIdentifier("rename-document-\(document.id.uuidString)")
                    .padding(.horizontal, 10)
                }
                if model.creatorMode == .audio, let audio = model.projectSession.audio {
                    AudioCaptureEntry(model: model, audio: audio)
                        .frame(maxHeight: 240)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func createDocument() {
        if model.creatorMode == .image {
            model.beginEditing()
            namingContext = DocumentNameContext(documentID: nil, name: "新创作")
        } else { Task { await model.createVisibleDocument() } }
    }

    @ViewBuilder private var workspaceEditor: some View {
        if model.presentedDocument == nil {
            ContentUnavailableView {
                Label("开始\(model.creatorMode.title)创作", systemImage: model.creatorMode.symbol)
            } description: {
                Text("这个项目还没有此类创作。切换模态不会自动创建文档。")
            } actions: {
                Button(model.creatorMode.newDocumentTitle, action: createDocument).buttonStyle(.glassProminent)
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
                        .disabled(model.selectedJob == nil).help("基于条件新建创作")
                        .accessibilityLabel("基于条件新建创作").accessibilityIdentifier("copy-settings")
                        .audioMeasured("copy-settings", probe: layoutProbe)
                        Button { Task { await model.exportSelected() } } label: { Image(systemName: "square.and.arrow.up") }
                            .disabled(model.selectedAsset == nil).help("导出原始 PNG")
                            .accessibilityLabel("导出作品").accessibilityIdentifier("export-artwork")
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
        if !model.showingAllArtworks, model.activeDocument?.audioCreation != nil,
           model.projectSession.audioCreationDraft != nil {
            audioWorkspace(presentation: .content)
        } else if !model.showingAllArtworks, model.activeDocument?.kind == .audio,
           let audio = model.projectSession.audio {
            VStack(spacing: 0) {
                if let assetID = model.activeDocument?.audioDraft?.assetID {
                    HStack {
                        Button("基于原声创建 AI 候选", systemImage: "waveform.badge.plus") {
                            Task { await model.createAudioCreation(sourceAssetID: assetID) }
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("audio-create-from-original")
                        Spacer()
                    }.padding(.horizontal, 20).padding(.top, 12)
                }
                AudioWorkbenchView(controller: audio,
                               recordingEnabled: model.audioRecordingEnabled,
                               navigationInProgress: model.projectSession.isChangingProject,
                               actions: audioActions)
                .observingLayout { id, rectangle in layoutProbe?(id, rectangle) }
                .id(audio.contextID)
            }
        } else if !model.showingAllArtworks, model.projectSession.text != nil {
            textWorkspace(presentation: .editor)
        } else if model.isComparing {
            ArtworkComparison(model: model)
        } else if let asset = model.selectedAsset, let url = model.assetURLs[asset.id] {
            ArtworkCanvas(url: url, label: "已保存的作品")
        } else if model.selectedAsset != nil {
            ContentUnavailableView("作品暂时无法访问", systemImage: "externaldrive.badge.exclamationmark",
                description: Text("请连接项目所在的磁盘，然后重新打开项目。已保存的作品不会被移除。"))
        } else {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                ContentUnavailableView {
                    Label("从一个想法开始", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("在右侧描述你想创作的画面。\n作品会自动保存在这个项目中。")
                }
            }
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
                status: jobID.flatMap { session.phases[$0] } ?? session.audioCreationSaveStatus,
                transport: session.audioCreationTransport,
                actions: model.audioCreationActions(contextID: context, documentID: document.id))
                .presenting(presentation, rangeState: audioRangeState, contextID: context)
                .id(document.id)
        }
    }

    @ViewBuilder private func textWorkspace(presentation: TextWorkbenchPresentation) -> some View {
        if let text = model.projectSession.text {
            let project = model.projectSession
            let id = text.editor.document.id
            let epoch = project.navigationEpoch
            VStack(spacing: 0) {
                if project.isTextWorking && !text.editor.isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在校验本地文字模型…")
                        Button("取消") { Task { await project.cancelTextRewrite() } }
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
                    onAccept: { text.accept() }, onReject: { text.reject() }, onUndo: { text.undo() },
                    onSave: { Task { await project.saveText() } },
                    onChooseModel: { Task { await model.chooseTextModel() } })
                    .presenting(presentation)
                .id(id)
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
    @Bindable var model: WorkbenchModel
    let audio: ProjectAudioController
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 8) { entries }.padding(10) } }
    @ViewBuilder private var entries: some View {
        let contextID = audio.contextID
        let renderDocumentID = model.activeDocumentID
        Text("原声素材").font(.caption.weight(.semibold))
        Button(action: model.audioImportAction(contextID: contextID, documentID: renderDocumentID)) {
            Label("导入原声…", systemImage: "waveform.badge.plus")
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .disabled(model.isChangingProject || audio.isBusy)
        .accessibilityIdentifier("sidebar-audio-import")
        if audio.transport.state == .recording || audio.transport.state == .requestingPermission {
            Button {
                Task { await model.finishAudioRecording() }
            } label: {
                Label(audio.transport.state == .recording ? "结束录音" : "取消等待",
                      systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .accessibilityIdentifier("sidebar-audio-record-finish")
        } else {
            Button {
                Task { await model.startAudioRecording() }
            } label: {
                Label(model.audioRecordingEnabled ? "开始录音" : "录音尚未启用",
                      systemImage: model.audioRecordingEnabled ? "mic.fill" : "mic.slash")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .disabled(!model.audioRecordingEnabled)
            .accessibilityIdentifier("sidebar-audio-record-start")
            Text(model.audioRecordingEnabled
                 ? "点击开始录音后请求麦克风许可；结束后保存在本地项目。"
                 : "麦克风录音暂未启用；不会申请系统许可。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
        }
        ForEach(audio.pendingCaptures) { capture in
            VStack(alignment: .leading, spacing: 4) {
                Text("待恢复：\(capture.name)").font(.caption).lineLimit(1)
                HStack {
                    Button("重试") {
                        Task {
                            await model.retryPendingAudioCapture(
                                id: capture.id, contextID: contextID,
                                renderDocumentID: renderDocumentID
                            )
                        }
                    }
                    Button("保留") {
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
    @Bindable var model: WorkbenchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("当前创作的候选").font(.caption.weight(.semibold))
                Spacer()
                Button("比较已选 \(model.comparisonSelection.count)/2") { model.beginComparison() }
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
                            if asset.isFavorite { Image(systemName: "star.fill").accessibilityLabel("已收藏") }
                            if model.documents.contains(where: { $0.adoptedAssetID == asset.id }) {
                                Label("已采用", systemImage: "checkmark.seal.fill")
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
            .help("选择两张作品进行比较")
            .accessibilityLabel("比较 \(asset.name)")
            .accessibilityValue(model.comparisonSelection.contains(asset.id) ? "已选择" : "未选择")
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
    @Bindable var model: WorkbenchModel
    let context: DocumentNameContext
    @State private var name: String
    @State private var saving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

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
            TextField("创作名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("document-name")
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            if model.editorCloseAttempted {
                Text("请先保存或取消编辑，再关闭项目或退出 D。")
                    .font(.caption).accessibilityIdentifier("pending-editor-close")
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let previousCount = model.documents.count
                    saving = true
                    Task {
                        if let id = context.documentID { await model.renameDocument(id: id, name: value) }
                        else { await model.createDocument(name: value) }
                        saving = false
                        let saved = context.documentID.map { identifier in
                            model.documents.contains { $0.id == identifier && $0.name == value }
                        } ?? (model.documents.count > previousCount && model.activeDocument?.name == value)
                        if saved { dismiss() }
                        else {
                            saveError = model.errorMessage ?? "未能保存，名称仍然保留。"
                            model.clearError()
                        }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("save-document-name")
            }
        }.padding(24).frame(width: 320)
            .disabled(saving).interactiveDismissDisabled()
    }
}
