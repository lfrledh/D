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
    @Environment(\.dLanguageStore) private var copyLanguage
    let wording: (String, String) -> String
    @State private var query = ""
    @State private var result: ChatKnowledgeSearchResult?
    @State private var issue: String?
    @State private var task: Task<Void, Never>?
    @State private var ticket: UUID?
    @State private var rerankBudget = "512"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowText(copyLanguage, "chat.knowledgePanel.findMaterialsByKeywords")).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup(workflowText(copyLanguage, "chat.knowledgePanel.howMatchingWorks")) {
                    Text(workflowText(copyLanguage, "chat.knowledgePanel.matchesKeywordsLexicallyItIsNotVectorSearchSelectingA")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(workflowText(copyLanguage, "chat.knowledgePanel.addDocuments"), action: importDocuments)
                    Button(workflowText(copyLanguage, "chat.knowledgePanel.chooseFolder"), action: importDirectory)
                }
                if !chat.ownsPersonalMemory && !chat.isTemporary {
                    DisclosureGroup(workflowText(copyLanguage, "chat.knowledgePanel.personalCollectionExplicitCopies")) {
                        Text(workflowText(copyLanguage, "chat.knowledgePanel.chooseSourcesToCopyIntoThisProjectExistingProjectCopies"))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(chat.personalKnowledgeDocuments) { item in
                            Button(item.material.name) { copy(item.id, toPersonal: false) }
                        }
                    }
                }
                Text(workflowText(copyLanguage, "chat.knowledgePanel.chooseTheScopeOnlyExcerptsYouAdoptAreSentThis"))
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
                        WorkbenchMenu {
                            WorkbenchMenuAction(workflowText(copyLanguage, "chat.quoteSelection")) { quote(document.id) }
                            WorkbenchMenuAction(workflowText(copyLanguage, "chat.sourceOriginal")) { preview(document.material.reference) }
                            if !chat.ownsPersonalMemory && !chat.isTemporary {
                                WorkbenchMenuAction(workflowText(copyLanguage, "chat.knowledgePanel.copyToPersonalCollection")) { copy(document.id, toPersonal: true) }
                            }
                            WorkbenchMenuAction(workflowText(copyLanguage, "chat.knowledgePanel.removeFromSearchCollection")) {
                                change { try chat.removeKnowledgeDocument(document.id) }
                            }
                        } label: { Image(systemName: "ellipsis") }
                            .accessibilityLabel(workflowText(copyLanguage, "chat.knowledgePanel.sourceActions") + " · " + document.material.name)
                    }
                }
                TextField(workflowText(copyLanguage, "chat.knowledgePanel.searchSelectedSources"), text: $query)
                    .accessibilityIdentifier("chat-knowledge-query")
                HStack {
                    Button(workflowText(copyLanguage, "chat.knowledgePanel.search")) { search() }
                        .disabled(task != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if task != nil {
                        Button(workflowText(copyLanguage, "chat.knowledgePanel.stopSearch")) { stop() }
                        ProgressView().controlSize(.small)
                    }
                }
                if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
                if let result {
                    if result.excerpts.count > 1 {
                        VStack(alignment: .leading) {
                            HStack {
                                TextField(workflowText(copyLanguage, "chat.knowledgePanel.outputTokenBudget"), text: $rerankBudget).frame(maxWidth: 130)
                                Button(workflowText(copyLanguage, "chat.knowledgePanel.reorderWithSelectedModel")) { reorder(result) }
                                    .disabled(task != nil || chat.isRerankingKnowledge || Int(rerankBudget) == nil || session.configuration == nil)
                            }
                            Text(workflowText(copyLanguage, "chat.knowledgePanel.explicitLocalInferenceOnlyOrderingChangesSourcesAreNotAdopted"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(result.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    if result.excerpts.isEmpty { Text(workflowText(copyLanguage, "chat.knowledgePanel.noMatchingExcerpt")).font(.caption) }
                    ForEach(result.excerpts) { excerpt in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(excerpt.name + position(excerpt)).font(.caption.bold())
                            Text(excerpt.text).font(.caption).textSelection(.enabled)
                            HStack {
                                Button(workflowText(copyLanguage, "chat.knowledgePanel.useExcerpt")) {
                                    change {
                                        var chosen = chat.state.sessions.first { $0.id == session.id }?.knowledgeExcerpts ?? []
                                        if !chosen.contains(where: { $0.id == excerpt.id }) { chosen.append(excerpt) }
                                        try chat.useKnowledgeExcerpts(chosen, sessionID: session.id)
                                    }
                                }
                                Button(workflowText(copyLanguage, "chat.knowledgePanel.original")) { preview(excerpt.source) }
                            }
                        }.padding(.vertical, 6)
                    }
                }
                if chat.pendingKnowledgeRerankSaveID != nil {
                    Button(workflowText(copyLanguage, "chat.knowledgePanel.retrySavingRawOrderingNoInference")) {
                        Task { do { try await chat.retryKnowledgeRerankSave() } catch { issue = error.localizedDescription } }
                    }.disabled(chat.isRerankingKnowledge)
                }
                if let last = session.knowledgeReranks?.last {
                    DisclosureGroup(workflowText(copyLanguage, "chat.knowledgePanel.lastModelOrdering")) {
                        Text(workflowText(language, "chat.ordering.status." + last.status.rawValue)).font(.caption)
                        Text(last.query).textSelection(.enabled)
                        if let issue = last.issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red) }
                        Text(last.node.operationID).font(.caption)
                        if let output = last.output { Button(workflowText(copyLanguage, "chat.knowledgePanel.rawOutput")) { preview(output) } }
                    }
                }
                ForEach(session.knowledgeExcerpts ?? []) { excerpt in
                    HStack {
                        Text(workflowText(copyLanguage, "chat.knowledgePanel.nextRequest") + excerpt.name + position(excerpt)).font(.caption)
                        Button(workflowText(copyLanguage, "baseline02.ui.label.6135d4159e89")) {
                            change { try chat.useKnowledgeExcerpts((session.knowledgeExcerpts ?? []).filter { $0.id != excerpt.id }, sessionID: session.id) }
                        }
                    }
                }
            }.padding(.top, 6)
        }.accessibilityIdentifier("chat-knowledge-panel")
            .onDisappear { stop() }
    }
    private func position(_ excerpt: ChatKnowledgeExcerpt) -> String {
        if let page = excerpt.page { return workflowText(copyLanguage, "chat.knowledgePanel.page") + String(page) }
        if let line = excerpt.line { return workflowText(copyLanguage, "chat.knowledgePanel.line") + String(line) }
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
