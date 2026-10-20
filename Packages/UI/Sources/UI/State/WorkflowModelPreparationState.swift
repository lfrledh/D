import DWorkbench
import Observation
import SwiftUI

struct WorkflowModelPreparation: Equatable {
    let resource: ModelResourceID?
    let taskID: UUID?
    let attemptID: UUID?
    let phase: String
    let completed: UInt64?
    let total: UInt64?
    let issue: String?
    static func make(record: ModelRecord, control: ModelResourceControl, task: ModelDownloadTask?, requiresPreparation: Bool) -> Self {
        let phase: String
        if record.availability == .unavailable { phase = "模型文件当前不可访问" }
        else if record.availability == .needsAuthorization { phase = "模型目录需要重新准入" }
        else if record.state == .verifying { phase = "正在校验模型文件" }
        else if record.state == .publishing { phase = "正在保存模型文件" }
        else if record.state == .failed { phase = "模型准备失败" }
        else if let task, task.state != .completed {
            phase = ["queued":"等待下载", "downloading":"正在下载", "verifying":"正在校验文件", "publishing":"正在保存下载", "waitingRetry":"等待重试", "paused":"下载已暂停", "failed":"下载失败", "cancelled":"下载已取消"][task.state.rawValue] ?? "准备状态待核实"
        } else if control.fileState != .verified {
            phase = ["partial":"文件尚不完整", "unchecked":"文件待校验", "invalid":"文件校验失败", "deleting":"正在移除", "deleted":"文件已移除"][control.fileState.rawValue] ?? "文件待校验"
        } else if record.registrationState == .pending { phase = "正在登记模型" }
        else if record.registrationState == .registered { phase = "文件已校验并登记；执行适配另行检查" }
        else { phase = requiresPreparation && control.role != .execution ? "文件已校验，待准备执行包" : "文件已校验，尚未登记" }
        let bytes = task?.state == .downloading && record.availability == .available
        return .init(resource: .init(rawValue: record.id.rawValue), taskID: task?.id, attemptID: task?.attemptID, phase: phase,
            completed: bytes ? record.downloadedBytes : nil, total: bytes && record.totalBytes > 0 ? record.totalBytes : nil,
            issue: task?.postActionError ?? task?.error ?? record.error)
    }
}
@MainActor @Observable final class WorkflowModelPreparationState {
    private(set) var values: [String: WorkflowModelPreparation] = [:]
    private(set) var resources: [ModelID: WorkflowModelPreparation] = [:]
    func replace(_ values: [String: WorkflowModelPreparation], resources: [ModelID: WorkflowModelPreparation]) {
        if self.values != values { self.values = values }
        if self.resources != resources { self.resources = resources }
    }
    func value(identity: String, installation: ModelID?) -> WorkflowModelPreparation? {
        if let installation { return resources[installation] }
        return values[identity]
    }
}
private struct WorkflowModelInstallationsKey: EnvironmentKey { static let defaultValue: [String: ModelID] = [:] }
private struct WorkflowModelPreparationKey: EnvironmentKey {
    static let defaultValue: WorkflowModelPreparationState? = nil
}
extension EnvironmentValues {
    var workflowModelInstallations: [String: ModelID] {
        get { self[WorkflowModelInstallationsKey.self] }
        set { self[WorkflowModelInstallationsKey.self] = newValue }
    }
    var workflowModelPreparation: WorkflowModelPreparationState? {
        get { self[WorkflowModelPreparationKey.self] }
        set { self[WorkflowModelPreparationKey.self] = newValue }
    }
}
struct WorkflowModelPreparationView: View {
    let identity: String
    var scale: CGFloat = 1
    @Environment(\.workflowModelPreparation) private var state
    @Environment(\.workflowModelInstallations) private var installations
    var body: some View {
        if let value = state?.value(identity: identity, installation: installations[identity]) {
            VStack(alignment: .leading, spacing: 3 * scale) {
                Text(value.phase)
                if let completed = value.completed, let total = value.total, total > 0 {
                    ProgressView(value: Double(min(completed, total)), total: Double(total))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: completed), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)).monospacedDigit()
                }
                if let issue = value.issue { Text(issue).lineLimit(2) }
            }.font(.system(size: 10 * scale)).foregroundStyle(.secondary).allowsHitTesting(false)
        }
    }
}
