import DWorkbench
import Observation
import SwiftUI

/// Local remembered names and stable aliases; deletion never changes the bound UUID.
struct SharedLibraryTagPresentation {
    private(set) var names: [UUID: String] = [:]
    private(set) var aliases: [UUID: Int] = [:]
    mutating func observe(tags: [UUID: SharedLibraryTag], requested: Set<UUID>) {
        for tag in tags.values { names[tag.id] = tag.name }
        for id in requested.union(tags.keys).sorted(by: { $0.uuidString < $1.uuidString }) where aliases[id] == nil {
            aliases[id] = aliases.count + 1
        }
    }
    func title(_ id: UUID, tags: [UUID: SharedLibraryTag], missing: String) -> String {
        if let tag = tags[id] { return tag.name }
        return missing + " · " + (names[id].map { $0 + " · " } ?? "") + String(aliases[id] ?? 0)
    }
}

@MainActor @Observable final class WorkflowResultQueryState {
    struct Identity: Hashable {
        let owner: ObjectIdentifier
        let assetGeneration: UInt64
        let references: [WorkflowAssetReference]
        @MainActor init(controller: WorkflowController, references: [WorkflowAssetReference]) {
            owner = ObjectIdentifier(controller.services.store); assetGeneration = controller.displayAssetGeneration; self.references = references
        }
    }
    var query = SharedLibraryQuery()
    var tagPresentation = SharedLibraryTagPresentation()
    private(set) var items: [WorkflowAssetReference: SharedLibraryItem] = [:]
    private(set) var identity: Identity?
    private(set) var failure: String?
    private(set) var isLoading = false
    private var generation: UUID?
    func invalidate() { generation = nil; identity = nil; items = [:]; failure = nil; isLoading = false }
    func load(identity: Identity, read: () async throws -> [ProjectAssetMetadataSnapshot]) async {
        let generation = UUID(); self.generation = generation
        if self.identity?.owner != identity.owner || self.identity?.references != identity.references { items = [:] }
        self.identity = identity; failure = nil; isLoading = true
        defer { if self.generation == generation { isLoading = false } }
        do {
            let values = try await read()
            guard !Task.isCancelled, self.generation == generation, self.identity == identity else { return }
            let byID = Dictionary(values.map { ($0.asset.id, $0) }, uniquingKeysWith: { first, _ in first })
            var updated: [WorkflowAssetReference: SharedLibraryItem] = [:]
            for reference in identity.references {
                guard let value = byID[reference.assetID], value.projectID == reference.projectID else { continue }
                // Ambiguous versions do not borrow another version's model or ancestry.
                let facts = value.record?.reference == reference ? value.facts : SharedLibraryAssetFacts(
                    projectID: value.projectID, instanceID: value.instanceID, note: value.asset.note, favorite: value.asset.isFavorite,
                    width: value.asset.metadata.width, height: value.asset.metadata.height, registeredAt: value.asset.createdAt,
                    occurrences: value.occurrences)
                updated[reference] = .init(key: "asset:" + reference.projectID.uuidString + ":" + reference.assetID.uuidString,
                    title: value.asset.name, detail: value.projectName, kind: .asset, contentKind: reference.kind, assetFacts: facts)
            }
            items = updated
        } catch {
            guard !Task.isCancelled, self.generation == generation, self.identity == identity else { return }
            failure = error.localizedDescription
        }
    }
    /// A result filter can outlive a tag. Keep every condition visible and removable
    /// without silently rewriting the draft, other conditions or Store history.
    static func tagConditions(_ ids: Set<UUID>, store: SharedLibraryStore,
                              missingLabel: String) -> [(id: UUID, title: String)] {
        ids.map { id in
            (id: id, title: store.metadata.tags[id]?.name ?? missingLabel)
        }.sorted { $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title < $1.title }
    }

    static func references(in value: WorkflowValue) -> [WorkflowAssetReference] {
        let values: [WorkflowAssetReference]
        switch value {
        case .asset(let reference): values = [reference]
        case .collection(let candidates): values = candidates.compactMap(\.asset)
        case .data(let datum): values = datum.assetReferences
        case .receipt: values = []
        }
        var seen = Set<WorkflowAssetReference>()
        return values.filter { seen.insert($0).inserted }
    }
    func keepsVisible(_ value: WorkflowValue, store: SharedLibraryStore?) -> Bool {
        // Unpublished failures and non-asset values carry decisions/diagnostics, not filterable assets.
        if case .collection(let candidates) = value, candidates.contains(where: { $0.asset == nil }) { return true }
        let assets = Self.references(in: value)
        return assets.isEmpty || assets.contains { matches($0, store: store) }
    }
    func matches(_ reference: WorkflowAssetReference, store: SharedLibraryStore?) -> Bool {
        guard let store else { return true }
        let item = items[reference] ?? SharedLibraryItem(key: "asset:" + reference.projectID.uuidString + ":" + reference.assetID.uuidString, title: reference.assetID.uuidString, kind: .asset, contentKind: reference.kind)
        return store.matches(item, query: query)
    }
}

struct WorkflowResultQueryControls: View {
    @Bindable var state: WorkflowResultQueryState
    let store: SharedLibraryStore
    let scope: SharedLibraryQueryScope?
    var scopeDescription: String? = nil
    @State private var expanded = false
    @State private var filters = false
    @State private var saveRequest: SharedLibrarySaveQueryRequest?
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String, _ en: String) -> String { metadataText(language, key, zh, en) }
    private var query: Binding<SharedLibraryQuery> { Binding(get: { state.query }, set: { var value = $0; value.scope = nil; state.query = value }) }
    private var token: String { String(describing: state.identity) + String(describing: scope) + String(describing: ObjectIdentifier(store)) }
    private var scopeTitle: String {
        scopeDescription ?? scope.map { SharedLibraryScopeSummary.readable($0, text: t) } ?? t("displayedResults", "当前显示的输出范围", "Currently displayed outputs")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(t("resultFilters", "筛选此范围的结果", "Filter results in this scope"), isExpanded: $expanded) {
                Text(scopeTitle).font(.caption)
                Text(t("localResults", "只筛选已保存资产；其他值、运行状态与待处理事项保持可见", "Filters saved assets only; other values, run status and pending decisions stay visible")).font(.caption2)
                TextField(t("searchResults", "搜索结果名称、说明和标签", "Search result names, notes & tags"), text: $state.query.text).textFieldStyle(WorkbenchGlassTextFieldStyle())
                HStack {
                    Button(t("filters", "筛选条件…", "Filter conditions…")) { filters = true }
                    Button(t("saveQuery", "保存此检索", "Save this query")) {
                        guard let scope else { return }
                        var captured = state.query; captured.scope = scope
                        saveRequest = .init(query: captured, scopeTitle: scopeTitle, tagTitles: Dictionary(uniqueKeysWithValues: captured.allTagIDs.union(captured.anyTagIDs).map { ($0, state.tagPresentation.title($0, tags: store.metadata.tags, missing: t("deletedTagCondition", "已删除的标签", "Deleted tag"))) }))
                    }.disabled(scope == nil)
                }
            }
            if !state.query.text.isEmpty {
                Button { state.query.text = "" } label: { Label(state.query.text, systemImage: "xmark.circle") }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
            }
            tagConditions(state.query.allTagIDs, path: \.allTagIDs, title: t("allTags", "同时包含标签", "Contains all tags"))
            tagConditions(state.query.anyTagIDs, path: \.anyTagIDs, title: t("anyTags", "至少包含一个标签", "Contains any tag"))
            SharedLibraryQuerySummary(query: state.query, remove: { state.query = $0 })
            if state.query.properties != nil && !state.isLoading && state.failure == nil {
                SharedLibraryPropertySummary(query: query, items: Array(state.items.values), context: .init(), store: store, fixedScopeDescription: scopeTitle)
            }
            if state.isLoading { Text(t("indexing", "正在读取当前结果的登记信息…", "Reading registered facts for these results…")) }
            else if let issue = state.failure { Text(issue).foregroundStyle(.orange) }
            else if state.identity == nil || state.items.count < (state.identity?.references.count ?? 0) {
                Text(t("incompleteIndex", "登记信息尚不完整；不把未知当作无结果。", "Registration information is incomplete; unknown does not mean no results."))
            } else {
                Text(t("uniqueAssets", "独立素材", "Distinct assets") + " \((state.identity?.references ?? []).filter { state.matches($0, store: store) }.count)/\(state.identity?.references.count ?? 0)")
            }
            if state.query != SharedLibraryQuery() {
                Button(t("clearQuery", "清除检索条件", "Clear query conditions")) { state.query = .init() }
            }
        }.font(.caption)
        .onAppear { rememberTags() }
        .onChange(of: store.metadata) { _, _ in rememberTags() }
        .onChange(of: state.query) { _, _ in rememberTags() }
        .popover(isPresented: $filters) {
            SharedLibraryFilterEditor(query: state.query, token: token, store: store, items: Array(state.items.values), context: .init(), allowsScopeEditing: false,
                current: { (state.query, token) }, apply: { query.wrappedValue = $0 }, close: { filters = false })
        }
        .sheet(item: $saveRequest) { request in SharedLibrarySaveQuerySheet(request: request, store: store) { saveRequest = nil } }
    }
    private func rememberTags() { state.tagPresentation.observe(tags: store.metadata.tags, requested: state.query.allTagIDs.union(state.query.anyTagIDs)) }
    private func tagConditions(_ ids: Set<UUID>, path: WritableKeyPath<SharedLibraryQuery, Set<UUID>>, title: String) -> some View {
        ForEach(WorkflowResultQueryState.tagConditions(ids, store: store, missingLabel: t("deletedTagCondition", "已删除的标签", "Deleted tag")), id: \.id) { condition in
            HStack {
                Button { state.query[keyPath: path].remove(condition.id) } label: { Label(title + ": " + state.tagPresentation.title(condition.id, tags: store.metadata.tags, missing: t("deletedTagCondition", "已删除的标签", "Deleted tag")), systemImage: "xmark.circle") }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
                if store.metadata.tags[condition.id] == nil { WorkflowTechnicalDetails(value: condition.id.uuidString) }
            }
        }
    }
}
