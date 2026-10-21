import DWorkbench
import SwiftUI

/// All previews are inert. An archive entry and any mapping losses are chosen explicitly.
struct ChatConversationImportSheet: View {
    let data: Data
    let title: String
    let onCancel: () -> Void
    let onAccept: (Int?, String, Bool, UUID) async throws -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var choices: [ChatOpenWebUIImport.ConversationChoice] = []
    @State private var selectedIndex = -1
    @State private var preview: ChatInterchange.ImportPreview?
    @State private var acceptLosses = false
    @State private var importID = UUID()
    @State private var saving = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(workflowText(language, "chat.conversationImportSheet.importConversation")).font(.headline)
            Text(title)
            Text(workflowText(language, "chat.conversationImportSheet.openWebUIHistoryDMappingV1OrDRoleContent"))
                .font(.caption).foregroundStyle(.secondary)
            if choices.count > 1 {
                WorkbenchPicker(workflowText(language, "chat.conversationImportSheet.conversation"), selection: $selectedIndex) {
                    WorkbenchChoice(workflowText(language, "chat.conversationImportSheet.chooseAConversation"), value:-1)
                    WorkbenchChoiceForEach(choices, id: \.index) { item in WorkbenchChoice(item.title, value:item.index) }
                }.disabled(saving).accessibilityIdentifier("chat-import-conversation-choice")
            }
            if let preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !preview.systemPrompt.isEmpty { Text(workflowText(language, "chat.role.system") + "\n" + preview.systemPrompt).textSelection(.enabled) }
                        ForEach(preview.messages.indices, id: \.self) { index in
                            VStack(alignment: .leading) {
                                Text(workflowText(language, "chat.role." + preview.messages[index].role.rawValue)).font(.caption.bold())
                                Text(preview.messages[index].text).textSelection(.enabled)
                            }
                        }
                        if !preview.losses.isEmpty {
                            Text(workflowText(language, "chat.conversationImportSheet.fieldsThatCannotBeImported")).font(.headline)
                            ForEach(preview.losses.indices, id: \.self) { index in
                                Text(preview.losses[index].location + ": " + preview.losses[index].reason).font(.caption)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !preview.losses.isEmpty {
                    Toggle(workflowText(language, "chat.conversationImportSheet.iAcceptTheseLossesKeepTheSourceUnchanged"), isOn: $acceptLosses).disabled(saving)
                }
            } else { Spacer() }
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(workflowText(language, "workflow.action.cancel"), action: onCancel).disabled(saving)
                Spacer()
                Button(workflowText(language, "chat.conversationImportSheet.createImportedConversation")) {
                    guard let preview else { return }
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do { try await onAccept(preview.conversationIndex, preview.sourceTitle ?? title, acceptLosses, importID) }
                        catch { issue = error.localizedDescription }
                    }
                }.disabled(saving || preview == nil || (preview?.losses.isEmpty == false && !acceptLosses))
            }
        }.padding(20).frame(minWidth: 580, idealWidth: 720, minHeight: 440, idealHeight: 600)
        .task {
            do {
                choices = (try? ChatOpenWebUIImport.conversations(in: data)) ?? []
                if choices.count == 1 { selectedIndex = choices[0].index }
                else if choices.isEmpty { preview = try ChatInterchange.previewImport(data) }
            } catch { issue = error.localizedDescription }
        }
        .onChange(of: selectedIndex) { _, index in
            // A different entry requires a new acceptance and retry identity.
            preview = nil; issue = nil; acceptLosses = false; importID = UUID()
            guard index >= 0 else { return }
            do { preview = try ChatInterchange.previewImport(data, selectedConversationIndex: index) }
            catch { issue = error.localizedDescription }
        }
    }
}
