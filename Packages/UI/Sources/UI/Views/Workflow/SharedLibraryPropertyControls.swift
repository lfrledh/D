import DWorkbench
import SwiftUI

/// Finite whitelist; localized labels never become query keys.
struct SharedLibraryPropertyControls: View {
    @Binding var query: SharedLibraryQuery
    let items: [SharedLibraryItem]
    let context: SharedLibraryQueryContext
    var allowsScopeEditing = true
    @State private var widthMin = ""
    @State private var widthMax = ""
    @State private var heightMin = ""
    @State private var heightMax = ""
    @State private var dateStart = Date()
    @State private var dateEnd = Date()
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var failure: String?
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String, _ en: String) -> String { metadataText(language, key, zh, en) }
    private var properties: SharedLibraryPropertyQuery {
        get { query.properties ?? .init() }
        nonmutating set { query.properties = newValue.isEmpty ? nil : newValue }
    }
    private var projectItems: [SharedLibraryItem] {
        var seen = Set<UUID>()
        return items.filter { $0.assetFacts.map { seen.insert($0.instanceID).inserted } ?? false }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("typed", "素材属性与范围", "Asset properties & scope")).font(.subheadline.weight(.semibold))
            if allowsScopeEditing { Menu(t("scope", "检索作用域", "Query scope")) {
                Button(t("registeredScope", "全部已登记条目", "All registered entries")) { query.scope = nil }
                Button(t("dynamicScope", "使用时的当前项目实例", "Current project instance when used")) { query.scope = .init(mode: .currentProject) }.disabled(context.projectID == nil)
                ForEach(projectItems) { item in
                    if let facts = item.assetFacts {
                        Button(item.detail + " · " + facts.instanceID.uuidString.prefix(6)) {
                            query.scope = .init(mode: .project, projectID: facts.projectID, instanceID: facts.instanceID)
                        }
                    }
                }
                Menu(t("runScope", "绑定已登记运行或节点", "Bind a recorded run or node")) {
                    ForEach(runScopes, id: \.key) { value in
                        Menu(value.title) {
                            Button(t("wholeRun", "此运行的全部结果", "All results of this run")) { query.scope = value.scope }
                            ForEach(value.nodes, id: \.self) { node in
                                Button("Node " + node.uuidString.prefix(8)) { var scope = value.scope; scope.nodeID = node; query.scope = scope }
                            }
                        }
                    }
                    if runScopes.isEmpty { Text(t("noRun", "当前索引无运行记录", "No runs in the current index")) }
                }
            }
            }
            Menu(t("favorite", "收藏", "Favorite")) {
                Button(t("unrestricted", "不限", "Any")) { properties.favorite = nil }
                Button(t("onlyFavorite", "仅收藏", "Favorites only")) { properties.favorite = true }
                Button(t("notFavorite", "未收藏", "Not favorited")) { properties.favorite = false }
            }
            Text(t("pixelRange", "像素范围（留空为不限）", "Pixel range (blank means unbounded)"))
            HStack { Text(t("width", "宽度", "Width")); TextField("min", text: $widthMin); Text("–"); TextField("max", text: $widthMax) }
            HStack { Text(t("height", "高度", "Height")); TextField("min", text: $heightMin); Text("–"); TextField("max", text: $heightMax) }
            Text(t("registered", "项目登记时间（本地时区）", "Project registration (local time)"))
            Toggle(t("dateAfter", "起始时间", "From"), isOn: $hasStart)
            if hasStart { DatePicker(t("dateAfter", "起始时间", "From"), selection: $dateStart).labelsHidden() }
            Toggle(t("dateBefore", "结束时间", "Until"), isOn: $hasEnd)
            if hasEnd { DatePicker(t("dateBefore", "结束时间", "Until"), selection: $dateEnd).labelsHidden() }
            Button(t("applyProperties", "应用尺寸与时间条件", "Apply size & time conditions")) {
                do {
                    var next = properties
                    next.width = try range(widthMin, widthMax); next.height = try range(heightMin, heightMax)
                    next.registeredAt = hasStart || hasEnd ? .init(start: hasStart ? dateStart : nil, end: hasEnd ? dateEnd : nil) : nil
                    try next.validate(); properties = next; failure = nil
                } catch { failure = t("invalidRange", "请输入正整数范围，结束值不能早于起始值。条件尚未应用。", "Use positive integer ranges and an end after the start. Conditions have not been applied.") }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            Text(t("sourceFilterHint", "模型和直接来源可从对象的“生成与来源”加入条件。保存检索会保存这些条件和明确范围，不修改对象。", "Add model and direct-source conditions from an item's provenance. Saving a query retains all conditions and its explicit scope, without editing items.")).foregroundStyle(.secondary)
        }.font(.caption).textFieldStyle(.roundedBorder)
        .onAppear {
            widthMin = properties.width?.minimum.map(String.init) ?? ""; widthMax = properties.width?.maximum.map(String.init) ?? ""
            heightMin = properties.height?.minimum.map(String.init) ?? ""; heightMax = properties.height?.maximum.map(String.init) ?? ""
            hasStart = properties.registeredAt?.start != nil; hasEnd = properties.registeredAt?.end != nil
            dateStart = properties.registeredAt?.start ?? Date(); dateEnd = properties.registeredAt?.end ?? Date()
        }
    }
    private func range(_ minimum: String, _ maximum: String) throws -> SharedLibraryNumberRange? {
        let low = minimum.trimmingCharacters(in: .whitespaces), high = maximum.trimmingCharacters(in: .whitespaces)
        if low.isEmpty && high.isEmpty { return nil }
        guard (low.isEmpty || Int(low) != nil), (high.isEmpty || Int(high) != nil) else { throw SharedLibraryError.invalidProperty }
        let range = SharedLibraryNumberRange(minimum: Int(low), maximum: Int(high)); try range.validate(); return range
    }
    private struct RunScope {
        let key: String, title: String
        let scope: SharedLibraryQueryScope
        var nodes: [UUID]
    }
    private var runScopes: [RunScope] {
        var values: [String: RunScope] = [:]
        for item in items {
            guard let facts = item.assetFacts else { continue }
            for occurrence in facts.occurrences ?? [] {
                let key = facts.instanceID.uuidString + occurrence.runID.uuidString
                if values[key] == nil { values[key] = .init(key: key, title: item.detail + " · " + occurrence.runID.uuidString.prefix(8),
                    scope: .init(mode: .run, projectID: facts.projectID, instanceID: facts.instanceID, runID: occurrence.runID), nodes: []) }
                if values[key]?.nodes.contains(occurrence.nodeID) == false { values[key]?.nodes.append(occurrence.nodeID) }
            }
        }
        return values.values.sorted { $0.key < $1.key }
    }
}

struct SharedLibraryPropertySummary: View {
    @Binding var query: SharedLibraryQuery
    let items: [SharedLibraryItem]
    let context: SharedLibraryQueryContext
    var store: SharedLibraryStore? = nil
    var fixedScopeDescription: String? = nil
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String, _ en: String) -> String { metadataText(language, key, zh, en) }
    private var p: SharedLibraryPropertyQuery {
        get { query.properties ?? .init() }
        nonmutating set { query.properties = newValue.isEmpty ? nil : newValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scope = query.scope {
                remove(scopeTitle(scope)) { query.scope = nil }
                if !items.contains(where: { $0.assetFacts?.matches(scope: scope, properties: nil, context: context) == true }) {
                    Text(t("unavailableScope", "所绑定范围在当前索引中无条目；没有扩大为全库。", "The bound scope has no entries in this index; it has not expanded to the whole library.")).foregroundStyle(.orange)
                }
            } else { Text(fixedScopeDescription ?? t("registeredScope", "全部已登记条目", "All registered entries")).foregroundStyle(.secondary) }
            if let favorite = p.favorite { remove(favorite ? t("onlyFavorite", "仅收藏", "Favorites only") : t("notFavorite", "未收藏", "Not favorited")) { p.favorite = nil } }
            if let width = p.width { remove(t("width", "宽度", "Width") + ": " + rangeLabel(width)) { p.width = nil } }
            if let height = p.height { remove(t("height", "高度", "Height") + ": " + rangeLabel(height)) { p.height = nil } }
            if let date = p.registeredAt { remove(t("registered", "项目登记时间（本地时区）", "Project registration (local time)") + ": " + (date.start?.formatted() ?? "…") + " – " + (date.end?.formatted() ?? "…")) { p.registeredAt = nil } }
            if let model = p.model { remove(t("model", "实际记录模型", "Recorded model") + ": " + (model.kind == .localReference ? URL(fileURLWithPath: model.value).lastPathComponent : model.value) + " · " + (model.revision ?? t("allVersions", "此模型的所有已记录版本", "All recorded revisions of this model"))) { p.model = nil } }
            if let parent = p.directParent { remove(t("directParent", "直接来源", "Direct source") + ": " + parent.assetID.uuidString.prefix(8)) { p.directParent = nil } }
            if !p.isEmpty {
                Text(t("missingFields", "当前范围中缺少所需属性的登记项", "Entries missing required properties in this scope") + ": \(missingCount)").foregroundStyle(.secondary)
            }
        }.font(.caption2)
    }
    private var missingCount: Int {
        var base = query; base.properties = nil
        return items.filter { item in
            guard store.map({ $0.matches(item, query: base, context: context) }) ?? (item.assetFacts?.matches(scope: query.scope, properties: nil, context: context) ?? false) else { return false }
            return item.assetFacts?.hasMissingFields(for: p) ?? true
        }.count
    }
    private func scopeTitle(_ scope: SharedLibraryQueryScope) -> String {
        if scope.mode == .currentProject { return t("dynamicScope", "使用时的当前项目实例", "Current project instance when used") }
        return (scope.runID.map { "Run " + $0.uuidString.prefix(8) } ?? "Project " + (scope.projectID?.uuidString.prefix(8) ?? "?"))
            + (scope.instanceID.map { " · " + $0.uuidString.prefix(6) } ?? "") + (scope.nodeID.map { " · Node " + $0.uuidString.prefix(8) } ?? "")
    }
    private func rangeLabel(_ value: SharedLibraryNumberRange) -> String { (value.minimum.map(String.init) ?? "…") + " – " + (value.maximum.map(String.init) ?? "…") + " px" }
    private func remove(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: "xmark.circle").multilineTextAlignment(.leading) }.buttonStyle(.borderless)
    }
}
