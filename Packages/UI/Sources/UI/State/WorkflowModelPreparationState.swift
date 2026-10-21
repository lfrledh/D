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
        if record.availability == .unavailable { phase = "unavailable" }
        else if record.availability == .needsAuthorization { phase = "authorization" }
        else if record.state == .verifying { phase = "verifyingModel" }
        else if record.state == .publishing { phase = "publishingModel" }
        else if record.state == .failed { phase = "failedModel" }
        else if let task, task.state != .completed {
            phase = ["queued":"queued", "downloading":"downloading", "verifying":"verifying", "publishing":"publishing", "waitingRetry":"waitingRetry", "paused":"paused", "failed":"failed", "cancelled":"cancelled"][task.state.rawValue] ?? "unknown"
        } else if control.fileState != .verified {
            phase = ["partial":"partial", "unchecked":"unchecked", "invalid":"invalid", "deleting":"deleting", "deleted":"deleted"][control.fileState.rawValue] ?? "unchecked"
        } else if record.registrationState == .pending { phase = "registering" }
        else if record.registrationState == .registered { phase = "registered" }
        else { phase = requiresPreparation && control.role != .execution ? "prepareExecution" : "unregistered" }
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
    @Environment(\.dLanguageStore) private var language
    @Environment(\.workflowModelPreparation) private var state
    @Environment(\.workflowModelInstallations) private var installations
    var body: some View {
        if let value = state?.value(identity: identity, installation: installations[identity]) {
            VStack(alignment: .leading, spacing: 3 * scale) {
                Text(workflowText(language, "workflow.preparation." + value.phase))
                if let completed = value.completed, let total = value.total, total > 0 {
                    ProgressView(value: Double(min(completed, total)), total: Double(total))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: completed), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)).monospacedDigit()
                }
                if let issue = value.issue { Text(issue).lineLimit(2) }
            }.font(.system(size: 10 * scale)).foregroundStyle(.secondary).allowsHitTesting(false)
        }
    }
}
