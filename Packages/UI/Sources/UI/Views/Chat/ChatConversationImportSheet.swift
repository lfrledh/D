import DWorkbench
import SwiftUI

/// All previews are inert. An archive entry and any mapping losses are chosen explicitly.
struct ChatConversationImportSheet: View {
    let data: Data
    let title: String
    let containsImport: (UUID) -> Bool
    let onClose: () -> Void
    let onAccept: (Int?, String, Bool, UUID) async throws -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var choices: [ChatOpenWebUIImport.ConversationChoice] = []
    @State private var selectedIndex = -1
    @State private var preview: ChatInterchange.ImportPreview?
    @State private var acceptLosses = false
    @State private var importID = UUID()
    @State private var saving = false
    @State private var issue: String?
    @State private var issueKey: String?
    @State private var pendingSave = false

    private func report(_ error: Error) {
        issue = error.localizedDescription
        issueKey = (error as? ChatInterchangeError).map { "chat.conversationImportSheet.error." + ($0.inputProblem?.rawValue ?? "structure") }
    }

    private func saveImport() async throws {
        guard let preview, !saving, preview.losses.isEmpty || acceptLosses else {
            throw ChatInterchangeError.invalid("Import preview or approval is unavailable.")
        }
        saving = true
        defer { saving = false }
        do {
            try await onAccept(preview.conversationIndex, preview.sourceTitle ?? title, acceptLosses, importID)
            pendingSave = false
        } catch {
            pendingSave = containsImport(importID)
            throw error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(workflowText(language, "chat.conversationImportSheet.importConversation")).font(.headline)
            Text(title)
            Text(workflowText(language, "chat.conversationImportSheet.summary"))
            DisclosureGroup(workflowText(language, "chat.conversationImportSheet.formats")) {
                Text(workflowText(language, "chat.conversationImportSheet.openWebUIHistoryDMappingV1OrDRoleContent"))
            }.font(.caption)
            if !choices.isEmpty {
                Text(workflowText(language, "chat.conversationImportSheet.activeBranch")).font(.caption)
            }
            if choices.count > 1 {
                WorkbenchPicker(workflowText(language, "chat.conversationImportSheet.conversation"), selection: $selectedIndex) {
                    WorkbenchChoice(workflowText(language, "chat.conversationImportSheet.chooseAConversation"), value:-1)
                    WorkbenchChoiceForEach(choices, id: \.index) { item in WorkbenchChoice(item.title, value:item.index) }
                }.disabled(saving || pendingSave).accessibilityIdentifier("chat-import-conversation-choice")
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
                            Text(workflowText(language, "chat.conversationImportSheet.lossIntro")).font(.caption)
                            ChatImportLossList(losses: preview.losses)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !preview.losses.isEmpty {
                    Toggle(workflowText(language, "chat.conversationImportSheet.iAcceptTheseLossesKeepTheSourceUnchanged"), isOn: $acceptLosses).disabled(saving || pendingSave)
                }
            } else { Spacer() }
            if let issue {
                if let issueKey {
                    Text(workflowText(language, issueKey)).foregroundStyle(.red)
                    DisclosureGroup(workflowText(language, "chat.conversationImportSheet.details")) { Text(issue).textSelection(.enabled) }
                } else { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            }
            HStack {
                WorkbenchRequestCloseButton(title: workflowText(language, "workflow.action.cancel"), fallback: onClose).disabled(saving)
                Spacer()
                Button(workflowText(language, pendingSave ? "chat.retrySave" : "chat.conversationImportSheet.createImportedConversation")) {
                    Task { @MainActor in
                        do { try await saveImport(); onClose() } catch { report(error) }
                    }
                }.disabled(saving || preview == nil || (preview?.losses.isEmpty == false && !acceptLosses))
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .workbenchCloseProtection(isDirty: pendingSave, isSaving: saving, allowsDiscard: false, save: { try await saveImport() })
        .task {
            do {
                choices = (try? ChatOpenWebUIImport.conversations(in: data)) ?? []
                if choices.count == 1 { selectedIndex = choices[0].index }
                else if choices.isEmpty { preview = try ChatInterchange.previewImport(data) }
            } catch { pendingSave = containsImport(importID); report(error) }
        }
        .onChange(of: selectedIndex) { _, index in
            // A different entry requires a new acceptance and retry identity.
            preview = nil; issue = nil; acceptLosses = false; importID = UUID()
            guard index >= 0 else { return }
            do { preview = try ChatInterchange.previewImport(data, selectedConversationIndex: index) }
            catch { pendingSave = containsImport(importID); report(error) }
        }
    }
}

struct ChatImportLossList: View {
    let losses: [ChatInterchange.Loss]
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        ForEach(losses.indices, id: \.self) { index in
            let loss = losses[index]
            VStack(alignment: .leading, spacing: 2) {
                if let number = loss.messageIndex, (0..<ChatInterchange.maximumMessages).contains(number) {
                    Text(workflowText(language, "chat.conversationImportSheet.sourceMessage", arguments: ["number": String(number + 1)]))
                }
                if let field = loss.field { Text(verbatim: field).font(.caption.monospaced()) }
                Text(workflowText(language, "chat.conversationImportSheet.loss." + loss.kind.rawValue,
                                  arguments: ["count": String(loss.count ?? 0)]))
                DisclosureGroup(workflowText(language, "chat.conversationImportSheet.details")) {
                    Text(verbatim: (loss.pointer ?? loss.location) + "\n" + loss.reason).textSelection(.enabled)
                }
            }.font(.caption)
        }
    }
}
