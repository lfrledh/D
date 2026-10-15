import DWorkbench
import SwiftUI

struct SharedLibraryQueryDraft {
    let original: SharedLibraryQuery
    let context: String
    var query: SharedLibraryQuery
    init(query: SharedLibraryQuery, context: String) { original = query; self.query = query; self.context = context }
    func validated(current: SharedLibraryQuery, context: String) throws -> SharedLibraryQuery {
        guard current == original, context == self.context else { throw WorkflowIssue("The filter context changed. Reopen the filter editor.") }
        try query.scope?.validate(); try query.properties?.validate()
        return query
    }
}

struct SharedLibraryFilterEditor: View {
    @State private var draft: SharedLibraryQueryDraft
    let store: SharedLibraryStore
    let items: [SharedLibraryItem]
    let context: SharedLibraryQueryContext
    let allowsScopeEditing: Bool
    let current: () -> (SharedLibraryQuery, String)
    let apply: (SharedLibraryQuery) -> Void
    let close: () -> Void
    @State private var failure: String?
    @Environment(\.dLanguageStore) private var language
    init(query: SharedLibraryQuery, token: String, store: SharedLibraryStore, items: [SharedLibraryItem],
         context: SharedLibraryQueryContext, allowsScopeEditing: Bool = true,
         current: @escaping () -> (SharedLibraryQuery, String), apply: @escaping (SharedLibraryQuery) -> Void, close: @escaping () -> Void) {
        _draft = State(initialValue: .init(query: query, context: token)); self.store = store; self.items = items
        self.context = context; self.allowsScopeEditing = allowsScopeEditing; self.current = current; self.apply = apply; self.close = close
    }
    private func t(_ key: String, _ zh: String, _ en: String) -> String { metadataText(language, key, zh, en) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("filters", "筛选条件", "Filter conditions")).font(.headline)
                Text(t("draftFilters", "全部条件在点应用后一起生效；取消不改当前检索。", "All conditions apply together. Cancel leaves the current query unchanged.")).font(.caption)
                TextField(t("searchResults", "搜索名称、说明和标签", "Search names, notes & tags"), text: $draft.query.text)
                group(t("allTags", "同时包含标签", "Contains all tags"), Array(store.metadata.tags.keys).sorted { $0.uuidString < $1.uuidString }, \.allTagIDs) { store.metadata.tags[$0]?.name ?? "—" }
                group(t("anyTags", "至少包含一个标签", "Contains any tag"), Array(store.metadata.tags.keys).sorted { $0.uuidString < $1.uuidString }, \.anyTagIDs) { store.metadata.tags[$0]?.name ?? "—" }
                group(t("kind", "类别", "Category"), SharedLibraryItemKind.allCases, \.kinds) { t("kind." + $0.rawValue, ["model":"模型", "component":"组件", "program":"程序", "asset":"素材", "tool":"工具"][$0.rawValue] ?? $0.rawValue, $0.rawValue.capitalized) }
                group(t("roles", "用途", "Role"), Array(Set(items.map(\.role).filter { !$0.isEmpty })).sorted(), \.roles) { $0 }
                group(t("inputs", "输入类型", "Input type"), WorkflowDataKind.allCases, \.inputs) { WorkflowCanvasPresentation.kind($0, language: language) }
                group(t("outputs", "输出类型", "Output type"), WorkflowDataKind.allCases, \.outputs) { WorkflowCanvasPresentation.kind($0, language: language) }
                group(t("content", "内容类型", "Content type"), WorkflowDataKind.allCases, \.contentKinds) { WorkflowCanvasPresentation.kind($0, language: language) }
                group(t("readiness", "准备状态", "Readiness"), SharedLibraryReadiness.allCases, \.readiness) { workflowText(language, "baseline02.library.ready." + $0.rawValue, fallback: $0.rawValue) }
                group(t("compatibility", "兼容性", "Compatibility"), SharedLibraryCompatibility.allCases, \.compatibility) { workflowText(language, "baseline02.library.compat." + $0.rawValue, fallback: $0.rawValue) }
                SharedLibraryPropertyControls(query: $draft.query, items: items, context: context, allowsScopeEditing: allowsScopeEditing, onApply: {
                    do { let live = current(); let value = try draft.validated(current: live.0, context: live.1); apply(value); close() }
                    catch { failure = t("filterContextChanged", "条件或所在范围已改变，或条件无效。未应用；请取消后重新打开。", "The query or context changed, or a condition is invalid. Nothing was applied; cancel and reopen.") }
                }, onCancel: close)
                if let failure { Text(failure).foregroundStyle(.red) }
            }.padding(16)
        }.frame(width: 380, height: 580)
    }
    private func group<T: Hashable>(_ title: String, _ values: [T], _ path: WritableKeyPath<SharedLibraryQuery, Set<T>>, label: @escaping (T) -> String) -> some View {
        Menu(title + " (\(draft.query[keyPath: path].count))") {
            ForEach(values, id: \.self) { value in
                Toggle(label(value), isOn: Binding(get: { draft.query[keyPath: path].contains(value) }, set: { included in
                    if included { draft.query[keyPath: path].insert(value) } else { draft.query[keyPath: path].remove(value) }
                }))
            }
        }
    }
}

struct SharedLibrarySaveQueryRequest: Identifiable {
    let id = UUID()
    let query: SharedLibraryQuery
    let scopeTitle: String
    var tagTitles: [UUID: String] = [:]
}
struct SharedLibrarySaveQuerySheet: View {
    let request: SharedLibrarySaveQueryRequest
    let store: SharedLibraryStore
    let close: () -> Void
    @State private var name = ""
    @State private var failure: String?
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String, _ en: String) -> String { metadataText(language, key, zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("saveQuery", "保存此检索", "Save this query")).font(.headline)
            Text(request.scopeTitle).font(.callout)
            if let scope = request.query.scope { Text(SharedLibraryScopeSummary.readable(scope, text: t)).font(.callout) }
            Text(t("queryName", "检索名称", "Query name"))
            TextField("", text: $name).textFieldStyle(WorkbenchGlassTextFieldStyle())
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !request.query.text.isEmpty { Text(t("searchText", "搜索文字：", "Search text: ") + request.query.text) }
                    conditions(request.query.allTagIDs, title: t("allTags", "同时包含标签", "Contains all tags"))
                    conditions(request.query.anyTagIDs, title: t("anyTags", "至少包含一个标签", "Contains any tag"))
                    SharedLibraryQuerySummary(query: request.query)
                    WorkflowTechnicalDetails(value: (try? String(data: JSONEncoder().encode(request.query), encoding: .utf8)) ?? "—")
                }
            }.frame(maxHeight: 220)
            Text(t("saveQueryImpact", "保存筛选条件和上述范围，不修改结果、节点或文件。", "Saves these conditions and this scope; does not change results, nodes, or files.")).font(.caption)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button(t("cancel", "取消", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("saveQuery", "保存此检索", "Save this query")) {
                    do { _ = try store.createSavedQuery(name: name, query: request.query); close() }
                    catch { failure = error.localizedDescription }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 460)
    }
    private func conditions(_ ids: Set<UUID>, title: String) -> some View {
        ForEach(WorkflowResultQueryState.tagConditions(ids, store: store, missingLabel: t("deletedTagCondition", "已删除的标签", "Deleted tag")), id: \.id) { item in Text(title + ": " + (request.tagTitles[item.id] ?? item.title)) }
    }
}

/// One exhaustive summary shared by the collapsed result filter and its save preview.
/// A read-only preview never pretends that an empty supplied index means missing data.
struct SharedLibraryQuerySummary: View {
    let query: SharedLibraryQuery
    var remove: ((SharedLibraryQuery) -> Void)? = nil
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String, _ en: String) -> String { metadataText(language, key, zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            dimensions(query.kinds, path: \.kinds, title: t("kind", "类别", "Category")) { workflowText(language, "baseline02.library.kind." + $0.rawValue, fallback: $0.rawValue) }
            dimensions(query.roles, path: \.roles, title: t("roles", "用途", "Role")) { $0 }
            dimensions(query.inputs, path: \.inputs, title: t("inputs", "输入类型", "Input type")) { WorkflowCanvasPresentation.kind($0, language: language) }
            dimensions(query.outputs, path: \.outputs, title: t("outputs", "输出类型", "Output type")) { WorkflowCanvasPresentation.kind($0, language: language) }
            dimensions(query.contentKinds, path: \.contentKinds, title: t("content", "内容类型", "Content type")) { WorkflowCanvasPresentation.kind($0, language: language) }
            dimensions(query.readiness, path: \.readiness, title: t("readiness", "准备状态", "Readiness")) { workflowText(language, "baseline02.library.ready." + $0.rawValue, fallback: $0.rawValue) }
            dimensions(query.compatibility, path: \.compatibility, title: t("compatibility", "兼容性", "Compatibility")) { workflowText(language, "baseline02.library.compat." + $0.rawValue, fallback: $0.rawValue) }
            if remove == nil, let p = query.properties {
                if let value = p.favorite { Text(t("favorite", "收藏", "Favorite") + ": " + (value ? t("yes", "是", "Yes") : t("no", "否", "No"))) }
                if let value = p.width { Text(t("width", "宽度", "Width") + ": " + range(value)) }
                if let value = p.height { Text(t("height", "高度", "Height") + ": " + range(value)) }
                if let value = p.registeredAt { Text(t("registered", "项目登记时间", "Project registration") + ": " + (value.start?.formatted() ?? "…") + " – " + (value.end?.formatted() ?? "…")) }
                if let value = p.model { Text(t("model", "实际记录模型", "Recorded model") + ": " + (value.kind == .localReference ? URL(fileURLWithPath: value.value).lastPathComponent : t("modelNameUnrecorded", "模型名称未记录", "Model name not recorded")) + " · " + (value.revision == nil ? t("allVersions", "此模型的所有已记录版本", "All recorded revisions of this model") : t("exactRecordedVersion", "精确已记录版本（见技术详情）", "Exact recorded revision (see technical details)"))) }
                if p.directParent != nil { Text(t("recordedSource", "已登记来源", "Recorded source")) }
            }
        }.font(.caption)
    }
    private func range(_ value: SharedLibraryNumberRange) -> String { (value.minimum.map(String.init) ?? "…") + " – " + (value.maximum.map(String.init) ?? "…") + " px" }
    private func dimensions<T: Hashable>(_ values: Set<T>, path: WritableKeyPath<SharedLibraryQuery, Set<T>>, title: String, label: @escaping (T) -> String) -> some View {
        ForEach(Array(values).sorted { label($0) < label($1) }, id: \.self) { value in
            if let remove {
                Button { var next = query; next[keyPath: path].remove(value); remove(next) } label: { Label(title + ": " + label(value), systemImage: "xmark.circle") }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
            } else { Text(title + ": " + label(value)) }
        }
    }
}
