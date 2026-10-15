import DWorkbench
import Observation
import SwiftUI

struct SharedLibraryTagTarget: Identifiable {
    let key: String
    let title: String
    var legacy: [String] = []
    var legacyFailure: String? = nil
    var activityID: String? = nil
    var id: String { activityID ?? key }
    static func legacy(_ state: ModelNodeTagReadState) -> (names: [String], failure: String?) {
        switch state {
        case .valid(let names): (names, nil)
        case .missing: ([], nil)
        case .corrupt: ([], "Legacy tags are damaged / 旧标签损坏，原记录已保留，暂停整合。")
        }
    }
}

/// Shared live canonical values; only an explicit editor owns a draft.
struct SharedLibraryTagSection: View {
    let store: SharedLibraryStore?
    let target: SharedLibraryTagTarget
    var validateTarget: () throws -> Void
    @State private var editing = false
    @Environment(\.dLanguageStore) private var language
    private func text(_ key: String, _ fallback: String) -> String { workflowText(language, "metadata.tags." + key, fallback: fallback) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text("title", "组织标签")).font(.subheadline.weight(.semibold))
            if let store {
                let ids = store.metadata.tagAssignments[target.key] ?? []
                Text(store.metadata.tags.values.filter { ids.contains($0.id) }.map(\.name).sorted().joined(separator: " · ").nilIfEmpty ?? text("none", "无共享标签"))
                    .font(.caption).textSelection(.enabled)
                if !store.metadata.importedLegacyKeys.contains(target.key), !target.legacy.isEmpty {
                    Text(text("legacy", "旧标签（尚未整合）") + ": " + target.legacy.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if let failure = target.legacyFailure { Text(failure).font(.caption).foregroundStyle(.orange) }
                Button(text("edit", "编辑标签…")) { editing = true }
                    .accessibilityIdentifier("organization-tags-edit")
                    .sheet(isPresented: $editing) { SharedLibraryTagEditor(store: store, targets: [target], validateTarget: validateTarget) }
            } else { Text(text("unavailable", "共享标签库不可用；未写入旧标签存储。")) .font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct SharedLibraryTagEditor: View {
    let store: SharedLibraryStore
    @State private var targets: [SharedLibraryTagTarget]
    @State private var baseline: SharedLibraryTagEditBaseline
    @State private var validateTarget: () throws -> Void
    @State private var add: Set<UUID>
    @State private var remove: Set<UUID>
    @State private var selectedLegacy: [String: Set<Int>]
    @State private var name = ""
    @State private var names: [String] = []
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.metadataEditorLifecycle) private var lifecycle
    @Environment(\.dLanguageStore) private var language

    init(store: SharedLibraryStore, targets: [SharedLibraryTagTarget], add: Set<UUID> = [], remove: Set<UUID> = [], validateTarget: @escaping () throws -> Void) {
        self.store = store
        _targets = State(initialValue: targets)
        _baseline = State(initialValue: .init(keys: Set(targets.map(\.key)), metadata: store.metadata))
        _validateTarget = State(initialValue: validateTarget)
        _add = State(initialValue: add); _remove = State(initialValue: remove)
        // Empty assignments cannot prove that legacy names were never deliberately removed.
        // Start unselected and retain each explicitly selected instance's source independently.
        _selectedLegacy = State(initialValue: [:])
    }
    private func text(_ key: String, _ fallback: String) -> String { workflowText(language, "metadata.tags." + key, fallback: fallback) }
    private var orderedTags: [SharedLibraryTag] { baseline.tags.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("edit", "编辑标签…")).font(.headline)
            Text(targets.map(\.title).joined(separator: " · ")).lineLimit(3)
            Text(text("storage", "共享资料库标签按逻辑项目/资产共享；恢复实例共用标签。标签不随现有项目备份或媒体导出包交换。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(orderedTags) { tag in
                        let count = baseline.assignments.values.filter { $0.contains(tag.id) }.count
                        Toggle(tag.name + (count > 0 && count < baseline.assignments.count ? " (\(count)/\(baseline.assignments.count))" : ""), isOn: Binding(get: {
                            add.contains(tag.id) || (!remove.contains(tag.id) && count == baseline.assignments.count)
                        }, set: { included in
                            if included { add.insert(tag.id); remove.remove(tag.id) }
                            else { remove.insert(tag.id); add.remove(tag.id) }
                        }))
                    }
                    ForEach(targets.filter { !baseline.integratedKeys.contains($0.key) }) { target in
                        if !target.legacy.isEmpty {
                            Divider()
                            Text(target.title + " · " + text("legacy", "旧标签（尚未整合）")).font(.subheadline)
                            Text(text("chooseLegacy", "只整合下方勾选的旧标签；未选内容保留在原记录中。存在共享改动时默认不合并。")) .font(.caption).foregroundStyle(.secondary)
                            ForEach(target.legacy.indices, id: \.self) { index in
                                Toggle(target.legacy[index], isOn: Binding(get: { selectedLegacy[target.id]?.contains(index) == true }, set: { value in
                                    if value { selectedLegacy[target.id, default: []].insert(index) }
                                    else { selectedLegacy[target.id]?.remove(index) }
                                }))
                            }
                        }
                        if let failure = target.legacyFailure { Text(failure).foregroundStyle(.orange) }
                    }
                    ForEach(names.indices, id: \.self) { index in
                        HStack { Text(names[index]); Button { names.remove(at: index) } label: { Image(systemName: "minus.circle") } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField(text("new", "创建标签并添加到这些对象"), text: $name).textFieldStyle(.roundedBorder)
                Button(text("stage", "加入待保存")) {
                    let next = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !next.isEmpty, next.count <= 32 else { error = text("invalidName", "标签名称需要 1–32 个字符。"); return }
                    if !names.contains(where: { $0.utf8.elementsEqual(next.utf8) }) { names.append(next) }
                    name = ""
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Button(text("cancel", "取消")) { dismiss() }
                Spacer()
                Button(baseline.integratedKeys.isSuperset(of: Set(targets.map(\.key))) ? text("saveOnly", "保存标签") : text("save", "确认整合并保存标签")) {
                    do {
                        try validateTarget()
                        let keys = Set(targets.map(\.key)).subtracting(baseline.integratedKeys)
                        var legacy: [String: [String]] = [:]
                        for target in targets where keys.contains(target.key) {
                            for index in target.legacy.indices where selectedLegacy[target.id]?.contains(index) == true {
                                let name = target.legacy[index]
                                if !legacy[target.key, default: []].contains(where: { $0.utf8.elementsEqual(name.utf8) }) { legacy[target.key, default: []].append(name) }
                            }
                        }
                        try store.editOrganizationTags(expected: baseline, add: add, remove: remove, createNames: names,
                            selectedLegacyNames: legacy, confirmIntegration: keys)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(WorkbenchPrimaryButtonStyle()).disabled(targets.isEmpty || targets.contains { $0.legacyFailure != nil && !baseline.integratedKeys.contains($0.key) } || !name.isEmpty)
            }
        }.padding(18).frame(width: 460, height: 520).interactiveDismissDisabled()
        .onAppear { lifecycle.begin() }.onDisappear { lifecycle.end() }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

struct WorkflowAssetOrganization: View {
    let controller: WorkflowController
    let reference: WorkflowAssetReference
    let metadata: SharedLibraryStore?
    @State private var expanded = false
    @Environment(\.dLanguageStore) private var language
    var onQuery: ((SharedLibraryPropertyQuery) -> Void)? = nil
    var onEdit: ((AssetAnnotationRequest) -> Void)? = nil
    var body: some View {
        DisclosureGroup(metadataText(language, "resultInformation", "结果信息", "Result information") + " · " + (controller.availableAssets.first(where: { $0.id == reference.assetID })?.name ?? metadataText(language, "unnamedResult", "未命名结果", "Untitled result")), isExpanded: $expanded) {
            if expanded { WorkflowAssetMetadataHost(controller: controller, reference: reference, metadata: metadata, onQuery: onQuery, onEdit: onEdit) }
        }
    }
}

@MainActor @Observable final class AssetMetadataLoadState {
    private(set) var snapshot: ProjectAssetMetadataSnapshot?
    private(set) var failure: String?
    private(set) var identity: WorkflowAssetPreviewState.Identity?
    private var generation: UUID?
    func invalidate() { generation = nil; identity = nil; snapshot = nil; failure = nil }
    func load(identity: WorkflowAssetPreviewState.Identity, read: () async throws -> ProjectAssetMetadataSnapshot) async {
        guard !Task.isCancelled else { return }
        let generation = UUID(); self.generation = generation; if self.identity != identity { snapshot = nil }
        self.identity = identity; failure = nil
        do {
            let value = try await read()
            guard !Task.isCancelled, self.generation == generation, self.identity == identity else { return }
            snapshot = value
        } catch {
            guard !Task.isCancelled, self.generation == generation, self.identity == identity else { return }
            failure = error.localizedDescription
        }
    }
}

struct WorkflowAssetMetadataHost: View {
    let controller: WorkflowController
    let reference: WorkflowAssetReference
    let metadata: SharedLibraryStore?
    var onQuery: ((SharedLibraryPropertyQuery) -> Void)? = nil
    var onEdit: ((AssetAnnotationRequest) -> Void)? = nil
    @State private var state = AssetMetadataLoadState()
    @State private var source: WorkflowAssetReference?
    @Environment(\.dLanguageStore) private var language
    private struct ReadIdentity: Hashable { let target: WorkflowAssetPreviewState.Identity; let revision: UInt64 }
    private var target: WorkflowAssetReference { source ?? reference }
    private var identity: WorkflowAssetPreviewState.Identity { .init(controller: controller, reference: target) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if source != nil { Button(metadataText(language, "backResult", "返回结果", "Back to result")) { source = nil } }
            if state.identity == identity, let failure = state.failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
            if state.identity == identity, let snapshot = state.snapshot {
                SharedAssetMetadataPanel(snapshot: snapshot, library: metadata,
                    validate: WorkflowMetadataTarget.validation(controller: controller, assetID: target.assetID),
                    save: { baseline, name, note, favorite in
                        try await controller.saveAssetAnnotations(expected: baseline, name: name, note: note, isFavorite: favorite)
                        await reload()
                    }, onQuery: onQuery, onOpenSource: { parent in source = parent }, onEdit: onEdit)
            } else if state.failure == nil { ProgressView() }
        }
        .task(id: ReadIdentity(target: identity, revision: controller.displayAssetGeneration)) { await reload() }
        .onDisappear { state.invalidate() }
    }
    private func reload() async {
        let requested = target, expected = identity
        await state.load(identity: expected) {
            let value = try await controller.services.store.assetMetadataSnapshot(id: requested.assetID, reference: requested)
            guard controller.canReadLibraryMetadata, controller.projectInstanceID == value.instanceID else { throw WorkflowIssue("Metadata owner closed / 所属实例已关闭。") }
            return value
        }
    }
}

@MainActor enum WorkflowMetadataTarget {
    static func validation(controller: WorkflowController, assetID: UUID? = nil) -> () throws -> Void {
        let project = controller.projectID, instance = controller.projectInstanceID
        return {
            guard controller.canEditLibraryMetadata, controller.projectID == project,
                  controller.projectInstanceID == instance,
                  assetID.map({ id in controller.availableAssets.contains { $0.id == id } }) ?? true else {
                throw WorkflowIssue("Metadata target is no longer open / 元数据所属项目实例或对象已改变。草稿未提交。")
            }
        }
    }
}
