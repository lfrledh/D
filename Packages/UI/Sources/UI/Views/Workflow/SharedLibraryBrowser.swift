import AppKit
import DWorkbench
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

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

public struct SharedLibraryBrowserEntry: Identifiable, Equatable {
    public let item: SharedLibraryItem
    public let selection: SharedLibraryBrowserSelection
    public let facts: [String]
    public let id: String
    public var legacyTags: [String]
    public var legacyFailure: String?
    public var metadataSnapshot: ProjectAssetMetadataSnapshot?

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

/// The caller owns one instance per browser surface so closing a view does not erase its place.
@MainActor @Observable
public final class SharedLibraryBrowserState {
    public var query: SharedLibraryQuery
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
        self.query = query
        self.scope = scope
        self.selectedKeys = selectedKeys
        self.focusedKey = focusedKey
    }

    /// Editing a named query creates a free filter draft, so its name never labels new rules.
    public func setDraftQuery(_ draft: SharedLibraryQuery) {
        if case .saved = scope, draft != query { scope = .all }
        query = draft
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
            query = saved.query
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
        if case .saved(let id) = scope, let saved = store.metadata.savedQueries[id] { query = saved.query }
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
        query: SharedLibraryQuery, scope: SharedLibraryBrowserScope, context: SharedLibraryQueryContext = .init()
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
        return entries.filter { entry in
            guard scopeKeys.contains(entry.id), store.matches(entry.item, query: query, context: context) else { return false }
            if case .kind(let kind) = scope { return entry.item.kind == kind }
            return true
        }
    }

    static func tagEditEntries(_ ids: Set<String>, in entries: [SharedLibraryBrowserEntry]) -> [SharedLibraryBrowserEntry] {
        entries.filter { ids.contains($0.id) }
    }

    static func validatedDropKeys(_ candidates: [String], entries: [SharedLibraryBrowserEntry]) -> Set<String>? {
        guard !candidates.isEmpty, candidates.count <= 128 else { return nil }
        let known = Set(entries.map(\.id))
        let keys = Set(candidates)
        guard keys.count == candidates.count, keys.allSatisfy({ known.contains($0) }) else { return nil }
        return keys
    }

    static func allows(_ action: SharedLibraryBrowserAction, entry: SharedLibraryBrowserEntry) -> Bool {
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

    static func dragProvider(for current: SharedLibraryBrowserEntry) -> NSItemProvider {
        let provider = NSItemProvider(object: current.id as NSString)
        if let transfer = canvasTransfer(for: current),
           let payload = try? transfer.encoded() {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.workflowCanvasItem.identifier, visibility: .all
            ) { completion in
                completion(payload, nil)
                return nil
            }
        }
        return provider
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
    private let onUse: (SharedLibraryBrowserEntry) -> Void
    private let onAdd: (SharedLibraryBrowserEntry) -> Void
    private let onPreview: (SharedLibraryBrowserEntry) -> Void
    private let onLocation: (SharedLibraryBrowserEntry) -> Void
    private let onPrepare: (SharedLibraryBrowserEntry) -> Void
    private let onImport: () -> Void
    private let allowsImport: Bool
    private let onClose: () -> Void
    private let queryContext: SharedLibraryQueryContext
    private let annotationSave: (SharedLibraryBrowserEntry) -> SharedLibraryAnnotationSave?
    private let tagValidation: (SharedLibraryBrowserEntry) -> (() throws -> Void)

    @Environment(\.dLanguageStore) private var language
    @State private var state: SharedLibraryBrowserState
    @State private var showFilters = false
    @State private var saveQueryRequest: SharedLibrarySaveQueryRequest?
    @State private var showOrganizer = false
    @State private var compactDetailKey: String?
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
    @State private var selectedQueryID: UUID?
    @State private var parentID: UUID?

    public init(
        entries: [SharedLibraryBrowserEntry], store: SharedLibraryStore, compact: Bool = false, allowsImport: Bool = true,
        state: SharedLibraryBrowserState? = nil,
        onUse: @escaping (SharedLibraryBrowserEntry) -> Void,
        onAdd: @escaping (SharedLibraryBrowserEntry) -> Void,
        onPreview: @escaping (SharedLibraryBrowserEntry) -> Void,
        onLocation: @escaping (SharedLibraryBrowserEntry) -> Void = { _ in },
        onPrepare: @escaping (SharedLibraryBrowserEntry) -> Void,
        onImport: @escaping () -> Void, onClose: @escaping () -> Void,
        tagValidation: @escaping (SharedLibraryBrowserEntry) -> (() throws -> Void) = { _ in {} },
        queryContext: SharedLibraryQueryContext = .init(), annotationSave: @escaping (SharedLibraryBrowserEntry) -> SharedLibraryAnnotationSave? = { _ in nil }
    ) {
        self._state = State(initialValue: state ?? SharedLibraryBrowserState())
        self.entries = entries; self.store = store; self.compact = compact; self.allowsImport = allowsImport
        self.onUse = onUse; self.onAdd = onAdd; self.onPreview = onPreview; self.onLocation = onLocation
        self.onPrepare = onPrepare; self.onImport = onImport; self.onClose = onClose
        self.tagValidation = tagValidation; self.queryContext = queryContext; self.annotationSave = annotationSave
    }

    private var query: SharedLibraryQuery {
        get { state.effectiveQuery(using: store) }
        nonmutating set { state.setDraftQuery(newValue) }
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
    private var selectedMetadataKeys: Set<String> { Set(entries.filter { validSelection.contains($0.id) }.map { $0.item.key }) }
    private var selectedEntry: SharedLibraryBrowserEntry? {
        entries.first { $0.id == focusedKey } ?? entries.first { validSelection.contains($0.id) }
    }
    private var visibleResult: Result<[SharedLibraryBrowserEntry], Error> {
        Result { try SharedLibraryBrowserLogic.visibleEntries(entries, store: store, query: query, scope: scope, context: queryContext) }
    }
    private var visible: [SharedLibraryBrowserEntry] { (try? visibleResult.get()) ?? [] }

    public var body: some View {
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
            if case .failure(let error) = visibleResult {
                Text(error.localizedDescription).foregroundStyle(.red).padding(8)
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
        .environment(\.workbenchMenuContext, "library:\(ObjectIdentifier(store)):\(ObjectIdentifier(state)):\(queryContext.projectID?.uuidString ?? "none"):\(queryContext.instanceID?.uuidString ?? "none")")
        .background { if !compact { Color.clear.workbenchPanel(cornerRadius: 12) } }
        .sheet(item: $saveQueryRequest) { request in SharedLibrarySaveQuerySheet(request: request, store: store) { saveQueryRequest = nil } }
        .sheet(isPresented: $showOrganizer) { organizer }
        .sheet(item: $tagRequest) { request in
            SharedLibraryTagEditor(store: store, targets: request.targets, add: request.add, remove: request.remove,
                validateTarget: {
                    for check in request.validations { try check() }
                })
        }
        .sheet(isPresented: Binding(
            get: { SharedLibraryBrowserLogic.detailEntry(key: compactDetailKey, entries: entries) != nil },
            set: { if !$0 { compactDetailKey = nil } }
        )) {
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
        .onAppear { state.reconcile(using: store) }
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
            Text(word("title", "共享资料库")).font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onImport) { Image(systemName: "square.and.arrow.down") }
                .help(word("import", "导入素材")).accessibilityLabel(word("import", "导入素材"))
            Button { showOrganizer = true } label: { Image(systemName: "square.stack.3d.up") }
                .help(word("organize", "整理资料库")).accessibilityLabel(word("organize", "整理资料库"))
            Button { perform { try store.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!store.canUndo).help(word("undo", "撤销")).accessibilityLabel(word("undo", "撤销"))
            Button { perform { try store.redo() } } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!store.canRedo).help(word("redo", "重做")).accessibilityLabel(word("redo", "重做"))
        }.buttonStyle(WorkbenchGlassButtonStyle()).padding(10)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            searchControls
            if !validSelection.isEmpty { bulkControls }
            WorkbenchScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visible) { entry in entryRow(entry, compact: true) }
                }.padding(.horizontal, 6)
            }
            searchFooter
        }.padding(7).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .dropDestination(for: String.self) { (keys: [String], _: CGPoint) -> Bool in
                            return acceptDrop(keys) { try store.addMembers($0, to: folder.id) }
                        }
                }
                Text(word("savedQueries", "智能筛选")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(saved) { item in
                    scopeButton(item.name, icon: "line.3.horizontal.decrease.circle", value: .saved(item.id))
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 7) {
            searchControls
            Text(word("legend", "能力 / 我的标签")).font(.caption2).foregroundStyle(.secondary)
            bulkControls
            if case .failure = visibleResult {
                Spacer()
            } else if visible.isEmpty {
                ContentUnavailableView(word("empty", "没有符合条件的条目"), systemImage: "square.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $state.selectedKeys) {
                    ForEach(visible) { entry in entryRow(entry, compact: false).tag(entry.id) }
                }.listStyle(.plain).accessibilityIdentifier("shared-library-results")
            }
            searchFooter
        }.padding(8)
    }

    private func tagTarget(_ entry: SharedLibraryBrowserEntry) -> SharedLibraryTagTarget {
        let identity: String
        if case .assetInstance(_, let instance, _) = entry.selection { identity = String(instance.uuidString.prefix(8)) }
        else { identity = entry.id }
        return .init(key: entry.item.key, title: entry.item.title + " · " + identity, legacy: entry.legacyTags, legacyFailure: entry.legacyFailure, activityID: entry.id)
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
    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(word("search", "搜索名称、说明或我的标签"), text: searchTextBinding)
                .textFieldStyle(WorkbenchGlassTextFieldStyle()).accessibilityIdentifier("shared-library-search")

            HStack {
                WorkbenchMenu(scopeTitle) {
                    WorkbenchMenuAction(word("all", "全部")) { selectScope(.all) }
                    WorkbenchMenuForEach(SharedLibraryItemKind.allCases, id: \.self) { kind in WorkbenchMenuAction(kindName(kind)) { selectScope(.kind(kind)) } }
                    WorkbenchMenuForEach(folders) { folder in WorkbenchMenuAction(folder.name) { selectScope(.folder(folder.id)) } }
                    WorkbenchMenuForEach(saved) { saved in WorkbenchMenuAction(saved.name) { selectScope(.saved(saved.id)) } }
                }.font(.caption)
                if compact {
                    Spacer(minLength: 0)
                    WorkbenchMenu {
                        WorkbenchSubmenu(consistencyText(language, "menu.library.saved")) { WorkbenchMenuForEach(saved) { item in WorkbenchMenuAction(item.name) { selectScope(.saved(item.id)) } } }
                        WorkbenchMenuAction(consistencyText(language, "menu.library.manage")) { showOrganizer = true }
                        WorkbenchMenuDivider()
                        WorkbenchMenuAction(word("undo", "撤销")) { perform { try store.undo() } }.disabled(!store.canUndo)
                        WorkbenchMenuAction(word("redo", "重做")) { perform { try store.redo() } }.disabled(!store.canRedo)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel(word("more", "更多"))
                        .accessibilityIdentifier("shared-library-more")
                }
            }
            HStack {
                if allowsImport {
                    Button(consistencyText(language, "LIB-ADD"), action: onImport)
                }
                WorkbenchMenu(consistencyText(language, "LIB-TAGS")) {
                    WorkbenchMenuForEach(tags) { tag in
                        WorkbenchMenuToggle(tag.name + " (\(countAddingTag(tag.id)))", isOn: setBinding(\.allTagIDs, tag.id))
                    }
                    if tags.isEmpty { WorkbenchMenuText(word("noTags", "尚无我的标签")) }
                }
                Button(word("filters", "筛选"), systemImage: "line.3.horizontal.decrease.circle") { showFilters.toggle() }
                    .popover(isPresented: $showFilters, arrowEdge: .bottom) { filterPopover }
            }.font(.caption)
            SharedLibraryPropertySummary(query: Binding(get: { query }, set: { query = $0 }), items: entries.map(\.item), context: queryContext, store: store, fixedScopeDescription: scopeTitle)
            if hasSearchTokens { ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    if scope != .all { token(scopeTitle) { selectScope(.all) } }
                    if !query.text.isEmpty { token(query.text) { query.text = "" } }
                    ForEach(WorkflowResultQueryState.tagConditions(query.allTagIDs, store: store, missingLabel: metadataText(language, "deletedTagCondition", "已删除的标签", "Deleted tag")), id: \.id) { tag in token(word("allTags", "同时包含标签") + ": " + state.tagPresentation.title(tag.id, tags: store.metadata.tags, missing: metadataText(language, "deletedTagCondition", "已删除的标签", "Deleted tag"))) { query.allTagIDs.remove(tag.id) } }
                    ForEach(WorkflowResultQueryState.tagConditions(query.anyTagIDs, store: store, missingLabel: metadataText(language, "deletedTagCondition", "已删除的标签", "Deleted tag")), id: \.id) { tag in token(word("anyTags", "至少一个标签") + ": " + state.tagPresentation.title(tag.id, tags: store.metadata.tags, missing: metadataText(language, "deletedTagCondition", "已删除的标签", "Deleted tag"))) { query.anyTagIDs.remove(tag.id) } }
                    dimensionTokens(query.kinds, path: \.kinds, label: kindName)
                    dimensionTokens(query.roles, path: \.roles, label: { $0 })
                    dimensionTokens(query.inputs, path: \.inputs, label: { word("inputs", "输入能力") + ": " + dataName($0) })
                    dimensionTokens(query.outputs, path: \.outputs, label: { word("outputs", "输出能力") + ": " + dataName($0) })
                    dimensionTokens(query.contentKinds, path: \.contentKinds, label: dataName)
                    dimensionTokens(query.readiness, path: \.readiness, label: readinessName)
                    dimensionTokens(query.compatibility, path: \.compatibility, label: compatibilityName)
                }
            }.scrollIndicators(.hidden) }
            if !query.allTagIDs.union(query.anyTagIDs).filter({ store.metadata.tags[$0] == nil }).isEmpty {
                WorkflowTechnicalDetails(value: query.allTagIDs.union(query.anyTagIDs).filter { store.metadata.tags[$0] == nil }.sorted { $0.uuidString < $1.uuidString }.map { state.tagPresentation.title($0, tags: store.metadata.tags, missing: metadataText(language, "deletedTagCondition", "已删除的标签", "Deleted tag")) + ": " + $0.uuidString }.joined(separator: "\n"))
            }
        }.workbenchPanel(cornerRadius: 0).workbenchSurface(.scrollEdge)
    }
    private var searchFooter: some View {
            HStack {
                if case .failure = visibleResult {
                    Text(metadataText(language, "countUnavailable", "当前范围数量不可用", "Count unavailable for this scope")).font(.caption2)
                } else {
                    Text("\(visible.count)/\(entries.count) " + word("locations", "结果位置")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(word("saveQuery", "保存检索")) { openSaveQuery() }.font(.caption)
            }
    }
    private var hasSearchTokens: Bool {
        scope != .all || !query.text.isEmpty || !query.allTagIDs.isEmpty || !query.anyTagIDs.isEmpty
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

    private var bulkControls: some View {
        let capturedSelection = validSelection
        let capturedKeys = selectedMetadataKeys
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
                .disabled(validSelection.isEmpty)
            WorkbenchMenu {
                WorkbenchMenuForEach(folders) { folder in
                    WorkbenchMenuAction(word("addToFolder", "加入分类") + " · " + folder.name) {
                        perform { try store.addMembers(capturedKeys, to: folder.id) }
                    }
                    WorkbenchMenuAction(word("removeFromFolder", "移出分类") + " · " + folder.name) {
                        perform { try store.removeMembers(capturedKeys, from: folder.id) }
                    }
                }
                if folders.isEmpty { WorkbenchMenuText(word("noFolders", "尚无分类")) }
            } label: { Label(word("bulkFolders", "批量分类"), systemImage: "folder") }
                .disabled(validSelection.isEmpty)
        }.font(.caption).environment(\.workbenchMenuContext, "bulk:\(ObjectIdentifier(store)):\(ObjectIdentifier(state)):\(capturedSelection.sorted()):\(capturedKeys.sorted())")
    }

    @ViewBuilder private func entryRow(_ entry: SharedLibraryBrowserEntry, compact: Bool) -> some View {
        let row = HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon(entry.item.kind)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(entry.item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if entry.item.kind == .model {
                    if let descriptor = ModelNodeCatalog.entries.first(where: { $0.id == entry.item.key }) {
                        Text(descriptor.precision).font(.system(size: 13)).lineLimit(2)
                    }
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
            }.frame(maxWidth: .infinity, alignment: .leading)
            if compact {
                Button {
                    if selectedKeys.contains(entry.id) { selectedKeys.remove(entry.id) }
                    else { selectedKeys.insert(entry.id) }
                    focusedKey = entry.id
                } label: {
                    Image(systemName: selectedKeys.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(WorkbenchGlassButtonStyle(compact: true))
                .accessibilityLabel(selectedKeys.contains(entry.id)
                    ? word("deselect", "取消选择") : word("select", "选择"))
                Button {
                    if canAdd(entry) { dispatch(.add, key: entry.id) }
                    else { compactDetailKey = entry.id }
                } label: { Image(systemName: canAdd(entry) ? "plus.circle" : "info.circle") }
                    .buttonStyle(WorkbenchGlassButtonStyle()).controlSize(.small)
                    .accessibilityLabel(canAdd(entry) ? word("addCanvas", "添加画布") : word("detail", "详情"))
            }
        }
        .padding(6).contentShape(Rectangle())
        .onTapGesture {
            focusedKey = entry.id
            if compact { selectedKeys = [entry.id]; compactDetailKey = entry.id }
        }
        .accessibilityIdentifier("shared-library-entry-" + entry.id)
        VStack(alignment: .leading, spacing: 4) {
            row.onDrag { dragProvider(for: entry.id) }
            if let ids = store.metadata.tagAssignments[entry.item.key], !ids.isEmpty {
                HStack {
                    ForEach(tags.filter { ids.contains($0.id) }) { tag in
                        Button(tag.name) { query.allTagIDs.insert(tag.id) }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
                            .help(metadataText(language, "tagFiltersOnly", "仅按此标签筛选", "Filter by this tag only"))
                    }
                }.font(.caption).padding(.horizontal, 6)
            }
        }
    }

    private var detailPane: some View {
        WorkbenchScrollView {
            if let entry = selectedEntry { details(entry).padding(12) }
            else { Text(word("choose", "选择条目以查看详情")).foregroundStyle(.secondary).padding(12) }
        }
    }

    private func details(_ entry: SharedLibraryBrowserEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !visible.contains(where: { $0.id == entry.id }) {
                Text(metadataText(language, "filteredSelection", "此对象已不匹配当前条件；详情仍绑定原对象。", "This item no longer matches; details remain bound to the same item.")).font(.caption).foregroundStyle(.orange)
            }
            Text(entry.item.title).font(.headline).textSelection(.enabled)
            Text(entry.item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text(word("legend", "能力 / 我的标签")).font(.caption2).foregroundStyle(.secondary)
            Divider()
            if canUse(entry) {
                Button(word("quickUse", "快速用")) { dispatch(.use, key: entry.id) }
                    .accessibilityIdentifier("shared-library-use")
                if entry.item.readiness != .available {
                    Text(word("draftOnly", "快速用仅选择草稿，不会执行；就绪状态仍如上所示。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if canAdd(entry) {
                Button(word("addCanvas", "添加画布")) { dispatch(.add, key: entry.id) }
                    .accessibilityIdentifier("shared-library-add")
            }
            if canPreview(entry) {
                Button(word("preview", "预览")) { dispatch(.preview, key: entry.id) }
                    .accessibilityIdentifier("shared-library-preview")
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
                        } else { errorMessage = metadataText(language, "sourceMissing", "此精确来源不在当前已登记范围，或存在多个实例。", "This exact source is outside the registered scope, or has multiple instances.") }
                    })
            } else {
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
        do {
            let captured = try SharedLibraryBrowserLogic.queryForSaving(query, scope: scope, store: store)
            saveQueryRequest = .init(query: captured, scopeTitle: scopeTitle, tagTitles: Dictionary(uniqueKeysWithValues: captured.allTagIDs.union(captured.anyTagIDs).map { ($0, state.tagPresentation.title($0, tags: store.metadata.tags, missing: metadataText(language, "deletedTagCondition", "已删除的标签", "Deleted tag"))) }))
        } catch { errorMessage = error.localizedDescription }
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

    private var searchTextBinding: Binding<String> {
        Binding(get: { query.text }, set: { query.text = String($0.prefix(256)) })
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
                Button(word("back", "返回")) { showOrganizer = false }
                Text(word("organize", "整理资料库")).font(.headline)
                Spacer()
            }
            Picker(word("organize", "整理资料库"), selection: $tab) {
                Text(word("myTags", "我的标签")).tag(OrganizerTab.tags)
                Text(word("folders", "分类")).tag(OrganizerTab.folders)
                Text(word("savedQueries", "智能筛选")).tag(OrganizerTab.saved)
            }.pickerStyle(.segmented)
            Text(word("legend", "能力 / 我的标签")).font(.caption).foregroundStyle(.secondary)
            switch tab {
            case .tags: tagOrganizer
            case .folders: folderOrganizer
            case .saved: savedOrganizer
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
        }.padding(16).frame(width: 520, height: 470)
    }

    private var tagOrganizer: some View {
        VStack(alignment: .leading, spacing: 9) {
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
                }.disabled(validSelection.isEmpty)
            }
        }
    }

    private var folderOrganizer: some View {
        VStack(alignment: .leading, spacing: 9) {
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
                        perform { try store.addMembers(selectedMetadataKeys, to: id) }
                    }
                    Button(word("removeSelected", "从已选条目移除")) {
                        perform { try store.removeMembers(selectedMetadataKeys, from: id) }
                    }
                }.disabled(validSelection.isEmpty)
            }
            Text(word("folderNote", "分类可重复收录条目；不移动原文件。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var savedOrganizer: some View {
        VStack(alignment: .leading, spacing: 9) {
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
                errorMessage = error.localizedDescription
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
        catch { errorMessage = error.localizedDescription; return false }
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
        case .add: onAdd(current)
        case .preview: onPreview(current)
        case .location: onLocation(current)
        case .prepare: onPrepare(current)
        }
    }
    private func dragProvider(for key: String) -> NSItemProvider {
        guard let current = entries.first(where: { $0.id == key }) else { return NSItemProvider() }
        return SharedLibraryBrowserLogic.dragProvider(for: current)
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
        SharedLibraryBrowserLogic.allows(.add, entry: entry)
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
