import AppKit
import DWorkbench
import Foundation
import Observation
import SwiftUI

public enum SharedLibraryBrowserSelection: Equatable {
    case operation(id: String, modelID: String?)
    case asset(projectID: UUID, assetID: UUID)
    case tool(WorkflowToolReference)
    case unavailable(String)
}

public struct SharedLibraryBrowserEntry: Identifiable, Equatable {
    public let item: SharedLibraryItem
    public let selection: SharedLibraryBrowserSelection
    public let facts: [String]
    public var id: String { item.key }

    public init(item: SharedLibraryItem, selection: SharedLibraryBrowserSelection, facts: [String] = []) {
        self.item = item
        self.selection = selection
        self.facts = facts
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
}

@MainActor enum SharedLibraryBrowserLogic {
    static func visibleEntries(
        _ entries: [SharedLibraryBrowserEntry], store: SharedLibraryStore,
        query: SharedLibraryQuery, scope: SharedLibraryBrowserScope
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
            scopeKeys = Set(entries.filter { store.metadata.tagAssignments[$0.id]?.contains(id) == true }.map(\.id))
        case .folder(let id):
            guard let folder = store.metadata.folders[id] else { throw SharedLibraryError.missingFolder }
            scopeKeys = folder.memberKeys
        }
        let filtered = Set(store.filter(entries.map(\.item), query: query).map(\.key))
        return entries.filter { entry in
            guard scopeKeys.contains(entry.id), filtered.contains(entry.id) else { return false }
            if case .kind(let kind) = scope { return entry.item.kind == kind }
            return true
        }
    }

    static func validatedDropKeys(_ candidates: [String], entries: [SharedLibraryBrowserEntry]) -> Set<String>? {
        guard !candidates.isEmpty, candidates.count <= 128 else { return nil }
        let known = Set(entries.map(\.id))
        let keys = Set(candidates)
        guard keys.count == candidates.count, keys.allSatisfy({ known.contains($0) }) else { return nil }
        return keys
    }

    static func canvasTransfer(for entry: SharedLibraryBrowserEntry) -> WorkflowCanvasTransfer? {
        guard entry.item.readiness == .available, entry.item.compatible != false else { return nil }
        switch entry.selection {
        case .operation(let id, let modelID): return .operation(id: id, modelID: modelID)
        case .asset(let projectID, let assetID): return .asset(projectID: projectID, assetID: assetID)
        case .tool, .unavailable: return nil
        }
    }

    static func quickUseAllowed(_ entry: SharedLibraryBrowserEntry) -> Bool {
        guard entry.item.compatible != false else { return false }
        guard case .operation(_, let modelID) = entry.selection else { return false }
        if entry.item.readiness == .available { return true }
        return entry.item.readiness == .unknown && modelID?.isEmpty == false
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
    private let onPrepare: (SharedLibraryBrowserEntry) -> Void
    private let onImport: () -> Void
    private let onClose: () -> Void

    @Environment(\.dLanguageStore) private var language
    @State private var state: SharedLibraryBrowserState
    @State private var showFilters = false
    @State private var showOrganizer = false
    @State private var compactDetail: SharedLibraryBrowserEntry?
    @State private var errorMessage: String?
    @State private var tab: OrganizerTab = .tags
    @State private var newName = ""
    @State private var renameName = ""
    @State private var selectedTagID: UUID?
    @State private var selectedFolderID: UUID?
    @State private var selectedQueryID: UUID?
    @State private var parentID: UUID?

    public init(
        entries: [SharedLibraryBrowserEntry], store: SharedLibraryStore, compact: Bool = false,
        state: SharedLibraryBrowserState? = nil,
        onUse: @escaping (SharedLibraryBrowserEntry) -> Void,
        onAdd: @escaping (SharedLibraryBrowserEntry) -> Void,
        onPreview: @escaping (SharedLibraryBrowserEntry) -> Void,
        onPrepare: @escaping (SharedLibraryBrowserEntry) -> Void,
        onImport: @escaping () -> Void, onClose: @escaping () -> Void
    ) {
        self._state = State(initialValue: state ?? SharedLibraryBrowserState())
        self.entries = entries; self.store = store; self.compact = compact
        self.onUse = onUse; self.onAdd = onAdd; self.onPreview = onPreview
        self.onPrepare = onPrepare; self.onImport = onImport; self.onClose = onClose
    }

    private var query: SharedLibraryQuery {
        get { state.query }
        nonmutating set { state.query = newValue }
    }
    private var scope: SharedLibraryBrowserScope {
        get { state.scope }
        nonmutating set { state.scope = newValue }
    }
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
    private var selectedEntry: SharedLibraryBrowserEntry? {
        entries.first { $0.id == focusedKey } ?? entries.first { validSelection.contains($0.id) }
    }
    private var visibleResult: Result<[SharedLibraryBrowserEntry], Error> {
        Result { try SharedLibraryBrowserLogic.visibleEntries(entries, store: store, query: query, scope: scope) }
    }
    private var visible: [SharedLibraryBrowserEntry] { (try? visibleResult.get()) ?? [] }

    public var body: some View {
        VStack(spacing: 0) {
            header
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
        .background(.regularMaterial)
        .sheet(isPresented: $showOrganizer) { organizer }
        .sheet(item: $compactDetail) { entry in
            VStack(alignment: .leading) {
                HStack {
                    Text(word("detail", "详情")).font(.headline)
                    Spacer()
                    Button(word("close", "关闭")) { compactDetail = nil }
                }
                ScrollView { details(entry) }
            }.padding(16).frame(minWidth: 300, minHeight: 320)
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
            if compact {
                Menu {
                    Button(word("import", "导入素材"), action: onImport)
                    Button(word("organize", "整理资料库")) { showOrganizer = true }
                    Button(word("undo", "撤销")) { perform { try store.undo() } }
                        .disabled(!store.canUndo)
                    Button(word("redo", "重做")) { perform { try store.redo() } }
                        .disabled(!store.canRedo)
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel(word("more", "更多"))
            } else {
                Button(action: onImport) { Image(systemName: "square.and.arrow.down") }
                    .help(word("import", "导入素材")).accessibilityLabel(word("import", "导入素材"))
                Button { showOrganizer = true } label: { Image(systemName: "square.stack.3d.up") }
                    .help(word("organize", "整理资料库")).accessibilityLabel(word("organize", "整理资料库"))
                Button { perform { try store.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!store.canUndo).help(word("undo", "撤销")).accessibilityLabel(word("undo", "撤销"))
                Button { perform { try store.redo() } } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!store.canRedo).help(word("redo", "重做")).accessibilityLabel(word("redo", "重做"))
            }
        }.buttonStyle(.borderless).padding(10)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            searchControls
            Text(word("legend", "能力 / 我的标签")).font(.caption2).foregroundStyle(.secondary)
            bulkControls
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visible) { entry in entryRow(entry, compact: true) }
                }.padding(.horizontal, 6)
            }
        }.padding(7).frame(width: 240).frame(maxHeight: .infinity)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                scopeButton(word("all", "全部"), icon: "square.grid.2x2", value: .all)
                Text(word("kind", "类别")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(SharedLibraryItemKind.allCases, id: \.self) { kind in
                    scopeButton(kindName(kind), icon: icon(kind), value: .kind(kind))
                }
                Text(word("myTags", "我的标签")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(tags) { tag in
                    scopeButton(tag.name, icon: "tag", value: .tag(tag.id))
                        .dropDestination(for: String.self) { keys, _ in
                            acceptDrop(keys) { try store.addTags([tag.id], to: $0) }
                        }
                }
                Text(word("folders", "分类")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(folderTree) { folder in
                    scopeButton(folder.name, icon: "folder", value: .folder(folder.id))
                        .padding(.leading, CGFloat(folderDepth(folder.id)) * 10)
                        .dropDestination(for: String.self) { keys, _ in
                            acceptDrop(keys) { try store.addMembers($0, to: folder.id) }
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
        }.padding(8)
    }

    private var searchControls: some View {
        HStack(spacing: 6) {
            TextField(word("search", "搜索名称、说明或我的标签"), text: searchTextBinding)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("shared-library-search")
            Button { showFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel(word("filters", "筛选"))
                .popover(isPresented: $showFilters, arrowEdge: .bottom) { filterPopover }
        }
    }

    private var bulkControls: some View {
        HStack(spacing: 6) {
            Text(word("selected", "已选") + " \(validSelection.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(tags) { tag in
                    Button(word("addTag", "添加标签") + " · " + tag.name) {
                        perform { try store.addTags([tag.id], to: validSelection) }
                    }
                    Button(word("removeTag", "移除标签") + " · " + tag.name) {
                        perform { try store.removeTags([tag.id], from: validSelection) }
                    }
                }
                if tags.isEmpty { Text(word("noTags", "尚无我的标签")) }
            } label: { Label(word("bulkTags", "批量标签"), systemImage: "tag") }
                .disabled(validSelection.isEmpty)
            Menu {
                ForEach(folders) { folder in
                    Button(word("addToFolder", "加入分类") + " · " + folder.name) {
                        perform { try store.addMembers(validSelection, to: folder.id) }
                    }
                    Button(word("removeFromFolder", "移出分类") + " · " + folder.name) {
                        perform { try store.removeMembers(validSelection, from: folder.id) }
                    }
                }
                if folders.isEmpty { Text(word("noFolders", "尚无分类")) }
            } label: { Label(word("bulkFolders", "批量分类"), systemImage: "folder") }
                .disabled(validSelection.isEmpty)
        }.font(.caption)
    }

    @ViewBuilder private func entryRow(_ entry: SharedLibraryBrowserEntry, compact: Bool) -> some View {
        let row = HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon(entry.item.kind)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(entry.item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                .buttonStyle(.borderless)
                .accessibilityLabel(selectedKeys.contains(entry.id)
                    ? word("deselect", "取消选择") : word("select", "选择"))
                Button {
                    if canAdd(entry) { onAdd(entry) } else { compactDetail = entry }
                } label: { Image(systemName: canAdd(entry) ? "plus.circle" : "info.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(canAdd(entry) ? word("addCanvas", "添加画布") : word("detail", "详情"))
            }
        }
        .padding(6).contentShape(Rectangle())
        .onTapGesture {
            focusedKey = entry.id
            if compact { selectedKeys = [entry.id]; compactDetail = entry }
        }
        .accessibilityIdentifier("shared-library-entry-" + entry.id)
        row.onDrag { dragProvider(for: entry) }
    }

    private var detailPane: some View {
        ScrollView {
            if let entry = selectedEntry { details(entry).padding(12) }
            else { Text(word("choose", "选择条目以查看详情")).foregroundStyle(.secondary).padding(12) }
        }
    }

    private func details(_ entry: SharedLibraryBrowserEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.item.title).font(.headline).textSelection(.enabled)
            Text(entry.item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            detailLine(word("kind", "类别"), kindName(entry.item.kind))
            detailLine(word("readiness", "就绪状态"), readinessName(entry.item.readiness))
            detailLine(word("compatibility", "兼容性"), compatibilityName(entry.item.compatible))
            if !entry.item.role.isEmpty { detailLine(word("role", "用途"), entry.item.role) }
            detailLine(word("inputs", "输入能力"), kindList(entry.item.inputs))
            detailLine(word("outputs", "输出能力"), kindList(entry.item.outputs))
            if let kind = entry.item.contentKind { detailLine(word("content", "内容类型"), dataName(kind)) }
            if !entry.facts.isEmpty {
                Text(word("facts", "能力事实")).font(.subheadline.weight(.semibold))
                ForEach(entry.facts, id: \.self) { fact in Text(fact).font(.caption).textSelection(.enabled) }
            }
            Text(word("myTags", "我的标签")).font(.subheadline.weight(.semibold))
            Text(assignedTagNames(entry.id)).font(.caption).textSelection(.enabled)
            Text(word("legend", "能力 / 我的标签")).font(.caption2).foregroundStyle(.secondary)
            Divider()
            if canUse(entry) {
                Button(word("quickUse", "快速用")) { onUse(entry) }
                    .accessibilityIdentifier("shared-library-use")
                if entry.item.readiness == .unknown {
                    Text(word("unknownDraft", "就绪状态未知；快速用仅选择草稿，不会执行。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if canAdd(entry) {
                Button(word("addCanvas", "添加画布")) { onAdd(entry) }
                    .accessibilityIdentifier("shared-library-add")
            }
            if canPreview(entry) {
                Button(word("preview", "预览")) { onPreview(entry) }
                    .accessibilityIdentifier("shared-library-preview")
            }
            if entry.item.readiness != .available || (!canUse(entry) && !canAdd(entry) && !canPreview(entry)) {
                Button(word("prepare", "准备")) { onPrepare(entry) }
                    .accessibilityIdentifier("shared-library-prepare")
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

    private var filterPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text(word("filters", "筛选")).font(.headline)
                filterGroup(word("kind", "类别"), values: SharedLibraryItemKind.allCases,
                            keyPath: \.kinds, label: kindName)
                Menu(word("role", "用途") + " (\(query.roles.count))") {
                    ForEach(Array(Set(entries.map(\.item.role).filter { !$0.isEmpty })).sorted(), id: \.self) { role in
                        Toggle(role, isOn: setBinding(\.roles, role))
                    }
                }
                filterGroup(word("inputs", "输入能力"), values: WorkflowDataKind.allCases,
                            keyPath: \.inputs, label: dataName)
                filterGroup(word("outputs", "输出能力"), values: WorkflowDataKind.allCases,
                            keyPath: \.outputs, label: dataName)
                filterGroup(word("content", "内容类型"), values: WorkflowDataKind.allCases,
                            keyPath: \.contentKinds, label: dataName)
                filterGroup(word("readiness", "就绪状态"), values: SharedLibraryReadiness.allCases,
                            keyPath: \.readiness, label: readinessName)
                filterGroup(word("compatibility", "兼容性"), values: SharedLibraryCompatibility.allCases,
                            keyPath: \.compatibility, label: compatibilityName)
                Menu(word("myTags", "我的标签") + " (\(query.anyTagIDs.count))") {
                    ForEach(tags) { tag in Toggle(tag.name, isOn: setBinding(\.anyTagIDs, tag.id)) }
                }
                Menu(word("allTags", "同时包含这些标签") + " (\(query.allTagIDs.count))") {
                    ForEach(tags) { tag in Toggle(tag.name, isOn: setBinding(\.allTagIDs, tag.id)) }
                }
                Menu(word("browseScope", "浏览范围")) {
                    Button(word("all", "全部")) { selectScope(.all) }
                    ForEach(SharedLibraryItemKind.allCases, id: \.self) { kind in
                        Button(kindName(kind)) { selectScope(.kind(kind)) }
                    }
                    ForEach(folders) { folder in
                        Button(folder.name) { selectScope(.folder(folder.id)) }
                    }
                    ForEach(saved) { item in
                        Button(item.name) { selectScope(.saved(item.id)) }
                    }
                }
                Text(word("filterRule", "同组任一，跨组同时满足")).font(.caption).foregroundStyle(.secondary)
                Text(filterSummary).font(.caption).foregroundStyle(.secondary)
                Button(word("clearFilters", "清除筛选")) { query = SharedLibraryQuery() }
                Button(word("saveQuery", "保存当前智能筛选")) {
                    tab = .saved; showOrganizer = true; showFilters = false
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(width: 290, height: 460)
    }

    private func filterGroup<Value: Hashable>(
        _ title: String, values: [Value],
        keyPath: WritableKeyPath<SharedLibraryQuery, Set<Value>>,
        label: @escaping (Value) -> String
    ) -> some View {
        Menu(title + " (\(query[keyPath: keyPath].count))") {
            ForEach(values, id: \.self) { value in
                Toggle(label(value), isOn: setBinding(keyPath, value))
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
        let parts = [
            query.kinds.map(kindName).sorted().joined(separator: ", "),
            query.roles.sorted().joined(separator: ", "),
            query.inputs.map(dataName).sorted().joined(separator: ", "),
            query.outputs.map(dataName).sorted().joined(separator: ", "),
            query.contentKinds.map(dataName).sorted().joined(separator: ", "),
            query.readiness.map(readinessName).sorted().joined(separator: ", "),
            query.compatibility.map(compatibilityName).sorted().joined(separator: ", "),
            tags.filter { query.anyTagIDs.contains($0.id) }.map(\.name).joined(separator: ", "),
            tags.filter { query.allTagIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? word("noFilters", "未选择筛选") : parts.joined(separator: " · ")
    }

    private enum OrganizerTab: String, CaseIterable { case tags, folders, saved }

    private var organizer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(word("organize", "整理资料库")).font(.headline)
                Spacer()
                Button(word("close", "关闭")) { showOrganizer = false }
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
            .onChange(of: selectedTagID) { _, id in renameName = id.flatMap { store.metadata.tags[$0]?.name } ?? "" }
            HStack {
                TextField(word("rename", "重命名"), text: $renameName)
                Button(word("rename", "重命名")) {
                    guard let id = selectedTagID else { return }
                    perform { try store.renameTags([id: renameName]) }
                }.disabled(selectedTagID == nil)
                Button(word("delete", "删除"), role: .destructive) {
                    guard let id = selectedTagID else { return }
                    perform { try store.deleteTags([id]); selectedTagID = nil }
                }.disabled(selectedTagID == nil)
            }
            if let id = selectedTagID {
                HStack {
                    Button(word("addSelected", "给已选条目添加")) {
                        perform { try store.addTags([id], to: validSelection) }
                    }
                    Button(word("removeSelected", "从已选条目移除")) {
                        perform { try store.removeTags([id], from: validSelection) }
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
                renameName = id.flatMap { store.metadata.folders[$0]?.name } ?? ""
                parentID = id.flatMap { store.metadata.folders[$0]?.parentID }
            }
            HStack {
                TextField(word("rename", "重命名"), text: $renameName)
                Button(word("rename", "重命名")) {
                    guard let id = selectedFolderID else { return }
                    perform { try store.renameFolder(id, to: renameName) }
                }.disabled(selectedFolderID == nil)
                Button(word("delete", "删除"), role: .destructive) {
                    guard let id = selectedFolderID else { return }
                    perform { try store.deleteFolder(id); selectedFolderID = nil }
                }.disabled(selectedFolderID == nil)
            }
            HStack {
                Picker(word("parent", "上级分类"), selection: $parentID) {
                    Text(word("root", "顶层")).tag(UUID?.none)
                    ForEach(folders) { folder in Text(folder.name).tag(Optional(folder.id)) }
                }
                Button(word("move", "移动分类")) {
                    guard let id = selectedFolderID else { return }
                    perform { try store.moveFolder(id, under: parentID) }
                }.disabled(selectedFolderID == nil)
            }
            if let id = selectedFolderID {
                HStack {
                    Button(word("addSelected", "给已选条目添加")) {
                        perform { try store.addMembers(validSelection, to: id) }
                    }
                    Button(word("removeSelected", "从已选条目移除")) {
                        perform { try store.removeMembers(validSelection, from: id) }
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
                    perform { _ = try store.createSavedQuery(name: newName, query: query); newName = "" }
                }
            }
            List(selection: $selectedQueryID) {
                ForEach(saved) { item in Text(item.name).tag(item.id) }
            }
            .onChange(of: selectedQueryID) { _, id in
                renameName = id.flatMap { store.metadata.savedQueries[$0]?.name } ?? ""
            }
            HStack {
                TextField(word("rename", "重命名"), text: $renameName)
                Button(word("rename", "重命名")) {
                    guard let id = selectedQueryID, let item = store.metadata.savedQueries[id] else { return }
                    perform { try store.updateSavedQuery(id, name: renameName, query: item.query) }
                }.disabled(selectedQueryID == nil)
                Button(word("updateRules", "更新当前规则")) {
                    guard let id = selectedQueryID else { return }
                    perform { try store.updateSavedQuery(id, name: renameName, query: query) }
                }.disabled(selectedQueryID == nil)
                Button(word("delete", "删除"), role: .destructive) {
                    guard let id = selectedQueryID else { return }
                    perform { try store.deleteSavedQuery(id); selectedQueryID = nil }
                }.disabled(selectedQueryID == nil)
            }
            Text(word("smartNote", "智能筛选按规则显示条目，不能手工添加成员。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func perform(_ body: () throws -> Void) {
        do { try body(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func selectScope(_ value: SharedLibraryBrowserScope) {
        scope = value
        if case .saved(let id) = value, let item = store.metadata.savedQueries[id] { query = item.query }
    }
    private func acceptDrop(_ values: [String], action: (Set<String>) throws -> Void) -> Bool {
        guard let keys = SharedLibraryBrowserLogic.validatedDropKeys(values, entries: entries) else {
            errorMessage = word("invalidDrop", "拖放条目不属于当前资料库")
            return false
        }
        do { try action(keys); errorMessage = nil; return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    private func dragProvider(for entry: SharedLibraryBrowserEntry) -> NSItemProvider {
        let provider = NSItemProvider(object: entry.id as NSString)
        if let transfer = SharedLibraryBrowserLogic.canvasTransfer(for: entry),
           let payload = try? transfer.encoded() {
            provider.registerDataRepresentation(
                forTypeIdentifier: "org.d-workbench.canvas-item", visibility: .all
            ) { completion in
                completion(payload, nil)
                return nil
            }
        }
        return provider
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
        SharedLibraryBrowserLogic.quickUseAllowed(entry)
    }
    private func canAdd(_ entry: SharedLibraryBrowserEntry) -> Bool {
        guard entry.item.readiness == .available, entry.item.compatible != false else { return false }
        switch entry.selection {
        case .operation, .asset, .tool: return true
        case .unavailable: return false
        }
    }
    private func canPreview(_ entry: SharedLibraryBrowserEntry) -> Bool {
        guard entry.item.readiness == .available, entry.item.compatible != false else { return false }
        if case .asset = entry.selection { return true }
        return false
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
