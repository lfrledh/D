import AppKit
import DWorkbench
import SwiftUI

/// Search labels describe registered capabilities; they are never parsed as execution rules.
struct WorkflowLibraryEntry: Identifiable {
    let id: String
    let operation: WorkflowOperationDefinition
    let model: WorkflowModelChoice?
    let title: String
    let detail: String
    let tagKey: String
    let systemTags: [String]
    var transfer: WorkflowCanvasTransfer { .operation(id: operation.id, modelID: model?.id) }
}

@MainActor enum WorkflowLibraryProjection {
    static func entries(controller: WorkflowController, language: UILanguageStore?) -> [WorkflowLibraryEntry] {
        func word(_ key: String, _ fallback: String) -> String { workflowText(language, "canvas.library." + key, fallback: fallback) }
        func kind(_ value: WorkflowModelKind) -> String {
            switch value { case .text: word("text", "文字"); case .image: word("image", "图像")
            case .music: word("audio", "音频"); case .video: word("video", "视频"); case .pitch: word("pitch", "音高") }
        }
        let profiles = (try? TextModelProfiles.registered()) ?? []
        return controller.registry.definitions.sorted { $0.id < $1.id }.flatMap { definition -> [WorkflowLibraryEntry] in
            let title = WorkflowCanvasPresentation.operationTitle(definition, language: language)
            let detail = WorkflowCanvasPresentation.operationDetail(definition, language: language)
            var tags = [definition.modelKind == nil ? word("program", "程序") : word("model", "模型")]
            if let modality = definition.modelKind { tags.append(kind(modality)) }
            for portKind in (definition.inputs + definition.outputs).flatMap(\.kinds) {
                let label = WorkflowCanvasPresentation.kind(portKind, language: language)
                if !tags.contains(label) { tags.append(label) }
            }
            let base = WorkflowLibraryEntry(id: definition.id, operation: definition, model: nil,
                title: title, detail: detail, tagKey: "operation:" + definition.id, systemTags: tags)
            let models = controller.modelChoices.filter { $0.kind == definition.modelKind }.map { model in
                var facts = tags
                var key = "model:" + model.id
                if let descriptor = ModelNodeCatalog.entries.first(where: { model.id == model.kind.rawValue + ":" + $0.revision }) {
                    key = descriptor.id // Preserve the existing model-card tag key.
                    facts += [descriptor.engine, descriptor.precision]
                    if descriptor.id == "flux2-klein-4b-q8" { facts += ["4B", "q8"] }
                }
                if let profile = profiles.first(where: { model.id == "text:" + $0.revision }) {
                    facts.append("\(profile.quantizationBits)-bit")
                    let sizes = ["mlx-community/Qwen2.5-0.5B-Instruct-4bit":"0.5B", "mlx-community/Qwen2.5-1.5B-Instruct-4bit":"1.5B", "mlx-community/Qwen2.5-7B-Instruct-4bit":"7B", "mlx-community/Qwen2.5-32B-Instruct-4bit":"32B"]
                    if let size = sizes[profile.id] { facts.append(size) }
                }
                return WorkflowLibraryEntry(id: definition.id + "/" + model.id, operation: definition, model: model,
                    title: model.displayName, detail: title, tagKey: key, systemTags: facts)
            }
            return [base] + models
        }
    }
}

@MainActor struct WorkflowNodeLibrary: View {
    let controller: WorkflowController
    let tagStore: ModelNodeTagStore
    let onAdd: (WorkflowLibraryEntry) -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var query = ""
    @State private var filters: Set<String> = []
    @State private var edited: WorkflowLibraryEntry?
    @State private var tagsRevision = 0
    private func text(_ key: String, _ fallback: String) -> String { workflowText(language, "canvas.library." + key, fallback: fallback) }
    private func tags(_ entry: WorkflowLibraryEntry) -> [String] {
        _ = tagsRevision
        if case .valid(let values) = tagStore.readState(for: entry.tagKey) { return values }; return []
    }
    private var entries: [WorkflowLibraryEntry] { WorkflowLibraryProjection.entries(controller: controller, language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text("nodes", "节点库"), systemImage: "square.grid.2x2").font(.headline)
            TextField(text("search", "搜索名称或标签"), text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("canvas-node-search")
            WorkflowLibraryFilters(tags: Array(Set(entries.flatMap { $0.systemTags + tags($0) })).sorted(), selected: $filters)
            Text(text("dragHint", "拖到画布，或点 ＋ 添加。双击节点编辑。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries.filter { LibrarySearch.matches(query: query, selectedTags: filters, title: $0.title,
                        detail: $0.detail, systemTags: $0.systemTags, userTags: tags($0)) }) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                    Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button { onAdd(entry) } label: { Image(systemName: "plus.circle") }
                                    .buttonStyle(.borderless).disabled(!controller.canEditCanvas)
                                    .accessibilityLabel(text("add", "加入画布") + " " + entry.title)
                            }
                            Text((entry.systemTags + tags(entry)).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                            Button(text("editTags", "编辑标签")) { edited = entry }.font(.caption).buttonStyle(.borderless)
                        }
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .draggable(entry.transfer)
                        .help(entry.operation.id)
                        .accessibilityIdentifier("canvas-library-" + entry.id)
                    }
                }
            }
        }.padding(12).background(.regularMaterial)
        .popover(item: $edited) { entry in
            WorkflowTagsEditor(title: entry.title, initial: tags(entry), corrupt: tagStore.readState(for: entry.tagKey) == .corrupt) { values in
                try tagStore.setTags(values, for: entry.tagKey); tagsRevision += 1
            }.id(entry.tagKey)
        }
    }
}

struct WorkflowLibraryFilters: View {
    let tags: [String]
    @Binding var selected: Set<String>
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        HStack {
            Menu {
                ForEach(tags, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(get: { selected.contains(tag) }, set: { if $0 { selected.insert(tag) } else { selected.remove(tag) } }))
                }
            } label: { Label(workflowText(language, "canvas.library.filter", fallback: "筛选标签") + (selected.isEmpty ? "" : " (\(selected.count))"), systemImage: "line.3.horizontal.decrease") }
            if !selected.isEmpty {
                Button { selected = [] } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).accessibilityLabel(workflowText(language, "canvas.library.clear", fallback: "清除筛选"))
            }
        }
        if !selected.isEmpty { Text(selected.sorted().joined(separator: " + ")).font(.caption).foregroundStyle(.secondary) }
    }
}

/// The actual editor keeps draft text on deletion/failure; successful addition alone clears it.
@MainActor struct WorkflowTagsEditor: View {
    let title: String
    let initial: [String]
    var corrupt = false
    let save: ([String]) async throws -> Void
    @State private var values: [String] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(workflowText(language, "canvas.tags.note", fallback: "系统标签来自能力资料。下方是你的标签，不改变执行参数。"))
                .font(.caption).foregroundStyle(.secondary)
            if corrupt {
                Text(workflowText(language, "canvas.tags.corrupt", fallback: "原标签记录损坏，已保留并暂停编辑。")) .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(values, id: \.self) { tag in
                        HStack {
                            Text(tag).textSelection(.enabled); Spacer()
                            Button { commit(values.filter { $0 != tag }, addition: false) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel(workflowText(language, "canvas.tags.remove", fallback: "删除标签") + " " + tag)
                        }
                    }
                }
            }.frame(maxHeight: 160)
            HStack {
                TextField(workflowText(language, "canvas.tags.new", fallback: "新标签（最多32个字符）"), text: $draft)
                    .textFieldStyle(.roundedBorder).onSubmit { commit(values + [draft], addition: true) }
                    .accessibilityIdentifier("canvas-tag-draft")
                Button(workflowText(language, "canvas.tags.add", fallback: "添加")) { commit(values + [draft], addition: true) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(16).frame(width: 330).disabled(busy || corrupt)
        .onAppear { values = initial }
    }
    private func commit(_ proposed: [String], addition: Bool) {
        guard !busy, !corrupt else { return }
        do {
            let validated = try LibraryTags.validate(proposed)
            busy = true
            Task { @MainActor in
                defer { busy = false }
                do { try await save(validated); values = validated; if addition { draft = "" }; error = nil }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor struct WorkflowAssetLibrary: View {
    let controller: WorkflowController
    let onAdd: (UUID, UUID) -> Void
    let onImport: () -> Void
    let onDropFile: (URL) -> Bool
    @State private var query = ""
    @State private var filters: Set<String> = []
    @State private var edited: ProjectAsset?
    @State private var preview: WorkflowAssetReference?
    @Environment(\.dLanguageStore) private var language
    private func text(_ key: String, _ fallback: String) -> String { workflowText(language, "canvas.assets." + key, fallback: fallback) }
    private func systemTags(_ asset: ProjectAsset) -> [String] {
        [controller.libraryKind(of: asset).map { WorkflowCanvasPresentation.kind($0, language: language) } ?? asset.mediaType,
         asset.role == .original ? text("input", "投入素材") : text("generated", "生成结果")]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(text("title", "资产库"), systemImage: "photo.on.rectangle.angled").font(.headline)
                Spacer()
                Button(action: onImport) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).disabled(!controller.canEditCanvas)
                    .help(text("import", "导入素材")) .accessibilityIdentifier("canvas-import-asset")
            }
            TextField(text("search", "搜索素材或标签"), text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("canvas-asset-search")
            WorkflowLibraryFilters(tags: Array(Set(controller.availableAssets.flatMap { systemTags($0) + $0.tags })).sorted(), selected: $filters)
            Text(text("hint", "拖到画布创建输入，或拖到已有素材节点。")) .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.availableAssets.filter { LibrarySearch.matches(query: query, selectedTags: filters,
                        title: $0.name, detail: $0.note, systemTags: systemTags($0), userTags: $0.tags) }) { asset in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: icon(asset)).foregroundStyle(.secondary)
                                Text(asset.name).font(.callout.weight(.medium)).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            Text((systemTags(asset) + asset.tags).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                            HStack {
                                Button(text("add", "加入画布")) { if let project = controller.projectID { onAdd(project, asset.id) } }
                                    .disabled(!controller.canEditCanvas)
                                if let ref = controller.assetReferences[asset.id] {
                                    Button(text("preview", "查看")) {
                                        if ref.kind == .audio || ref.kind == .video { controller.mediaPreviewReference = ref }
                                        else { preview = ref }
                                    }
                                }
                                Button { edited = asset } label: { Image(systemName: "tag") }
                                    .accessibilityLabel(text("tags", "编辑资产标签")).disabled(!controller.canEditCanvas)
                            }.font(.caption).buttonStyle(.borderless)
                        }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .draggable(WorkflowCanvasTransfer.asset(projectID: controller.projectID ?? UUID(), assetID: asset.id))
                        .accessibilityIdentifier("canvas-asset-" + asset.id.uuidString)
                    }
                    if controller.availableAssets.isEmpty {
                        Text(text("empty", "导入文件或运行节点后，素材会出现在这里。"))
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical)
                    }
                }
            }
        }.padding(12).background(.regularMaterial)
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first, url.isFileURL, controller.canEditCanvas else { return false }
            return onDropFile(url)
        }
        .popover(item: $edited) { asset in
            WorkflowTagsEditor(title: asset.name, initial: asset.tags) { try await controller.setAssetTags(id: asset.id, tags: $0) }.id(asset.id)
        }
        .sheet(item: $preview) { reference in
            VStack {
                WorkflowAssetPreview(controller: controller, reference: reference)
                Button(text("close", "关闭")) { preview = nil }
            }.padding(20).frame(minWidth: 420, minHeight: 240)
        }
    }
    private func icon(_ asset: ProjectAsset) -> String {
        switch controller.libraryKind(of: asset) {
        case .image: "photo"; case .audio: "waveform"; case .video: "film"; case .text: "doc.text"; default: "doc"
        }
    }
}
