import Foundation
import Observation

public struct WorkflowAssetBindingTarget: Sendable, Equatable {
    public let instanceID: UUID
    public let graphID: UUID
    public let revision: UUID
    public let path: [WorkflowBodyLocation]
    public let node: WorkflowNode
}

public struct WorkflowCanvasInsertionTarget: Sendable, Equatable {
    public let projectID: UUID
    public let instanceID: UUID
    public let rootID: UUID?
    public let revision: UUID
    public let bodyID: UUID?
    public let path: [WorkflowBodyLocation]
}

/// Display evidence only; execution admission continues to validate independently.
public enum WorkflowOutputComparison: Equatable, Sendable {
    case matching, changed, missingUpstream
    case unavailable(String)
    public var stale: Bool { self != .matching }
}

public struct WorkflowNodePresentationStatus: Equatable, Sendable {
    public let status: WorkflowStepStatus
    public let comparison: WorkflowOutputComparison
    public var stale: Bool { comparison.stale }
}

/// Coordinates compiled structured workflows; all expensive model work is still admitted by the shared InferenceRuntime.
@MainActor @Observable public final class WorkflowController {
    public let registry: WorkflowRegistry
    public private(set) var pendingPausedStopRunID: UUID?
    public private(set) var containerSubmissions: [WorkflowContainerSubmission] = [] { didSet { contentGeneration &+= 1 } }
    public private(set) var batchStages: [WorkflowBatchStage] = [] { didSet { contentGeneration &+= 1; invalidateContainerStages(oldValue) } }
    public private(set) var batchPauseRequested = false
    public private(set) var activeBatchID: UUID?
    public private(set) var graphs: [WorkflowGraph] = [] {
        didSet { emptyInsertionRevision = UUID(); displayGraphGeneration &+= 1; contentGeneration &+= 1 }
    }
    @ObservationIgnored private var emptyInsertionRevision = UUID()
    public private(set) var runs: [WorkflowRun] = [] { didSet { displayHistoryGeneration &+= 1; contentGeneration &+= 1; invalidateContainerRuns(oldValue) } }
    public private(set) var tools: [WorkflowToolDefinition] = [] { didSet { if oldValue != tools { displayToolGeneration &+= 1 }; contentGeneration &+= 1 } }
    @ObservationIgnored private var activeExecutor: WorkflowPlanExecutor? {
        didSet { if activeExecutor == nil { presentationHasExecutor = false } }
    }
    private var presentationHasExecutor = false
    public var canPausePresentation: Bool {
        guard !batchPauseRequested, !cancelled else { return false }
        if activeBatchID != nil { return isRunning }
        guard presentationHasExecutor, !isSaving, let run = activePresentationRun else { return false }
        return run.status == .running && run.planCheckpoint?.state == .running
    }
    public private(set) var collectionRequests: [WorkflowAssetCollectionRequest] = [] { didSet { contentGeneration &+= 1 } }
    public private(set) var collectingAssets = false
    // Display epochs are owned by this project controller, bounded to its
    // current graph/run identities. They do not authorize any data mutation.
    private var containerNodeEpochs: [UUID: UInt64] = [:]
    private var containerRunEpochs: [UUID: UInt64] = [:]
    private var containerPlanEpoch: UInt64 = 0
    @ObservationIgnored private var containerClock: UInt64 = 0
    public func containerDisplayRevision(for node: WorkflowNode) -> [UInt64] {
        [containerNodeEpochs[node.id] ?? 0, containerPlanEpoch, displayToolGeneration] +
        (node.librarySources ?? []).compactMap { source -> UInt64? in
            guard case .runtime(let ref) = source else { return nil }
            return containerRunEpochs[ref.call.address.runID] ?? 0
        }
    }
    private func containerNodes(_ run: WorkflowRun) -> Set<UUID> {
        Set(run.graph.nodes.map(\.id) + (run.planCheckpoint?.records.map { $0.step.node.id } ?? []))
    }
    private func invalidateContainerRuns(_ old: [WorkflowRun]) {
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        var affected = Set<UUID>()
        for id in Set(previous.keys).union(current.keys) {
            let before = previous[id], after = current[id]
            guard before != after else { continue }
            containerClock &+= 1; containerRunEpochs[id] = containerClock
            if var normalized = after, let before {
                // A waiting selection only changes its own card. All other
                // record/status/provenance changes invalidate the run's cards.
                let priorRecords = Dictionary(uniqueKeysWithValues: (before.planCheckpoint?.records ?? []).map { ($0.id, $0) })
                var draftNodes = Set<UUID>()
                if normalized.planCheckpoint != nil {
                    for i in normalized.planCheckpoint!.records.indices {
                        let record = normalized.planCheckpoint!.records[i]
                        if let prior = priorRecords[record.id] {
                            if record.step.containerSelectionDraft != prior.step.containerSelectionDraft { draftNodes.insert(record.step.node.id) }
                            normalized.planCheckpoint!.records[i].step.containerSelectionDraft = prior.step.containerSelectionDraft
                        }
                    }
                }
                for i in normalized.steps.indices {
                    normalized.steps[i].containerSelectionDraft = before.steps.first { $0.id == normalized.steps[i].id }?.containerSelectionDraft
                }
                if normalized == before { affected.formUnion(draftNodes); continue }
            }
            if let before { affected.formUnion(containerNodes(before)) }
            if let after { affected.formUnion(containerNodes(after)) }
        }
        if old.compactMap({ $0.planCheckpoint?.plan }) != runs.compactMap({ $0.planCheckpoint?.plan }) { containerPlanEpoch &+= 1 }
        containerClock &+= 1
        for id in affected { containerNodeEpochs[id] = containerClock }
        let live = Set(graphs.flatMap { $0.nodes.map(\.id) }).union(runs.reduce(into: Set<UUID>()) { $0.formUnion(containerNodes($1)) })
        containerNodeEpochs = containerNodeEpochs.filter { live.contains($0.key) }
        containerRunEpochs = containerRunEpochs.filter { current[$0.key] != nil }
    }
    private func invalidateContainerStages(_ old: [WorkflowBatchStage]) {
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: batchStages.map { ($0.id, $0) })
        var runIDs = Set<UUID>()
        for id in Set(previous.keys).union(current.keys) where previous[id] != current[id] {
            runIDs.formUnion(previous[id]?.attempts.map(\.runID) ?? [])
            runIDs.formUnion(current[id]?.attempts.map(\.runID) ?? [])
        }
        containerClock &+= 1
        for run in runs where runIDs.contains(run.id) {
            for node in containerNodes(run) { containerNodeEpochs[node] = containerClock }
        }
    }
    public func canEditContainerCall(_ call: WorkflowCallReference) -> Bool { !closed && !closing && activeRunID != call.address.runID }
    public private(set) var assetCollection: WorkflowAssetCollection?
    private var collectionWriting = false
    @ObservationIgnored private var collectionUndo: [WorkflowAssetCollection] = []
    @ObservationIgnored private var collectionRedo: [WorkflowAssetCollection] = []
    public private(set) var availableAssets: [ProjectAsset] = [] { didSet { displayAssetGeneration &+= 1 } }
    public private(set) var displayAssetGeneration: UInt64 = 0
    public var canReadLibraryMetadata: Bool { !closed && !closing }
    public private(set) var projectID: UUID?
    public private(set) var projectInstanceID: UUID?
    public private(set) var assetReferences: [UUID: WorkflowAssetReference] = [:]
    public var canEditLibraryMetadata: Bool { !closed && !closing && !externalOperationBusy() }
    public var canEditCanvas: Bool {
        !closed && !closing && !toolPublicationBusy && !externalOperationBusy() && readOnlyReason == nil &&
        (!isRunning || editingOriginalID != nil) && (graphs.isEmpty || graph != nil)
    }
    public var selectedGraphID: UUID? { didSet { if oldValue != selectedGraphID { bodyPath = []; selectedNodeIDs = [] } } }
    public private(set) var bodyPath: [WorkflowBodyLocation] = []
    public var selectedNodeIDs: Set<UUID> = []
    public var selectedNodeID: UUID?
    public private(set) var isRunning = false
    private var contentGeneration: UInt64 = 0
    private var savedContentGeneration: UInt64 = 0
    @ObservationIgnored private var savingToken = UUID()
    public var savePresentation: String {
        if isSaving { return "saving" }
        if hasSaveFailure { return "failed" }
        if services.hasPendingSaves { return isRunning ? "saving" : "unsaved" }
        return contentGeneration == savedContentGeneration ? "saved" : "unsaved"
    }
    public var hasSaveFailure: Bool {
        persistenceFailed || (services.hasPendingSaves && runs.contains { run in
            run.status == .saving && (run.planCheckpoint?.error != nil || run.steps.contains { $0.status == .saving && $0.error != nil })
        })
    }
    public var pausePendingPresentation: String? {
        guard isRunning, batchPauseRequested, !cancelled, !hasSaveFailure else { return nil }
        return activeBatchID == nil ? "pausePending" : "batchPausePending"
    }
    public private(set) var isSaving = false
    public private(set) var readOnlyReason: String?
    public var errorMessage: String? { didSet { errorCode = nil } }
    public private(set) var errorCode: String?
    public func reportIssue(_ issue: WorkflowIssue) { errorMessage = issue.reason; errorCode = issue.code }
    public var mediaPreviewReference: WorkflowAssetReference?
    /// The existing project recording owner may temporarily reserve interactive work.
    @ObservationIgnored public var externalOperationBusy: () -> Bool = { false }
    public private(set) var streamingText = ""
    public private(set) var streamingStepID: UUID?
    public var activePresentationRun: WorkflowRun? {
        guard isRunning, let activeRunID else { return nil }
        return runs.first { $0.id == activeRunID }
    }
    public var visibleStreamingText: String {
        guard let id = activeRunID, runs.first(where: { $0.id == id })?.graph.id == selectedGraphID else { return "" }
        return streamingText
    }
    public private(set) var progressMessage = "" { didSet { progressPresentation = nil } }
    public private(set) var progressPresentation: WorkflowProgressMessage? = .init("start")
    func setProgress(_ message: WorkflowProgressMessage) { progressMessage = ""; progressPresentation = message }
    public var textModelDescription = "尚未选择文字模型"
    public var imageModelDescription = "尚未选择图像模型"
    public var modelChoices: [WorkflowModelChoice] = []
    public private(set) var destinationDescription = "尚未选择导出目录"
    public var rootGraph: WorkflowGraph? { graphs.first { $0.id == selectedGraphID } }
    public var graph: WorkflowGraph? { rootGraph.flatMap { try? WorkflowGraphEditing.body(in: $0, path: bodyPath) } }
    public var selectedNode: WorkflowNode? { graph?.nodes.first { $0.id == selectedNodeID } }
    public var canUndo: Bool { canEditCanvas && undoStack.last.map(historyPreservesOriginal) == true }
    public var canRedo: Bool { canEditCanvas && redoStack.last.map(historyPreservesOriginal) == true }
    public var hasPendingSaves: Bool { services.hasPendingSaves || persistenceFailed }
    @ObservationIgnored public let services: WorkflowServices
    private struct EditSnapshot { var graphs: [WorkflowGraph]; var tools: [WorkflowToolDefinition] }
    private var editSnapshot: EditSnapshot { .init(graphs: graphs, tools: tools) }
    private var toolPublicationBusy = false
    @ObservationIgnored private var undoStack: [EditSnapshot] = []
    @ObservationIgnored private var redoStack: [EditSnapshot] = []
    @ObservationIgnored private var persistenceFailed = false
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var activeRunID: UUID?
    // Set before execution can suspend; decision-saving operations have no
    // editable execution owner and retain their independent admission rules.
    /// Read-only UI identity; navigation and metadata inspection never create an editing copy.
    public var presentationEditingOriginalID: UUID? { editingOriginalID }
    public var presentationCopySourceID: UUID? { editingCopies.first(where: { $0.value == rootGraph?.id })?.key }
    private var editingOriginalID: UUID?
    @ObservationIgnored private var editingCopies: [UUID: UUID] = [:]
    private var closed = false
    private var closing = false
    @ObservationIgnored private var writeTail: Task<Void, Error>?
    // Internal fault injection at the actual history transaction, used only by CPU tests.
    @ObservationIgnored var beforeHistorySave: () throws -> Void = {}
    @ObservationIgnored var beforeCollectionRequestCommit: () async throws -> Void = {}
    @ObservationIgnored var beforeContainerDecisionCommit: () async throws -> Void = {}
    @ObservationIgnored var batchSeedSource: () -> UInt64 = { UInt64.random(in: UInt64.min...UInt64.max) }
    // Controlled suspension/failure at the real asset-to-graph handoff in CPU tests.
    @ObservationIgnored var afterTextPublication: () async throws -> Void = {}
    @ObservationIgnored public var onChange: @MainActor () async -> Void = {}

    public init(services: WorkflowServices, registry: WorkflowRegistry = .standard) {
        self.services = services; self.registry = registry
        services.progress = { [weak self] in self?.progressMessage = $0 }
        services.progressEvent = { [weak self] in self?.setProgress($0) }
        services.languagePreviewChanged = { [weak self] stepID, text in
            guard let self, self.isRunning, self.activeRunID != nil, !self.closed, !self.closing else { return }
            self.streamingStepID = text.isEmpty ? nil : stepID
            self.streamingText = text
        }
        services.candidatesChanged = { [weak self] stepID, items in
            guard let self, let executor = self.activeExecutor else { throw WorkflowIssue("图像进度没有当前执行所有者。") }
            do { try await executor.updateCandidates(stepID: stepID, candidates: items) }
            catch { throw WorkflowSaveFailure(reason: error.localizedDescription) }
        }
    }
    public func load() async {
        do {
            let state = try await services.store.workflowState()
            readOnlyReason = state.readOnlyReason
            guard let archive = state.archive else { return }
            graphs = archive.graphs; runs = archive.runs; tools = archive.tools ?? []; batchStages = archive.batchStages ?? []; containerSubmissions = archive.containerSubmissions ?? []; collectionRequests = archive.collectionRequests ?? []
            savedContentGeneration = contentGeneration
            let batchRunIDs = Set(batchStages.flatMap(\.attempts).map(\.runID))
            for ri in runs.indices where batchRunIDs.contains(runs[ri].id) {
                guard var cp = runs[ri].planCheckpoint, cp.state == .saving,
                      cp.records.contains(where: { $0.step.status == .saving && $0.step.node.control == nil }) else { continue }
                // In-memory unpublished bytes cannot be reconstructed after a process exit.
                // Preserve partial evidence and require a newly authorized attempt.
                cp.state = .interrupted; cp.error = "上次未发布的结果不可恢复；原记录保留，未重新计算。"
                for ci in cp.records.indices where cp.records[ci].step.status == .saving {
                    cp.records[ci].step.status = .interrupted; cp.records[ci].step.error = cp.error
                }
                capture(cp, runIndex: ri)
            }
            for si in batchStages.indices {
                if batchStages[si].state == .running { batchStages[si].state = .paused }
                for ai in batchStages[si].attempts.indices where [.dispatched, .savingBlocked].contains(batchStages[si].attempts[ai].state) {
                    guard let run = runs.first(where: { $0.id == batchStages[si].attempts[ai].runID }) else { continue }
                    let state = batchAttemptState(run)
                    batchStages[si].attempts[ai].state = state == .queued ? .interrupted : state
                }
                if batchStages[si].attempts.contains(where: { $0.state == .savingBlocked }), batchStages[si].state != .cancelled { batchStages[si].state = .savingBlocked }
                else if !batchStages[si].attempts.contains(where: { [.queued, .dispatched, .interrupted].contains($0.state) }), batchStages[si].state != .cancelled { batchStages[si].state = .finished }
            }
            await refreshAssets()
            // Interrupted processes are never silently restarted. Waiting decisions remain valid.
            let unstartedBatchRuns = Set(batchStages.flatMap(\.attempts).filter { $0.state == .queued }.map(\.runID))
            for i in runs.indices where [.running, .queued, .cancelling].contains(runs[i].status) && !unstartedBatchRuns.contains(runs[i].id) {
                runs[i].status = .interrupted
                if var checkpoint = runs[i].planCheckpoint {
                    checkpoint.state = .interrupted
                    for j in checkpoint.records.indices where [.running, .queued, .cancelling].contains(checkpoint.records[j].step.status) {
                        checkpoint.records[j].step.status = .interrupted
                        checkpoint.records[j].step.error = "上次进程已停止；未自动重新计算。"
                    }
                    runs[i].planCheckpoint = checkpoint
                }
                for j in runs[i].steps.indices where [.running, .queued, .cancelling].contains(runs[i].steps[j].status) {
                    runs[i].steps[j].status = .interrupted
                    runs[i].steps[j].error = "上次进程已停止；未自动重新计算。"
                }
            }
            selectedGraphID = graphs.first?.id; selectedNodeID = graph?.nodes.first?.id
        } catch { readOnlyReason = error.localizedDescription; errorMessage = error.localizedDescription }
    }
    public func prepareForClose() async throws {
        guard !isRunning, !toolPublicationBusy, !collectionWriting, !collectingAssets, !services.hasPendingSaves else { throw WorkflowIssue("请先取消运行或恢复待保存结果。") }
        closing = true
        do { if readOnlyReason == nil { try await persist() } }
        catch { closing = false; throw error }
    }
    public func cancelClosing() { closing = false }
    public func deactivateAfterClose() { closed = true; closing = false }
    public func close() async throws { try await prepareForClose(); deactivateAfterClose() }
    public func setDestination(_ url: URL) { services.destination = url; destinationDescription = url.lastPathComponent }
    public func preview(_ ref: WorkflowAssetReference) async throws -> Data {
        if ref.kind == .text { return Data(try await services.store.workflowText(ref).utf8) }
        return try await services.store.workflowData(ref)
    }
    public func metadata(_ ref: WorkflowAssetReference) async throws -> String {
        let state = try await services.store.workflowState()
        guard let record = state.archive?.assets.first(where: { $0.reference == ref }) else { throw WorkflowIssue("来源记录不存在。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }
    public func libraryKind(of asset: ProjectAsset) -> WorkflowDataKind? { WorkflowMediaFormat.descriptor(asset.mediaType)?.kind }
    /// File operations may publish assets outside this controller. Keep the live graph and edit state intact.
    public func refreshAvailableAssets(instanceID: UUID) async {
        guard !closed, projectInstanceID == instanceID else { return }
        let snapshot = await services.store.snapshot()
        guard !closed, projectInstanceID == instanceID,
              snapshot.effectiveInstanceID == instanceID,
              snapshot.id == projectID else { return }
        availableAssets = snapshot.assets.filter { WorkflowMediaFormat.descriptor($0.mediaType) != nil }
    }
    public func saveAssetAnnotations(expected: ProjectAssetEditBaseline, name: String?, note: String?, isFavorite: Bool?) async throws {
        guard canEditLibraryMetadata, projectID == expected.projectID, projectInstanceID == expected.instanceID else {
            throw WorkflowIssue("作品所属实例已改变，草稿未提交。")
        }
        _ = try await services.store.updateAsset(id: expected.assetID, name: name, note: note, isFavorite: isFavorite, expected: expected)
        guard !closed, projectInstanceID == expected.instanceID else { throw WorkflowIssue("注释已写入原实例，请重新打开原作品查看。") }
        await refreshAvailableAssets(instanceID: expected.instanceID); await onChange()
    }

    private func refreshAssets() async {
        let snapshot = await services.store.snapshot()
        projectID = snapshot.id
        projectInstanceID = snapshot.effectiveInstanceID
        availableAssets = snapshot.assets.filter { WorkflowMediaFormat.descriptor($0.mediaType) != nil }
        assetReferences = [:]
        do {
            let state = try await services.store.workflowState()
            if let reason = state.readOnlyReason { errorMessage = reason; return }
            if let archive = state.archive {
                assetCollection = archive.assetCollection
                assetReferences = Dictionary(archive.assets.map { ($0.reference.assetID, $0.reference) }, uniquingKeysWith: { _, last in last })
            }
        } catch { errorMessage = error.localizedDescription }
    }
    /// First visit captures legacy visibility once. No graph, run or asset bytes are rewritten.
    public func initializeAssetCollection() async {
        guard !closed, !closing, readOnlyReason == nil, !collectionWriting else { return }
        collectionWriting = true; defer { collectionWriting = false }
        do { assetCollection = try await services.store.initializeAssetCollection(); await refreshAssets() }
        catch { errorMessage = error.localizedDescription }
    }
    public var assetLibraryOwner: WorkflowAssetLibraryOwner? {
        guard let projectID, let projectInstanceID else { return nil }
        return .init(projectID: projectID, instanceID: projectInstanceID)
    }
    public func isCollected(_ source: WorkflowLibrarySource) -> Bool {
        guard let assetCollection else { return false }
        if case .asset(let reference) = source, let asset = availableAssets.first(where: { $0.id == reference.assetID }) {
            return assetCollection.contains(asset: asset)
        }
        return assetCollection.contains(source)
    }
    public func setCollected(_ sources: [WorkflowLibrarySource], collected: Bool, owner: WorkflowAssetLibraryOwner) async throws {
        guard assetLibraryOwner == owner, canEditLibraryMetadata, !collectionWriting, readOnlyReason == nil, let baseline = assetCollection else {
            throw WorkflowIssue("Project asset library is not ready.", code: "container.issue.targetChanged")
        }
        collectionWriting = true; defer { collectionWriting = false }
        let project = projectID, instance = projectInstanceID
        for source in sources {
            if case .asset(let reference) = source { try await services.verifyAsset(reference) }
        }
        guard canEditLibraryMetadata, projectID == project, projectInstanceID == instance, assetCollection == baseline else {
            throw WorkflowIssue("Asset collection target changed.", code: "container.issue.targetChanged")
        }
        let next = try await services.store.setAssetCollection(sources, collected: collected, expected: baseline)
        if next != baseline {
            collectionUndo.append(baseline); if collectionUndo.count > 50 { collectionUndo.removeFirst() }
            collectionRedo.removeAll(); assetCollection = next
        }
        await onChange()
    }
    public var canUndoCollection: Bool { !collectionUndo.isEmpty && canEditLibraryMetadata && !collectionWriting }
    public var canRedoCollection: Bool { !collectionRedo.isEmpty && canEditLibraryMetadata && !collectionWriting }
    public func undoCollection() async throws {
        guard canUndoCollection, let prior = collectionUndo.last, let current = assetCollection else { return }
        collectionWriting = true; defer { collectionWriting = false }
        try await services.store.replaceAssetCollection(prior, expected: current)
        collectionUndo.removeLast(); collectionRedo.append(current); assetCollection = prior; await onChange()
    }
    public func redoCollection() async throws {
        guard canRedoCollection, let next = collectionRedo.last, let current = assetCollection else { return }
        collectionWriting = true; defer { collectionWriting = false }
        try await services.store.replaceAssetCollection(next, expected: current)
        collectionRedo.removeLast(); collectionUndo.append(current); assetCollection = next; await onChange()
    }
    @discardableResult
    public func setCollectionRule(_ rule: WorkflowAssetCollectionRule?, nodeID: UUID, target: WorkflowCanvasInsertionTarget) -> WorkflowCanvasInsertionTarget? {
        guard isCurrent(target), let node = graph?.nodes.first(where: { $0.id == nodeID }),
              [WorkflowAssetContainer.filterID, WorkflowAssetContainer.previewID].contains(node.operationID) else { return nil }
        if node.collectionRule == rule { return target }
        guard edit({ graph in guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }; graph.nodes[index].collectionRule = rule }) else { return nil }
        return canvasInsertionTarget()
    }
    private func registerCollectionEvents(_ records: [WorkflowPlanCallRecord], previous: [WorkflowPlanCallRecord]) {
        guard let owner = assetLibraryOwner else { return }
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for record in records {
            do {
                guard let request = try WorkflowAssetCollectionRequest.event(record, previous: before[record.id], owner: owner),
                      !collectionRequests.contains(where: { $0.id == request.id }) else { continue }
                // At most one intent per retained frozen call. The existing archive
                // run/call limits bound this project-owned ledger; pending entries
                // are never discarded to satisfy an unrelated cache quota.
                collectionRequests.append(request)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    @discardableResult public func requestCollection(_ sources: [WorkflowLibrarySource], owner: WorkflowAssetLibraryOwner,
        folderID: UUID?, requestID: UUID) async throws -> String {
        guard assetLibraryOwner == owner, canEditLibraryMetadata, readOnlyReason == nil,
              !sources.isEmpty, Set(sources.map(\.key)).count == sources.count else { throw WorkflowIssue("Collection target changed.", code: "container.issue.targetChanged") }
        let request = try WorkflowAssetCollectionRequest(trigger: "manual:" + requestID.uuidString, owner: owner,
            sources: sources, folderID: folderID, manualID: requestID)
        if let existing = collectionRequests.first(where: { $0.id == request.id }) {
            guard existing.owner == owner, existing.sources == sources, existing.folderID == folderID else { throw WorkflowIssue("Collection request identity was reused.", code: "container.issue.targetChanged") }
            return existing.id
        }
        guard collectionRequests.filter({ $0.manualID != nil && !$0.completed }).count < 256 else { throw WorkflowIssue("Retry pending collection requests before adding more.", code: "container.issue.collectionLimit") }
        let values = try WorkflowAssetContainer.sourceValues(sources, runs: runs)
        for value in values { for ref in WorkflowAssetContainer.references(in: value) { try await services.verifyAsset(ref) } }
        guard assetLibraryOwner == owner, canEditLibraryMetadata else { throw WorkflowIssue("Collection owner changed.", code: "container.issue.targetChanged") }
        try await beforeCollectionRequestCommit()
        // Verification suspends. Revalidate identity, capacity and frozen values
        // after the last await, before publishing this durable organization intent.
        _ = try WorkflowAssetContainer.sourceValues(sources, runs: runs)
        if let existing = collectionRequests.first(where: { $0.id == request.id }) {
            guard existing.owner == owner, existing.sources == sources, existing.folderID == folderID else { throw WorkflowIssue("Collection request identity was reused.", code: "container.issue.targetChanged") }
            return existing.id
        }
        guard collectionRequests.filter({ $0.manualID != nil && !$0.completed }).count < 256 else { throw WorkflowIssue("Retry pending collection requests before adding more.", code: "container.issue.collectionLimit") }
        let completed = collectionRequests.filter { $0.manualID != nil && $0.completed }.map(\.id)
        if completed.count > 128 { let remove = Set(completed.prefix(completed.count - 128)); collectionRequests.removeAll { remove.contains($0.id) } }
        collectionRequests.append(request); try await persist(); return request.id
    }
    // The existing UI task observes readiness so a save/organization write
    // releasing ownership wakes pending work; no timer or second queue.
    public var collectionDrainReady: Bool {
        !isRunning && !isSaving && !hasPendingSaves && !collectionWriting && !closed && !closing
    }
    public func processCollectionRequests(retryFailed: Bool = false,
        classify: @MainActor (WorkflowAssetCollectionRequest) async throws -> Void) async {
        guard collectionDrainReady, !collectingAssets else { return }
        collectingAssets = true; defer { collectingAssets = false }
        var attempted: Set<String> = []
        // A new request can arrive while classification suspends. The active
        // owner drains it too; failed requests are attempted only once per call.
        // A SwiftUI task-ID cancellation is not a user cancel of this ledger.
        while collectionDrainReady, let request = collectionRequests.first(where: {
            !$0.completed && !attempted.contains($0.id) && (retryFailed || $0.error == nil)
        }) {
            attempted.insert(request.id)
            var failureCode = "container.issue.collectionSavePending"
            do {
                guard assetLibraryOwner == request.owner else { throw WorkflowIssue("Collection belongs to another project instance.", code: "container.issue.targetChanged") }
                try await setCollected(request.sources, collected: true, owner: request.owner)
                failureCode = "container.issue.collectionClassifyPending"
                try await classify(request)
                failureCode = "container.issue.collectionAckPending"
                guard let current = collectionRequests.firstIndex(where: { $0.id == request.id }),
                      collectionRequests[current].sources == request.sources, collectionRequests[current].owner == request.owner else { throw WorkflowIssue("Collection request changed while saving.", code: "container.issue.targetChanged") }
                collectionRequests[current].completed = true; collectionRequests[current].error = nil; collectionRequests[current].errorCode = nil
                let completedManual = collectionRequests.filter { $0.manualID != nil && $0.completed }.map(\.id)
                if completedManual.count > 128 {
                    let remove = Set(completedManual.filter { $0 != request.id }.prefix(completedManual.count - 128))
                    collectionRequests.removeAll { remove.contains($0.id) }
                }
                try await persist()
            } catch {
                guard let current = collectionRequests.firstIndex(where: { $0.id == request.id }), collectionRequests[current].sources == request.sources else { errorMessage = error.localizedDescription; break }
                collectionRequests[current].completed = false; collectionRequests[current].error = error.localizedDescription; collectionRequests[current].errorCode = failureCode
                do { try await persist() } catch { errorMessage = error.localizedDescription; break }
            }
        }
    }
    public func bindExistingAsset(_ id: UUID, nodeID: UUID) async {
        guard canEditCanvas else { return }
        guard let target = assetBindingTarget(nodeID: nodeID) else { return }
        do {
            let ref = try await services.store.pinWorkflowAsset(id)
            guard canEditCanvas, isCurrent(target) else { throw WorkflowIssue("流程或输入节点已改变；素材未绑定到另一位置。") }
            attach(ref, nodeID: nodeID)
            guard graph?.nodes.first(where: { $0.id == nodeID })?.assetReference == ref else { throw WorkflowIssue("素材已保存，但节点未绑定；请在当前编辑副本中重新选择。") }
            try await persist()
        } catch { errorMessage = error.localizedDescription }
    }
    public func assetBindingTarget(nodeID: UUID) -> WorkflowAssetBindingTarget? {
        guard !closed, !closing, readOnlyReason == nil, let root = rootGraph,
              let node = graph?.nodes.first(where: { $0.id == nodeID }),
              registry.operation(node.operationID)?.definition.interaction == .assetInput else { return nil }
        guard let projectInstanceID else { return nil }
        return .init(instanceID: projectInstanceID, graphID: root.id, revision: root.revision, path: bodyPath, node: node)
    }
    public func isCurrent(_ target: WorkflowAssetBindingTarget) -> Bool {
        !closed && !closing && readOnlyReason == nil && projectInstanceID == target.instanceID && rootGraph?.id == target.graphID &&
        rootGraph?.revision == target.revision && bodyPath == target.path &&
        graph?.nodes.first(where: { $0.id == target.node.id }) == target.node
    }
    public func bindRecordedAsset(_ id: UUID, target: WorkflowAssetBindingTarget) async {
        guard canEditCanvas, isCurrent(target) else {
            errorMessage = "录音已保存，但原输入位置已改变或当前不可编辑；请从项目素材中重新选择。"
            if !closed, !closing { await refreshAvailableAssets(instanceID: target.instanceID); await onChange() }
            return
        }
        do {
            let ref = try await services.store.pinWorkflowAsset(id)
            guard canEditCanvas, isCurrent(target), ref.kind == .audio else { throw WorkflowIssue("录音已保存，但原输入位置已改变；请从项目素材中重新选择。") }
            attach(ref, nodeID: target.node.id)
            guard graph?.nodes.first(where: { $0.id == target.node.id })?.assetReference == ref else { throw WorkflowIssue("录音已保存，但节点未绑定；请重新选择。") }
            try await persist(); await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    public func toggleCollapsed(_ id: UUID) {
        edit({ g in if let i = g.layout.firstIndex(where: { $0.nodeID == id }) { g.layout[i].collapsed.toggle() } }, changesConfiguration: false)
    }

    public func editReviewText(stepID: UUID, text: String) {
        // Editing a waiting draft is safe during another run: execute() never
        // consumes an undecided waiting step, and acceptance still requires idle.
        guard !closed, !closing, readOnlyReason == nil,
              let ri = runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } || $0.planCheckpoint?.records.contains { $0.id == stepID } == true }),
              let step = runs[ri].planCheckpoint?.records.first(where: { $0.id == stepID })?.step ?? runs[ri].steps.first(where: { $0.id == stepID }),
              belongsToSelectedWorkflow(runs[ri]),
              registry.operation(step.node.operationID)?.definition.interaction == .textReview,
              step.status == .waiting, step.decision == nil else { return }
        do {
            try TextDraftDocument.validate(text)
            if let si = runs[ri].steps.firstIndex(where: { $0.id == stepID }) { runs[ri].steps[si].reviewTextDraft = text }
            if let ci = runs[ri].planCheckpoint?.records.firstIndex(where: { $0.step.id == stepID }) { runs[ri].planCheckpoint?.records[ci].step.reviewTextDraft = text }
        } catch { errorMessage = "确认草稿未改变：\(error.localizedDescription)" }
    }

    @discardableResult
    private func edit(_ action: (inout WorkflowGraph) throws -> Void, changesConfiguration: Bool = true) -> Bool {
        guard canEditCanvas, let selectedIndex = graphs.firstIndex(where: { $0.id == selectedGraphID }) else { return false }
        do {
            let before = editSnapshot
            let originalID = graphs[selectedIndex].id
            let forksOriginal = isRunning && editingOriginalID == originalID
            let path = bodyPath, selection = selectedNodeIDs
            if forksOriginal, let copyID = editingCopies[originalID],
               let copy = graphs.first(where: { $0.id == copyID }) {
                // An action captured from the original must never overwrite an
                // existing draft. Open it explicitly; the user can retry there.
                selectedGraphID = copy.id
                if (try? WorkflowGraphEditing.body(in: copy, path: path)) != nil { bodyPath = path }
                selectedNodeIDs = selection.intersection(Set(graph?.nodes.map(\.id) ?? []))
                if graph?.nodes.contains(where: { $0.id == selectedNodeID }) != true { selectedNodeID = nil }
                errorMessage = "此运行已有编辑副本，已打开；请在副本中重试修改。"
                return false
            }
            let index = selectedIndex
            let body = try WorkflowGraphEditing.body(in: graphs[index], path: path)
            var value = body
            try action(&value)
            guard value != body else { return false }
            if changesConfiguration { value.revision = UUID() }
            try registry.validate(value, tools: tools)
            var replacement = try WorkflowGraphEditing.replacingBody(in: graphs[index], path: path, with: value)
            undoStack.append(before); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack = []
            if forksOriginal {
                replacement.id = UUID(); replacement.revision = UUID()
                replacement.name += " · 编辑副本"
                editingCopies[originalID] = replacement.id
                graphs.append(replacement)
            } else { graphs[index] = replacement }
            if forksOriginal {
                selectedGraphID = replacement.id; bodyPath = path
                selectedNodeIDs = selection.intersection(Set(value.nodes.map(\.id)))
                setProgress(.init("editingCopy"))
            }
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func historyPreservesOriginal(_ candidate: EditSnapshot) -> Bool {
        guard isRunning, let id = editingOriginalID else { return true }
        let original = graphs.filter { $0.id == id }, proposed = candidate.graphs.filter { $0.id == id }
        return original.count == 1 && proposed == original
    }
    private func applyHistory(_ snapshot: EditSnapshot) {
        let value = snapshot.graphs
        // Published runs keep their immutable definitions even when an edit is undone.
        let retained = WorkflowToolRegistration.referencedTools(in: value + runs.map(\.graph), tools: tools)
        tools = snapshot.tools + retained.filter { tool in !snapshot.tools.contains { $0.id == tool.id && $0.version == tool.version } }
        let previous = selectedGraphID, path = bodyPath
        graphs = value
        if let original = editingOriginalID, previous == original, let copy = editingCopies[original], value.contains(where: { $0.id == copy }) {
            selectedGraphID = copy
        } else if !value.contains(where: { $0.id == previous }) {
            selectedGraphID = value.first(where: { $0.id == editingOriginalID })?.id ?? value.first?.id
        }
        if let rootGraph, (try? WorkflowGraphEditing.body(in: rootGraph, path: path)) != nil { bodyPath = path } else { bodyPath = [] }
        if graph?.nodes.contains(where: { $0.id == selectedNodeID }) != true { selectedNodeID = nil }
        selectedNodeIDs.formIntersection(Set(graph?.nodes.map(\.id) ?? []))
    }
    private func editingRootID(for run: WorkflowRun) -> UUID? {
        var current = run, seen: Set<UUID> = []
        while let parent = current.scope?.originCall?.address.runID {
            guard seen.insert(current.id).inserted, let value = runs.first(where: { $0.id == parent }) else { return nil }
            current = value
        }
        return graphs.contains(where: { $0.id == current.graph.id }) ? current.graph.id : nil
    }
    public func openBody(nodeID: UUID, slot: String) {
        // Navigation does not edit the frozen run or create an editing copy.
        // Actual changes still pass through edit's original/copy ownership checks.
        guard !closed, !closing, !externalOperationBusy(), let rootGraph else { return }
        do {
            let path = bodyPath + [.init(nodeID: nodeID, slot: slot)]
            let body = try WorkflowGraphEditing.body(in: rootGraph, path: path)
            bodyPath = path; selectedNodeID = body.nodes.first?.id; selectedNodeIDs = []
        } catch { errorMessage = error.localizedDescription }
    }
    public func closeBody() {
        guard !closed, !closing, !externalOperationBusy(), let rootGraph,
              (try? WorkflowGraphEditing.body(in: rootGraph, path: bodyPath)) != nil,
              let location = bodyPath.last else { return }
        bodyPath.removeLast(); selectedNodeID = location.nodeID; selectedNodeIDs = []
    }
    public func updateNode(_ node: WorkflowNode, in graphID: UUID) {
        guard graph?.id == graphID else { errorMessage = "编辑目标已切换。"; return }
        edit { graph in
            guard let index = graph.nodes.firstIndex(where: { $0.id == node.id }), graph.nodes[index].operationID == node.operationID else {
                throw WorkflowIssue("编辑节点已改变。")
            }
            graph.nodes[index] = node
        }
    }
    public func updateInterface(_ interface: WorkflowGraphInterface?, in graphID: UUID) {
        guard graph?.id == graphID else { return }
        edit { $0.interface = interface }
    }
    public func extractSelection(name: String, inputs: [WorkflowToolInputBinding], outputs: [WorkflowNamedOutput], expectedGraphID: UUID, expectedRevision: UUID) {
        guard canEditCanvas, !isRunning, !toolPublicationBusy, let graph,
              graph.id == expectedGraphID, graph.revision == expectedRevision else { errorMessage = "封装期间原图已改变；请重新检查边界。"; return }
        do {
            let result = try WorkflowToolEditing.extract(graph, selected: selectedNodeIDs, name: name, inputs: inputs, outputs: outputs, tools: tools, registry: registry)
            let oldTools = tools; let before = editSnapshot; tools.append(result.tool)
            edit { $0 = result.graph }
            if self.graph?.nodes.contains(where: { $0.id == result.invocationID }) != true { tools = oldTools; return }
            if !undoStack.isEmpty { undoStack[undoStack.count - 1] = before }
            selectedNodeID = result.invocationID; selectedNodeIDs = []
        } catch { errorMessage = error.localizedDescription }
    }
    public func publishSelection(name: String, registration: WorkflowToolRegistration,
                                 inputs: [WorkflowToolInputBinding], outputs: [WorkflowNamedOutput],
                                 expectedGraphID: UUID, expectedRevision: UUID) async throws {
        guard canEditCanvas, !isRunning, !isSaving, !hasPendingSaves, let body = graph,
              body.id == expectedGraphID, body.revision == expectedRevision, let root = rootGraph,
              let index = graphs.firstIndex(where: { $0.id == root.id }) else {
            throw WorkflowIssue("封装目标已改变或正在保存；草稿保留，请重新检查边界。")
        }
        let result = try WorkflowToolEditing.extract(body, selected: selectedNodeIDs, name: name,
            inputs: inputs, outputs: outputs, tools: tools, registry: registry, registration: registration)
        let path = bodyPath
        var next = graphs
        next[index] = try WorkflowGraphEditing.replacingBody(in: root, path: path, with: result.graph)
        try await commitToolPublication(graphs: next, tools: tools + [result.tool])
        if selectedGraphID == root.id, bodyPath == path { selectedNodeID = result.invocationID; selectedNodeIDs = [] }
        errorMessage = nil; setProgress(.init("toolSaved"))
        await onChange()
    }

    private func commitToolPublication(graphs next: [WorkflowGraph], tools nextTools: [WorkflowToolDefinition]) async throws {
        let before = editSnapshot, capturedRuns = runs, batches = batchStages
        toolPublicationBusy = true; isSaving = true
        defer { toolPublicationBusy = false; isSaving = false }
        if let writeTail { try await writeTail.value }
        let state = try await services.store.workflowState()
        guard let archive = state.archive else { throw WorkflowIssue(state.readOnlyReason ?? "项目只读。") }
        try beforeHistorySave()
        _ = try await services.store.saveWorkflow(graphs: next, runs: capturedRuns,
            expectedRevision: archive.revision, tools: nextTools, batchStages: batches.isEmpty ? nil : batches)
        undoStack.append(before); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack = []
        tools = nextTools; graphs = next
        if runs == capturedRuns && batchStages == batches { savedContentGeneration = contentGeneration }
    }

    public func publishGraphTool(name: String, registration: WorkflowToolRegistration,
                                 expectedGraphID: UUID, expectedRevision: UUID) async throws {
        guard canEditCanvas, !isRunning, !isSaving, !hasPendingSaves, let current = graph,
              current.id == expectedGraphID, current.revision == expectedRevision,
              let interface = current.interface, !interface.outputs.isEmpty else { throw WorkflowIssue("流程或公开接口已改变；草稿保留。") }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 256 else { throw WorkflowIssue("名称不能为空或过长。") }
        try registration.validate(interface: interface)
        var body = current; body.toolSource = nil
        var tool = WorkflowToolDefinition(name: title, graph: body, registration: registration)
        if let source = current.toolSource {
            guard let original = tools.first(where: { $0.id == source.id && $0.version == source.version }),
                  try WorkflowPlanCompiler.digest(original) == source.digest else { throw WorkflowIssue("原工具版本或摘要已改变。") }
            let latest = tools.filter { $0.id == source.id }.map(\.version).max() ?? source.version
            guard latest < 1_000_000 else { throw WorkflowIssue("工具版本超过预算。") }
            tool.id = source.id; tool.version = latest + 1
        }
        _ = try WorkflowPlanCompiler(registry: registry).compile(body, tools: tools + [tool])
        try await commitToolPublication(graphs: graphs, tools: tools + [tool])
        errorMessage = nil; setProgress(.init("toolVersionSaved")); await onChange()
    }

    public func addTool(_ tool: WorkflowToolDefinition, x: Double = 160, y: Double = 160) {
        guard canEditCanvas, x.isFinite, y.isFinite,
              let definition = registry.operation("d.control.invoke")?.definition else { return }
        do {
            guard tools.contains(tool), let interface = tool.graph.interface else { throw WorkflowIssue("工具版本不在项目中。") }
            var node = definition.makeNode(); node.title = tool.name
            node.control = .invoke(.init(id: tool.id, version: tool.version, digest: try WorkflowPlanCompiler.digest(tool)))
            node.dataConfiguration = .init(fields: interface.inputs)
            let createdGraph = graph == nil
            if createdGraph { addBlankGraph() }
            edit { $0.nodes.append(node); $0.layout.append(.init(nodeID: node.id, x: x, y: y)) }
            if graph?.nodes.contains(where: { $0.id == node.id }) == true {
                if createdGraph { _ = undoStack.popLast() }
                selectedNodeID = node.id
            }
        } catch { errorMessage = error.localizedDescription }
    }
    public func openToolCopy(_ reference: WorkflowToolReference) {
        guard canEditCanvas, !isRunning, !toolPublicationBusy,
              let tool = tools.first(where: { $0.id == reference.id && $0.version == reference.version }) else { return }
        do {
            guard try WorkflowPlanCompiler.digest(tool) == reference.digest else { throw WorkflowIssue("工具内容与引用不一致。") }
            var draft = WorkflowToolEditing.editableCopy(of: tool); draft.toolSource = reference
            undoStack.append(editSnapshot); redoStack = []; graphs.append(draft); selectedGraphID = draft.id; selectedNodeID = draft.nodes.first?.id
        } catch { errorMessage = error.localizedDescription }
    }
    public func saveGraphAsTool(name: String) {
        guard canEditCanvas, !isRunning, !toolPublicationBusy, let graph else { return }
        do {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf8.count <= 256, !tools.contains(where: { $0.name == title }), graph.interface?.outputs.isEmpty == false else { throw WorkflowIssue("请填写唯一名称，并在公开接口中指定输出。") }
            let tool = WorkflowToolDefinition(name: title, graph: graph)
            _ = try WorkflowPlanCompiler(registry: registry).compile(graph, tools: tools + [tool])
            undoStack.append(editSnapshot); redoStack = []; tools.append(tool); setProgress(.init("toolAdded"))
        } catch { errorMessage = error.localizedDescription }
    }
    public func addBlankGraph(name: String = "新流程") {
        guard canEditCanvas else { return }
        let next = WorkflowGraph(name: name)
        undoStack.append(editSnapshot); redoStack = []; graphs.append(next)
        selectedGraphID = next.id; selectedNodeID = nil
    }
    public func addNode(operationID: String, modelID: String? = nil, x: Double? = nil, y: Double? = nil) {
        guard canEditCanvas else { return }
        guard let op = registry.operation(operationID) else { errorMessage = "未知操作。"; return }
        if let modelID {
            guard let kind = op.definition.modelKind,
                  modelChoices.contains(where: { $0.id == modelID && $0.kind == kind })
                    || WorkflowModelRoutes.draftChoice(operationID: operationID, modelID: modelID)?.kind == kind else {
                errorMessage = "此模型身份与操作不匹配，且不是受支持的目录草稿。"; return
            }
        }
        guard x?.isFinite != false, y?.isFinite != false else { return }
        let createdGraph = graph == nil
        if createdGraph { addBlankGraph() }
        var node = op.definition.makeNode()
        if WorkflowModelRoutes.isLanguage(operationID) { node.dataConfiguration = .init(schema: .text) }
        if let modelID { node.parameters["modelID"] = .text(modelID) }
        edit { graph in
            graph.nodes.append(node)
            graph.layout.append(.init(nodeID: node.id,
                x: x ?? (80 + Double(graph.nodes.count % 5) * 250),
                y: y ?? (100 + Double(graph.nodes.count / 5) * 210)))
        }
        if graph?.nodes.contains(where: { $0.id == node.id }) == true {
            // New graph plus its first node is one user insertion, not two undo steps.
            if createdGraph { _ = undoStack.popLast() }
            selectedNodeID = node.id
        }
    }

    /// Copy explicit settings and input snapshots; no runner is invoked by this command.
    public func insertQuickSettings(_ draft: QuickDraft, target: WorkflowCanvasInsertionTarget) async throws {
        guard isCurrent(target), target.rootID != nil else { throw WorkflowIssue("目标流程已改变，未添加到其他流程。") }
        try registry.validate(draft.node)
        var model = draft.node; model.id = UUID()
        var inputs: [(WorkflowNode, String)] = []
        for (port, value) in draft.inputs.sorted(by: { $0.key < $1.key }) {
            guard let datum = value.datum, let definition = registry.operation("d.value.input")?.definition else {
                throw WorkflowIssue("此输入必须先选择单项结果，不能隐式转换。")
            }
            var node = definition.makeNode(); node.title = port
            node.dataConfiguration = .init(value: datum)
            inputs.append((node, port))
        }
        guard edit({ graph in
            graph.nodes.append(model)
            graph.layout.append(.init(nodeID: model.id, x: 400, y: 100))
            for (index, input) in inputs.enumerated() {
                graph.nodes.append(input.0)
                graph.layout.append(.init(nodeID: input.0.id, x: 60, y: 100 + Double(index) * 180))
                graph.connections.append(.init(sourceNode: input.0.id, targetNode: model.id, targetPort: input.1))
            }
        }) else { throw WorkflowIssue("设置未插入；请在当前编辑副本中重试。") }
        selectedNodeID = model.id
        try await persist(); await onChange()
    }

    public func resolveLibraryDrop(_ items: [WorkflowLibraryDropItem], owner: WorkflowAssetLibraryOwner,
        target: WorkflowCanvasInsertionTarget? = nil) async throws -> [WorkflowLibrarySource] {
        guard assetLibraryOwner == owner, !items.isEmpty, items.count <= 64,
              target.map(isCurrent) ?? canEditLibraryMetadata else { throw WorkflowIssue("Drop destination changed.", code: "container.issue.targetChanged") }
        // All exact read tokens are checked before the first explicit registration.
        for item in items {
            if case .original(let token) = item {
                guard token.projectID == owner.projectID, token.instanceID == owner.instanceID else { throw WorkflowIssue("Original belongs to another project instance.", code: "container.issue.targetChanged") }
                _ = try await services.store.readOnlyAsset(token)
            }
        }
        var sources: [WorkflowLibrarySource] = []
        for item in items {
            guard assetLibraryOwner == owner, target.map(isCurrent) ?? canEditLibraryMetadata else { throw WorkflowIssue("Drop destination changed during verification.", code: "container.issue.targetChanged") }
            switch item {
            case .source(let source): sources.append(source)
            case .original(let token): sources.append(.asset(try await services.store.pinWorkflowAsset(token.assetID, expected: token)))
            }
        }
        guard assetLibraryOwner == owner, target.map(isCurrent) ?? canEditLibraryMetadata else { throw WorkflowIssue("Drop destination changed during registration.", code: "container.issue.targetChanged") }
        return sources
    }

    /// Reuse exact saved objects. The source and optional connection share one edit/Undo.
    public func insertLibrarySources(_ sources: [WorkflowLibrarySource], owner: WorkflowAssetLibraryOwner,
        target: WorkflowCanvasInsertionTarget, x: Double, y: Double, inputNode: UUID? = nil, inputPort: String? = nil) async throws {
        guard assetLibraryOwner == owner, isCurrent(target), !sources.isEmpty, sources.count <= 64, x.isFinite, y.isFinite,
              Set(sources.map(\.key)).count == sources.count else { throw WorkflowIssue("Asset drop target changed.", code: "container.issue.targetChanged") }
        let capturedRuns = runs
        let values = try WorkflowAssetContainer.sourceValues(sources, runs: capturedRuns)
        for value in values { for ref in WorkflowAssetContainer.references(in: value) { try await services.verifyAsset(ref) } }
        guard assetLibraryOwner == owner, isCurrent(target) else { throw WorkflowIssue("Asset drop target changed during validation.", code: "container.issue.targetChanged") }
        for source in sources { if case .runtime(let ref) = source { guard try ref.resolve(in: runs) == ref.resolve(in: capturedRuns) else { throw WorkflowIssue("Runtime source changed.", code: "container.issue.targetChanged") } } }
        let output = WorkflowAssetContainer.sourceOutput(sources, values: values)
        var source: WorkflowNode
        if sources.count == 1, case .asset(let ref) = sources[0] {
            guard let definition = registry.operation("d.asset.reference")?.definition else { throw WorkflowIssue("Asset reference operation is unavailable.", code: "container.issue.operationUnavailable") }
            source = definition.makeNode(); source.assetReference = ref
        } else {
            guard let definition = registry.operation(WorkflowAssetContainer.sourceID)?.definition else { throw WorkflowIssue("Source container operation is unavailable.", code: "container.issue.operationUnavailable") }
            source = definition.makeNode(); source.librarySources = sources
            source.parameters["kind"] = .text(output?.kind.rawValue ?? "mixed")
            source.dataConfiguration = .init(schema: output?.datum?.schema)
        }
        var connection: WorkflowConnection?
        if let inputNode, let inputPort {
            guard sources.count == 1, let output, let node = graph?.nodes.first(where: { $0.id == inputNode }),
                  graph?.connections.contains(where: { $0.targetNode == inputNode && $0.targetPort == inputPort }) == false else { throw WorkflowIssue("Drop one compatible asset onto an empty input.", code: "container.dropTarget") }
            let contract = try WorkflowInputContract(step: .init(node: node, inputs: []), portID: inputPort, tools: tools, registry: registry)
            let match = contract.compatibility(with: output)
            guard match.status == .direct else { throw WorkflowIssue(match.reason, code: "container.dropIncompatible") }
            connection = .init(sourceNode: source.id, targetNode: inputNode, targetPort: inputPort)
        } else if inputNode != nil || inputPort != nil { throw WorkflowIssue("Incomplete input drop target.", code: "container.issue.targetChanged") }
        if target.rootID == nil {
            guard connection == nil else { throw WorkflowIssue("Input destination disappeared.", code: "container.issue.targetChanged") }
            let next = WorkflowGraph(name: "新流程", nodes: [source], layout: [.init(nodeID: source.id, x: x, y: y)])
            try registry.validate(next, tools: tools)
            undoStack.append(editSnapshot); redoStack = []; graphs.append(next); selectedGraphID = next.id
        } else {
            guard edit({ graph in
                graph.nodes.append(source); graph.layout.append(.init(nodeID: source.id, x: x, y: y))
                if let connection { graph.connections.append(connection) }
            }) else { throw WorkflowIssue(errorMessage ?? "Cannot insert source container.", code: "container.issue.targetChanged") }
        }
        selectedNodeID = source.id
        do { try await persist(); await onChange() }
        catch { throw WorkflowIssue(error.localizedDescription, code: "container.issue.dropSavePending") }
    }
    public func addPreviewContainer(after nodeID: UUID, port: String, target: WorkflowCanvasInsertionTarget) throws {
        guard isCurrent(target), let graph, let source = graph.nodes.first(where: { $0.id == nodeID }),
              let output = registry.definition(for: source, tools: tools)?.outputs.first(where: { $0.id == port }), output.kinds.count == 1,
              let kind = output.kinds.first, kind != .receipt else { throw WorkflowIssue("Choose a concrete output for the preview container.") }
        guard let definition = registry.operation(WorkflowAssetContainer.previewID)?.definition else { throw WorkflowIssue("Preview container operation is unavailable.") }
        var preview = definition.makeNode()
        preview.parameters["kind"] = .text(kind.rawValue)
        let origin = graph.layout.first { $0.nodeID == nodeID }
        guard edit({ graph in
            graph.nodes.append(preview); graph.layout.append(.init(nodeID: preview.id, x: (origin?.x ?? 100) + 420, y: origin?.y ?? 100))
            graph.connections.append(.init(sourceNode: nodeID, sourcePort: port, targetNode: preview.id))
        }) else { throw WorkflowIssue(errorMessage ?? "Cannot add preview container.") }
        selectedNodeID = preview.id
    }
    public func insertQuickResult(_ reference: WorkflowAssetReference, target: WorkflowCanvasInsertionTarget, x: Double = 80, y: Double = 100, title: String? = nil) async throws {
        try Task.checkCancellation()
        guard x.isFinite, y.isFinite, isCurrent(target), let definition = registry.operation("d.asset.reference")?.definition else { throw WorkflowIssue("目标流程已改变。") }
        _ = try await services.store.workflowData(reference)
        try Task.checkCancellation()
        guard isCurrent(target) else { throw WorkflowIssue("读取期间流程已改变。") }
        var node = definition.makeNode(); node.assetReference = reference
        if let title { node.title = title }
        if target.rootID == nil {
            // Do not create an empty graph before the asynchronous copy/read succeeds.
            // First graph and first asset are a single user insertion and undo step.
            let next = WorkflowGraph(name: "新流程", nodes: [node],
                layout: [.init(nodeID: node.id, x: x, y: y)])
            try registry.validate(next, tools: tools)
            undoStack.append(editSnapshot); redoStack = []; graphs.append(next)
            selectedGraphID = next.id
        } else {
            edit { $0.nodes.append(node); $0.layout.append(.init(nodeID: node.id, x: x, y: y)) }
        }
        guard graph?.nodes.contains(where: { $0.id == node.id }) == true else { throw WorkflowIssue("没有插入结果节点。") }
        selectedNodeID = node.id
        try await persist(); await onChange()
    }

    /// A structured published result is a frozen value input, not a generator or hidden execution.
    public func insertQuickValue(_ value: WorkflowDatum, target: WorkflowCanvasInsertionTarget) async throws {
        try Task.checkCancellation()
        guard isCurrent(target), target.rootID != nil, let definition = registry.operation("d.value.input")?.definition else { throw WorkflowIssue("目标流程已改变。") }
        try value.validate()
        for reference in value.assetReferences { _ = try await services.store.workflowData(reference) }
        try Task.checkCancellation()
        guard isCurrent(target) else { throw WorkflowIssue("读取期间流程已改变。") }
        var node = definition.makeNode(); node.dataConfiguration = .init(value: value)
        edit { $0.nodes.append(node); $0.layout.append(.init(nodeID: node.id, x: 80, y: 100)) }
        guard graph?.nodes.contains(where: { $0.id == node.id }) == true else { throw WorkflowIssue("没有插入结果节点。") }
        selectedNodeID = node.id
        try await persist(); await onChange()
    }

    public func canvasInsertionTarget() -> WorkflowCanvasInsertionTarget? {
        guard canEditCanvas, let projectID, let projectInstanceID else { return nil }
        if graphs.isEmpty {
            return .init(projectID: projectID, instanceID: projectInstanceID, rootID: nil, revision: emptyInsertionRevision, bodyID: nil, path: [])
        }
        guard let rootGraph, let graph else { return nil }
        return .init(projectID: projectID, instanceID: projectInstanceID, rootID: rootGraph.id, revision: rootGraph.revision, bodyID: graph.id, path: bodyPath)
    }
    public func isCurrent(_ target: WorkflowCanvasInsertionTarget) -> Bool {
        guard canEditCanvas, projectID == target.projectID, projectInstanceID == target.instanceID else { return false }
        if target.rootID == nil {
            return graphs.isEmpty && target.bodyID == nil && target.path.isEmpty && emptyInsertionRevision == target.revision
        }
        return rootGraph?.id == target.rootID && rootGraph?.revision == target.revision &&
            graph?.id == target.bodyID && bodyPath == target.path
    }
    /// The UI captures the insertion scope synchronously before starting its Task.
    public func addAssetNode(projectID expectedProject: UUID, assetID: UUID, x: Double, y: Double,
                             target: WorkflowCanvasInsertionTarget) async {
        guard expectedProject == target.projectID, isCurrent(target),
              availableAssets.contains(where: { $0.id == assetID }), x.isFinite, y.isFinite else { return }
        do {
            let ref = try await services.store.pinWorkflowAsset(assetID)
            guard isCurrent(target) else { throw WorkflowIssue("拖入期间流程已改变；资产保留，未添加到其他流程。") }
            try await insertQuickResult(ref, target: target, x: x, y: y,
                title: availableAssets.first(where: { $0.id == assetID })?.name)
        } catch { errorMessage = error.localizedDescription }
    }
    public func bindLibraryAsset(projectID expectedProject: UUID, assetID: UUID, target: WorkflowAssetBindingTarget) async {
        guard canEditCanvas, projectID == expectedProject, isCurrent(target),
              availableAssets.contains(where: { $0.id == assetID }) else { return }
        do {
            let ref = try await services.store.pinWorkflowAsset(assetID)
            guard canEditCanvas, projectID == expectedProject, isCurrent(target) else {
                throw WorkflowIssue("资产输入已改变；素材未绑定到其他节点。")
            }
            attach(ref, nodeID: target.node.id)
            guard graph?.nodes.first(where: { $0.id == target.node.id })?.assetReference == ref else { throw WorkflowIssue("素材已保存，但节点未绑定；请重新选择。") }
            try await persist(); await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    /// An explicit import publishes the chosen reference or copy in this project's existing Store.
    public func importLibraryFile(_ url: URL, mode: AssetImportMode = .copy) async {
        do { try await importLibraryFileReportingFailure(url, mode: mode) }
        catch { errorMessage = error.localizedDescription }
    }
    /// Shared commands must receive the failure, rather than reporting a successful
    /// import after this controller has only stored an error for its records panel.
    public func importLibraryFileReportingFailure(_ url: URL, mode: AssetImportMode = .copy) async throws {
        guard canEditCanvas else { throw WorkflowIssue("目标流程已改变。") }
        _ = try await services.store.importWorkflowMediaFile(at: url, mode: mode)
        await refreshAssets(); await onChange()
    }
    /// Import and graph insertion have separate durability boundaries. A changed
    /// destination keeps the successfully imported asset, but never inserts into a new graph.
    @discardableResult
    public func importCanvasFile(_ url: URL, owner: WorkflowAssetLibraryOwner,
        target: WorkflowCanvasInsertionTarget, x: Double, y: Double,
        mode: AssetImportMode = .copy) async throws -> Bool {
        guard assetLibraryOwner == owner, isCurrent(target), url.isFileURL, x.isFinite, y.isFinite else {
            throw WorkflowIssue("Asset drop target changed.")
        }
        let published = try await services.store.importWorkflowMediaFile(at: url, mode: mode)
        await refreshAssets(); await onChange()
        guard assetLibraryOwner == owner, isCurrent(target) else { return false }
        try await insertLibrarySources([.asset(published.record.reference)], owner: owner,
            target: target, x: x, y: y)
        return true
    }
    public func setAssetTags(id: UUID, tags: [String]) async throws {
        guard canEditCanvas, availableAssets.contains(where: { $0.id == id }) else {
            throw WorkflowIssue("当前不能编辑此资产标签。")
        }
        _ = try await services.store.updateAsset(id: id, tags: tags)
        await refreshAssets(); await onChange()
    }
    public func deleteSelected() {
        guard let id = selectedNodeID, let target = canvasInsertionTarget() else { return }
        _ = deleteNode(id: id, target: target)
    }
    /// The card owns an explicit identity; selection may belong to another card.
    @discardableResult
    public func deleteNode(id: UUID, target: WorkflowCanvasInsertionTarget) -> Bool {
        guard isCurrent(target), graph?.nodes.contains(where: { $0.id == id }) == true else { return false }
        guard edit({ g in g.nodes.removeAll { $0.id == id }; g.connections.removeAll { $0.sourceNode == id || $0.targetNode == id }; g.layout.removeAll { $0.nodeID == id } }) else { return false }
        guard graph?.nodes.contains(where: { $0.id == id }) == false else { return false }
        if selectedNodeID == id { selectedNodeID = nil }
        selectedNodeIDs.remove(id)
        return true
    }
    public func copySelected() {
        guard canEditCanvas, var node = selectedNode else { return }; node.id = UUID(); node.title += " 副本"
        if edit({ g in g.nodes.append(node); g.layout.append(.init(nodeID: node.id, x: 100, y: 100)) }) { selectedNodeID = node.id }
    }
    public func resizeContainer(id: UUID, width: Double, height: Double, target: WorkflowCanvasInsertionTarget) {
        guard isCurrent(target), width.isFinite, height.isFinite,
              let node = graph?.nodes.first(where: { $0.id == id }), WorkflowAssetContainer.isContainer(node.operationID) else { return }
        edit({ graph in
            guard let index = graph.layout.firstIndex(where: { $0.nodeID == id }) else { return }
            let oldWidth = graph.layout[index].width ?? 360
            graph.layout[index].x += (min(1200, max(300, width)) - oldWidth) / 2
            graph.layout[index].width = min(1200, max(300, width))
            graph.layout[index].height = min(1000, max(280, height))
        }, changesConfiguration: false)
    }
    public func moveNode(id: UUID, x: Double, y: Double) {
        guard canEditCanvas, x.isFinite, y.isFinite else { return }
        edit({ g in
            if let i = g.layout.firstIndex(where: { $0.nodeID == id }) { g.layout[i].x = x; g.layout[i].y = y }
            else { g.layout.append(.init(nodeID: id, x: x, y: y)) }
        }, changesConfiguration: false)
    }
    /// One layout gesture creates one undo entry; request revisions and outputs stay unchanged.
    public func moveNodes(_ positions: [WorkflowLayout], target: WorkflowCanvasInsertionTarget) {
        guard isCurrent(target), let graph, !positions.isEmpty,
              Set(positions.map(\.nodeID)).count == positions.count,
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        let ids = Set(graph.nodes.map(\.id))
        guard positions.allSatisfy({ ids.contains($0.nodeID) }) else { return }
        edit({ g in
            for position in positions {
                if let index = g.layout.firstIndex(where: { $0.nodeID == position.nodeID }) { g.layout[index] = position }
                else { g.layout.append(position) }
            }
        }, changesConfiguration: false)
    }
    public func modelSelectionTarget(nodeID: UUID? = nil) -> WorkflowModelSelectionTarget? {
        guard canEditCanvas, let graph else { return nil }
        let candidate = nodeID == nil ? selectedNode : graph.nodes.first { $0.id == nodeID }
        guard let node = candidate, let kind = registry.operation(node.operationID)?.definition.modelKind else { return nil }
        return .init(graphID: graph.id, nodeID: node.id, operationID: node.operationID, kind: kind,
                     previousIdentity: node.parameters["modelID"]?.string ?? "")
    }
    public func isCurrent(_ target: WorkflowModelSelectionTarget) -> Bool {
        guard canEditCanvas, graph?.id == target.graphID,
              let node = graph?.nodes.first(where: { $0.id == target.nodeID }),
              node.operationID == target.operationID,
              registry.operation(node.operationID)?.definition.modelKind == target.kind,
              node.parameters["modelID"]?.string == target.previousIdentity else { return false }
        return true
    }
    public func bindModel(_ identity: String, to target: WorkflowModelSelectionTarget) {
        guard isCurrent(target) else { errorMessage = "目标节点已改变，模型未绑定到其他节点。"; return }
        setParameter(nodeID: target.nodeID, key: "modelID", value: .text(identity))
    }

    public func setParameter(nodeID: UUID, key: String, value: WorkflowScalar) {
        if key == "modelID", let node = graph?.nodes.first(where: { $0.id == nodeID }),
           let existing = node.parameters[key]?.string, !existing.isEmpty, value.string != existing,
           registry.definition(for: node, tools: tools)?.modelKind != nil {
            reportIssue(.init("A fixed model node cannot change model identity.", code: "workflow.model.fixedIdentity")); return
        }
        edit { g in guard let i = g.nodes.firstIndex(where: { $0.id == nodeID }) else { return }; g.nodes[i].parameters[key] = value }
    }
    public func setDataConfiguration(nodeID: UUID, value: WorkflowDataConfiguration?) {
        edit { graph in
            guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            try value?.schema?.validateDefinition(); try value?.value?.validate()
            graph.nodes[index].dataConfiguration = value
        }
    }
    public func connect(source: UUID, sourcePort: String, target: UUID, targetPort: String) {
        edit { $0.connections.append(.init(sourceNode: source, sourcePort: sourcePort, targetNode: target, targetPort: targetPort)) }
    }
    public func disconnect(_ connectionID: UUID) { edit { $0.connections.removeAll { $0.id == connectionID } } }
    public func undo() { guard canUndo, let value = undoStack.popLast() else { return }; redoStack.append(editSnapshot); applyHistory(value) }
    public func redo() { guard canRedo, let value = redoStack.popLast() else { return }; undoStack.append(editSnapshot); applyHistory(value) }
    public func addExample(_ name: String) {
        guard canEditCanvas else { return }
        let next: WorkflowGraph
        switch name {
        case "containerImages":
            do { next = try WorkflowExamples.imageContainerReview() } catch { errorMessage = error.localizedDescription; return }
        case "container": next = WorkflowExamples.assetReview(); case "image": next = WorkflowExamples.image(); case "file": next = WorkflowExamples.file()
        case "template": next = WorkflowExamples.template(); default: next = WorkflowExamples.text() }
        undoStack.append(editSnapshot); redoStack = []; graphs.append(next); selectedGraphID = next.id; selectedNodeID = next.nodes.first?.id
    }
    public func addLanguageExample(_ choice: WorkflowLanguageExample) {
        guard canEditCanvas else { return }
        do {
            let bundle = try WorkflowLanguageExamples.make(choice)
            // Every addition is an independent editable copy. Tool identity and
            // digest remain fixed for existing instances; never overwrite them.
            let combined = tools + bundle.tools
            _ = try WorkflowPlanCompiler(registry: registry).compile(bundle.graph, tools: combined)
            undoStack.append(editSnapshot); redoStack = []
            tools = combined; graphs.append(bundle.graph); selectedGraphID = bundle.graph.id
            selectedNodeID = bundle.graph.nodes.first?.id; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    public func attach(_ reference: WorkflowAssetReference, nodeID: UUID) {
        edit { g in guard let i = g.nodes.firstIndex(where: { $0.id == nodeID }), registry.operation(g.nodes[i].operationID)?.definition.interaction == .assetInput else { throw WorkflowIssue("请选择文件／资产输入节点。") }; g.nodes[i].assetReference = reference }
    }
    public func importFile(_ url: URL, nodeID: UUID, mode: AssetImportMode = .copy) async {
        guard canEditCanvas else { return }
        guard let target = assetBindingTarget(nodeID: nodeID) else { return }
        do {
            let asset = try await services.store.importWorkflowMediaFile(at: url, mode: mode)
            guard canEditCanvas, isCurrent(target) else { throw WorkflowIssue("导入期间流程或输入已改变；资产已保存，未绑定到另一位置。") }
            attach(asset.record.reference, nodeID: nodeID)
            guard graph?.nodes.first(where: { $0.id == nodeID })?.assetReference == asset.record.reference else { throw WorkflowIssue("导入素材已保存，但节点未绑定；请在当前编辑副本中重新选择。") }
            try await persist(); await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    public func publishText(_ text: String, origin: String, target suppliedTarget: WorkflowCanvasInsertionTarget? = nil) async {
        guard let target = suppliedTarget ?? canvasInsertionTarget(), isCurrentTextPublication(target) else {
            errorMessage = "目标流程已改变或当前不可编辑，文稿未发布。"; return
        }
        let execution = activeRunID, original = editingOriginalID
        let copy = target.rootID.flatMap { editingCopies[$0] }
        var published = false
        do {
            try Task.checkCancellation()
            let asset = try await services.store.publishWorkflowAsset(data: Data(text.utf8), mediaType: "text/plain",
                name: "已发布文稿", operationID: "d.text.publish", details: ["origin": origin])
            published = true
            try await afterTextPublication()
            try Task.checkCancellation()
            guard isCurrentTextPublication(target), activeRunID == execution, editingOriginalID == original,
                  target.rootID.flatMap({ editingCopies[$0] }) == copy else {
                throw WorkflowIssue("文稿素材已保存，但目标流程已改变或当前不可编辑，未添加节点。")
            }
            // Preserve the existing first-publication text example. Only an
            // originally empty project may take this path, never a changed selection.
            if target.rootID == nil { addExample("text") }
            guard let operation = registry.operation("d.asset.reference") else { throw WorkflowIssue("文稿素材已保存，但素材节点不可用。") }
            var node = operation.definition.makeNode(); node.assetReference = asset.record.reference; node.title = "已发布文稿"
            edit { g in g.nodes.append(node); g.layout.append(.init(nodeID: node.id, x: 40, y: 360)) }
            guard graph?.nodes.contains(where: { $0.id == node.id }) == true else {
                throw WorkflowIssue("文稿素材已保存，但节点未加入流程。")
            }
            selectedNodeID = node.id; try await persist()
        } catch {
            errorMessage = published
                ? "文稿素材已保存；流程插入或保存未完成：\(error.localizedDescription)"
                : "文稿未发布：\(error.localizedDescription)"
        }
        // The asset is independently durable, including when insertion is refused.
        // Closed owners must not be read again merely to refresh presentation.
        if published, !closed, !closing, projectInstanceID == target.instanceID {
            await refreshAvailableAssets(instanceID: target.instanceID)
            if !closed, !closing { await onChange() }
        }
    }

    private func isCurrentTextPublication(_ target: WorkflowCanvasInsertionTarget) -> Bool {
        guard canEditCanvas, projectID == target.projectID, projectInstanceID == target.instanceID else { return false }
        if target.rootID == nil {
            return graphs.isEmpty && target.bodyID == nil && target.path.isEmpty && emptyInsertionRevision == target.revision
        }
        // Appending an independent asset does not consume graph configuration.
        // Re-read the current body only after identity matches, preserving edits
        // and layout changes without treating an ancestor layout revision as stale.
        return rootGraph?.id == target.rootID && graph?.id == target.bodyID && bodyPath == target.path &&
            !(isRunning && editingOriginalID == target.rootID && target.rootID.flatMap { editingCopies[$0] }.flatMap { id in graphs.first { $0.id == id } } != nil)
    }

    // One current-scope display cache, owned by this controller. Generations are
    // observed even on warm reads; derived cache writes never publish view changes.
    private var displayGraphGeneration: UInt64 = 0
    private var displayHistoryGeneration: UInt64 = 0
    private var displayToolGeneration: UInt64 = 0
    @ObservationIgnored private var displaySnapshot = NodeDisplaySnapshot()
    #if DEBUG
    @ObservationIgnored var displayAnalysisCount = 0
    @ObservationIgnored var displayHistoryCount = 0
    #endif

    public func presentationStatus(for nodeID: UUID) -> WorkflowNodePresentationStatus? {
        let graphGeneration = displayGraphGeneration, toolGeneration = displayToolGeneration
        let historyGeneration = displayHistoryGeneration
        let cache = displaySnapshot
        let scope = NodeDisplaySnapshot.Scope(root: selectedGraphID, path: bodyPath,
            project: projectID, instance: projectInstanceID)
        if cache.historyPresenceScope != scope || cache.historyPresenceGeneration != historyGeneration {
            cache.hasHistory = runs.contains { $0.graph.id == selectedGraphID && !$0.steps.isEmpty }
            cache.historyPresenceScope = scope; cache.historyPresenceGeneration = historyGeneration
        }
        // New graphs have no status badges: do not introduce analysis work on that path.
        guard cache.hasHistory else { return nil }
        if cache.scope != scope || cache.graphGeneration != graphGeneration || cache.toolGeneration != toolGeneration {
            guard let graph else { displaySnapshot = NodeDisplaySnapshot(); return nil }
            var key = graph
            key.name = ""; key.revision = graph.id; key.layout = []
            for index in key.nodes.indices { key.nodes[index].title = ""; key.nodes[index].collectionRule = nil }
            let layoutIDs = Set(graph.layout.map(\.nodeID))
            let validLayout = layoutIDs.count == graph.layout.count && layoutIDs.isSubset(of: Set(graph.nodes.map(\.id)))
            if cache.scope != scope || cache.semanticGraph != key || cache.toolGeneration != toolGeneration || cache.validLayout != validLayout {
                do {
                    let evidence = try registry.signatureEvidence(in: graph, tools: tools)
                    cache.signatures = evidence.values; cache.signatureFailures = evidence.failures
                    cache.analysisFailure = nil
                } catch {
                    cache.signatures = [:]; cache.signatureFailures = [:]
                    cache.analysisFailure = error.localizedDescription
                }
                cache.incoming = Dictionary(grouping: graph.connections, by: \.targetNode)
                cache.semanticGraph = key; cache.validLayout = validLayout
                cache.historyGeneration = nil
                #if DEBUG
                displayAnalysisCount += 1
                #endif
            }
            cache.scope = scope; cache.graphGeneration = graphGeneration; cache.toolGeneration = toolGeneration
        }
        if cache.historyGeneration != historyGeneration {
            cache.statuses = [:]
            guard let graphID = cache.semanticGraph?.id else { return nil }
            // Preserve run/step array order. Latest display belongs to the selected root;
            // reusable upstreams belong to the actual visible graph, including nested bodies.
            typealias Index = (run: Int, step: Int)
            var latest: [UUID: Index] = [:], reusable: [UUID: Index] = [:]
            for ri in runs.indices.reversed() {
                let run = runs[ri]
                guard run.graph.id == selectedGraphID || run.graph.id == graphID else { continue }
                for si in run.steps.indices.reversed() {
                    let step = run.steps[si], id = step.node.id
                    if run.graph.id == selectedGraphID, latest[id] == nil { latest[id] = (ri, si) }
                    if run.graph.id == graphID, reusable[id] == nil,
                       cache.signatures[id] == step.signature, [.completed, .partial].contains(step.status) {
                        reusable[id] = (ri, si)
                    }
                }
            }
            cache.reusable = reusable
            cache.comparisons = [:]; cache.buildingStatuses = true
            for (id, index) in latest {
                let step = runs[index.run].steps[index.step]
                cache.statuses[id] = .init(status: step.status,
                    comparison: compareOutput(step, in: runs[index.run], cache: cache, visiting: []))
            }
            cache.buildingStatuses = false; cache.statusMemoCount = cache.comparisons.count
            cache.historyGeneration = historyGeneration
            #if DEBUG
            displayHistoryCount += 1
            #endif
        }
        return cache.statuses[nodeID]
    }

    /// Selected historical output shares the same epoch-bound analysis. The memo is
    /// limited to 128 additional records and is cleared on graph/history/tool changes.
    public func outputComparison(_ step: WorkflowStepRun, runID: UUID) -> WorkflowOutputComparison {
        _ = presentationStatus(for: step.node.id)
        guard let run = runs.first(where: { $0.id == runID }),
              run.steps.contains(where: { $0.id == step.id && $0 == step }) ||
                run.planCheckpoint?.records.contains(where: { $0.id == step.id && $0.step == step }) == true else {
            return .unavailable("The recorded output is unavailable.")
        }
        return compareOutput(step, in: run, cache: displaySnapshot, visiting: [])
    }

    private func compareOutput(_ value: WorkflowStepRun, in run: WorkflowRun,
                               cache: NodeDisplaySnapshot, visiting: Set<UUID>) -> WorkflowOutputComparison {
        let memoKey = NodeDisplaySnapshot.OutputKey(run: run.id, step: value.id)
        if let known = cache.comparisons[memoKey] { return known }
        func evaluate() -> WorkflowOutputComparison {
            if let failure = cache.analysisFailure ?? cache.signatureFailures[value.node.id] { return .unavailable(failure) }
            guard let current = cache.semanticGraph,
                  let signature = cache.signatures[value.node.id] else { return .unavailable("Missing current node signature.") }
            guard !visiting.contains(value.node.id) else { return .unavailable("Cycle in current workflow.") }
            let seen = visiting.union([value.node.id])
            let pins = run.scope?.historicalInputs ?? []
            if !pins.isEmpty, let cp = run.planCheckpoint {
                // Exact pinned boundaries are intentionally independent of newer upstream
                // runs. Compare the selected scope and its boundary edges, not those ancestors.
                let scopeIDs = Set(cp.plan.steps.map(\.id))
                var ids: Set<UUID> = [], pending = [value.node.id]
                while let id = pending.popLast(), ids.insert(id).inserted {
                    pending += run.graph.connections.filter { $0.targetNode == id && scopeIDs.contains($0.sourceNode) }.map(\.sourceNode)
                }
                func normalized(_ node: WorkflowNode) -> WorkflowNode {
                    var copy = node; copy.title = ""; copy.collectionRule = nil
                    if let kind = registry.definition(for: node, tools: tools)?.modelKind,
                       copy.parameters["modelID"] == nil,
                       let model = cp.modelDefaults?[kind.rawValue] { copy.parameters["modelID"] = .text(model) }
                    return copy
                }
                for id in ids {
                    guard let now = current.nodes.first(where: { $0.id == id }),
                          let then = run.graph.nodes.first(where: { $0.id == id }) else { return .changed }
                    if normalized(now) != normalized(then) { return .changed }
                }
                let oldEdges = run.graph.connections.filter { ids.contains($0.targetNode) }
                let newEdges = current.connections.filter { ids.contains($0.targetNode) }
                guard oldEdges.count == newEdges.count, oldEdges.allSatisfy({ old in
                    newEdges.contains { $0.sourceNode == old.sourceNode && $0.sourcePort == old.sourcePort && $0.targetNode == old.targetNode && $0.targetPort == old.targetPort }
                }) else { return .changed }
            }
            for edge in cache.incoming[value.node.id] ?? [] {
                if let pin = pins.first(where: { $0.destinationNodeID == value.node.id && $0.destinationPort == edge.targetPort }) {
                    guard pin.sourcePort == edge.sourcePort,
                          let owner = runs.first(where: { $0.id == pin.sourceCall.address.runID }),
                          let call = owner.planCheckpoint?.records.first(where: { $0.address == pin.sourceCall.address && $0.id == pin.sourceCall.stepID }),
                          call.step.node.id == edge.sourceNode,
                          let output = call.step.outputs[pin.sourcePort],
                          output == run.planCheckpoint?.externalInputs[value.node.id]?[edge.targetPort],
                          output == value.inputs[edge.targetPort] else { return .unavailable("The selected historical input no longer matches its exact call.") }
                    continue
                }
                let upstreamRun: WorkflowRun, upstream: WorkflowStepRun
                if !pins.isEmpty, let record = run.planCheckpoint?.records.first(where: {
                    $0.address.path == [.node(edge.sourceNode)] && [.completed, .partial].contains($0.step.status)
                }) {
                    upstreamRun = run; upstream = record.step
                } else {
                    guard let index = cache.reusable[edge.sourceNode] else { return .missingUpstream }
                    upstreamRun = runs[index.run]; upstream = upstreamRun.steps[index.step]
                }
                guard let output = upstream.outputs[edge.sourcePort] else { return .missingUpstream }
                guard value.inputs[edge.targetPort] == output else { return .changed }
                let reason = compareOutput(upstream, in: upstreamRun, cache: cache, visiting: seen)
                if reason != .matching { return reason }
            }
            return !pins.isEmpty || signature == value.signature ? .matching : .changed
        }
        let result = evaluate()
        if cache.buildingStatuses || cache.comparisons.count < cache.statusMemoCount + 128 { cache.comparisons[memoKey] = result }
        return result
    }

    private final class NodeDisplaySnapshot {
        struct Scope: Equatable {
            let root: UUID?; let path: [WorkflowBodyLocation]; let project: UUID?; let instance: UUID?
        }
        var scope: Scope?
        var historyPresenceScope: Scope?
        var historyPresenceGeneration: UInt64?
        var hasHistory = false
        var graphGeneration: UInt64?
        var toolGeneration: UInt64?
        var historyGeneration: UInt64?
        var semanticGraph: WorkflowGraph?
        var validLayout = true
        var signatures: [UUID: String] = [:]
        var signatureFailures: [UUID: String] = [:]
        var analysisFailure: String?
        var incoming: [UUID: [WorkflowConnection]] = [:]
        var statuses: [UUID: WorkflowNodePresentationStatus] = [:]
        var reusable: [UUID: (run: Int, step: Int)] = [:]
        var buildingStatuses = false
        var statusMemoCount = 0
        struct OutputKey: Hashable { let run: UUID; let step: UUID }
        var comparisons: [OutputKey: WorkflowOutputComparison] = [:]
    }

    public func latestStep(for nodeID: UUID) -> WorkflowStepRun? {
        for run in runs.reversed() where run.graph.id == selectedGraphID {
            if let step = run.steps.reversed().first(where: { $0.node.id == nodeID }) { return step }
        }
        return nil
    }
    public func isStale(_ step: WorkflowStepRun) -> Bool {
        guard let graph else { return true }
        if (try? registry.signature(step.node.id, in: graph, tools: tools)) != step.signature { return true }
        func upstreamChanged(_ value: WorkflowStepRun, visited: Set<UUID>) -> Bool {
            if visited.contains(value.node.id) { return true }
            let seen = visited.union([value.node.id])
            for edge in graph.connections where edge.targetNode == value.node.id {
                guard let upstream = reusable(nodeID: edge.sourceNode, graph: graph, inputs: nil),
                      value.inputs[edge.targetPort] == upstream.outputs[edge.sourcePort],
                      !upstreamChanged(upstream, visited: seen) else { return true }
            }
            return false
        }
        return upstreamChanged(step, visited: [])
    }
    private func reusable(nodeID: UUID, graph: WorkflowGraph, inputs: [String: WorkflowValue]?) -> WorkflowStepRun? {
        guard let signature = try? registry.signature(nodeID, in: graph, tools: tools) else { return nil }
        return runs.reversed().filter { $0.graph.id == graph.id }.flatMap { $0.steps.reversed() }.first {
            $0.node.id == nodeID && $0.signature == signature && [.completed, .partial].contains($0.status) && (inputs == nil || $0.inputs == inputs)
        }
    }
    public func plan(target: UUID, only: Bool) throws -> [String] {
        guard bodyPath.isEmpty else { throw WorkflowIssue("局部流程是编辑模板；请返回外层运行，或在运行详情选择具体调用。") }
        guard let graph else { throw WorkflowIssue("请先创建流程。") }
        let ids = try WorkflowPlanCompiler(registry: registry).compile(graph, tools: tools, target: target, only: only).steps.map(\.id)
        return try ids.map { id in
            guard let node = graph.nodes.first(where: { $0.id == id }) else { throw WorkflowIssue("节点已不存在。") }
            if only {
                let old = graph.connections.filter { $0.targetNode == id }.contains { edge in
                    reusable(nodeID: edge.sourceNode, graph: graph, inputs: nil).map(isStale) ?? true
                }
                return "重新执行 \(node.title)；使用已就绪的上游资产版本，不重算上游。" + (old ? " 注意：包含旧输入结果。" : "")
            }
            if let step = reusable(nodeID: id, graph: graph, inputs: nil) { return "检查后复用 \(node.title)（\(step.id.uuidString.prefix(8))）；若输入版本不同则重新执行。" }
            if registry.operation(node.operationID).map { [.textReview, .candidateReview].contains($0.definition.interaction) } == true { return "等待人工确认：\(node.title)；不会自动启动后续生成。" }
            return "执行：\(node.title)"
        }
    }

    private func persist() async throws {
        guard !closed, !toolPublicationBusy, readOnlyReason == nil else { throw WorkflowIssue(readOnlyReason ?? "项目已关闭或节点正在保存。") }
        // Chain the complete transaction, including its read, so actor reentrancy cannot lose another save.
        let generation = contentGeneration, token = UUID()
        savingToken = token
        let preceding = writeTail, store = services.store, capturedGraphs = graphs, capturedRuns = runs, capturedTools = tools, capturedBatches = batchStages, capturedSubmissions = containerSubmissions, capturedCollection = collectionRequests
        let task = Task { @MainActor in
            if let preceding { _ = try? await preceding.value }
            let state = try await store.workflowState()
            guard let archive = state.archive else { throw WorkflowIssue(state.readOnlyReason ?? "流程只读。") }
            try self.beforeHistorySave()
            _ = try await store.saveWorkflow(graphs: capturedGraphs, runs: capturedRuns, expectedRevision: archive.revision, tools: capturedTools, batchStages: capturedBatches.isEmpty ? nil : capturedBatches, containerSubmissions: capturedSubmissions.isEmpty ? nil : capturedSubmissions, collectionRequests: capturedCollection.isEmpty ? nil : capturedCollection)
        }
        writeTail = task; isSaving = true
        do {
            try await task.value
            savedContentGeneration = max(savedContentGeneration, generation)
            if savingToken == token { persistenceFailed = false; isSaving = false }
            await refreshAssets()
        } catch {
            if savingToken == token { persistenceFailed = true; isSaving = false }
            throw error
        }
    }
    public func save() async {
        let pendingStop = pendingPausedStopRunID
        do { try await persist(); if pendingPausedStopRunID == pendingStop { pendingPausedStopRunID = nil }; setProgress(.init("workflowSaved")); await onChange() }
        catch { errorMessage = error.localizedDescription }
    }
    public func saveExplicitEdits() async throws { try await persist(); await onChange() }

    /// Freeze and authorize a finite stage. No inference happens until its ledger is durable.
    @discardableResult public func createBatchStage(
        selection: WorkflowGraphSelection, pins: [WorkflowHistoricalInput], repetitions: Int,
        expectedGraphID: UUID, expectedRevision: UUID, seedStrategy: WorkflowBatchSeedStrategy = .fixed
    ) async throws -> UUID {
        guard canEditCanvas, !isRunning, !isSaving, !hasPendingSaves, bodyPath.isEmpty,
              let original = rootGraph, original.id == expectedGraphID, original.revision == expectedRevision,
              (1...64).contains(repetitions), runs.count + repetitions <= 4_096 else {
            throw WorkflowIssue("批次范围已改变、次数超限或仍有未完成保存。")
        }
        isRunning = true; defer { isRunning = false }
        let frozen = services.freezeModels(in: original), defaults = services.capturedModelDefaults()
        let plan = try WorkflowScopePlanner.rebuild(graph: frozen, selection: selection, modelDefaults: defaults, tools: tools, registry: registry)
        let arguments = try publicArguments(plan, graph: frozen)
        let sourceIDs = Set(pins.map { $0.sourceCall.address.runID })
        let sources = try runs.filter { sourceIDs.contains($0.id) }.map { try WorkflowArchiveInspection.scopeSource($0, tools: tools, registry: registry) }
        let target: UUID
        switch selection { case .through(let id), .only(let id), .downstream(let id, _): target = id }
        var additions: [WorkflowRun] = []
        let seeds = try WorkflowBatchSeedSchedule.allocate(plan: plan, strategy: seedStrategy,
            count: repetitions, registry: registry, nextSeed: batchSeedSource)
        for index in 0..<repetitions {
            var cp = WorkflowPlanCheckpoint(plan: plan, arguments: arguments); cp.modelDefaults = defaults
            cp.batchSeeds = seeds[index]
            cp.externalInputs = try WorkflowScopePlanner.resolveHistoricalInputs(pins,
                destination: .init(graph: frozen, selection: selection, checkpoint: cp),
                sources: sources, tools: tools, registry: registry)
            var run = WorkflowRun(id: cp.runID, graph: frozen, targetNodeID: target)
            run.planCheckpoint = cp
            run.scope = .init(selection: selection, historicalInputs: pins, recomputeSelected: true)
            additions.append(run)
        }
        return try await registerBatchStage(name: original.name, repetitions: repetitions, parents: [], additions: additions, seedStrategy: seedStrategy)
    }

    /// Each selected, settled attempt is one typed bundle, including list values and all join inputs.
    public func containerSubmission(forParent runID: UUID) -> WorkflowContainerSubmission? {
        containerSubmissions.first { $0.choices.contains { $0.call.address.runID == runID && !$0.selectedIDs.isEmpty } }
    }
    public func batchContinuationIssue(_ runID: UUID) -> WorkflowIssue? {
        if containerSubmission(forParent: runID) != nil { return WorkflowIssue("Continue this container’s saved stage; its parent cannot be dispatched twice.", code: "workflow.batch.issue.continuationExists") }
        guard let run = runs.first(where: { $0.id == runID }) else { return WorkflowIssue("Original attempt is unavailable.", code: "workflow.batch.issue.unavailableRun") }
        do { _ = try WorkflowBatchValidation.acceptedPrefix(run); return nil }
        catch { return error as? WorkflowIssue ?? WorkflowIssue(error.localizedDescription) }
    }

    @discardableResult public func createNextBatchStage(parentRunIDs: [UUID], repetitions: Int,
                                                       seedStrategy: WorkflowBatchSeedStrategy = .fixed) async throws -> UUID {
        guard !closed, !closing, !isRunning, !isSaving, !hasPendingSaves, !externalOperationBusy(),
              readOnlyReason == nil, !toolPublicationBusy, (1...64).contains(repetitions),
              !parentRunIDs.isEmpty, Set(parentRunIDs).count == parentRunIDs.count,
              parentRunIDs.count <= 256 / repetitions, runs.count + parentRunIDs.count * repetitions <= 4_096 else {
            throw WorkflowIssue("请选择已采用的尝试；每项 1—64 次、单阶段最多 256 次，且先完成保存。")
        }
        isRunning = true; defer { isRunning = false }
        let known = Set(batchStages.flatMap(\.attempts).map(\.runID))
        var additions: [WorkflowRun] = []
        for id in parentRunIDs {
            guard containerSubmission(forParent: id) == nil else { throw WorkflowIssue("Use the container’s saved continuation instead of creating another stage.", code: "workflow.batch.issue.continuationExists") }
            guard known.contains(id), let parent = runs.first(where: { $0.id == id }) else { throw WorkflowIssue("父尝试不属于已保存批次。") }
            try WorkflowArchiveInspection.validateRun(parent, tools: tools, registry: registry)
            let cp = try WorkflowBatchValidation.acceptedPrefix(parent)
            let seeds = try WorkflowBatchSeedSchedule.allocate(plan: cp.plan, parent: cp, strategy: seedStrategy,
                count: repetitions, registry: registry, nextSeed: batchSeedSource)
            for index in 0..<repetitions {
                var child = try WorkflowBatchValidation.continuation(of: parent)
                child.planCheckpoint?.batchSeeds = seeds[index]
                additions.append(child)
            }
        }
        return try await registerBatchStage(name: "Continuation batch", repetitions: repetitions, parents: parentRunIDs, additions: additions, seedStrategy: seedStrategy, systemTitle: .continuation)
    }

    private func registerBatchStage(name: String, repetitions: Int, parents: [UUID], additions: [WorkflowRun],
                                    seedStrategy: WorkflowBatchSeedStrategy = .fixed, systemTitle: WorkflowBatchStage.SystemTitle? = nil) async throws -> UUID {
        let stage = WorkflowBatchStage(name: name, repetitions: repetitions, parentRunIDs: parents,
            attempts: additions.enumerated().map { .init(ordinal: $0.offset + 1, runID: $0.element.id) }, seedStrategy: seedStrategy, systemTitle: systemTitle)
        try WorkflowArchiveInspection.validateScopeHistory(runs + additions, tools: tools, registry: registry)
        try WorkflowBatchValidation.validate(batchStages + [stage], runs: runs + additions, registry: registry)
        runs.append(contentsOf: additions); batchStages.append(stage)
        do { try await persist() }
        catch {
            // Retain the exact dispatch IDs for save-only recovery; no computation has run.
            batchStages[batchStages.count - 1].state = .savingBlocked
            errorMessage = error.localizedDescription
            throw error
        }
        await onChange()
        return stage.id
    }

    public func runBatchStage(_ id: UUID) async {
        guard !closed, !closing, !isRunning, !toolPublicationBusy, !externalOperationBusy(),
              readOnlyReason == nil, !hasPendingSaves,
              let si = batchStages.firstIndex(where: { $0.id == id }),
              ![.finished, .cancelled].contains(batchStages[si].state) else { return }
        isRunning = true; activeBatchID = id; cancelled = false; batchPauseRequested = false; errorMessage = nil
        defer {
            isRunning = false; activeBatchID = nil; activeRunID = nil; activeExecutor = nil
            editingOriginalID = nil; editingCopies = [:]; streamingText = ""; streamingStepID = nil
        }
        do {
            try WorkflowBatchValidation.validate(batchStages, runs: runs, registry: registry)
            batchStages[si].state = .running; try await persist()
            for ai in batchStages[si].attempts.indices {
                if cancelled || batchPauseRequested { break }
                guard batchStages[si].attempts[ai].state == .queued else { continue }
                let runID = batchStages[si].attempts[ai].runID
                guard let ri = runs.firstIndex(where: { $0.id == runID }), let cp = runs[ri].planCheckpoint,
                      cp.state == .ready else { throw WorkflowIssue("排队恢复点不是未派发状态；没有自动重算。") }
                activeRunID = runID; editingOriginalID = editingRootID(for: runs[ri]); editingCopies = [:]
                batchStages[si].attempts[ai].state = .dispatched
                batchStages[si].attempts[ai].startedAt = Date()
                try await persist() // Dispatch claim before any model admission.
                let clock = ContinuousClock(), start = ContinuousClock.now
                var failure: (any Error)?
                do { try await executePlan(runID: runID) } catch { failure = error }
                await finishExecution(failure) // Includes release/drain before the next dispatch.
                let elapsed = start.duration(to: clock.now).components
                batchStages[si].attempts[ai].activeSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                activeExecutor = nil
                batchStages[si].attempts[ai].state = batchAttemptState(runs[ri])
                if hasPendingSaves || runs[ri].status == .saving {
                    batchStages[si].attempts[ai].state = .savingBlocked
                    batchStages[si].state = .savingBlocked
                    break
                }
                try await persist() // A durable waiting/completed result permits the next attempt.
                if runs[ri].planCheckpoint?.state == .paused || (failure != nil && (!(runs[ri].planCheckpoint.map { WorkflowAssetContainer.containsFilter($0.plan) } ?? false) || ![.failed, .cancelled, .rejected].contains(runs[ri].status))) {
                    batchPauseRequested = true; break
                }
            }
            if cancelled {
                for ai in batchStages[si].attempts.indices where batchStages[si].attempts[ai].state == .queued {
                    batchStages[si].attempts[ai].state = .cancelled
                    if let ri = runs.firstIndex(where: { $0.id == batchStages[si].attempts[ai].runID }) {
                        runs[ri].status = .cancelled; runs[ri].planCheckpoint?.state = .cancelled
                    }
                }
                batchStages[si].state = .cancelled
            } else if batchStages[si].state != .savingBlocked {
                let unfinished: Set<WorkflowBatchAttempt.State> = [.queued, .dispatched, .interrupted, .savingBlocked]
                batchStages[si].state = batchStages[si].attempts.contains { unfinished.contains($0.state) } ? .paused : .finished
            }
            if !hasPendingSaves { try await persist() }
        } catch {
            batchStages[si].state = cancelled ? .cancelled : (hasPendingSaves ? .savingBlocked : .paused)
            errorMessage = error.localizedDescription
        }
        await onChange()
    }

    /// Stop only undispatched attempts. Completed/waiting results and adopted
    /// prefixes remain byte-for-byte intact; failed persistence keeps this intent.
    public func stopBatchQueue(_ id: UUID) async {
        guard !closed, !closing, !isRunning, !isSaving, !toolPublicationBusy,
              !externalOperationBusy(), readOnlyReason == nil, !hasPendingSaves,
              let si = batchStages.firstIndex(where: { $0.id == id }),
              [.queued, .paused].contains(batchStages[si].state),
              batchStages[si].attempts.contains(where: { $0.state == .queued }) else { return }
        isRunning = true; defer { isRunning = false }
        do {
            try WorkflowBatchValidation.validate(batchStages, runs: runs, registry: registry)
            let queued = batchStages[si].attempts.filter { $0.state == .queued }
            // Validate all identities before changing any record.
            guard queued.allSatisfy({ attempt in runs.contains { $0.id == attempt.runID && $0.planCheckpoint?.state == .ready } }) else {
                throw WorkflowIssue("排队恢复点不是未派发状态；没有取消其他运行。")
            }
            for ai in batchStages[si].attempts.indices where batchStages[si].attempts[ai].state == .queued {
                let ri = runs.firstIndex { $0.id == batchStages[si].attempts[ai].runID }!
                runs[ri].status = .cancelled; runs[ri].planCheckpoint?.state = .cancelled
                batchStages[si].attempts[ai].state = .cancelled
            }
            batchStages[si].state = .cancelled
            try await persist(); errorMessage = nil; await onChange()
        } catch { errorMessage = error.localizedDescription }
    }

    private func batchAttemptState(_ run: WorkflowRun) -> WorkflowBatchAttempt.State {
        switch run.status {
        case .completed, .partial: .completed
        case .waiting: .waiting
        case .failed: .failed
        case .cancelled, .rejected: .cancelled
        case .saving: .savingBlocked
        case .queued: .queued
        default: .interrupted
        }
    }

    public func retryBatchSaving(_ id: UUID) async {
        guard !closed, !closing, !isRunning, !isSaving, !toolPublicationBusy, readOnlyReason == nil,
              let si = batchStages.firstIndex(where: { $0.id == id }) else { return }
        let wasCancelled = batchStages[si].state == .cancelled
        let recoveringAttemptIDs = Set(batchStages[si].attempts.filter {
            [.savingBlocked, .dispatched].contains($0.state)
        }.map(\.id))
        isRunning = true; defer { isRunning = false }
        do {
            for ai in batchStages[si].attempts.indices {
                guard let ri = runs.firstIndex(where: { $0.id == batchStages[si].attempts[ai].runID }),
                      var cp = runs[ri].planCheckpoint else { throw WorkflowIssue("批次恢复点不存在。") }
                for record in cp.records where services.hasPendingPublication(stepID: record.id) {
                    guard record.step.status == .saving else {
                        throw WorkflowIssue("此内容来自尚未保存的人工决定。请在原关卡再次保存决定；队列未计算或自动采用。")
                    }
                    guard let context = services.retainedPublicationContext(stepID: record.id),
                          context.node == record.step.node, context.inputs == record.step.inputs,
                          context.address == record.address else { throw WorkflowIssue("待保存内容与冻结调用不符。") }
                    let saver = WorkflowPlanExecutor(registry: registry, executeCall: { _ in throw WorkflowIssue("保存恢复禁止计算。") },
                        save: { [unowned self] value in self.capture(value, runIndex: ri); try await self.persist() })
                    do {
                        do {
                            let outputs = try await services.retryWorkflowPublications(context)
                            cp = try await saver.restorePublication(cp, stepID: record.id, outputs: outputs)
                        } catch let failure as WorkflowOutputValidationFailure {
                            cp = try await saver.restorePublicationFailure(cp, stepID: record.id, failure: failure)
                        }
                    } catch { if let latest = saver.checkpoint { capture(latest, runIndex: ri) }; throw error }
                    capture(cp, runIndex: ri); services.acknowledgePublication(stepID: record.id)
                }
                if cp.state == .saving {
                    let saver = WorkflowPlanExecutor(registry: registry, executeCall: { _ in throw WorkflowIssue("恢复保存不能执行节点。") },
                        save: { [unowned self] value in self.capture(value, runIndex: ri); try await self.persist() })
                    var saved = try await saver.saveOnly(cp)
                    if saved.state == .running { saved.state = .ready }
                    capture(saved, runIndex: ri)
                }
                if [.savingBlocked, .dispatched].contains(batchStages[si].attempts[ai].state) {
                    batchStages[si].attempts[ai].state = batchAttemptState(runs[ri])
                }
            }
            batchStages[si].state = wasCancelled ? .cancelled : .paused
            try await persist()
            // A previous publication may already be in the checkpoint when its history save failed.
            // Release retained bookkeeping only after this durable retry has succeeded.
            for attempt in batchStages[si].attempts {
                for record in runs.first(where: { $0.id == attempt.runID })?.planCheckpoint?.records ?? []
                    where [.completed, .partial, .failed].contains(record.step.status) && !services.hasPendingPublication(stepID: record.id) {
                    services.acknowledgePublication(stepID: record.id)
                }
            }
            errorMessage = nil; await onChange()
        } catch {
            // A restored checkpoint may be durable before the final batch ledger is.
            // Preserve the save-only entry without undoing output identity or cancellation.
            for ai in batchStages[si].attempts.indices where recoveringAttemptIDs.contains(batchStages[si].attempts[ai].id) {
                batchStages[si].attempts[ai].state = .savingBlocked
            }
            errorMessage = error.localizedDescription
            batchStages[si].state = wasCancelled ? .cancelled : .savingBlocked
        }
    }

    /// An uncertain/crashed or failed dispatch is retained; retry is a newly authorized attempt.
    @discardableResult public func retryBatchAttempt(_ runID: UUID) async throws -> UUID {
        guard !closed, !closing, !isRunning, !isSaving, !hasPendingSaves, !externalOperationBusy(),
              readOnlyReason == nil, !toolPublicationBusy,
              batchStages.flatMap(\.attempts).contains(where: { $0.runID == runID && [.failed, .interrupted].contains($0.state) }),
              let old = runs.first(where: { $0.id == runID }), var cp = old.planCheckpoint else {
            throw WorkflowIssue("此尝试不能重算，或仍需恢复保存。")
        }
        isRunning = true; defer { isRunning = false }
        var replacement: WorkflowRun
        let parents: [UUID]
        let strategy = batchStages.first(where: { $0.attempts.contains(where: { $0.runID == runID }) })?.seedStrategy ?? .fixed
        var parentCheckpoint: WorkflowPlanCheckpoint?
        if let source = old.batchParent {
            guard let parent = runs.first(where: { $0.id == source.runID }),
                  let parentCP = parent.planCheckpoint, try WorkflowBatchValidation.digest(parentCP) == source.checkpointDigest else {
                throw WorkflowIssue("原阶段输入已改变；没有使用最新结果替代。")
            }
            replacement = try WorkflowBatchValidation.continuation(of: parent); parents = [parent.id]
            parentCheckpoint = parentCP
        } else {
            cp.runID = UUID(); cp.records = []; cp.outputs = [:]; cp.state = .ready; cp.error = nil
            replacement = WorkflowRun(id: cp.runID, graph: old.graph, targetNodeID: old.targetNodeID)
            replacement.scope = old.scope; replacement.planCheckpoint = cp; parents = []
        }
        replacement.planCheckpoint?.batchSeeds = try WorkflowBatchSeedSchedule.allocate(plan: cp.plan, parent: parentCheckpoint,
            strategy: strategy, count: 1, registry: registry, nextSeed: batchSeedSource)[0]
        return try await registerBatchStage(name: "Retry batch", repetitions: 1, parents: parents, additions: [replacement], seedStrategy: strategy, systemTitle: .retry)
    }

    public func run(target: UUID, only: Bool) async {
        guard !externalOperationBusy() else { errorMessage = "请先结束录音或恢复保存，再运行流程。"; return }
        guard bodyPath.isEmpty else { errorMessage = "请返回外层运行；不能把局部模板当作独立调用。"; return }
        guard !closed, !closing, !isRunning, !toolPublicationBusy, readOnlyReason == nil, let original = graph else { return }
        guard !hasPendingSaves else { errorMessage = "请先恢复保存，避免重复计算。"; return }
        editingOriginalID = original.id; editingCopies = [:]
        isRunning = true; cancelled = false; batchPauseRequested = false; errorMessage = nil
        defer { editingOriginalID = nil; editingCopies = [:]; isRunning = false; activeRunID = nil; activeExecutor = nil; streamingText = ""; streamingStepID = nil }
        var failure: (any Error)?
        do {
            let frozen = services.freezeModels(in: original)
            let defaults = services.capturedModelDefaults()
            let compiled = try WorkflowPlanCompiler(registry: registry).compile(frozen, tools: tools, target: target, only: only)
            let plan = try WorkflowPlanBinding.freeze(compiled, defaults: defaults, registry: registry)
            if let i = graphs.firstIndex(where: { $0.id == frozen.id }), graphs[i].revision == original.revision { graphs[i] = frozen }
            var arguments: [String: WorkflowDatum] = [:]
            for field in plan.interface.inputs {
                if let input = frozen.nodes.first(where: { $0.operationID == "d.value.input" && $0.parameters["publicName"]?.string == field.name }), let value = input.dataConfiguration?.value {
                    try value.validate(as: field.type); arguments[field.name] = value
                } else if field.required { throw WorkflowIssue("公开输入尚未填写：\(field.name)。") }
            }
            var checkpoint = WorkflowPlanCheckpoint(plan: plan, arguments: arguments)
            checkpoint.modelDefaults = defaults
            if only {
                guard let node = frozen.nodes.first(where: { $0.id == target }) else { throw WorkflowIssue("节点不存在。") }
                checkpoint.externalInputs[target] = try inputs(for: node, run: .init(graph: frozen, targetNodeID: target))
                var requested = WorkflowStepRun(node: plan.steps[0].node, signature: plan.steps[0].sourceSignature ?? "")
                requested.repeatRequested = true
                checkpoint.records = [.init(address: .init(runID: checkpoint.runID, path: [.node(target)]), step: requested)]
            }
            var run = WorkflowRun(id: checkpoint.runID, graph: frozen, targetNodeID: target, status: .running)
            run.planCheckpoint = checkpoint
            run.steps = checkpoint.records.filter { $0.address.path.count == 1 }.map(\.step)
            runs.append(run); activeRunID = run.id
            try await persist()
            try await executePlan(runID: run.id, force: only ? target : nil)
        } catch { failure = error }
        await finishExecution(failure)
    }

    public func scopeBoundaries(_ selection: WorkflowGraphSelection) throws -> [WorkflowScopeBoundary] {
        guard bodyPath.isEmpty, let graph = rootGraph else { throw WorkflowIssue("请返回外层选择运行范围；模板不能冒充实际调用。") }
        return try WorkflowScopePlanner.select(graph: graph, selection: selection, tools: tools, registry: registry).boundaries
    }

    public func history(for nodeID: UUID) -> [WorkflowRun] {
        return runs.filter { run in
            belongsToSelectedWorkflow(run) && (run.graph.nodes.contains { $0.id == nodeID } ||
                run.planCheckpoint?.records.contains { $0.step.node.id == nodeID } == true)
        }
    }

    /// Read-only navigation follows a concrete call's provenance to its root.
    /// It changes presentation only, including while the frozen run is in flight.
    public func presentationRootGraphID(for runID: UUID) -> UUID? {
        guard var current = runs.first(where: { $0.id == runID }) else { return nil }
        var seen = Set<UUID>()
        while seen.insert(current.id).inserted {
            if graphs.contains(where: { $0.id == current.graph.id }) { return current.graph.id }
            guard let parentID = current.scope?.originCall?.address.runID,
                  let parent = runs.first(where: { $0.id == parentID }) else { return nil }
            current = parent
        }
        return nil
    }
    @discardableResult public func revealRunForPresentation(_ runID: UUID) -> Bool {
        guard !closed, let root = presentationRootGraphID(for: runID) else { return false }
        selectedGraphID = root; bodyPath = []; selectedNodeID = nil; selectedNodeIDs = []
        return true
    }

    private func belongsToSelectedWorkflow(_ run: WorkflowRun) -> Bool {
        var current = run, seen = Set<UUID>()
        while seen.insert(current.id).inserted {
            if current.graph.id == selectedGraphID { return true }
            guard let id = current.scope?.originCall?.address.runID,
                  let parent = runs.first(where: { $0.id == id }) else { return false }
            current = parent
        }
        return false
    }

    public func presentationStep(nodeID: UUID, runID: UUID?) -> WorkflowStepRun? {
        guard let runID else { return latestStep(for: nodeID) }
        guard let run = runs.first(where: { $0.id == runID }), belongsToSelectedWorkflow(run) else { return nil }
        return run.planCheckpoint?.records.last(where: { $0.step.node.id == nodeID })?.step
            ?? run.steps.last(where: { $0.node.id == nodeID })
    }

    public func canRerunCall(_ call: WorkflowPlanCallRecord) -> Bool {
        // Presentation hint only. The action independently validates full provenance.
        call.step.node.control == nil && call.step.inputsBound == true &&
            [.completed, .partial, .failed, .cancelled].contains(call.step.status)
    }

    /// Choices are explicit old output versions; never an implicit 'latest' binding.
    public func historicalCalls(for boundary: WorkflowScopeBoundary) -> [WorkflowPlanCallRecord] {
        runs.reversed().filter { $0.graph.id == rootGraph?.id }.flatMap { run in
            (run.planCheckpoint?.records ?? []).filter {
                $0.address.path.count == 1 && $0.step.node.id == boundary.sourceNodeID &&
                [.completed, .partial].contains($0.step.status) && $0.step.outputs[boundary.sourcePort] != nil
            }
        }
    }

    public func runScoped(_ selection: WorkflowGraphSelection, pins: [WorkflowHistoricalInput],
                          expectedGraphID: UUID, expectedRevision: UUID) async {
        guard !externalOperationBusy(), !closed, !closing, !isRunning, !toolPublicationBusy, readOnlyReason == nil,
              !hasPendingSaves, bodyPath.isEmpty, let original = rootGraph,
              original.id == expectedGraphID, original.revision == expectedRevision else {
            errorMessage = "运行范围或原图已改变，或当前有未完成操作；请重新确认。"; return
        }
        editingOriginalID = original.id; editingCopies = [:]
        isRunning = true; cancelled = false; batchPauseRequested = false; errorMessage = nil
        defer { editingOriginalID = nil; editingCopies = [:]; isRunning = false; activeRunID = nil; activeExecutor = nil; streamingText = ""; streamingStepID = nil }
        var failure: (any Error)?
        do {
            let frozen = services.freezeModels(in: original), defaults = services.capturedModelDefaults()
            let plan = try WorkflowScopePlanner.rebuild(graph: frozen, selection: selection, modelDefaults: defaults,
                tools: tools, registry: registry)
            var checkpoint = WorkflowPlanCheckpoint(plan: plan, arguments: try publicArguments(plan, graph: frozen))
            checkpoint.modelDefaults = defaults
            let sourceIDs = Set(pins.map { $0.sourceCall.address.runID })
            let sources = try runs.filter { sourceIDs.contains($0.id) }.map {
                try WorkflowArchiveInspection.scopeSource($0, tools: tools, registry: registry)
            }
            checkpoint.externalInputs = try WorkflowScopePlanner.resolveHistoricalInputs(pins,
                destination: .init(graph: frozen, selection: selection, checkpoint: checkpoint),
                sources: sources, tools: tools, registry: registry)
            let target: UUID, recompute: Bool
            switch selection {
            case .through(let id): target = id; recompute = false
            case .only(let id), .downstream(let id, _): target = id; recompute = true
            }
            var run = WorkflowRun(id: checkpoint.runID, graph: frozen, targetNodeID: target, status: .running)
            run.scope = .init(selection: selection, historicalInputs: pins, recomputeSelected: recompute)
            run.planCheckpoint = checkpoint
            try WorkflowArchiveInspection.validateScopeHistory(runs + [run], tools: tools, registry: registry)
            if let i = graphs.firstIndex(where: { $0.id == frozen.id }), graphs[i].revision == original.revision { graphs[i] = frozen }
            runs.append(run); activeRunID = run.id
            try await persist(); try await executePlan(runID: run.id)
        } catch { failure = error }
        await finishExecution(failure)
    }

    /// A selected concrete call becomes a new run on its frozen local graph.
    /// It does not mutate or resume the original Map item, Loop iteration or waiting task.
    public func rerunCall(_ reference: WorkflowCallReference) async {
        guard !externalOperationBusy(), !closed, !closing, !isRunning, !toolPublicationBusy, readOnlyReason == nil, !hasPendingSaves else { return }
        editingOriginalID = runs.first(where: { $0.id == reference.address.runID }).flatMap { editingRootID(for: $0) }; editingCopies = [:]
        isRunning = true; cancelled = false; batchPauseRequested = false; errorMessage = nil
        defer { editingOriginalID = nil; editingCopies = [:]; isRunning = false; activeRunID = nil; activeExecutor = nil; streamingText = ""; streamingStepID = nil }
        var failure: (any Error)?
        do {
            guard let old = runs.first(where: { $0.id == reference.address.runID }) else { throw WorkflowIssue("原调用记录不存在。") }
            try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
            let source = try WorkflowArchiveInspection.scopeSource(old, tools: tools, registry: registry)
            let resolved = try WorkflowScopePlanner.resolveCall(reference, source: source, tools: tools, registry: registry)
            guard let node = resolved.plan.steps.first?.node else { throw WorkflowIssue("具体调用为空。") }
            var checkpoint = WorkflowPlanCheckpoint(plan: resolved.plan, arguments: resolved.arguments)
            checkpoint.modelDefaults = resolved.modelDefaults; checkpoint.externalInputs = resolved.externalInputs
            var run = WorkflowRun(id: checkpoint.runID, graph: resolved.graph, targetNodeID: node.id, status: .running)
            run.scope = .init(selection: .only(node.id), originCall: reference, recomputeSelected: true)
            run.planCheckpoint = checkpoint
            try WorkflowArchiveInspection.validateScopeHistory(runs + [run], tools: tools, registry: registry)
            runs.append(run); activeRunID = run.id
            try await persist(); try await executePlan(runID: run.id)
        } catch { failure = error }
        await finishExecution(failure)
    }

    private func publicArguments(_ plan: WorkflowPlan, graph: WorkflowGraph) throws -> [String: WorkflowDatum] {
        var result: [String: WorkflowDatum] = [:]
        for field in plan.interface.inputs {
            if let input = graph.nodes.first(where: { $0.operationID == "d.value.input" && $0.parameters["publicName"]?.string == field.name }),
               let value = input.dataConfiguration?.value {
                try value.validate(as: field.type); result[field.name] = value
            } else if field.required { throw WorkflowIssue("公开输入尚未填写：\(field.name)。") }
        }
        return result
    }

    private func inputs(for node: WorkflowNode, run: WorkflowRun) throws -> [String: WorkflowValue] {
        var result: [String: WorkflowValue] = [:]
        for edge in run.graph.connections where edge.targetNode == node.id {
            let source = run.steps.last { $0.node.id == edge.sourceNode && [.completed, .partial].contains($0.status) }
                ?? reusable(nodeID: edge.sourceNode, graph: run.graph, inputs: nil)
            guard let value = source?.outputs[edge.sourcePort] else {
                throw WorkflowIssue("已连接的输入尚未就绪；先运行上游或完成确认。", nodeID: node.id, port: edge.targetPort)
            }
            result[edge.targetPort] = value
        }
        try registry.validateInputs(result, node: node, connectedPorts: Set(run.graph.connections.filter { $0.targetNode == node.id }.map(\.targetPort)))
        return result
    }
    private func capture(_ checkpoint: WorkflowPlanCheckpoint, runIndex: Int) {
        registerCollectionEvents(checkpoint.records, previous: runs[runIndex].planCheckpoint?.records ?? [])
        runs[runIndex].planCheckpoint = checkpoint
        // Top-level compatibility projection; nested records remain in the checkpoint.
        runs[runIndex].steps = checkpoint.records.filter { $0.address.path.count == 1 }.map(\.step)
        switch checkpoint.state {
        case .ready: runs[runIndex].status = .queued
        case .running: runs[runIndex].status = cancelled ? .cancelling : .running
        case .paused, .waiting: runs[runIndex].status = .waiting
        case .completed: runs[runIndex].status = .completed
        case .failed: runs[runIndex].status = .failed
        case .cancelled: runs[runIndex].status = checkpoint.records.contains { $0.step.status == .rejected } ? .rejected : .cancelled
        case .saving: runs[runIndex].status = .saving
        case .interrupted: runs[runIndex].status = .interrupted
        }
    }
    private func executePlan(runID: UUID, force: UUID? = nil) async throws {
        guard let ri = runs.firstIndex(where: { $0.id == runID }), let checkpoint = runs[ri].planCheckpoint else { throw WorkflowIssue("结构化恢复点不存在。") }
        if cancelled {
            var stopped = checkpoint; stopped.state = .cancelled
            for i in stopped.records.indices where [.queued, .running].contains(stopped.records[i].step.status) { stopped.records[i].step.status = .cancelled }
            capture(stopped, runIndex: ri); try await persist(); return
        }
        try services.beginPlan()
        let executor = WorkflowPlanExecutor(registry: registry, executeCall: { [unowned self] context in
            self.progressMessage = context.node.title
            let top = context.address?.path.count == 1
            let record = self.activeExecutor?.checkpoint?.records.first { $0.step.id == context.stepID }
            if top, self.runs[ri].scope?.recomputeSelected != true, force != context.node.id, record?.step.repeatRequested != true, record?.step.outputs.isEmpty == true, !services.hasPendingSaves,
               let cached = self.reusable(nodeID: context.node.id, graph: self.runs[ri].graph, inputs: context.inputs), cached.id != context.stepID {
                return .outputs(cached.outputs)
            }
            return try await self.services.executeCall(context)
        }, save: { [unowned self] value in
            self.capture(value, runIndex: ri)
            try await self.persist()
        }, executionRecords: { [unowned self] in self.services.executionRecords(for: $0) })
        activeExecutor = executor
        executor.pauseAvailabilityChanged = { [weak self, weak executor] ready in
            guard let self, self.activeExecutor === executor else { return }
            self.presentationHasExecutor = ready
        }
        do {
            let result = try await executor.execute(checkpoint)
            capture(result, runIndex: ri)
            setProgress(.init(result.state == .waiting ? "waitingDecision" : result.state == .paused ? "paused" : "runSaved"))
        } catch {
            if let latest = executor.checkpoint { capture(latest, runIndex: ri) }
            throw error
        }
    }
    /// Convert an old run only on explicit resume. No new Call is added or executed here.
    private func checkpointForResume(_ index: Int) throws -> WorkflowPlanCheckpoint {
        if let checkpoint = runs[index].planCheckpoint { return try WorkflowPlanExecutor.preparingRetry(checkpoint) }
        let run = runs[index]
        let full = try WorkflowPlanCompiler(registry: registry).compile(run.graph, tools: tools, target: run.targetNodeID,
            only: run.steps.count == 1 && run.steps.first?.node.id == run.targetNodeID)
        var checkpoint = WorkflowPlanCheckpoint(runID: run.id, plan: full)
        checkpoint.records = run.steps.map { .init(address: .init(runID: run.id, path: [.node($0.node.id)]), step: $0) }
        if full.steps.count == 1, let step = run.steps.first { checkpoint.externalInputs[step.node.id] = step.inputs }
        checkpoint.state = run.status == .saving ? .saving : .ready
        return try WorkflowPlanExecutor.preparingRetry(checkpoint)
    }
    public func pause() {
        guard canPausePresentation else { return }
        batchPauseRequested = true
        if activeBatchID == nil { activeExecutor?.requestPause() }
        setProgress(.init(activeBatchID == nil ? "pausePending" : "batchPausePending"))
    }

    /// A cancellation is terminal only after the operation drained and its model leases were released.
    private func finishExecution(_ failure: (any Error)?) async {
        await services.finish()
        let failedRun = runs.first { $0.id == activeRunID && ($0.status == .failed || $0.status == .saving) &&
            $0.planCheckpoint?.records.contains(where: { $0.address.path.count == 1 && $0.step.status == .failed }) == true }
        if let failedRun {
            errorMessage = failedRun.planCheckpoint?.error ?? failedRun.steps.last(where: { $0.status == .failed })?.error
            if let failure, !(failure is CancellationError),
               errorMessage?.contains(failure.localizedDescription) != true {
                errorMessage = [errorMessage, failure.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            }
            errorCode = failedRun.steps.last(where: { $0.status == .failed })?.errorCode ?? (failure as? WorkflowIssue)?.code
            setProgress(.init(failedRun.status == .saving || hasPendingSaves ? "failureRecordPending" : "failureRecordSaved"))
        } else if let failure, !(failure is CancellationError) {
            reportIssue(failure as? WorkflowIssue ?? WorkflowIssue(failure.localizedDescription))
            setProgress(.init("failed"))
        }
        if hasPendingSaves, failedRun == nil {
            setProgress(.init("savePending"))
            if errorMessage == nil { reportIssue(WorkflowIssue("运行记录或结果尚未保存，请恢复保存。", code: "workflow.status.pendingSave")) }
        } else if failedRun == nil && (failure is CancellationError || (failure == nil && runs.first(where: { $0.id == activeRunID })?.status == .cancelled)) {
            errorMessage = nil
            setProgress(.init("cancelled"))
        }
        await onChange()
    }

    public func cancel() async {
        guard isRunning else { return }
        if let id = activeRunID, let i = runs.firstIndex(where: { $0.id == id }) {
            if [.running, .queued, .cancelling].contains(runs[i].status) { runs[i].status = .cancelling }
            else if activeBatchID == nil { return }
        }
        cancelled = true
        setProgress(.init("cancelling"))
        activeExecutor?.requestStop()
        await services.cancel()
    }
    public func containerSnapshot(_ scope: WorkflowContainerScope) throws -> WorkflowContainerSnapshot {
        guard let projectID, let projectInstanceID, !closed, !closing,
              (scope.stageID == nil) != (scope.runID == nil), !scope.path.isEmpty else {
            throw WorkflowIssue("Container owner is unavailable.", code: "container.issue.targetChanged")
        }
        let stage = scope.stageID.flatMap { id in batchStages.first { $0.id == id } }
        if scope.stageID != nil && stage == nil { throw WorkflowIssue("Container stage is unavailable.", code: "container.issue.targetChanged") }
        let ids = stage?.attempts.map(\.runID) ?? [scope.runID!]
        let captured = try ids.map { id in
            guard let run = runs.first(where: { $0.id == id }) else { throw WorkflowIssue("Container run is unavailable.", code: "container.issue.targetChanged") }
            return run
        }
        return .init(projectID: projectID, instanceID: projectInstanceID, scope: scope, stage: stage, runs: captured)
    }

    /// May edit a settled waiting call while a different attempt is collecting.
    /// Draft changes never adopt a value or dispatch work.
    public func editContainerSelection(call: WorkflowCallReference, input: WorkflowValue, selectedIDs: [String]) throws {
        guard !closed, !closing, readOnlyReason == nil, !toolPublicationBusy,
              activeRunID != call.address.runID,
              let ri = runs.firstIndex(where: { $0.id == call.address.runID }),
              var cp = runs[ri].planCheckpoint,
              let ci = cp.records.firstIndex(where: { $0.address == call.address && $0.id == call.stepID }),
              cp.records[ci].step.node.operationID == WorkflowAssetContainer.filterID,
              cp.records[ci].step.status == .waiting, cp.records[ci].step.decision == nil,
              cp.records[ci].step.inputs["input"] == input else { throw WorkflowIssue("Container draft target changed.", code: "container.issue.targetChanged") }
        let items = try WorkflowAssetContainer.items(in: input), ids = Set(selectedIDs)
        guard ids.count == selectedIDs.count, ids.isSubset(of: Set(items.filter(\.selectable).map(\.id))) else {
            throw WorkflowIssue("Container draft contains unavailable items.", code: "container.issue.selectionUnavailable")
        }
        cp.records[ci].step.containerSelectionDraft = items.filter { ids.contains($0.id) }.map(\.id)
        capture(cp, runIndex: ri)
    }

    /// Save every exact decision and its continuation ledger in one transaction.
    /// The only executor used here is settlement-only; no upstream or downstream runs.
    @discardableResult public func submitContainer(_ expected: WorkflowContainerSnapshot,
        choices: [WorkflowContainerChoice], repetitions: Int = 1,
        seedStrategy: WorkflowBatchSeedStrategy = .fixed, endAll: Bool = false) async throws -> WorkflowContainerSubmission {
        guard !closed, !closing, !isRunning, !isSaving, !hasPendingSaves,
              !toolPublicationBusy, !externalOperationBusy(), readOnlyReason == nil,
              expected.projectID == projectID, expected.instanceID == projectInstanceID,
              (1...64).contains(repetitions) else { throw WorkflowIssue("Container cannot submit while work or saving is pending.", code: "container.issue.targetChanged") }
        if let previous = containerSubmissions.first(where: { $0.scope == expected.scope }) {
            guard previous.choices == choices, previous.repetitions == repetitions, previous.seedStrategy == seedStrategy else {
                throw WorkflowIssue("This container decision is already committed; start a new run to select differently.", code: "container.issue.alreadyCommitted")
            }
            return previous
        }
        guard try containerSnapshot(expected.scope) == expected, expected.collectionComplete else {
            throw WorkflowIssue("Wait for every scheduled attempt to reach its gate or terminal state.", code: "container.issue.targetChanged")
        }
        let calls = expected.calls.filter { $0.step.node.operationID == WorkflowAssetContainer.filterID && $0.step.status == .waiting && $0.step.decision == nil }
        guard !calls.isEmpty, choices.count == calls.count,
              zip(calls, choices).allSatisfy({ $0.address == $1.call.address && $0.id == $1.call.stepID }),
              endAll || choices.contains(where: { !$0.selectedIDs.isEmpty }) else {
            throw WorkflowIssue("Selection must identify every exact waiting call; empty selection requires explicit rejection.", code: "container.issue.selectionUnavailable")
        }
        isRunning = true; cancelled = false; defer { isRunning = false }
        let capturedRuns = runs, capturedBatches = batchStages
        var nextRuns = capturedRuns, nextBatches = capturedBatches
        for (call, choice) in zip(calls, choices) {
            guard let input = call.step.inputs["input"] else { throw WorkflowIssue("Missing container input.", code: "container.issue.targetChanged") }
            let output = choice.selectedIDs.isEmpty ? nil : try WorkflowAssetContainer.selecting(choice.selectedIDs, from: input)
            if let output { for ref in WorkflowAssetContainer.references(in: output) { try await services.verifyAsset(ref) } }
            guard try containerSnapshot(expected.scope) == expected else { throw WorkflowIssue("Container changed during validation.", code: "container.issue.targetChanged") }
            let decision = WorkflowDecision(waitingStepID: call.id, accepted: output != nil,
                selectedItemIDs: choice.selectedIDs, typedOutput: output)
            try WorkflowAssetContainer.validateDecision(decision, step: call.step)
            guard let ri = nextRuns.firstIndex(where: { $0.id == call.address.runID }),
                  var cp = nextRuns[ri].planCheckpoint,
                  let ci = cp.records.firstIndex(where: { $0.id == call.id && $0.address == call.address }) else { throw WorkflowIssue("Missing exact container call.", code: "container.issue.targetChanged") }
            cp.records[ci].step.decision = decision
            let settler = WorkflowPlanExecutor(registry: registry,
                executeCall: { _ in throw WorkflowIssue("Container settlement cannot execute a node.", code: "container.issue.targetChanged") }, save: { _ in })
            let settled = try await settler.settleWaiting(cp, stepID: call.id)
            nextRuns[ri].planCheckpoint = settled
            nextRuns[ri].steps = settled.records.filter { $0.address.path.count == 1 }.map(\.step)
            nextRuns[ri].status = decision.accepted ? .waiting : .rejected
            if let si = nextBatches.firstIndex(where: { $0.id == expected.scope.stageID }),
               let ai = nextBatches[si].attempts.firstIndex(where: { $0.runID == call.address.runID }) {
                nextBatches[si].attempts[ai].state = decision.accepted ? .waiting : .cancelled
            }
        }
        let parentIDs = choices.filter { !$0.selectedIDs.isEmpty }.map { $0.call.address.runID }
        let nextStage = try appendContainerContinuation(parentIDs: parentIDs, repetitions: repetitions,
            seedStrategy: seedStrategy, runs: &nextRuns, stages: &nextBatches)
        try await beforeContainerDecisionCommit()
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard runs == capturedRuns, batchStages == capturedBatches,
              try containerSnapshot(expected.scope) == expected else { throw WorkflowIssue("Container or another draft changed before commit; retry without losing either draft.", code: "container.issue.targetChanged") }
        try WorkflowArchiveInspection.validateScopeHistory(nextRuns, tools: tools, registry: registry)
        try WorkflowBatchValidation.validate(nextBatches, runs: nextRuns, registry: registry)
        let submission = WorkflowContainerSubmission(id: UUID(), scope: expected.scope, choices: choices,
            repetitions: repetitions, seedStrategy: seedStrategy, nextStageID: nextStage?.id, createdAt: Date())
        for run in nextRuns where expected.runs.contains(where: { $0.id == run.id }) {
            registerCollectionEvents(run.planCheckpoint?.records ?? [], previous: runs.first(where: { $0.id == run.id })?.planCheckpoint?.records ?? [])
        }
        runs = nextRuns; batchStages = nextBatches; containerSubmissions.append(submission)
        do { try await persist() }
        catch {
            let issue = WorkflowIssue(error.localizedDescription, code: "container.issue.decisionSavePending")
            reportIssue(issue); throw issue
        } // Same seeds/IDs remain for save-only recovery.
        await onChange()
        guard !cancelled else { throw CancellationError() }
        return submission
    }

    private func appendContainerContinuation(parentIDs: [UUID], repetitions: Int,
        seedStrategy: WorkflowBatchSeedStrategy, runs nextRuns: inout [WorkflowRun],
        stages nextBatches: inout [WorkflowBatchStage]) throws -> WorkflowBatchStage? {
        guard !parentIDs.isEmpty,
              parentIDs.allSatisfy({ id in nextRuns.first(where: { $0.id == id }).map { (try? WorkflowBatchValidation.acceptedPrefix($0)) != nil } == true }) else { return nil }
        guard Set(parentIDs).count == parentIDs.count, parentIDs.count <= 256 / repetitions,
              nextRuns.count + parentIDs.count * repetitions <= 4096 else { throw WorkflowIssue("Container continuation exceeds the bounded stage size.") }
        var children: [WorkflowRun] = []
        for id in parentIDs {
            guard let parent = nextRuns.first(where: { $0.id == id }) else { throw WorkflowIssue("Missing parent attempt.") }
            let cp = try WorkflowBatchValidation.acceptedPrefix(parent)
            let seeds = try WorkflowBatchSeedSchedule.allocate(plan: cp.plan, parent: cp,
                strategy: seedStrategy, count: repetitions, registry: registry, nextSeed: batchSeedSource)
            for index in 0..<repetitions {
                var child = try WorkflowBatchValidation.continuation(of: parent)
                child.planCheckpoint?.batchSeeds = seeds[index]; children.append(child)
            }
        }
        let stage = WorkflowBatchStage(name: "Container continuation", repetitions: repetitions, parentRunIDs: parentIDs,
            attempts: children.enumerated().map { .init(ordinal: $0.offset + 1, runID: $0.element.id) }, seedStrategy: seedStrategy, systemTitle: .continuation)
        nextRuns.append(contentsOf: children); nextBatches.append(stage)
        return stage
    }

    /// Explicitly finish a saved decision after other independent gates were handled.
    /// A retry reuses its dispatch key; it never re-settles or re-randomizes a prefix.
    public func continueContainerSubmission(_ expected: WorkflowContainerSubmission) async throws -> UUID? {
        guard !closed, !closing, !isRunning, !isSaving, !hasPendingSaves, readOnlyReason == nil,
              !externalOperationBusy(), !toolPublicationBusy,
              let index = containerSubmissions.firstIndex(where: { $0.id == expected.id }),
              containerSubmissions[index] == expected else { throw WorkflowIssue("Container continuation is stale or saving is pending.") }
        if let next = expected.nextStageID { return next }
        isRunning = true; cancelled = false; defer { isRunning = false }
        var updatedRuns = runs, updatedStages = batchStages
        let parents = expected.choices.filter { !$0.selectedIDs.isEmpty }.map { $0.call.address.runID }
        guard let stage = try appendContainerContinuation(parentIDs: parents, repetitions: expected.repetitions,
            seedStrategy: expected.seedStrategy, runs: &updatedRuns, stages: &updatedStages) else { return nil }
        try WorkflowArchiveInspection.validateScopeHistory(updatedRuns, tools: tools, registry: registry)
        try WorkflowBatchValidation.validate(updatedStages, runs: updatedRuns, registry: registry)
        runs = updatedRuns; batchStages = updatedStages; containerSubmissions[index].nextStageID = stage.id
        try await persist(); await onChange()
        guard !cancelled else { throw CancellationError() }
        return stage.id
    }

    public func retryContainerSaving(_ scope: WorkflowContainerScope) async throws -> WorkflowContainerSubmission {
        guard !closed, !closing, !isRunning, !isSaving, readOnlyReason == nil,
              let submission = containerSubmissions.first(where: { $0.scope == scope }) else { throw WorkflowIssue("No container save to recover.") }
        try await persist(); await onChange(); return submission
    }

    public func editHumanDraft(stepID: UUID, value: WorkflowDatum?) {
        guard !closed, !closing, readOnlyReason == nil, !isRunning, !toolPublicationBusy,
              let ri = runs.firstIndex(where: { $0.planCheckpoint?.records.contains { $0.step.id == stepID } == true }),
              let ci = runs[ri].planCheckpoint?.records.firstIndex(where: { $0.step.id == stepID }),
              runs[ri].planCheckpoint?.records[ci].step.status == .waiting,
              runs[ri].planCheckpoint?.records[ci].step.humanTask?.decision == nil else { return }
        do {
            try value?.validate()
            runs[ri].planCheckpoint?.records[ci].step.humanTask?.draft = value
            if let cp = runs[ri].planCheckpoint { capture(cp, runIndex: ri) }
        } catch { errorMessage = error.localizedDescription }
    }
    public func decideHuman(stepID: UUID, value: WorkflowDatum?, reject: Bool = false, expectedTask: WorkflowHumanTask) async {
        guard !closed, !closing, readOnlyReason == nil, !isRunning, !toolPublicationBusy else { return }
        isRunning = true; defer { isRunning = false }
        do {
            guard let ri = runs.firstIndex(where: { $0.planCheckpoint?.records.contains { $0.step.id == stepID } == true }),
                  var cp = runs[ri].planCheckpoint,
                  let ci = cp.records.firstIndex(where: { $0.step.id == stepID }),
                  var human = cp.records[ci].step.humanTask, human.id == stepID, human == expectedTask,
                  cp.records[ci].step.status == .waiting, human.decision == nil, !human.rejected,
                  waitingSnapshotIsCurrent(runs[ri]) else {
                throw WorkflowIssue("等待点或原图已改变；未应用到其他调用。")
            }
            if !reject {
                guard let value else { throw WorkflowIssue("请明确提供人工结果。") }
                try value.validate(as: human.resultSchema)
                for ref in value.assetReferences { try await services.verifyAsset(ref) }
            }
            guard waitingSnapshotIsCurrent(runs[ri]) else { throw WorkflowIssue("确认期间流程已改变。") }
            try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
            human.decision = reject ? nil : value; human.rejected = reject
            cp.records[ci].step.humanTask = human
            let executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in throw WorkflowIssue("提交人工结果不执行下游。") }, save: { [unowned self] latest in
                self.capture(latest, runIndex: ri); try await self.persist()
            })
            do { let settled = try await executor.settleWaiting(cp, stepID: stepID); capture(settled, runIndex: ri) }
            catch { if let latest = executor.checkpoint { capture(latest, runIndex: ri) }; throw error }
            if reject { setProgress(.init("rejected")) }
            else if human.kind == .approve {
                let waiting = runs[ri].planCheckpoint?.records.contains { $0.step.status == .waiting } == true
                setProgress(.init(waiting ? "judgmentSavedWaiting" : "judgmentSaved"))
            } else { setProgress(.init("resultSaved")) }
        } catch { errorMessage = error.localizedDescription }
    }
    public func callRecords(runID: UUID) -> [WorkflowPlanCallRecord] {
        runs.first { $0.id == runID }?.planCheckpoint?.records ?? []
    }
    private func waitingSnapshotIsCurrent(_ run: WorkflowRun) -> Bool {
        if batchStages.contains(where: { $0.attempts.contains(where: { $0.runID == run.id }) }) {
            return (try? WorkflowArchiveInspection.validateRun(run, tools: tools, registry: registry)) != nil && (try? WorkflowBatchValidation.validateParents(runs, registry: registry)) != nil
        }
        if run.scope?.originCall != nil { return belongsToSelectedWorkflow(run) }
        return rootGraph?.id == run.graph.id && rootGraph?.revision == run.graph.revision
    }
    private func canDecide(_ step: WorkflowStepRun, in run: WorkflowRun) -> Bool {
        if batchStages.contains(where: { $0.attempts.contains(where: { $0.runID == run.id }) }) { return waitingSnapshotIsCurrent(run) }
        if run.scope?.originCall != nil || !run.steps.contains(where: { $0.id == step.id }) { return waitingSnapshotIsCurrent(run) }
        if let scope = run.scope, !scope.historicalInputs.isEmpty {
            // An explicit historical boundary is not the latest upstream value.
            // Keep the selected graph frozen and validate the actual source chain,
            // both before publishing and again after the publication suspension.
            guard rootGraph == run.graph else { return false }
            do {
                try WorkflowArchiveInspection.validateRun(run, tools: tools, registry: registry)
                try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
                return true
            } catch { return false }
        }
        return belongsToSelectedWorkflow(run) && !isStale(step)
    }
    public func decide(stepID: UUID, accept: Bool, text: String?, candidateID: UUID?, acceptPartial: Bool) async {
        guard !closed, !closing, !isRunning, !toolPublicationBusy, readOnlyReason == nil else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            guard let ri = runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } || $0.planCheckpoint?.records.contains { $0.id == stepID } == true }),
                  let step = runs[ri].planCheckpoint?.records.first(where: { $0.id == stepID })?.step ?? runs[ri].steps.first(where: { $0.id == stepID }) else { throw WorkflowIssue("等待点不存在。") }
            if step.decision != nil { return } // Idempotent replay never creates a second derived asset.
            guard step.status == .waiting, canDecide(step, in: runs[ri]) else { throw WorkflowIssue("此等待点已经过期；原输入或连接已改变，请运行新的快照。") }
            var output: WorkflowAssetReference?
            if accept {
                if registry.operation(step.node.operationID)?.definition.interaction == .textReview {
                    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let parent = step.outputs["preview"]?.asset else { throw WorkflowIssue("确认文字不能为空。") }
                    output = try await services.publishText(text, parents: [parent], context: .init(node: step.node, stepID: step.id, inputs: step.inputs))
                } else {
                    let items = step.outputs["preview"]?.candidates ?? []
                    guard let chosen = items.first(where: { $0.id == candidateID }), let asset = chosen.asset,
                          acceptPartial || items.allSatisfy({ $0.asset != nil }) else { throw WorkflowIssue("请选择成功候选；部分集合需要明确同意。") }
                    try await services.verifyAsset(asset); output = asset
                }
            }
            guard canDecide(step, in: runs[ri]) else {
                throw WorkflowIssue("确认期间原输入已改变；派生资产保留，但未采用到新的流程。")
            }
            try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
            // Do not resume downstream here. Confirmation and expensive continuation are separate user actions.
            let decision = WorkflowDecision(waitingStepID: stepID, accepted: accept, selectedCandidateID: candidateID, output: output)
            if var cp = runs[ri].planCheckpoint, let ci = cp.records.firstIndex(where: { $0.step.id == stepID }) {
                cp.records[ci].step.decision = decision
                let executor = WorkflowPlanExecutor(registry: registry, executeCall: { _ in throw WorkflowIssue("提交决定不能运行节点。") }, save: { [unowned self] value in
                    self.capture(value, runIndex: ri); try await self.persist()
                })
                do { let settled = try await executor.settleWaiting(cp, stepID: stepID); capture(settled, runIndex: ri) }
                catch { if let latest = executor.checkpoint { capture(latest, runIndex: ri) }; throw error }
            } else {
                // Historical checkpoint-free wait: retain its established decision format.
                guard let si = runs[ri].steps.firstIndex(where: { $0.id == stepID }) else { throw WorkflowIssue("等待点不存在。") }
                runs[ri].steps[si].decision = decision
                runs[ri].steps[si].outputs = output.map { ["output": .asset($0)] } ?? [:]
                runs[ri].steps[si].status = accept ? .completed : .rejected
                runs[ri].status = accept ? .waiting : .rejected
                try await persist()
            }
            setProgress(.init(accept ? "decisionSaved" : "rejectedEmpty"))
            await onChange()
        } catch { errorMessage = error.localizedDescription }
    }
    /// Persist this exact run without admitting a calculation or accepting a human decision.
    /// A resumed computation still requires the separate explicit resume command.
    public func retryRunSaving(runID: UUID) async {
        guard !closed, !closing, !isRunning, !isSaving, !toolPublicationBusy,
              readOnlyReason == nil, !externalOperationBusy(),
              !batchStages.contains(where: { $0.attempts.contains(where: { $0.runID == runID }) }),
              !runs.contains(where: { $0.batchParent?.runID == runID }),
              let ri = runs.firstIndex(where: { $0.id == runID }),
              runs[ri].status == .saving || persistenceFailed,
              var cp = runs[ri].planCheckpoint else { return }
        isRunning = true; activeRunID = runID
        defer { isRunning = false; activeRunID = nil }
        func pausedIfReady(_ value: WorkflowPlanCheckpoint) -> WorkflowPlanCheckpoint {
            var copy = value
            if copy.state == .running || copy.state == .ready { copy.state = .paused }
            return copy
        }
        let saver = WorkflowPlanExecutor(registry: registry,
            executeCall: { _ in throw WorkflowIssue("保存恢复禁止计算。") },
            save: { [unowned self] value in
                self.capture(pausedIfReady(value), runIndex: ri)
                try await self.persist()
            })
        do {
            try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
            // A failed terminal write must never be fed to saveOnly's derived-state
            // recovery: every recorded step may already be complete at pause time.
            if pendingPausedStopRunID == runID {
                guard cp.state == .cancelled else { throw WorkflowIssue("待保存的停止记录已改变。") }
                try await persist(); pendingPausedStopRunID = nil
                errorMessage = nil; setProgress(.init("cancelled")); await onChange(); return
            }
            for record in cp.records where services.hasPendingPublication(stepID: record.id) {
                guard record.step.status == .saving else {
                    throw WorkflowIssue("此内容来自尚未保存的人工决定。请在原关卡再次保存决定；未计算或自动采用。")
                }
                guard let context = services.retainedPublicationContext(stepID: record.id),
                      context.node == record.step.node, context.inputs == record.step.inputs,
                      context.address == record.address else { throw WorkflowIssue("待保存内容与冻结调用不符。") }
                do {
                    let outputs = try await services.retryWorkflowPublications(context)
                    cp = try await saver.restorePublication(cp, stepID: record.id, outputs: outputs)
                } catch let failure as WorkflowOutputValidationFailure {
                    cp = try await saver.restorePublicationFailure(cp, stepID: record.id, failure: failure)
                }
            }
            cp = pausedIfReady(try await saver.saveOnly(cp))
            capture(cp, runIndex: ri)
            try await persist()
            for record in cp.records where [.completed, .partial, .failed].contains(record.step.status)
                && !services.hasPendingPublication(stepID: record.id) {
                services.acknowledgePublication(stepID: record.id)
            }
            if cp.state == .failed {
                errorMessage = cp.error
                setProgress(.init("failureRecordSaved"))
            } else { errorMessage = nil; setProgress(.init("workflowSaved")) }
            await onChange()
        } catch {
            if let latest = saver.checkpoint { capture(pausedIfReady(latest), runIndex: ri) }
            errorMessage = error.localizedDescription; setProgress(.init("savePending"))
        }
    }

    /// Paused plans have already drained. Persist the explicit terminal intent;
    /// a save failure retains it for a save-only retry, never a preparingRetry.
    public func stopPausedRun(runID: UUID) async {
        guard !closed, !closing, !isRunning, !isSaving, !hasPendingSaves, !toolPublicationBusy,
              readOnlyReason == nil, !externalOperationBusy(),
              !batchStages.contains(where: { $0.attempts.contains(where: { $0.runID == runID }) }),
              let ri = runs.firstIndex(where: { $0.id == runID }),
              var cp = runs[ri].planCheckpoint, cp.state == .paused else { return }
        isRunning = true; defer { isRunning = false }
        cp.state = .cancelled
        for i in cp.records.indices where cp.records[i].step.status == .running { cp.records[i].step.status = .cancelled }
        capture(cp, runIndex: ri)
        do { try await persist(); pendingPausedStopRunID = nil; errorMessage = nil; setProgress(.init("cancelled")); await onChange() }
        catch { pendingPausedStopRunID = runID; errorMessage = error.localizedDescription; setProgress(.init("savePending")) }
    }

    public func resume(runID: UUID) async {
        guard !runs.contains(where: { $0.batchParent?.runID == runID }) else { reportIssue(WorkflowIssue("This run is an adopted prefix. Continue its saved child stage instead.", code: "workflow.batch.issue.continuationExists")); return }
        guard pendingPausedStopRunID == nil else { errorMessage = "请先恢复停止状态的保存；没有重新计算。"; return }
        guard !batchStages.contains(where: { $0.attempts.contains(where: { $0.runID == runID }) }) else { errorMessage = "批次尝试保留固定结果；请使用继续所选，明确下一阶段次数。"; return }
        guard !externalOperationBusy() else { errorMessage = "请先结束录音或恢复保存，再恢复流程。"; return }
        guard !closed, !closing, !isRunning, !toolPublicationBusy, readOnlyReason == nil, let i = runs.firstIndex(where: { $0.id == runID }) else { return }
        if runs[i].scope?.originCall != nil {
            guard belongsToSelectedWorkflow(runs[i]) else { errorMessage = "请在原调用所属流程中恢复。"; return }
        } else {
            guard runs[i].graph.id == selectedGraphID, let current = rootGraph,
                  (runs[i].planCheckpoint?.plan.steps.map(\.node) ?? runs[i].steps.map(\.node)).allSatisfy({ (try? registry.signature($0.id, in: current, tools: tools)) == (try? registry.signature($0.id, in: runs[i].graph, tools: tools)) }) else {
                errorMessage = "当前流程已变化；旧运行保留，请运行新的快照。"; return
            }
        }
        guard runs[i].status != .rejected && runs[i].status != .completed else { return }
        editingOriginalID = editingRootID(for: runs[i]); editingCopies = [:]
        isRunning = true; cancelled = false; batchPauseRequested = false; errorMessage = nil
        defer { editingOriginalID = nil; editingCopies = [:]; isRunning = false; activeRunID = nil; activeExecutor = nil; streamingText = ""; streamingStepID = nil }
        var failure: (any Error)?
        do {
            try WorkflowArchiveInspection.validateScopeHistory(runs, tools: tools, registry: registry)
            activeRunID = runID
            let savingFailure = runs[i].status == .saving && runs[i].planCheckpoint?.records.contains {
                $0.address.path.count == 1 && $0.step.status == .failed
            } == true
            // Let the executor retain the failure diagnostics on every save
            // attempt. Saving a failed record must not prepare a calculation retry.
            if persistenceFailed && !savingFailure { try await persist() }
            let resumedCheckpoint = try checkpointForResume(i)
            runs[i].planCheckpoint = resumedCheckpoint
            activeRunID = runID
            try await executePlan(runID: runID)
        } catch { failure = error }
        await finishExecution(failure)
    }
    public func retryFailedCandidates(stepID: UUID) async {
        guard !externalOperationBusy() else { errorMessage = "请先结束录音或恢复保存，再重试候选。"; return }
        guard !closed, !closing, !isRunning, !toolPublicationBusy, readOnlyReason == nil,
              let ri = runs.firstIndex(where: { $0.steps.contains { $0.id == stepID } }),
              let si = runs[ri].steps.firstIndex(where: { $0.id == stepID }),
              registry.operation(runs[ri].steps[si].node.operationID)?.definition.modelKind == .image else { return }
        let old = runs[ri].steps[si]
        guard !hasPendingSaves else { errorMessage = "请先恢复保存记录或结果，再明确重试计算。"; return }
        guard !isStale(old), old.outputs["output"]?.candidates.contains(where: { $0.asset == nil }) == true else { return }
        editingOriginalID = editingRootID(for: runs[ri]); editingCopies = [:]
        isRunning = true; cancelled = false; batchPauseRequested = false; errorMessage = nil
        defer { editingOriginalID = nil; editingCopies = [:]; isRunning = false; activeRunID = nil; activeExecutor = nil; streamingText = ""; streamingStepID = nil }
        var failure: (any Error)?
        do {
            let frozen = runs[ri].graph

            var replacement = WorkflowStepRun(node: old.node, signature: old.signature, inputs: old.inputs)
            replacement.repeatRequested = true
            replacement.inputsBound = true
            replacement.outputs = old.outputs // Retry set survives save failure, cancellation and cold reopen.
            var retry = WorkflowRun(graph: frozen, targetNodeID: old.node.id, steps: [replacement], status: .running)
            let compiled = try WorkflowPlanCompiler(registry: registry).compile(frozen, tools: tools, target: old.node.id, only: true)
            var checkpoint = WorkflowPlanCheckpoint(runID: retry.id, plan: compiled)
            checkpoint.externalInputs[old.node.id] = old.inputs
            checkpoint.records = [.init(address: .init(runID: retry.id, path: [.node(old.node.id)]), step: replacement)]
            retry.planCheckpoint = checkpoint
            runs.append(retry); activeRunID = retry.id
            try await persist()
            try await executePlan(runID: retry.id, force: old.node.id)
            setProgress(.init("candidatesRetried"))
        } catch { failure = error }
        await finishExecution(failure)
    }
}
