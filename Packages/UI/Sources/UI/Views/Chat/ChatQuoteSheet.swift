import DWorkbench
import SwiftUI

struct ChatQuoteSheet: View {
    let chat: ChatController
    let sessionID: UUID
    let source: ChatQuoteSource
    let onSaved: () -> Void
    let onClose: () -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var task: Task<Void, Never>?
    @State private var issue: String?
    @State private var publication = ChatQuotePublication()
    private func wording(_ en: String, _ zh: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(wording("Select text to quote", "选择要引用的文字")).font(.headline)
                Spacer()
                Button(wording("Close", "关闭")) { task?.cancel(); onClose() }.keyboardShortcut(.cancelAction)
            }
            Text(wording("This adds an editable quotation to the original conversation. Nothing is sent automatically.", "选段加入原会话的可编辑草稿，不自动发送，不替换原文。"))
                .font(.caption).foregroundStyle(.secondary)
            ChatQuoteSelectionView(source: source) { selection, action in
                guard task == nil else { return }
                let instruction: String = switch action {
                case .ask: wording("My question about this quotation: ", "关于这段引用，我的问题是：")
                case .explain: wording("Explain this quotation.", "请解释这段引用。")
                case .translate: wording("Translate this quotation into: ", "请将这段引用翻译为：")
                case .rewrite: wording("Rewrite this quotation as follows: ", "请按以下要求改写这段引用：")
                }
                let publicationID = publication.id(for: selection)
                task = Task { @MainActor in
                    defer { task = nil }
                    do {
                        try await chat.appendQuote(selection, instruction: instruction, sessionID: sessionID, assetID: publicationID)
                        try Task.checkCancellation(); onSaved(); onClose()
                    } catch is CancellationError {} catch { issue = error.localizedDescription }
                }
            }.disabled(task != nil)
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            if task != nil { ProgressView().controlSize(.small) }
        }.padding(20).frame(minWidth: 600, idealWidth: 800, minHeight: 400)
            .onDisappear { task?.cancel() }
    }
}
