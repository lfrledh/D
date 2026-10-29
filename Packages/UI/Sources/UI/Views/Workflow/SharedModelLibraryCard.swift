import AppKit
import DWorkbench
import SwiftUI

/// Functions are executable routes, not descriptive recipe IDs or a model-kind cross product.
@MainActor enum SharedModelLibraryCard {
    static func descriptor(_ entry: SharedLibraryBrowserEntry) -> ModelNodeDescriptor? {
        ModelNodeCatalog.entries.first { $0.id == entry.item.key }
    }
    static func functions(_ entry: SharedLibraryBrowserEntry) -> [WorkflowOperationDefinition] {
        guard entry.item.kind == .model, case .operation(let primary, let modelID) = entry.selection, let modelID,
              WorkflowRegistry.standard.operation(primary)?.definition.modelKind != nil else { return [] }
        let additional = WorkflowModelRoutes.legacyTextOperations(identity: modelID)
        let ids = [primary] + additional.filter { $0 != primary }.sorted()
        return ids.compactMap { WorkflowRegistry.standard.operation($0)?.definition }
    }
    static func resolve(_ base: SharedLibraryBrowserEntry, function: String, current: [SharedLibraryBrowserEntry]) -> SharedLibraryBrowserEntry? {
        guard let value = current.first(where: { $0.id == base.id }), value.selection == base.selection,
              functions(value).contains(where: { $0.id == function }), case .operation(_, let model) = value.selection else { return nil }
        return .init(item: value.item, selection: .operation(id: function, modelID: model), facts: value.facts,
            activityID: value.id, legacyTags: value.legacyTags, legacyFailure: value.legacyFailure, metadataSnapshot: value.metadataSnapshot)
    }
    static func searchEntry(_ entry: SharedLibraryBrowserEntry, language: UILanguageStore?) -> SharedLibraryBrowserEntry {
        let functions = functions(entry)
        guard !functions.isEmpty else { return entry }
        let item = entry.item
        let search = SharedLibraryItem(key: item.key, title: item.title,
            detail: item.detail + "\n" + functions.map { WorkflowCanvasPresentation.operationTitle($0, language: language) }.joined(separator: "\n"),
            kind: item.kind, role: item.role, inputs: item.inputs, outputs: item.outputs, contentKind: item.contentKind,
            readiness: item.readiness, compatible: item.compatible, assetFacts: item.assetFacts, facts: item.facts)
        return .init(item: search, selection: entry.selection, facts: entry.facts, activityID: entry.id,
            legacyTags: entry.legacyTags, legacyFailure: entry.legacyFailure, metadataSnapshot: entry.metadataSnapshot)
    }
}

/// One result set per browser owner. Exact entries and language revision invalidate;
/// no disk access, global cache, or repeated catalog tree sorting while hovering.
@MainActor final class SharedModelGroupCache {
    private var entries: [SharedLibraryBrowserEntry] = []
    private weak var language: UILanguageStore?
    private var languageRevision: UInt64?
    private var languageID: String?
    private var value: [WorkflowOperationTree] = []
    private(set) var builds = 0
    func tree(_ current: [SharedLibraryBrowserEntry], language: UILanguageStore?) -> [WorkflowOperationTree] {
        let revision = language?.presentationRevision, id = language?.effectiveLanguageIdentifier
        if current == entries, self.language === language, languageRevision == revision, languageID == id, builds > 0 { return value }
        entries = current; self.language = language; languageRevision = revision; languageID = id
        value = WorkflowOperationTree.make(current, models: true, language: language); builds += 1
        return value
    }
}

struct SharedModelVariantCard: View {
    let entry: SharedLibraryBrowserEntry
    let selected: Bool
    let focused: Bool
    let readiness: String
    let query: String
    var selectingQuickModel = false
    @Binding var expanded: Bool
    let choose: () -> Void
    let info: () -> Void
    let add: (String) -> Void
    let drag: (String) -> NSItemProvider
    let insertionIssue: (String) -> String?
    let prepare: () -> Void
    let prepareTitle: String?
    @Environment(\.dLanguageStore) private var language
    private var functions: [WorkflowOperationDefinition] { SharedModelLibraryCard.functions(entry) }
    private var shown: [WorkflowOperationDefinition] {
        if expanded { return functions }
        return functions.enumerated().filter { index, function in
            index < 3 || (!query.isEmpty && query.split(whereSeparator: \.isWhitespace).contains { WorkflowCanvasPresentation.operationTitle(function, language: language).localizedStandardContains(String($0)) })
        }.map(\.element)
    }
    private func t(_ key: String) -> String { workflowText(language, "modelLibrary.cards." + key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                Text(entry.item.title).font(.headline).lineLimit(2).help(entry.item.title)
                Spacer(minLength: 0)
                Button(action: info) { Image(systemName: "info.circle") }
                    .buttonStyle(WorkbenchIconButtonStyle()).help(t("details")).accessibilityLabel(t("details"))
            }
            ModelSpecificationFields(descriptor: SharedModelLibraryCard.descriptor(entry), font: .caption)
            if let descriptor = SharedModelLibraryCard.descriptor(entry) {
                Text(ModelNodeUILocalization.summary(descriptor, language: language)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Text(readiness).font(.caption).foregroundStyle(.secondary)
            ForEach(shown, id: \.id) { function in
                functionRow(function)
            }
            if functions.count > 3 {
                Button(t(expanded ? "fewer" : "more"), systemImage: expanded ? "chevron.up" : "chevron.down") { expanded.toggle() }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
            }
            if let prepareTitle { Button(prepareTitle, action: prepare).buttonStyle(WorkbenchGlassButtonStyle(compact: true)) }
            if case .unavailable(let reason) = entry.selection { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(WorkbenchItemFeedback(selected: selected, focused: focused, radius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12)).onTapGesture(perform: choose)
            .accessibilityIdentifier("model-variant-card-" + entry.id)
    }
    private var primaryTitle: String { selectingQuickModel ? workflowText(language, "workflow.action.chooseModel") : t("add") }
    @ViewBuilder private func functionRow(_ definition: WorkflowOperationDefinition) -> some View {
        let title = WorkflowCanvasPresentation.operationTitle(definition, language: language)
        let reason = insertionIssue(definition.id)
        let row = HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(definition.inputs.map { WorkflowCanvasPresentation.portTitle(operationID: definition.id, port: $0, input: true, language: language) }.joined(separator: ", ") + " → " + definition.outputs.map { WorkflowCanvasPresentation.portTitle(operationID: definition.id, port: $0, input: false, language: language) }.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { add(definition.id) } label: { Image(systemName: selectingQuickModel ? "checkmark" : "plus") }
                .buttonStyle(WorkbenchIconButtonStyle()).disabled(reason != nil)
                .help(reason ?? primaryTitle + " · " + title).accessibilityLabel(primaryTitle + " · " + title)
        }.padding(.vertical, 4).contentShape(Rectangle())
        if selectingQuickModel { row } else { row.onDrag { drag(definition.id) } }
    }
}
