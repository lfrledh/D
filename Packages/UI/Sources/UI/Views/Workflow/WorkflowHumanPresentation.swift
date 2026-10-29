import AppKit
import DWorkbench
import SwiftUI

/// Local presentation aliases are derived from the complete owning collection,
/// never from a search result or visible row. They are not persisted identities.
enum WorkflowHumanPresentation {
    @MainActor static func name(_ node: WorkflowNode, in nodes: [WorkflowNode], language: UILanguageStore? = nil) -> String {
        func base(_ value: WorkflowNode) -> String {
            if !value.title.isEmpty { return value.title }
            return WorkflowRegistry.standard.definition(for: value).map { WorkflowCanvasPresentation.operationTitle($0, language: language) }
                ?? metadataText(language, "unnamedNode")
        }
        let title = base(node)
        let peers = nodes.filter { base($0) == title }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard peers.count > 1, let index = peers.firstIndex(where: { $0.id == node.id }) else { return title }
        return title + " · \(index + 1)"
    }
    @MainActor static func stage(_ stage: WorkflowBatchStage, language: UILanguageStore?) -> String {
        guard let kind = stage.systemTitle else { return stage.name }
        return workspaceText(language, "batchTitle." + kind.rawValue)
    }
    @MainActor static func runStatus(_ run: WorkflowRun, language: UILanguageStore?) -> String {
        if run.status == .waiting, run.planCheckpoint?.state == .paused {
            return workflowText(language, "workflow.dock.paused")
        }
        if run.status == .waiting {
            let records = WorkflowWorkspacePanels.records(in: run)
            if records.contains(where: { $0.step.status == .waiting }) {
                return workflowText(language, "workflow.dock.waiting")
            }
            return workflowText(language, run.planCheckpoint == nil ? "workflow.status.waitingUnknown" : "workflow.status.readyToContinue")
        }
        return WorkflowCanvasPresentation.statusTitle(run.status, language: language)
    }
    @MainActor static func port(_ id: String, nodeID: UUID, graph: WorkflowGraph, controller: WorkflowController,
                               input: Bool, language: UILanguageStore?) -> String {
        guard let node = graph.nodes.first(where: { $0.id == nodeID }),
              let definition = controller.registry.definition(for: node, tools: controller.tools),
              let port = (input ? definition.inputs : definition.outputs).first(where: { $0.id == id }) else {
            return workflowText(language, "workflow.port.unknownID", arguments: ["id": id])
        }
        return WorkflowCanvasPresentation.portTitle(operationID: node.operationID, port: port, input: input, language: language)
    }
    static func nodes(in run: WorkflowRun) -> [WorkflowNode] {
        var seen = Set<UUID>()
        return (run.graph.nodes + WorkflowWorkspacePanels.records(in: run).map(\.step.node)).filter { seen.insert($0.id).inserted }
    }
    @MainActor static func run(_ run: WorkflowRun, in runs: [WorkflowRun], stages: [WorkflowBatchStage] = [], language: UILanguageStore?) -> String {
        let title = run.graph.name + " · " + run.createdAt.formatted(date: .abbreviated, time: .standard)
        if let attempt = stages.lazy.flatMap({ $0.attempts }).first(where: { $0.runID == run.id }) {
            return title + " · " + metadataText(language, "attemptNumber")
                .replacingOccurrences(of: "{number}", with: String(attempt.ordinal))
                + " · " + WorkflowHumanPresentation.runStatus(run, language: language)
        }
        let peers = runs.filter { $0.graph.name == run.graph.name && $0.createdAt.formatted(date: .abbreviated, time: .standard) == run.createdAt.formatted(date: .abbreviated, time: .standard) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let alias = peers.count > 1 ? " · " + metadataText(language, "runNumber").replacingOccurrences(of: "{number}", with: String((peers.firstIndex { $0.id == run.id } ?? 0) + 1)) : ""
        return title + alias + " · " + WorkflowHumanPresentation.runStatus(run, language: language)
    }
    @MainActor static func call(_ call: WorkflowPlanCallRecord, in records: [WorkflowPlanCallRecord], language: UILanguageStore?) -> String {
        var parts: [String] = []
        for (offset, component) in call.address.path.enumerated() {
            switch component {
            case .iteration(let number): parts.append(metadataText(language, "iteration") + " \(number)")
            case .branch(let selected): parts.append(metadataText(language, "branch") + " · " + workflowText(language, selected ? "workflow.language.control.conditionMet" : "workflow.language.control.conditionNotMet"))
            case .item(let id):
                let parentPath = Array(call.address.path.prefix(offset))
                let parent = records.first { $0.address.runID == call.address.runID && $0.address.path == parentPath }
                if case .data(.list(_, let items)) = parent?.step.inputs["input"], let index = items.firstIndex(where: { $0.id == id }) {
                    parts.append(metadataText(language, "batchIndex") + " \(index + 1)")
                } else { parts.append(metadataText(language, "batchUnknown")) }
            case .tool(let tool): parts.append(metadataText(language, "fixedToolCall") + " · v\(tool.version)")
            case .node: break
            }
        }
        if parts.isEmpty { parts.append(metadataText(language, "rootCall")) }
        let peers = records.filter { $0.step.node.id == call.step.node.id }.sorted { $0.id.uuidString < $1.id.uuidString }
        if peers.count > 1, let index = peers.firstIndex(where: { $0.id == call.id }) {
            parts.append(metadataText(language, "callAlias") + " \(index + 1)")
        }
        return parts.joined(separator: " · ")
    }
    static func opensPendingDecision(_ run: WorkflowRun) -> Bool {
        run.status != .saving && WorkflowWorkspacePanels.records(in: run).contains { $0.step.status == .waiting }
    }
    struct Output: Identifiable {
        struct ID: Hashable { let address: WorkflowExecutionAddress; let step: UUID; let port: String }
        let id: ID
        let call: WorkflowPlanCallRecord
        let port: String
        let value: WorkflowValue
        var storageKey: String {
            // Presentation titles never key output values. Preserve the full structural reference.
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return ((try? encoder.encode(WorkflowCallReference(address: id.address, stepID: id.step)).base64EncodedString()) ?? "") + ":" + port
        }
    }
    static func outputs(_ run: WorkflowRun) -> [Output] {
        WorkflowWorkspacePanels.records(in: run).flatMap { call in
            call.step.outputs.keys.sorted().compactMap { port in
                call.step.outputs[port].map { Output(id: .init(address: call.address, step: call.id, port: port), call: call, port: port, value: $0) }
            }
        }
    }
}

struct WorkflowTechnicalDetails: View {
    let value: String
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        DisclosureGroup(metadataText(language, "technicalDetails")) {
            Text(value).font(.caption2.monospaced()).textSelection(.enabled)
            Button(metadataText(language, "copyDetails")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
            }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
        }.font(.caption)
    }
}

/// Display-only reasons from the existing controller snapshot; never an admission rule.
enum WorkflowOutputComparisonText {
    @MainActor static func title(_ reason: WorkflowOutputComparison, language: UILanguageStore?) -> String {
        switch reason {
        case .matching: ""
        case .changed: workflowText(language, "workflow.status.staleInput")
        case .missingUpstream: workflowText(language, "workflow.status.missingUpstream")
        case .unavailable(let diagnostic):
            WorkbenchOwnedIssue.summary(diagnostic, language: language)
                ?? workflowText(language, "workflow.status.comparisonFailed")
        }
    }
    @MainActor static func help(_ reason: WorkflowOutputComparison, language: UILanguageStore?) -> String {
        switch reason {
        case .matching: ""
        case .changed: workflowText(language, "workflow.status.staleInput.help")
        case .missingUpstream: workflowText(language, "workflow.status.missingUpstream.help")
        case .unavailable(let diagnostic): diagnostic
        }
    }
}
