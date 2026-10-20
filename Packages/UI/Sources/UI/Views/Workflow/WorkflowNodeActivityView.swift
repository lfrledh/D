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
                    Text(workspaceText(language, "phase." + value.phase,
                        ["preparing":"准备处理", "queued":"等待执行", "running":"正在处理", "cancelling":"正在取消", "releasing":"正在释放资源", "completed":"处理完成", "waiting":"等待用户处理", "cancelled":"已取消", "failed":"处理失败"][value.phase] ?? value.phase, value.phase))
                }
                if let progress = value.progress { Text(progress).lineLimit(2) }
                Text(workspaceText(language, "callElapsed", "本次处理用时", "Processing time") + String(format: " %.1f s", value.elapsedSeconds)).monospacedDigit()
            }.font(.system(size: 10 * scale)).foregroundStyle(.secondary).allowsHitTesting(false)
        }
    }
}
