import SwiftUI
import DWorkbench

/// Fixed geometry of the approved dock; no camera or execution ownership.
enum WorkflowDockLayout {
    static func width(available: CGFloat) -> CGFloat { min(440, max(1, available - 224)) }
}

/// A batch can pause between attempts without leaving any paused run. Keep the
/// stage owner explicit; multiple paused queues require selection in Records.
@MainActor enum WorkflowDockRecovery {
    enum Target: Hashable { case stage(UUID), run(UUID) }
    struct Snapshot: Equatable {
        let context: WorkflowRunTarget.Context
        let targets: Set<Target>
        var soleTarget: Target? { targets.count == 1 ? targets.first : nil }
    }
    static func pausedQueues(_ controller: WorkflowController) -> [WorkflowBatchStage] {
        controller.batchStages.filter { $0.state == .paused && $0.attempts.contains { $0.state == .queued } }
    }
    static func targets(stageIDs: [UUID], runIDs: [UUID]) -> Set<Target> {
        Set(stageIDs.map(Target.stage) + runIDs.map(Target.run))
    }
    static func capture(_ controller: WorkflowController) -> Snapshot {
        let batchRuns = Set(controller.batchStages.flatMap { $0.attempts.compactMap(\.runID) })
        let runs = controller.runs.filter { !batchRuns.contains($0.id) && WorkflowCanvasPresentation.canResume($0.status) && $0.planCheckpoint?.state == .paused }
        return Snapshot(context: WorkflowRunTarget.Context(controller), targets: targets(stageIDs: pausedQueues(controller).map(\.id), runIDs: runs.map(\.id)))
    }
    static func perform(_ snapshot: Snapshot, stopping: Bool, controller: WorkflowController, showRecords: () -> Void) {
        guard !controller.isRunning, !controller.hasPendingSaves, !controller.isSaving, controller.readOnlyReason == nil else { return }
        guard snapshot == capture(controller), let target = snapshot.soleTarget else { showRecords(); return }
        Task {
            // The task may begin after another command changed the owner or queue.
            guard snapshot == capture(controller), !controller.isRunning, !controller.hasPendingSaves,
                  !controller.isSaving, controller.readOnlyReason == nil else { return }
            switch target {
            case .stage(let id): if stopping { await controller.stopBatchQueue(id) } else { await controller.runBatchStage(id) }
            case .run(let id): if stopping { await controller.stopPausedRun(runID: id) } else { await controller.resume(runID: id) }
            }
        }
    }
}

@MainActor struct WorkflowPausedBatchControls: View {
    let controller: WorkflowController
    let showRecords: () -> Void
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        let snapshot = WorkflowDockRecovery.capture(controller)
        Group {
            if snapshot.soleTarget != nil {
                HStack(spacing: 0) {
                    Button(workflowText(language, "workflow.dock.resume")) {
                        WorkflowDockRecovery.perform(snapshot, stopping: false, controller: controller, showRecords: showRecords)
                    }.accessibilityIdentifier("workflow-batch-resume")
                    Button(workflowText(language, "workflow.dock.stop")) {
                        WorkflowDockRecovery.perform(snapshot, stopping: true, controller: controller, showRecords: showRecords)
                    }.accessibilityIdentifier("workflow-batch-stop")
                }
            } else {
                Button(workflowText(language, "workflow.dock.records"), action: showRecords)
                    .accessibilityIdentifier("workflow-batch-choose")
            }
        }.buttonStyle(WorkflowDockButtonStyle(expand: true))
            .disabled(controller.isRunning || controller.hasPendingSaves || controller.readOnlyReason != nil)
    }
}

struct WorkflowDockButtonStyle: ButtonStyle {
    var expand = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption)
            .frame(maxWidth: expand ? .infinity : nil).frame(height: 32)
            .background(.primary.opacity(configuration.isPressed ? 0.15 : 0.065), in: Capsule())
            .contentShape(Capsule()).opacity(enabled ? 1 : 0.4)
    }
}

/// A camera leaf: opening secondary controls must not subscribe the canvas shell
/// or retained libraries to every zoom update.
struct WorkflowCanvasCornerZoom: View {
    @Binding var zoom: CGFloat
    let locked: Bool
    let canFit: Bool
    let fit: () -> Void
    @State private var precisionVisible = false
    @Environment(\.dLanguageStore) private var language
    private func text(_ key: String) -> String { workflowText(language, "workflow.dock." + key) }
    var body: some View {
        Button { zoom = 1 } label: { Text("100%").font(.system(size: 10, weight: .semibold)) }
            .buttonStyle(WorkbenchIconButtonStyle(diameter: 40)).disabled(locked)
            .accessibilityIdentifier("workflow-canvas-reset-zoom")
            .accessibilityLabel(text("resetZoom"))
            .help(text("resetZoom") + " · \(Int((zoom * 100).rounded()))%")
            .workbenchContextMenu {
                WorkbenchMenuAction(text("zoomIn")) { zoom = min(WorkflowCanvasLayoutPolicy.zoomRange.upperBound, zoom * 1.2) }.disabled(locked)
                WorkbenchMenuAction(text("zoomOut")) { zoom = max(WorkflowCanvasLayoutPolicy.zoomRange.lowerBound, zoom / 1.2) }.disabled(locked)
                WorkbenchMenuAction(workflowText(language, "refinement.workflow.fitAll"), action: fit).disabled(locked || !canFit)
                WorkbenchMenuDivider()
                WorkbenchMenuAction(text("fineZoom") + " · \(Int((zoom * 100).rounded()))%") { precisionVisible = true }.disabled(locked)
            }
            .workbenchPopover(isPresented: $precisionVisible, title: workflowText(language, "childPanel.name.zoom")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(text("fineZoom") + " · \(Int((zoom * 100).rounded()))%")
                    Slider(value: $zoom, in: WorkflowCanvasLayoutPolicy.sliderZoomRange(current: zoom))
                        .accessibilityLabel(text("fineZoom")).disabled(locked)
                }.padding(14).frame(width: 240)
            }
    }
}

/// Secondary run surfaces already own a glass shell.
struct WorkflowDecisionPrimaryStyle: ViewModifier {
    let flat: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if flat { content.buttonStyle(.borderedProminent) }
        else { content.buttonStyle(WorkbenchPrimaryButtonStyle()) }
    }
}
