import AppKit
import AVKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

@MainActor func baselineText(_ language: UILanguageStore?, _ key: String, fallback: String) -> String {
    workflowText(language, "baseline02.ui." + key, fallback: fallback)
}

struct QuickGenerationView: View {
    private struct InputAction {
        let ticket: UUID
        var feedbackValid = true
    }

    @Bindable var quick: QuickGenerationController
    let model: WorkbenchModel
    @Binding var selectedResults: [QuickCategory: WorkflowAssetReference]
    let onChooseModel: () -> Void
    let onSettingsToCanvas: (QuickDraft) -> Void
    let onResultToCanvas: (WorkflowAssetReference) -> Void
    let onValueToCanvas: (WorkflowDatum) -> Void
    var onOpenLibrary: () -> Void = {}
    var onAssetsChanged: () -> Void = {}
    var onResolveSharedAsset: QuickInputImport.SharedAssetResolver? = nil
    @State private var narrowRight = false
    @State private var leftRequested = true
    @State private var rightRequested = true
    @State private var detailRun: QuickRunRecord?
    @State private var pendingPreview: WorkflowAssetReference?
    @State private var advanced = false
    @State private var history = false
    @State private var inputIssue: String?
    @State private var inputNotice: String?
    @State private var inputAction: InputAction?
    @State private var preview: WorkflowAssetReference?
    @Environment(\.dLanguageStore) private var language
    private func inputLabel(_ key: String, english: String, chinese: String) -> String {
        workflowText(language, "quick.input." + key,
                     fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english)
    }
    private func refinementText(_ key: String, fallback: String) -> String {
        workflowText(language, "refinement.quick." + key, fallback: fallback)
    }
    private var definition: WorkflowOperationDefinition? { quick.definition }
    private var title: String {
        let id = quick.draft?.node.parameters["modelID"]?.string ?? ""
        return model.projectSession.explicitModelChoices.first { $0.id == id }?.displayName
            ?? ModelNodeCatalog.entries.first { descriptor in WorkflowModelKind.allCases.contains { id == $0.rawValue + ":" + descriptor.revision } }?.title
            ?? (id.isEmpty ? "选择一个模型" : "指定模型未准备")
    }
    var body: some View {
        GeometryReader { geometry in
            let leftShown = leftRequested && geometry.size.width >= 790 && (geometry.size.width >= 1110 || !narrowRight)
            let rightShown = rightRequested && geometry.size.width >= (leftShown ? 1110 : 700)
            HStack(alignment: .top, spacing: 12) {
                if leftShown {
                    VStack(spacing: 0) {
                        HStack { Text(refinementText("settings", fallback: "生成设置")).font(.headline); Spacer(); panelButton(refinementText("collapseSettings", fallback: "收起生成设置"), "sidebar.left") { leftRequested = false } }.padding(12)
                        modelHeader
                        Divider()
                        parameterPanel
                    }.frame(width: 280).workbenchPanel(cornerRadius: 18).transition(.identity)
                }
                VStack(spacing: 10) {
                    HStack {
                        if !leftShown { panelButton(refinementText("expandSettings", fallback: "展开生成设置"), "slider.horizontal.3") { leftRequested = true; narrowRight = false } }
                        Text(title).font(.headline).lineLimit(1)
                        Spacer()
                        if let result = selectedMedia, let run = run(containing: result) {
                            Button(refinementText("resultDetails", fallback: "结果详情"), systemImage: "info.circle") { detailRun = run }
                        }
                        if !rightShown { panelButton(refinementText("expandAssets", fallback: "展开素材与结果"), "square.grid.2x2") { rightRequested = true; narrowRight = true } }
                    }
                    if quick.category == .image || quick.category == .video {
                        mediaStage
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                if !quick.visibleStreamingText.isEmpty { Text(quick.visibleStreamingText).textSelection(.enabled) }
                                ForEach(currentRuns) { run in runCard(run) }
                                if !pastRuns.isEmpty { DisclosureGroup(refinementText("pastCreations", fallback: "以前的创作"), isExpanded: $history) { ForEach(pastRuns) { run in runCard(run) } } }
                                if quick.visibleRuns.isEmpty { ContentUnavailableView(refinementText("startCreation", fallback: "开始一份创作"), systemImage: "sparkles", description: Text(refinementText("startCreationHelp", fallback: "输入任务后生成；结果会自动保存。"))) }
                            }.padding(12)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let definition, let draft = quick.draft {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(definition.fields.filter { ["task", "promptText"].contains($0.id) }) { field in
                                QuickParameterField(ownerID: draft.id, operationID: draft.node.operationID, field: field, value: draft.node.parameters[field.id] ?? field.defaultValue,
                                    onChange: { quick.setParameter(field.id, value: $0, draftID: draft.id) }, raw: draft.fieldText[field.id], onRaw: { quick.setFieldText(field.id, text: $0, draftID: draft.id) })
                            }
                        }.frame(maxHeight: min(180, geometry.size.height * 0.28))
                    }
                    if let issue = inputIssue ?? quick.inputIssue ?? quick.saveIssue ?? quick.error {
                        Text(issue).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                    }
                    generationBar
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if rightShown {
                    VStack(spacing: 0) {
                        HStack { Text(refinementText("assetsAndResults", fallback: "素材与结果")).font(.headline); Spacer(); panelButton(refinementText("collapseAssets", fallback: "收起素材与结果"), "sidebar.right") { rightRequested = false } }.padding(12)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                Button(refinementText("openLibrary", fallback: "全部资料库…"), action: onOpenLibrary)
                                if !inputReferences.isEmpty {
                                    Text(refinementText("currentInputs", fallback: "当前输入")).font(.caption.bold())
                                    ForEach(inputReferences, id: \.self) { reference in
                                        Button { preview = reference } label: {
                                            QuickInputAssetName(store: quick.store, reference: reference)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }.buttonStyle(.bordered)
                                    }
                                    Divider()
                                }
                                Text(refinementText("resultsAndCandidates", fallback: "结果与候选")).font(.caption.bold())
                                ForEach(mediaReferences, id: \.self) { reference in
                                    Button { selectedResults[quick.category] = reference } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            if reference.kind == .image { QuickAssetPreview(store: quick.store, reference: reference, compact: true).frame(height: 100) }
                                            QuickInputAssetName(store: quick.store, reference: reference)
                                            Text(WorkflowCanvasPresentation.kind(reference.kind, language: language)).font(.caption).foregroundStyle(.secondary)
                                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(selectedMedia == reference ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                }
                                if mediaReferences.isEmpty { Text(refinementText("noResults", fallback: "尚无结果")).foregroundStyle(.secondary).padding() }
                                ForEach(quick.visibleRuns) { run in
                                    Button { detailRun = run } label: { HStack { Text(run.createdAt, style: .time); Text(statusTitle(run.status)); Spacer(); Image(systemName: "info.circle") } }
                                }
                            }.padding(10)
                        }
                    }.frame(width: 220).workbenchPanel(cornerRadius: 18).transition(.identity)
                }
            }.padding(14)
                .workbenchMotion(value: leftShown).workbenchMotion(value: rightShown)
        }
        .sheet(item: $detailRun, onDismiss: {
            if let pendingPreview { preview = pendingPreview; self.pendingPreview = nil }
        }) { run in
            VStack { HStack { Text(refinementText("resultDetails", fallback: "结果详情")).font(.headline); Spacer(); Button(refinementText("done", fallback: "完成")) { detailRun = nil }.keyboardShortcut(.cancelAction) }; ScrollView { runCard(run) } }
                .padding(20).frame(minWidth: 580, minHeight: 420)
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let reference = preview { VStack {
                HStack { Button(baselineText(language, "label.572cf45ba436", fallback: "返回")) { preview = nil }.keyboardShortcut(.cancelAction); Spacer() }
                QuickAssetPreview(store: quick.store, reference: reference, compact: false)
            }.padding(20).frame(minWidth: 560, minHeight: 360) }
        }
        .onChange(of: quick.state.selectedDraftID) { _, _ in
            inputAction?.feedbackValid = false
            inputIssue = nil; inputNotice = nil; history = false
        }
        .onChange(of: ObjectIdentifier(quick)) { _, _ in
            inputAction?.feedbackValid = false
            inputIssue = nil; inputNotice = nil
        }
        .onDisappear { inputAction?.feedbackValid = false }
    }
    private func panelButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 30, height: 30) }
            .buttonStyle(.bordered).buttonBorderShape(.circle).help(title).accessibilityLabel(title)
    }
    private var modelHeader: some View {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.bold())
                    Text(definition.map { WorkflowCanvasPresentation.operationTitle($0, language: language) } ?? "从资料库选择已适配模型").font(.caption).foregroundStyle(.secondary)
                    if let id = quick.draft?.node.parameters["modelID"]?.string, !id.isEmpty {
                        Text((ModelNodeCatalog.entries.first { descriptor in WorkflowModelKind.allCases.contains { id == $0.rawValue + ":" + descriptor.revision } }?.precision ?? "") + " · " + readinessTitle(id))
                            .font(.caption).foregroundStyle(.secondary).help(id)
                    }
                }
                Button(baselineText(language, "label.48ff0f9d0b4d", fallback: "更换模型"), action: onChooseModel)
                if let draft = quick.draft {
                    Button(baselineText(language, "label.7d9795fa3684", fallback: "带设置到工作流")) { onSettingsToCanvas(draft) }
                }
            }.padding(20)
    }
    private var parameterPanel: some View {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(baselineText(language, "label.39a07dc80743", fallback: "创作输入")).font(.headline)
                        if let definition, let draft = quick.draft {
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
                                    HStack {
                                        Button(baselineText(language, "label.1b9818e1adfe", fallback: "导入…")) {
                                            _ = startInputAction { ticket in await importInput(port: port, draft: draft, ticket: ticket) }
                                        }
                                        Button(inputLabel("paste", english: "Paste", chinese: "粘贴")) {
                                            _ = startInputAction { ticket in await pasteInput(port: port, draft: draft, ticket: ticket) }
                                        }
                                        .disabled(inputAction != nil)
                                    }
                                    .disabled(inputAction != nil)
                                    HStack(spacing: 8) {
                                        Text(inputLabel("dropFiles", english: "Drop Finder files", chinese: "拖入 Finder 文件"))
                                            .frame(maxWidth: .infinity, minHeight: 34)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                            .dropDestination(for: URL.self) { urls, _ in
                                                guard !urls.isEmpty else { return false }
                                                return startInputAction { ticket in
                                                    await applyInput(urls.map(QuickInputImport.Item.file), port: port, draft: draft, ticket: ticket)
                                                }
                                            }
                                        Text(inputLabel("dropAssets", english: "Drop library assets", chinese: "拖入资料库素材"))
                                            .frame(maxWidth: .infinity, minHeight: 34)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                            .dropDestination(for: WorkflowCanvasTransfer.self) { items, _ in
                                                guard !items.isEmpty else { return false }
                                                return startInputAction { ticket in
                                                    await applyInput(items.map(QuickInputImport.Item.managed), port: port, draft: draft, ticket: ticket)
                                                }
                                            }
                                    }.font(.caption).foregroundStyle(.secondary).disabled(inputAction != nil)
                                }
                            }
                            DisclosureGroup(baselineText(language, "label.44455611b910", fallback: "高级设置"), isExpanded: $advanced) {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(definition.fields.filter { !["modelID", "task", "promptText", "count"].contains($0.id) }) { field in
                                        QuickParameterField(ownerID: draft.id, operationID: draft.node.operationID, field: field, value: draft.node.parameters[field.id] ?? field.defaultValue,
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
                            if let inputNotice { Text(inputNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        } else {
                            if let error = quick.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                            ContentUnavailableView(baselineText(language, "label.48ccfc0d2104", fallback: "从一个模型开始"), systemImage: "square.stack.3d.up",
                                description: Text(baselineText(language, "label.6f33836bdd1a", fallback: "选择模型后，这里只显示它支持的输入和设置。")))
                            Button(baselineText(language, "label.72f5f0e15b59", fallback: "浏览模型"), action: onChooseModel)
                        }
                    }.padding(22)
                }
    }
    private var generationBar: some View {
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
    private var inputReferences: [WorkflowAssetReference] {
        var result: [WorkflowAssetReference] = []
        for key in (quick.draft?.inputs.keys.sorted() ?? []) {
            for ref in quick.draft?.inputs[key]?.datum?.assetReferences ?? [] where !result.contains(ref) { result.append(ref) }
        }
        return result
    }
    private var mediaReferences: [WorkflowAssetReference] {
        var result: [WorkflowAssetReference] = []
        for run in quick.visibleRuns {
            for reference in references(run) where !result.contains(reference) { result.append(reference) }
        }
        return result
    }
    private var selectedMedia: WorkflowAssetReference? {
        if let selected = selectedResults[quick.category], mediaReferences.contains(selected) { return selected }
        return mediaReferences.first
    }
    private func run(containing reference: WorkflowAssetReference) -> QuickRunRecord? {
        quick.visibleRuns.first { references($0).contains(reference) }
    }
    private func stepCandidate(_ delta: Int) {
        guard let selectedMedia, let index = mediaReferences.firstIndex(of: selectedMedia) else { return }
        let next = index + delta
        if mediaReferences.indices.contains(next) { selectedResults[quick.category] = mediaReferences[next] }
    }
    private var mediaStage: some View {
        VStack(spacing: 8) {
            HStack {
                Text(refinementText("currentResultHelp", fallback: "当前结果 · 与下次生成设置独立")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(refinementText("previousResult", fallback: "上一项"), systemImage: "chevron.left") { stepCandidate(-1) }.labelStyle(.iconOnly).disabled(selectedMedia == mediaReferences.first)
                Text("\(selectedMedia.flatMap { mediaReferences.firstIndex(of: $0) }.map { $0 + 1 } ?? 0) / \(mediaReferences.count)").monospacedDigit()
                Button(refinementText("nextResult", fallback: "下一项"), systemImage: "chevron.right") { stepCandidate(1) }.labelStyle(.iconOnly).disabled(selectedMedia == mediaReferences.last)
            }
            if let reference = selectedMedia {
                QuickMediaViewport(store: quick.store, reference: reference)
                    .id(reference).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button(baselineText(language, "label.1c66265feb9f", fallback: "带结果到工作流"), systemImage: "square.stack.3d.up") { onResultToCanvas(reference) }
                    Spacer()
                    Button(baselineText(language, "label.643e7408e6a7", fallback: "导出…"), systemImage: "square.and.arrow.up") { Task { await export(reference) } }
                }
            } else {
                ContentUnavailableView(refinementText("preview", fallback: "预览"), systemImage: quick.category == .image ? "photo" : "video", description: Text(refinementText("previewHelp", fallback: "生成后在这里查看；素材与结果保留在右侧。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.accessibilityIdentifier("quick-fixed-preview")
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
                                            Button(baselineText(language, "label.db8db0530432", fallback: "查看")) {
                                                if detailRun != nil { pendingPreview = reference; detailRun = nil }
                                                else { preview = reference }
                                            }
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
        for key in run.outputs.keys.sorted() {
            guard let value = run.outputs[key] else { continue }
            if let ref = value.asset, !refs.contains(ref) { refs.append(ref) }
            for ref in value.candidates.compactMap(\.asset) where !refs.contains(ref) { refs.append(ref) }
        }
        for ref in run.candidates.compactMap(\.asset) where !refs.contains(ref) { refs.append(ref) }
        return refs
    }
    private func startInputAction(_ action: @escaping (UUID) async -> Void) -> Bool {
        guard inputAction == nil else { return false }
        let ticket = UUID()
        inputAction = InputAction(ticket: ticket)
        Task {
            await action(ticket)
            if inputAction?.ticket == ticket { inputAction = nil }
        }
        return true
    }
    private func canShowInputFeedback(_ ticket: UUID, draft: QuickDraft,
                                      controller: QuickGenerationController, store: ProjectStore) -> Bool {
        inputAction?.ticket == ticket && inputAction?.feedbackValid == true &&
            quick === controller && quick.store === store && quick.draft?.id == draft.id
    }
    private func importInput(port: WorkflowPortDefinition, draft: QuickDraft, ticket: UUID) async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard await panel.begin() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        await applyInput(urls.map(QuickInputImport.Item.file), port: port, draft: draft, ticket: ticket)
    }
    private func pasteInput(port: WorkflowPortDefinition, draft: QuickDraft, ticket: UUID) async {
        let controller = quick, store = quick.store
        do {
            await applyInput(try QuickInputImport.clipboardItems(), port: port, draft: draft, ticket: ticket)
        } catch {
            if canShowInputFeedback(ticket, draft: draft, controller: controller, store: store) {
                inputIssue = error.localizedDescription
            }
        }
    }
    private func applyInput(_ items: [QuickInputImport.Item], port: WorkflowPortDefinition,
                            draft: QuickDraft, ticket: UUID) async {
        let controller = quick, store = quick.store
        let result = await QuickInputImport.run(items, quick: controller, draft: draft, port: port,
                                                resolveSharedAsset: onResolveSharedAsset)
        if result.published > 0 { onAssetsChanged() }
        guard canShowInputFeedback(ticket, draft: draft, controller: controller, store: store) else { return }
        inputIssue = result.cancelled
            ? inputLabel("cancelled", english: "Import cancelled. Already saved assets remain in the library; the current input was not changed.",
                         chinese: "导入已取消；已保存的素材仍在资料库，当前输入未修改。")
            : result.message
        inputNotice = result.copied > 0
            ? inputLabel("copied", english: "Assets from another project were copied into this project; the originals are unchanged.",
                         chinese: "跨项目素材已复制到当前项目；来源原件保持不变。")
            : nil
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

struct QuickParameterField: View {
    let ownerID: String
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
                if multiline {
                    // Reuse the existing composition-safe editor: a save revision
                    // must not write the last committed value over marked text.
                    TextSourcesQuestionEditor(value: value.string ?? "", editEpoch: 0, isEditable: true,
                        accessibilityIdentifier: "quick-field-" + field.id,
                        onEdit: { onChange(.text($0)) })
                        .id([ownerID, field.id])
                        .frame(minHeight: 130).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                }
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
                    else if reference.kind == .document { text = "原始文档已保留；可加入聊天后读取文字。 / Original document preserved; add it to chat to read its text." }
                    else { text = String(data: data, encoding: .utf8) ?? "此素材不支持文本预览" }
                }
            } catch { issue = error.localizedDescription }
        }
        .onDisappear { player?.pause() }
    }
}
