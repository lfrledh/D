import DWorkbench
import Foundation
import SwiftUI

@MainActor func workspaceText(_ language: UILanguageStore?, _ key: String, _ zh: String = "", _ en: String = "") -> String {
    metadataText(language, "workspace." + key, zh, en)
}

enum WorkflowResourceCategory: String, CaseIterable, Hashable {
    case all, text, image, video, audio, data
    var mode: WorkflowCanvasLibraryMode {
        switch self { case .all: .assets; case .text: .text; case .image: .image; case .video: .video; case .audio: .audio; case .data: .data }
    }
    @MainActor func title(_ language: UILanguageStore?) -> String {
        switch self {
        case .all: workspaceText(language, "all")
        case .text: workspaceText(language, "text")
        case .image: workspaceText(language, "image")
        case .video: workspaceText(language, "video")
        case .audio: workspaceText(language, "audio")
        case .data: workspaceText(language, "otherResources")
        }
    }
    func contains(_ kind: WorkflowDataKind?) -> Bool {
        switch self {
        case .all: true
        case .text: kind == .text || kind == .document
        case .image: kind == .image || kind == .images
        case .video: kind == .video
        case .audio: kind == .audio
        case .data: kind.map { ![.text,.document,.image,.images,.video,.audio].contains($0) } ?? true
        }
    }
}

/// Read-only projection. Its identity cannot be substituted by a row title or latest run.
struct WorkflowLibraryValue: Equatable {
    let projectID: UUID
    let instanceID: UUID
    let call: WorkflowCallReference
    let port: String
    let value: WorkflowValue
    let createdAt: Date
    var reference: WorkflowAssetReference? { value.asset }
    var annotationIdentity: WorkflowValueIdentity? {
        // Registered assets retain their existing ProjectStore annotation owner.
        guard reference == nil else { return nil }
        return try? WorkflowValueIdentity(projectID: projectID, instanceID: instanceID, call: call, port: port, value: value)
    }
    @MainActor func saveAnnotation(in controller: WorkflowController, library: SharedLibraryStore,
        expected: WorkflowValueAnnotation?, value: WorkflowValueAnnotation) throws {
        guard isCurrent(in: controller), let identity = annotationIdentity else { throw SharedLibraryError.staleAnnotation }
        try library.saveRuntimeAnnotation(identity: identity, expected: expected, value: value)
    }
    var kind: WorkflowDataKind? {
        switch value {
        case .asset(let ref): ref.kind
        case .collection: .images
        case .receipt: .receipt
        case .data(let data): data.kind
        }
    }
    @MainActor func isCurrent(in controller: WorkflowController) -> Bool {
        guard controller.canReadLibraryMetadata, controller.projectID == projectID,
              controller.projectInstanceID == instanceID,
              let run = controller.runs.first(where: { $0.id == call.address.runID }),
              let record = WorkflowWorkspacePanels.records(in: run).first(where: { $0.address == call.address && $0.id == call.stepID }) else { return false }
        guard let current = record.step.outputs[port],
              let captured = try? WorkflowValueIdentity(projectID: projectID, instanceID: instanceID, call: call, port: port, value: value),
              let latest = try? WorkflowValueIdentity(projectID: projectID, instanceID: instanceID, call: call, port: port, value: current) else { return false }
        return captured == latest
    }
    @MainActor static func entries(_ controller: WorkflowController, language: UILanguageStore?, excludingSaved: Set<WorkflowAssetReference> = [], library: SharedLibraryStore? = nil, indexedSaved: [ProjectAssetMetadataSnapshot] = []) -> [SharedLibraryBrowserEntry] {
        guard let project = controller.projectID, let instance = controller.projectInstanceID else { return [] }
        return controller.runs.flatMap { run in
            WorkflowHumanPresentation.outputs(run).compactMap { output -> SharedLibraryBrowserEntry? in
                if output.call.step.status != .waiting, let reference = output.value.asset, excludingSaved.contains(reference),
                   indexedSaved.contains(where: { snapshot in
                       snapshot.projectID == project && snapshot.instanceID == instance && snapshot.record?.reference == reference
                       && snapshot.occurrences?.contains { $0.runID == run.id && $0.stepID == output.call.id && ($0.address == output.call.address || (run.planCheckpoint == nil && output.call.address.path.isEmpty && $0.address == nil)) } == true
                   }) { return nil }
                let snapshot = Self(projectID:project,instanceID:instance,call:.init(address:output.call.address,stepID:output.call.id),port:output.port,value:output.value,createdAt:run.createdAt)
                let state: String = output.call.step.status == .waiting
                    ? workspaceText(language, "candidate")
                    : output.value.asset != nil ? workspaceText(language, "saved")
                    : workspaceText(language, "runValue")
                let name = WorkflowHumanPresentation.name(output.call.step.node,in:WorkflowHumanPresentation.nodes(in:run),language:language)
                let defaultTitle = name + " · " + WorkflowCanvasPresentation.portTitle(operationID:output.call.step.node.operationID,portID:output.port,fallback:output.port,input:false,language:language)
                let id = snapshot.annotationIdentity?.storageKey ?? ("run-value:" + instance.uuidString + ":" + output.storageKey)
                let annotation = library?.metadata.runtimeAnnotations[id]
                let title = annotation?.name ?? defaultTitle
                var entry = SharedLibraryBrowserEntry(item:.init(key:id,title:title,
                    detail:state + " · " + run.createdAt.formatted(date:.abbreviated,time:.shortened),kind:.asset,role:"run-value",contentKind:snapshot.kind,readiness:.available,
                    assetFacts:.init(projectID:project,instanceID:instance,note:annotation?.note ?? "",favorite:annotation?.favorite ?? false,registeredAt:run.createdAt,
                        occurrences:[.init(runID:run.id,nodeID:output.call.step.node.id,stepID:output.call.id,address:output.call.address)]),
                    facts: WorkflowValueCompatibility.facts(output.value, producer: output.call.step.node.operationID)),
                    selection:.unavailable(state),facts:[WorkflowHumanPresentation.run(run,in:controller.runs,language:language),WorkflowHumanPresentation.call(output.call,in:WorkflowWorkspacePanels.records(in:run),language:language)],activityID:id)
                entry.runtimeValue = snapshot
                return entry
            }
        }
    }
}

/// A UI draft captures the real compiler slice and its owners. It does not resolve
/// runtime inputs, publish assets, mutate the graph or create an edit copy.
/// Presentation draft only. Retained by the canvas while settings and plan come and go.
struct WorkflowWorkspaceRunOptions: Equatable {
    var batch = false
    var repetitions = 1
    var seedStrategy: WorkflowBatchSeedStrategy = .fixed
    var choices: [String: WorkflowCallReference] = [:]
}

struct WorkflowWorkspaceRunDraft: Identifiable {
    let id = UUID()
    let owner: ObjectIdentifier
    let project: UUID?
    let instance: UUID?
    let graph: WorkflowGraph
    let tools: [WorkflowToolDefinition]
    let defaults: [String:String]
    let target: UUID
    let mode: Int
    let slice: WorkflowScopeSlice
    let runs: [WorkflowRun]
    var selection: WorkflowGraphSelection { Self.selection(target:target,mode:mode) }
    static func selection(target: UUID, mode: Int) -> WorkflowGraphSelection {
        switch mode { case 1: .only(target); case 2: .downstream(target,includingAnchor:true); case 3: .downstream(target,includingAnchor:false); default: .through(target) }
    }
    @MainActor init(controller:WorkflowController,target:UUID,mode:Int) throws {
        guard let graph=controller.rootGraph,controller.bodyPath.isEmpty else { throw WorkflowIssue("Root workflow required / 需要在主流程中查看运行计划。") }
        self.owner=ObjectIdentifier(controller);project=controller.projectID;instance=controller.projectInstanceID
        self.graph=graph;tools=controller.tools;defaults=controller.services.capturedModelDefaults()
        self.target=target;self.mode=mode; runs=controller.runs
        slice=try WorkflowScopePlanner.select(graph:graph,selection:Self.selection(target:target,mode:mode),tools:controller.tools,registry:controller.registry)
    }
    @MainActor func isCurrent(in controller:WorkflowController) -> Bool {
        owner == ObjectIdentifier(controller) && project == controller.projectID && instance == controller.projectInstanceID
            && graph == controller.rootGraph && tools == controller.tools && defaults == controller.services.capturedModelDefaults()
            && controller.bodyPath.isEmpty && controller.canReadLibraryMetadata
            && (mode == 0 || runs == controller.runs)
    }
    /// Each row is one dependency frontier; siblings have no invented serial arrow.
    static func layers(_ plan: WorkflowPlan) -> [[WorkflowPlannedStep]] {
        var remaining=plan.steps, completed=Set<UUID>(), result:[[WorkflowPlannedStep]]=[]
        let ids=Set(remaining.map(\.id))
        while !remaining.isEmpty {
            let layer=remaining.filter { Set($0.inputs.map(\.sourceNode)).intersection(ids).isSubset(of:completed) }
            guard !layer.isEmpty else { return result + [remaining] }
            result.append(layer); let found=Set(layer.map(\.id)); completed.formUnion(found);remaining.removeAll { found.contains($0.id) }
        }
        return result
    }
    var marks: [UUID:WorkflowPlanMark] {
        var values=Dictionary(uniqueKeysWithValues:slice.plan.steps.map { ($0.id, WorkflowPlanMark(kind:mode == 0 ? .mayReuse : .recompute,human:$0.effect == .human)) })
        for boundary in slice.boundaries where values[boundary.sourceNodeID] == nil { values[boundary.sourceNodeID] = .init(kind:.historicalInput,human:false) }
        return values
    }
}

struct WorkflowPlanMark: Equatable {
    enum Kind { case recompute, mayReuse, historicalInput, resolvedAtSubmit }
    let kind:Kind
    let human:Bool
    var historicalLabel:String? = nil
    var icon:String { human ? "person.crop.circle.badge.checkmark" : (kind == .historicalInput || kind == .resolvedAtSubmit) ? "tray.and.arrow.down" : kind == .mayReuse ? "arrow.trianglehead.2.clockwise" : "play.fill" }
    @MainActor func title(_ language:UILanguageStore?) -> String {
        let base = switch kind {
        case .recompute: workspaceText(language, "recompute")
        case .mayReuse: workspaceText(language, "mayReuse")
        case .resolvedAtSubmit: workspaceText(language, "resolvedAtSubmit")
        case .historicalInput: historicalLabel.map { workspaceText(language, "selectedInput")+" · "+$0 } ?? workspaceText(language, "historicalInput")
        }
        return human ? base + " · " + workspaceText(language, "human") : base
    }
}

/// Temporary, owner-bound navigation. Never stored as a saved query or executed.
struct WorkflowLibraryContext: Equatable {
    enum Source: Equatable {
        case node(UUID)
        case run(UUID)
        case call(WorkflowCallReference)
        case attempt(stage: UUID, attempt: UUID, run: UUID)
    }
    let project: UUID?
    let instance: UUID?
    let source: Source
    let name: String
    private let owner: ObjectIdentifier?
    private let legacyFlat: Bool
    init(project: UUID?, instance: UUID?, node: UUID, name: String) {
        self.project = project; self.instance = instance; source = .node(node); self.name = name
        owner = nil; legacyFlat = false
    }
    @MainActor init(controller: WorkflowController, source: Source, name: String) {
        project = controller.projectID; instance = controller.projectInstanceID
        owner = ObjectIdentifier(controller); self.source = source; self.name = name
        if case .call(let call) = source {
            legacyFlat = controller.runs.first { $0.id == call.address.runID }?.planCheckpoint == nil
        } else { legacyFlat = false }
    }
    @MainActor func isCurrent(in controller: WorkflowController) -> Bool {
        guard (owner == nil || owner == ObjectIdentifier(controller)), controller.canReadLibraryMetadata,
              controller.projectID == project, controller.projectInstanceID == instance else { return false }
        switch source {
        case .node(let id): return controller.graph?.nodes.contains { $0.id == id } == true
        case .run(let id): return controller.runs.contains { $0.id == id }
        case .call(let call):
            return controller.runs.first { $0.id == call.address.runID }.map { run in
                WorkflowWorkspacePanels.records(in: run).contains { $0.address == call.address && $0.id == call.stepID }
            } ?? false
        case .attempt(let stage, let attempt, let run):
            return controller.batchStages.first { $0.id == stage }?.attempts.contains { $0.id == attempt && $0.runID == run } == true
                && controller.runs.contains { $0.id == run }
        }
    }
    @MainActor func displayName(in controller: WorkflowController, language: UILanguageStore?) -> String {
        let runID: UUID
        switch source {
        case .node: return name
        case .run(let id), .attempt(_, _, let id): runID = id
        case .call(let call): runID = call.address.runID
        }
        guard let run = controller.runs.first(where: { $0.id == runID }) else { return name }
        let title = WorkflowHumanPresentation.run(run, in: controller.runs, language: language)
        if case .call(let call) = source, let record = WorkflowWorkspacePanels.records(in: run).first(where: { $0.address == call.address && $0.id == call.stepID }) {
            return title + " · " + WorkflowHumanPresentation.name(record.step.node, in: WorkflowHumanPresentation.nodes(in: run), language: language) + " · " + WorkflowHumanPresentation.call(record, in: WorkflowWorkspacePanels.records(in: run), language: language)
        }
        return title
    }
    func includes(_ entry: SharedLibraryBrowserEntry) -> Bool {
        guard let facts = entry.item.assetFacts, facts.projectID == project, facts.instanceID == instance else { return false }
        if case .node = source {} else if let snapshot = entry.metadataSnapshot, snapshot.record == nil {
            // A merged occurrence list across versions cannot identify the bytes of this result.
            return false
        }
        return facts.occurrences?.contains { occurrence in
            switch source {
            case .node(let id): return occurrence.nodeID == id
            case .run(let id), .attempt(_, _, let id): return occurrence.runID == id
            case .call(let call):
                return occurrence.runID == call.address.runID && occurrence.stepID == call.stepID
                    && (occurrence.address == call.address || (legacyFlat && call.address.path.isEmpty && occurrence.address == nil))
            }
        } == true
    }
}
private struct WorkflowLibraryContextKey:EnvironmentKey { static let defaultValue:WorkflowLibraryContext? = nil }
extension EnvironmentValues {
    var workflowLibraryContext:WorkflowLibraryContext? { get { self[WorkflowLibraryContextKey.self] } set { self[WorkflowLibraryContextKey.self]=newValue } }
}
