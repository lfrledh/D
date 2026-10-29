import DWorkbench
import Foundation

/// Only explicit presentation intent changes tabs. Controller selection also changes during
/// insertion, Undo and dragging, so it must never be used as a navigation event.
struct WorkflowWorkspacePanels: Equatable {
    enum Preparation: String, CaseIterable { case models, programs, configuration }
    enum Output: String, CaseIterable { case node, overview, batches }
    var preparation: Preparation = .models
    var lastResource: Preparation = .models
    var output: Output = .overview
    var pinned = false
    var runID: UUID?
    var nodeID: UUID?
    var call: WorkflowCallReference?

    mutating func selectPreparation(_ tab: Preparation) {
        preparation = tab
        if tab != .configuration { lastResource = tab }
    }
    mutating func inspect(_ id: UUID) {
        preparation = .configuration
    }
    mutating func clearSelection() {
        preparation = lastResource
    }
    mutating func selectRun(_ id: UUID?) { runID = id; call = nil }
    mutating func selectResult(node: UUID, call: WorkflowCallReference?) {
        nodeID = node; self.call = call; output = .node
    }
    static func records(in run: WorkflowRun) -> [WorkflowPlanCallRecord] {
        if let checkpoint = run.planCheckpoint { return checkpoint.records }
        // Legacy flat records have no nested address. Their run + exact step identity is retained.
        return run.steps.map { .init(address: .init(runID: run.id), step: $0) }
    }
    func record(in run: WorkflowRun?) -> WorkflowPlanCallRecord? {
        guard let run, run.id == runID, let nodeID else { return nil }
        let records = Self.records(in: run).filter { $0.step.node.id == nodeID }
        if let call { return records.first { $0.address == call.address && $0.step.id == call.stepID } }
        return records.count == 1 ? records.first : nil
    }
}

/// Stable field IDs only; unknown future fields remain visible. Required ports stay outside disclosure.
enum WorkflowParameterPresentation {
    static func isVisible(_ field: WorkflowFieldDefinition, node: WorkflowNode) -> Bool {
        field.id != "streamWeights" || node.parameters["memoryStrategySelection"]?.string != "automatic"
    }
    static let advanced: Set<String> = ["temperature", "topP", "topK", "seed", "guidance", "steps",
        "memoryBudgetGiB", "loadingStrategy", "messagesJSON", "toolsJSON", "thinking", "reasoningEffort",
        "preserveThinking", "chatTemplateOverride", "repetitionPenalty"]
}
