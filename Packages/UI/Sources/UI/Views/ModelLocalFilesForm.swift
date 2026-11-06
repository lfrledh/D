import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

/// Folder, drop and restored-model entrances share one form and application owner.
/// Accepting it never selects a node or changes the current project.
struct ModelLocalFilesForm: View {
    @Bindable var model: ModelLibraryModel
    var knownSource: ProjectRestoredModel? = nil
    var onComplete: (ModelResourceID) -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var surfaceActive = false
    @State private var dropGeneration = UUID()
    @State private var storage: ModelStorageKind = .external
    private func t(_ key: String) -> String { workflowText(language, "modelManagement." + key) }
    private var entry: ModelCatalogEntry? { model.catalog.first { $0.id == model.localFileSelection?.catalogID } }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if knownSource == nil {
                Button(t("chooseFolder")) { Task { await model.chooseLocalFiles(acceptsResult: { surfaceActive }) } }
                    .disabled(model.isChoosingLocation || model.globalOperation != nil)
            }
            if model.localFileChoices.count > 1 {
                WorkbenchPicker(t("local.chooseModel"), selection: Binding(get: { model.localFileSelection?.catalogID ?? "" }, set: model.selectLocalCandidate)) {
                    WorkbenchChoice(t("local.chooseModel"), value: "")
                    WorkbenchChoiceForEach(model.catalog.filter { entry in model.localFileChoices.contains { $0.catalogID == entry.id } }) { WorkbenchChoice($0.title, value: $0.id) }
                }.disabled(model.globalOperation != nil)
            }
            if let selection = model.localFileSelection, let entry {
                Text(entry.title).font(.headline)
                Text(selection.directory.path).font(.caption).textSelection(.enabled)
                Picker(t("local.usage"), selection: $storage) {
                    Text(t("local.original")).tag(ModelStorageKind.external).disabled(!selection.supportsOriginal)
                    Text(t("local.copy")).tag(ModelStorageKind.managed)
                }.pickerStyle(.radioGroup).disabled(model.globalOperation != nil)
                if !selection.supportsOriginal { Text(t("local.originalUnsupported")) }
                Text(t(storage == .external ? "local.originalHelp" : "local.copyHelp"))
                if storage == .managed {
                    Text(model.rootURL?.path ?? t("noRoot")).font(.caption).textSelection(.enabled)
                    Button(t("local.changeLocation")) { Task { await model.chooseRoot() } }.disabled(!model.canChooseRoot)
                    if !selection.prepared && entry.preparation != .none { Text(t(entry.id == "wan21-t2v-1.3b-bf16" ? "local.conversionHelp" : "local.packagingHelp")) }
                    if let bytes = selection.estimatedBytes { Text(workflowText(language, "modelManagement.local.size", arguments: ["size": ModelLibraryModel.formatBytes(bytes)])).font(.caption) }
                    Text(t("local.spaceUnknown")).font(.caption)
                }
                if entry.workflowProfileID == "d.music.ace-step-1.5-xl-sft" { Text(t("local.aceDerived")).font(.caption) }
                Text(t("local.noGeneration")).font(.caption).foregroundStyle(.secondary)
                Button(t("local.add")) {
                    guard let submission = model.captureLocalSubmission(matching: knownSource) else { return }
                    let selectedStorage = storage
                    Task {
                        if let result = await model.submitLocalFiles(submission, storage: selectedStorage),
                           surfaceActive, model.isCurrentLocalSubmission(submission) { onComplete(result) }
                    }
                }
                    .buttonStyle(WorkbenchPrimaryButtonStyle())
                    .disabled(model.globalOperation != nil || model.hasActiveWork || (storage == .external && !selection.supportsOriginal) || (storage == .managed && model.rootURL == nil))
                    .accessibilityIdentifier("model-local-submit")
            }
            if model.globalOperation != nil { ProgressView(); Button(t("cancel")) { model.cancelImport() } }
            if let error = model.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(20).frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        }
        // The whole scrolling form is the destination, including empty viewport space.
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers, _ in
            guard knownSource == nil, surfaceActive, providers.count == 1, let provider = providers.first,
                  !model.isChoosingLocation, model.globalOperation == nil else { return false }
            guard let intent = model.beginLocalInspection() else { return false }
            let generation = UUID(); dropGeneration = generation
            Task { @MainActor in
                do {
                    let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                            if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                        }
                    }
                    guard surfaceActive, dropGeneration == generation, model.isCurrentLocalInspection(intent),
                          !model.isChoosingLocation, model.globalOperation == nil else { return }
                    await model.chooseLocalFiles(at: try Self.droppedFileURL(bytes), inspectionID: intent,
                                                acceptsResult: { surfaceActive && dropGeneration == generation })
                } catch {
                    if surfaceActive, dropGeneration == generation, model.isCurrentLocalInspection(intent) { model.errorMessage = error.localizedDescription }
                }
            }
            return true
        }
        .task(id: knownSource?.id) {
            if let knownSource, let directory = knownSource.directory {
                await model.chooseLocalFiles(at: directory, catalogID: knownSource.catalogID, revision: knownSource.revision, acceptsResult: { surfaceActive })
            }
        }
        .onAppear { surfaceActive = true }
        .onChange(of: model.isChoosingLocation) { _, choosing in if choosing { dropGeneration = UUID() } }
        .onDisappear { surfaceActive = false; dropGeneration = UUID() }
        .workbenchCloseProtection(isDirty: model.globalOperation == nil && (model.localFileSelection != nil || !model.localFileChoices.isEmpty))
    }
    static func droppedFileURL(_ bytes: Data) throws -> URL {
        guard let url = URL(dataRepresentation: bytes, relativeTo: nil), url.isFileURL,
              let path = (url as NSURL).filePathURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return path
    }

}
