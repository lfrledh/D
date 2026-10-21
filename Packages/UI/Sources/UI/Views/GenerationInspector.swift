import DInference
import DWorkbench
import SwiftUI

struct GenerationInspector: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Bindable var model: WorkbenchModel
    var library: ModelLibraryModel? = nil
    private let parameterDocumentID: UUID?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var promptFocused: Bool
    @State private var editingAsset: ProjectAsset?
    @State private var rawImageWidth: String?
    @State private var rawImageHeight: String?

    init(model: WorkbenchModel, library: ModelLibraryModel? = nil) {
        self.model = model
        self.library = library
        parameterDocumentID = model.activeDocumentID
    }

    private var selectedLibraryRecord: ModelRecord? {
        guard let id = model.selectedModelID else { return nil }
        return library?.records.first { $0.id == id }
    }

    private var displayedModelStatus: String {
        guard let library else { return model.modelStatus }
        if let record = selectedLibraryRecord { return library.status(for: record) }
        if model.selectedModelID != nil, library.snapshot != nil {
            return workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.56")
        }
        return workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.57")
    }

    private var hasAvailableSelection: Bool {
        guard let library else { return true }
        guard let record = selectedLibraryRecord else { return false }
        return library.canUse(record)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.activeDocument?.name ?? workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.58")).font(.title2.weight(.semibold))
                    Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.59"))
                        .font(.callout).foregroundStyle(.secondary)
                }

                modelSection
                Divider()
                ImageReferenceSection(
                    model: model,
                    documentID: model.activeDocumentID,
                    navigationEpoch: model.projectSession.navigationEpoch
                )
                Divider()
                promptSection
                seedSection
                generationSettings

                if let asset = model.selectedAsset {
                    Divider()
                    CandidateDetails(model: model, asset: asset) {
                        model.beginEditing()
                        editingAsset = asset
                    }
                }
                if let job = model.selectedJob, case .image(let image) = job.request.input {
                    Divider()
                    savedConditions(job: job, image: image)
                }
            }
            .padding(20)
        }
        .onChange(of: model.activeDocumentID) { _, _ in
            // Uncommitted field text belongs to its previous document, never the next one.
            rawImageWidth = nil; rawImageHeight = nil
        }
        .accessibilityIdentifier("generation-inspector-scroll")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            generateButton
                .padding(.horizontal, 20).padding(.vertical, 16)
                .background(.background)
        }
        .sheet(item: $editingAsset, onDismiss: { model.endEditing() }) { asset in
            CandidateMetadataEditor(model: model, asset: asset, isPresented: Binding(
                get: { editingAsset != nil }, set: { if !$0 { editingAsset = nil } }))
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.60"), systemImage: "cube.transparent")
            if let name = model.modelName {
                Text(name).font(.callout.weight(.medium)).textSelection(.enabled)
            } else {
                Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.61")).font(.callout.weight(.medium))
            }
            Text(displayedModelStatus).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("model-status")
            Button {
                if let library {
                    let owner = model.projectSession, store = model.projectSession.currentStore
                    library.presentSelection(selected: model.selectedModelID) { id in
                        guard model.projectSession === owner, owner.currentStore === store, !model.isChangingProject else { return }
                        await model.selectModel(id: id)
                    }
                    library.captureSelectionPresentation(model.manifest?.name ?? "D") {
                        model.projectSession === owner && owner.currentStore === store && !model.isChangingProject
                    }
                }
                else { Task { await model.registerModel() } }
            } label: {
                Label(library != nil ? workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.62") : (model.modelName == nil ? workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.63") : workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.64")),
                      systemImage: library != nil ? "cube.transparent" : "folder.badge.plus")
            }
            .accessibilityIdentifier(library != nil ? "choose-project-model" : "register-model")
            .disabled(library == nil && model.isBusy)
            .help(library != nil ? workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.65") : workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.66"))
            if let library, library.hasActiveWork {
                Label(consistencyText(legacyLanguage, "copy.GenerationInspector.0", arguments: ["v0": String(describing: library.activityCount)]), systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let library, library.failedCount > 0 {
                Label(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.67"), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.68"), systemImage: "text.alignleft")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(minHeight: 145)
                    .focused($promptFocused)
                    .accessibilityLabel(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.68"))
                    .accessibilityIdentifier("prompt-editor")
                if model.prompt.isEmpty {
                    Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.69"))
                        .font(.body).foregroundStyle(.tertiary)
                        .padding(.horizontal, 10).padding(.top, 13)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .workbenchInputSurface()
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(promptFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
            Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.70"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var seedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.71"), systemImage: "dice")
                Spacer()
                Toggle(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.72"), isOn: $model.randomSeed)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("random-seed")
            }
            if model.randomSeed {
                Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.73"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("0", text: $model.seedText)
                    .textFieldStyle(WorkbenchGlassTextFieldStyle())
                    .monospacedDigit()
                    .accessibilityLabel(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.74"))
                    .accessibilityIdentifier("seed-field")
                Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.75"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var generationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.76"), systemImage: "slider.horizontal.3")
            VStack(alignment: .leading, spacing: 8) {
                Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.77")).font(.caption).foregroundStyle(.secondary)
                TextField(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.77"), text: imageWidth)
                    .textFieldStyle(WorkbenchGlassTextFieldStyle())
                    .accessibilityLabel(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.77"))
                    .accessibilityIdentifier("image-width")
                Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.78")).font(.caption).foregroundStyle(.secondary)
                TextField(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.78"), text: imageHeight)
                    .textFieldStyle(WorkbenchGlassTextFieldStyle())
                    .accessibilityLabel(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.78"))
                    .accessibilityIdentifier("image-height")
            }
            HStack(spacing: 18) {
                settingValue(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.79"), value: "\(model.imageCapability.steps)")
                settingValue("Guidance", value: model.imageCapability.guidanceScale.formatted())
            }
            Text(consistencyText(legacyLanguage, "copy.GenerationInspector.1", arguments: ["v0": String(describing: model.imageCapability.minimumWidth), "v1": String(describing: model.imageCapability.maximumWidth), "v2": String(describing: model.imageCapability.minimumHeight), "v3": String(describing: model.imageCapability.maximumHeight), "v4": String(describing: model.imageCapability.dimensionMultiple)]))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let recommendation = model.executionRecommendations {
                Text(consistencyText(legacyLanguage, "copy.GenerationInspector.2", arguments: ["v0": String(describing: recommendation.imageDimension), "v1": String(describing: recommendation.imageDimension)]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            presetButtons
            if let error = model.imageConfigurationError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("image-settings-error")
            }
        }
        .accessibilityIdentifier("image-parameter-section")
        .onDisappear(perform: discardUnfinishedImageEdit)
    }

    private var imageWidth: Binding<String> {
        Binding(get: { rawImageWidth ?? String(model.imageSettings.width) }, set: { value in
            rawImageWidth = value
            publishImageEditIfComplete()
        })
    }

    private var imageHeight: Binding<String> {
        Binding(get: { rawImageHeight ?? String(model.imageSettings.height) }, set: { value in
            rawImageHeight = value
            publishImageEditIfComplete()
        })
    }

    @ViewBuilder private var presetButtons: some View {
        let sizes = [512, 768, 1024].filter { accepts(width: $0, height: $0) }
        if !sizes.isEmpty {
            WorkbenchMenu(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.80")) {
                WorkbenchMenuForEach(sizes, id: \.self) { size in
                    WorkbenchMenuAction("\(size) × \(size)") { applyImagePreset(width: size, height: size) }
                }
            }
            .controlSize(.small)
            Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.81"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func accepts(width: Int, height: Int) -> Bool {
        let capability = model.imageCapability
        return (try? ImageGenerationSettings(width: width, height: height,
            executionProfile: capability.profile).request(prompt: "preset", seed: 0, capability: capability)) != nil
    }

    private func publishImageEditIfComplete() {
        let widthText = rawImageWidth ?? String(model.imageSettings.width)
        let heightText = rawImageHeight ?? String(model.imageSettings.height)
        if let error = numericEditingError(widthText, label: workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.82"))
            ?? numericEditingError(heightText, label: workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.83")) {
            setImageEditingError(error)
            return
        }
        guard let width = Int(widthText), let height = Int(heightText) else { return }
        let currentProfile = model.imageSettings.executionProfile
        let profile = Self.profileForManualDimensionEdit(currentProfile, capability: model.imageCapability)
        model.imageSettings = ImageGenerationSettings(width: width, height: height,
            executionProfile: profile)
        rawImageWidth = nil; rawImageHeight = nil
        setImageEditingError(nil)
    }

    private func applyImagePreset(width: Int, height: Int) {
        model.imageSettings = ImageGenerationSettings(width: width, height: height,
            executionProfile: model.imageCapability.profile)
        rawImageWidth = nil; rawImageHeight = nil
        setImageEditingError(nil)
    }

    private func discardUnfinishedImageEdit() {
        guard rawImageWidth != nil || rawImageHeight != nil else { return }
        rawImageWidth = nil; rawImageHeight = nil
        setImageEditingError(nil)
    }

    private func setImageEditingError(_ error: String?) {
        model.projectSession.setParameterEditingError(error, for: .image, documentID: parameterDocumentID)
    }

    private func numericEditingError(_ raw: String, label: String) -> String? {
        workbenchIntegerEditingError(raw, field: label, language: legacyLanguage)
    }

    static func profileForManualDimensionEdit(_ current: ExecutionProfileReference,
                                               capability: ImageExecutionCapability) -> ExecutionProfileReference {
        current == ImageExecutionCapability.verified512.profile ? capability.profile : current
    }

    @ViewBuilder private var generateButton: some View {
        if reduceTransparency {
            generateAction.buttonStyle(WorkbenchPrimaryButtonStyle())
        } else {
            generateAction.buttonStyle(WorkbenchPrimaryButtonStyle())
        }
    }

    private var generateAction: some View {
        Button {
            Task { await model.generate() }
        } label: {
            Label(model.isBusy ? workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.84") : workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.85"), systemImage: "sparkles")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .controlSize(.large)
        .disabled(!model.canGenerate || !hasAvailableSelection)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityIdentifier("generate")
        .help(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.86"))
    }

    private func savedConditions(job: ProjectJob, image: ImageRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.87"), systemImage: "info.circle")
            Text(image.prompt).font(.caption).lineLimit(5).textSelection(.enabled)
            LabeledContent(workflowText(legacyLanguage, "workbench.field.seed"), value: String(image.seed))
                .font(.caption).monospacedDigit().textSelection(.enabled)
            LabeledContent(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.88"), value: job.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
            if let provenance = ImageReferenceSection.submittedReferenceText(job: job, manifest: model.manifest, language: legacyLanguage) {
                Text(provenance)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("submitted-image-reference")
            } else {
                Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.89"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("submitted-image-reference-none")
            }
            Button {
                Task { await model.copySettings(from: job.id) }
            } label: {
                Label(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.12"), systemImage: "arrow.branch")
            }
            .accessibilityIdentifier("copy-settings-inspector")
            Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.90"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleOnly)
    }

    private func settingValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}

private struct CandidateDetails: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Bindable var model: WorkbenchModel
    let asset: ProjectAsset
    let edit: () -> Void
    private var ownerID: UUID? { model.manifest?.jobs.first(where: { $0.id == asset.jobID })?.documentID }
    private var ownerName: String {
        model.documents.first(where: { $0.id == ownerID })?.name ?? workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.91")
    }
    private var adoptionActionTitle: String {
        if model.documents.contains(where: { $0.adoptedAssetID == asset.id }) {
            return ownerID == model.activeDocumentID ? workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.92") : "取消「\(ownerName)」的采用"
        }
        return "采用为「\(ownerName)」的方案"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.93")).font(.subheadline.weight(.semibold))
            Text(asset.name).font(.callout.weight(.medium))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(asset.name)
                .accessibilityIdentifier("candidate-saved-name")
            if !asset.note.isEmpty { Text(asset.note).font(.caption).textSelection(.enabled) }
            Toggle(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.94"), isOn: Binding(get: { asset.isFavorite }, set: { value in
                guard let owner = model.projectSession.currentStore, let project = model.manifest else { return }
                let baseline = ProjectAssetEditBaseline(project: project, asset: asset)
                Task {
                    do { try await model.projectSession.saveAssetAnnotations(owner: owner, expected: baseline, isFavorite: value) }
                    catch { if model.projectSession.currentStore === owner { model.errorMessage = workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.95") + error.localizedDescription } }
                }
            })).accessibilityIdentifier("candidate-favorite")
            Button(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.96"), action: edit)
                .accessibilityIdentifier("edit-candidate")
            Button {
                Task {
                    if let document = model.documents.first(where: { $0.adoptedAssetID == asset.id }) {
                        await model.clearAdoptedAsset(documentID: document.id)
                    } else { await model.adoptAsset(asset.id) }
                }
            } label: {
                Label(adoptionActionTitle, systemImage: "checkmark.seal")
            }
            .accessibilityIdentifier("adopt-candidate")
            Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.97"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CandidateMetadataEditor: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Bindable var model: WorkbenchModel
    let asset: ProjectAsset
    @Binding var isPresented: Bool
    @State private var name: String
    @State private var note: String
    @State private var saving = false
    @State private var saveError: String?
    @State private var owner: ProjectStore?
    @State private var baseline: ProjectAssetEditBaseline?
    private let originalName: String
    private let originalNote: String

    init(model: WorkbenchModel, asset: ProjectAsset, isPresented: Binding<Bool>) {
        self.model = model
        self.asset = asset
        self._isPresented = isPresented
        originalName = asset.name
        originalNote = asset.note
        _owner = State(initialValue: model.projectSession.currentStore)
        _baseline = State(initialValue: model.manifest.map { ProjectAssetEditBaseline(project: $0, asset: asset) })
        _name = State(initialValue: asset.name)
        _note = State(initialValue: asset.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.98")).font(.headline)
            TextField(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.99"), text: $name).textFieldStyle(WorkbenchGlassTextFieldStyle())
                .accessibilityIdentifier("candidate-name")
            TextField(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.100"), text: $note, axis: .vertical).lineLimit(4...8)
                .textFieldStyle(WorkbenchGlassTextFieldStyle()).accessibilityIdentifier("candidate-note")
            if let saveError { WorkbenchIssueText(raw: saveError).font(.caption).foregroundStyle(.red) }
            if model.editorCloseAttempted {
                Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.53"))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("pending-editor-close")
            }
            HStack {
                Spacer()
                Button(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.33"), role: .cancel) { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.54")) {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            guard let owner, let baseline else { throw WorkflowIssue("作品所属实例不可访问，草稿保留。") }
                            try await model.projectSession.saveAssetAnnotations(owner: owner, expected: baseline,
                                name: name.utf8.elementsEqual(baseline.name.utf8) ? nil : name,
                                note: note.utf8.elementsEqual(baseline.note.utf8) ? nil : note)
                            isPresented = false
                        } catch { saveError = error.localizedDescription }

                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-candidate")
            }
        }.padding(24).frame(width: 360)
            .disabled(saving).interactiveDismissDisabled()
    }
}
