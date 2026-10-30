import DInference
import DWorkbench
import SwiftUI

private struct LowMemoryDecisionsKey: EnvironmentKey {
    static let defaultValue: LowMemoryDecisionStore? = nil
}
public extension EnvironmentValues {
    var lowMemoryDecisions: LowMemoryDecisionStore? {
        get { self[LowMemoryDecisionsKey.self] }
        set { self[LowMemoryDecisionsKey.self] = newValue }
    }
}

public struct LowMemoryDecisionPresenter: ViewModifier {
    let owner: LowMemoryDecisionStore?
    @Environment(\.dLanguageStore) private var language
    public init(owner: LowMemoryDecisionStore?) { self.owner = owner }
    public func body(content: Content) -> some View {
        content.environment(\.lowMemoryDecisions, owner)
            .workbenchSheet(item: Binding(get: { owner?.pending }, set: { value in
                if value == nil, let pending = owner?.pending {
                    owner?.resolve(proposalID: pending.id, entryToken: pending.entryToken, allow: false)
                }
            }), title: workflowText(language, "memory.confirmTitle"), size: .init(width: 600, height: 580)) { proposal in
                if let owner { LowMemoryDecisionPanel(owner: owner, proposal: proposal) }
            }
    }
}

struct LowMemoryDecisionPanel: View {
    let owner: LowMemoryDecisionStore
    let proposal: LowMemoryProposal
    @State private var remember = false
    @Environment(\.dLanguageStore) private var language
    private func text(_ key: String) -> String { workflowText(language, "memory." + key) }
    private var descriptor: ModelNodeDescriptor? {
        let matches = ModelNodeCatalog.entries.filter { $0.revision == proposal.original.model.revision }
        return matches.count == 1 ? matches.first : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("confirmBody")).fixedSize(horizontal: false, vertical: true)
            Text(descriptor?.title ?? proposal.original.model.directory.lastPathComponent).font(.headline).textSelection(.enabled)
            ModelSpecificationFields(descriptor: descriptor)
            LabeledContent(text("version"), value: proposal.original.model.revision ?? workflowText(language, "model.spec.unrecorded"))
                .font(.caption).textSelection(.enabled)
            LabeledContent(text("method"), value: text(proposal.plan.method.rawValue))
            LabeledContent(text("estimate"), value: ByteCountFormatter.string(fromByteCount: Int64(clamping: proposal.estimate.peakBytes), countStyle: .memory))
            LabeledContent(text("budget"), value: ByteCountFormatter.string(fromByteCount: Int64(clamping: proposal.budget), countStyle: .memory))
            Toggle(text("remember"), isOn: $remember).help(text("rememberHelp"))
                .accessibilityIdentifier("low-memory-remember")
            Spacer(minLength: 4)
            HStack {
                Button(text("stop")) { resolve(false) }
                    .buttonStyle(WorkbenchGlassButtonStyle()).accessibilityIdentifier("low-memory-stop")
                Spacer()
                Button(text("run")) { resolve(true) }
                    .buttonStyle(WorkbenchGlassButtonStyle()).accessibilityIdentifier("low-memory-run")
                // Deliberately no defaultAction/Return shortcut: the submit key is not consent.
            }
        }.padding(20).id(proposal.id)
    }
    private func resolve(_ allow: Bool) {
        owner.resolve(proposalID: proposal.id, entryToken: proposal.entryToken, allow: allow, remember: remember)
    }
}

struct LowMemoryPreferenceControl: View {
    let owner: LowMemoryDecisionStore
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkbenchPicker(workflowText(language, "memory.preference"), selection: Binding(
                get: { owner.preference }, set: { owner.setPreference($0) })) {
                WorkbenchChoiceForEach(LowMemoryDecisionStore.Preference.allCases, id: \.self) { value in
                    WorkbenchChoice(workflowText(language, "memory.preference." + value.rawValue), value: value)
                }
            }.accessibilityIdentifier("settings-low-memory-preference")
            Text(workflowText(language, "memory.preferenceHelp")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Existing run details share this value-only projection; never evaluates a model.
struct LowMemoryExecutionDetails: View {
    let records: [InferenceExecutionRecord]
    @Environment(\.dLanguageStore) private var language
    private func text(_ key: String) -> String { workflowText(language, "memory." + key) }
    var body: some View {
        if !records.isEmpty {
            DisclosureGroup(text("executionDetails")) {
                ForEach(records, id: \.submissionID) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        let used = record.method?.rawValue ?? record.preferredMode
                        LabeledContent(text(record.executionStarted == true ? "actualMethod" : record.executionStarted == false ? "proposedMethod" : "unrecordedMethod"), value: text(used == "ssdLayered" ? "layered" : used))
                        if record.explicitlySelected { Text(text("explicit")) }
                        else if let decision = record.decision {
                            Text(text(decision == .userStopped ? "stopped" : decision == .denyByPreference ? "denied" : decision.rawValue))
                        }
                        if let reason = record.reason {
                            Text(text(reason == "noSupportedPlan" ? "unsupported" : reason == "noSupportedPlanWithinBudget" ? "allOverBudget" : "fixedOverBudget"))
                        }
                        LabeledContent(text("budget"), value: ByteCountFormatter.string(fromByteCount: Int64(clamping: record.budget), countStyle: .memory))
                        if let estimate = record.lowMemoryEstimate ?? record.preferredEstimate {
                            LabeledContent(text("estimate"), value: ByteCountFormatter.string(fromByteCount: Int64(clamping: estimate.peakBytes), countStyle: .memory))
                        }
                        WorkflowTechnicalDetails(value: String(data: (try? JSONEncoder().encode(record)) ?? Data(), encoding: .utf8) ?? "")
                    }.font(.caption).textSelection(.enabled)
                }
            }
        }
    }
}
