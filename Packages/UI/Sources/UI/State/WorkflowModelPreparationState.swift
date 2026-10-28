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
    func displayPhase(ready: Bool, hasExplicitInstallation: Bool) -> String {
        // A validated legacy bookmark is an exact choice even though it has no
        // inventory ID. Other copies do not make that choice ambiguous. Never
        // override an actual missing, revoked or failed installation state.
        if ready && (phase == "registered" || (!hasExplicitInstallation && phase == "ambiguousCopies")) { return "ready" }
        return phase
    }
    static func make(record: ModelRecord, control: ModelResourceControl, task: ModelDownloadTask?, requiresPreparation: Bool) -> Self {
        let phase: String
        if record.availability == .unavailable { phase = record.locationIssue?.rawValue ?? "unavailable" }
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
/// One cell per visible exact requirement/installation. Weak registry entries
/// are pruned on access/publication; snapshots are bounded by current inventory.
/// Progress mutates the matching cell, never an observable dictionary of all models.
@MainActor @Observable final class WorkflowModelPreparationCell {
    var value: WorkflowModelPreparation?
    init(_ value: WorkflowModelPreparation?) { self.value = value }
}
@MainActor final class WorkflowModelPreparationState {
    private(set) var values: [String: WorkflowModelPreparation] = [:]
    private(set) var resources: [ModelID: WorkflowModelPreparation] = [:]
    private struct WeakCell { weak var cell: WorkflowModelPreparationCell? }
    private var identities: [String: WeakCell] = [:]
    private var installations: [ModelID: WeakCell] = [:]
    func replace(_ values: [String: WorkflowModelPreparation], resources: [ModelID: WorkflowModelPreparation]) {
        self.values = values; self.resources = resources
        identities = identities.filter { $0.value.cell != nil }
        installations = installations.filter { $0.value.cell != nil }
        for (key, weak) in identities { if weak.cell?.value != values[key] { weak.cell?.value = values[key] } }
        for (key, weak) in installations { if weak.cell?.value != resources[key] { weak.cell?.value = resources[key] } }
    }
    func cell(identity: String, installation: ModelID?) -> WorkflowModelPreparationCell {
        if let installation {
            if let cell = installations[installation]?.cell { return cell }
            installations = installations.filter { $0.value.cell != nil }
            let cell = WorkflowModelPreparationCell(resources[installation]); installations[installation] = .init(cell: cell)
            return cell
        }
        if let cell = identities[identity]?.cell { return cell }
        identities = identities.filter { $0.value.cell != nil }
        let cell = WorkflowModelPreparationCell(values[identity]); identities[identity] = .init(cell: cell)
        return cell
    }
    func value(identity: String, installation: ModelID?) -> WorkflowModelPreparation? {
        installation.map { resources[$0] } ?? values[identity]
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
    var fallbackReady = false
    var onPrepare: (() -> Void)? = nil
    var permitsPreparation = true
    var nodeID: UUID? = nil
    @Environment(\.dLanguageStore) private var language
    @Environment(\.workflowModelPreparation) private var state
    @Environment(\.workflowModelInstallations) private var installations
    var body: some View {
        if let state {
            WorkflowModelPreparationCellView(cell: state.cell(identity: identity, installation: installations[identity]), hasExplicitInstallation: installations[identity] != nil, scale: scale, fallbackReady: fallbackReady, onPrepare: onPrepare, permitsPreparation: permitsPreparation, nodeID: nodeID)
        }
    }
}
private struct WorkflowModelPreparationCellView: View {
    let cell: WorkflowModelPreparationCell
    let hasExplicitInstallation: Bool
    let scale: CGFloat
    let fallbackReady: Bool
    let onPrepare: (() -> Void)?
    let permitsPreparation: Bool
    let nodeID: UUID?
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        if let value = cell.value {
            VStack(alignment: .leading, spacing: 3 * scale) {
                Text(workflowText(language, "workflow.preparation." + value.displayPhase(ready: fallbackReady, hasExplicitInstallation: hasExplicitInstallation)))
                if let completed = value.completed, let total = value.total, total > 0 {
                    ProgressView(value: Double(min(completed, total)), total: Double(total))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: completed), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)).monospacedDigit()
                }

            }.font(.system(size: 10 * scale)).foregroundStyle(.secondary).allowsHitTesting(false)
        }
        if let onPrepare, cell.value?.phase != "registered", !fallbackReady {
            let busy = ["queued", "downloading", "verifying", "publishing", "verifyingModel", "publishingModel", "registering"].contains(cell.value?.phase ?? "")
            Button(action: onPrepare) {
                Text(workflowText(language, busy ? "workflow.node.prepare.pending" : "workflow.node.prepare.download"))
            }.buttonStyle(WorkbenchGlassButtonStyle())
                .disabled(!permitsPreparation || busy)
                .accessibilityIdentifier("workflow-node-prepare-" + (nodeID?.uuidString ?? "quick"))
                .modifier(ModelPreparationNodeControl(nodeID: nodeID))
        }

    }
}

private struct ModelPreparationNodeControl: ViewModifier {
    let nodeID: UUID?
    @ViewBuilder func body(content: Content) -> some View {
        if let nodeID { content.workflowNodeControl(nodeID) } else { content }
    }
}
