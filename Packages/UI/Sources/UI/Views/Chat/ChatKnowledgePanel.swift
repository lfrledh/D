import DWorkbench
import SwiftUI

/// A view onto the existing project chat owner. It has no independent asset store.
struct ChatKnowledgePanel: View {
    let chat: ChatController
    let session: ChatSession
    let importDocuments: () -> Void
    let preview: (WorkflowAssetReference) -> Void
    let wording: (String, String) -> String
    @State private var query = ""
    @State private var result: ChatKnowledgeSearchResult?
    @State private var issue: String?
    @State private var task: Task<Void, Never>?
    @State private var ticket: UUID?

    var body: some View {
        DisclosureGroup(wording("Knowledge sources · lexical search", "资料来源 · 词法检索")) {
            VStack(alignment: .leading, spacing: 8) {
                Button(wording("Add documents…", "添加资料…"), action: importDocuments)
                Text(wording("Choose the scope. Only excerpts you adopt are sent; this is not vector search.",
                    "先选择范围；仅发送您采用的片段。这不是向量语义检索。"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(chat.state.knowledgeDocuments ?? []) { document in
                    HStack {
                        Toggle(document.material.name, isOn: Binding(get: {
                            session.knowledgeScope?.contains(document.id) == true
                        }, set: { enabled in
                            change {
                                var scope = session.knowledgeScope ?? []
                                scope.removeAll { $0 == document.id }
                                if enabled { scope.append(document.id) }
                                try chat.setKnowledgeScope(scope, sessionID: session.id)
                            }
                        }))
                        Menu {
                            Button(wording("View original", "查看原件")) { preview(document.material.reference) }
                            Button(wording("Remove from search collection", "移出检索集合")) {
                                change { try chat.removeKnowledgeDocument(document.id) }
                            }
                        } label: { Image(systemName: "ellipsis") }
                            .accessibilityLabel(wording("Source actions", "资料操作") + " · " + document.material.name)
                    }
                }
                TextField(wording("Search selected sources", "检索选定资料"), text: $query)
                    .accessibilityIdentifier("chat-knowledge-query")
                HStack {
                    Button(wording("Search", "检索")) { search() }
                        .disabled(task != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if task != nil {
                        Button(wording("Stop search", "停止检索")) { stop() }
                        ProgressView().controlSize(.small)
                    }
                }
                if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
                if let result {
                    ForEach(result.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    if result.excerpts.isEmpty { Text(wording("No matching excerpt", "没有匹配片段")).font(.caption) }
                    ForEach(result.excerpts) { excerpt in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(excerpt.name + position(excerpt)).font(.caption.bold())
                            Text(excerpt.text).font(.caption).textSelection(.enabled)
                            HStack {
                                Button(wording("Use excerpt", "采用片段")) {
                                    change {
                                        var chosen = chat.state.sessions.first { $0.id == session.id }?.knowledgeExcerpts ?? []
                                        if !chosen.contains(where: { $0.id == excerpt.id }) { chosen.append(excerpt) }
                                        try chat.useKnowledgeExcerpts(chosen, sessionID: session.id)
                                    }
                                }
                                Button(wording("Original", "原件")) { preview(excerpt.source) }
                            }
                        }.padding(.vertical, 6)
                    }
                }
                ForEach(session.knowledgeExcerpts ?? []) { excerpt in
                    HStack {
                        Text(wording("Next request: ", "下次发送：") + excerpt.name + position(excerpt)).font(.caption)
                        Button(wording("Remove", "移除")) {
                            change { try chat.useKnowledgeExcerpts((session.knowledgeExcerpts ?? []).filter { $0.id != excerpt.id }, sessionID: session.id) }
                        }
                    }
                }
            }.padding(.top, 6)
        }.accessibilityIdentifier("chat-knowledge-panel")
            .onDisappear { stop() }
    }
    private func position(_ excerpt: ChatKnowledgeExcerpt) -> String {
        if let page = excerpt.page { return wording(" · page ", " · 页 ") + String(page) }
        if let line = excerpt.line { return wording(" · line ", " · 行 ") + String(line) }
        return " · UTF-16 \(excerpt.utf16Offset)"
    }
    private func change(_ action: () throws -> Void) {
        do { try action(); issue = nil } catch { issue = error.localizedDescription }
    }
    private func stop() { task?.cancel(); task = nil; ticket = nil }
    private func search() {
        stop(); let current = UUID(), input = query, owner = session.id
        ticket = current; issue = nil; result = nil
        task = Task { @MainActor in
            defer { if ticket == current { task = nil } }
            do {
                let found = try await chat.searchKnowledge(input, sessionID: owner)
                guard ticket == current, chat.state.selectedSessionID == owner else { return }
                result = found
            } catch is CancellationError {} catch {
                if ticket == current { issue = error.localizedDescription }
            }
        }
    }
}
