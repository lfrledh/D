import DWorkbench
import SwiftUI

/// Finite whitelist; localized labels never become query keys.
struct SharedLibraryPropertyControls: View {
    @Binding var query: SharedLibraryQuery
    let items: [SharedLibraryItem]
    let context: SharedLibraryQueryContext
    var allowsScopeEditing = true
    var onApply: () -> Void = {}
    var onCancel: () -> Void = {}
    var showsActions = true
    var applyRequest = 0
    var onValidationFailure: (String) -> Void = { _ in }
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
    private func t(_ key: String, _ zh: String = "", _ en: String = "") -> String { metadataText(language, key, zh, en) }
    private var properties: SharedLibraryPropertyQuery {
        get { query.properties ?? .init() }
        nonmutating set { query.properties = newValue.isEmpty ? nil : newValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("typed")).font(.subheadline.weight(.semibold))
            if allowsScopeEditing { SharedLibraryScopeControls(query: $query, items: items, context: context) }
            WorkbenchMenu(t("favorite")) {
                WorkbenchMenuAction(t("unrestricted")) { properties.favorite = nil }
                WorkbenchMenuAction(t("onlyFavorite")) { properties.favorite = true }
                WorkbenchMenuAction(t("notFavorite")) { properties.favorite = false }
            }
            Text(t("pixelRange"))
            HStack { Text(t("width")); TextField(workflowText(language, "workbench.field.minimum"), text: $widthMin); Text("–"); TextField(workflowText(language, "workbench.field.maximum"), text: $widthMax) }
            HStack { Text(t("height")); TextField(workflowText(language, "workbench.field.minimum"), text: $heightMin); Text("–"); TextField(workflowText(language, "workbench.field.maximum"), text: $heightMax) }
            Text(t("registered"))
            Toggle(t("dateAfter"), isOn: $hasStart)
            if hasStart { DatePicker(t("dateAfter"), selection: $dateStart).labelsHidden() }
            Toggle(t("dateBefore"), isOn: $hasEnd)
            if hasEnd { DatePicker(t("dateBefore"), selection: $dateEnd).labelsHidden() }
            if showsActions {
                Button(t("applyAllFilters"), action: applyChanges)
                Button(t("cancel"), action: onCancel).keyboardShortcut(.cancelAction)
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            Text(t("sourceFilterHint")).foregroundStyle(.secondary)
        }.font(.caption).textFieldStyle(WorkbenchGlassTextFieldStyle())
        .onChange(of: applyRequest) { _, _ in applyChanges() }
        .onAppear {
            widthMin = properties.width?.minimum.map(String.init) ?? ""; widthMax = properties.width?.maximum.map(String.init) ?? ""
            heightMin = properties.height?.minimum.map(String.init) ?? ""; heightMax = properties.height?.maximum.map(String.init) ?? ""
            hasStart = properties.registeredAt?.start != nil; hasEnd = properties.registeredAt?.end != nil
            dateStart = properties.registeredAt?.start ?? Date(); dateEnd = properties.registeredAt?.end ?? Date()
        }
    }
    private func applyChanges() {
                do {
                    var next = properties
                    next.width = try range(widthMin, widthMax); next.height = try range(heightMin, heightMax)
                    next.registeredAt = hasStart || hasEnd ? .init(start: hasStart ? dateStart : nil, end: hasEnd ? dateEnd : nil) : nil
                    try next.validate(); try query.scope?.validate(); properties = next; failure = nil; onApply()
                } catch { failure = t("invalidRange"); onValidationFailure(failure!) }
    }
    private func range(_ minimum: String, _ maximum: String) throws -> SharedLibraryNumberRange? {
        let low = minimum.trimmingCharacters(in: .whitespaces), high = maximum.trimmingCharacters(in: .whitespaces)
        if low.isEmpty && high.isEmpty { return nil }
        guard (low.isEmpty || Int(low) != nil), (high.isEmpty || Int(high) != nil) else { throw SharedLibraryError.invalidProperty }
        let range = SharedLibraryNumberRange(minimum: Int(low), maximum: Int(high)); try range.validate(); return range
    }

}

struct SharedLibraryPropertySummary: View {
    @Binding var query: SharedLibraryQuery
    let items: [SharedLibraryItem]
    let context: SharedLibraryQueryContext
    var store: SharedLibraryStore? = nil
    var fixedScopeDescription: String? = nil
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String = "", _ en: String = "") -> String { metadataText(language, key, zh, en) }
    private var p: SharedLibraryPropertyQuery {
        get { query.properties ?? .init() }
        nonmutating set { query.properties = newValue.isEmpty ? nil : newValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scope = query.scope {
                remove(scopeTitle(scope)) { query.scope = nil }
                let sources = items.filter { $0.assetFacts?.matches(scope: scope, properties: nil, context: context) == true }
                if !sources.isEmpty { Text(t("scopeSources") + Array(Set(sources.map { $0.detail + " · " + $0.title })).sorted().prefix(3).joined(separator: "、")).foregroundStyle(.secondary) }
                WorkflowTechnicalDetails(value: SharedLibraryScopeSummary.title(scope, text: t))
                if !items.contains(where: { $0.assetFacts?.matches(scope: scope, properties: nil, context: context) == true }) {
                    Text(t("unavailableScope")).foregroundStyle(.orange)
                }
            } else { Text(fixedScopeDescription ?? t("registeredScope")).foregroundStyle(.secondary) }
            if let favorite = p.favorite { remove(favorite ? t("onlyFavorite") : t("notFavorite")) { p.favorite = nil } }
            if let width = p.width { remove(t("width") + ": " + rangeLabel(width)) { p.width = nil } }
            if let height = p.height { remove(t("height") + ": " + rangeLabel(height)) { p.height = nil } }
            if let date = p.registeredAt { remove(t("registered") + ": " + (date.start?.formatted() ?? "…") + " – " + (date.end?.formatted() ?? "…")) { p.registeredAt = nil } }
            if let model = p.model { remove(t("model") + ": " + (model.kind == .localReference ? URL(fileURLWithPath: model.value).lastPathComponent : t("modelNameUnrecorded")) + " · " + (model.revision == nil ? t("allVersions") : t("exactRecordedVersion"))) { p.model = nil } }
            if p.directParent != nil { remove(t("directParent") + ": " + t("recordedSource")) { p.directParent = nil } }
            if p.model != nil || p.directParent != nil {
                WorkflowTechnicalDetails(value: (try? String(data: JSONEncoder().encode(p), encoding: .utf8)) ?? "—")
            }
            if !p.isEmpty {
                Text(t("missingFields") + ": \(missingCount)").foregroundStyle(.secondary)
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
        SharedLibraryScopeSummary.readable(scope, text: t)
    }
    private func rangeLabel(_ value: SharedLibraryNumberRange) -> String { (value.minimum.map(String.init) ?? "…") + " – " + (value.maximum.map(String.init) ?? "…") + " px" }
    private func remove(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: "xmark.circle").multilineTextAlignment(.leading) }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
    }
}

/// The saved query and its removable summary use the same complete identity.
enum SharedLibraryScopeSummary {
    static func readable(_ scope: SharedLibraryQueryScope, text: (String, String, String) -> String) -> String {
        if scope.mode == .currentProject { return text("dynamicScope", "使用时的当前项目实例", "Current project instance when used") }
        var parts = [scope.instanceID == nil ? text("fixedLogicalProject", "固定项目（所有已登记实例）", "Fixed project (all registered instances)") : text("fixedProject", "固定项目实例", "Fixed project instance")]
        if scope.runID != nil { parts.append(text("fixedRun", "所选历史运行", "Selected historical run")) }
        if scope.nodeID != nil { parts.append(text("fixedNode", "所选节点", "Selected node")) }
        if scope.stepID != nil { parts.append(text("fixedCall", "所选具体调用", "Selected exact call")) }
        return parts.joined(separator: " · ")
    }
    static func title(_ scope: SharedLibraryQueryScope,
                      text: (String, String, String) -> String) -> String {
        if scope.mode == .currentProject {
            return text("dynamicScope", "使用时的当前项目实例", "Current project instance when used")
        }
        var parts: [String] = []
        if let id = scope.projectID { parts.append(text("scopeProject", "项目", "Project") + " " + id.uuidString) }
        if let id = scope.instanceID { parts.append(text("scopeInstance", "项目实例", "Project instance") + " " + id.uuidString) }
        if let id = scope.runID { parts.append(text("scopeRun", "运行", "Run") + " " + id.uuidString) }
        if let id = scope.nodeID { parts.append(text("scopeNode", "节点", "Node") + " " + id.uuidString) }
        if let id = scope.stepID { parts.append(text("scopeCall", "具体调用", "Call") + " " + id.uuidString) }
        return parts.joined(separator: " · ")
    }
}

/// Shared scope selector remains visible above the filter's advanced properties.
struct SharedLibraryScopeControls: View {
    @Binding var query: SharedLibraryQuery
    let items: [SharedLibraryItem]
    let context: SharedLibraryQueryContext
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String = "", _ en: String = "") -> String { metadataText(language, key, zh, en) }
    private var projectItems: [SharedLibraryItem] {
        var seen = Set<UUID>()
        return items.filter { $0.assetFacts.map { seen.insert($0.instanceID).inserted } ?? false }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkbenchMenu(t("scope")) {
                WorkbenchMenuAction(t("registeredScope")) { query.scope = nil }
                WorkbenchMenuAction(t("dynamicScope")) { query.scope = .init(mode: .currentProject) }.disabled(context.projectID == nil)
                WorkbenchMenuForEach(projectItems) { item in
                    if let facts = item.assetFacts {
                        WorkbenchMenuAction(item.detail + " · " + t("recordedInstance") + " \((projectItems.map { $0.assetFacts!.instanceID }.sorted { $0.uuidString < $1.uuidString }.firstIndex(of: facts.instanceID) ?? 0) + 1)") {
                            query.scope = .init(mode: .project, projectID: facts.projectID, instanceID: facts.instanceID)
                        }
                    }
                }
                WorkbenchSubmenu(t("runScope")) {
                    WorkbenchMenuForEach(runScopes, id: \.key) { value in
                        WorkbenchSubmenu(value.title + " \((runScopes.firstIndex { $0.key == value.key } ?? 0) + 1)") {
                            WorkbenchMenuAction(t("wholeRun")) { query.scope = value.scope }
                            WorkbenchMenuForEach(value.nodes, id: \.self) { node in
                                WorkbenchMenuAction(t("recordedNode") + " \((value.nodes.sorted { $0.uuidString < $1.uuidString }.firstIndex(of: node) ?? 0) + 1)") { var scope = value.scope; scope.nodeID = node; query.scope = scope }
                            }
                        }
                    }
                    if runScopes.isEmpty { WorkbenchMenuText(t("noRun")) }
                }
            }
            Text(query.scope.map { SharedLibraryScopeSummary.readable($0, text: t) } ?? t("registeredScope"))
                .font(.caption).foregroundStyle(.secondary)
        }
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
                if values[key] == nil { values[key] = .init(key: key, title: item.detail + " · " + t("recordedRun"),
                    scope: .init(mode: .run, projectID: facts.projectID, instanceID: facts.instanceID, runID: occurrence.runID), nodes: []) }
                if values[key]?.nodes.contains(occurrence.nodeID) == false { values[key]?.nodes.append(occurrence.nodeID) }
            }
        }
        return values.values.sorted { $0.key < $1.key }
    }
}
