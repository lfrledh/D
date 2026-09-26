import DWorkbench
import SwiftUI

struct WorkflowScopePresentation: Identifiable {
    let id = UUID()
    let graphID: UUID
    let revision: UUID
    let nodeID: UUID
    init(graph: WorkflowGraph, nodeID: UUID) {
        self.graphID = graph.id; self.revision = graph.revision; self.nodeID = nodeID
    }
}

/// Explicit run controls, not another operation or scheduler.
@MainActor struct WorkflowScopePanel: View {
    let controller: WorkflowController
    let graphID: UUID
    let revision: UUID
    let nodeID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dLanguageStore) private var language
    @State private var mode = 0
    @State private var choices: [String: UUID] = [:]

    private func text(_ key: String, _ fallback: String) -> String {
        language?.text("workflow.scope." + key, fallback: fallback) ?? fallback
    }
    private var selection: WorkflowGraphSelection {
        switch mode {
        case 1: .only(nodeID)
        case 2: .downstream(nodeID, includingAnchor: true)
        case 3: .downstream(nodeID, includingAnchor: false)
        default: .through(nodeID)
        }
    }
    private func key(_ boundary: WorkflowScopeBoundary) -> String {
        boundary.destinationNodeID.uuidString + ":" + boundary.destinationPort
    }
    private func pins(_ boundaries: [WorkflowScopeBoundary]) -> [WorkflowHistoricalInput] {
        boundaries.compactMap { boundary in
            guard let id = choices[key(boundary)],
                  let call = controller.historicalCalls(for: boundary).first(where: { $0.id == id }) else { return nil }
            return .init(destinationNodeID: boundary.destinationNodeID, destinationPort: boundary.destinationPort,
                sourceCall: .init(address: call.address, stepID: call.step.id), sourcePort: boundary.sourcePort)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("title", "选择运行范围与历史输入")).font(.headline)
            Picker(text("range", "运行范围"), selection: $mode) {
                Text(text("through", "运行到这里")).tag(0)
                Text(text("only", "仅重新运行此节点")).tag(1)
                Text(text("from", "从这里重新运行（含此节点）")).tag(2)
                Text(text("after", "从其输出继续（不重算此节点）")).tag(3)
            }.onChange(of: mode) { _, _ in choices = [:] }
            Text(text("explanation", "边界输入必须选择一个明确的已保存结果；不会自动取最新版本。重新运行产生新记录，旧记录不变。"))
                .font(.callout).foregroundStyle(.secondary)
            if let boundaries = try? controller.scopeBoundaries(selection) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(boundaries.enumerated()), id: \.offset) { _, boundary in
                            let records = controller.historicalCalls(for: boundary)
                            VStack(alignment: .leading) {
                                Text((controller.rootGraph?.nodes.first { $0.id == boundary.destinationNodeID }?.title ?? "") + " · " + boundary.destinationPort)
                                Picker(text("version", "历史输出版本"), selection: Binding<UUID?>(
                                    get: { choices[key(boundary)] }, set: { choices[key(boundary)] = $0 })) {
                                    Text(text("choose", "请选择一个结果")).tag(Optional<UUID>.none)
                                    ForEach(records) { call in
                                        Text(call.step.node.title + " · " + call.address.runID.uuidString.prefix(8) + " / " + call.step.id.uuidString.prefix(8))
                                            .tag(Optional(call.id))
                                    }
                                }
                                if let call = records.first(where: { $0.id == choices[key(boundary)] }) {
                                    Text(String(describing: call.step.outputs[boundary.sourcePort]))
                                        .font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                                    DisclosureGroup(text("identity", "完整来源身份")) {
                                        Text(String(describing: call.address) + "\n" + call.step.id.uuidString + " / " + boundary.sourcePort)
                                            .font(.caption2.monospaced()).textSelection(.enabled)
                                    }
                                }
                            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(text("cancel", "取消")) { dismiss() }
                    Button(text("run", "运行所选范围")) {
                        let chosen = pins(boundaries), requested = selection
                        dismiss()
                        Task { await controller.runScoped(requested, pins: chosen, expectedGraphID: graphID, expectedRevision: revision) }
                    }.disabled(pins(boundaries).count != boundaries.count || controller.isRunning ||
                        controller.rootGraph?.id != graphID || controller.rootGraph?.revision != revision)
                }
            } else {
                Text(text("invalid", "该范围不存在或不能编译；请先检查图和锚点。"))
                Button(text("close", "关闭")) { dismiss() }
            }
        }.padding(20).frame(minWidth: 580, idealWidth: 680, minHeight: 420)
    }
}
