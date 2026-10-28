import AppKit
import AVKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

@MainActor func baselineText(_ language: UILanguageStore?, _ key: String, fallback: String = "") -> String {
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
    var onImportAsset: () -> Void = {}
    var importTargetTitle: String = ""
    var onAssetsChanged: () -> Void = {}
    var onResolveSharedAsset: QuickInputImport.SharedAssetResolver? = nil
    var textWorkspaceActions: AnyView = AnyView(EmptyView())
    @Environment(\.workbenchSidebars) private var sharedSidebars
    @Environment(\.workbenchModeSize) private var modeSize
    @State private var localSidebars = WorkbenchSidebarState()
    private var sidebars: WorkbenchSidebarState { sharedSidebars ?? localSidebars }
    private enum LeftTab: String, CaseIterable { case settings, assets }
    private enum RightTab: String, CaseIterable { case results, history }
    @State private var leftTab: LeftTab = .settings
    @State private var rightTab: RightTab = .results
    @State private var detailRun: QuickRunRecord?
    @State private var pendingPreview: WorkflowAssetReference?
    @State private var advanced = false
    @State private var audioPlayback = QuickAudioPlayback()
    @State private var savingAudio = false
    @State private var history = false
    @State private var commandScope = WorkbenchCommandScope()
    @Environment(\.workbenchContentVisible) private var contentVisible
    @State private var inputIssue: String?
    @State private var inputIssueCode: String?
    @State private var inputNotice: String?
    @State private var inputAction: InputAction?
    @State private var preview: WorkflowAssetReference?
    @Environment(\.dLanguageStore) private var language
    private func inputLabel(_ key: String, english: String, chinese: String) -> String {
        workflowText(language, "quick.input." + key,
                     fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english)
    }
    private func refinementText(_ key: String, fallback: String = "") -> String {
        workflowText(language, "refinement.quick." + key, fallback: fallback)
    }
    private var definition: WorkflowOperationDefinition? { quick.definition }
    private var title: String {
        let id = quick.draft?.node.parameters["modelID"]?.string ?? ""
        return model.projectSession.explicitModelChoices.first { $0.id == id }?.displayName
            ?? ModelNodeCatalog.entries.first { descriptor in WorkflowModelKind.allCases.contains { id == $0.rawValue + ":" + descriptor.revision } }?.title
            ?? (id.isEmpty ? refinementText("chooseModel", fallback: "选择一个模型") : refinementText("modelNotReady", fallback: "指定模型未准备"))
    }
    @Environment(\.workbenchQuickContentTop) private var quickContentTop
    var body: some View {
        GeometryReader { geometry in
            let shown = WorkbenchSidebarLayout.visible(available: geometry.size.width, leading: sidebars.leading, trailing: sidebars.trailing)
            let leftShown = shown.leading
            let rightShown = shown.trailing
            ZStack(alignment: .topLeading) {
                VStack(spacing: 10) {
                    HStack {
                        Text(quick.category == .text ? workflowText(language, "quick.textWorkspace.singleTitle") : title).font(.headline).lineLimit(1)
                        Spacer()
                        if quick.category == .text { textWorkspaceActions }
                        if let result = selectedMedia, let run = run(containing: result) {
                            Button(refinementText("resultDetails", fallback: "结果详情"), systemImage: "info.circle") { detailRun = run }
                        }
                    }
                    if quick.category == .audio {
                        audioStage
                    } else if quick.category == .image || quick.category == .video {
                        mediaStage
                    } else {
                        WorkbenchScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                if !quick.visibleStreamingText.isEmpty { Text(quick.visibleStreamingText).textSelection(.enabled) }
                                ForEach(currentRuns) { run in runCard(run) }
                                if !pastRuns.isEmpty { DisclosureGroup(refinementText("pastCreations", fallback: "以前的创作"), isExpanded: $history) { ForEach(pastRuns) { run in runCard(run) } } }
                                if quick.visibleRuns.isEmpty { ContentUnavailableView(refinementText("startCreation", fallback: "开始一份创作"), systemImage: "sparkles", description: Text(refinementText("startCreationHelp", fallback: "输入任务后生成；结果会自动保存。"))) }
                            }.padding(12)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                    if quick.category == .audio {
                        let compactAudio = geometry.size.height < 720
                        let lyrics = quick.draft?.node.parameters["vocal"]?.string == "lyrics" && !quick.audioRequiresWorkflow
                        WorkbenchScrollView {
                            QuickAudioInput(quick: quick, continueInWorkflow: onSettingsToCanvas, compact: compactAudio)
                        }.frame(height: quick.audioRequiresWorkflow ? 94 : lyrics ? (compactAudio ? 198 : 234) : (compactAudio ? 78 : 94))
                    } else if let definition, let draft = quick.draft,
                       !definition.fields.filter({ ["task", "promptText"].contains($0.id) }).isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(definition.fields.filter { ["task", "promptText"].contains($0.id) }) { field in
                                QuickParameterField(ownerID: draft.id, operationID: draft.node.operationID, modelIdentity: draft.node.parameters["modelID"]?.string, field: field, value: draft.node.parameters[field.id] ?? field.defaultValue,
                                    onChange: { quick.setParameter(field.id, value: $0, draftID: draft.id) }, raw: draft.fieldText[field.id], onRaw: { quick.setFieldText(field.id, text: $0, draftID: draft.id) })
                            }
                        }.frame(maxHeight: min(180, geometry.size.height * 0.28))
                    }
                    if let issue = inputIssue ?? (quick.category == .audio && quick.inputIssueCode == "quick.audio.complex" ? nil : quick.inputIssue) ?? quick.saveIssue ?? quick.error {
                        WorkbenchIssueText(raw: issue, key: inputIssue != nil ? inputIssueCode : (quick.inputIssue == issue ? quick.inputIssueCode : nil)).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                    }
                    generationBar
                    }.padding(12).workbenchPanel(cornerRadius: 16)
                        .workbenchMeasureLayout("quick-input")
                        .padding(.trailing, WorkbenchFloatingLayout.composerTrailingInset(
                            visibleRightPanel: WorkbenchSidebarLayout.occupiedWidth(rightShown, leading: false, available: geometry.size.width),
                            mode: modeSize))
                }.frame(width: max(0, geometry.size.width - 32
                    - WorkbenchSidebarLayout.occupiedWidth(leftShown, leading: true, available: geometry.size.width)
                    - WorkbenchSidebarLayout.occupiedWidth(rightShown, leading: false, available: geometry.size.width)))
                    .workbenchMeasureLayout("quick-center")
                .transaction { $0.animation = nil }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .padding(.top, quickContentTop)
                    .padding(.leading, WorkbenchSidebarLayout.occupiedWidth(leftShown, leading: true, available: geometry.size.width))
                    .padding(.trailing, WorkbenchSidebarLayout.occupiedWidth(rightShown, leading: false, available: geometry.size.width))
                    .workbenchMorph(value: leftShown).workbenchMorph(value: rightShown)
                WorkbenchSidebar(leading: true, expanded: leftShown,
                    title: quick.category == .audio ? audioText("settings") : consistencyText(language, "tabs." + leftTab.rawValue),
                    identifier: "quick-settings-toggle", hostIdentifier: "quick-settings-host",
                    toggle: { sidebars.leading.toggle() }) {
                        if quick.category == .audio {
                            WorkbenchScrollView { VStack(alignment: .leading, spacing: 16) { modelHeader; QuickAudioSettings(quick: quick) }.padding(.bottom, 16) }
                        } else {
                        VStack(spacing: 0) {
                            WorkbenchSidebarTabs(title: consistencyText(language, "tabs.tools"), selection: $leftTab, choices: [
                                (.settings, consistencyText(language, "tabs.settings")), (.assets, consistencyText(language, "tabs.assets"))], helpPrefix: "TAB-QUICK-LEFT-")
                            WorkbenchSidebarPages(selection: leftTab, choices: LeftTab.allCases, identifier: "quick-left") { tab in
                                if tab == .settings { VStack(spacing: 0) { modelHeader; parameterPanel(assets: false) } }
                                else { VStack(spacing: 0) {
                                    HStack(spacing: 8) {
                                        Button(layoutText(language, "importAsset"), action: onImportAsset).help(importTargetTitle)
                                        Button(layoutText(language, "expandAssets"), action: onOpenLibrary)
                                    }.padding(.horizontal, 12).padding(.vertical, 8)
                                    if !inputReferences.isEmpty {
                                        ScrollView(.horizontal) { HStack {
                                            ForEach(inputReferences, id: \.self) { reference in
                                                Button { preview = reference } label: { QuickInputAssetName(store: quick.store, reference: reference) }
                                            }
                                        }.padding(.horizontal, 12).padding(.vertical, 10) }.frame(maxHeight: 56)
                                    }
                                    parameterPanel(assets: true)
                                } }
                            }
                        }
                    }
                }
                WorkbenchSidebar(leading: false, expanded: rightShown,
                    title: quick.category == .audio ? audioText(rightTab == .results ? "assets" : "history") : consistencyText(language, "tabs." + rightTab.rawValue),
                    identifier: "quick-assets-toggle", hostIdentifier: "quick-assets-host",
                    toggle: { sidebars.trailing.toggle() }) {
                        VStack(spacing: 0) {
                            WorkbenchSidebarTabs(title: consistencyText(language, "tabs.output"), selection: $rightTab, choices: [
                                (.results, quick.category == .audio ? audioText("assets") : consistencyText(language, "tabs.results")), (.history, quick.category == .audio ? audioText("history") : consistencyText(language, "tabs.history"))], helpPrefix: "TAB-QUICK-RIGHT-")
                            WorkbenchSidebarPages(selection: rightTab, choices: RightTab.allCases, identifier: "quick-right") { tab in
                                if tab == .results {
                        WorkbenchScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if quick.category != .audio { Text(refinementText("resultsAndCandidates", fallback: "结果与候选")).font(.caption.bold()) }
                                ForEach(mediaReferences, id: \.self) { reference in
                                    Button { selectedResults[quick.category] = reference } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            if reference.kind == .image { QuickAssetPreview(store: quick.store, reference: reference, compact: true).frame(height: 100) }
                                            if quick.category == .audio { QuickAudioCandidate(store: quick.store, reference: reference, attempt: run(containing: reference)?.attemptIndex) }
                                            else { QuickInputAssetName(store: quick.store, reference: reference)
                                            Text(WorkflowCanvasPresentation.kind(reference.kind, language: language)).font(.caption).foregroundStyle(.secondary) }
                                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(selectedMedia == reference ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                            .contentShape(.interaction, RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                }
                                if mediaReferences.isEmpty {
                                    if quick.category != .audio { ForEach(quick.visibleRuns) { run in runCard(run) } }
                                    if quick.visibleRuns.isEmpty || quick.category == .audio { Text(refinementText("noResults", fallback: "尚无结果")).foregroundStyle(.secondary).padding() }
                                }
                            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 16)
                        }
                                } else {
                                    WorkbenchScrollView { LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(quick.visibleRuns) { run in
                                    Button { detailRun = run } label: { HStack { Text(run.createdAt, style: .time); Text(statusTitle(run.status)); Spacer(); Image(systemName: "info.circle") } }
                                }
                                    }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 16) }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(.horizontal, 16).padding(.bottom, 16)
                .environment(\.workbenchPanelWidths, WorkbenchSidebarLayout.widths(available: geometry.size.width))
        }
        .background(WorkbenchCommandWindow(scope: commandScope))
        .focusedSceneValue(\.workbenchAssetExport, exportMenuCommand)
        .environment(\.workbenchMenuContext, "quick:\(ObjectIdentifier(quick)):\(quick.draft?.id ?? "none")")
        .workbenchSheet(item: $detailRun, title: workflowText(language, "childPanel.name.tasks"), onDismiss: {
            if let pendingPreview { preview = pendingPreview; self.pendingPreview = nil }
        }) { run in
            VStack { HStack { Text(refinementText("resultDetails", fallback: "结果详情")).font(.headline); Spacer(); Button(refinementText("done", fallback: "完成")) { detailRun = nil }.keyboardShortcut(.cancelAction) }; WorkbenchScrollView { runCard(run) } }
                .padding(20).frame(minWidth: 580, minHeight: 420)
        }
        .workbenchSheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }), title: workflowText(language, "childPanel.name.preview")) {
            if let reference = preview { VStack {
                HStack { Button(baselineText(language, "label.572cf45ba436")) { preview = nil }.keyboardShortcut(.cancelAction); Spacer() }
                QuickAssetPreview(store: quick.store, reference: reference, compact: false)
            }.padding(20).frame(minWidth: 560, minHeight: 360) }
        }
        .onChange(of: quick.state.selectedDraftID) { _, _ in
            inputAction?.feedbackValid = false
            inputIssue = nil; inputIssueCode = nil; inputNotice = nil; history = false
        }
        .onChange(of: ObjectIdentifier(quick)) { _, _ in
            inputAction?.feedbackValid = false
            inputIssue = nil; inputIssueCode = nil; inputNotice = nil
        }
        .task(id: audioIdentity) {
            audioPlayback.stop()
            guard contentVisible, quick.category == .audio, detailRun == nil, preview == nil, let reference = selectedMedia else { return }
            // Pin before loading so a new batch cannot replace an existing selection.
            selectedResults[.audio] = reference
            await audioPlayback.select(reference, store: quick.store)
        }
        .onChange(of: selectedResults[.audio]) { _, _ in
            if quick.category == .audio { inputIssue = nil; inputIssueCode = nil; inputNotice = nil }
        }
        .onChange(of: contentVisible) { _, visible in if !visible { audioPlayback.stop() } }
        .onDisappear { inputAction?.feedbackValid = false; audioPlayback.stop() }
    }
    private var modelHeader: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let definition {
                    WorkbenchModelCard(definition: definition, modelID: quick.draft?.node.parameters["modelID"]?.string,
                        choices: model.projectSession.explicitModelChoices,
                        status: readinessTitle(quick.draft?.node.parameters["modelID"]?.string ?? ""), change: onChooseModel, compact: quick.category == .audio)
                    WorkflowModelPreparationView(identity: quick.draft?.node.parameters["modelID"]?.string ?? "",
                        fallbackReady: model.projectSession.explicitModelReadiness[quick.draft?.node.parameters["modelID"]?.string ?? ""] == .available)
                } else { Button(quick.category == .audio ? audioText("chooseModel") : consistencyText(language, "MODEL-CHANGE"), action: onChooseModel) }
                if let draft = quick.draft {
                    if quick.category == .audio {
                        WorkbenchMenu {
                            WorkbenchMenuAction(audioText("continue")) { onSettingsToCanvas(draft) }
                            let previous = quick.state.drafts.filter { $0.id != draft.id && QuickCategory.category(for: $0.node.operationID) == .audio }
                            if !previous.isEmpty {
                                WorkbenchSubmenu(refinementText("pastCreations")) {
                                    WorkbenchMenuForEach(previous) { saved in
                                        WorkbenchMenuAction(saved.node.title) { editInput { try quick.resumeAudioDraft(saved) } }
                                    }
                                }
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.help(audioText("details"))
                            .environment(\.workbenchMenuContext, "quick-audio-history:\(ObjectIdentifier(quick)):\(ObjectIdentifier(quick.store)):\(draft.id)")
                    } else { Button(baselineText(language, "label.7d9795fa3684")) { onSettingsToCanvas(draft) } }
                }
            }.padding(20)
    }
    private func parameterPanel(assets: Bool) -> some View {
                WorkbenchScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                        if let definition, let draft = quick.draft {
                            if assets {
                            if definition.inputs.contains(where: { $0.id == "content" && $0.assetListKind == nil && $0.kinds.contains(.text) }) {
                                Text(baselineText(language, "label.bf8881ad5d3a")).font(.subheadline)
                                TextEditor(text: Binding(get: { draft.inputs["content"]?.datum?.text ?? "" },
                                    set: { quick.setInput("content", value: $0.isEmpty ? nil : .data(.text($0)), draftID: draft.id) }))
                                    .frame(minHeight: 100).padding(6).workbenchInputSurface()
                            }
                            ForEach(definition.inputs.filter { $0.assetListKind != nil || !["task", "prompt", "content"].contains($0.id) }) { port in
                                VStack(alignment: .leading) {
                                    Text(WorkflowCanvasPresentation.portTitle(operationID: draft.node.operationID, port: port, input: true, language: language) +
                                         (port.required ? baselineText(language, "required") : baselineText(language, "optional"))).font(.subheadline)
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
                                                        Button(refinementText("moveUp", fallback: "上移")) { editInput { try quick.moveInputAsset(item.id, by: -1, port: port, draftID: draft.id) } }
                                                            .disabled(ordinal == 0)
                                                        Button(refinementText("moveDown", fallback: "下移")) { editInput { try quick.moveInputAsset(item.id, by: 1, port: port, draftID: draft.id) } }
                                                            .disabled(ordinal == items.count - 1)
                                                        Button(refinementText("removeInput", fallback: "移除")) { editInput { try quick.removeInputAsset(item.id, port: port, draftID: draft.id) } }
                                                    }
                                                }
                                            }
                                            if items.isEmpty { Text(refinementText("unboundInput", fallback: "未绑定输入")).foregroundStyle(.secondary) }
                                        case .invalid(let issue):
                                            Text(refinementText("invalidInput", fallback: "已保存的输入无效：") + issue).foregroundStyle(.red).textSelection(.enabled)
                                            Button(refinementText("clearInput", fallback: "清空整个输入")) {
                                                editInput {
                                                    try quick.clearInputAssetList(port: port, draftID: draft.id,
                                                                                  expectedNode: draft.node, expectedInputs: draft.inputs)
                                                }
                                            }
                                        }
                                    } else {
                                        HStack {
                                            Text(draft.inputs[port.id] == nil ? refinementText("unboundInput", fallback: "未绑定输入") : refinementText("savedInput", fallback: "已保存输入快照")).foregroundStyle(.secondary)
                                            Spacer()
                                            if draft.inputs[port.id] != nil {
                                                Button(baselineText(language, "label.6135d4159e89", fallback: refinementText("removeInput", fallback: "移除"))) { quick.setInput(port.id, value: nil, draftID: draft.id) }
                                            }
                                        }
                                    }
                                    HStack {
                                        Button(baselineText(language, "label.1b9818e1adfe")) {
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
                                            .workbenchInputSurface()
                                            .dropDestination(for: URL.self) { urls, _ in
                                                guard !urls.isEmpty else { return false }
                                                return startInputAction { ticket in
                                                    await applyInput(urls.map(QuickInputImport.Item.file), port: port, draft: draft, ticket: ticket)
                                                }
                                            }
                                        Text(inputLabel("dropAssets", english: "Drop library assets", chinese: "拖入资料库素材"))
                                            .frame(maxWidth: .infinity, minHeight: 34)
                                            .workbenchInputSurface()
                                            .dropDestination(for: WorkflowCanvasTransfer.self) { items, _ in
                                                guard !items.isEmpty else { return false }
                                                return startInputAction { ticket in
                                                    await applyInput(items.map(QuickInputImport.Item.managed), port: port, draft: draft, ticket: ticket)
                                                }
                                            }
                                    }.font(.caption).foregroundStyle(.secondary).disabled(inputAction != nil)
                                }
                            }
                            } else {
                            DisclosureGroup(baselineText(language, "label.44455611b910"), isExpanded: $advanced) {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(definition.fields.filter { !["modelID", "task", "promptText", "count"].contains($0.id) }) { field in
                                        QuickParameterField(ownerID: draft.id, operationID: draft.node.operationID, modelIdentity: draft.node.parameters["modelID"]?.string, field: field, value: draft.node.parameters[field.id] ?? field.defaultValue,
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
                            Stepper(workflowText(language, "refinement.quick.attemptCount", arguments: ["count": String(draft.attempts)]), value: Binding(get: { draft.attempts },
                                set: { quick.setAttempts($0, draftID: draft.id) }), in: 1...8)
                            Text(baselineText(language, "label.3238f75ca285"))
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            if let issue = inputIssue ?? quick.inputIssue ?? quick.saveIssue ?? quick.error { WorkbenchIssueText(raw: issue, key: inputIssue == nil && quick.inputIssue == issue ? quick.inputIssueCode : nil).foregroundStyle(.red).textSelection(.enabled) }
                            if let inputNotice { Text(inputNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        } else {
                            if let error = quick.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                            ContentUnavailableView(baselineText(language, "label.48ccfc0d2104"), systemImage: "square.stack.3d.up",
                                description: Text(baselineText(language, "label.6f33836bdd1a")))
                            Button(baselineText(language, "label.72f5f0e15b59"), action: onChooseModel)
                        }
                    }.padding(22)
                }
    }
    private var generationBar: some View {
            HStack {
                Text(quick.isRunning ? quick.phase : refinementText("saveNote", fallback: "输入与结果保存到快速创作记录")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if quick.isRunning {
                    ProgressView().controlSize(.small)
                    Button(quick.category == .audio ? audioText("stop") : baselineText(language, "label.ea6aa5fbc2d9")) { Task { await quick.cancel() } }
                } else if quick.pendingSaveRunID != nil || quick.saveIssue != nil {
                    Button(quick.category == .audio ? audioText("retrySave") : baselineText(language, "label.fb412bfea70f")) { Task { await quick.retrySave() } }
                } else {
                    Button(quick.category == .audio ? audioText("generate") : baselineText(language, "label.1ad1463fe16f")) { quick.start() }.buttonStyle(WorkbenchPrimaryButtonStyle())
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
        return quick.category == .audio ? result.filter { $0.kind == .audio } : result
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
                    Button(baselineText(language, "label.1c66265feb9f"), systemImage: "square.stack.3d.up") { onResultToCanvas(reference) }
                    Spacer()
                    Button(baselineText(language, "label.643e7408e6a7"), systemImage: "square.and.arrow.up") { Task { await export(reference) } }
                }
            } else {
                ContentUnavailableView(refinementText("preview", fallback: "预览"), systemImage: quick.category == .image ? "photo" : "video", description: Text(refinementText("previewHelp", fallback: "生成后在这里查看；素材与结果保留在右侧。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(12).workbenchPanel(cornerRadius: 16).accessibilityIdentifier("quick-fixed-preview")
    }
    private func audioText(_ key: String) -> String { workflowText(language, "quick.audio." + key) }
    private var audioIdentity: String {
        guard quick.category == .audio, contentVisible else { return "inactive" }
        return "\(ObjectIdentifier(quick.store)):\(quick.category.rawValue):\(selectedMedia?.assetID.uuidString ?? "none"):\(selectedMedia?.version.uuidString ?? "none"):\(contentVisible):\(detailRun?.id.uuidString ?? "none"):\(preview?.assetID.uuidString ?? "none")"
    }
    private var audioStage: some View {
        VStack(spacing: 8) {
            if let reference = selectedMedia {
                HStack {
                    QuickAudioCandidate(store: quick.store, reference: reference, attempt: run(containing: reference)?.attemptIndex)
                    Spacer()
                    Button(audioText("details"), systemImage: "info.circle") { detailRun = run(containing: reference) }.labelStyle(.iconOnly).help(audioText("details"))
                    WorkbenchMenu {
                        WorkbenchMenuAction(audioText("save"), systemImage: "square.and.arrow.down") { Task { await saveAudio(reference) } }.disabled(savingAudio)
                        WorkbenchMenuAction(audioText("export"), systemImage: "square.and.arrow.up") { Task { await export(reference) } }
                        WorkbenchMenuAction(audioText("continue")) { onResultToCanvas(reference) }
                    } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.help(audioText("details"))
                }
                Spacer(minLength: 0)
                QuickAudioPlayer(playback: audioPlayback, beforePlay: {
                    model.projectSession.audio?.transport.stopPlayback()
                    model.projectSession.audioCreationTransport.stopPlayback()
                })
                Spacer(minLength: 0)
                HStack {
                    Button(audioText("previous"), systemImage: "chevron.left") { stepCandidate(-1) }.labelStyle(.iconOnly).help(audioText("previous")).disabled(reference == mediaReferences.first)
                    Text("\((mediaReferences.firstIndex(of: reference) ?? 0) + 1) / \(mediaReferences.count)").monospacedDigit()
                    Button(audioText("next"), systemImage: "chevron.right") { stepCandidate(1) }.labelStyle(.iconOnly).help(audioText("next")).disabled(reference == mediaReferences.last)
                }
            } else {
                Spacer(); Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                Text(audioText("empty")).foregroundStyle(.secondary); Spacer()
            }
            if quick.visibleRuns.contains(where: QuickAudioPresentation.hasUnexpectedOutput) { Text(audioText("outputMismatch")).font(.caption).foregroundStyle(.red) }
            if let inputNotice { Text(inputNotice).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).workbenchPanel(cornerRadius: 20)
    }
    private func saveAudio(_ reference: WorkflowAssetReference) async {
        guard !savingAudio else { return }
        let source = quick.store, owner = model.projectSession
        guard owner.currentStore === source else { return }
        savingAudio = true; inputIssue = nil; inputIssueCode = nil; inputNotice = nil
        defer { savingAudio = false }
        do {
            if owner.workflow == nil { await owner.openWorkflow() }
            guard owner.currentStore === source, let controller = owner.workflow,
                  controller.services.store === source, let identity = controller.assetLibraryOwner else { throw WorkflowIssue("Project changed.", code: "container.issue.targetChanged") }
            try await controller.setCollected([.asset(reference)], collected: true, owner: identity)
            onAssetsChanged()
            guard quick.store === source, selectedMedia == reference else { return }
            inputIssue = nil; inputIssueCode = nil; inputNotice = audioText("saved")
        } catch { if quick.store === source, selectedMedia == reference { inputIssue = error.localizedDescription; inputIssueCode = (error as? WorkflowIssue)?.code } }
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
                                if let index = run.attemptIndex { Text(workflowText(language, "refinement.quick.attempt", arguments: ["index": String(index)])).font(.caption).foregroundStyle(.secondary) }
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
                                        if quick.category == .audio { QuickAudioCandidate(store: quick.store, reference: reference, attempt: run.attemptIndex) }
                                        else { QuickAssetPreview(store: quick.store, reference: reference, compact: true) }
                                        HStack {
                                            Button(baselineText(language, "label.db8db0530432")) {
                                                if detailRun != nil { pendingPreview = reference; detailRun = nil }
                                                else { preview = reference }
                                            }
                                            Button(baselineText(language, "label.1c66265feb9f")) { onResultToCanvas(reference) }
                                            Button(baselineText(language, "label.643e7408e6a7")) { Task { await export(reference) } }
                                        }
                                    }
                                }
                                if let issue = run.issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                                if [.failed, .cancelled, .interrupted, .partial].contains(run.status) {
                                    Button(baselineText(language, "retry.generate", fallback: "按本次输入重新生成")) { quick.retryAttempt(run.id) }
                                        .disabled(!quick.canRetry(run))
                                }
                                if QuickAudioPresentation.requiresWorkflow(run.draft) { Button(audioText("continue")) { onSettingsToCanvas(run.draft) } }
                                if run.retryOf != nil { Text(baselineText(language, "retry.record", fallback: "这是一次重新生成，原记录仍保留。")).font(.caption).foregroundStyle(.secondary) }
                                DisclosureGroup(baselineText(language, "label.b27824d6e4d6")) {
                                    Text(String(data: (try? JSONEncoder().encode(run.draft)) ?? Data(), encoding: .utf8) ?? "")
                                        .font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }.padding(16).workbenchPanel(cornerRadius: 14)
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
        case .available: baselineText(language, "readiness.ready")
        case .unprepared: baselineText(language, "readiness.unprepared")
        case .unavailable: baselineText(language, "readiness.unavailable")
        case .unsupported: baselineText(language, "readiness.unsupported")
        case .unknown: baselineText(language, "readiness.unknown")
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
                inputIssue = error.localizedDescription; inputIssueCode = (error as? WorkflowIssue)?.code
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
        inputIssueCode = nil
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
        do { try action(); inputIssue = nil; inputIssueCode = nil }
        catch { inputIssue = error.localizedDescription; inputIssueCode = (error as? WorkflowIssue)?.code }
    }
    private var exportMenuCommand: WorkbenchGenerationCommand? {
        guard contentVisible, [.image, .video, .audio].contains(quick.category), let reference = selectedMedia else { return nil }
        return .init(title: systemMenuText(language, "export"), isEnabled: detailRun == nil && preview == nil) {
            guard commandScope.permitsVisibleCommands, contentVisible, selectedMedia == reference else { return }
            Task { await export(reference, selectionIsCurrent: { selectedMedia == reference }) }
        }
    }
    private func export(_ reference: WorkflowAssetReference, selectionIsCurrent: @escaping () -> Bool = { true }) async {
        let owner = quick, source = quick.store, category = quick.category, draftID = quick.draft?.id
        let command = WorkbenchAssetExportCommand(store: source, reference: reference,
            staleMessage: systemMenuText(language, "stale"), isCurrent: {
                selectionIsCurrent() && contentVisible && quick === owner && quick.store === source && quick.category == category && quick.draft?.id == draftID
                    && quick.visibleRuns.contains { references($0).contains(reference) }
            })
        do {
            _ = try await command.perform {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.title = systemMenuText(language, "export")
                return await panel.begin() == .OK ? panel.url : nil
            }
        } catch { inputIssue = error.localizedDescription; inputIssueCode = (error as? WorkflowIssue)?.code }
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
    var modelIdentity: String? = nil
    let field: WorkflowFieldDefinition
    let value: WorkflowScalar
    let onChange: (WorkflowScalar) -> Void
    let raw: String?
    let onRaw: (String) -> Void
    var titleOverride: String? = nil
    var hidesTitle = false
    @Environment(\.dLanguageStore) private var language
    private var title: String { titleOverride ?? WorkflowCanvasPresentation.fieldTitle(operationID: operationID, field: field, language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !hidesTitle { Text(title).font(.subheadline) }
            switch field.kind {
            case .text(let multiline):
                if multiline {
                    // Reuse the existing composition-safe editor: a save revision
                    // must not write the last committed value over marked text.
                    TextSourcesQuestionEditor(value: value.string ?? "", editEpoch: 0, isEditable: true,
                        accessibilityIdentifier: "quick-field-" + field.id,
                        onEdit: { onChange(.text($0)) })
                        .id([ownerID, field.id])
                        .frame(minHeight: 130).padding(6).workbenchInputSurface()
                }
                else { TextField(title, text: stringBinding).textFieldStyle(WorkbenchGlassTextFieldStyle()) }
            case .choice(let options):
                WorkbenchPicker(title, selection: stringBinding) {
                    WorkbenchChoiceForEach(options, id: \.self) { option in
                        WorkbenchChoice(WorkflowCanvasPresentation.choiceTitle(fieldID: field.id, value: option, language: language), value: option)
                            .disabled(field.id == "loadingStrategy" && WorkflowModelRoutes.rejectsTextLoading(modelIdentity: modelIdentity, strategy: option))
                    }
                }.labelsHidden()
                if field.id == "loadingStrategy", WorkflowModelRoutes.rejectsTextLoading(modelIdentity: modelIdentity, strategy: "ssdLayered") {
                    Text(workflowText(language, "workflow.loading.quantizedRestriction"))
                        .font(.caption).foregroundStyle(value.string == "ssdLayered" ? .orange : .secondary)
                }
            case .flag: Toggle(title, isOn: Binding(get: { if case .flag(let b) = value { b } else { false } }, set: { onChange(.flag($0)) })).labelsHidden()
            case .integer, .decimal:
                TextField(title, text: Binding(get: { raw ?? numberString }, set: { onRaw($0) })).textFieldStyle(WorkbenchGlassTextFieldStyle())
            }
        }
    }
    private var stringBinding: Binding<String> { .init(get: { value.string ?? "" }, set: { onChange(.text($0)) }) }
    private var numberString: String { switch value { case .integer(let n): String(n); case .decimal(let n): String(n); default: "" } }
}

struct QuickAssetPreview: View {
    private struct Identity: Hashable {
        let store: ObjectIdentifier
        let reference: WorkflowAssetReference
    }
    private var identity: Identity { .init(store: ObjectIdentifier(store), reference: reference) }
    @State private var requestGeneration: UUID?
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
            else { ProgressView(baselineText(language, "label.0dee08a39132")) }
        }
        .task(id: identity) {
            let generation = UUID(); requestGeneration = generation
            player?.pause(); player = nil; image = nil; text = nil; issue = nil
            @MainActor func current() -> Bool { !Task.isCancelled && requestGeneration == generation }
            do {
                if [.audio, .video].contains(reference.kind) {
                    let (url, _) = try await store.workflowMedia(reference)
                    guard current() else { return }
                    player = AVPlayer(url: url)
                } else if reference.kind == .text {
                    let value = try await store.workflowText(reference)
                    guard current() else { return }; text = value
                } else {
                    let data = try await store.workflowData(reference)
                    guard current() else { return }
                    if reference.kind == .image { image = NSImage(data: data) }
                    else if reference.kind == .document { text = "原始文档已保留；可加入聊天后读取文字。 / Original document preserved; add it to chat to read its text." }
                    else { text = String(data: data, encoding: .utf8) ?? "此素材不支持文本预览" }
                }
            } catch { if current() { issue = error.localizedDescription } }
        }
        .onDisappear { requestGeneration = nil; player?.pause(); player = nil }
    }
}
