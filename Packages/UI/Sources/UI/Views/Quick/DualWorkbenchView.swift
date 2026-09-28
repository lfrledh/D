import AppKit
import DWorkbench
import SwiftUI

/// Two peers share real services and assets; navigation does not own inference.
public struct DualWorkbenchView: View {
    public enum Entry: String, CaseIterable { case quick, workflow }
    let model: WorkbenchModel
    let quickModel: WorkbenchModel
    let quick: QuickGenerationController
    let library: ModelLibraryModel
    let nodeTags: ModelNodeTagStore
    let metadata: SharedLibraryStore?
    let metadataIssue: String?
    @State private var projects: [ProjectManifest] = []
    @State private var fullLibraryState = SharedLibraryBrowserState()
    @State private var compactLibraryState = SharedLibraryBrowserState()
    @State private var previewAsset: LibraryAssetPreview?
    private enum LibraryDestination { case asset(LibraryAssetPreview), info(SharedLibraryBrowserEntry), models }
    @State private var pendingLibraryDestination: LibraryDestination?
    @State private var returnToLibrary = false
    @State private var libraryInfo: SharedLibraryBrowserEntry?
    private struct LibraryAssetPreview: Identifiable { let store: ProjectStore; let reference: WorkflowAssetReference; var id: WorkflowAssetReference { reference } }
    private var entries: [SharedLibraryBrowserEntry] {
        SharedLibraryProjection.entries(models: quickModel.projectSession.explicitModelChoices,
            readiness: quickModel.projectSession.explicitModelReadiness,
            tools: canvasModel.projectSession.workflow?.tools ?? [], projects: projects, language: language)
    }
    @State private var entry: Entry = .quick
    @State private var libraryVisible = false
    @State private var projectsVisible = false
    @State private var compatibilityVisible = false
    @State private var languageVisible = false
    @State private var issue: String?
    @Environment(\.dLanguageStore) private var language
    private var canvasModel: WorkbenchModel { model.manifest == nil ? quickModel : model }
    public init(model: WorkbenchModel, quickModel: WorkbenchModel, quick: QuickGenerationController,
                library: ModelLibraryModel, nodeTags: ModelNodeTagStore, metadata: SharedLibraryStore?, metadataIssue: String? = nil) {
        self.model = model; self.quickModel = quickModel; self.quick = quick; self.library = library; self.nodeTags = nodeTags; self.metadata = metadata; self.metadataIssue = metadataIssue
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Text("D").font(.title2.bold())
                Picker(baselineText(language, "label.78d18c6b29c7", fallback: "工作方式"), selection: $entry) {
                    Text(baselineText(language, "label.893819bb34b0", fallback: "快速生成")).tag(Entry.quick)
                    Text(baselineText(language, "label.c71d0bca46eb", fallback: "工作流")).tag(Entry.workflow)
                }.pickerStyle(.segmented).frame(width: 230).accessibilityIdentifier("workbench-entry")
                Spacer()
                if entry == .workflow {
                    Button(canvasModel.manifest?.name ?? "流程项目") { projectsVisible = true }
                }
                Button { libraryVisible = true } label: { Label(baselineText(language, "label.433bdcb25776", fallback: "资料库"), systemImage: "square.stack.3d.up") }
                    .accessibilityIdentifier("shared-library-open")
                Menu {
                    Button(baselineText(language, "label.a6b4608f6c77", fallback: "项目…")) { projectsVisible = true }
                    Button(baselineText(language, "label.7e060553182c", fallback: "创作文稿与原有编辑器…")) { compatibilityVisible = true }
                    Button(baselineText(language, "label.17bb056515cd", fallback: "模型下载与安装…")) { library.isPresented = true }
                    Button(baselineText(language, "label.f1df761fb2f8", fallback: "显示语言…")) { languageVisible = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            Divider()
            ZStack {
                QuickGenerationView(quick: quick, model: quickModel, onChooseModel: { libraryVisible = true },
                    onSettingsToCanvas: { draft in Task { await settingsToCanvas(draft) } },
                    onResultToCanvas: { ref in Task { await resultToCanvas(ref) } },
                    onValueToCanvas: { value in Task { await valueToCanvas(value) } })
                    .opacity(entry == .quick ? 1 : 0).allowsHitTesting(entry == .quick).accessibilityHidden(entry != .quick)
                WorkflowHostView(model: canvasModel, nodeTags: nodeTags, onQuickUse: useNode,
                    libraryContent: { point in AnyView(libraryBrowser(compact: true, at: point)) },
                    onSharedAssetDrop: acceptSharedAssetDrop)
                    .opacity(entry == .workflow ? 1 : 0).allowsHitTesting(entry == .workflow).accessibilityHidden(entry != .workflow)
            }

        }
        .frame(minWidth: 860, minHeight: 580)
        .sheet(isPresented: $libraryVisible, onDismiss: finishLibraryDismissal) {
            libraryBrowser(compact: false, at: CGPoint(x: 160, y: 140))
                .frame(minWidth: 820, minHeight: 540)
                .task { await refreshLibrary(checkModels: true) }
        }
        .sheet(isPresented: $projectsVisible) {
            VStack(spacing: 0) {
                HStack { Text(baselineText(language, "label.79f326be4409", fallback: "项目")).font(.headline); Spacer(); Button(baselineText(language, "label.3fd47edce45b", fallback: "关闭")) { projectsVisible = false }.keyboardShortcut(.cancelAction) }.padding()
                ProjectChooserView(recentProjects: model.recentProjects, isBusy: model.isChangingProject,
                    onNew: { Task { if await model.newProject() { projectsVisible = false; entry = .workflow } } },
                    onOpen: { Task { if await model.openProject() { projectsVisible = false; entry = .workflow } } },
                    onRecent: { id in Task { if await model.openRecentProject(id: id) { projectsVisible = false; entry = .workflow } } },
                    onModels: { library.isPresented = true })
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
                }
            }.frame(minWidth: 640, minHeight: 420)
        }
        .sheet(isPresented: $compatibilityVisible) {
            VStack(spacing: 0) {
                HStack { Text(baselineText(language, "label.6f5cabc6a134", fallback: "创作文稿与模态编辑器")); Spacer(); Button(baselineText(language, "label.572cf45ba436", fallback: "返回")) { compatibilityVisible = false }.keyboardShortcut(.cancelAction) }.padding()
                WorkbenchView(model: model, library: library, nodeTags: nodeTags)
            }.frame(minWidth: 960, minHeight: 650)
        }
        .sheet(isPresented: Binding(get: { library.isPresented }, set: { library.isPresented = $0 }), onDismiss: restoreLibraryIfNeeded) {
            ModelLibraryView(model: library, selectedModelID: quickModel.selectedModelID, canSelect: true) { id in
                quickModel.clearError()
                await quickModel.selectModel(id: id)
                guard quickModel.selectedModelID == id, quickModel.projectSession.errorMessage == nil else {
                    issue = quickModel.projectSession.errorMessage ?? "模型选择未完成，原选择保留。"; return
                }
                quickModel.projectSession.refreshWorkflowModels()
                if let identity = quickModel.projectSession.selectedWorkflowImageIdentity {
                    quick.select(operationID: "d.image.generate", modelID: identity)
                }
                returnToLibrary = false; library.isPresented = false; entry = .quick
            }
        }
        .sheet(isPresented: $languageVisible) {
            VStack { if let language { LanguageSettingsView(store: language) }
                Button(baselineText(language, "label.3fd47edce45b", fallback: "关闭")) { languageVisible = false }.keyboardShortcut(.cancelAction) }.padding().frame(width: 560, height: 440)
        }
        .alert("操作未完成", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button(baselineText(language, "label.f867f3417859", fallback: "好")) { issue = nil }
        } message: { Text(issue ?? "") }
        .task {
            if quick.draft == nil { quick.select(operationID: "d.model.language", modelID: "") }
            await refreshLibrary(checkModels: false)
        }
        .onChange(of: quick.state.revision) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .onChange(of: model.manifest?.revision) { _, _ in Task { await refreshLibrary(checkModels: false) } }
        .sheet(item: $previewAsset, onDismiss: restoreLibraryIfNeeded) { value in
            VStack { QuickAssetPreview(store: value.store, reference: value.reference, compact: false)
                Button(baselineText(language, "label.3fd47edce45b", fallback: "关闭")) { previewAsset = nil }.keyboardShortcut(.cancelAction) }.padding(20).frame(minWidth: 560, minHeight: 360)
        }
        .sheet(item: $libraryInfo, onDismiss: restoreLibraryIfNeeded) { value in
            VStack(alignment: .leading, spacing: 14) { HStack { Text(value.item.title).font(.title2); Spacer(); Button(baselineText(language, "label.3fd47edce45b", fallback: "关闭")) { libraryInfo = nil } }
                Text(value.item.detail); ForEach(value.facts, id: \.self) { Text($0).textSelection(.enabled) }
                if case .unavailable = value.selection { Button(baselineText(language, "label.32d818ead29f", fallback: "打开已有编辑器")) { returnToLibrary = false; libraryInfo = nil; libraryVisible = false; compatibilityVisible = true } }
            }.padding(24).frame(minWidth: 550, minHeight: 280)
        }
        .focusedSceneValue(\.workbenchGeneration, WorkbenchGenerationCommand(title: "快速生成", isEnabled: quickCommandEnabled,
            action: { if quickCommandEnabled { quick.start() } }))
    }
    private func presentLibraryDestination(_ value: LibraryDestination) {
        if libraryVisible {
            returnToLibrary = true; pendingLibraryDestination = value; libraryVisible = false
        } else { openLibraryDestination(value) }
    }
    private func finishLibraryDismissal() {
        guard let pending = pendingLibraryDestination else { return }
        pendingLibraryDestination = nil; openLibraryDestination(pending)
    }
    private func openLibraryDestination(_ value: LibraryDestination) {
        switch value {
        case .asset(let preview): previewAsset = preview
        case .info(let item): libraryInfo = item
        case .models: library.isPresented = true
        }
    }
    private func restoreLibraryIfNeeded() {
        guard returnToLibrary else { return }
        returnToLibrary = false; libraryVisible = true
    }
    private var quickCommandEnabled: Bool {
        entry == .quick && quick.canStart && !libraryVisible && !projectsVisible && !compatibilityVisible &&
        !languageVisible && !library.isPresented && previewAsset == nil && libraryInfo == nil
    }
    @ViewBuilder private func libraryBrowser(compact: Bool, at point: CGPoint) -> some View {
        if let metadata {
            SharedLibraryBrowser(entries: entries, store: metadata, compact: compact, state: compact ? compactLibraryState : fullLibraryState,
                onUse: useLibraryEntry, onAdd: { value in Task { await addLibraryEntry(value, at: point) } },
                onPreview: { value in Task { await previewLibraryEntry(value) } },
                onPrepare: { value in Task { await prepareModel(value) } },
                onImport: { Task { await importLibraryAsset() } }, onClose: { libraryVisible = false })
        } else {
            VStack { Text(metadataIssue ?? "资料整理暂不可用，原件未改。").textSelection(.enabled)
                Button(baselineText(language, "label.17bb056515cd", fallback: "模型下载与安装…")) { libraryVisible = false; library.isPresented = true }
                Button(baselineText(language, "label.3fd47edce45b", fallback: "关闭")) { libraryVisible = false } }.padding()
        }
    }
    private func refreshLibrary(checkModels: Bool) async {
        quickModel.projectSession.refreshWorkflowModels()
        if checkModels { await quickModel.projectSession.checkExplicitModelReadiness() }
        var snapshots = [await quick.store.snapshot()]
        if let store = model.projectSession.currentStore, store !== quick.store { snapshots.append(await store.snapshot()) }
        projects = snapshots
        if let metadata {
            do {
                for value in entries where value.item.kind == .model || value.item.kind == .program {
                    switch nodeTags.readState(for: value.item.key) {
                    case .valid(let names): try metadata.importLegacyTags(names, for: value.item.key)
                    case .missing: break
                    case .corrupt: issue = "旧标签记录损坏，未迁移或覆盖：" + value.item.title
                    }
                }
            } catch { issue = error.localizedDescription }
        }
    }
    private func useLibraryEntry(_ value: SharedLibraryBrowserEntry) {
        guard case .operation(let operation, let id) = value.selection,
              let id, WorkflowRegistry.standard.operation(operation)?.definition.modelKind != nil else { presentLibraryDestination(.info(value)); return }
        quick.select(operationID: operation, modelID: id)
        libraryVisible = false; entry = .quick
    }
    private func useNode(_ node: WorkflowNode) {
        guard let controller = canvasModel.projectSession.workflow else { return }
        // Connected values are not silently guessed from stale history; the graph is untouched.
        guard controller.graph?.connections.contains(where: { $0.targetNode == node.id }) != true else {
            issue = "此节点包含连线输入。请先把所需结果存为素材，再在快速界面显式选择；未忽略连线或修改原节点。"; return
        }
        quick.useSettings(node); entry = .quick
    }
    private func store(for projectID: UUID) async throws -> ProjectStore {
        if await quick.store.snapshot().id == projectID { return quick.store }
        if let store = model.projectSession.currentStore, await store.snapshot().id == projectID { return store }
        throw WorkflowIssue("所属项目已关闭，请重新打开；没有扩大素材访问范围。")
    }
    private func previewLibraryEntry(_ value: SharedLibraryBrowserEntry) async {
        guard case .asset(let projectID, let assetID) = value.selection else { presentLibraryDestination(.info(value)); return }
        do { let source = try await store(for: projectID)
            let ref = try await source.pinWorkflowAsset(assetID)
            presentLibraryDestination(.asset(.init(store: source, reference: ref)))
        } catch { issue = error.localizedDescription }
    }
    private func prepareModel(_ value: SharedLibraryBrowserEntry) async {
        guard case .operation(let id, _) = value.selection, let kind = WorkflowRegistry.standard.operation(id)?.definition.modelKind else { presentLibraryDestination(.info(value)); return }
        if kind == .image { presentLibraryDestination(.models); return }
        if kind == .pitch { await refreshLibrary(checkModels: true); presentLibraryDestination(.info(value)); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "登记已有模型的原位置；不会复制、移动或删除权重。"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { let choice = try await quickModel.projectSession.registerExplicitModel(at: url, kind: kind)
            quick.select(operationID: id, modelID: choice.id)
            await refreshLibrary(checkModels: true)
        } catch { issue = error.localizedDescription }
    }
    private func importLibraryAsset() async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do { _ = try await quick.store.importWorkflowMediaFile(at: url); await refreshLibrary(checkModels: false) }
        catch { issue = error.localizedDescription }
    }
    private func addLibraryEntry(_ value: SharedLibraryBrowserEntry, at point: CGPoint) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { return }
        do {
            switch value.selection {
            case .operation(let id, let modelID): controller.addNode(operationID: id, modelID: modelID, x: point.x, y: point.y)
            case .tool(let reference):
                guard let tool = controller.tools.first(where: { $0.id == reference.id && $0.version == reference.version && (try? WorkflowPlanCompiler.digest($0)) == reference.digest }) else { throw WorkflowIssue("工具不属于当前项目的固定版本。") }
                controller.addTool(tool, x: point.x, y: point.y)
            case .asset(let projectID, let assetID):
                let source = try await store(for: projectID)
                let ref = try await source.pinWorkflowAsset(assetID)
                let copied = try await copiedReference(ref, from: source, to: controller.services.store)
                guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变。") }
                try await controller.insertQuickResult(copied, target: scope, x: point.x, y: point.y)
            case .unavailable(let reason): throw WorkflowIssue(reason)
            }
            try await controller.saveExplicitEdits()
            libraryVisible = false; entry = .workflow
        } catch { issue = error.localizedDescription }
    }
    private func copiedReference(_ reference: WorkflowAssetReference, from original: ProjectStore? = nil, to destination: ProjectStore) async throws -> WorkflowAssetReference {
        let source = original ?? quick.store
        if destination === source { return reference }
        return try await destination.copyWorkflowAsset(reference, from: source)
    }
    private func copiedDatum(_ value: WorkflowDatum, to destination: ProjectStore) async throws -> WorkflowDatum {
        try value.validate()
        var copies: [WorkflowAssetReference: WorkflowAssetReference] = [:]
        for ref in value.assetReferences where copies[ref] == nil {
            copies[ref] = try await copiedReference(ref, to: destination)
        }
        func replace(_ datum: WorkflowDatum) throws -> WorkflowDatum {
            switch datum {
            case .asset(let ref):
                guard let copy = copies[ref] else { throw WorkflowIssue("缺少已复制的素材引用。") }
                return .asset(copy)
            case .record(let schema, let fields): return .record(schema: schema, fields: try fields.mapValues(replace))
            case .list(let element, let items): return .list(element: element, items: try items.map { .init(id: $0.id, value: try replace($0.value)) })
            case .result(var result): result.value = try result.value.map(replace); return .result(result)
            default: return datum
            }
        }
        return try replace(value)
    }
    private func acceptSharedAssetDrop(_ projectID: UUID, _ assetID: UUID, _ point: CGPoint, _ target: WorkflowCanvasInsertionTarget) -> Bool {
        guard let controller = canvasModel.projectSession.workflow, controller.isCurrent(target),
              projects.contains(where: { $0.id == projectID && $0.assets.contains(where: { $0.id == assetID }) }) else { return false }
        let owner = canvasModel.projectSession
        Task {
            do {
                let source = try await store(for: projectID)
                let ref = try await source.pinWorkflowAsset(assetID)
                let copied = try await copiedReference(ref, from: source, to: controller.services.store)
                guard owner.workflow === controller, controller.isCurrent(target) else { throw WorkflowIssue("拖放期间目标已改变，未插入其他流程。") }
                try await controller.insertQuickResult(copied, target: target, x: point.x, y: point.y)
            } catch { issue = error.localizedDescription }
        }
        return true
    }
    private func settingsToCanvas(_ draft: QuickDraft) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { issue = "流程当前不可编辑"; return }
        do {
            var copy = draft
            for (port, value) in copy.inputs {
                guard let datum = value.datum else { throw WorkflowIssue("请先选择单项输入，不能隐式复制候选集合。") }
                copy.inputs[port] = .data(try await copiedDatum(datum, to: controller.services.store))
            }
            guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变，未放入其他流程。") }
            try await controller.insertQuickSettings(copy, target: scope)
            entry = .workflow
        } catch { issue = error.localizedDescription }
    }
    private func resultToCanvas(_ ref: WorkflowAssetReference) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { issue = "流程当前不可编辑"; return }
        do {
            let copy = try await copiedReference(ref, to: controller.services.store)
            guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变。") }
            try await controller.insertQuickResult(copy, target: scope)
            entry = .workflow
        } catch { issue = error.localizedDescription }
    }
    private func valueToCanvas(_ value: WorkflowDatum) async {
        let target = canvasModel
        await target.projectSession.openWorkflow()
        guard let controller = target.projectSession.workflow else { return }
        if controller.graph == nil { controller.addBlankGraph() }
        guard let scope = controller.canvasInsertionTarget() else { issue = "流程当前不可编辑"; return }
        do {
            let copy = try await copiedDatum(value, to: controller.services.store)
            guard target.projectSession.workflow === controller else { throw WorkflowIssue("目标项目已改变。") }
            try await controller.insertQuickValue(copy, target: scope)
            entry = .workflow
        } catch { issue = error.localizedDescription }
    }
}
