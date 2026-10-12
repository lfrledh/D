import DWorkbench
import Observation
import SwiftUI

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
    @State private var filters = false
    @State private var saveName = ""
    @State private var failure: String?
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String, _ en: String) -> String { metadataText(language, key, zh, en) }
    private var query: Binding<SharedLibraryQuery> { Binding(get: { state.query }, set: { var value = $0; value.scope = nil; state.query = value }) }
    private var resultScopeTitle: String {
        guard let scope else { return t("displayedResults", "当前显示的输出范围", "Currently displayed outputs") }
        return (scope.runID.map { "Run " + $0.uuidString.prefix(8) } ?? "")
            + (scope.nodeID.map { " · Node " + $0.uuidString.prefix(8) } ?? "")
            + (scope.stepID.map { " · Call " + $0.uuidString.prefix(8) } ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t("localResults", "只筛选已保存资产；其他值、运行状态与待处理事项保持可见", "Filters saved assets only; other values, run status and pending decisions stay visible")).font(.caption2).foregroundStyle(.secondary)
            TextField(t("searchResults", "搜索结果名称、说明和标签", "Search result names, notes & tags"), text: $state.query.text).textFieldStyle(.roundedBorder)
            HStack {
                Menu(t("allTags", "同时包含标签", "Contains all tags")) {
                    ForEach(store.metadata.tags.values.sorted { $0.name < $1.name }) { tag in
                        Toggle(tag.name, isOn: Binding(get: { state.query.allTagIDs.contains(tag.id) }, set: { selected in
                            if selected { state.query.allTagIDs.insert(tag.id) } else { state.query.allTagIDs.remove(tag.id) }
                        }))
                    }
                }
                Button(t("filters", "属性与高级筛选", "Properties & advanced filters")) { filters = true }
                    .popover(isPresented: $filters) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                SharedLibraryPropertyControls(query: query, items: Array(state.items.values), context: .init(), allowsScopeEditing: false)
                                Menu(t("anyTags", "至少包含一个标签", "Contains any tag")) {
                                    ForEach(store.metadata.tags.values.sorted { $0.name < $1.name }) { tag in
                                        Toggle(tag.name, isOn: Binding(get: { state.query.anyTagIDs.contains(tag.id) }, set: { selected in
                                            if selected { state.query.anyTagIDs.insert(tag.id) } else { state.query.anyTagIDs.remove(tag.id) }
                                        }))
                                    }
                                }
                                if let scope {
                                    Text(t("saveBoundResults", "保存时绑定此运行/节点/调用的结果范围", "Saved query binds this run/node/call result scope")).font(.caption)
                                    TextField(t("queryName", "检索名称", "Query name"), text: $saveName)
                                    Button(t("saveQuery", "保存此检索", "Save this query")) {
                                        do { var saved = state.query; saved.scope = scope; _ = try store.createSavedQuery(name: saveName, query: saved); saveName = ""; failure = nil }
                                        catch { failure = error.localizedDescription }
                                    }.disabled(saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                            }.padding(14)
                        }.frame(width: 330, height: 520)
                    }
            }
            SharedLibraryPropertySummary(query: query, items: Array(state.items.values), context: .init(), store: store, fixedScopeDescription: resultScopeTitle)
            ForEach(store.metadata.tags.values.sorted { $0.name < $1.name }) { tag in
                if state.query.allTagIDs.contains(tag.id) {
                    Button { state.query.allTagIDs.remove(tag.id) } label: { Label(t("allTags", "同时包含标签", "Contains all tags") + ": " + tag.name, systemImage: "xmark.circle") }.buttonStyle(.borderless).font(.caption2)
                }
                if state.query.anyTagIDs.contains(tag.id) {
                    Button { state.query.anyTagIDs.remove(tag.id) } label: { Label(t("anyTags", "至少包含一个标签", "Contains any tag") + ": " + tag.name, systemImage: "xmark.circle") }.buttonStyle(.borderless).font(.caption2)
                }
            }
            HStack {
                Text("\((state.identity?.references ?? []).filter { state.matches($0, store: store) }.count)/\(state.identity?.references.count ?? 0) · " + t("indexed", "已索引", "Indexed") + " \(state.items.count)").font(.caption2)
                Button(t("clearQuery", "清除检索条件", "Clear query conditions")) { state.query = .init() }.font(.caption2)
            }
            if state.isLoading { Text(t("indexing", "正在读取当前结果的登记信息…", "Reading registered facts for these results…")).font(.caption2) }
            if let issue = state.failure { Text(issue).font(.caption).foregroundStyle(.orange) }
        }.font(.caption)
    }
}
