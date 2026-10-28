import AppKit
import DWorkbench
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One visible receipt follows the existing project-owned request; it never drains
/// or retries work. A replaced owner cannot publish a stale success destination.
struct SharedLibraryCollectionFeedback {
    enum Status: Equatable { case pending, completed, failed(WorkflowIssue), obsolete }
    let requestID: String
    let context: WorkflowLibraryContext
    private(set) var durablyCompleted = false
    @MainActor mutating func acknowledgeCompletion(in controller: WorkflowController?) {
        if status(in: controller) == .completed { durablyCompleted = true }
    }
    @MainActor func status(in controller: WorkflowController?) -> Status {
        guard let controller, context.isCurrent(in: controller),
              case .sources(let sources) = context.source,
              let request = controller.collectionRequests.first(where: { $0.id == requestID }),
              request.owner == controller.assetLibraryOwner, request.sources == sources else { return .obsolete }
        if let error = request.error { return .failed(.init(error, code: request.errorCode)) }
        if request.completed { return durablyCompleted || !(controller.isSaving || controller.hasPendingSaves) ? .completed : .pending }
        return .pending
    }
}

enum SharedLibraryBrowserIssue: Error, Equatable {
    case folderCannotBeSaved
    case conflictingKindScope
}

public enum SharedLibraryBrowserSelection: Equatable {
    case operation(id: String, modelID: String?)
    case asset(projectID: UUID, assetID: UUID)
    case assetInstance(projectID: UUID, instanceID: UUID, assetID: UUID)
    case tool(WorkflowToolReference)
    case unavailable(String)
}

// Catalog preparation state is not permission to insert into the current project.
private struct WorkflowLibraryInsertionControllerKey: EnvironmentKey {
    static let defaultValue: WorkflowController? = nil
}
extension EnvironmentValues {
    var workflowLibraryInsertionController: WorkflowController? {
        get { self[WorkflowLibraryInsertionControllerKey.self] }
        set { self[WorkflowLibraryInsertionControllerKey.self] = newValue }
    }
}

public struct SharedLibraryBrowserEntry: Identifiable, Equatable {
    public let item: SharedLibraryItem
    public let selection: SharedLibraryBrowserSelection
    public let facts: [String]
    public let id: String
    public var legacyTags: [String]
    public var legacyFailure: String?
    public var metadataSnapshot: ProjectAssetMetadataSnapshot?
    var runtimeValue: WorkflowLibraryValue? = nil
    var collected = true
    var collectionSource: WorkflowLibrarySource? = nil

    public init(item: SharedLibraryItem, selection: SharedLibraryBrowserSelection, facts: [String] = [], activityID: String? = nil, legacyTags: [String] = [], legacyFailure: String? = nil, metadataSnapshot: ProjectAssetMetadataSnapshot? = nil) {
        self.item = item
        self.selection = selection
        self.facts = facts
        self.id = activityID ?? item.key
        self.legacyTags = legacyTags; self.legacyFailure = legacyFailure; self.metadataSnapshot = metadataSnapshot
    }
}

public enum SharedLibraryBrowserScope: Hashable {
    case all, kind(SharedLibraryItemKind), tag(UUID), folder(UUID), saved(UUID)
}

enum SharedLibraryAssetSort: String, CaseIterable { case source, nameAscending, nameDescending }

/// The caller owns one instance per browser surface so closing a view does not erase its place.
@MainActor @Observable
public final class SharedLibraryBrowserState {
    public var query: SharedLibraryQuery
    public var draftText: String
    public var collectedOnly = true
    var assetSort: SharedLibraryAssetSort = .source
    public var operationPath: [String] = []
    var modelModality: CreatorMode?
    var collapsedModelFamilies: Set<String> = []
    var expandedModelFunctions: Set<String> = []
    @ObservationIgnored let modelGroupsCache = SharedModelGroupCache()
    var modelPathMigrated = false
    var modelScrollKey: String { "models:" + (modelModality?.rawValue ?? "all") + (query.text.isEmpty ? "" : ":search") }
    func migrateModelPath() {
        guard !modelPathMigrated else { return }
        modelPathMigrated = true
        modelModality = CreatorMode.allCases.first { mode in operationPath.contains { $0.hasSuffix("/mode:" + mode.rawValue) } }
        if let family = operationPath.last(where: { $0.contains("/family:") }) {
            var position = ScrollPosition(idType: String.self); position.scrollTo(id: family, anchor: .top)
            navigationScrolls[modelScrollKey] = position
        }
    }
    // Browser-owned, bounded navigation positions; dropped with this surface owner.
    var navigationScrolls: [String: ScrollPosition] = [:]
    var previewCache = WorkflowLibraryPreviewCache()
    var thumbnailSize = 190.0
    public var scope: SharedLibraryBrowserScope
    public var selectedKeys: Set<String>
    var tagPresentation = SharedLibraryTagPresentation()
    public var focusedKey: String?

    public init(
        query: SharedLibraryQuery = SharedLibraryQuery(),
        scope: SharedLibraryBrowserScope = .all,
        selectedKeys: Set<String> = [],
        focusedKey: String? = nil
    ) {
        self.query = query; self.draftText = query.text
        self.scope = scope
        self.selectedKeys = selectedKeys
        self.focusedKey = focusedKey
    }

    /// Editing a named query creates a free filter draft, so its name never labels new rules.
    public func setDraftQuery(_ draft: SharedLibraryQuery) {
        if case .saved = scope, draft != query { scope = .all }
        query = draft; draftText = draft.text
    }

    public var hasUnsubmittedText: Bool { draftText != query.text }
    public func submitSearch(hasMarkedText: Bool = false) {
        guard !hasMarkedText else { return }
        var next = query; next.text = String(draftText.prefix(256)); setDraftQuery(next)
    }

    public func selectScope(_ requested: SharedLibraryBrowserScope, using store: SharedLibraryStore) throws {
        switch requested {
        case .all, .kind:
            scope = requested
        case .tag(let id):
            guard store.metadata.tags[id] != nil else { throw SharedLibraryError.missingTag }
            scope = requested
        case .folder(let id):
            guard store.metadata.folders[id] != nil else { throw SharedLibraryError.missingFolder }
            scope = requested
        case .saved(let id):
            guard let saved = store.metadata.savedQueries[id] else { throw SharedLibraryError.missingQuery }
            query = saved.query; draftText = saved.query.text
            scope = requested
        }
    }

    /// Named queries always evaluate the current Store version, including before onChange runs.
    public func effectiveQuery(using store: SharedLibraryStore) -> SharedLibraryQuery {
        if case .saved(let id) = scope, let saved = store.metadata.savedQueries[id] {
            return saved.query
        }
        return query
    }

    /// Called after local or external metadata changes. Drafts and selected keys are retained.
    public func reconcile(using store: SharedLibraryStore) {
        tagPresentation.observe(tags: store.metadata.tags, requested: query.allTagIDs.union(query.anyTagIDs))
        // Missing conditions and scopes remain explicit; never widen a query on deletion.
        if case .saved(let id) = scope, let saved = store.metadata.savedQueries[id] {
            let wasCommitted = draftText == query.text
            query = saved.query
            if wasCommitted { draftText = saved.query.text }
        }
    }

    public func repairScope(using store: SharedLibraryStore) {
        reconcile(using: store)
    }
}

enum SharedLibraryBrowserAction {
    case use, add, preview, prepare, location
}

enum SharedLibraryBrowserOrganizerItem: Hashable {
    case tag(UUID), folder(UUID), saved(UUID)
}

struct SharedLibraryBrowserRenameDrafts {
    private var values: [SharedLibraryBrowserOrganizerItem: String] = [:]
    var hasDrafts: Bool { !values.isEmpty }

    func text(for item: SharedLibraryBrowserOrganizerItem?, canonical: String) -> String {
        guard let item else { return "" }
        return values[item] ?? canonical
    }

    mutating func set(_ text: String, for item: SharedLibraryBrowserOrganizerItem?) {
        guard let item else { return }
        values[item] = text
    }

    mutating func clear(_ item: SharedLibraryBrowserOrganizerItem) {
        values.removeValue(forKey: item)
    }
}

@MainActor enum SharedLibraryBrowserLogic {
    static func deleteTag(_ id: UUID, store: SharedLibraryStore, state: SharedLibraryBrowserState) throws {
        try store.deleteTags([id])
        state.repairScope(using: store)
    }

    static func deleteFolder(_ id: UUID, store: SharedLibraryStore, state: SharedLibraryBrowserState) throws {
        try store.deleteFolder(id)
        state.repairScope(using: store)
    }

    static func deleteSavedQuery(_ id: UUID, store: SharedLibraryStore, state: SharedLibraryBrowserState) throws {
        try store.deleteSavedQuery(id)
        state.repairScope(using: store)
    }

    static func queryForSaving(
        _ query: SharedLibraryQuery, scope: SharedLibraryBrowserScope,
        store: SharedLibraryStore
    ) throws -> SharedLibraryQuery {
        var saved = query
        switch scope {
        case .all:
            break
        case .saved(let id):
            guard store.metadata.savedQueries[id] != nil else { throw SharedLibraryError.missingQuery }
        case .kind(let kind):
            if !saved.kinds.isEmpty && !saved.kinds.contains(kind) {
                throw SharedLibraryBrowserIssue.conflictingKindScope
            }
            saved.kinds = [kind]
        case .tag(let id):
            guard store.metadata.tags[id] != nil else { throw SharedLibraryError.missingTag }
            saved.allTagIDs.insert(id)
        case .folder:
            throw SharedLibraryBrowserIssue.folderCannotBeSaved
        }
        return saved
    }

    static func visibleEntries(
        _ entries: [SharedLibraryBrowserEntry], store: SharedLibraryStore,
        query: SharedLibraryQuery, scope: SharedLibraryBrowserScope, context: SharedLibraryQueryContext = .init(),
        collectedOnly: Bool = false, sort: SharedLibraryAssetSort = .source
    ) throws -> [SharedLibraryBrowserEntry] {
        let scopeKeys: Set<String>
        switch scope {
        case .all, .kind, .saved:
            if case .saved(let id) = scope, store.metadata.savedQueries[id] == nil {
                throw SharedLibraryError.missingQuery
            }
            scopeKeys = Set(entries.map(\.id))
        case .tag(let id):
            guard store.metadata.tags[id] != nil else { throw SharedLibraryError.missingTag }
            scopeKeys = Set(entries.filter { store.metadata.tagAssignments[$0.item.key]?.contains(id) == true }.map(\.id))
        case .folder(let id):
            guard let folder = store.metadata.folders[id] else { throw SharedLibraryError.missingFolder }
            scopeKeys = Set(entries.filter { folder.memberKeys.contains($0.item.key) }.map(\.id))
        }
        let result = entries.filter { entry in
            if scope == .all && collectedOnly && !entry.collected { return false }
            guard scopeKeys.contains(entry.id), store.matches(entry.item, query: query, context: context) else { return false }
            if case .kind(let kind) = scope { return entry.item.kind == kind }
            return true
        }
        guard sort != .source else { return result }
        return result.enumerated().sorted { a, b in
            let order = a.element.item.title.localizedStandardCompare(b.element.item.title)
            if order == .orderedSame { return a.offset < b.offset }
            return sort == .nameAscending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
    }

    static func tagEditEntries(_ ids: Set<String>, in entries: [SharedLibraryBrowserEntry]) -> [SharedLibraryBrowserEntry] {
        entries.filter { ids.contains($0.id) && ($0.runtimeValue == nil || $0.runtimeValue?.annotationIdentity != nil) }
    }

    static func validatedOrganizationKeys(_ entries: [SharedLibraryBrowserEntry], validations: [() throws -> Void]) throws -> Set<String> {
        guard !entries.isEmpty, entries.count == validations.count else { throw SharedLibraryError.staleAnnotation }
        for (entry, validate) in zip(entries, validations) {
            if let runtime = entry.runtimeValue {
                guard runtime.annotationIdentity?.storageKey == entry.item.key else { throw SharedLibraryError.staleAnnotation }
            }
            try validate()
        }
        return Set(entries.map { $0.item.key })
    }

    static func validatedDropKeys(_ candidates: [String], entries: [SharedLibraryBrowserEntry]) -> Set<String>? {
        guard !candidates.isEmpty, candidates.count <= 128 else { return nil }
        let known = Set(entries.map(\.id))
        let keys = Set(candidates)
        guard !entries.contains(where: { keys.contains($0.id) && $0.runtimeValue != nil }) else { return nil }
        guard keys.count == candidates.count, keys.allSatisfy({ known.contains($0) }) else { return nil }
        return keys
    }

    static func allows(_ action: SharedLibraryBrowserAction, entry: SharedLibraryBrowserEntry) -> Bool {
        if entry.runtimeValue != nil { return action == .preview || (action == .add && entry.collectionSource != nil) }
        if action == .location {
            switch entry.selection { case .asset, .assetInstance: return true; default: return false }
        }
        if action == .prepare {
            if entry.item.readiness != .available || entry.item.compatible == false { return true }
            if case .unavailable = entry.selection { return true }
            return false
        }
        guard entry.item.compatible != false, entry.item.readiness != .unsupported else { return false }
        switch entry.selection {
        case .operation(let operationID, let modelID):
            guard !operationID.isEmpty else { return false }
            let selectable = entry.item.readiness == .available
                || (modelID?.isEmpty == false
                    && (entry.item.readiness == .unprepared || entry.item.readiness == .unknown))
            return selectable && action != .preview
        case .asset, .assetInstance:
            let selectable = entry.item.readiness == .available || entry.item.readiness == .unknown
            return selectable && action != .use
        case .tool:
            return entry.item.readiness == .available && action == .add
        case .unavailable:
            return false
        }
    }

    static func currentEntry(
        key: String, entries: [SharedLibraryBrowserEntry],
        action: SharedLibraryBrowserAction
    ) -> SharedLibraryBrowserEntry? {
        guard let entry = entries.first(where: { $0.id == key }), allows(action, entry: entry) else {
            return nil
        }
        return entry
    }

    static func detailEntry(
        key: String?, entries: [SharedLibraryBrowserEntry]
    ) -> SharedLibraryBrowserEntry? {
        guard let key else { return nil }
        return entries.first { $0.id == key }
    }

    static func canvasTransfer(for entry: SharedLibraryBrowserEntry) -> WorkflowCanvasTransfer? {
        if let source = entry.collectionSource, let facts = entry.item.assetFacts {
            return .library(owner: .init(projectID: facts.projectID, instanceID: facts.instanceID), sources: [source])
        }
        guard allows(.add, entry: entry) else { return nil }
        switch entry.selection {
        case .operation(let id, let modelID): return .operation(id: id, modelID: modelID)
        case .asset(let projectID, let assetID): return .asset(projectID: projectID, assetID: assetID)
        case .assetInstance(let projectID, let instanceID, let assetID):
            return .assetInstance(projectID: projectID, instanceID: instanceID, assetID: assetID)
        case .tool(let reference): return .tool(reference)
        case .unavailable: return nil
        }
    }

    @MainActor static func dragProvider(for current: SharedLibraryBrowserEntry, controller: WorkflowController? = nil) -> NSItemProvider {
        let allowsCanvas: Bool
        switch current.selection {
        case .operation, .tool: allowsCanvas = insertionIssue(for: current, controller: controller, language: nil) == nil
        default: allowsCanvas = true // Assets also serve independent Quick/Chat destinations.
        }
        let provider = NSItemProvider(object: current.id as NSString)
        if allowsCanvas, let transfer = canvasTransfer(for: current),
           let payload = try? transfer.encoded() {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.workflowCanvasItem.identifier, visibility: .ownProcess
            ) { completion in
                completion(payload, nil)
                return nil
            }
        }
        return provider
    }

    @MainActor static func insertionIssue(for entry: SharedLibraryBrowserEntry,
                                         controller: WorkflowController?, language: UILanguageStore?) -> String? {
        guard let controller else { return nil } // Existing explicit Add opens the target first.
        if !controller.canEditCanvas {
            return metadataText(language, "canvasUnavailable")
        }
        guard case .operation(let id, let modelID) = entry.selection, let modelID else { return nil }
        guard let definition = controller.registry.operation(id)?.definition, definition.modelKind != nil,
              (controller.modelChoices.contains(where: { $0.id == modelID && $0.kind == definition.modelKind })
                || WorkflowModelRoutes.draftChoice(operationID: id, modelID: modelID)?.kind == definition.modelKind) else {
            return metadataText(language, "modelIdentityBeforeAdd")
        }
        return nil
    }

    static func quickUseAllowed(_ entry: SharedLibraryBrowserEntry) -> Bool {
        allows(.use, entry: entry)
    }
}

@MainActor
public struct SharedLibraryBrowser: View {
    private let entries: [SharedLibraryBrowserEntry]
    private let store: SharedLibraryStore
    private let compact: Bool
    private let onCollect: (([SharedLibraryBrowserEntry], Bool) -> Void)?
    private let onUse: (SharedLibraryBrowserEntry) -> Void
    private let onAdd: (SharedLibraryBrowserEntry) -> Void
    private let onPreview: (SharedLibraryBrowserEntry) -> Void
    private let onExternalCopy: ((SharedLibraryBrowserEntry) -> Void)?
    private let onExport: ((SharedLibraryBrowserEntry, @escaping () -> Bool) -> Void)?
    private let readPreview: (@MainActor @Sendable (SharedLibraryBrowserEntry) async throws -> ProjectReadOnlyContent)?
    private let onLocation: (SharedLibraryBrowserEntry) -> Void
    private let onPrepare: (SharedLibraryBrowserEntry) -> Void
    private let onImport: () -> Void
    private let allowsImport: Bool
    private let canvasMode: WorkflowCanvasLibraryMode?
    private let scopeDescription: String
    private let importTargetDescription: String
    private let onClose: () -> Void
    private let queryContext: SharedLibraryQueryContext
    private let annotationSave: (SharedLibraryBrowserEntry) -> SharedLibraryAnnotationSave?
    private let tagValidation: (SharedLibraryBrowserEntry) -> (() throws -> Void)
    private var captureFileImport: (() -> WorkbenchAssetImportCommand?)?
    private var headerOnly = false
    private var selectingQuickModel = false

    func quickModelSelection(_ value: Bool) -> Self {
        var copy = self; copy.selectingQuickModel = value; return copy
    }

    @Environment(\.dLanguageStore) private var language
    @Environment(\.workflowLibraryContext) private var workflowContext
    @Environment(\.workflowLibraryInsertionController) private var insertionController
    @State private var state: SharedLibraryBrowserState
    @State private var commandScope = WorkbenchCommandScope()
    @Environment(\.workbenchContentVisible) private var contentVisible
    @State private var featureHelp = WorkbenchHelpStore()
    @State private var showFilters = false
    @State private var saveQueryRequest: SharedLibrarySaveQueryRequest?
    @State private var showOrganizer = false
    @State private var compactDetailKey: String?
    @Environment(\.workflowContainerNavigation) private var containerNavigation
    @State private var collectionNotice: String?
    @State private var collectionNoticeCode: String?
    @State private var collectedLocation: WorkflowLibraryContext?
    @State private var collectionFeedback: SharedLibraryCollectionFeedback?
    @State private var collectionNoticeIntent: UUID?
    @State private var errorMessage: String?
    private struct TagRequest: Identifiable {
        let id = UUID()
        let targets: [SharedLibraryTagTarget]
        let validations: [() throws -> Void]
        var add: Set<UUID> = []
        var remove: Set<UUID> = []
    }
    @State private var tagRequest: TagRequest?
    @State private var tab: OrganizerTab = .tags
    @State private var newName = ""
    @State private var renameDrafts = SharedLibraryBrowserRenameDrafts()
    @State private var selectedTagID: UUID?
    @State private var selectedFolderID: UUID?
    @FocusState private var searchFocused: Bool
    @FocusState private var selectionFocused: Bool
    @FocusState private var entryKeyboardFocus: String?
    @State private var showTags = false
    @State private var tagSearch = ""
    @State private var selectedQueryID: UUID?
    @State private var parentID: UUID?
    @State private var modelResultsWidth: CGFloat = 0

    public init(
        entries: [SharedLibraryBrowserEntry], store: SharedLibraryStore, compact: Bool = false, allowsImport: Bool = true, canvasMode: WorkflowCanvasLibraryMode? = nil, scopeDescription: String = "", importTargetDescription: String = "",
        state: SharedLibraryBrowserState? = nil,
        onCollect: (([SharedLibraryBrowserEntry], Bool) -> Void)? = nil,
        onUse: @escaping (SharedLibraryBrowserEntry) -> Void,
        onAdd: @escaping (SharedLibraryBrowserEntry) -> Void,
        onPreview: @escaping (SharedLibraryBrowserEntry) -> Void,
        onExternalCopy: ((SharedLibraryBrowserEntry) -> Void)? = nil,
        onExport: ((SharedLibraryBrowserEntry, @escaping () -> Bool) -> Void)? = nil,
        readPreview: (@MainActor @Sendable (SharedLibraryBrowserEntry) async throws -> ProjectReadOnlyContent)? = nil,
        onLocation: @escaping (SharedLibraryBrowserEntry) -> Void = { _ in },
        onPrepare: @escaping (SharedLibraryBrowserEntry) -> Void,
        onImport: @escaping () -> Void, onClose: @escaping () -> Void,
        tagValidation: @escaping (SharedLibraryBrowserEntry) -> (() throws -> Void) = { _ in {} },
        queryContext: SharedLibraryQueryContext = .init(), annotationSave: @escaping (SharedLibraryBrowserEntry) -> SharedLibraryAnnotationSave? = { _ in nil }
    ) {
        self._state = State(initialValue: state ?? SharedLibraryBrowserState())
        self.importTargetDescription = importTargetDescription; self.scopeDescription = scopeDescription; self.canvasMode = canvasMode; self.entries = entries; self.store = store; self.compact = compact; self.allowsImport = allowsImport
        self.onCollect = onCollect; self.onUse = onUse; self.onAdd = onAdd; self.onPreview = onPreview; self.onLocation = onLocation
        self.onExport = onExport
        self.onExternalCopy = onExternalCopy; self.readPreview = readPreview
        self.onPrepare = onPrepare; self.onImport = onImport; self.onClose = onClose
        self.tagValidation = tagValidation; self.queryContext = queryContext; self.annotationSave = annotationSave
    }

    func importingFiles(_ capture: @escaping () -> WorkbenchAssetImportCommand?) -> Self {
        var copy = self; copy.captureFileImport = capture; return copy
    }
    func headerActionsOnly(_ value: Bool) -> Self { var copy = self; copy.headerOnly = value; return copy }

    private var query: SharedLibraryQuery {
        get { state.effectiveQuery(using: store) }
        nonmutating set {
            guard (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
            var next = newValue
            if next.text == query.text { next.text = state.draftText }
            state.setDraftQuery(next)
        }
    }
    private var scope: SharedLibraryBrowserScope { state.scope }
    private var selectedKeys: Set<String> {
        get { state.selectedKeys }
        nonmutating set { state.selectedKeys = newValue }
    }
    private var focusedKey: String? {
        get { state.focusedKey }
        nonmutating set { state.focusedKey = newValue }
    }

    private func word(_ key: String, _ fallback: String) -> String {
        workflowText(language, "baseline02.library." + key, fallback: fallback)
    }
    private var tags: [SharedLibraryTag] { store.metadata.tags.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var folders: [SharedLibraryFolder] { store.metadata.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var folderTree: [SharedLibraryFolder] {
        var ordered: [SharedLibraryFolder] = []
        func appendChildren(of parent: UUID?) {
            for folder in folders where folder.parentID == parent {
                ordered.append(folder)
                appendChildren(of: folder.id)
            }
        }
        appendChildren(of: nil)
        return ordered
    }
    private var saved: [SharedLibrarySavedQuery] { store.metadata.savedQueries.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var validSelection: Set<String> { selectedKeys.intersection(Set(entries.map(\.id))) }
    private var selectedTagKeys: Set<String> { Set(SharedLibraryBrowserLogic.tagEditEntries(validSelection, in: entries).map { $0.item.key }) }
    private var selectedMetadataEntries: [SharedLibraryBrowserEntry] { SharedLibraryBrowserLogic.tagEditEntries(validSelection, in: entries) }
    private var selectedMetadataKeys: Set<String> { Set(selectedMetadataEntries.map { $0.item.key }) }
    private var selectedEntry: SharedLibraryBrowserEntry? {
        entries.first { $0.id == focusedKey } ?? entries.first { validSelection.contains($0.id) }
    }
    private var visibleResult: Result<[SharedLibraryBrowserEntry], Error> {
        Result {
            let eligible = entries.filter { entry in
                guard let workflowContext else { return true }
                return insertionController.map { workflowContext.isCurrent(in: $0) } == true && workflowContext.includes(entry)
            }
            let search = canvasMode == .nodes ? eligible.map { SharedModelLibraryCard.searchEntry($0, language: language) } : eligible
            let matches = try SharedLibraryBrowserLogic.visibleEntries(search, store: store, query: query, scope: scope, context: queryContext,
                collectedOnly: onCollect != nil && state.collectedOnly && workflowContext == nil,
                sort: onCollect != nil ? state.assetSort : .source)
            let originals = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return matches.compactMap { originals[$0.id] }
        }
    }
    private var visible: [SharedLibraryBrowserEntry] { (try? visibleResult.get()) ?? [] }

    private var exportMenuCommand: WorkbenchGenerationCommand? {
        let selected = visible.filter { selectedKeys.contains($0.id) }
        guard contentVisible, selected.count == 1, let item = selected.first, selectedKeys == [item.id], item.runtimeValue == nil,
              item.item.kind == .asset, let mediaType = item.metadataSnapshot?.asset.mediaType,
              WorkflowMediaFormat.supportsReadOnlyExport(mediaType), let onExport else { return nil }
        let current: () -> Bool = {
            contentVisible && selectedKeys == [item.id] && visible.contains { $0.id == item.id && $0.selection == item.selection && $0.metadataSnapshot == item.metadataSnapshot }
        }
        return .init(title: systemMenuText(language, "export"), isEnabled: true) {
            guard commandScope.permitsCommands, current() else { return }
            onExport(item, current)
        }
    }

    public var body: some View {
        Group {
        if headerOnly { searchMore }
        else {
        VStack(spacing: 0) {
            if !compact { header }
            if let errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { self.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(word("dismissError", "关闭错误"))
                }.font(.caption).foregroundStyle(.red).padding(8)
                    .accessibilityIdentifier("shared-library-error")
            }
            if let collectionNotice {
                HStack {
                    WorkbenchIssueText(raw: collectionNotice, key: collectionNoticeCode).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let collectedLocation, let containerNavigation {
                        Button(workflowText(language, "container.showInLibrary")) { containerNavigation.reveal(collectedLocation) }
                    }
                    Button { self.collectionNotice = nil; collectionNoticeCode = nil; collectedLocation = nil; collectionFeedback = nil; collectionNoticeIntent = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(word("dismissError", "关闭错误"))
                }.padding(8)
            }
            if case .failure(let error) = visibleResult {
                Text(sharedLibraryErrorText(error, language: language)).foregroundStyle(.red).padding(8)
            }
            if workflowContext != nil, visible.isEmpty {
                Text(workspaceText(language, "locationEmpty")).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if compact {
                compactBody
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            sidebar.frame(width: 190)
                            Divider()
                            results.frame(width: max(300, geometry.size.width - 462))
                            Divider()
                            detailPane.frame(width: 270)
                        }
                    }
                }
            }
        }
        }
        }
        .onDrop(of: [.workflowCanvasItem, .fileURL], isTargeted: nil) { providers, _ in
            guard !headerOnly, contentVisible, providers.count == 1, let provider = providers.first else { return false }
            let custom = provider.hasItemConformingToTypeIdentifier(UTType.workflowCanvasItem.identifier)
            guard !custom || onCollect != nil else { return false }
            let capturedScope = scope, capturedOwner = insertionController?.assetLibraryOwner
            let command = custom ? nil : captureFileImport?()
            guard custom || command != nil else { return false }
            Task { @MainActor in
                do {
                    let load: () async throws -> Data = {
                        try await withCheckedThrowingContinuation { continuation in
                            provider.loadDataRepresentation(forTypeIdentifier: custom ? UTType.workflowCanvasItem.identifier : UTType.fileURL.identifier) { data, error in
                                if let data { continuation.resume(returning: data) }
                                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                            }
                        }
                    }
                    if custom {
                        let bytes = try await load()
                        guard contentVisible, scope == capturedScope, insertionController?.assetLibraryOwner == capturedOwner else { throw SharedLibraryError.staleAnnotation }
                        guard acceptCollectionDrop([try WorkflowCanvasTransfer.decode(bytes)], into: capturedScope) else { throw SharedLibraryError.staleAnnotation }
                    } else if let command {
                        _ = try await command.perform {
                            guard let url = URL(dataRepresentation: try await load(), relativeTo: nil), url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                            return (url, .copy)
                        }
                    }
                } catch { errorMessage = sharedLibraryErrorText(error, language: language) }
            }
            return true
        }
        .background(WorkbenchCommandWindow(scope: commandScope))
        .focusable(!headerOnly).focusEffectDisabled().focused($selectionFocused)
        .focusedValue(\.workbenchAssetExport, headerOnly ? nil : exportMenuCommand)
        .onChange(of: entryKeyboardFocus) { _, value in
            if let value, visible.contains(where: { $0.id == value }) { focusedKey = value }
        }
        .onKeyPress(.space) {
            guard selectionFocused, !searchFocused, contentVisible, commandScope.permitsCommands,
                  let entry = selectedEntry, visible.contains(where: { $0.id == entry.id }), canPreview(entry) else { return .ignored }
            dispatch(.preview, key: entry.id); return .handled
        }
        .workflowKeyboardCommands { command in
            guard !headerOnly else { return false }
            switch command {
            case .search: searchFocused = true; return true
            case .tags: showTags = true; return true
            case .preview:
                guard let entry = selectedEntry, visible.contains(where: { $0.id == entry.id }) else { return false }
                dispatch(.preview, key: entry.id); return true
            default: return false
            }
        }
        .environment(\.workbenchHelpStore, featureHelp)
        .workbenchSheet(item: $featureHelp.presentation, title: workflowText(language, "childPanel.name.help")) { WorkbenchFeatureGuide(presentation: $0, store: featureHelp).environment(\.dLanguageStore, language) }
        .environment(\.workbenchMenuContext, "library:\(ObjectIdentifier(store)):\(ObjectIdentifier(state)):\(queryContext.projectID?.uuidString ?? "none"):\(queryContext.instanceID?.uuidString ?? "none")")
        .modifier(LibraryPanelSurface(enabled: !compact))
        .workbenchPopover(isPresented: $showFilters, title: workflowText(language, "childPanel.name.filters"), arrowEdge: .bottom) { filterPopover }
        .workbenchSheet(isPresented: Binding(get: { headerOnly && errorMessage != nil }, set: { if !$0 { errorMessage = nil } }), title: word("unavailable", "当前不可用")) {
            Text(errorMessage ?? "").textSelection(.enabled).padding(24).frame(width: 420)
        }
        .workbenchSheet(item: $saveQueryRequest, title: workflowText(language, "childPanel.name.query")) { request in SharedLibrarySaveQuerySheet(request: request, store: store) { saveQueryRequest = nil } }
        .workbenchSheet(isPresented: $showOrganizer, title: workflowText(language, "childPanel.name.organizer")) { organizer }
        .workbenchSheet(item: $tagRequest, title: workflowText(language, "childPanel.name.tags")) { request in
            SharedLibraryTagEditor(store: store, targets: request.targets, add: request.add, remove: request.remove,
                validateTarget: {
                    for check in request.validations { try check() }
                })
        }
        .workbenchSheet(isPresented: Binding(
            get: { SharedLibraryBrowserLogic.detailEntry(key: compactDetailKey, entries: entries) != nil },
            set: { if !$0 { compactDetailKey = nil } }
        ), title: word("detail", "详情")) {
            if let entry = SharedLibraryBrowserLogic.detailEntry(key: compactDetailKey, entries: entries) {
                VStack(alignment: .leading) {
                    HStack {
                        Button(word("back", "返回")) { compactDetailKey = nil }
                        Text(word("detail", "详情")).font(.headline)
                        Spacer()
                    }
                    WorkbenchScrollView { details(entry) }
                }.padding(16).frame(minWidth: 300, minHeight: 320)
            }
        }
        .onAppear {
            state.reconcile(using: store)
            if canvasMode == .nodes { state.migrateModelPath() }
        }
        .onChange(of: collectionFeedback?.status(in: insertionController)) { _, _ in refreshCollectionFeedback() }
        .onChange(of: store.metadata) { _, _ in state.reconcile(using: store) }
        .onChange(of: entries) { _, current in
            if compactDetailKey != nil,
               SharedLibraryBrowserLogic.detailEntry(key: compactDetailKey, entries: current) == nil {
                self.compactDetailKey = nil
            }
        }
        .onChange(of: selectedKeys) { _, value in
            if let focusedKey, value.contains(focusedKey) { return }
            focusedKey = entries.first { value.contains($0.id) }?.id
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) { Label(word("back", "返回"), systemImage: "chevron.left") }
                .accessibilityIdentifier("shared-library-close")
            VStack(alignment: .leading, spacing: 2) {
                Text(layoutText(language, allowsImport ? "assetLibrary" : "nodeLibrary")).font(.headline).lineLimit(1)
                Text(scopeDescription.isEmpty ? word("registered", "已登记条目") : scopeDescription).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if allowsImport {
                Button(action: onImport) { Image(systemName: "square.and.arrow.down") }
                    .help(layoutText(language, "importAsset") + " · " + importTargetDescription).accessibilityLabel(layoutText(language, "importAsset"))
            }
            if onCollect != nil { searchMore }
            Button { showOrganizer = true } label: { Image(systemName: "square.stack.3d.up") }
                .help(word("organize", "整理资料库")).accessibilityLabel(word("organize", "整理资料库")).workbenchHelp("MENU-LIBRARY-MANAGE")
            Button { perform { try store.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!store.canUndo).help(word("undo", "撤销")).accessibilityLabel(word("undo", "撤销")).workbenchHelp("MENU-LIBRARY-UNDO")
            Button { perform { try store.redo() } } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!store.canRedo).help(word("redo", "重做")).accessibilityLabel(word("redo", "重做")).workbenchHelp("MENU-LIBRARY-REDO")
        }.buttonStyle(WorkbenchGlassButtonStyle()).padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var navigationScroll: Binding<ScrollPosition> {
        let key = canvasMode == .nodes ? state.modelScrollKey : query.text.isEmpty ? state.operationPath.joined(separator: "/") : "search"
        return Binding(get: { state.navigationScrolls[key] ?? ScrollPosition() }, set: { value in
            if state.navigationScrolls[key] == nil, state.navigationScrolls.count >= 32,
               let oldest = state.navigationScrolls.keys.sorted().first { state.navigationScrolls.removeValue(forKey: oldest) }
            state.navigationScrolls[key] = value
        })
    }
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchControls
            if !validSelection.isEmpty { bulkControls }
            WorkbenchScrollView {
                LazyVStack(spacing: 6) {
                    if canvasMode == .nodes { modelGroups }
                    else if canvasMode == .programs, query.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        operationNavigation

                    } else if canvasMode == .image || canvasMode == .video { resourceGrid }
                    else { ForEach(visible) { entry in entryRow(entry, compact: true) } }
                }.padding(.bottom, 16)
            }.scrollPosition(navigationScroll)
            searchFooter
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resourceGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkbenchPicker(word("thumbnailSize", "缩略图大小"), selection: $state.thumbnailSize) {
                WorkbenchChoice("S", value: 150.0); WorkbenchChoice("M", value: 190.0); WorkbenchChoice("L", value: 240.0)
            }
            LazyVGrid(columns: [.init(.adaptive(minimum: state.thumbnailSize), spacing: 10)], spacing: 10) {
                ForEach(visible) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Button {
                                if !selectedKeys.insert(entry.id).inserted { selectedKeys.remove(entry.id) }
                            } label: { Image(systemName: selectedKeys.contains(entry.id) ? "checkmark.circle.fill" : "circle").frame(width: 28, height: 28) }
                                .buttonStyle(.plain).accessibilityLabel(workflowText(language, "container.select"))
                            Spacer()
                        }
                        if let readPreview {
                            WorkflowLibraryPreview(entry: entry, cache: state.previewCache, pixels: Int(state.thumbnailSize * 2), load: { try await readPreview(entry) })
                                .frame(height: state.thumbnailSize * 0.68).frame(maxWidth: .infinity)
                        }
                        Text(entry.item.title).font(.callout.weight(.medium)).lineLimit(2)
                        Text(readinessName(entry.item.readiness)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(WorkbenchItemFeedback(selected: selectedKeys.contains(entry.id), focused: entryKeyboardFocus == entry.id, radius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture(count: 2) { dispatch(.preview, key: entry.id) }
                        .onTapGesture { selectedKeys = [entry.id]; focusedKey = entry.id; entryKeyboardFocus = entry.id }
                        .focusable().focused($entryKeyboardFocus, equals: entry.id).focusEffectDisabled().onKeyPress(.space) { dispatch(.preview, key: entry.id); return .handled }
                        .workbenchContextMenu { resourceActions(entry) }.onDrag { dragProvider(for: entry.id) } preview: { dragPreview(for: entry.id) }
                        .accessibilityElement(children: .combine).accessibilityIdentifier("shared-library-entry-" + entry.id)
                }
            }
        }
    }

    private var modelGroups: some View {
        let models = visible.filter { $0.item.kind == .model && (state.modelModality == nil || SharedModelLibraryCard.descriptor($0)?.modality == state.modelModality) }
        let modes = state.modelGroupsCache.tree(models, language: language)
        return VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    modelFilter(nil, title: word("all", "全部"))
                    ForEach(CreatorMode.allCases, id: \.self) { mode in modelFilter(mode, title: workspaceText(language, mode.rawValue)) }
                }
            }.scrollIndicators(.hidden)
            ForEach(modes) { mode in
                if state.modelModality == nil { Text(mode.title).font(.title3).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(mode.children?.contains(where: { $0.entry != nil }) == true ? [mode] : mode.children ?? []) { group in
                    modelFamily(group)
                }
            }
            if models.isEmpty { Text(word("empty", "没有符合条件的条目")).foregroundStyle(.secondary) }
        }.scrollTargetLayout().frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { modelResultsWidth = $0 }
    }
    private func modelFamily(_ group: WorkflowOperationTree) -> some View {
        let leaves = group.children?.compactMap(\.entry) ?? []
        let open = !state.collapsedModelFamilies.contains(group.id) || !query.text.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if !state.collapsedModelFamilies.insert(group.id).inserted { state.collapsedModelFamilies.remove(group.id) }
            } label: {
                HStack { Text(group.title + " (" + String(leaves.count) + ")").font(.headline); Spacer(); Image(systemName: open ? "chevron.down" : "chevron.right") }.contentShape(Rectangle())
            }.buttonStyle(WorkbenchGlassButtonStyle())
            if open {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: modelResultsWidth >= 572 ? 280 : 1), spacing: 12, alignment: .top), count: modelResultsWidth >= 572 ? 2 : 1), alignment: .leading, spacing: 10) {
                    ForEach(leaves) { entry in modelCard(entry) }
                }
            }
        }.id(group.id)
    }
    private func modelFilter(_ mode: CreatorMode?, title: String) -> some View {
        Button { state.modelModality = mode } label: {
            Text(title).padding(.horizontal, 10).frame(minHeight: 28)
                .background(state.modelModality == mode ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(state.modelModality == mode ? .isSelected : [])
    }
    private func modelCard(_ entry: SharedLibraryBrowserEntry) -> some View {
        SharedModelVariantCard(entry: entry, selected: selectedKeys.contains(entry.id), focused: entryKeyboardFocus == entry.id,
            readiness: readinessName(entry.item.readiness), query: query.text, selectingQuickModel: selectingQuickModel,
            expanded: Binding(get: { state.expandedModelFunctions.contains(entry.id) }, set: { if $0 { state.expandedModelFunctions.insert(entry.id) } else { state.expandedModelFunctions.remove(entry.id) } }),
            choose: { selectedKeys = [entry.id]; focusedKey = entry.id; entryKeyboardFocus = entry.id },
            info: { selectedKeys = [entry.id]; focusedKey = entry.id; compactDetailKey = entry.id },
            add: { function in
                dispatchFunction(selectingQuickModel ? .use : .add, entry: entry, function: function)
            }, drag: { function in
                guard let current = SharedModelLibraryCard.resolve(entry, function: function, current: entries), canAdd(current) else { return NSItemProvider() }
                return SharedLibraryBrowserLogic.dragProvider(for: current, controller: insertionController)
            }, insertionIssue: { function in
                guard let current = SharedModelLibraryCard.resolve(entry, function: function, current: entries), SharedLibraryBrowserLogic.allows(selectingQuickModel ? .use : .add, entry: current) else { return word("unavailable", "当前不可用") }
                return selectingQuickModel ? nil : insertionIssue(current)
            }, prepare: { dispatch(.prepare, key: entry.id) },
            prepareTitle: SharedLibraryBrowserLogic.allows(.prepare, entry: entry) ? prepareLabel(for: entry) : nil)
            .focusable().focused($entryKeyboardFocus, equals: entry.id).focusEffectDisabled()
            .workbenchContextMenu { resourceActions(entry) }
    }

    private var operationNavigation: some View {
        let root = WorkflowOperationTree.make(visible, models: canvasMode == .nodes, language: language)
        var children = root
        var ancestors: [WorkflowOperationTree] = []
        for id in state.operationPath {
            guard let group = children.first(where: { $0.id == id && $0.children != nil }) else { break }
            ancestors.append(group); children = group.children ?? []
        }
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    Button(word("all", "全部")) { state.operationPath = [] }
                    ForEach(Array(ancestors.enumerated()), id: \.element.id) { index, item in
                        Image(systemName: "chevron.right").font(.caption2)
                        Button(item.title) { state.operationPath = Array(ancestors.prefix(index + 1).map(\.id)) }
                    }
                }.buttonStyle(.plain).font(.caption).padding(.vertical, 3)
            }.scrollIndicators(.hidden)
            ForEach(children) { item in
                if let entry = item.entry { entryRow(entry, compact: true) }
                else {
                    Button { state.operationPath = ancestors.map(\.id) + [item.id] } label: {
                        HStack { Text(item.title); Spacer(); Image(systemName: "chevron.right") }
                            .padding(10).frame(maxWidth: .infinity).contentShape(Rectangle())
                            .modifier(WorkbenchItemFeedback(selected: false, focused: false))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var sidebar: some View {
        WorkbenchScrollView {
            VStack(alignment: .leading, spacing: 5) {
                scopeButton(word("all", "全部"), icon: "square.grid.2x2", value: .all)
                Text(word("kind", "类别")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(SharedLibraryItemKind.allCases, id: \.self) { kind in
                    scopeButton(kindName(kind), icon: icon(kind), value: .kind(kind))
                }
                Text(word("myTags", "我的标签")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(tags) { tag in
                    scopeButton(tag.name, icon: "tag", value: .tag(tag.id))
                        .dropDestination(for: String.self) { (keys: [String], _: CGPoint) -> Bool in
                            guard let ids = SharedLibraryBrowserLogic.validatedDropKeys(keys, entries: entries) else { return false }
                            openTagEditor(activityIDs: ids, add: [tag.id]); return true
                        }
                }
                Text(word("folders", "分类")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(folderTree) { folder in
                    scopeButton(folder.name, icon: "folder", value: .folder(folder.id))
                        .padding(.leading, CGFloat(folderDepth(folder.id)) * 10)
                        .dropDestination(for: WorkflowCanvasTransfer.self) { values, _ in acceptCollectionDrop(values, into: .folder(folder.id)) }
                        .dropDestination(for: String.self) { (keys: [String], _: CGPoint) -> Bool in
                            if onCollect != nil, let owner = insertionController?.assetLibraryOwner {
                                guard let ids = SharedLibraryBrowserLogic.validatedDropKeys(keys, entries: entries) else { return false }
                                let selected = entries.filter { ids.contains($0.id) }
                                let sources = selected.compactMap(\.collectionSource)
                                guard sources.count == selected.count, !sources.isEmpty else { return false }
                                return acceptCollectionDrop([.library(owner: owner, sources: sources)], into: .folder(folder.id))
                            }
                            return acceptDrop(keys) { try store.addMembers($0, to: folder.id) }
                        }
                }
                Text(word("savedQueries", "智能筛选")).workbenchHelp("MENU-LIBRARY-SAVED").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(saved) { item in
                    scopeButton(item.name, icon: "line.3.horizontal.decrease.circle", value: .saved(item.id))
                        .dropDestination(for: WorkflowCanvasTransfer.self) { values, _ in acceptCollectionDrop(values, into: .saved(item.id)) }.workbenchHelp("MENU-LIBRARY-SAVED-DYNAMIC", target: item.id.uuidString)
                }
            }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scopeButton(_ title: String, icon: String, value: SharedLibraryBrowserScope) -> some View {
        Button { selectScope(value) } label: {
            Label(title, systemImage: icon).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .padding(5)
                .background(scope == value ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchControls
            Text(word("legend", "能力 / 我的标签")).font(.caption2).foregroundStyle(.secondary)
            bulkControls
            if canvasMode == .nodes {
                WorkbenchScrollView { modelGroups.padding(.bottom, 16) }.scrollPosition(navigationScroll)
            } else if canvasMode == .programs, query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                WorkbenchScrollView { operationNavigation.padding(.bottom, 16) }.scrollPosition(navigationScroll)
            } else if case .failure = visibleResult {
                Spacer()
            } else if visible.isEmpty {
                ContentUnavailableView(word("empty", "没有符合条件的条目"), systemImage: "square.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if canvasMode == .image || canvasMode == .video || (canvasMode == nil && query.contentKinds.count == 1 && (query.contentKinds.contains(.image) || query.contentKinds.contains(.video))) {
                WorkbenchScrollView { resourceGrid.padding(.bottom, 16) }
                    .scrollPosition(navigationScroll).accessibilityIdentifier("shared-library-results")
            } else {
                List(selection: $state.selectedKeys) {
                    ForEach(visible) { entry in entryRow(entry, compact: false).tag(entry.id) }
                }.listStyle(.plain).contentMargins(.bottom, 16, for: .scrollContent).scrollPosition(navigationScroll).accessibilityIdentifier("shared-library-results")
            }
            searchFooter
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 16)
    }

    private func tagTarget(_ entry: SharedLibraryBrowserEntry) -> SharedLibraryTagTarget {
        let identity: String
        if case .assetInstance(_, let instance, _) = entry.selection { identity = String(instance.uuidString.prefix(8)) }
        else { identity = entry.id }
        return .init(key: entry.item.key, title: entry.item.title + " · " + identity, legacy: entry.legacyTags, legacyFailure: entry.legacyFailure, activityID: entry.id, contentKind: entry.item.contentKind, inputs: entry.item.inputs, outputs: entry.item.outputs)
    }
    private func openTagEditor(activityIDs: Set<String>, add: Set<UUID> = [], remove: Set<UUID> = []) {
        let selected = SharedLibraryBrowserLogic.tagEditEntries(activityIDs, in: entries)
        tagRequest = .init(targets: selected.map(tagTarget), validations: selected.map(tagValidation), add: add, remove: remove)
    }
    private var scopeTitle: String {
        switch scope {
        case .all: word("registered", "已登记条目")
        case .kind(let value): kindName(value)
        case .tag(let id): word("myTags", "我的标签") + ": " + (store.metadata.tags[id]?.name ?? "—")
        case .folder(let id): word("folders", "分类") + ": " + (store.metadata.folders[id]?.name ?? "—")
        case .saved(let id): word("savedQueries", "智能筛选") + ": " + (store.metadata.savedQueries[id]?.name ?? "—")
        }
    }
    private var searchMore: some View {
                    WorkbenchMenu {
                        if allowsImport { WorkbenchMenuAction(layoutText(language, "importAsset"), action: onImport) }
                        WorkbenchMenuAction(layoutText(language, "saveFilter")) { openSaveQuery() }.featureHelp("QUERY-SAVE", language: language)
                        WorkbenchMenuAction(word("advancedConditions", "高级条件")) { showFilters = true }
                        WorkbenchSubmenu(consistencyText(language, "menu.library.saved")) { WorkbenchMenuForEach(saved) { item in WorkbenchMenuAction(item.name) { selectScope(.saved(item.id)) } } }
                        WorkbenchMenuAction(consistencyText(language, "menu.library.manage")) { showOrganizer = true }
                        WorkbenchMenuDivider()
                        WorkbenchMenuAction(word("undo", "撤销")) { perform { try store.undo() } }.disabled(!store.canUndo)
                        WorkbenchMenuAction(word("redo", "重做")) { perform { try store.redo() } }.disabled(!store.canRedo)
                        if onCollect != nil, let controller = insertionController, let owner = controller.assetLibraryOwner {
                            WorkbenchMenuDivider()
                            WorkbenchMenuAction(workflowText(language, "container.library.undoCollection")) {
                                updateCollectionHistory(controller, owner: owner, redo: false)
                            }.disabled(!controller.canUndoCollection)
                            WorkbenchMenuAction(workflowText(language, "container.library.redoCollection")) {
                                updateCollectionHistory(controller, owner: owner, redo: true)
                            }.disabled(!controller.canRedoCollection)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel(word("more", "更多"))
                        .accessibilityIdentifier("shared-library-more")
    }
    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(word("search", "搜索名称、说明或我的标签"), text: searchTextBinding)
                    .textFieldStyle(.plain).focused($searchFocused).onSubmit { submitSearch() }
                    .accessibilityIdentifier("shared-library-search").workbenchHelp("LIB-SEARCH")
                if onCollect == nil { tagSearchControl }
                Button { submitSearch() } label: { Image(systemName: "magnifyingglass").padding(6).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(word("searchNow", "搜索"))
                if onCollect == nil { searchMore }
            }.padding(7).workbenchInputSurface()
            if state.hasUnsubmittedText {
                Text(word("searchPending", "待搜索 · 当前仍显示上次搜索结果")).font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                WorkbenchMenu(onCollect != nil && scope == .all ? workflowText(language, state.collectedOnly ? "container.library.collected" : "container.library.all") : scopeTitle) {
                    if onCollect != nil {
                        WorkbenchMenuAction(workflowText(language, "container.library.collected")) { state.collectedOnly = true; selectScope(.all) }
                        WorkbenchMenuAction(workflowText(language, "container.library.all")) { state.collectedOnly = false; selectScope(.all) }
                    } else { WorkbenchMenuAction(word("all", "全部")) { selectScope(.all) } }
                    if onCollect == nil { WorkbenchMenuForEach(SharedLibraryItemKind.allCases, id: \.self) { kind in WorkbenchMenuAction(kindName(kind)) { selectScope(.kind(kind)) } } }
                    WorkbenchMenuForEach(folders) { folder in WorkbenchMenuAction(folder.name) { selectScope(.folder(folder.id)) } }
                    WorkbenchMenuForEach(saved) { saved in WorkbenchMenuAction(saved.name) { selectScope(.saved(saved.id)) } }
                }.font(.caption)
                if onCollect != nil { tagSearchControl }
                Spacer(minLength: 0)
                if onCollect != nil {
                    WorkbenchMenu {
                        WorkbenchMenuForEach(SharedLibraryAssetSort.allCases, id: \.self) { order in
                            WorkbenchMenuAction(workflowText(language, "container.sort." + order.rawValue)) { state.assetSort = order }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 28, height: 28) }
                        .accessibilityLabel(workflowText(language, "container.sort.title"))
                        .help(workflowText(language, "container.sort." + state.assetSort.rawValue))
                }
            }
            if query.scope != nil || query.properties?.isEmpty == false {
                SharedLibraryPropertySummary(query: Binding(get: { query }, set: { query = $0 }), items: entries.map(\.item), context: queryContext, store: store, fixedScopeDescription: scopeTitle)
            }
            if query.textTagCombination == .any { Text(word("logicAnyBadge", "文字或标签任一符合")).font(.caption.weight(.semibold)).foregroundStyle(.tint) }
            if hasSearchTokens { ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    if scope != .all { token(scopeTitle) { selectScope(.all) } }
                    if !query.text.isEmpty { token(query.text) { query.text = "" } }
                    ForEach(WorkflowResultQueryState.tagConditions(query.allTagIDs, store: store, missingLabel: metadataText(language, "deletedTagCondition")), id: \.id) { tag in token(word("allTags", "同时包含标签") + ": " + state.tagPresentation.title(tag.id, tags: store.metadata.tags, missing: metadataText(language, "deletedTagCondition"))) { query.allTagIDs.remove(tag.id) } }
                    ForEach(WorkflowResultQueryState.tagConditions(query.anyTagIDs, store: store, missingLabel: metadataText(language, "deletedTagCondition")), id: \.id) { tag in token(word("anyTags", "至少一个标签") + ": " + state.tagPresentation.title(tag.id, tags: store.metadata.tags, missing: metadataText(language, "deletedTagCondition"))) { query.anyTagIDs.remove(tag.id) } }
                    dimensionTokens(query.kinds, path: \.kinds, label: kindName)
                    dimensionTokens(query.roles, path: \.roles, label: { $0 })
                    dimensionTokens(query.inputs, path: \.inputs, label: { word("inputs", "输入能力") + ": " + dataName($0) })
                    dimensionTokens(query.outputs, path: \.outputs, label: { word("outputs", "输出能力") + ": " + dataName($0) })
                    dimensionTokens(query.contentKinds, path: \.contentKinds, label: dataName)
                    dimensionTokens(query.readiness, path: \.readiness, label: readinessName)
                    dimensionTokens(query.compatibility, path: \.compatibility, label: compatibilityName)
                    factTokens(\.concepts); factTokens(\.producers); factTokens(\.consumers); factTokens(\.formats)
                }
            }.scrollIndicators(.hidden) }
            if !query.allTagIDs.union(query.anyTagIDs).filter({ store.metadata.tags[$0] == nil }).isEmpty {
                WorkflowTechnicalDetails(value: query.allTagIDs.union(query.anyTagIDs).filter { store.metadata.tags[$0] == nil }.sorted { $0.uuidString < $1.uuidString }.map { state.tagPresentation.title($0, tags: store.metadata.tags, missing: metadataText(language, "deletedTagCondition")) + ": " + $0.uuidString }.joined(separator: "\n"))
            }
        }
    }
    private var tagSearchControl: some View {
        Button { showTags.toggle() } label: {
            HStack(spacing: 3) { Image(systemName: "tag"); if onCollect != nil { Text(workflowText(language, "container.library.tags")); Image(systemName: "chevron.down").font(.caption2) } }
                .padding(6).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(word("conditions", "条件"))
            .workbenchPopover(isPresented: $showTags, title: workflowText(language, "childPanel.name.tags"), arrowEdge: .bottom) { queryTagPopover }
    }
    private var searchFooter: some View {
            HStack {
                if case .failure = visibleResult {
                    Text(metadataText(language, "countUnavailable")).font(.caption2)
                } else {
                    Text("\(visible.count)/\(entries.count) " + word("locations", "结果位置")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                WorkbenchFeatureGuideButton(store: featureHelp)
            }
    }
    private var hasSearchTokens: Bool {
        query.facts?.isEmpty == false || scope != .all || !query.text.isEmpty || !query.allTagIDs.isEmpty || !query.anyTagIDs.isEmpty
            || !query.kinds.isEmpty || !query.roles.isEmpty || !query.inputs.isEmpty || !query.outputs.isEmpty
            || !query.contentKinds.isEmpty || !query.readiness.isEmpty || !query.compatibility.isEmpty
    }
    private func countAddingTag(_ id: UUID) -> Int {
        var value = query; value.allTagIDs.insert(id)
        return Set(((try? SharedLibraryBrowserLogic.visibleEntries(entries, store: store, query: value, scope: scope, context: queryContext)) ?? []).map(\.item.key)).count
    }
    private func token(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) { HStack(spacing: 3) { Text(title); Image(systemName: "xmark") }.padding(4) }
            .buttonStyle(WorkbenchGlassButtonStyle()).font(.caption2).help(word("removeCondition", "仅移除检索条件，不改变对象标签"))
    }
    private func dimensionTokens<T: Hashable>(_ values: Set<T>, path: WritableKeyPath<SharedLibraryQuery, Set<T>>, label: @escaping (T) -> String) -> some View {
        ForEach(Array(values).sorted { label($0) < label($1) }, id: \.self) { value in token(label(value)) { query[keyPath: path].remove(value) } }
    }

    private func updateCollectionHistory(_ controller: WorkflowController, owner: WorkflowAssetLibraryOwner, redo: Bool) {
        Task {
            do {
                guard insertionController === controller, controller.assetLibraryOwner == owner,
                      controller.canEditLibraryMetadata else { throw SharedLibraryError.staleAnnotation }
                if redo { try await controller.redoCollection() } else { try await controller.undoCollection() }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func editFolderMembership(_ values: [SharedLibraryBrowserEntry], validations: [() throws -> Void], folder: UUID, adding: Bool) {
        perform {
            let keys = try SharedLibraryBrowserLogic.validatedOrganizationKeys(values, validations: validations)
            if adding { try store.addMembers(keys, to: folder) } else { try store.removeMembers(keys, from: folder) }
        }
    }

    private var bulkControls: some View {
        let capturedSelection = validSelection
        let capturedEntries = selectedMetadataEntries
        let capturedKeys = Set(capturedEntries.map { $0.item.key })
        let validations = capturedEntries.map(tagValidation)
        return HStack(spacing: 6) {
            Text(word("selected", "已选") + " \(validSelection.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            WorkbenchMenu {
                WorkbenchMenuAction(word("editTags", "编辑所选对象标签…")) { openTagEditor(activityIDs: capturedSelection) }
                WorkbenchMenuForEach(tags) { tag in
                    WorkbenchMenuAction(word("addTag", "添加标签") + " · " + tag.name) {
                        openTagEditor(activityIDs: capturedSelection, add: [tag.id])
                    }
                    WorkbenchMenuAction(word("removeTag", "移除标签") + " · " + tag.name) {
                        openTagEditor(activityIDs: capturedSelection, remove: [tag.id])
                    }
                }
                if tags.isEmpty { WorkbenchMenuText(word("noTags", "尚无我的标签")) }
            } label: { Label(word("bulkTags", "批量标签"), systemImage: "tag") }
                .disabled(selectedTagKeys.isEmpty)
            WorkbenchMenu {
                WorkbenchMenuForEach(folders) { folder in
                    WorkbenchMenuAction(word("addToFolder", "加入分类") + " · " + folder.name) {
                        editFolderMembership(capturedEntries, validations: validations, folder: folder.id, adding: true)
                    }
                    WorkbenchMenuAction(word("removeFromFolder", "移出分类") + " · " + folder.name) {
                        editFolderMembership(capturedEntries, validations: validations, folder: folder.id, adding: false)
                    }
                }
                if folders.isEmpty { WorkbenchMenuText(word("noFolders", "尚无分类")) }
            } label: { Label(word("bulkFolders", "批量分类"), systemImage: "folder") }
                .disabled(selectedMetadataKeys.isEmpty)
        }.font(.caption).environment(\.workbenchMenuContext, "bulk:\(ObjectIdentifier(store)):\(ObjectIdentifier(state)):\(capturedSelection.sorted()):\(capturedKeys.sorted())")
    }

    @ViewBuilder private func entryRow(_ entry: SharedLibraryBrowserEntry, compact: Bool) -> some View {
        let addIssue = insertionIssue(entry)
        let row = HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon(entry.item.kind)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.title).font(.callout.weight(.medium)).lineLimit(2)
                if entry.item.kind == .asset, entry.item.contentKind == .text, let readPreview {
                    WorkflowLibraryPreview(entry: entry, cache: state.previewCache, pixels: 160, load: { try await readPreview(entry) }).frame(height: 34)
                } else { Text(entry.item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if entry.item.kind == .model {
                    ModelSpecificationSummary(descriptor: ModelNodeCatalog.entries.first { $0.id == entry.item.key })
                    if case .operation(let id, _) = entry.selection, let definition = WorkflowRegistry.standard.operation(id)?.definition {
                        Text(WorkflowCanvasPresentation.operationDetail(definition, language: language)).font(.caption).lineLimit(2)
                    }
                    Text(entry.item.inputs.map(dataName).sorted().joined(separator: "/") + " → " + entry.item.outputs.map(dataName).sorted().joined(separator: "/"))
                        .font(.caption).lineLimit(2)
                }
                if !(store.metadata.tagAssignments[entry.item.key] ?? []).isEmpty {
                    Text(assignedTagNames(entry.item.key)).font(.caption2).lineLimit(2)
                }
                if !entry.legacyTags.isEmpty && !store.metadata.importedLegacyKeys.contains(entry.item.key) {
                    Text(word("legacy", "有尚未整合的旧标签")).font(.caption2).foregroundStyle(.secondary)
                }
                Text(readinessName(entry.item.readiness) + " · " + kindName(entry.item.kind))
                    .font(.caption2).foregroundStyle(.secondary)
                if let reason = addIssue {
                    Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if compact {
                if canPreview(entry), canvasMode?.resourceCategory != nil {
                    Button { dispatch(.preview,key:entry.id) } label: { Image(systemName:"arrow.up.right.square") }
                        .buttonStyle(WorkbenchGlassButtonStyle(compact:true))
                        .accessibilityLabel(word("preview","预览"))
                }
                Button {
                    if selectedKeys.contains(entry.id) { selectedKeys.remove(entry.id) }
                    else { selectedKeys.insert(entry.id) }
                    focusedKey = entry.id
                    entryKeyboardFocus = entry.id
                } label: {
                    Image(systemName: selectedKeys.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(WorkbenchGlassButtonStyle(compact: true))
                .accessibilityLabel(selectedKeys.contains(entry.id)
                    ? word("deselect", "取消选择") : word("select", "选择"))
                if !selectingQuickModel, SharedLibraryBrowserLogic.allows(.add, entry: entry) {
                    Button { dispatch(.add,key:entry.id) } label: { Image(systemName:"plus.circle") }
                        .buttonStyle(WorkbenchGlassButtonStyle(compact:true))
                        .accessibilityLabel(word("addCanvas","添加画布"))
                        .disabled(addIssue != nil).help(addIssue ?? word("addCanvas", "添加画布"))
                }
                Button { compactDetailKey=entry.id } label: { Image(systemName:"info.circle") }
                    .buttonStyle(WorkbenchGlassButtonStyle(compact:true))
                    .accessibilityLabel(word("detail","详情"))
            }
        }
        .padding(6)
        .modifier(WorkbenchItemFeedback(selected: selectedKeys.contains(entry.id), focused: entryKeyboardFocus == entry.id))
        .contentShape(Rectangle())
        .onTapGesture {
            focusedKey = entry.id
            if compact { entryKeyboardFocus = entry.id }
            if compact { selectedKeys = [entry.id]; if canvasMode?.resourceCategory == nil { compactDetailKey = entry.id } }
        }
        .accessibilityIdentifier("shared-library-entry-" + entry.id)
        VStack(alignment: .leading, spacing: 4) {
            row.workbenchContextMenu { resourceActions(entry) }.onDrag { dragProvider(for: entry.id) } preview: { dragPreview(for: entry.id) }
                .onTapGesture(count:2) { if entry.item.kind == .asset,canPreview(entry) { dispatch(.preview,key:entry.id) } }
                .focusable().focused($entryKeyboardFocus, equals: entry.id).focusEffectDisabled()
                .onKeyPress(.space) { guard entry.item.kind == .asset,canPreview(entry) else { return .ignored }; dispatch(.preview,key:entry.id);return .handled }
            if let ids = store.metadata.tagAssignments[entry.item.key], !ids.isEmpty {
                HStack {
                    ForEach(tags.filter { ids.contains($0.id) }) { tag in
                        Button(tag.name) { query.allTagIDs.insert(tag.id) }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
                            .help(metadataText(language, "tagFiltersOnly"))
                    }
                }.font(.caption).padding(.horizontal, 6)
            }
        }
    }

    @WorkbenchMenuBuilder private func resourceActions(_ entry: SharedLibraryBrowserEntry) -> WorkbenchMenuRows {
        if let onCollect, entry.item.kind == .asset {
            WorkbenchMenuAction(workflowText(language, entry.collected ? "container.library.remove" : "container.library.add"), id: "asset.collection") { onCollect([entry], !entry.collected) }
        }
        if canPreview(entry) { WorkbenchMenuAction(word("viewReadOnly", "在 D 内只读查看")) { dispatch(.preview, key: entry.id) } }
        WorkbenchMenuAction(word("detailsAndTags", "详情、名称与标签…")) { focusedKey = entry.id; compactDetailKey = compact ? entry.id : nil }
        if entry.item.kind == .asset, entry.runtimeValue == nil || entry.runtimeValue?.reference != nil, let onExternalCopy {
            WorkbenchMenuAction(word("openExternalCopy", "用外部应用打开独立副本…")) {
                guard let current = SharedLibraryBrowserLogic.currentEntry(key: entry.id, entries: entries, action: .preview), current.selection == entry.selection else { return }
                onExternalCopy(current)
            }
        }
        if SharedLibraryBrowserLogic.allows(.location, entry: entry) { WorkbenchMenuAction(word("location", "在访达显示来源")) { dispatch(.location, key: entry.id) } }
        if !selectingQuickModel, SharedModelLibraryCard.functions(entry).count <= 1, SharedLibraryBrowserLogic.allows(.add, entry: entry) { WorkbenchMenuAction(word("addCanvas", "添加画布")) { dispatch(.add, key: entry.id) }.disabled(!canAdd(entry)) }
    }

    private var detailPane: some View {
        WorkbenchScrollView {
            if let entry = selectedEntry { details(entry).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 16) }
            else { Text(word("choose", "选择条目以查看详情")).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 16) }
        }
    }

    private func details(_ entry: SharedLibraryBrowserEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !visible.contains(where: { $0.id == entry.id }) {
                Text(metadataText(language, "filteredSelection")).font(.caption).foregroundStyle(.orange)
            }
            Text(entry.item.title).font(.headline).textSelection(.enabled)
            Text(entry.item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text(word("legend", "能力 / 我的标签")).font(.caption2).foregroundStyle(.secondary)
            Divider()
            let functions = entry.item.kind == .model ? SharedModelLibraryCard.functions(entry) : []
            if functions.count > 1 {
                ForEach(functions, id: \.id) { function in
                    HStack {
                        Text(WorkflowCanvasPresentation.operationTitle(function, language: language))
                        Spacer()
                        Button(word("quickUse", "快速用")) { dispatchFunction(.use, entry: entry, function: function.id) }
                            .disabled(!canUse(entry))
                        if !selectingQuickModel {
                            Button(word("addCanvas", "添加画布")) { dispatchFunction(.add, entry: entry, function: function.id) }
                                .disabled(SharedModelLibraryCard.resolve(entry, function: function.id, current: entries).map { !canAdd($0) } ?? true)
                        }
                    }
                }
            }
            if functions.count <= 1, canUse(entry) {
                Button(word("quickUse", "快速用")) { dispatch(.use, key: entry.id) }
                    .accessibilityIdentifier("shared-library-use")
                if entry.item.readiness != .available {
                    Text(word("draftOnly", "快速用仅选择草稿，不会执行；就绪状态仍如上所示。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !selectingQuickModel, functions.count <= 1, SharedLibraryBrowserLogic.allows(.add, entry: entry) {
                Button(word("addCanvas", "添加画布")) { dispatch(.add, key: entry.id) }
                    .accessibilityIdentifier("shared-library-add").workbenchHelp("LIB-ENTRY-ADD", target: "entry:\(entry.id):\(entry.selection):\(entry.metadataSnapshot?.instanceID)")
                    .disabled(!canAdd(entry))
                if let reason = insertionIssue(entry) { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }
            if canPreview(entry) {
                Button(word("preview", "预览")) { dispatch(.preview, key: entry.id) }
                    .accessibilityIdentifier("shared-library-preview").workbenchHelp("LIB-ENTRY-INFO", target: "entry:\(entry.id):\(entry.selection):\(entry.metadataSnapshot?.instanceID)")
            }
            if case .runtime(let source) = entry.collectionSource, let navigation = containerNavigation {
                Button(workflowText(language, "container.locateSource")) { navigation.source(source.call) }
                    .accessibilityIdentifier("shared-library-locate-source")
            }
            if SharedLibraryBrowserLogic.allows(.location, entry: entry) {
                Button(word("location", "查看文件位置…")) { dispatch(.location, key: entry.id) }
                    .accessibilityIdentifier("shared-library-location")
            }
            if SharedLibraryBrowserLogic.allows(.prepare, entry: entry) {
                Button(prepareLabel(for: entry)) { dispatch(.prepare, key: entry.id) }
                    .accessibilityIdentifier("shared-library-prepare")
            }
            detailLine(word("kind", "类别"), kindName(entry.item.kind))
            detailLine(word("readiness", "就绪状态"), readinessName(entry.item.readiness))
            detailLine(word("compatibility", "兼容性"), compatibilityName(entry.item.compatible))
            if !entry.item.role.isEmpty { detailLine(word("role", "用途"), entry.item.role) }
            detailLine(word("inputs", "输入能力"), kindList(entry.item.inputs))
            detailLine(word("outputs", "输出能力"), kindList(entry.item.outputs))
            if let kind = entry.item.contentKind { detailLine(word("content", "内容类型"), dataName(kind)) }
            if !entry.facts.isEmpty {
                WorkflowTechnicalDetails(value: entry.facts.joined(separator: "\n") + "\n" + entry.item.key)
            }
            if let snapshot = entry.metadataSnapshot {
                SharedAssetMetadataPanel(snapshot: snapshot, library: store, validate: tagValidation(entry), save: annotationSave(entry),
                    onQuery: { properties in
                        var next = query; next.properties = SharedLibraryPropertyQuery.merging(next.properties, properties)
                        state.setDraftQuery(next)
                    }, onOpenSource: { reference in
                        let matches = entries.filter { $0.metadataSnapshot?.record?.reference == reference }
                        let sameInstance = matches.filter { $0.metadataSnapshot?.instanceID == snapshot.instanceID }
                        if let target = sameInstance.first ?? (matches.count == 1 ? matches.first : nil) {
                            focusedKey = target.id; compactDetailKey = compact ? target.id : nil
                        } else { errorMessage = metadataText(language, "sourceMissing") }
                    })
            } else if let runtime = entry.runtimeValue, let identity = runtime.annotationIdentity {
                RuntimeValueMetadataPanel(value: runtime, identity: identity, title: entry.item.title, library: store, validate: tagValidation(entry))
            } else if entry.runtimeValue == nil {
                SharedLibraryTagSection(store: store, target: tagTarget(entry), validateTarget: tagValidation(entry))
            }
            if case .unavailable(let reason) = entry.selection {
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(value).font(.caption).textSelection(.enabled)
        }
    }

    private func assignedTagNames(_ key: String) -> String {
        let assigned = store.metadata.tagAssignments[key] ?? []
        let names = tags.filter { assigned.contains($0.id) }.map(\.name).joined(separator: " · ")
        return names.isEmpty ? word("none", "无") : names
    }

    private var filterToken: String {
        String(describing: ObjectIdentifier(state)) + String(describing: ObjectIdentifier(store)) + String(describing: scope)
            + String(describing: queryContext.projectID) + String(describing: queryContext.instanceID)
    }
    private var filterPopover: some View {
        SharedLibraryFilterEditor(query: query, token: filterToken, store: store, items: entries.map(\.item), context: queryContext, scopeTitle: scopeTitle,
            current: { (query, filterToken) }, apply: { query = $0 }, close: { showFilters = false })
    }
    private func openSaveQuery() {
        guard workflowContext == nil else {
            errorMessage=workspaceText(language, "relatedSaveScope")
            return
        }
        do {
            let captured = try SharedLibraryBrowserLogic.queryForSaving(query, scope: scope, store: store)
            saveQueryRequest = .init(query: captured, scopeTitle: scopeTitle, tagTitles: Dictionary(uniqueKeysWithValues: captured.allTagIDs.union(captured.anyTagIDs).map { ($0, state.tagPresentation.title($0, tags: store.metadata.tags, missing: metadataText(language, "deletedTagCondition"))) }))
        } catch { errorMessage = sharedLibraryErrorText(error, language: language) }
    }

    private func filterGroup<Value: Hashable>(
        _ title: String, values: [Value],
        keyPath: WritableKeyPath<SharedLibraryQuery, Set<Value>>,
        label: @escaping (Value) -> String
    ) -> some View {
        WorkbenchMenu(title + " (\(query[keyPath: keyPath].count))") {
            WorkbenchMenuForEach(values, id: \.self) { value in
                WorkbenchMenuToggle(label(value), isOn: setBinding(keyPath, value))
            }
        }
    }

    private func submitSearch() {
        let composing = (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
        state.submitSearch(hasMarkedText: composing)
    }

    private var queryTagPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(word("tagSearch", "搜索或新建标签"), text: $tagSearch)
                Button(word("newTag", "新建标签")) {
                    perform {
                        let id = try store.createTags([tagSearch]).first!
                        query.allTagIDs.insert(id); tagSearch = ""
                    }
                }.disabled(tagSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            WorkbenchScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(word("systemTags", "预置条件")).font(.headline)
                    if canvasMode?.resourceCategory != nil || scope == .kind(.asset) || canvasMode == nil {
                        contentConditionGroup(word("content", "素材内容"), path: \.contentKinds)
                        factConditions(word("concept", "内容用途"), path: \.concepts)
                        factConditions(word("producer", "生产方"), path: \.producers)
                        factConditions(word("consumer", "候选接收方 · 结构另验"), path: \.consumers)
                        factConditions(word("format", "实际格式"), path: \.formats)
                    }
                    if canvasMode?.resourceCategory == nil && scope != .kind(.asset) {
                        contentConditionGroup(word("inputs", "可接收"), path: \.inputs)
                        contentConditionGroup(word("outputs", "可输出"), path: \.outputs)
                        factConditions(word("model", "模型 / 实现"), path: \.producers)
                    }
                    Divider()
                    Text(word("myTags", "我的标签")).font(.headline)
                    ForEach(tags.filter { tagSearch.isEmpty || $0.name.localizedStandardContains(tagSearch) }) { tag in
                        Toggle(tag.name, isOn: setBinding(\.allTagIDs, tag.id))
                    }
                    if tags.isEmpty { Text(word("noTags", "尚无我的标签")).foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 340)
            DisclosureGroup(word("searchLogic", "匹配方式")) {
            Picker(word("textTagLogic", "文字与标签"), selection: Binding(get: { query.textTagCombination ?? .all }, set: { query.textTagCombination = $0 })) {
                Text(word("logicAll", "全部符合")).tag(SharedLibrarySearchCombination.all)
                Text(word("logicAny", "任一符合")).tag(SharedLibrarySearchCombination.any)
            }
            }
            Text(word("queryOnly", "此处只修改搜索条件，不给结果添加标签。")).font(.caption).foregroundStyle(.secondary)
        }.padding(14).frame(width: 320).workbenchPresentation()
    }

    private func contentConditionGroup(_ title: String, path: WritableKeyPath<SharedLibraryQuery, Set<WorkflowDataKind>>) -> some View {
        DisclosureGroup(title) {
            ForEach(SharedLibraryContentGroup.allCases, id: \.self) { group in
                let label = word("contentGroup." + group.rawValue, ["text":"文字与文档", "image":"图像", "video":"视频", "audio":"音频", "other":"其他"] [group.rawValue] ?? "其他")
                if tagSearch.isEmpty || label.localizedStandardContains(tagSearch) {
                    Toggle(label, isOn: Binding(get: { group.kinds.isSubset(of: query[keyPath: path]) }, set: { enabled in
                        if enabled { query[keyPath: path].formUnion(group.kinds) }
                        else { query[keyPath: path].subtract(group.kinds) }
                    }))
                }
            }
        }
    }
    private func factConditions(_ title: String, path: WritableKeyPath<SharedLibraryFactConditions, Set<String>>) -> some View {
        let known = Set(entries.flatMap { $0.item.facts[keyPath: path] })
        let selected = (query.facts ?? .init())[keyPath: path]
        return DisclosureGroup(title) {
            ForEach(known.union(selected).sorted(), id: \.self) { value in
                if tagSearch.isEmpty || value.localizedStandardContains(tagSearch) || factLabel(value, concept: path == \.concepts).localizedStandardContains(tagSearch) {
                    Toggle(factLabel(value, concept: path == \.concepts) + (known.contains(value) ? "" : " · " + word("unknownCondition", "当前范围未记录")), isOn: Binding(get: { selected.contains(value) }, set: { included in
                        var facts = query.facts ?? .init()
                        if included { facts[keyPath: path].insert(value) } else { facts[keyPath: path].remove(value) }
                        query.facts = facts.isEmpty ? nil : facts
                    }))
                }
            }
            if known.isEmpty && selected.isEmpty { Text(word("factUnrecorded", "当前范围尚未记录此项事实")).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func factLabel(_ value: String, concept: Bool = false) -> String {
        if concept { return SharedLibraryConceptPresentation.label(value, language: language) }
        if value.hasPrefix("content."), let kind = WorkflowDataKind(rawValue: String(value.dropFirst(8))) { return WorkflowCanvasPresentation.kind(kind, language: language) }
        if let definition = WorkflowRegistry.standard.operation(value)?.definition { return WorkflowCanvasPresentation.operationTitle(definition, language: language) }
        if let descriptor = ModelNodeCatalog.entries.first(where: { $0.modelIdentity == value }) { return descriptor.title }
        return value
    }
    private func factTokens(_ path: WritableKeyPath<SharedLibraryFactConditions, Set<String>>) -> some View {
        ForEach((query.facts ?? .init())[keyPath: path].sorted(), id: \.self) { value in
            token(factLabel(value, concept: path == \.concepts)) { var facts = query.facts ?? .init(); facts[keyPath: path].remove(value); query.facts = facts.isEmpty ? nil : facts }
        }
    }

    private var searchTextBinding: Binding<String> {
        Binding(get: { state.draftText }, set: { state.draftText = String($0.prefix(256)) })
    }

    private func setBinding<Value: Hashable>(
        _ path: WritableKeyPath<SharedLibraryQuery, Set<Value>>, _ value: Value
    ) -> Binding<Bool> {
        Binding(get: { query[keyPath: path].contains(value) }, set: { included in
            if included { query[keyPath: path].insert(value) }
            else { query[keyPath: path].remove(value) }
        })
    }

    private var filterSummary: String {
        let current = query
        var parts: [String] = []
        func include(_ names: [String]) {
            if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        }
        let kindNames: [String] = current.kinds.map { kindName($0) }
        let inputNames: [String] = current.inputs.map { dataName($0) }
        let outputNames: [String] = current.outputs.map { dataName($0) }
        let contentNames: [String] = current.contentKinds.map { dataName($0) }
        let readinessNames: [String] = current.readiness.map { readinessName($0) }
        let compatibilityNames: [String] = current.compatibility.map { compatibilityName($0) }
        include(kindNames.sorted())
        include(current.roles.sorted())
        include(inputNames.sorted())
        include(outputNames.sorted())
        include(contentNames.sorted())
        include(readinessNames.sorted())
        include(compatibilityNames.sorted())
        include(tags.filter { current.anyTagIDs.contains($0.id) }.map(\.name))
        include(tags.filter { current.allTagIDs.contains($0.id) }.map(\.name))
        return parts.isEmpty ? word("noFilters", "未选择筛选") : parts.joined(separator: " · ")
    }

    private enum OrganizerTab: String, CaseIterable { case tags, folders, saved }

    private var organizer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WorkbenchRequestCloseButton(title: workflowText(language, "childPanel.close"), fallback: { showOrganizer = false })
                Text(word("organize", "整理资料库")).font(.headline)
                Spacer()
            }
            WorkbenchGlassSegments(title: word("organize", "整理资料库"), selection: $tab,
                choices: [(OrganizerTab.tags, word("myTags", "我的标签")), (.folders, word("folders", "分类")), (.saved, word("savedQueries", "智能筛选"))], owner: AnyHashable(ObjectIdentifier(store)))

            Text(word("legend", "能力 / 我的标签")).font(.caption).foregroundStyle(.secondary)
            switch tab {
            case .tags: tagOrganizer
            case .folders: folderOrganizer
            case .saved: savedOrganizer
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .workbenchCloseProtection(isDirty: !newName.isEmpty || renameDrafts.hasDrafts)
    }

    private var tagOrganizer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(word("newTag", "新标签"), text: $newName)
                Button(word("create", "创建")) {
                    perform { _ = try store.createTags([newName]); newName = "" }
                }
            }
            List(selection: $selectedTagID) {
                ForEach(tags) { tag in Text(tag.name).tag(tag.id) }
            }
            HStack {
                TextField(word("rename", "重命名"), text: renameBinding(
                    selectedTagID.map { .tag($0) },
                    canonical: selectedTagID.flatMap { store.metadata.tags[$0]?.name } ?? ""
                ))
                Button(word("rename", "重命名")) {
                    guard let id = selectedTagID else { return }
                    let item = SharedLibraryBrowserOrganizerItem.tag(id)
                    let name = renameDrafts.text(for: item, canonical: store.metadata.tags[id]?.name ?? "")
                    if perform({ try store.renameTags([id: name]) }) { renameDrafts.clear(item) }
                }.disabled(selectedTagID == nil)
                Button(word("delete", "删除"), role: .destructive) {
                    guard let id = selectedTagID else { return }
                    if perform({ try SharedLibraryBrowserLogic.deleteTag(id, store: store, state: state) }) {
                        selectedTagID = nil
                        renameDrafts.clear(.tag(id))
                    }
                }.disabled(selectedTagID == nil)
            }
            if let id = selectedTagID {
                HStack {
                    Button(word("addSelected", "给已选条目添加")) {
                        openTagEditor(activityIDs: validSelection, add: [id])
                    }
                    Button(word("removeSelected", "从已选条目移除")) {
                        openTagEditor(activityIDs: validSelection, remove: [id])
                    }
                }.disabled(selectedTagKeys.isEmpty)
            }
        }
    }

    private var folderOrganizer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(word("newFolder", "新分类"), text: $newName)
                Button(word("create", "创建")) {
                    perform { _ = try store.createFolder(name: newName, parentID: parentID); newName = "" }
                }
            }
            List(selection: $selectedFolderID) {
                ForEach(folderTree) { folder in
                    Text(String(repeating: "  ", count: folderDepth(folder.id)) + folder.name).tag(folder.id)
                }
            }
            .onChange(of: selectedFolderID) { _, id in
                parentID = id.flatMap { store.metadata.folders[$0]?.parentID }
            }
            HStack {
                TextField(word("rename", "重命名"), text: renameBinding(
                    selectedFolderID.map { .folder($0) },
                    canonical: selectedFolderID.flatMap { store.metadata.folders[$0]?.name } ?? ""
                ))
                Button(word("rename", "重命名")) {
                    guard let id = selectedFolderID else { return }
                    let item = SharedLibraryBrowserOrganizerItem.folder(id)
                    let name = renameDrafts.text(for: item, canonical: store.metadata.folders[id]?.name ?? "")
                    if perform({ try store.renameFolder(id, to: name) }) { renameDrafts.clear(item) }
                }.disabled(selectedFolderID == nil)
                Button(word("delete", "删除"), role: .destructive) {
                    guard let id = selectedFolderID else { return }
                    if perform({ try SharedLibraryBrowserLogic.deleteFolder(id, store: store, state: state) }) {
                        selectedFolderID = nil
                        renameDrafts.clear(.folder(id))
                    }
                }.disabled(selectedFolderID == nil)
            }
            HStack {
                WorkbenchPicker(word("parent", "上级分类"), selection: $parentID) {
                    WorkbenchChoice(word("root", "顶层"), value:UUID?.none)
                    WorkbenchChoiceForEach(folders) { folder in WorkbenchChoice(folder.name, value:Optional(folder.id)) }
                }
                Button(word("move", "移动分类")) {
                    guard let id = selectedFolderID else { return }
                    perform { try store.moveFolder(id, under: parentID) }
                }.disabled(selectedFolderID == nil)
            }
            if let id = selectedFolderID {
                HStack {
                    Button(word("addSelected", "给已选条目添加")) {
                        let values = selectedMetadataEntries
                        editFolderMembership(values, validations: values.map(tagValidation), folder: id, adding: true)
                    }
                    Button(word("removeSelected", "从已选条目移除")) {
                        let values = selectedMetadataEntries
                        editFolderMembership(values, validations: values.map(tagValidation), folder: id, adding: false)
                    }
                }.disabled(selectedMetadataKeys.isEmpty)
            }
            Text(word("folderNote", "分类可重复收录条目；不移动原文件。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var savedOrganizer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(word("newQuery", "新智能筛选"), text: $newName)
                Button(word("saveQuery", "保存当前智能筛选")) {
                    perform {
                        let savedQuery = try SharedLibraryBrowserLogic.queryForSaving(query, scope: scope, store: store)
                        _ = try store.createSavedQuery(name: newName, query: savedQuery)
                        newName = ""
                    }
                }
            }
            List(selection: $selectedQueryID) {
                ForEach(saved) { item in Text(item.name).tag(item.id) }
            }
            HStack {
                TextField(word("rename", "重命名"), text: renameBinding(
                    selectedQueryID.map { .saved($0) },
                    canonical: selectedQueryID.flatMap { store.metadata.savedQueries[$0]?.name } ?? ""
                ))
                Button(word("rename", "重命名")) {
                    guard let id = selectedQueryID, let saved = store.metadata.savedQueries[id] else { return }
                    let item = SharedLibraryBrowserOrganizerItem.saved(id)
                    let name = renameDrafts.text(for: item, canonical: saved.name)
                    if perform({ try store.updateSavedQuery(id, name: name, query: saved.query) }) {
                        renameDrafts.clear(item)
                    }
                }.disabled(selectedQueryID == nil)
                Button(word("updateRules", "更新当前规则")) {
                    guard let id = selectedQueryID, let saved = store.metadata.savedQueries[id] else { return }
                    let item = SharedLibraryBrowserOrganizerItem.saved(id)
                    let name = renameDrafts.text(for: item, canonical: saved.name)
                    if perform({
                        let savedQuery = try SharedLibraryBrowserLogic.queryForSaving(query, scope: scope, store: store)
                        try store.updateSavedQuery(id, name: name, query: savedQuery)
                    }) {
                        renameDrafts.clear(item)
                        selectScope(.saved(id))
                    }
                }.disabled(selectedQueryID == nil)
                Button(word("delete", "删除"), role: .destructive) {
                    guard let id = selectedQueryID else { return }
                    if perform({ try SharedLibraryBrowserLogic.deleteSavedQuery(id, store: store, state: state) }) {
                        selectedQueryID = nil
                        renameDrafts.clear(.saved(id))
                    }
                }.disabled(selectedQueryID == nil)
            }
            Text(word("smartNote", "智能筛选按规则显示条目，不能手工添加成员。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func renameBinding(
        _ item: SharedLibraryBrowserOrganizerItem?, canonical: String
    ) -> Binding<String> {
        Binding(
            get: { renameDrafts.text(for: item, canonical: canonical) },
            set: { renameDrafts.set($0, for: item) }
        )
    }
    @discardableResult private func perform(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            state.reconcile(using: store)
            errorMessage = nil
            return true
        }
        catch {
            if let issue = error as? SharedLibraryBrowserIssue {
                switch issue {
                case .folderCannotBeSaved:
                    errorMessage = word("folderNotSaved", "当前分类的成员无法存为智能筛选；请先切换浏览范围。")
                case .conflictingKindScope:
                    errorMessage = word("conflictingScope", "当前类别与筛选条件冲突，无法保存。")
                }
            } else {
                errorMessage = sharedLibraryErrorText(error, language: language)
            }
            return false
        }
    }
    private func selectScope(_ value: SharedLibraryBrowserScope) {
        perform { try state.selectScope(value, using: store) }
    }
    private func acceptDrop(_ values: [String], action: (Set<String>) throws -> Void) -> Bool {
        guard let keys = SharedLibraryBrowserLogic.validatedDropKeys(values, entries: entries) else {
            errorMessage = word("invalidDrop", "拖放条目不属于当前资料库")
            return false
        }
        do {
            try action(Set(entries.filter { keys.contains($0.id) }.map { $0.item.key }))
            state.reconcile(using: store)
            errorMessage = nil
            return true
        }
        catch { errorMessage = sharedLibraryErrorText(error, language: language); return false }
    }
    private func dispatchFunction(_ action: SharedLibraryBrowserAction, entry: SharedLibraryBrowserEntry, function: String) {
        guard let current = SharedModelLibraryCard.resolve(entry, function: function, current: entries),
              SharedLibraryBrowserLogic.allows(action, entry: current) else {
            errorMessage = word("staleEntry", "条目已变化，请重新选择。"); return
        }
        if case .add = action {
            if let reason = insertionIssue(current) { errorMessage = reason; return }; onAdd(current)
        } else if case .use = action { onUse(current) }
    }
    private func dispatch(_ action: SharedLibraryBrowserAction, key: String) {
        guard let current = SharedLibraryBrowserLogic.currentEntry(
            key: key, entries: entries, action: action
        ) else {
            errorMessage = word("staleEntry", "条目已变化，请重新选择。")
            return
        }
        switch action {
        case .use: onUse(current)
        case .add:
            if let reason = insertionIssue(current) { errorMessage = reason; return }
            onAdd(current)
        case .preview: onPreview(current)
        case .location: onLocation(current)
        case .prepare: onPrepare(current)
        }
    }
    private func acceptCollectionDrop(_ values: [WorkflowCanvasTransfer], into target: SharedLibraryBrowserScope) -> Bool {
        guard onCollect != nil, values.count == 1, let payload = values[0].libraryPayload,
              let controller = insertionController, controller.assetLibraryOwner == payload.owner else { return false }
        if case .saved = target { errorMessage = workflowText(language, "container.savedDrop"); return true }
        if case .tag = target { errorMessage = workflowText(language, "container.tagDrop"); return true }
        let folder: UUID? = { if case .folder(let id) = target { return id }; return nil }()
        let requestID = UUID()
        collectionNoticeIntent = requestID; collectionFeedback = nil; collectionNotice = nil; collectionNoticeCode = nil; collectedLocation = nil
        Task {
            do {
                let sources = try await controller.resolveLibraryDrop(payload.items, owner: payload.owner)
                let id = try await controller.requestCollection(sources, owner: payload.owner, folderID: folder, requestID: requestID)
                if collectionNoticeIntent == requestID, insertionController === controller, controller.assetLibraryOwner == payload.owner {
                    collectionFeedback = .init(requestID: id, context: .init(controller: controller, source: .sources(sources), name: workflowText(language, "container.selected") + " \(sources.count)"))
                    refreshCollectionFeedback()
                }
                await controller.processCollectionRequests { request in
                    try store.applyCollectionOrganization(request, runs: controller.runs)
                }
                if collectionNoticeIntent == requestID { refreshCollectionFeedback() }
            } catch { if collectionNoticeIntent == requestID, insertionController === controller, controller.assetLibraryOwner == payload.owner { collectionNotice = error.localizedDescription; collectionNoticeCode = (error as? WorkflowIssue)?.code ?? "container.issue.collectionSavePending"; collectedLocation = nil } }
        }
        return true
    }
    private func refreshCollectionFeedback() {
        guard let feedback = collectionFeedback else { return }
        switch feedback.status(in: insertionController) {
        case .pending:
            collectionNoticeCode = "container.collectionPending"; collectionNotice = "Collection pending."; collectedLocation = nil
        case .completed:
            if !feedback.durablyCompleted {
                var confirmed = feedback; confirmed.acknowledgeCompletion(in: insertionController); collectionFeedback = confirmed
            }
            // Completion proves persistence, not whether this query hides every
            // source. Keep the precise reveal action without inventing filtering.
            collectionNoticeCode = "container.collected"; collectionNotice = "Collection saved."; collectedLocation = feedback.context
        case .failed(let reason):
            collectionNotice = reason.reason; collectionNoticeCode = reason.code; collectedLocation = nil
        case .obsolete:
            collectionNotice = nil; collectionNoticeCode = nil; collectedLocation = nil; collectionFeedback = nil; collectionNoticeIntent = nil
        }
    }
    private func dragEntries(for key: String) -> [SharedLibraryBrowserEntry] {
        guard let current = entries.first(where: { $0.id == key }) else { return [] }
        return selectedKeys.contains(key) ? visible.filter { selectedKeys.contains($0.id) } : [current]
    }
    private func dragPreview(for key: String) -> some View {
        let selected = dragEntries(for: key)
        let valid = !selectedKeys.contains(key) || selected.count == validSelection.count
        return Label(valid ? (selected.count == 1 ? selected[0].item.title : workflowText(language, "container.selected") + " \(selected.count)") : workflowText(language, "container.hiddenSelection"), systemImage: "doc.on.doc")
            .font(.callout).lineLimit(2).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    private func dragProvider(for key: String) -> NSItemProvider {
        dragProvider(for: key, using: insertionController)
    }
    // The actual view route is also checked with a captured controller in tests.
    func dragProvider(for key: String, using controller: WorkflowController?) -> NSItemProvider {
        guard let current = entries.first(where: { $0.id == key }) else { return NSItemProvider() }
        // Only the project collection owns multi-source/runtime transfers.
        // Quick/Chat keep their existing asset payload even while a canvas is open.
        if onCollect != nil, let controller, let owner = controller.assetLibraryOwner, current.item.kind == .asset {
            let selected = dragEntries(for: key)
            guard !selectedKeys.contains(key) || selected.count == validSelection.count else {
                errorMessage = workflowText(language, "container.hiddenSelection")
                return NSItemProvider()
            }
            guard !selected.isEmpty, selected.count <= 64, selected.allSatisfy({ $0.item.assetFacts?.projectID == owner.projectID && $0.item.assetFacts?.instanceID == owner.instanceID }) else { return NSItemProvider() }
            // Capture when dragging starts, not when hover enters a destination.
            let capture = Task { @MainActor () throws -> Data in
                var items: [WorkflowLibraryDropItem] = []
                for entry in selected {
                    if let source = entry.collectionSource { items.append(.source(source)) }
                    else if let readPreview { items.append(.original(try await readPreview(entry).token)) }
                    else { throw WorkflowIssue(workflowText(language, "container.stale")) }
                }
                guard controller.assetLibraryOwner == owner else { throw WorkflowIssue(workflowText(language, "container.stale")) }
                return try WorkflowCanvasTransfer.libraryItems(owner: owner, items: items).encoded()
            }
            let provider = NSItemProvider(); provider.suggestedName = selected.count == 1 ? current.item.title : workflowText(language, "container.selected") + " \(selected.count)"
            provider.registerDataRepresentation(forTypeIdentifier: UTType.workflowCanvasItem.identifier, visibility: .ownProcess) { completion in
                let progress = Progress(totalUnitCount: 1)
                progress.cancellationHandler = { capture.cancel() }
                Task { do { completion(try await capture.value, nil); progress.completedUnitCount = 1 } catch { completion(nil, error) } }
                return progress
            }
            return provider
        }
        return SharedLibraryBrowserLogic.dragProvider(for: current, controller: controller)
    }
    private func folderDepth(_ id: UUID) -> Int {
        var depth = 0
        var current = store.metadata.folders[id]?.parentID
        var seen: Set<UUID> = [id]
        while let parent = current, depth < 4, seen.insert(parent).inserted {
            depth += 1; current = store.metadata.folders[parent]?.parentID
        }
        return depth
    }
    private func canUse(_ entry: SharedLibraryBrowserEntry) -> Bool {
        SharedLibraryBrowserLogic.allows(.use, entry: entry)
    }
    private func canAdd(_ entry: SharedLibraryBrowserEntry) -> Bool {
        SharedLibraryBrowserLogic.allows(.add, entry: entry) && insertionIssue(entry) == nil
    }
    private func insertionIssue(_ entry: SharedLibraryBrowserEntry) -> String? {
        SharedLibraryBrowserLogic.insertionIssue(for: entry, controller: insertionController, language: language)
    }
    private func canPreview(_ entry: SharedLibraryBrowserEntry) -> Bool {
        SharedLibraryBrowserLogic.allows(.preview, entry: entry)
    }
    private func prepareLabel(for entry: SharedLibraryBrowserEntry) -> String {
        switch entry.item.readiness {
        case .unprepared: word("prepare", "准备")
        case .unknown: word("checkPreparation", "检查准备状态")
        case .unavailable, .unsupported, .available: word("prepareInfo", "查看准备信息")
        }
    }
    private func kindList(_ kinds: Set<WorkflowDataKind>) -> String {
        kinds.isEmpty ? word("none", "无") : kinds.map(dataName).sorted().joined(separator: " · ")
    }
    private func icon(_ kind: SharedLibraryItemKind) -> String {
        switch kind {
        case .model: "cpu"
        case .component: "puzzlepiece"
        case .program: "chevron.left.forwardslash.chevron.right"
        case .tool: "wrench.and.screwdriver"
        case .asset: "photo.on.rectangle"
        }
    }
    private func kindName(_ kind: SharedLibraryItemKind) -> String {
        switch kind {
        case .model: word("kind.model", "模型")
        case .component: word("kind.component", "组件")
        case .program: word("kind.program", "程序")
        case .tool: word("kind.tool", "工具")
        case .asset: word("kind.asset", "素材")
        }
    }
    private func readinessName(_ readiness: SharedLibraryReadiness) -> String {
        switch readiness {
        case .available: word("ready.available", "可用")
        case .unprepared: word("ready.unprepared", "未准备")
        case .unavailable: word("ready.unavailable", "不可用")
        case .unsupported: word("ready.unsupported", "不支持")
        case .unknown: word("ready.unknown", "未知")
        }
    }
    private func compatibilityName(_ value: Bool?) -> String {
        compatibilityName(SharedLibraryCompatibility(value))
    }
    private func compatibilityName(_ value: SharedLibraryCompatibility) -> String {
        switch value {
        case .compatible: word("compat.compatible", "兼容")
        case .incompatible: word("compat.incompatible", "不兼容")
        case .unknown: word("compat.unknown", "未知")
        }
    }
    private func dataName(_ kind: WorkflowDataKind) -> String {
        let fallback: String
        switch kind {
        case .text: fallback = "文字"
        case .document: fallback = "文档 / Document"
        case .image: fallback = "图像"
        case .images: fallback = "图像组"
        case .receipt: fallback = "记录"
        case .number: fallback = "数字"
        case .boolean: fallback = "布尔"
        case .enumeration: fallback = "选项"
        case .record: fallback = "结构记录"
        case .list: fallback = "列表"
        case .optional: fallback = "可选值"
        case .result: fallback = "结果"
        case .audio: fallback = "音频"
        case .video: fallback = "视频"
        case .notes: fallback = "音符"
        case .chords: fallback = "和弦"
        case .tempo: fallback = "速度"
        case .pitch: fallback = "音高"
        }
        return word("data." + kind.rawValue, fallback)
    }
}

private struct LibraryPanelSurface: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.workbenchPanel(cornerRadius: 12) } else { content }
    }
}
