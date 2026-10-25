import AppKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

/// One finite handoff sheet; does not open projects, run models or interpret imported instructions.
struct RecipeHandoffButton: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    @Bindable var model: WorkbenchModel
    @State private var presented = false
    @State private var projectID: UUID?
    @State private var assetID: UUID?

    var body: some View {
        Button {
            projectID = model.manifest?.id
            assetID = model.selectedAssetID
            model.beginEditing()
            presented = true
        } label: { Label(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.191"), systemImage: "doc.text.magnifyingglass") }
        .accessibilityIdentifier("png-recipe-handoff")
        .disabled(model.isChangingProject || model.isBusy || model.hasPendingEditor)
        .workbenchSheet(isPresented: $presented, title: workflowText(legacyLanguage, "childPanel.name.recipe"), onDismiss: { model.endEditing() }) {
            RecipeHandoffView(model: model, expectedProjectID: projectID, assetID: assetID)
        }
    }
}

private struct RecipeHandoffView: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    let model: WorkbenchModel
    let expectedProjectID: UUID?
    let assetID: UUID?
    @WorkbenchDismiss private var dismiss
    @State private var privateArchive = false
    @State private var prepared: Data?
    @State private var inspection: PNGRecipeInspection?
    @State private var imported = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.191")).font(.title2.bold())
            Text(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.192"))
                .foregroundStyle(.secondary)
            HStack {
                Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.193")) { Task { await readPNG() } }
                    .accessibilityIdentifier("read-recipe-png")
                if assetID != nil {
                    Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.194")) { Task { await prepare() } }
                        .accessibilityIdentifier("prepare-recipe-png")
                    Toggle(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.195"), isOn: $privateArchive)
                        .onChange(of: privateArchive) { _, _ in prepared = nil; inspection = nil; imported = false }
                }
            }.disabled(busy)
            if let recipe = inspection?.recipe {
                Text(imported ? workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.196") : workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.197")).font(.headline)
                Text(consistencyText(legacyLanguage, "copy.RecipeHandoffView.0", arguments: ["v0": String(describing: recipe.assetID.uuidString), "v1": String(describing: recipe.assetVersion.uuidString), "v2": String(describing: recipe.runID.uuidString)]))
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(imported ? workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.198") : workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.199"))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(json(recipe)).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(minHeight: 220).background(.background, in: RoundedRectangle(cornerRadius: 8))
                Text(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.200"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.201"), systemImage: "doc.questionmark",
                    description: Text(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.202")))
                    .frame(minHeight: 220)
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if imported {
                    Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.203")) { Task { await createDraft() } }
                        .disabled(busy || !canCreateDraft).accessibilityIdentifier("recipe-new-draft")
                } else {
                    Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.204")) { Task { await savePNG() } }
                        .disabled(busy || prepared == nil).accessibilityIdentifier("save-recipe-png")
                }
                Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.205")) { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .workbenchCloseProtection(isDirty: false, isSaving: busy)
        .interactiveDismissDisabled(busy)
    }

    private var canCreateDraft: Bool {
        guard let recipe = inspection?.recipe, case .value = recipe.prompt,
              expectedProjectID == model.manifest?.id else { return false }
        return true
    }
    private func json(_ recipe: GenerationRecipe) -> String {
        guard let data = try? GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive),
              let value = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.206") }
        return text
    }
    private func errorText(_ error: Error) -> String {
        if let error = error as? PNGRecipeError {
            switch error {
            case .privacyConflict: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.207")
            case .sizeLimitExceeded: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.208")
            case .unsupportedPNG, .unsupportedRecipe: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.209")
            case .duplicateRecipe: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.210")
            case .invalidPNG, .invalidRecipe: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.211")
            }
        }
        return error.localizedDescription
    }
    private func prepare() async {
        guard !busy, let assetID, expectedProjectID == model.manifest?.id else { return }
        busy = true; defer { busy = false }
        prepared = nil; inspection = nil; imported = false; message = nil
        do {
            let data = try await model.projectSession.prepareRecipePNG(assetID: assetID,
                disclosure: privateArchive ? .privateArchive : .publicShare)
            guard expectedProjectID == model.manifest?.id else { return }
            let result = try await Task.detached { try PNGRecipeCodec.inspect(data) }.value
            guard expectedProjectID == model.manifest?.id else { return }
            inspection = result; prepared = data
            message = privateArchive ? workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.212") : workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.213")
        } catch { message = errorText(error) }
    }
    private func savePNG() async {
        guard !busy, let data = prepared else { return }
        busy = true; defer { busy = false }
        let panel = NSSavePanel(); panel.title = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.214")
        panel.nameFieldStringValue = "D-recipe-\(UUID().uuidString.prefix(8)).png"
        panel.allowedContentTypes = [.png]
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            try await Task.detached { try ProjectStore.publishRecipePNG(data, to: url) }.value
            message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.215")
        } catch { message = errorText(error) }
    }
    private func readPNG() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let panel = NSOpenPanel(); panel.title = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.216")
        panel.allowedContentTypes = [.png]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        prepared = nil; inspection = nil; imported = true; message = nil
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            let (_, result) = try await Task.detached { try ProjectStore.readRecipePNG(at: url) }.value
            inspection = result
            if result.recipe == nil { message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.217") }
            else if !canCreateDraft { message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.218") }
            else { message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.219") }
        } catch { message = errorText(error) }
    }
    private func createDraft() async {
        guard !busy, canCreateDraft, let recipe = inspection?.recipe, let expectedProjectID else { return }
        busy = true; defer { busy = false }
        if await model.projectSession.createRecipeDocument(recipe, expectedProjectID: expectedProjectID) {
            message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.220"); dismiss()
        } else { message = model.errorMessage ?? workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.221") }
    }
}
