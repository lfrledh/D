import DWorkbench
import SwiftUI

/// The caller retains the selected security scope until this sheet closes.
struct ChatKnowledgeDirectorySheet: View {
    @Environment(\.dLanguageStore) private var language
    let inventory: ChatKnowledgeDirectoryInventory
    @Environment(\.dLanguageStore) private var copyLanguage
    let wording: (String, String) -> String
    let importEntries: ([ChatKnowledgeDirectoryInventory.Entry]) async throws -> Void
    let close: () -> Void
    @State private var selected = Set<URL>()
    @State private var importing = false
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(workflowText(copyLanguage, "chat.knowledgeDirectorySheet.chooseDocumentsToCopy")).font(.headline)
            Text(workflowText(copyLanguage, "chat.knowledgeDirectorySheet.onlySelectedDirectFilesAreImportedFoldersLinksAndUnsupported"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                ForEach(inventory.entries) { entry in
                    Toggle(entry.name + " · \(entry.byteCount) B", isOn: Binding(get: { selected.contains(entry.url) }, set: {
                        if $0 { selected.insert(entry.url) } else { selected.remove(entry.url) }
                    })).disabled(importing)
                }
                ForEach(inventory.excluded, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                WorkbenchRequestCloseButton(title: workflowText(copyLanguage, "workflow.action.close"), fallback: close).disabled(importing).keyboardShortcut(.cancelAction)
                Spacer()
                if importing { ProgressView().controlSize(.small) }
                Button(workflowText(copyLanguage, "chat.knowledgeDirectorySheet.importSelectedCopies")) {
                    importing = true; issue = nil
                    let entries = inventory.entries.filter { selected.contains($0.url) }
                    Task { @MainActor in
                        defer { importing = false }
                        // Remove each completed item before a later failure. Retrying the
                        // remaining selection must not import successful copies again.
                        for entry in entries {
                            do { try await importEntries([entry]); selected.remove(entry.url) }
                            catch { issue = error.localizedDescription; break }
                        }
                    }
                }.disabled(importing || selected.isEmpty)
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .workbenchCloseProtection(isDirty: !selected.isEmpty, isSaving: importing).interactiveDismissDisabled(importing)
    }
}
