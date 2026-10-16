import AppKit
import DWorkbench
import SwiftUI

/// Adapts the existing workbench editor-close gate; owns no project or draft state.
struct MetadataEditorLifecycle: Sendable {
    var begin: @MainActor @Sendable () -> Void = {}
    var end: @MainActor @Sendable () -> Void = {}
}
private struct MetadataEditorLifecycleKey: EnvironmentKey { static let defaultValue = MetadataEditorLifecycle() }
extension EnvironmentValues {
    var metadataEditorLifecycle: MetadataEditorLifecycle {
        get { self[MetadataEditorLifecycleKey.self] }
        set { self[MetadataEditorLifecycleKey.self] = newValue }
    }
}

public typealias SharedLibraryAnnotationSave = @MainActor (ProjectAssetEditBaseline, String?, String?, Bool?) async throws -> Void

@MainActor func metadataText(_ language: UILanguageStore?, _ key: String, _ zh: String, _ en: String) -> String {
    workflowText(language, "metadata.panel." + key, fallback: language?.effectiveLanguageIdentifier.hasPrefix("en") == true ? en : zh)
}

struct AssetAnnotationRequest: Identifiable {
        let id = UUID()
        let snapshot: ProjectAssetMetadataSnapshot
        var context: String? = nil
        let validate: () throws -> Void
        let save: SharedLibraryAnnotationSave
    }

/// Same factual sections in library and exact workflow results; only the captured owner writes.
struct SharedAssetMetadataPanel: View {
    let snapshot: ProjectAssetMetadataSnapshot
    let library: SharedLibraryStore?
    let validate: () throws -> Void
    let save: SharedLibraryAnnotationSave?
    var onQuery: ((SharedLibraryPropertyQuery) -> Void)? = nil
    var onOpenSource: ((WorkflowAssetReference) -> Void)? = nil
    var onEdit: ((AssetAnnotationRequest) -> Void)? = nil
    @State private var editing: AssetAnnotationRequest?
    @State private var showsRaw = false
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String, _ en: String) -> String { metadataText(language, key, zh, en) }
    private var unknown: String { t("unknown", "未记录", "Not recorded") }
    private var logicalKey: String { "asset:" + snapshot.projectID.uuidString + ":" + snapshot.asset.id.uuidString }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(t("description", "说明与组织", "Description & organization")) {
                VStack(alignment: .leading, spacing: 7) {
                    row(t("displayName", "显示名（不重命名文件）", "Display name (does not rename file)"), snapshot.asset.name)
                    row(t("note", "用户说明", "User note"), snapshot.asset.note.isEmpty ? unknown : snapshot.asset.note)
                    row(t("favorite", "收藏", "Favorite"), snapshot.asset.isFavorite ? t("yes", "是", "Yes") : t("no", "否", "No"))
                    if let save {
                        Button(t("edit", "编辑名称、说明和收藏…", "Edit name, note & favorite…")) {
                            let request = AssetAnnotationRequest(snapshot: snapshot, validate: validate, save: save)
                            if let onEdit { onEdit(request) } else { editing = request }
                        }.accessibilityIdentifier("asset-annotations-edit").workbenchHelp("RESULT-INFO", target: "asset:\(snapshot.projectID):\(snapshot.instanceID):\(snapshot.asset.id):\(snapshot.record?.reference)")
                    }
                    SharedLibraryTagSection(store: library, target: .init(key: logicalKey, title: snapshot.asset.name, legacy: snapshot.asset.tags), validateTarget: validate)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(t("technical", "技术属性（已记录值）", "Technical properties (recorded)")) {
                VStack(alignment: .leading, spacing: 6) {
                    row(t("format", "格式", "Format"), snapshot.asset.mediaType)
                    if snapshot.asset.workflowContentKind == .image || snapshot.asset.workflowContentKind == .video {
                    dimension(t("width", "宽度", "Width"), value: snapshot.asset.metadata.width, width: true)
                    dimension(t("height", "高度", "Height"), value: snapshot.asset.metadata.height, width: false)
                    row(t("depth", "位深", "Bit depth"), snapshot.asset.metadata.bitDepth.map { "\($0) bit" } ?? unknown)
                    row(t("color", "色彩空间", "Color space"), snapshot.asset.metadata.colorSpace ?? unknown)
                    }
                    row(t("registered", "项目登记时间（本地时区）", "Project registration (local time)"), snapshot.asset.createdAt.formatted(date: .abbreviated, time: .standard))
                    if let audio = snapshot.asset.metadata.audio?.format {
                        row(t("audio", "音频", "Audio"), "\(audio.sampleRate) Hz · \(audio.channelCount) ch · \(audio.bitDepth) bit")
                        if audio.sampleRate > 0 { row(t("duration", "时长", "Duration"), String(format: "%.3f s", Double(audio.frameCount) / audio.sampleRate)) }
                    }
                    if let video = snapshot.asset.metadata.video {
                        row(t("video", "视频", "Video"), "\(video.width) × \(video.height) px · \(video.codec)")
                        row(t("fps", "帧率", "Frame rate"), "\(video.frameRate.numerator)/\(video.frameRate.denominator) fps")
                        if video.durationDenominator > 0 { row(t("duration", "时长", "Duration"), String(format: "%.3f s", Double(video.durationNumerator) / Double(video.durationDenominator))) }
                    }
                    Text(t("unknownRule", "缺失值不填零；格式不适用的字段不参与数值筛选。", "Missing values are not zero; inapplicable fields do not match numeric filters.")).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(t("source", "生成与来源", "Generation & provenance")) {
                VStack(alignment: .leading, spacing: 7) {
                    if let issue = snapshot.sourceIssue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let model = snapshot.facts.model {
                        row(model.kind == .recordedIdentity ? t("model", "实际记录模型", "Recorded model") : t("localModel", "请求中的本地模型引用", "Local model reference in request"), model.kind == .recordedIdentity ? t("modelNameUnrecorded", "模型名称未记录", "Model name not recorded") : URL(fileURLWithPath: model.value).lastPathComponent)
                        row(t("revision", "模型版本", "Model revision"), model.revision == nil ? unknown : t("exactRecordedVersion", "精确已记录版本（见技术详情）", "Exact recorded revision (see technical details)"))
                        WorkflowTechnicalDetails(value: model.value + "\n" + (model.revision ?? unknown))
                        if let onQuery {
                            WorkbenchMenu(t("filterModel", "按此模型筛选", "Filter by this model")) {
                                if model.revision != nil { WorkbenchMenuAction(t("exactVersion", "精确模型及版本", "Exact model & revision")) { onQuery(.init(model: model)) } }
                                WorkbenchMenuAction(t("allVersions", "此模型的所有已记录版本", "All recorded revisions of this model")) { var source = model; source.revision = nil; onQuery(.init(model: source)) }
                            }
                        }
                    } else { row(t("model", "实际记录模型", "Recorded model"), unknown) }
                    row(t("requestSeed", "提交请求的 Seed", "Seed in submitted request"), snapshot.requestedSeed ?? unknown)
                    row(t("backend", "后端报告", "Backend report"), snapshot.record?.metadata["backend"] ?? snapshot.job?.resultMetadata["backend"] ?? unknown)
                    if let record = snapshot.record {
                        WorkflowTechnicalDetails(value: record.operationID)
                        if record.parents.isEmpty { Text(t("noParents", "未登记直接来源资产", "No direct source assets recorded")).font(.caption) }
                        ForEach(record.parents, id: \.self) { parent in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("sourceAsset", "已登记来源素材", "Recorded source asset"))
                                WorkflowTechnicalDetails(value: String(describing: parent))
                                if let onOpenSource { Button(t("openParent", "查看此来源", "View this source")) { onOpenSource(parent) } }
                                if let onQuery { Button(t("filterParent", "查找直接来自此资产的结果", "Find direct derivatives of this asset")) { onQuery(.init(directParent: parent)) } }
                            }
                        }
                    }
                    if snapshot.record == nil { Text(t("unknownParents", "直接来源：未登记或尚不可访问", "Direct sources: not recorded or currently unavailable")).font(.caption) }
                    if let occurrences = snapshot.occurrences, !occurrences.isEmpty {
                        DisclosureGroup(t("calls", "登记的运行与调用", "Recorded runs & calls")) {
                            ForEach(Array(occurrences.enumerated()), id: \.offset) { _, value in
                                Text("Run \(value.runID)\nNode \(value.nodeID)\nCall \(value.stepID)").font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    DisclosureGroup(t("raw", "原始本地请求与来源（可能包含私有路径或文本）", "Local request & source (may contain private paths or text)"), isExpanded: $showsRaw) {
                        if showsRaw { ScrollView { Text(rawSource).font(.caption2.monospaced()).textSelection(.enabled) }.frame(maxHeight: 200) }
                    }
                    row(t("rights", "作者、许可与拍摄时间", "Author, rights & capture time"), t("rightsUnknown", "未记录；不根据用户名或标签推定", "Not recorded; never inferred from user name or tags"))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(t("technicalDetails", "技术详情与完整身份", "Technical details & full identity")) {
                VStack(alignment: .leading, spacing: 5) {
                    row(t("project", "项目", "Project"), snapshot.projectName)
                    row(t("instance", "当前实例", "Open instance"), snapshot.instanceID.uuidString)
                    row(t("asset", "资产", "Asset"), snapshot.asset.id.uuidString)
                    if let record = snapshot.record {
                        row(t("version", "内容版本", "Content version"), record.reference.version.uuidString)
                        DisclosureGroup(t("digest", "内容摘要（登记记录）", "Content digest (recorded)")) {
                            Text(record.reference.sha256).font(.caption.monospaced()).textSelection(.enabled)
                            Text(t("digestLimit", "字节摘要不证明作者、许可或完全可复现。", "A byte digest does not establish authorship, rights, or full reproducibility.")).font(.caption2)
                        }
                    } else { row(t("version", "内容版本", "Content version"), unknown) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(t("files", "文件与导出", "Files & export")) {
                row(t("relativePath", "项目内位置记录", "Recorded project location"), snapshot.asset.relativePath)
                Text(t("fileLimit", "此处显示已保存位置；实际可访问性与字节校验由打开/文件位置操作单独检查。", "This is the saved location; opening and file-location operations check access and bytes separately.")).font(.caption)
                Text(t("exportLimit", "现有导出节点每次 1–8 个引用，名称不超过 128 UTF-8 字节。导出原媒体、受限配方与回执；不包含共享标签、说明或完整私有请求。配方脱敏不等于已清除媒体内 GPS/作者等信息。", "The existing export node accepts 1–8 references and names up to 128 UTF-8 bytes. It exports original media, a limited recipe and receipt, without shared tags, notes or the full private request. Recipe redaction does not strip embedded GPS or author metadata.")).font(.caption)
            }
        }.font(.caption).textSelection(.enabled)
        .sheet(item: $editing) { request in
            AssetAnnotationEditor(snapshot: request.snapshot, validate: request.validate, save: request.save) { editing = nil }
        }
    }
    private var rawSource: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let record = snapshot.record { return (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) } ?? unknown }
        if let job = snapshot.job { return (try? encoder.encode(job)).map { String(decoding: $0, as: UTF8.self) } ?? unknown }
        return unknown
    }
    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
    private func dimension(_ title: String, value: Int?, width: Bool) -> some View {
        HStack {
            row(title, value.map { "\($0) px" } ?? ([WorkflowDataKind.image, .video].contains(snapshot.asset.workflowContentKind ?? .text) ? unknown : t("notApplicable", "不适用", "Not applicable")))
            Spacer(minLength: 0)
            if let value, value > 0, let onQuery {
                Button("≥ \(value)", systemImage: "line.3.horizontal.decrease.circle") {
                    onQuery(width ? .init(width: .init(minimum: value)) : .init(height: .init(minimum: value)))
                }.help(t("propertyFilter", "加入属性条件，不创建标签", "Add a property condition, not a tag"))
            }
        }
    }
}

struct AssetAnnotationEditor: View {
    @State private var snapshot: ProjectAssetMetadataSnapshot
    @State private var context: String?
    @State private var validate: () throws -> Void
    @State private var save: SharedLibraryAnnotationSave
    let dismiss: () -> Void
    @State private var name: String
    @State private var note: String
    @State private var favorite: Bool
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.metadataEditorLifecycle) private var lifecycle
    @Environment(\.dLanguageStore) private var language
    init(snapshot: ProjectAssetMetadataSnapshot, context: String? = nil, validate: @escaping () throws -> Void, save: @escaping SharedLibraryAnnotationSave, dismiss: @escaping () -> Void) {
        _context = State(initialValue: context); _snapshot = State(initialValue: snapshot); _validate = State(initialValue: validate); _save = State(initialValue: save)
        _name = State(initialValue: snapshot.asset.name); _note = State(initialValue: snapshot.asset.note)
        _favorite = State(initialValue: snapshot.asset.isFavorite); self.dismiss = dismiss
    }
    private func t(_ key: String, _ zh: String, _ en: String) -> String { metadataText(language, key, zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("editResultInfo", "编辑结果信息", "Edit result information") + " · " + snapshot.asset.name).font(.headline)
            Text(context ?? (snapshot.projectName + " · " + snapshot.asset.createdAt.formatted(date: .abbreviated, time: .standard))).font(.caption).textSelection(.enabled)
            Text(t("annotationImpact", "只修改此结果的信息；不改正文、节点参数或文件名。", "Changes this result’s information only; not its content, node parameters, or file name.")).font(.callout)
            Text(t("resultName", "结果名称", "Result name")).font(.subheadline)
            TextField(t("resultName", "结果名称", "Result name"), text: $name).textFieldStyle(WorkbenchGlassTextFieldStyle()).accessibilityIdentifier("asset-annotation-name").workbenchHelp("ANNOTATION-NAME")
            Text(t("resultNote", "结果说明", "Result note")).font(.subheadline)
            TextField(t("resultNote", "结果说明", "Result note"), text: $note, axis: .vertical).lineLimit(4...10).textFieldStyle(WorkbenchGlassTextFieldStyle()).accessibilityIdentifier("asset-annotation-note").workbenchHelp("ANNOTATION-NOTE")
            Toggle(t("favorite", "收藏", "Favorite"), isOn: $favorite)
            Text(t("instanceWrite", "这些注释只写入此项目实例；共享组织标签按逻辑资产共享。", "These annotations belong to this project instance; organization tags are shared by logical asset.")).font(.caption)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(t("cancel", "取消", "Cancel"), action: dismiss).workbenchHelp("ANNOTATION-CANCEL").keyboardShortcut(.cancelAction)
                Button(t("saveResultInfo", "保存结果信息", "Save result information")) {
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            try validate()
                            let baseline = ProjectAssetEditBaseline(snapshot: snapshot)
                            try await save(baseline, name.utf8.elementsEqual(baseline.name.utf8) ? nil : name,
                                note.utf8.elementsEqual(baseline.note.utf8) ? nil : note, favorite == baseline.favorite ? nil : favorite)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                }.workbenchHelp("ANNOTATION-SAVE").keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            WorkflowTechnicalDetails(value: snapshot.projectID.uuidString + "\n" + snapshot.instanceID.uuidString + "\n" + snapshot.asset.id.uuidString)
        }.padding(24).frame(minWidth: 410, idealWidth: 480).disabled(saving).interactiveDismissDisabled()
        .onAppear { lifecycle.begin() }.onDisappear { lifecycle.end() }
    }
}
