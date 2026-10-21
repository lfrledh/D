import DWorkbench
import SwiftUI

struct ChatQuoteSheet: View {
    let chat: ChatController
    let sessionID: UUID
    let source: ChatQuoteSource
    let onSaved: () -> Void
    var onKeep: ((WorkflowAssetReference, Bool, UUID) async throws -> Void)? = nil
    let onClose: () -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var task: Task<Void, Never>?
    @State private var issue: String?
    @State private var publication = ChatQuotePublication()
    var body: some View {
        let presetInstruction = chat.state.sessions.first { $0.id == sessionID }?.selectionInstruction
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(workflowText(language, "chat.quoteSheet.selectTextToQuote")).font(.headline)
                Spacer()
                Button(workflowText(language, "workflow.action.close")) { task?.cancel(); onClose() }.keyboardShortcut(.cancelAction)
            }
            Text(workflowText(language, "chat.quoteSheet.thisAddsAnEditableQuotationToTheOriginalConversationNothing"))
                .font(.caption).foregroundStyle(.secondary)
            if let presetInstruction {
                Text(workflowText(language, "chat.quoteSheet.appliedSelectionInstruction") + presetInstruction)
                    .font(.caption).textSelection(.enabled)
            }
            ChatQuoteSelectionView(source: source) { selection, action in
                guard task == nil else { return }
                let defaultInstruction: String = switch action {
                case .ask: workflowText(language, "chat.quoteSheet.myQuestionAboutThisQuotation")
                case .explain: workflowText(language, "chat.quoteSheet.explainThisQuotation")
                case .translate: workflowText(language, "chat.quoteSheet.translateThisQuotationInto")
                case .save, .workflow: ""
                case .rewrite: workflowText(language, "chat.quoteSheet.rewriteThisQuotationAsFollows")
                }
                let instruction = presetInstruction ?? defaultInstruction
                let publicationID = publication.id(for: selection)
                task = Task { @MainActor in
                    defer { task = nil }
                    do {
                        let activity = try chat.beginExternalActivity(); defer { chat.endExternalActivity(activity) }
                        if action == .save || action == .workflow {
                            let reference = try await chat.saveQuote(selection, sessionID: sessionID, assetID: publicationID)
                            try Task.checkCancellation()
                            if let onKeep { try await onKeep(reference, action == .workflow, activity) }
                            else if action == .workflow { throw WorkflowIssue("工作流交接入口不可用；选段已保留。") }
                        } else { try await chat.appendQuote(selection, instruction: instruction, sessionID: sessionID, assetID: publicationID) }
                        try Task.checkCancellation(); onSaved(); onClose()
                    } catch is CancellationError {} catch { issue = error.localizedDescription }
                }
            }.disabled(task != nil)
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
            if task != nil { ProgressView().controlSize(.small) }
        }.padding(20).frame(minWidth: 600, idealWidth: 800, minHeight: 400)
            .onDisappear { task?.cancel() }
    }
}
