import AppKit
import DWorkbench
import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor struct ContainerItem: Identifiable {
    let id: String
    let itemID: String
    let value: WorkflowValue?
    let record: WorkflowPlanCallRecord?
    let source: WorkflowLibrarySource?
    let failure: String?
    let ordinal: Int
    var failureCode: String? = nil
    var runtimeAnnotationKey: String? = nil
    var concept: String? = nil
    var producer: WorkflowNode? = nil
    var consumers: [WorkflowConsumerMatch] = []

    mutating func captureAnnotationKey(owner: WorkflowAssetLibraryOwner?) {
        guard let owner, let value, value.asset == nil, case .runtime(let runtime) = source else { return }
        runtimeAnnotationKey = try? runtime.annotationIdentity(owner: owner, value: value).storageKey
    }
    func displayName(assets: [ProjectAsset], metadata: SharedLibraryMetadata?, fallback: String) -> String {
        if let reference = value?.asset, let asset = assets.first(where: { $0.id == reference.assetID }) { return asset.name }
        if let runtimeAnnotationKey, let name = metadata?.runtimeAnnotations[runtimeAnnotationKey]?.name, !name.isEmpty { return name }
        return fallback
    }
    func exactProducer(in runs: [WorkflowRun]) -> WorkflowNode? {
        guard case .runtime(let source) = source,
              let run = runs.first(where: { $0.id == source.call.address.runID }), let checkpoint = run.planCheckpoint,
              let current = checkpoint.records.first(where: { $0.id == source.call.stepID && $0.address == source.call.address }) else { return nil }
        if source.input != true { return current.step.node }
        var bindings: [WorkflowPlanInput] = []
        func visit(_ plan: WorkflowPlan) {
            for step in plan.steps {
                if step.id == current.step.node.id { bindings += step.inputs.filter { $0.port == source.port } }
                switch step.kind {
                case .call: break
                case .branch(_, let yes, let no): visit(yes); visit(no)
                case .map(let body, _), .loop(let body, _, _, _), .invoke(_, let body): visit(body)
                }
            }
        }
        visit(checkpoint.plan)
        guard bindings.count == 1, let binding = bindings.first else { return nil }
        let address = WorkflowExecutionAddress(runID: run.id, path: Array(current.address.path.dropLast()) + [.node(binding.sourceNode)])
        guard let producer = checkpoint.records.first(where: { $0.address == address }),
              let output = producer.step.outputs[binding.sourcePort], output == current.step.inputs[source.port] else { return nil }
        return producer.step.node
    }
}

@MainActor @Observable final class WorkflowContainerPresentation {
    var showCollectionSettings = false
    var ruleDraft: WorkflowCollectionRuleDraft?
    var scopes: [WorkflowContainerScope] = []
    var selectedScope: WorkflowContainerScope?
    var snapshot: WorkflowContainerSnapshot?
    var previewSelection = Set<String>()
    var staticSourceRows: [ContainerItem] = []
    var currentItem: String?
    var repetitions = 1
    var seedStrategy: WorkflowBatchSeedStrategy = .fixed
    var error: WorkflowIssue?
    var rejectAll = false
    var cache = WorkflowLibraryPreviewCache()
    var rows: [ContainerItem] = []
    var playback = WorkflowContainerPlayback()
    var collectionLocation: WorkflowLibraryContext?
    var expanded = false
    static func hasUndecidedFilter(_ calls: [WorkflowPlanCallRecord]) -> Bool {
        calls.contains { $0.step.node.operationID == WorkflowAssetContainer.filterID && $0.step.status == .waiting && $0.step.decision == nil }
    }
}

/// The card and historical waiting entries share the same captured call decisions.
/// Only bounded presentation state lives here; accepted values remain in the archive.
@MainActor struct WorkflowAssetContainerView: View {
    let controller: WorkflowController
    @State private var presentation: WorkflowContainerPresentation
    @Environment(\.workflowContainerNavigation) private var navigation
    @Environment(\.workbenchContentVisible) private var contentVisible
    let node: WorkflowNode
    var forcedStepID: UUID? = nil
    var scale: CGFloat = 1
    var height: CGFloat = 270
    private let headerActions: WorkbenchMenuRows?
    private let expandedPresentation: Bool
    @Environment(\.dLanguageStore) private var language
    @Environment(\.workflowViewerModel) private var model
    @Environment(\.workflowContainerLibrary) private var library
    private var showCollectionSettings: Bool { get { presentation.showCollectionSettings } nonmutating set { presentation.showCollectionSettings = newValue } }
    private var scopes: [WorkflowContainerScope] { get { presentation.scopes } nonmutating set { presentation.scopes = newValue } }
    private var selectedScope: WorkflowContainerScope? { get { presentation.selectedScope } nonmutating set { presentation.selectedScope = newValue } }
    private var snapshot: WorkflowContainerSnapshot? { get { presentation.snapshot } nonmutating set { presentation.snapshot = newValue } }
    private var previewSelection: Set<String> { get { presentation.previewSelection } nonmutating set { presentation.previewSelection = newValue } }
    private var staticSourceRows: [ContainerItem] { get { presentation.staticSourceRows } nonmutating set { presentation.staticSourceRows = newValue } }
    private var currentItem: String? { get { presentation.currentItem } nonmutating set { presentation.currentItem = newValue } }
    private var repetitions: Int { get { presentation.repetitions } nonmutating set { presentation.repetitions = newValue } }
    private var seedStrategy: WorkflowBatchSeedStrategy { get { presentation.seedStrategy } nonmutating set { presentation.seedStrategy = newValue } }
    private var error: WorkflowIssue? { get { presentation.error } nonmutating set { presentation.error = newValue } }
    private var rejectAll: Bool { get { presentation.rejectAll } nonmutating set { presentation.rejectAll = newValue } }
    private var cache: WorkflowLibraryPreviewCache { get { presentation.cache } nonmutating set { presentation.cache = newValue } }
    init(controller: WorkflowController, node: WorkflowNode, forcedStepID: UUID? = nil, scale: CGFloat = 1, height: CGFloat = 270, presentation: WorkflowContainerPresentation? = nil, headerActions: WorkbenchMenuRows? = nil, expandedPresentation: Bool = false) {
        self.controller = controller; self.node = node; self.forcedStepID = forcedStepID; self.scale = scale; self.height = height
        self._presentation = State(initialValue: presentation ?? WorkflowContainerPresentation())
        self.headerActions = headerActions; self.expandedPresentation = expandedPresentation
    }
    var enlargeControl: some View {
        Button { presentation.expanded = true } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 16 * scale)).frame(width: 28 * scale, height: 28 * scale)
        }.buttonStyle(.plain).accessibilityLabel(t("enlarge")).workflowNodeControl(node.id)
            .workbenchSheet(isPresented: $presentation.expanded, title: node.title) {
                WorkflowAssetContainerView(controller: controller, node: node, forcedStepID: forcedStepID, height: 560, presentation: presentation, expandedPresentation: true).frame(width: 720)
            }
    }
    @WorkbenchMenuBuilder var menuActions: WorkbenchMenuRows {
        WorkbenchMenuAction(t("invert")) { selectAll(invert: true) }.disabled(review && !mutable)
        WorkbenchMenuAction(t("collectAll") + " (\(rows.count))") { collect(rows) }.disabled(rows.isEmpty)
        if [WorkflowAssetContainer.filterID, WorkflowAssetContainer.previewID].contains(node.operationID) {
            WorkbenchMenuAction(t("collectionSettings")) {
                guard let target = controller.canvasInsertionTarget(),
                      let current = controller.graph?.nodes.first(where: { $0.id == node.id }) else { error = .init("Container target changed.", code: "container.stale"); return }
                presentation.ruleDraft = WorkflowCollectionRuleDraft(controller: controller, node: current, target: target)
                showCollectionSettings = true
            }
        }
        WorkbenchMenuAction(t("showInLibrary")) { showInLibrary(chosen.isEmpty ? rows : chosen) }.disabled(rows.isEmpty || navigation == nil)
        if let item = rows.first(where: { $0.id == currentItem }), let call = sourceCall(item) {
            WorkbenchMenuAction(t("locateSource")) { navigation?.source(call) }
        }
        if review { WorkbenchMenuAction(t("rejectAll"), role: .destructive) { rejectAll = true }.disabled(!canDecide) }
    }
    private func t(_ key: String) -> String { workflowText(language, "container." + key) }
    private var review: Bool { node.operationID == WorkflowAssetContainer.filterID }
    private var submission: WorkflowContainerSubmission? {
        controller.containerSubmissions.first { $0.scope == selectedScope }
    }
    private var rows: [ContainerItem] { get { presentation.rows } nonmutating set { presentation.rows = newValue } }
    private func projectedRows() -> [ContainerItem] {
        if let snapshot, node.assetReference == nil && node.operationID != WorkflowAssetContainer.sourceID {
            return snapshot.calls.enumerated().flatMap { ordinal, record -> [ContainerItem] in
                let value = record.step.inputs["input"] ?? record.step.outputs["output"]
                guard let value else { return [] }
                let isInput = record.step.node.operationID == WorkflowAssetContainer.filterID
                let projected = (try? WorkflowRuntimeAssetSource.projectedItems(call: .init(address: record.address, stepID: record.id), port: isInput ? "input" : "output", value: value, input: isInput)) ?? []
                return projected.map { item, runtime in
                    let validSource = isInput || record.step.outputs["output"] == value
                    return .init(id: record.id.uuidString + ":" + item.id, itemID: item.id, value: item.value, record: record,
                        source: item.value?.asset.map(WorkflowLibrarySource.asset) ?? (validSource ? .runtime(runtime) : nil), failure: item.failure, ordinal: ordinal + 1)
                }
            }
        }
        if node.librarySources != nil { return staticSourceRows }
        let values: [WorkflowDataItem]
        if let reference = node.assetReference { values = [.init(id: reference.assetID.uuidString, value: .asset(reference))] }
        else if let value = node.dataConfiguration?.value { values = [.init(id: "value", value: value)] }
        else if let items = node.dataConfiguration?.items { values = items }
        else { values = [] }
        return values.enumerated().map { index, item in
            let value = WorkflowValue.data(item.value)
            return .init(id: item.id, itemID: item.id, value: value, record: nil, source: value.asset.map(WorkflowLibrarySource.asset), failure: nil, ordinal: index + 1)
        }
    }
    private func selected(_ item: ContainerItem) -> Bool {
        guard review, let step = item.record?.step else { return previewSelection.contains(item.id) }
        return (step.decision?.selectedItemIDs ?? step.containerSelectionDraft ?? []).contains(item.itemID)
    }
    private var chosen: [ContainerItem] { rows.filter(selected) }
    private var grid: Bool { !rows.isEmpty && rows.allSatisfy { [WorkflowDataKind.image, .video].contains($0.value?.kind ?? .receipt) } }
    private var mutable: Bool { review && submission == nil && snapshot.map { WorkflowContainerPresentation.hasUndecidedFilter($0.calls) } == true }
    var body: some View {
        if let headerActions {
            HStack(spacing: 4 * scale) {
                enlargeControl
                WorkbenchMenu { menuActions; headerActions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16 * scale)).frame(width: 28 * scale, height: 28 * scale)
                }.buttonStyle(.plain).accessibilityLabel(t("more"))
                    .accessibilityIdentifier("workflow-node-menu-" + node.id.uuidString)
            }.workflowNodeControl(node.id)
        } else {
            VStack(spacing: 0) {
                if expandedPresentation || forcedStepID != nil {
                    HStack {
                        Text(node.title).font(.headline); Spacer()
                        WorkbenchMenu { menuActions } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                            .buttonStyle(.plain).accessibilityLabel(t("more"))
                    }.padding([.top, .horizontal], 12)
                }
                content
            }
        }
    }
    private var settingsPresented: Binding<Bool> {
        Binding(get: { presentation.showCollectionSettings && presentation.expanded == expandedPresentation },
                set: { if !$0 { presentation.showCollectionSettings = false } })
    }
    private var rejectionPresented: Binding<Bool> {
        Binding(get: { presentation.rejectAll && presentation.expanded == expandedPresentation },
                set: { if !$0 { presentation.rejectAll = false } })
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack(spacing: 6 * scale) {
                Text(t(review ? "manual" : "preview")).foregroundStyle(.secondary)
                if !scopes.isEmpty {
                    WorkbenchMenu {
                        WorkbenchMenuForEach(Array(scopes.enumerated()), id: \.element.key) { index, scope in
                            WorkbenchMenuAction(batchTitle(scope)) { selectedScope = scope; refresh() }
                        }
                    } label: {
                        Text(batchTitle(selectedScope))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Text(arrivalSummary).monospacedDigit().lineLimit(2)

            }
            if let otherWaitingCall {
                Button(t("otherGates")) { navigation?.source(otherWaitingCall) }.font(.caption).buttonStyle(.plain)
            }
            if let snapshot, !snapshot.collectionComplete { Text(t("collecting")).foregroundStyle(.secondary) }
            if controller.collectionRequests.contains(where: { !$0.completed && $0.error != nil }) {
                if let request = controller.collectionRequests.first(where: { !$0.completed && $0.error != nil }), let raw = request.error {
                    WorkbenchIssueText(raw: raw, key: request.errorCode).foregroundStyle(.red)
                }
                Button(t("retryCollection")) { Task { await retryCollection() } }
            }
            if let location = presentation.collectionLocation {
                HStack { Text(t("collectedFiltered")).font(.caption).foregroundStyle(.secondary); Button(t("showInLibrary")) {
                    guard location.isCurrent(in: controller) else { error = .init("Container target changed.", code: "container.stale"); return }
                    navigation?.reveal(location)
                } }
            }
            if let error { WorkbenchIssueText(raw: error.reason, key: error.code).foregroundStyle(.red) }
            WorkbenchScrollView {
                if rows.isEmpty { Text(t("empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80 * scale) }
                else if grid {
                    LazyVGrid(columns: [.init(.adaptive(minimum: 228 * scale), spacing: 8 * scale)], spacing: 8 * scale) {
                        ForEach(rows) { row($0) }
                    }
                } else { LazyVStack(spacing: 8 * scale) { ForEach(rows) { row($0) } } }
            }.frame(maxHeight: .infinity)
            HStack(spacing: 8 * scale) {
                Button(t("selectAll")) { selectAll() }.disabled(review && !mutable)
                Button(t("clear")) { selectAll(clear: true) }.disabled(review && !mutable)
                Spacer(minLength: 0)
                Text(t("selected") + " \(chosen.count)").monospacedDigit().onDrag { provider(chosen) } preview: { dragPreview(chosen) }
            }.buttonStyle(.plain)
            if review, submission == nil {
                HStack {
                    Stepper(t("perInput") + " \(repetitions)", value: $presentation.repetitions, in: 1...64)
                    Text("× \(Set(chosen.compactMap { $0.record?.address.runID }).count)").monospacedDigit()
                }.disabled(!canDecide)
                WorkbenchPicker(workspaceText(language, "seedStrategy"), selection: $presentation.seedStrategy) {
                    WorkbenchChoice(workspaceText(language, "seedFixed"), value: WorkflowBatchSeedStrategy.fixed)
                    WorkbenchChoice(workspaceText(language, "seedAutomatic"), value: WorkflowBatchSeedStrategy.automatic)
                }.disabled(!canDecide)
            }
            HStack(spacing: 8 * scale) {
                Button(t("library.add")) { collect(chosen) }.disabled(chosen.isEmpty)
                    .buttonStyle(WorkbenchGlassButtonStyle())
                Spacer(minLength: 0)
                if review {
                    Button(primaryTitle) { submit() }.buttonStyle(WorkbenchPrimaryButtonStyle())
                        .disabled(controller.isRunning || (submission == nil && (!canDecide || chosen.isEmpty)))
                }
            }
        }.font(.system(size: 11 * scale))
            .padding(12 * scale).frame(height: max(190, height) * scale)
            .contentShape(Rectangle()).workflowNodeControl(node.id)
            .task(id: controller.containerGeneration) { refresh() }
            .onChange(of: contentVisible) { _, visible in if !visible { presentation.playback.stop() } }
            .onDisappear { presentation.playback.stop() }
            .workbenchSheet(isPresented: settingsPresented, title: t("collectionSettings")) {
                if let draft = presentation.ruleDraft {
                    WorkflowCollectionRuleEditor(draft: draft, review: review, library: library)
                }
            }
            .workbenchSheet(isPresented: rejectionPresented, title: t("rejectAll")) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(t("rejectHelp"))
                    HStack {
                        Button(workspaceText(language, "cancel")) { rejectAll = false }
                        Spacer()
                        Button(t("rejectAll"), role: .destructive) { rejectAll = false; submit(endAll: true) }
                    }
                }.padding(24).frame(width: 430)
            }
    }
    private var otherWaitingCall: WorkflowCallReference? {
        guard let snapshot else { return nil }
        let own = Set(snapshot.calls.map(\.id))
        let selectedParents = Set(chosen.compactMap { $0.record?.address.runID })
        for run in snapshot.runs where selectedParents.contains(run.id) {
            for record in run.planCheckpoint?.records ?? [] {
                if record.step.status == .waiting && record.step.decision == nil && !own.contains(record.id) {
                    return WorkflowCallReference(address: record.address, stepID: record.id)
                }
            }
        }
        return nil
    }
    private var canDecide: Bool { mutable && snapshot?.collectionComplete == true && !controller.isRunning && !controller.hasPendingSaves }
    private var primaryTitle: String {
        if controller.hasPendingSaves && submission != nil { return workspaceText(language, "saveOnly") }
        if submission != nil { return t("continueSaved") }
        return t(otherWaitingCall == nil ? "useContinue" : "confirm") + " (\(chosen.count))"
    }
    private func row(_ item: ContainerItem) -> some View {
        HStack(alignment: .top, spacing: 6 * scale) {
            Button { toggle(item) } label: {
                Image(systemName: selected(item) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16 * scale)).frame(width: 28 * scale, height: 28 * scale).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(t("choose"))
                .disabled(item.value == nil || item.failure != nil || (review && (!mutable || item.record.map { !controller.canEditContainerCall(.init(address: $0.address, stepID: $0.id)) } == true)))
            VStack(alignment: .leading, spacing: 5 * scale) {
                Text(name(item)).fontWeight(.medium).lineLimit(2).textSelection(.enabled)
                if let value = item.value {
                    if let reference = value.asset {
                        if ![WorkflowDataKind.image, .video, .audio, .text, .document].contains(reference.kind) {
                            WorkflowContainerStructuredAssetInfo(reference: reference, controller: controller)
                        } else {
                        let entry = SharedLibraryBrowserEntry(item: .init(key: reference.assetID.uuidString, title: name(item), detail: "", kind: .asset, role: "container", contentKind: reference.kind, readiness: .available), selection: .unavailable(""))
                        WorkflowLibraryPreview(entry: entry, cache: cache, pixels: Int(300 * scale), load: {
                            try await controller.services.store.readOnlyAsset(id: reference.assetID, reference: reference)
                        }, exactVersion: reference.sha256).frame(minWidth: grid ? 140 * scale : nil, minHeight: grid ? 105 * scale : 38 * scale, maxHeight: grid ? 105 * scale : 38 * scale)
                            .onDrag { provider([item]) } preview: { dragPreview([item]) }
                        if reference.kind == .audio { audioControls(reference) }
                        else if reference.kind == .video {
                            Button { open(item) } label: { Label(workspaceText(language, "play"), systemImage: "play.fill") }
                                .buttonStyle(.plain)
                        }
                        }
                    } else if case .data(.text(let text)) = value {
                        Text(String(text.prefix(300))).lineLimit(3).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text(item.concept.map { WorkflowValueCompatibility.conceptTitle($0, language: language) }
                             ?? WorkflowCanvasPresentation.kind(value.kind, language: language)).foregroundStyle(.secondary)
                        Text(workflowText(language, "workflow.compatibility.producer") + " · " +
                             (item.producer?.title ?? workflowText(language, "metadata.panel.unknown"))).font(.caption)
                        ForEach(item.consumers) { match in
                            Text(match.displayTitle(language) + " · " + match.displayPort(language) + " · " +
                                 workflowText(language, "workflow.compatibility.status." + match.result.status.rawValue)).font(.caption).lineLimit(2)
                        }
                        if item.consumers.isEmpty { Text(workflowText(language, "workflow.compatibility.noReceivers")).font(.caption) }
                    }
                }
                if let failure = item.failure { WorkbenchIssueText(raw: failure, key: item.failureCode).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4 * scale) {
                Image(systemName: "hand.draw").font(.system(size: 16 * scale)).frame(width: 28 * scale, height: 28 * scale)
                    .contentShape(Rectangle()).onDrag { provider([item]) } preview: { dragPreview([item]) }
                    .help(t("dragAsset")).accessibilityLabel(t("dragAsset"))
            Button { open(item) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 16 * scale)).frame(width: 28 * scale, height: 28 * scale) }
                .buttonStyle(.plain).accessibilityLabel(t("enlarge")).disabled(item.value == nil)
            }
        }.padding(4 * scale).contentShape(Rectangle())
            .background(currentItem == item.id ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6 * scale))
            .onTapGesture(count: 2) { open(item) }.onTapGesture { currentItem = item.id }
            .focusable().focusEffectDisabled().onKeyPress(.space) { open(item); return .handled }
            .accessibilityIdentifier("container-item-" + item.id)
    }
    @ViewBuilder private func audioControls(_ reference: WorkflowAssetReference) -> some View {
        let playback = presentation.playback
        let isPlaying = playback.reference == reference && playback.transport.state == .playing
        HStack(spacing: 4 * scale) {
            Button {
                Task { do { try await playback.toggle(reference, controller: controller) } catch { self.error = .init(presenting: error, fallbackCode: "container.issue.actionFailed") } }
            } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 28 * scale, height: 28 * scale) }
                .buttonStyle(.plain).accessibilityLabel(workspaceText(language, isPlaying ? "pause" : "play"))
            if playback.reference == reference, let format = playback.format {
                Slider(value: Binding(get: { Double(playback.transport.positionFrame) }, set: { value in
                    do { try playback.transport.seek(toFrame: Int64(value)) } catch { self.error = .init(presenting: error, fallbackCode: "container.issue.actionFailed") }
                }), in: 0...Double(max(1, format.frameCount - 1))).accessibilityLabel(workspaceText(language, "seek"))
            }
        }
    }
    private func sourceCall(_ item: ContainerItem) -> WorkflowCallReference? {
        if case .runtime(let source) = item.source { return source.call }
        if let record = item.record { return .init(address: record.address, stepID: record.id) }
        return nil
    }
    private func showInLibrary(_ items: [ContainerItem]) {
        let sources = items.compactMap(\.source)
        guard !sources.isEmpty else { return }
        navigation?.reveal(.init(controller: controller, source: .sources(sources), name: node.title))
    }
    private func batchTitle(_ scope: WorkflowContainerScope?) -> String {
        guard let scope else { return "" }
        let index = (scopes.firstIndex(of: scope) ?? 0) + 1
        let date = controller.batchStages.first { $0.id == scope.stageID }?.createdAt
            ?? controller.runs.first { $0.id == scope.runID }?.createdAt
        return t("batch") + " \(index)" + (date.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
    }
    private var arrivalSummary: String {
        guard let snapshot else { return "\(rows.count)" }
        let failures = snapshot.stage?.attempts.filter { [.failed, .cancelled].contains($0.state) }.count ?? snapshot.runs.filter { [.failed, .cancelled].contains($0.status) }.count
        return t("arrived") + " \(rows.count)" + (failures == 0 ? "" : " · " + t("failed") + " \(failures)")
    }
    private func transferSources(_ items: [ContainerItem]) -> [WorkflowLibrarySource] {
        var seen = Set<String>()
        return items.compactMap(\.source).filter { seen.insert($0.key).inserted }
    }
    private func dragPreview(_ items: [ContainerItem]) -> some View {
        Label(items.count == 1 ? name(items[0]) : t("selected") + " \(transferSources(items).count)", systemImage: "doc.on.doc")
            .font(.callout).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    private func provider(_ items: [ContainerItem]) -> NSItemProvider {
        guard let owner = controller.assetLibraryOwner else { return NSItemProvider() }
        let sources = transferSources(items)
        guard let data = try? WorkflowCanvasTransfer.library(owner: owner, sources: sources).encoded() else { return NSItemProvider() }
        let result = NSItemProvider(); result.suggestedName = t("selected") + " \(sources.count)"
        result.registerDataRepresentation(forTypeIdentifier: UTType.workflowCanvasItem.identifier, visibility: .ownProcess) { completion in completion(data, nil); return nil }
        return result
    }
    private func name(_ item: ContainerItem) -> String {
        item.displayName(assets: controller.availableAssets, metadata: library?.metadata, fallback: t("item") + " \(item.ordinal)")
    }
    private func refresh() {
        if let sources = node.librarySources {
            staticSourceRows = sources.enumerated().map { index, source in
                do {
                    let value = try WorkflowAssetContainer.sourceValues([source], runs: controller.runs)[0]
                    return .init(id: source.key, itemID: source.key, value: value, record: nil, source: source, failure: nil, ordinal: index + 1)
                } catch { return .init(id: source.key, itemID: source.key, value: nil, record: nil, source: nil, failure: error.localizedDescription, ordinal: index + 1, failureCode: (error as? WorkflowIssue)?.code ?? "container.issue.sourceUnavailable") }
            }
        }
        let history = forcedStepID == nil ? controller.history(for: node.id) : controller.runs.filter { $0.planCheckpoint?.records.contains(where: { $0.id == forcedStepID }) == true }
        let records = history.flatMap { run in (run.planCheckpoint?.records ?? []).filter { $0.step.node.id == node.id && $0.step.node.operationID == node.operationID } }
        var seen = Set<String>()
        scopes = records.compactMap { record in
            let stage = controller.batchStages.first { $0.attempts.contains { $0.runID == record.address.runID } }
            let scope = WorkflowContainerScope(stageID: stage?.id, runID: stage == nil ? record.address.runID : nil, path: record.address.path)
            return seen.insert(scope.key).inserted ? scope : nil
        }
        if selectedScope == nil {
            if let forcedStepID, let record = records.first(where: { $0.id == forcedStepID }) {
                selectedScope = scopes.first { scope in scope.path == record.address.path && (scope.runID == record.address.runID || controller.batchStages.first(where: { $0.id == scope.stageID })?.attempts.contains(where: { $0.runID == record.address.runID }) == true) }
            } else { selectedScope = scopes.last }
        }
        if let selectedScope, scopes.contains(where: { $0 == selectedScope }) { snapshot = try? controller.containerSnapshot(selectedScope) }
        else if selectedScope != nil { snapshot = nil; error = .init("Container target changed.", code: "container.stale") }
        else { snapshot = nil }
        let plans = controller.runs.compactMap { $0.planCheckpoint?.plan }
        rows = projectedRows().map { source in
            var item = source
            item.captureAnnotationKey(owner: controller.assetLibraryOwner)
            if let value = item.value, value.asset == nil, value.kind != .text {
                item.concept = value.datum.flatMap(WorkflowInputContract.concept)
                item.producer = item.exactProducer(in: controller.runs)
                let matches = WorkflowValueCompatibility.concreteConsumers(value, plans: plans, tools: controller.tools, language: language)
                    + WorkflowValueCompatibility.consumers(value, language: language)
                var seen = Set<String>()
                item.consumers = Array(matches.filter {
                    [.direct, .conversion].contains($0.result.status) && seen.insert($0.id).inserted
                }.prefix(2))
            }
            return item
        }
        previewSelection.formIntersection(Set(rows.map(\.id)))
    }
    private func toggle(_ item: ContainerItem) {
        guard item.failure == nil, item.value != nil else { return }
        if review, let record = item.record, let input = record.step.inputs["input"] {
            var ids = record.step.containerSelectionDraft ?? []
            if let i = ids.firstIndex(of: item.itemID) { ids.remove(at: i) } else { ids.append(item.itemID) }
            do { try controller.editContainerSelection(call: .init(address: record.address, stepID: record.id), input: input, selectedIDs: ids); refresh() }
            catch { self.error = .init(presenting: error, fallbackCode: "container.issue.actionFailed") }
        } else { if !previewSelection.insert(item.id).inserted { previewSelection.remove(item.id) } }
    }
    private func selectAll(clear: Bool = false, invert: Bool = false) {
        if review, let snapshot {
            do {
                for record in snapshot.calls where record.step.decision == nil && record.step.status == .waiting {
                    guard let input = record.step.inputs["input"] else { continue }
                    let available = try WorkflowAssetContainer.items(in: input).filter(\.selectable).map(\.id)
                    let ids = clear ? [] : invert ? available.filter { !(record.step.containerSelectionDraft ?? []).contains($0) } : available
                    try controller.editContainerSelection(call: .init(address: record.address, stepID: record.id), input: input, selectedIDs: ids)
                }
                refresh()
            } catch { self.error = .init(presenting: error, fallbackCode: "container.issue.actionFailed") }
        } else { previewSelection = clear ? [] : Set(rows.filter { $0.value != nil && $0.failure == nil && (!invert || !previewSelection.contains($0.id)) }.map(\.id)) }
    }
    private func submit(endAll: Bool = false) {
        guard let snapshot else { return }
        let saved = submission, count = repetitions, strategy = seedStrategy
        let choices = snapshot.calls.filter { $0.step.status == .waiting && $0.step.decision == nil }.map {
            WorkflowContainerChoice(call: .init(address: $0.address, stepID: $0.id), selectedIDs: endAll ? [] : $0.step.containerSelectionDraft ?? [])
        }
        Task {
            do {
                let intent: WorkflowContainerSubmission
                if let saved, controller.hasPendingSaves {
                    _ = try await controller.retryContainerSaving(saved.scope); refresh(); return
                }
                if let saved { intent = saved }
                else { intent = try await controller.submitContainer(snapshot, choices: choices, repetitions: count, seedStrategy: strategy, endAll: endAll) }
                if let next = try await controller.continueContainerSubmission(intent) { await controller.runBatchStage(next) }
                else if !endAll && otherWaitingCall == nil { error = .init("Other human gates remain.", code: "container.otherGates") }
                refresh()
            } catch { self.error = .init(presenting: error, fallbackCode: "container.issue.actionFailed") }
        }
    }
    private func retryCollection() async {
        await controller.processCollectionRequests(retryFailed: true) { request in
            guard let folder = request.folderID else { return }
            guard let library, controller.assetLibraryOwner == request.owner else { throw SharedLibraryError.staleAnnotation }
            try library.addMembers(Set(try request.sources.map { try $0.metadataKey(owner: request.owner, runs: controller.runs) }), to: folder)
        }
    }
    private func collect(_ items: [ContainerItem]) {
        guard let owner = controller.assetLibraryOwner else { return }
        var seen = Set<String>()
        let sources = items.compactMap(\.source).filter { seen.insert($0.key).inserted }
        let location = WorkflowLibraryContext(controller: controller, source: .sources(sources), name: node.title)
        Task { do { try await controller.setCollected(sources, collected: true, owner: owner); presentation.collectionLocation = location } catch { self.error = .init(presenting: error, fallbackCode: "container.issue.actionFailed") } }
    }
    private func open(_ item: ContainerItem) {
        guard let model, let value = item.value, model.projectSession.workflow === controller else { return }
        do {
            if case .runtime(let source) = item.source { guard try source.resolve(in: controller.runs) == value else { throw WorkflowIssue("Container source changed.", code: "container.stale") } }
            try model.viewers.open(.init(title: name(item), subtitle: snapshot?.runs.first?.createdAt.formatted() ?? "", value: value, call: { if case .runtime(let source) = item.source { return source.call }; return item.record.map { .init(address: $0.address, stepID: $0.id) } }(), runtimeSource: { if case .runtime(let source) = item.source { return source }; return nil }()), model: model, language: language)
        } catch { self.error = .init(presenting: error, fallbackCode: "container.issue.actionFailed") }
    }
}

/// One visible row's summary. Read through the existing exact Store reader once;
/// release full decoded bytes after validation and retain only bounded display facts.
private struct WorkflowContainerStructuredAssetInfo: View {
    private struct Identity: Hashable {
        let reference: WorkflowAssetReference
        let instanceID: UUID?
        let visible: Bool
    }
    let reference: WorkflowAssetReference
    let controller: WorkflowController
    @Environment(\.dLanguageStore) private var language
    @Environment(\.workbenchContentVisible) private var visible
    @State private var concept: String?
    @State private var producerID: String?
    @State private var receivers: [WorkflowConsumerMatch] = []
    @State private var failure: WorkflowIssue?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(concept.map { WorkflowValueCompatibility.conceptTitle($0, language: language) }
                 ?? WorkflowCanvasPresentation.kind(reference.kind, language: language))
            Text(workflowText(language, "workflow.compatibility.producer") + " · " +
                 (producerID.flatMap { WorkflowRegistry.standard.operation($0) }.map { WorkflowCanvasPresentation.operationTitle($0.definition, language: language) }
                  ?? workflowText(language, "metadata.panel.unknown")))
            ForEach(receivers) { match in
                Text(match.displayTitle(language) + " · " + match.displayPort(language) + " · " + workflowText(language, "workflow.compatibility.status." + match.result.status.rawValue)).lineLimit(2)
            }
            if receivers.isEmpty { Text(workflowText(language, "workflow.compatibility.noReceivers")) }
            if let failure { WorkbenchIssueText(raw: failure.reason, key: failure.code).foregroundStyle(.red) }
        }.font(.caption).foregroundStyle(.secondary)
        .task(id: Identity(reference: reference, instanceID: controller.projectInstanceID, visible: visible)) {
            concept = nil; producerID = nil; receivers = []; failure = nil
            guard visible else { return }
            let owner = controller.assetLibraryOwner
            do {
                let content = try await controller.services.store.readOnlyAsset(id: reference.assetID, reference: reference)
                try Task.checkCancellation()
                guard controller.assetLibraryOwner == owner else { return }
                producerID = content.metadata.record?.operationID
                let decoded = try? JSONDecoder().decode(WorkflowDatum.self, from: content.data)
                if let decoded { try decoded.validate(); concept = WorkflowInputContract.concept(of: decoded) }
                let matches = WorkflowValueCompatibility.concreteConsumers(.asset(reference), decodedAsset: decoded,
                    plans: controller.runs.compactMap { $0.planCheckpoint?.plan }, tools: controller.tools, language: nil)
                    + WorkflowValueCompatibility.consumers(.asset(reference), decodedAsset: decoded, language: nil)
                var seen = Set<String>()
                receivers = Array(matches.filter { [.direct, .conversion].contains($0.result.status) && seen.insert($0.id).inserted }.prefix(2))
            } catch is CancellationError { }
            catch { failure = .init(presenting: error, fallbackCode: "container.issue.sourceUnavailable") }
        }
        .onDisappear { concept = nil; producerID = nil; receivers = []; failure = nil }
    }
}

private struct WorkflowContainerLibraryKey: EnvironmentKey {
    static let defaultValue: SharedLibraryStore? = nil
}
extension EnvironmentValues {
    var workflowContainerLibrary: SharedLibraryStore? {
        get { self[WorkflowContainerLibraryKey.self] }
        set { self[WorkflowContainerLibraryKey.self] = newValue }
    }
}

/// One explicit player per container, shared with its enlarged presentation.
/// Closing, collapsing or hiding the container releases the existing transport.
@MainActor @Observable final class WorkflowContainerPlayback {
    let transport = AudioTransport(recordingEnabled: false)
    private(set) var reference: WorkflowAssetReference?
    private(set) var format: AudioFormatInfo?
    private var generation = UUID()
    func toggle(_ ref: WorkflowAssetReference, controller: WorkflowController) async throws {
        if reference == ref {
            if transport.state == .playing { transport.pause() } else { try transport.play() }
            return
        }
        stop(); let request = generation, owner = controller.assetLibraryOwner
        let (url, asset) = try await controller.services.store.workflowMedia(ref)
        let policy = try await controller.services.store.workflowAudioPlaybackPolicy(ref)
        guard request == generation, controller.assetLibraryOwner == owner, let format = asset.metadata.audio?.format else { return }
        try transport.preparePlayback(url: url, format: format, policy: policy)
        self.reference = ref; self.format = format; try transport.play()
    }
    func stop() { generation = UUID(); transport.shutdown(); reference = nil; format = nil }
}
