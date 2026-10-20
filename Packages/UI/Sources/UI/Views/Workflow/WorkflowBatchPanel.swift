import DWorkbench
import SwiftUI

@MainActor struct WorkflowBatchPanel: View {
    let controller: WorkflowController
    let inspect: (WorkflowRun, WorkflowPlanCallRecord) -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var selected: Set<UUID> = []
    @State private var repetitions = 1
    @State private var showPlan = false
    private func text(_ key: String, _ zh: String, _ en: String) -> String { workspaceText(language, key, zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(text("batchReview", "先筛选，再明确继续下一阶段。", "Review first, then authorize the next stage.")).font(.caption)
                Spacer()
                if controller.isRunning {
                    Button(text("batchPauseReview", "到关卡后暂停并筛选", "Pause at gate to review")) { controller.pause() }
                    Button(text("batchCancel", "取消剩余生成", "Cancel remaining attempts")) { Task { await controller.cancel() } }
                }
                Button(text("continueSelected", "继续所选…", "Continue selected…")) { showPlan = true }
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
                                Text("\(complete)/\(stage.attempts.count) " + text("batchCompleted", "完成", "completed") +
                                     " · \(waiting) " + text("batchWaiting", "待筛选", "awaiting review")).font(.caption)
                                if stage.state == .savingBlocked || stage.attempts.contains(where: { $0.state == .savingBlocked }) {
                                    Button(text("saveOnly", "仅重试保存", "Retry saving only")) { Task { await controller.retryBatchSaving(stage.id) } }.disabled(controller.isRunning)
                                } else if stage.attempts.contains(where: { $0.state == .queued }), stage.state != .cancelled {
                                    Button(text("resumeQueue", "运行剩余已授权次数", "Run remaining authorized attempts")) { Task { await controller.runBatchStage(stage.id) } }
                                        .disabled(controller.isRunning || controller.hasPendingSaves)
                                }
                            }
                            ForEach(stage.attempts) { attempt in
                                if let run = controller.runs.first(where: { $0.id == attempt.runID }) { row(attempt, run: run) }
                            }
                        }.padding(8).workbenchPanel(cornerRadius: 12)
                    }
                    if controller.batchStages.isEmpty {
                        Text(text("batchEmpty", "从运行计划中开启批量生成；尚未提交批次。", "Enable batch generation in a run plan. No batch has been submitted.")).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
        }.padding(10)
            .sheet(isPresented: $showPlan) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(text("nextStage", "下一阶段计划", "Next stage plan")).font(.headline)
                    Stepper(text("perSelected", "每项再生成", "Attempts per selected item") + " \(repetitions)", value: $repetitions, in: 1...64)
                    Text("\(selected.count) × \(repetitions) = \(selected.count * repetitions)")
                    Text(text("fixedPrefix", "已采用输入保持固定，不重算上游。列表视为一个输入包。下一人工关卡再次停止。", "Accepted inputs remain fixed; upstream is not rerun. A list is one input bundle. Stop at the next human gate.")).font(.callout)
                    Text(text("batchSeed", "串行执行至人工关卡；使用固定配方中的种子，结果可能相同。", "Run serially to review gates. Retain configured seeds; results may match.")).font(.caption)
                    HStack {
                        Button(text("cancel", "取消", "Cancel")) { showPlan = false }
                        Spacer()
                        Button(text("confirmNextStage", "明确提交下一阶段", "Submit next stage")) {
                            let ids = controller.runs.filter { selected.contains($0.id) }.map(\.id), count = repetitions
                            Task {
                                do {
                                    let stage = try await controller.createNextBatchStage(parentRunIDs: ids, repetitions: count)
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

    private func row(_ attempt: WorkflowBatchAttempt, run: WorkflowRun) -> some View {
        HStack(alignment: .top) {
            let reason = controller.batchContinuationIssue(run.id)
            Toggle(isOn: Binding(get: { selected.contains(run.id) }, set: { if $0 { selected.insert(run.id) } else { selected.remove(run.id) } })) {
                Text("#\(attempt.ordinal)").monospacedDigit()
            }.disabled(reason != nil || controller.isRunning).help(reason ?? "")
            VStack(alignment: .leading) {
                Text(WorkflowCanvasPresentation.statusTitle(run.status, language: language))
                if let parent = run.batchParent { Text(text("fixedParent", "固定父尝试", "Fixed parent") + " " + parent.runID.uuidString.prefix(8)).font(.caption) }
                if let seconds = attempt.activeSeconds {
                    Text(text("activeTime", "本阶段执行用时", "Stage execution time") + String(format: " %.2f s", seconds)).font(.caption)
                } else { Text(text("timeUnrecorded", "执行用时未记录", "Execution time not recorded")).font(.caption) }
            }
            Spacer()
            ForEach(controller.callRecords(runID: run.id).filter { $0.step.status == .waiting }) { record in
                Button(text("reviewGate", "筛选 / 保存决定", "Review / save decision")) { inspect(run, record) }
            }
            if [.failed, .interrupted].contains(attempt.state) {
                Button(text("newAttempt", "新建一次重试", "Authorize a new retry")) {
                    Task {
                        do { let id = try await controller.retryBatchAttempt(run.id); await controller.runBatchStage(id) }
                        catch { controller.errorMessage = error.localizedDescription }
                    }
                }.disabled(controller.isRunning || controller.hasPendingSaves)
            }
        }.font(.callout).padding(.vertical, 3)
    }
}
