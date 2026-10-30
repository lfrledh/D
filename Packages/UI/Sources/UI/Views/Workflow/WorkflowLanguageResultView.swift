import AppKit
import DWorkbench
import SwiftUI

/// The same region displays the active prefix, terminal handoff and persisted
/// asset. A failed save never makes the in-memory terminal handoff disappear.
struct WorkflowLanguageResultView: View {
    let store: ProjectStore
    let reference: WorkflowAssetReference?
    var transient: WorkflowLanguageContent? = nil
    var streaming = ""
    var end: WorkflowLanguageEnd? = nil
    var pendingSave = false
    @State private var loaded: WorkflowLanguageContent?
    @State private var readFailure: String?
    @Environment(\.dLanguageStore) private var language
    private var content: WorkflowLanguageContent? { transient ?? loaded }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let content {
                let response = content.response
                if let answer = response?.finalText, !answer.isEmpty {
                    Text(answer).textSelection(.enabled)
                } else if content.reasoningOnly, let reasoning = response?.reasoningText {
                    Text(workflowText(language, "partial.reasoning")).font(.caption).foregroundStyle(.secondary)
                    Text(reasoning).textSelection(.enabled)
                } else if !content.rawText.isEmpty {
                    Text(workflowText(language, "partial.raw")).font(.caption).foregroundStyle(.secondary)
                    Text(content.rawText).textSelection(.enabled)
                }
                if let end = end ?? content.end, end.interrupted {
                    Text(workflowText(language, PartialOutputPresentation.key(end, reasoningOnly: content.reasoningOnly)))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(workflowText(language, "partial.contract")).font(.caption).foregroundStyle(.secondary)
                }
                if pendingSave { Text(workflowText(language, "partial.notSaved")).font(.caption).foregroundStyle(.red) }
                HStack(spacing: 4) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(response?.finalText?.isEmpty == false ? response!.finalText! : content.rawText, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 16)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help(workflowText(language, "partial.copy"))
                    .accessibilityLabel(workflowText(language, "partial.copy"))
                    DisclosureGroup(workflowText(language, "partial.details")) {
                        Text(content.rawText).textSelection(.enabled)
                        if let diagnostic = (end ?? content.end)?.diagnostic { Text(diagnostic).font(.caption).textSelection(.enabled) }
                    }.font(.caption)
                }
            } else if !streaming.isEmpty {
                Text(streaming).textSelection(.enabled)
            } else if let readFailure { WorkbenchIssueText(raw: readFailure).font(.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reference) {
            loaded = nil; readFailure = nil
            guard let reference else { return }
            do { let value = try await store.workflowLanguageContent(reference); try Task.checkCancellation(); loaded = value }
            catch is CancellationError { }
            catch { readFailure = error.localizedDescription }
        }
    }
}

enum PartialOutputPresentation {
    static func key(_ end: WorkflowLanguageEnd, reasoningOnly: Bool) -> String {
        end.noticeKey(reasoningOnly: reasoningOnly)
    }
}
