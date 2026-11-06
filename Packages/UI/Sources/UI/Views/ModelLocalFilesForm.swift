import DWorkbench
import SwiftUI

/// Folder, drop and restored-model entrances share one form and application owner.
/// Accepting it never selects a node or changes the current project.
struct ModelLocalFilesForm: View {
    @Bindable var model: ModelLibraryModel
    var knownSource: ProjectRestoredModel? = nil
    var onComplete: (ModelResourceID) -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var surfaceActive = false
    @State private var storage: ModelStorageKind = .external
    private func t(_ key: String) -> String { workflowText(language, "modelManagement." + key) }
    private var entry: ModelCatalogEntry? { model.catalog.first { $0.id == model.localFileSelection?.catalogID } }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if knownSource == nil {
                Button(t("chooseFolder")) { Task { await model.chooseLocalFiles() } }
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
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard knownSource == nil, urls.count == 1, let url = urls.first,
                      !model.isChoosingLocation, model.globalOperation == nil else { return false }
                Task { await model.chooseLocalFiles(at: url) }; return true
            }
        }
        .task(id: knownSource?.id) {
            if let knownSource, let directory = knownSource.directory {
                await model.chooseLocalFiles(at: directory, catalogID: knownSource.catalogID, revision: knownSource.revision)
            }
        }
        .onAppear { surfaceActive = true }
        .onDisappear { surfaceActive = false }
        .workbenchCloseProtection(isDirty: model.globalOperation == nil && (model.localFileSelection != nil || !model.localFileChoices.isEmpty))
    }
}
