import DWorkbench
import SwiftUI

struct SharedLibraryQueryDraft {
    let original: SharedLibraryQuery
    let context: String
    var query: SharedLibraryQuery
    init(query: SharedLibraryQuery, context: String) { original = query; self.query = query; self.context = context }
    func validated(current: SharedLibraryQuery, context: String) throws -> SharedLibraryQuery {
        guard current == original, context == self.context else { throw WorkflowIssue("The filter context changed. Reopen the filter editor.") }
        try query.scope?.validate(); try query.properties?.validate(); try query.facts?.validate()
        return query
    }
}

struct SharedLibraryFilterEditor: View {
    @State private var tagSearch = ""
    @State private var advanced = false
    @State private var applyRequest = 0
    @State private var draft: SharedLibraryQueryDraft
    let store: SharedLibraryStore
    let items: [SharedLibraryItem]
    let context: SharedLibraryQueryContext
    let allowsScopeEditing: Bool
    let scopeTitle: String
    let current: () -> (SharedLibraryQuery, String)
    let apply: (SharedLibraryQuery) -> Void
    let close: () -> Void
    @State private var failure: String?
    @Environment(\.dLanguageStore) private var language
    init(query: SharedLibraryQuery, token: String, store: SharedLibraryStore, items: [SharedLibraryItem],
         context: SharedLibraryQueryContext, allowsScopeEditing: Bool = true, scopeTitle: String = "",
         current: @escaping () -> (SharedLibraryQuery, String), apply: @escaping (SharedLibraryQuery) -> Void, close: @escaping () -> Void) {
        _draft = State(initialValue: .init(query: query, context: token)); self.store = store; self.items = items
        self.context = context; self.allowsScopeEditing = allowsScopeEditing; self.scopeTitle = scopeTitle; self.current = current; self.apply = apply; self.close = close
    }
    private func t(_ key: String, _ zh: String = "", _ en: String = "") -> String { metadataText(language, key, zh, en) }
    var body: some View {
        VStack(spacing: 0) {
        WorkbenchScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("filters")).font(.headline)
                Text(t("draftFilters")).font(.caption)
                if !scopeTitle.isEmpty { Text(scopeTitle).font(.subheadline) }
                if allowsScopeEditing { SharedLibraryScopeControls(query: $draft.query, items: items, context: context) }
                TextField(t("searchResults"), text: $draft.query.text)
                TextField(t("tagSearch"), text: $tagSearch)
                tagsGroup(t("allTags"), \.allTagIDs)
                tagsGroup(t("anyTags"), \.anyTagIDs)
                group(t("kind"), SharedLibraryItemKind.allCases, \.kinds) { t("kind." + $0.rawValue, ["model":"模型", "component":"组件", "program":"程序", "asset":"素材", "tool":"工具"][$0.rawValue] ?? $0.rawValue, $0.rawValue.capitalized) }
                group(t("roles"), Array(Set(items.map(\.role).filter { !$0.isEmpty })).sorted(), \.roles) { $0 }
                group(t("inputs"), WorkflowDataKind.allCases, \.inputs) { WorkflowCanvasPresentation.kind($0, language: language) }
                group(t("outputs"), WorkflowDataKind.allCases, \.outputs) { WorkflowCanvasPresentation.kind($0, language: language) }
                group(t("content"), WorkflowDataKind.allCases, \.contentKinds) { WorkflowCanvasPresentation.kind($0, language: language) }
                group(t("readiness"), SharedLibraryReadiness.allCases, \.readiness) { workflowText(language, "baseline02.library.ready." + $0.rawValue, fallback: $0.rawValue) }
                group(t("compatibility"), SharedLibraryCompatibility.allCases, \.compatibility) { workflowText(language, "baseline02.library.compat." + $0.rawValue, fallback: $0.rawValue) }
                Button { advanced.toggle() } label: { Label(t("advancedPropertiesOnly"), systemImage: advanced ? "chevron.down" : "chevron.right") }
                SharedLibraryPropertyControls(query: $draft.query, items: items, context: context, allowsScopeEditing: false, onApply: {
                    do { let live = current(); let value = try draft.validated(current: live.0, context: live.1); apply(value); close() }
                    catch { failure = t("filterContextChanged") }
                }, onCancel: close, showsActions: false, applyRequest: applyRequest, onValidationFailure: { failure = $0; advanced = true })
                .frame(height: advanced ? nil : 0).clipped().allowsHitTesting(advanced).accessibilityHidden(!advanced)
                if let failure { Text(failure).foregroundStyle(.red) }
            }.padding(16)
        }
        HStack {
            Button(t("cancel"), action: close).workbenchHelp("QUERY-CANCEL").keyboardShortcut(.cancelAction)
            Spacer()
            Button(t("applyAllFilters")) { applyRequest += 1 }.buttonStyle(WorkbenchPrimaryButtonStyle()).workbenchHelp("QUERY-APPLY").keyboardShortcut(.defaultAction)
        }.environment(\.workbenchActionHeight, 36).padding(16)
        }.frame(width: 400, height: 580)
        .environment(\.workbenchMenuContext, "filter:\(ObjectIdentifier(store)):\(draft.context)")
    }
    private func tagsGroup(_ title: String, _ path: WritableKeyPath<SharedLibraryQuery, Set<UUID>>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(draft.query[keyPath: path].sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                Button { draft.query[keyPath: path].remove(id) } label: {
                    Label(store.metadata.tags[id]?.name ?? t("deletedTagCondition"), systemImage: "xmark.circle")
                }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
            }
            ForEach(store.metadata.tags.values.filter { tagSearch.isEmpty || $0.name.localizedStandardContains(tagSearch) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
                Toggle(tag.name, isOn: Binding(get: { draft.query[keyPath: path].contains(tag.id) }, set: { included in
                    if included { draft.query[keyPath: path].insert(tag.id) } else { draft.query[keyPath: path].remove(tag.id) }
                }))
            }
        }
    }
    private func group<T: Hashable>(_ title: String, _ values: [T], _ path: WritableKeyPath<SharedLibraryQuery, Set<T>>, label: @escaping (T) -> String) -> some View {
        DisclosureGroup(title + " (\(draft.query[keyPath: path].count))") {
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
    @Environment(\.workbenchChildClose) private var closeGate
    let close: () -> Void
    @State private var name = ""
    @State private var failure: (any Error)?
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String = "", _ en: String = "") -> String { metadataText(language, key, zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("saveQuery")).font(.headline)
            Text(request.scopeTitle).font(.callout)
            if let scope = request.query.scope { Text(SharedLibraryScopeSummary.readable(scope, text: t)).font(.callout) }
            Text(t("queryName"))
            TextField("", text: $name).textFieldStyle(WorkbenchGlassTextFieldStyle())
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !request.query.text.isEmpty { Text(t("searchText") + request.query.text) }
                    conditions(request.query.allTagIDs, title: t("allTags"))
                    conditions(request.query.anyTagIDs, title: t("anyTags"))
                    SharedLibraryQuerySummary(query: request.query)
                    WorkflowTechnicalDetails(value: (try? String(data: JSONEncoder().encode(request.query), encoding: .utf8)) ?? "—")
                }
            }.frame(maxHeight: 220)
            Text(t("saveQueryImpact")).font(.caption)
            if let failure { Text(sharedLibraryErrorText(failure, language: language)).foregroundStyle(.red) }
            HStack {
                Button(t("cancel")) { if let closeGate { closeGate.requestClose() } else { close() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("saveQuery")) {
                    do { _ = try store.createSavedQuery(name: name, query: request.query); close() }
                    catch { failure = error }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(maxWidth: 460)
        .workbenchCloseProtection(isDirty: !name.isEmpty, save: { _ = try store.createSavedQuery(name: name, query: request.query) })
    }
    private func conditions(_ ids: Set<UUID>, title: String) -> some View {
        ForEach(WorkflowResultQueryState.tagConditions(ids, store: store, missingLabel: t("deletedTagCondition")), id: \.id) { item in Text(title + ": " + (request.tagTitles[item.id] ?? item.title)) }
    }
}

/// One exhaustive summary shared by the collapsed result filter and its save preview.
/// A read-only preview never pretends that an empty supplied index means missing data.
struct SharedLibraryQuerySummary: View {
    let query: SharedLibraryQuery
    var remove: ((SharedLibraryQuery) -> Void)? = nil
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String = "", _ en: String = "") -> String { metadataText(language, key, zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            dimensions(query.kinds, path: \.kinds, title: t("kind")) { workflowText(language, "baseline02.library.kind." + $0.rawValue, fallback: $0.rawValue) }
            dimensions(query.roles, path: \.roles, title: t("roles")) { $0 }
            dimensions(query.inputs, path: \.inputs, title: t("inputs")) { WorkflowCanvasPresentation.kind($0, language: language) }
            dimensions(query.outputs, path: \.outputs, title: t("outputs")) { WorkflowCanvasPresentation.kind($0, language: language) }
            dimensions(query.contentKinds, path: \.contentKinds, title: t("content")) { WorkflowCanvasPresentation.kind($0, language: language) }
            dimensions(query.readiness, path: \.readiness, title: t("readiness")) { workflowText(language, "baseline02.library.ready." + $0.rawValue, fallback: $0.rawValue) }
            dimensions(query.compatibility, path: \.compatibility, title: t("compatibility")) { workflowText(language, "baseline02.library.compat." + $0.rawValue, fallback: $0.rawValue) }
            if remove == nil, let p = query.properties {
                if let value = p.favorite { Text(t("favorite") + ": " + (value ? t("yes") : t("no"))) }
                if let value = p.width { Text(t("width") + ": " + range(value)) }
                if let value = p.height { Text(t("height") + ": " + range(value)) }
                if let value = p.registeredAt { Text(t("registered") + ": " + (value.start?.formatted() ?? "…") + " – " + (value.end?.formatted() ?? "…")) }
                if let value = p.model { Text(t("model") + ": " + (value.kind == .localReference ? URL(fileURLWithPath: value.value).lastPathComponent : t("modelNameUnrecorded")) + " · " + (value.revision == nil ? t("allVersions") : t("exactRecordedVersion"))) }
                if p.directParent != nil { Text(t("recordedSource")) }
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
