import DInference
import DWorkbench
import SwiftUI

struct ProjectImageCandidateDetails: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Bindable var model: WorkbenchModel
    let asset: ProjectAsset
    let edit: () -> Void
    private var ownerID: UUID? { model.manifest?.jobs.first(where: { $0.id == asset.jobID })?.documentID }
    private var ownerName: String {
        model.documents.first(where: { $0.id == ownerID })?.name ?? workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.91")
    }
    private var adoptionActionTitle: String {
        workflowText(legacyLanguage, model.documents.contains(where: { $0.adoptedAssetID == asset.id })
            ? "consistency.legacy.GenerationInspector.92" : "consistency.remaining.6f6004072ae7")
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
                Label(adoptionActionTitle + " · " + ownerName, systemImage: "checkmark.seal")
            }
            .accessibilityIdentifier("adopt-candidate")
            Text(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.97"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ProjectImageMetadataEditor: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Environment(\.workbenchChildClose) private var closeGate
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
                Button(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.33"), role: .cancel) { if let closeGate { closeGate.requestClose() } else { isPresented = false } }.keyboardShortcut(.cancelAction)
                Button(workflowText(legacyLanguage, "consistency.legacy.GenerationInspector.54")) {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await saveDraft()
                            isPresented = false
                        } catch { saveError = error.localizedDescription }

                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-candidate")
            }
        }.padding(24).frame(width: 360)
            .disabled(saving).interactiveDismissDisabled()
            .workbenchCloseProtection(isDirty: name != originalName || note != originalNote, isSaving: saving, save: { try await saveDraft() })
    }
    private func saveDraft() async throws {
        guard let owner, let baseline else { throw WorkflowIssue("作品所属实例不可访问，草稿保留。") }
        try await model.projectSession.saveAssetAnnotations(owner: owner, expected: baseline,
            name: name.utf8.elementsEqual(baseline.name.utf8) ? nil : name,
            note: note.utf8.elementsEqual(baseline.note.utf8) ? nil : note)
    }

}
