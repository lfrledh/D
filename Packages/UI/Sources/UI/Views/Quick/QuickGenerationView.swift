import AppKit
import AVKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

@MainActor func baselineText(_ language: UILanguageStore?, _ key: String, fallback: String) -> String {
    workflowText(language, "baseline02.ui." + key, fallback: fallback)
}

struct QuickGenerationView: View {
    @Bindable var quick: QuickGenerationController
    let model: WorkbenchModel
    let onChooseModel: () -> Void
    let onSettingsToCanvas: (QuickDraft) -> Void
    let onResultToCanvas: (WorkflowAssetReference) -> Void
    let onValueToCanvas: (WorkflowDatum) -> Void
    @State private var advanced = false
    @State private var history = false
    @State private var inputIssue: String?
    @State private var preview: WorkflowAssetReference?
    @Environment(\.dLanguageStore) private var language
    private var definition: WorkflowOperationDefinition? { quick.definition }
    private var title: String {
        let id = quick.draft?.node.parameters["modelID"]?.string ?? ""
        return model.projectSession.explicitModelChoices.first { $0.id == id }?.displayName
            ?? ModelNodeCatalog.entries.first { descriptor in WorkflowModelKind.allCases.contains { id == $0.rawValue + ":" + descriptor.revision } }?.title
            ?? (id.isEmpty ? "选择一个模型" : "指定模型未准备")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.bold())
                    Text(definition.map { WorkflowCanvasPresentation.operationTitle($0, language: language) } ?? "从资料库选择已适配模型").font(.caption).foregroundStyle(.secondary)
                    if let id = quick.draft?.node.parameters["modelID"]?.string, !id.isEmpty {
                        Text((ModelNodeCatalog.entries.first { descriptor in WorkflowModelKind.allCases.contains { id == $0.rawValue + ":" + descriptor.revision } }?.precision ?? "") + " · " + readinessTitle(id))
                            .font(.caption).foregroundStyle(.secondary).help(id)
                    }
                }
                Spacer()
                Button(baselineText(language, "label.48ff0f9d0b4d", fallback: "更换模型"), action: onChooseModel)
                if let draft = quick.draft {
                    Button(baselineText(language, "label.7d9795fa3684", fallback: "带设置到工作流")) { onSettingsToCanvas(draft) }
                }
            }.padding(20)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(baselineText(language, "label.39a07dc80743", fallback: "创作输入")).font(.headline)
                        if let definition, let draft = quick.draft {
                            ForEach(definition.fields.filter { ["task", "promptText"].contains($0.id) }) { field in
                                QuickParameterField(operationID: draft.node.operationID, field: field, value: draft.node.parameters[field.id] ?? field.defaultValue,
                                    onChange: { quick.setParameter(field.id, value: $0, draftID: draft.id) }, raw: draft.fieldText[field.id], onRaw: { quick.setFieldText(field.id, text: $0, draftID: draft.id) })
                            }
                            if definition.inputs.contains(where: { $0.id == "content" && $0.assetListKind == nil && $0.kinds.contains(.text) }) {
                                Text(baselineText(language, "label.bf8881ad5d3a", fallback: "参考正文（可选）")).font(.subheadline)
                                TextEditor(text: Binding(get: { draft.inputs["content"]?.datum?.text ?? "" },
                                    set: { quick.setInput("content", value: $0.isEmpty ? nil : .data(.text($0)), draftID: draft.id) }))
                                    .frame(minHeight: 100).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                            }
                            ForEach(definition.inputs.filter { $0.assetListKind != nil || !["task", "prompt", "content"].contains($0.id) }) { port in
                                VStack(alignment: .leading) {
                                    Text(WorkflowCanvasPresentation.portTitle(operationID: draft.node.operationID, port: port, input: true, language: language) +
                                         (port.required ? baselineText(language, "required", fallback: " · 必选") : baselineText(language, "optional", fallback: " · 可选"))).font(.subheadline)
                                    if port.assetListKind != nil {
                                        switch assetListPresentation(port: port, draftID: draft.id) {
                                        case .valid(let items):
                                            ForEach(items) { item in
                                                if let ordinal = items.firstIndex(where: { $0.id == item.id }),
                                                   case .asset(let reference) = item.value {
                                                    HStack {
                                                        Text("\(ordinal + 1).")
                                                        QuickInputAssetName(store: quick.store, reference: reference)
                                                        Spacer()
                                                        Button("上移") { editInput { try quick.moveInputAsset(item.id, by: -1, port: port, draftID: draft.id) } }
                                                            .disabled(ordinal == 0)
                                                        Button("下移") { editInput { try quick.moveInputAsset(item.id, by: 1, port: port, draftID: draft.id) } }
                                                            .disabled(ordinal == items.count - 1)
                                                        Button("移除") { editInput { try quick.removeInputAsset(item.id, port: port, draftID: draft.id) } }
                                                    }
                                                }
                                            }
                                            if items.isEmpty { Text("未绑定输入").foregroundStyle(.secondary) }
                                        case .invalid(let issue):
                                            Text("已保存的输入无效：" + issue).foregroundStyle(.red).textSelection(.enabled)
                                            Button("清空整个输入") {
                                                editInput {
                                                    try quick.clearInputAssetList(port: port, draftID: draft.id,
                                                                                  expectedNode: draft.node, expectedInputs: draft.inputs)
                                                }
                                            }
                                        }
                                    } else {
                                        HStack {
                                            Text(draft.inputs[port.id] == nil ? "未绑定输入" : "已保存输入快照").foregroundStyle(.secondary)
                                            Spacer()
                                            if draft.inputs[port.id] != nil {
                                                Button(baselineText(language, "label.6135d4159e89", fallback: "移除")) { quick.setInput(port.id, value: nil, draftID: draft.id) }
                                            }
                                        }
                                    }
                                    Button(baselineText(language, "label.1b9818e1adfe", fallback: "导入…")) { Task { await importInput(port: port, draft: draft) } }
                                }
                            }
                            DisclosureGroup(baselineText(language, "label.44455611b910", fallback: "高级设置"), isExpanded: $advanced) {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(definition.fields.filter { !["modelID", "task", "promptText", "count"].contains($0.id) }) { field in
                                        QuickParameterField(operationID: draft.node.operationID, field: field, value: draft.node.parameters[field.id] ?? field.defaultValue,
                                            onChange: { quick.setParameter(field.id, value: $0, draftID: draft.id) }, raw: draft.fieldText[field.id], onRaw: { quick.setFieldText(field.id, text: $0, draftID: draft.id) })
                                    }
                                    if WorkflowModelRoutes.isLanguage(draft.node.operationID),
                                       definition.fields.contains(where: { $0.id == "outputMode" }),
                                       draft.node.parameters["outputMode"]?.string == "json" {
                                        WorkflowNodeDataEditor(node: Binding(get: { draft.node }, set: {
                                            quick.setDataConfiguration($0.dataConfiguration, draftID: draft.id)
                                        }))
                                    }
                                }.padding(.top, 12)
                            }
                            Stepper("独立尝试：\(draft.attempts) 次", value: Binding(get: { draft.attempts },
                                set: { quick.setAttempts($0, draftID: draft.id) }), in: 1...8)
                            Text(baselineText(language, "label.3238f75ca285", fallback: "每次单独排队、保存；有种子的模型按次递增，不与模型内部批量相乘。"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let issue = inputIssue ?? quick.inputIssue ?? quick.saveIssue ?? quick.error { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
                        } else {
                            if let error = quick.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                            ContentUnavailableView(baselineText(language, "label.48ccfc0d2104", fallback: "从一个模型开始"), systemImage: "square.stack.3d.up",
                                description: Text(baselineText(language, "label.6f33836bdd1a", fallback: "选择模型后，这里只显示它支持的输入和设置。")))
                            Button(baselineText(language, "label.72f5f0e15b59", fallback: "浏览模型"), action: onChooseModel)
                        }
                    }.padding(22)
                }.frame(minWidth: 280, idealWidth: 410, maxWidth: 520)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        HStack { Text(baselineText(language, "label.a78c1924def7", fallback: "生成结果")).font(.headline); Spacer(); Text(baselineText(language, "label.f2db3712a685", fallback: "自动保存")).font(.caption).foregroundStyle(.secondary) }
                        if quick.visibleRuns.isEmpty {
                            ContentUnavailableView(baselineText(language, "label.45cfbda520a0", fallback: "结果会保存在这里"), systemImage: "photo.on.rectangle.angled",
                                description: Text(baselineText(language, "label.2187866b8a29", fallback: "无需先命名项目。切换模型不会丢失已有创作。")))
                                .frame(minHeight: 300)
                        }
                        if quick.isRunning && !quick.visibleStreamingText.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(baselineText(language, "generation.preview.pending", fallback: "正在生成 · 临时预览")).font(.caption).foregroundStyle(.secondary)
                                Text(quick.visibleStreamingText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.accessibilityIdentifier("quick-streaming-text")
                        }
                        ForEach(currentRuns) { run in runCard(run) }
                        if !pastRuns.isEmpty {
                            DisclosureGroup(baselineText(language, "label.dda5a8cd017c", fallback: "以前的创作"), isExpanded: $history) {
                                ForEach(pastRuns) { run in runCard(run) }
                            }
                        }
                    }.padding(22)
                }.frame(minWidth: 310).background(.quaternary.opacity(0.2))
            }
            Divider()
            HStack {
                Text(quick.isRunning ? quick.phase : "输入与结果保存到快速创作记录").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if quick.isRunning {
                    ProgressView().controlSize(.small)
                    Button(baselineText(language, "label.ea6aa5fbc2d9", fallback: "取消生成")) { Task { await quick.cancel() } }
                } else if quick.pendingSaveRunID != nil || quick.saveIssue != nil {
                    Button(baselineText(language, "label.fb412bfea70f", fallback: "重试保存（不重新生成）")) { Task { await quick.retrySave() } }
                } else {
                    Button(baselineText(language, "label.1ad1463fe16f", fallback: "生成")) { quick.start() }.buttonStyle(.glassProminent)
                        .disabled(!quick.canStart)
                        .accessibilityIdentifier("quick-generate")
                }
            }.padding(16)
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let reference = preview { VStack {
                HStack { Button(baselineText(language, "label.572cf45ba436", fallback: "返回")) { preview = nil }.keyboardShortcut(.cancelAction); Spacer() }
                QuickAssetPreview(store: quick.store, reference: reference, compact: false)
            }.padding(20).frame(minWidth: 560, minHeight: 360) }
        }
        .onChange(of: quick.state.selectedDraftID) { _, _ in inputIssue = nil; history = false }
    }
    private var currentRuns: [QuickRunRecord] {
        guard let latest = quick.visibleRuns.first else { return [] }
        return quick.visibleRuns.filter { ($0.batchID ?? $0.id) == (latest.batchID ?? latest.id) }
    }
    private var pastRuns: [QuickRunRecord] {
        let current = Set(currentRuns.map(\.id)); return quick.visibleRuns.filter { !current.contains($0.id) }
    }
    private enum AssetListPresentation {
        case valid([WorkflowDataItem])
        case invalid(String)
    }
    private func assetListPresentation(port: WorkflowPortDefinition, draftID: String) -> AssetListPresentation {
        do { return .valid(try quick.inputAssetItems(port: port, draftID: draftID)) }
        catch { return .invalid(error.localizedDescription) }
    }
    private func runCard(_ run: QuickRunRecord) -> some View {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(run.createdAt, style: .time); Spacer(); Text(statusTitle(run.status)).font(.caption) }
                                if let index = run.attemptIndex { Text("独立尝试 \(index)").font(.caption).foregroundStyle(.secondary) }
                                ForEach(Array(run.outputs.keys.sorted()), id: \.self) { key in
                                    if let text = run.outputs[key]?.datum?.text {
                                        Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    } else if let value = run.outputs[key]?.datum, run.outputs[key]?.asset == nil {
                                        WorkflowDatumSnapshotView(value: value)
                                        Button(baselineText(language, "result.toCanvas", fallback: "带结果到工作流")) { onValueToCanvas(value) }
                                    }
                                }
                                ForEach(references(run), id: \.assetID) { reference in
                                    VStack(alignment: .leading) {
                                        QuickAssetPreview(store: quick.store, reference: reference, compact: true)
                                        HStack {
                                            Button(baselineText(language, "label.db8db0530432", fallback: "查看")) { preview = reference }
                                            Button(baselineText(language, "label.1c66265feb9f", fallback: "带结果到工作流")) { onResultToCanvas(reference) }
                                            Button(baselineText(language, "label.643e7408e6a7", fallback: "导出…")) { Task { await export(reference) } }
                                        }
                                    }
                                }
                                if let issue = run.issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                                if [.failed, .cancelled, .interrupted, .partial].contains(run.status) {
                                    Button(baselineText(language, "retry.generate", fallback: "按本次输入重新生成")) { quick.retryAttempt(run.id) }
                                        .disabled(quick.isRunning || quick.pendingSaveRunID != nil || quick.saveIssue != nil)
                                }
                                if run.retryOf != nil { Text(baselineText(language, "retry.record", fallback: "这是一次重新生成，原记录仍保留。")).font(.caption).foregroundStyle(.secondary) }
                                DisclosureGroup(baselineText(language, "label.b27824d6e4d6", fallback: "本次输入与参数")) {
                                    Text(String(data: (try? JSONEncoder().encode(run.draft)) ?? Data(), encoding: .utf8) ?? "")
                                        .font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
    private func statusTitle(_ status: QuickRunRecord.Status) -> String {
        let fallback: String = switch status {
        case .running: "运行中"; case .completed: "已完成"; case .partial: "部分完成"
        case .cancelled: "已取消"; case .failed: "失败"; case .interrupted: "已中断"
        }
        return workflowText(language, "baseline02.quick.status." + status.rawValue, fallback: fallback)
    }
    private func readinessTitle(_ id: String) -> String {
        switch model.projectSession.explicitModelReadiness[id] ?? .unknown {
        case .available: baselineText(language, "readiness.ready", fallback: "文件已核验 · 运行时检查参数")
        case .unprepared: baselineText(language, "readiness.unprepared", fallback: "需要准备模型文件")
        case .unavailable: baselineText(language, "readiness.unavailable", fallback: "文件或授权暂不可用")
        case .unsupported: baselineText(language, "readiness.unsupported", fallback: "当前入口未适配")
        case .unknown: baselineText(language, "readiness.unknown", fallback: "准备状态待核验")
        }
    }
    private func references(_ run: QuickRunRecord) -> [WorkflowAssetReference] {
        var refs: [WorkflowAssetReference] = []
        for value in run.outputs.values {
            if let ref = value.asset, !refs.contains(ref) { refs.append(ref) }
            for ref in value.candidates.compactMap(\.asset) where !refs.contains(ref) { refs.append(ref) }
        }
        for ref in run.candidates.compactMap(\.asset) where !refs.contains(ref) { refs.append(ref) }
        return refs
    }
    private func importInput(port: WorkflowPortDefinition, draft: QuickDraft) async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowsMultipleSelection = port.assetListKind != nil
        guard await panel.begin() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        do {
            var imported: [WorkflowAssetReference] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let published = try await quick.store.importWorkflowMediaFile(at: url)
                    imported.append(published.record.reference)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
            }
            try quick.commitImportedAssets(imported, port: port, draftID: draft.id,
                                           expectedNode: draft.node, expectedInputs: draft.inputs)
            inputIssue = nil
        } catch {
            if quick.draft?.id == draft.id { inputIssue = error.localizedDescription }
        }
    }
    private func editInput(_ action: () throws -> Void) {
        do { try action(); inputIssue = nil }
        catch { inputIssue = error.localizedDescription }
    }
    private func export(_ reference: WorkflowAssetReference) async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { _ = try await quick.store.exportWorkflowAssets([reference], name: "D-" + UUID().uuidString.prefix(8), exportID: UUID(), directory: url) }
        catch { inputIssue = error.localizedDescription }
    }
}

private struct QuickInputAssetName: View {
    let store: ProjectStore
    let reference: WorkflowAssetReference
    @State private var name: String?
    var body: some View {
        Text(name ?? reference.assetID.uuidString)
            .lineLimit(1)
            .help(reference.assetID.uuidString + " · " + reference.version.uuidString)
            .task(id: reference) {
                let manifest = await store.snapshot()
                name = manifest.id == reference.projectID
                    ? manifest.assets.first(where: { $0.id == reference.assetID })?.name
                    : nil
            }
    }
}

private struct QuickParameterField: View {
    let operationID: String
    let field: WorkflowFieldDefinition
    let value: WorkflowScalar
    let onChange: (WorkflowScalar) -> Void
    let raw: String?
    let onRaw: (String) -> Void
    @Environment(\.dLanguageStore) private var language
    private var title: String { WorkflowCanvasPresentation.fieldTitle(operationID: operationID, field: field, language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            switch field.kind {
            case .text(let multiline):
                if multiline { TextEditor(text: stringBinding).frame(minHeight: 130).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 9)) }
                else { TextField(title, text: stringBinding).textFieldStyle(.roundedBorder) }
            case .choice(let options):
                Picker(title, selection: stringBinding) { ForEach(options, id: \.self) { Text(WorkflowCanvasPresentation.choiceTitle(fieldID: field.id, value: $0, language: language)).tag($0) } }.labelsHidden()
            case .flag: Toggle(title, isOn: Binding(get: { if case .flag(let b) = value { b } else { false } }, set: { onChange(.flag($0)) })).labelsHidden()
            case .integer, .decimal:
                TextField(title, text: Binding(get: { raw ?? numberString }, set: { onRaw($0) })).textFieldStyle(.roundedBorder)
            }
        }
    }
    private var stringBinding: Binding<String> { .init(get: { value.string ?? "" }, set: { onChange(.text($0)) }) }
    private var numberString: String { switch value { case .integer(let n): String(n); case .decimal(let n): String(n); default: "" } }
}

struct QuickAssetPreview: View {
    @Environment(\.dLanguageStore) private var language
    let store: ProjectStore
    let reference: WorkflowAssetReference
    let compact: Bool
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var text: String?
    @State private var issue: String?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: compact ? 260 : 550) }
            else if let player { VideoPlayer(player: player).frame(height: reference.kind == .audio ? 90 : (compact ? 240 : 400)) }
            else if let text { Text(text).textSelection(.enabled).lineLimit(compact ? 8 : nil) }
            else if let issue { Text(issue).foregroundStyle(.red) }
            else { ProgressView(baselineText(language, "label.0dee08a39132", fallback: "正在读取素材…")) }
        }
        .task(id: reference) {
            player?.pause(); player = nil; image = nil; text = nil; issue = nil
            do {
                if [.audio, .video].contains(reference.kind) {
                    let (url, _) = try await store.workflowMedia(reference); player = AVPlayer(url: url)
                } else {
                    let data = try await store.workflowData(reference)
                    if reference.kind == .image { image = NSImage(data: data) }
                    else if reference.kind == .text { text = try await store.workflowText(reference) }
                    else { text = String(data: data, encoding: .utf8) ?? "此素材不支持文本预览" }
                }
            } catch { issue = error.localizedDescription }
        }
        .onDisappear { player?.pause() }
    }
}
