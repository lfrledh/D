import DWorkbench
import SwiftUI

/// The caller retains the selected security scope until this sheet closes.
struct ChatKnowledgeDirectorySheet: View {
    @Environment(\.dLanguageStore) private var language
    let inventory: ChatKnowledgeDirectoryInventory
    let wording: (String, String) -> String
    let importEntries: ([ChatKnowledgeDirectoryInventory.Entry]) async throws -> Void
    let close: () -> Void
    @State private var selected = Set<URL>()
    @State private var importing = false
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(wording("Choose documents to copy", "选择要复制的资料")).font(.headline)
            Text(wording("Only selected direct files are imported. Folders, links and unsupported files are excluded; nothing is read recursively.", "只导入勾选的直属文件，不递归读取。子目录、链接和未支持格式不会导入。"))
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
                Button(wording("Close", "关闭"), action: close).disabled(importing).keyboardShortcut(.cancelAction)
                Spacer()
                if importing { ProgressView().controlSize(.small) }
                Button(wording("Import selected copies", "导入选定副本")) {
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
        }.padding(20).frame(minWidth: 500, minHeight: 360).interactiveDismissDisabled(importing)
    }
}
