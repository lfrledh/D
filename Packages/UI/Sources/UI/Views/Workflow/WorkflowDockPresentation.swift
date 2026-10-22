import SwiftUI
import DWorkbench

/// Fixed geometry of the approved dock; no camera or execution ownership.
enum WorkflowDockLayout {
    static func width(available: CGFloat) -> CGFloat { min(440, max(1, available - 224)) }
}

/// A batch can pause between attempts without leaving any paused run. Keep the
/// stage owner explicit; multiple paused queues require selection in Records.
@MainActor enum WorkflowDockRecovery {
    static func pausedQueues(_ controller: WorkflowController) -> [WorkflowBatchStage] {
        controller.batchStages.filter { $0.state == .paused && $0.attempts.contains { $0.state == .queued } }
    }
}

@MainActor struct WorkflowPausedBatchControls: View {
    let controller: WorkflowController
    let showRecords: () -> Void
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        let queues = WorkflowDockRecovery.pausedQueues(controller)
        Group {
            if queues.count == 1, let stage = queues.first {
                HStack(spacing: 0) {
                    Button(workflowText(language, "workflow.dock.resume")) {
                        Task { await controller.runBatchStage(stage.id) }
                    }.accessibilityIdentifier("workflow-batch-resume")
                    Button(workflowText(language, "workflow.dock.stop")) {
                        Task { await controller.stopBatchQueue(stage.id) }
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
            .popover(isPresented: $precisionVisible) {
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
