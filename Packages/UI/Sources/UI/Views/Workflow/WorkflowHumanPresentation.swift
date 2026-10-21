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
    static func nodes(in run: WorkflowRun) -> [WorkflowNode] {
        var seen = Set<UUID>()
        return (run.graph.nodes + WorkflowWorkspacePanels.records(in: run).map(\.step.node)).filter { seen.insert($0.id).inserted }
    }
    @MainActor static func run(_ run: WorkflowRun, in runs: [WorkflowRun], language: UILanguageStore?) -> String {
        let title = run.graph.name + " · " + run.createdAt.formatted(date: .abbreviated, time: .standard)
        let peers = runs.filter { $0.graph.name == run.graph.name && $0.createdAt.formatted(date: .abbreviated, time: .standard) == run.createdAt.formatted(date: .abbreviated, time: .standard) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let alias = peers.count > 1 ? " · \((peers.firstIndex { $0.id == run.id } ?? 0) + 1)" : ""
        return title + alias + " · " + WorkflowCanvasPresentation.statusTitle(run.status, language: language)
    }
    @MainActor static func call(_ call: WorkflowPlanCallRecord, in records: [WorkflowPlanCallRecord], language: UILanguageStore?) -> String {
        var parts: [String] = []
        for (offset, component) in call.address.path.enumerated() {
            switch component {
            case .iteration(let number): parts.append(metadataText(language, "iteration") + " \(number)")
            case .branch(let selected): parts.append(metadataText(language, "branch") + " · " + (selected ? "true" : "false"))
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
