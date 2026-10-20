import DWorkbench
import SwiftUI

@MainActor struct WorkflowWorkspaceRunPlan: View {
    let controller:WorkflowController
    let draft:WorkflowWorkspaceRunDraft
    let close:() -> Void
    var inputsChanged:([UUID:String])->Void = { _ in }
    let preview:(WorkflowValue,WorkflowCallReference,String) -> Void
    @Environment(\.dLanguageStore) private var language
    @Environment(\.workbenchModelReadiness) private var readiness
    @State private var choices:[String:WorkflowCallReference]=[:]
    @State private var batch = false
    @State private var repetitions = 1
    private func text(_ key:String,_ zh:String,_ en:String)->String { workspaceText(language,key,zh,en) }
    private func key(_ boundary:WorkflowScopeBoundary)->String { boundary.destinationNodeID.uuidString+":"+boundary.destinationPort }
    private var current:Bool { draft.isCurrent(in:controller) }
    private var pins:[WorkflowHistoricalInput] {
        draft.slice.boundaries.compactMap { boundary in
            guard let choice=choices[key(boundary)],controller.historicalCalls(for:boundary).contains(where:{$0.address == choice.address && $0.id == choice.stepID}) else { return nil }
            return .init(destinationNodeID:boundary.destinationNodeID,destinationPort:boundary.destinationPort,sourceCall:choice,sourcePort:boundary.sourcePort)
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(text("plan","运行计划","Run plan")).font(.headline)
                Text(draft.graph.nodes.first { $0.id == draft.target }?.title ?? text("missing","不可访问","Unavailable")).lineLimit(2)
                Spacer()
                Button(text("close","关闭计划","Close plan"),systemImage:"xmark",action:close)
            }
            if !current { Label(text("stalePlan","流程、模型或历史输入已变化，请关闭后重新检查。","Workflow, models or historical inputs changed. Close and review again."),systemImage:"exclamationmark.triangle").foregroundStyle(.orange) }
            HStack {
                Toggle(text("batchGenerate", "批量生成", "Generate a batch"), isOn: $batch)
                if batch {
                    Stepper(text("stageCount", "本阶段次数", "Attempts this stage") + " \(repetitions)", value: $repetitions, in: 1...64)
                    Text(text("batchSeed", "串行执行至人工关卡；使用固定配方中的种子，结果可能相同。", "Run serially to review gates. Retain configured seeds; results may match.")).font(.caption)
                }
            }
            WorkbenchScrollView {
                VStack(alignment:.leading,spacing:10) {
                    Text(batch ? text("batchFresh", "每次尝试独立计算所选范围；范围外输入固定为明确选择的历史结果。", "Each attempt computes the selected range independently; external inputs remain pinned to the chosen historical results.") : draft.mode == 0 ? text("reuseNote","范围内的节点仍可能按原规则复用；提交时再校验。","In-scope steps may reuse results under existing rules; admission revalidates them.") : draft.mode == 1 ? text("singleNote","只重新计算所选节点；上游输入由原单步运行入口在提交时解析，当前尚未固定。","Recompute only this node. The existing single-step command resolves reusable upstream inputs at submission; they are not pinned yet.") : text("boundaryNote","只计算范围内节点；每个外部输入都要选择明确的历史调用，不自动替换为最新结果。","Compute only in-scope nodes. Choose an exact historical call for every external input; no automatic latest-result substitution."))
                        .font(.callout).foregroundStyle(.secondary)
                    let layers=WorkflowWorkspaceRunDraft.layers(draft.slice.plan)
                    ForEach(layers.indices,id:\.self) { index in
                        VStack(alignment:.leading,spacing:5) {
                            Text(text("frontier","依赖层","Dependency layer")+" \(index+1)").font(.caption.weight(.semibold))
                            ForEach(layers[index]) { step in
                                HStack {
                                    let mark=draft.marks[step.id]!
                                    Label(WorkflowHumanPresentation.name(step.node,in:draft.graph.nodes,language:language),systemImage:mark.icon)
                                    Text(mark.title(language)).font(.caption).foregroundStyle(.secondary)
                                }
                                if let definition=controller.registry.definition(for:step.node,tools:draft.tools),let kind=definition.modelKind {
                                    let modelID=step.node.parameters["modelID"]?.string ?? draft.defaults[kind.rawValue]
                                    WorkbenchModelCard(definition:definition,modelID:modelID,choices:controller.modelChoices,
                                        status:workbenchModelReadinessText(readiness[modelID ?? ""] ?? .unknown,language:language),usingDefault:step.node.parameters["modelID"]?.string == nil)
                                }
                            }
                        }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    if draft.mode >= 2 || batch {
                        ForEach(Array(draft.slice.boundaries.enumerated()),id:\.offset) { _,boundary in boundaryPicker(boundary) }
                    } else if !draft.slice.boundaries.isEmpty {
                        ForEach(Array(draft.slice.boundaries.enumerated()),id:\.offset) { _,boundary in
                            Text(name(boundary.sourceNodeID)+" · "+boundary.sourcePort+" → "+name(boundary.destinationNodeID)+" · "+boundary.destinationPort)
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                    DisclosureGroup(text("planIdentity","固定计划身份","Fixed plan identity")) {
                        WorkflowTechnicalDetails(value:"\(draft.project) / \(draft.instance)\n\(draft.graph.id) / \(draft.graph.revision)\n\(draft.target)")
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack {
                Text(text("noComputePreview","查看计划不会运行或修改流程。","Reviewing a plan does not run or edit the workflow.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(batch ? text("batchStart", "开始本阶段生成", "Start this stage") + " ×\(repetitions)" : text("submit","明确提交运行","Submit run"),systemImage:"play.fill") {
                    guard current else { return }
                    let inputs=pins, isBatch=batch, count=repetitions
                    guard (!batch && draft.mode < 2) || inputs.count == draft.slice.boundaries.count else { return }
                    close()
                    Task {
                        guard draft.isCurrent(in:controller) else { controller.errorMessage=text("stalePlan","计划已改变，请重新检查。","Plan changed; review again.");return }
                        if isBatch {
                            do {
                                let id = try await controller.createBatchStage(selection: draft.selection, pins: inputs,
                                    repetitions: count, expectedGraphID: draft.graph.id, expectedRevision: draft.graph.revision)
                                await controller.runBatchStage(id)
                            } catch { controller.errorMessage = error.localizedDescription }
                        } else if draft.mode < 2 { await controller.run(target:draft.target,only:draft.mode == 1) }
                        else { await controller.runScoped(draft.selection,pins:inputs,expectedGraphID:draft.graph.id,expectedRevision:draft.graph.revision) }
                    }
                }.buttonStyle(WorkbenchPrimaryButtonStyle())
                    .disabled(!current || !controller.canEditCanvas || controller.isRunning || ((draft.mode >= 2 || batch) && pins.count != draft.slice.boundaries.count))
                    .accessibilityIdentifier("workflow-run-preview-submit")
            }
        }.padding(14)
            .onChange(of:choices) { _,_ in
                var labels:[UUID:String]=[:]
                for boundary in draft.slice.boundaries {
                    if let choice=choices[key(boundary)],let run=controller.runs.first(where:{$0.id == choice.address.runID}) {
                        labels[boundary.sourceNodeID]=run.createdAt.formatted(date:.abbreviated,time:.shortened)
                    }
                }
                inputsChanged(labels)
            }
    }
    private func name(_ id:UUID)->String { draft.graph.nodes.first { $0.id == id }.map { WorkflowHumanPresentation.name($0,in:draft.graph.nodes,language:language) } ?? text("missing","不可访问","Unavailable") }
    private func boundaryPicker(_ boundary:WorkflowScopeBoundary)->some View {
        let records=controller.historicalCalls(for:boundary)
        return VStack(alignment:.leading,spacing:6) {
            Text(name(boundary.sourceNodeID)+" · "+boundary.sourcePort+" → "+name(boundary.destinationNodeID)+" · "+boundary.destinationPort).font(.subheadline)
            WorkbenchPicker(text("chooseInput","选择历史输入","Choose historical input"),selection:Binding<UUID?>(get:{choices[key(boundary)]?.stepID},set:{ id in
                choices[key(boundary)]=records.first { $0.id == id }.map { .init(address:$0.address,stepID:$0.id) }
            })) {
                WorkbenchChoice(text("none","请选择具体调用","Choose an exact call"),value:UUID?.none)
                WorkbenchChoiceForEach(records) { call in
                    WorkbenchChoice((controller.runs.first { $0.id == call.address.runID }.map { WorkflowHumanPresentation.run($0,in:controller.runs,language:language) } ?? text("missing","不可访问","Unavailable"))+" · "+WorkflowHumanPresentation.call(call,in:records,language:language),value:Optional(call.id))
                }
            }.disabled(!current)
            if let choice=choices[key(boundary)],let call=records.first(where:{$0.address == choice.address && $0.id == choice.stepID}),let value=call.step.outputs[boundary.sourcePort] {
                Button(text("previewInput","查看所选输入","Preview chosen input"),systemImage:"arrow.up.right.square") { preview(value,choice,name(boundary.sourceNodeID)) }
            }
        }.padding(8)
    }
}

struct WorkflowPlanBadge:View {
    let mark:WorkflowPlanMark
    let scale:CGFloat
    @Environment(\.dLanguageStore) private var language
    @Environment(\.workbenchModelReadiness) private var readiness
    var body:some View {
        RoundedRectangle(cornerRadius:13*scale,style:.continuous)
            .strokeBorder(mark.kind == .historicalInput ? Color.orange : Color.accentColor,style:StrokeStyle(lineWidth:2*scale,dash:mark.kind == .mayReuse ? [6*scale,4*scale] : []))
            .overlay(alignment:.bottom) {
                Label(mark.title(language),systemImage:mark.icon).font(.system(size:10*scale,weight:.semibold))
                    .padding(3*scale).background(.background,in:RoundedRectangle(cornerRadius:4*scale))
                    .offset(y:10*scale)
            }.allowsHitTesting(false).accessibilityLabel(mark.title(language))
    }
}
