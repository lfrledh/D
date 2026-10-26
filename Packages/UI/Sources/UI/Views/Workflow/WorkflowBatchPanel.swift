import DWorkbench
import SwiftUI

@MainActor struct WorkflowBatchPanel: View {
    let controller: WorkflowController
    var revealLibrary: ((WorkflowLibraryContext) -> Void)? = nil
    let inspect: (WorkflowRun, WorkflowPlanCallRecord) -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var selected: Set<UUID> = []
    @State private var repetitions = 1
    @State private var seedStrategy: WorkflowBatchSeedStrategy = .fixed
    @State private var showPlan = false
    private func text(_ key: String, _ zh: String = "", _ en: String = "") -> String { workspaceText(language, key, zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(text("batchReview")).font(.caption)
                Spacer()
                if controller.isRunning {
                    Button(text("batchPauseReview")) { controller.pause() }
                    Button(text("batchCancel")) { Task { await controller.cancel() } }
                }
                Button(text("continueSelected")) { showPlan = true }
                    .disabled(selected.isEmpty || controller.isRunning || controller.hasPendingSaves)
            }
            WorkbenchScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.batchStages.reversed()) { stage in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(stage.name).font(.headline)
                                Text(stage.createdAt, style: .time).font(.caption)
                                Spacer()
                                let waiting = stage.attempts.filter { $0.state == .waiting }.count
                                let complete = stage.attempts.filter { $0.state == .completed }.count
                                Text("\(complete)/\(stage.attempts.count) " + text("batchCompleted") +
                                     " · \(waiting) " + text("batchWaiting")).font(.caption)
                                if stage.state == .savingBlocked || stage.attempts.contains(where: { $0.state == .savingBlocked }) || (stage.state == .cancelled && controller.hasPendingSaves) {
                                    Button(text("saveOnly")) { Task { await controller.retryBatchSaving(stage.id) } }.disabled(controller.isRunning)
                                } else if stage.attempts.contains(where: { $0.state == .queued }), stage.state != .cancelled {
                                    Button(text("resumeQueue")) { Task { await controller.runBatchStage(stage.id) } }
                                        .disabled(controller.isRunning || controller.hasPendingSaves)
                                    Button(workflowText(language, "workflow.dock.stopRemaining")) { Task { await controller.stopBatchQueue(stage.id) } }
                                        .disabled(controller.isRunning || controller.hasPendingSaves)
                                }
                            }
                            ForEach(stage.attempts) { attempt in
                                if let run = controller.runs.first(where: { $0.id == attempt.runID }) { row(attempt, stageID: stage.id, run: run) }
                            }
                        }.padding(8).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if controller.batchStages.isEmpty {
                        Text(text("batchEmpty")).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
        }.padding(10)
            .workbenchSheet(isPresented: $showPlan, title: workflowText(language, "childPanel.name.plan")) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(text("nextStage")).font(.headline)
                    Stepper(text("perSelected") + " \(repetitions)", value: $repetitions, in: 1...64)
                    Text("\(selected.count) × \(repetitions) = \(selected.count * repetitions)")
                    Text(text("fixedPrefix")).font(.callout)
                    WorkbenchPicker(text("seedStrategy"), selection: $seedStrategy) {
                        WorkbenchChoice(text("seedFixed"), value: WorkflowBatchSeedStrategy.fixed)
                        WorkbenchChoice(text("seedAutomatic"), value: WorkflowBatchSeedStrategy.automatic)
                    }
                    Text(text("seedEffect")).font(.caption)
                    HStack {
                        Button(text("cancel")) { showPlan = false }
                        Spacer()
                        Button(text("confirmNextStage")) {
                            let ids = controller.runs.filter { selected.contains($0.id) }.map(\.id), count = repetitions
                            Task {
                                do {
                                    let stage = try await controller.createNextBatchStage(parentRunIDs: ids, repetitions: count, seedStrategy: seedStrategy)
                                    showPlan = false; selected = []
                                    await controller.runBatchStage(stage)
                                } catch { controller.errorMessage = error.localizedDescription }
                            }
                        }.buttonStyle(WorkbenchPrimaryButtonStyle())
                            .disabled(selected.isEmpty || selected.count > 256 / repetitions || controller.isRunning || controller.hasPendingSaves)
                    }
                }.padding(24).frame(width: 480)
            }
    }

    // Only the candidate-review surface selects assets. Generic human forms and
    // text review keep their own label without changing the inspected call.
    static func reviewActionKey(for step: WorkflowStepRun, registry: WorkflowRegistry) -> String {
        step.humanTask == nil && registry.operation(step.node.operationID)?.definition.interaction == .candidateReview || step.node.operationID == WorkflowAssetContainer.filterID
            ? "reviewGate" : "reviewHumanGate"
    }

    private func row(_ attempt: WorkflowBatchAttempt, stageID: UUID, run: WorkflowRun) -> some View {
        HStack(alignment: .top) {
            let reason = controller.batchContinuationIssue(run.id)
            Toggle(isOn: Binding(get: { selected.contains(run.id) }, set: { if $0 { selected.insert(run.id) } else { selected.remove(run.id) } })) {
                Text("#\(attempt.ordinal)").monospacedDigit()
            }.disabled(reason != nil || controller.isRunning).help(reason ?? "")
            VStack(alignment: .leading) {
                Text(WorkflowCanvasPresentation.statusTitle(run.status, language: language))
                if let parent = run.batchParent, let parentRun = controller.runs.first(where: { $0.id == parent.runID }) {
                    Text(text("fixedParent") + " " + WorkflowHumanPresentation.run(parentRun, in: controller.runs, stages: controller.batchStages, language: language)).font(.caption)
                }
                if let schedule = run.planCheckpoint?.batchSeeds {
                    DisclosureGroup(text("actualSeeds")) {
                        ForEach(Array(schedule.assignments.enumerated()), id: \.offset) { index, item in
                            Text("\(index + 1) · \(item.value)").font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Text(text("seedInherited")).font(.caption)
                    }
                }
                if let seconds = attempt.activeSeconds {
                    Text(text("activeTime") + String(format: " %.2f s", seconds)).font(.caption)
                } else { Text(text("timeUnrecorded")).font(.caption) }
            }
            Spacer()
            if let revealLibrary {
                Button(workspaceText(language, "locateResults", "", ""), systemImage: "tray.full") {
                    revealLibrary(.init(controller: controller, source: .attempt(stage: stageID, attempt: attempt.id, run: run.id), name: WorkflowHumanPresentation.run(run, in: controller.runs, stages: controller.batchStages, language: language)))
                }.accessibilityIdentifier("attempt-locate-results")
            }
            ForEach(controller.callRecords(runID: run.id).filter { $0.step.status == .waiting }) { record in
                Button(text(Self.reviewActionKey(for: record.step, registry: controller.registry))) { inspect(run, record) }
            }
            if let intent = controller.containerSubmission(forParent: run.id), intent.choices.first(where: { !$0.selectedIDs.isEmpty })?.call.address.runID == run.id {
                Button(workflowText(language, controller.hasPendingSaves ? "metadata.panel.workspace.saveOnly" : "container.continueSaved")) {
                    Task {
                        do {
                            if controller.hasPendingSaves { _ = try await controller.retryContainerSaving(intent.scope); return }
                            if let next = try await controller.continueContainerSubmission(intent) { await controller.runBatchStage(next) }
                        } catch { controller.errorMessage = error.localizedDescription }
                    }
                }.disabled(controller.isRunning)
            }
            if [.failed, .interrupted].contains(attempt.state) {
                Button(text("newAttempt")) {
                    Task {
                        do { let id = try await controller.retryBatchAttempt(run.id); await controller.runBatchStage(id) }
                        catch { controller.errorMessage = error.localizedDescription }
                    }
                }.disabled(controller.isRunning || controller.hasPendingSaves)
            }
        }.font(.callout).padding(.vertical, 3)
    }
}
