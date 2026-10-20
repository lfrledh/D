import DWorkbench
import Foundation
import SwiftUI

@MainActor func workspaceText(_ language: UILanguageStore?, _ key: String, _ zh: String, _ en: String) -> String {
    metadataText(language, "workspace." + key, zh, en)
}

enum WorkflowResourceCategory: String, CaseIterable, Hashable {
    case all, text, image, video, audio, data
    var mode: WorkflowCanvasLibraryMode {
        switch self { case .all: .assets; case .text: .text; case .image: .image; case .video: .video; case .audio: .audio; case .data: .data }
    }
    @MainActor func title(_ language: UILanguageStore?) -> String {
        switch self {
        case .all: workspaceText(language,"all","全部","All")
        case .text: workspaceText(language,"text","文字","Text")
        case .image: workspaceText(language,"image","图像","Images")
        case .video: workspaceText(language,"video","视频","Video")
        case .audio: workspaceText(language,"audio","音频","Audio")
        case .data: workspaceText(language,"otherResources","其他","Other")
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
        return record.step.outputs[port] == value
    }
    @MainActor static func entries(_ controller: WorkflowController, language: UILanguageStore?) -> [SharedLibraryBrowserEntry] {
        guard let project = controller.projectID, let instance = controller.projectInstanceID else { return [] }
        return controller.runs.flatMap { run in
            WorkflowHumanPresentation.outputs(run).map { output in
                let snapshot = Self(projectID:project,instanceID:instance,call:.init(address:output.call.address,stepID:output.call.id),port:output.port,value:output.value,createdAt:run.createdAt)
                let state: String = output.call.step.status == .waiting
                    ? workspaceText(language,"candidate","待确认候选","Awaiting decision")
                    : output.value.asset != nil ? workspaceText(language,"saved","已保存资产","Saved asset")
                    : workspaceText(language,"runValue","运行内数据","Run value")
                let name = WorkflowHumanPresentation.name(output.call.step.node,in:WorkflowHumanPresentation.nodes(in:run),language:language)
                let title = name + " · " + WorkflowCanvasPresentation.portTitle(operationID:output.call.step.node.operationID,portID:output.port,fallback:output.port,input:false,language:language)
                let id = "run-value:" + instance.uuidString + ":" + output.storageKey
                var entry = SharedLibraryBrowserEntry(item:.init(key:id,title:title,
                    detail:state + " · " + run.createdAt.formatted(date:.abbreviated,time:.shortened),kind:.asset,role:"run-value",contentKind:snapshot.kind,readiness:.available,
                    assetFacts:.init(projectID:project,instanceID:instance,registeredAt:run.createdAt,
                        occurrences:[.init(runID:run.id,nodeID:output.call.step.node.id,stepID:output.call.id,address:output.call.address)])),
                    selection:.unavailable(state),facts:[WorkflowHumanPresentation.run(run,in:controller.runs,language:language),WorkflowHumanPresentation.call(output.call,in:WorkflowWorkspacePanels.records(in:run),language:language)],activityID:id)
                entry.runtimeValue = snapshot
                return entry
            }
        }
    }
}

/// A UI draft captures the real compiler slice and its owners. It does not resolve
/// runtime inputs, publish assets, mutate the graph or create an edit copy.
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
            && (mode < 2 || runs == controller.runs)
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
        for boundary in slice.boundaries where values[boundary.sourceNodeID] == nil { values[boundary.sourceNodeID] = .init(kind:mode == 1 ? .resolvedAtSubmit : .historicalInput,human:false) }
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
        case .recompute: workspaceText(language,"recompute","将重新计算","Recompute")
        case .mayReuse: workspaceText(language,"mayReuse","范围内，可能复用","In scope; may reuse")
        case .resolvedAtSubmit: workspaceText(language,"resolvedAtSubmit","提交时解析上游输入","Resolve upstream input at submission")
        case .historicalInput: historicalLabel.map { workspaceText(language,"selectedInput","已选历史输入","Historical input chosen")+" · "+$0 } ?? workspaceText(language,"historicalInput","需要历史输入","Historical input required")
        }
        return human ? base + " · " + workspaceText(language,"human","人工确认点","Human decision") : base
    }
}

struct WorkflowLibraryContext: Equatable {
    let project:UUID?
    let instance:UUID?
    let node:UUID
    let name:String
    func includes(_ entry:SharedLibraryBrowserEntry) -> Bool {
        guard let facts=entry.item.assetFacts, facts.projectID == project, facts.instanceID == instance else { return false }
        return facts.occurrences?.contains { $0.nodeID == node } == true
    }
}
private struct WorkflowLibraryContextKey:EnvironmentKey { static let defaultValue:WorkflowLibraryContext? = nil }
extension EnvironmentValues {
    var workflowLibraryContext:WorkflowLibraryContext? { get { self[WorkflowLibraryContextKey.self] } set { self[WorkflowLibraryContextKey.self]=newValue } }
}
