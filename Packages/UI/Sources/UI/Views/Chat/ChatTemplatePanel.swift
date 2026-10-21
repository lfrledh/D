import SwiftUI
import DWorkbench
import DInference

/// Explicit CPU preview, never runs or installs a language model.
struct ChatTemplatePanel: View {
    let chat: ChatController
    let sessionID: UUID
    @State private var result: TextTemplatePreview?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowText(language, "chat.templatePanel.templateAndTokenPreview")).font(.headline)
            Text(workflowText(language, "chat.templatePanel.readsTheInstalledTokenizerOnlyMediaPlaceholdersPrecedeVisionProcessing"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(workflowText(language, "chat.templatePanel.previewCurrentRequest")) {
                    error = nil; result = nil
                    task = Task { @MainActor in
                        defer { task = nil }
                        do { result = try await chat.previewTemplate(sessionID: sessionID) }
                        catch is CancellationError {} catch { self.error = error.localizedDescription }
                    }
                }.disabled(task != nil).accessibilityIdentifier("chat-preview-template")
                if task != nil { Button(workflowText(language, "chat.templatePanel.cancelPreview")) { task?.cancel() } }
                Button(workflowText(language, "chat.templatePanel.useModelTemplate")) {
                    do {
                        guard var node = chat.state.sessions.first(where: { $0.id == sessionID })?.configuration else { return }
                        node.parameters["chatTemplateOverride"] = .text("")
                        try chat.updateConfiguration(node, sessionID: sessionID); result = nil
                    } catch { self.error = error.localizedDescription }
                }.disabled(task != nil)
            }
            if let error { Text(ChatErrorText.display(error, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            if let result {
                DisclosureGroup(workflowText(language, "chat.templatePanel.installedSource")) {
                    ScrollView { Text(result.sourceTemplate).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                }
                DisclosureGroup(workflowText(language, "chat.templatePanel.renderedRequest")) {
                    ScrollView { Text(result.renderedTemplate).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                }
                Text(workflowText(language, "chat.templatePanel.templateTokens") + String(result.templateTokenIDs.count))
                Text(result.diagnostics.joined(separator: "\n")).font(.caption).textSelection(.enabled)
            }
        }.onChange(of: chat.state.sessions.first(where: { $0.id == sessionID })) { _, _ in
            task?.cancel(); result = nil; error = nil
        }.onDisappear { task?.cancel() }
    }
}
