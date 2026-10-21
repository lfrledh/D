import DWorkbench
import SwiftUI

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
                if let message = value.message { Text(workflowProgressText(message, language: language)).lineLimit(2) }
                else if let progress = value.progress { Text(progress).lineLimit(2) }
                Text(workspaceText(language, "callElapsed") + String(format: " %.1f s", value.elapsedSeconds)).monospacedDigit()
            }.font(.system(size: 10 * scale)).foregroundStyle(.secondary).allowsHitTesting(false)
        }
    }
}
