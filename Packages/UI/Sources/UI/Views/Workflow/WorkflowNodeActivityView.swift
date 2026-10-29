import DWorkbench
import SwiftUI

enum WorkflowNodeActivityPresentation {
    static func secondaryMessage(phase: String, message: WorkflowProgressMessage) -> WorkflowProgressMessage? {
        // The activity bridge also publishes the phase as a progress message.
        // Preserve distinct details (including arguments), without comparing translated text.
        message.code == "phase." + phase && message.arguments.isEmpty ? nil : message
    }
}

struct WorkflowNodeActivityView: View {
    let state: WorkflowCallActivityState
    let nodeID: UUID
    let graphID: UUID
    var scale: CGFloat = 1
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        if let value = state.current, value.nodeID == nodeID, value.graphID == graphID {
            VStack(alignment: .leading, spacing: 3 * scale) {
                HStack {
                    if !value.finished { ProgressView().controlSize(.mini) }
                    Text(workspaceText(language, "phase." + value.phase, value.phase, value.phase))
                }
                if let message = value.message {
                    if let detail = WorkflowNodeActivityPresentation.secondaryMessage(phase: value.phase, message: message) {
                        Text(workflowProgressText(detail, language: language)).lineLimit(2)
                    }
                }
                else if let progress = value.progress { Text(progress).lineLimit(2) }
                Text(workspaceText(language, "callElapsed") + String(format: " %.1f s", value.elapsedSeconds)).monospacedDigit()
            }.font(.system(size: 10 * scale)).foregroundStyle(.secondary).allowsHitTesting(false)
        }
    }
}
