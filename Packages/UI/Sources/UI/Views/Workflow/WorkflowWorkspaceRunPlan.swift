import DWorkbench
import SwiftUI

@MainActor struct WorkflowWorkspaceRunPlan: View {
    let controller:WorkflowController
    let draft:WorkflowWorkspaceRunDraft
    let close:() -> Void
    var inputsChanged:([UUID:String])->Void = { _ in }
    let preview:(WorkflowValue,WorkflowCallReference,String,String) -> Void
    @Environment(\.dLanguageStore) private var language
    @Environment(\.workbenchModelReadiness) private var readiness
    @Binding var options: WorkflowWorkspaceRunOptions
    var settings: () -> Void = {}
    private func text(_ key: String) -> String { workspaceText(language, key) }
    private func key(_ boundary:WorkflowScopeBoundary)->String { boundary.destinationNodeID.uuidString+":"+boundary.destinationPort }
    private var current:Bool { draft.isCurrent(in:controller) }
    private var pins:[WorkflowHistoricalInput] {
        draft.slice.boundaries.compactMap { boundary in
            guard let choice=options.choices[key(boundary)],controller.historicalCalls(for:boundary).contains(where:{$0.address == choice.address && $0.id == choice.stepID}) else { return nil }
            return .init(destinationNodeID:boundary.destinationNodeID,destinationPort:boundary.destinationPort,sourceCall:choice,sourcePort:boundary.sourcePort)
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(text("plan")).font(.headline)
                Text(draft.graph.nodes.first { $0.id == draft.target }?.title ?? text("missing")).lineLimit(2)
                Spacer()
                Button(text("close"),systemImage:"xmark",action:close)
            }
            if !current { Label(text("stalePlan"),systemImage:"exclamationmark.triangle").foregroundStyle(.orange) }
            WorkbenchScrollView {
                VStack(alignment:.leading,spacing:10) {
                    Text(options.batch ? text("batchFresh") : draft.mode == 0 ? text("reuseNote") : draft.mode == 1 ? text("singleNote") : text("boundaryNote"))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(workflowText(language, "workflow.dock.range." + String(draft.mode))).font(.subheadline)
                    if draft.mode >= 1 || options.batch {
                        ForEach(Array(draft.slice.boundaries.enumerated()),id:\.offset) { _,boundary in boundaryPicker(boundary) }
                    }
                    DisclosureGroup(workflowText(language, "workflow.dock.steps")) {
                    let layers=WorkflowWorkspaceRunDraft.layers(draft.slice.plan)
                    ForEach(layers.indices,id:\.self) { index in
                        VStack(alignment:.leading,spacing:5) {
                            Text(text("frontier")+" \(index+1)").font(.caption.weight(.semibold))
                            ForEach(layers[index]) { step in
                                HStack {
                                    let mark=draft.marks(batch: options.batch)[step.id]!
                                    Label(WorkflowHumanPresentation.name(step.node,in:draft.graph.nodes,language:language),systemImage:mark.icon)
                                    Text(mark.title(language)).font(.caption).foregroundStyle(.secondary)
                                        .help(mark.kind == .mayReuse ? text("mayReuse.help") : mark.title(language))
                                }
                                if let definition=controller.registry.definition(for:step.node,tools:draft.tools),let kind=definition.modelKind {
                                    let modelID=step.node.parameters["modelID"]?.string ?? draft.defaults[kind.rawValue]
                                    WorkbenchModelCard(definition:definition,modelID:modelID,choices:controller.modelChoices,
                                        status:workbenchModelReadinessText(readiness[modelID ?? ""] ?? .unknown,language:language),usingDefault:step.node.parameters["modelID"]?.string == nil)
                                }
                            }
                        }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    }
                    DisclosureGroup(text("planIdentity")) {
                        WorkflowTechnicalDetails(value:"\(draft.project) / \(draft.instance)\n\(draft.graph.id) / \(draft.graph.revision)\n\(draft.target)")
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack {
                Button(workflowText(language, "workflow.dock.settings"), action: settings)
                Spacer()
                Button(options.batch ? text("batchStart") + " ×\(options.repetitions)" : text("submit"),systemImage:"play.fill") {
                    guard current else { return }
                    let inputs=pins, isBatch=options.batch, count=options.repetitions, selectedSeed=options.seedStrategy
                    guard (!options.batch && draft.mode == 0) || inputs.count == draft.slice.boundaries.count else { return }
                    close()
                    Task {
                        guard draft.isCurrent(in:controller) else { controller.errorMessage=text("stalePlan");return }
                        if isBatch {
                            do {
                                let id = try await controller.createBatchStage(selection: draft.selection, pins: inputs,
                                    repetitions: count, expectedGraphID: draft.graph.id, expectedRevision: draft.graph.revision, seedStrategy: selectedSeed)
                                await controller.runBatchStage(id)
                            } catch { controller.reportIssue(error as? WorkflowIssue ?? WorkflowIssue(error.localizedDescription)) }
                        } else if draft.mode == 0 { await controller.run(target:draft.target,only:false) }
                        else { await controller.runScoped(draft.selection,pins:inputs,expectedGraphID:draft.graph.id,expectedRevision:draft.graph.revision) }
                    }
                }.buttonStyle(WorkbenchPrimaryButtonStyle())
                    .disabled(!current || !controller.canEditCanvas || controller.isRunning || ((draft.mode >= 1 || options.batch) && pins.count != draft.slice.boundaries.count))
                    .accessibilityIdentifier("workflow-run-preview-submit")
            }.environment(\.workbenchActionHeight, 36)
        }.padding(14).buttonStyle(WorkbenchGlassButtonStyle())
            .onChange(of:options.choices, initial: true) { _,_ in
                var labels:[UUID:String]=[:]
                for boundary in draft.slice.boundaries {
                    if let choice=options.choices[key(boundary)],let run=controller.runs.first(where:{$0.id == choice.address.runID}) {
                        labels[boundary.sourceNodeID]=run.createdAt.formatted(date:.abbreviated,time:.shortened)
                    }
                }
                inputsChanged(labels)
            }
    }
    private func name(_ id:UUID)->String { draft.graph.nodes.first { $0.id == id }.map { WorkflowHumanPresentation.name($0,in:draft.graph.nodes,language:language) } ?? text("missing") }
    private func boundaryPicker(_ boundary:WorkflowScopeBoundary)->some View {
        let records=controller.historicalCalls(for:boundary)
        return VStack(alignment:.leading,spacing:6) {
            Text(name(boundary.sourceNodeID)+" · "+WorkflowHumanPresentation.port(boundary.sourcePort, nodeID: boundary.sourceNodeID, graph: draft.graph, controller: controller, input: false, language: language)+" → "+name(boundary.destinationNodeID)+" · "+WorkflowHumanPresentation.port(boundary.destinationPort, nodeID: boundary.destinationNodeID, graph: draft.graph, controller: controller, input: true, language: language)).font(.subheadline)
            WorkbenchPicker(text("chooseInput"),selection:Binding<UUID?>(get:{options.choices[key(boundary)]?.stepID},set:{ id in
                options.choices[key(boundary)]=records.first { $0.id == id }.map { .init(address:$0.address,stepID:$0.id) }
            })) {
                WorkbenchChoice(text("none"),value:UUID?.none)
                WorkbenchChoiceForEach(records) { call in
                    WorkbenchChoice((controller.runs.first { $0.id == call.address.runID }.map { WorkflowHumanPresentation.run($0,in:controller.runs,stages:controller.batchStages,language:language) } ?? text("missing"))+" · "+WorkflowHumanPresentation.call(call,in:records,language:language),value:Optional(call.id))
                }
            }.disabled(!current).help(text("historicalInput.help"))
            if let choice=options.choices[key(boundary)],let call=records.first(where:{$0.address == choice.address && $0.id == choice.stepID}),let value=call.step.outputs[boundary.sourcePort] {
                Button(text("previewInput"),systemImage:"arrow.up.right.square") { preview(value,choice,name(boundary.sourceNodeID),boundary.sourcePort) }
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
