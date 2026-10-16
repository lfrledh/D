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
        } label: { Label(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.191", fallback: "PNG Recipe Handoff"), systemImage: "doc.text.magnifyingglass") }
        .accessibilityIdentifier("png-recipe-handoff")
        .disabled(model.isChangingProject || model.isBusy || model.hasPendingEditor)
        .sheet(isPresented: $presented, onDismiss: { model.endEditing() }) {
            RecipeHandoffView(model: model, expectedProjectID: projectID, assetID: assetID)
        }
    }
}

private struct RecipeHandoffView: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    let model: WorkbenchModel
    let expectedProjectID: UUID?
    let assetID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var privateArchive = false
    @State private var prepared: Data?
    @State private var inspection: PNGRecipeInspection?
    @State private var imported = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.191", fallback: "PNG Recipe Handoff")).font(.title2.bold())
            Text(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.192", fallback: "Save a new copy with a recipe, or read a PNG offline. External claims are for reference only; nothing runs and no models are downloaded automatically."))
                .foregroundStyle(.secondary)
            HStack {
                Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.193", fallback: "Read PNG…")) { Task { await readPNG() } }
                    .accessibilityIdentifier("read-recipe-png")
                if assetID != nil {
                    Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.194", fallback: "Prepare from Selected Work")) { Task { await prepare() } }
                        .accessibilityIdentifier("prepare-recipe-png")
                    Toggle(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.195", fallback: "Private Archive (Includes Prompts)"), isOn: $privateArchive)
                        .onChange(of: privateArchive) { _, _ in prepared = nil; inspection = nil; imported = false }
                }
            }.disabled(busy)
            if let recipe = inspection?.recipe {
                Text(imported ? workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.196", fallback: "External File Claims: Unverified") : workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.197", fallback: "Export Snapshot: Not Authenticated by a Signature")).font(.headline)
                Text(consistencyText(legacyLanguage, "copy.RecipeHandoffView.0", arguments: ["v0": String(describing: recipe.assetID.uuidString), "v1": String(describing: recipe.assetVersion.uuidString), "v2": String(describing: recipe.runID.uuidString)]))
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(imported ? workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.198", fallback: "Source fields remain external claims. They do not establish trust in a model or links embedded in the file.") : workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.199", fallback: "The asset version identifies a new snapshot created for this export. It is not a historical version previously recorded in the project."))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(json(recipe)).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(minHeight: 220).background(.background, in: RoundedRectangle(cornerRadius: 8))
                Text(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.200", fallback: "Only a recognized prompt and seed can be restored into a new draft. Other parameters and models are not restored automatically. You must explicitly start any generation using supported settings."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.201", fallback: "No Recipe Available"), systemImage: "doc.questionmark",
                    description: Text(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.202", fallback: "Prepare the selected work for export, or read a PNG containing a D recipe.")))
                    .frame(minHeight: 220)
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if imported {
                    Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.203", fallback: "Create New Draft")) { Task { await createDraft() } }
                        .disabled(busy || !canCreateDraft).accessibilityIdentifier("recipe-new-draft")
                } else {
                    Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.204", fallback: "Save PNG Copy…")) { Task { await savePNG() } }
                        .disabled(busy || prepared == nil).accessibilityIdentifier("save-recipe-png")
                }
                Button(workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.205", fallback: "Done")) { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 740, height: 620)
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
              let text = String(data: pretty, encoding: .utf8) else { return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.206", fallback: "The recipe could not be displayed.") }
        return text
    }
    private func errorText(_ error: Error) -> String {
        if let error = error as? PNGRecipeError {
            switch error {
            case .privacyConflict: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.207", fallback: "The image contains additional metadata whose privacy this tool cannot guarantee. Public export was refused, and the original was kept. You can explicitly choose a private archive.")
            case .sizeLimitExceeded: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.208", fallback: "The PNG or recipe exceeds this version's reading limit. The original has been kept.")
            case .unsupportedPNG, .unsupportedRecipe: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.209", fallback: "This PNG or recipe encoding is not supported. No external content was installed or executed.")
            case .duplicateRecipe: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.210", fallback: "The PNG contains conflicting recipes and was not read.")
            case .invalidPNG, .invalidRecipe: return workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.211", fallback: "The image or recipe is damaged, uses an unsupported version, or has inconsistent digests or dimensions. The original has been kept.")
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
            message = privateArchive ? workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.212", fallback: "Prompts will be included. Review the actual fields above before saving a copy.") : workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.213", fallback: "The public recipe hides prompts and structured input sources. It does not redact the image itself.")
        } catch { message = errorText(error) }
    }
    private func savePNG() async {
        guard !busy, let data = prepared else { return }
        busy = true; defer { busy = false }
        let panel = NSSavePanel(); panel.title = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.214", fallback: "Save PNG Copy with Recipe")
        panel.nameFieldStringValue = "D-recipe-\(UUID().uuidString.prefix(8)).png"
        panel.allowedContentTypes = [.png]
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            try await Task.detached { try ProjectStore.publishRecipePNG(data, to: url) }.value
            message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.215", fallback: "A new copy has been saved. The original image and any existing file with the same name were not overwritten.")
        } catch { message = errorText(error) }
    }
    private func readPNG() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let panel = NSOpenPanel(); panel.title = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.216", fallback: "Read PNG Recipe")
        panel.allowedContentTypes = [.png]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        prepared = nil; inspection = nil; imported = true; message = nil
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            let (_, result) = try await Task.detached { try ProjectStore.readRecipePNG(at: url) }.value
            inspection = result
            if result.recipe == nil { message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.217", fallback: "The image can be read, but it contains no D recipe.") }
            else if !canCreateDraft { message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.218", fallback: "The recipe prompt is missing, hidden or unavailable, so it cannot be restored into a new draft. You can inspect the other source fields.") }
            else { message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.219", fallback: "Read offline. The original file is unchanged. You can explicitly create a new draft.") }
        } catch { message = errorText(error) }
    }
    private func createDraft() async {
        guard !busy, canCreateDraft, let recipe = inspection?.recipe, let expectedProjectID else { return }
        busy = true; defer { busy = false }
        if await model.projectSession.createRecipeDocument(recipe, expectedProjectID: expectedProjectID) {
            message = workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.220", fallback: "A separate new draft has been saved. The original creation was not overwritten."); dismiss()
        } else { message = model.errorMessage ?? workflowText(legacyLanguage, "consistency.legacy.RecipeHandoffView.221", fallback: "The project changed. The external recipe was not applied.") }
    }
}
