import DWorkbench
import SwiftUI

/// A view onto the existing project chat owner. It has no independent asset store.
struct ChatKnowledgePanel: View {
    @Environment(\.dLanguageStore) private var language
    let chat: ChatController
    let session: ChatSession
    let quote: (UUID) -> Void
    let importDocuments: () -> Void
    let importDirectory: () -> Void
    let preview: (WorkflowAssetReference) -> Void
    let wording: (String, String) -> String
    @State private var query = ""
    @State private var result: ChatKnowledgeSearchResult?
    @State private var issue: String?
    @State private var task: Task<Void, Never>?
    @State private var ticket: UUID?
    @State private var rerankBudget = "512"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(wording("Find materials by keywords", "按关键词查找资料")).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup(wording("How matching works", "查找方式说明")) {
                    Text(wording("Matches keywords lexically; it is not vector search. Selecting a search scope does not send its content.", "使用关键词进行词法匹配，不是向量搜索。勾选检索范围不会发送其中内容。")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(wording("Add documents…", "添加资料…"), action: importDocuments)
                    Button(wording("Choose folder…", "选择文件夹…"), action: importDirectory)
                }
                if !chat.ownsPersonalMemory && !chat.isTemporary {
                    DisclosureGroup(wording("Personal collection · explicit copies", "个人资料库 · 显式复制")) {
                        Text(wording("Choose sources to copy into this project. Existing project copies do not change when the personal collection changes.", "选择要复制入本项目的资料。个人集合后来改变不会悄悄替换本项目副本。"))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(chat.personalKnowledgeDocuments) { item in
                            Button(item.material.name) { copy(item.id, toPersonal: false) }
                        }
                    }
                }
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
                            Button(wording("Quote a selection…", "选择片段引用…")) { quote(document.id) }
                            Button(wording("View original", "查看原件")) { preview(document.material.reference) }
                            if !chat.ownsPersonalMemory && !chat.isTemporary {
                                Button(wording("Copy to personal collection", "复制到个人资料库")) { copy(document.id, toPersonal: true) }
                            }
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
                if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
                if let result {
                    if result.excerpts.count > 1 {
                        VStack(alignment: .leading) {
                            HStack {
                                TextField(wording("Output token budget", "输出 token 预算"), text: $rerankBudget).frame(maxWidth: 130)
                                Button(wording("Reorder with selected model", "用所选模型重排")) { reorder(result) }
                                    .disabled(task != nil || chat.isRerankingKnowledge || Int(rerankBudget) == nil || session.configuration == nil)
                            }
                            Text(wording("Explicit local inference; only ordering changes. Sources are not adopted automatically.", "显式本地推理，只改变排序；不会自动采用资料。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
                if chat.pendingKnowledgeRerankSaveID != nil {
                    Button(wording("Retry saving raw ordering · no inference", "重试保存重排原文 · 不重推理")) {
                        Task { do { try await chat.retryKnowledgeRerankSave() } catch { issue = error.localizedDescription } }
                    }.disabled(chat.isRerankingKnowledge)
                }
                if let last = session.knowledgeReranks?.last {
                    DisclosureGroup(wording("Last model ordering", "上次模型重排")) {
                        Text(last.status.rawValue).font(.caption)
                        Text(last.query).textSelection(.enabled)
                        if let issue = last.issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red) }
                        Text(last.node.operationID).font(.caption)
                        if let output = last.output { Button(wording("Raw output", "原始输出")) { preview(output) } }
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
    private func stop() {
        task?.cancel(); task = nil; ticket = nil
        if chat.rerankingSessionID == session.id { Task { await chat.cancelKnowledgeRerank() } }
    }
    private func copy(_ id: UUID, toPersonal: Bool) {
        guard task == nil else { return }
        let current = UUID(); ticket = current; issue = nil
        task = Task { @MainActor in
            defer { if ticket == current { task = nil } }
            do { try await chat.copyKnowledgeDocument(id, toPersonal: toPersonal) }
            catch { if ticket == current { issue = error.localizedDescription } }
        }
    }
    private func reorder(_ source: ChatKnowledgeSearchResult) {
        guard let budget = Int(rerankBudget), task == nil else { return }
        let current = UUID(), owner = session.id, input = query
        ticket = current; issue = nil
        task = Task { @MainActor in
            defer { if ticket == current { task = nil } }
            do {
                let ordered = try await chat.rerankKnowledge(source.excerpts, query: input, sessionID: owner, maximumOutputTokens: budget)
                guard ticket == current, chat.state.selectedSessionID == owner, query == input else { return }
                result = ChatKnowledgeSearchResult(excerpts: ordered, issues: source.issues)
            } catch is CancellationError {} catch { if ticket == current { issue = error.localizedDescription } }
        }
    }
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
