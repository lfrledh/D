import DWorkbench
import Observation
import SwiftUI

/// A captured editor, not the live card's latest selection. An applied edit is
/// retried as a save only; its graph transaction must never run a second time.
@MainActor @Observable final class WorkflowCollectionRuleDraft {
    let controller: WorkflowController
    let nodeID: UUID
    let baseline: WorkflowAssetCollectionRule?
    private(set) var target: WorkflowCanvasInsertionTarget
    var enabled: Bool
    var folderID: UUID?
    private let editedRuleID = UUID()
    private(set) var applied = false
    private(set) var saved = false
    private var appliedValue: WorkflowAssetCollectionRule?
    private(set) var saving = false
    var failure: WorkflowIssue?
    @ObservationIgnored private let flush: @MainActor () async throws -> Void

    init(controller: WorkflowController, node: WorkflowNode, target: WorkflowCanvasInsertionTarget,
         flush: (@MainActor () async throws -> Void)? = nil) {
        self.controller = controller; nodeID = node.id; baseline = node.collectionRule; self.target = target
        enabled = baseline != nil; folderID = baseline?.folderID
        self.flush = flush ?? { try await controller.saveExplicitEdits() }
    }
    var value: WorkflowAssetCollectionRule? {
        guard enabled else { return nil }
        if let baseline, baseline.folderID == folderID { return baseline }
        return .init(id: editedRuleID, folderID: folderID)
    }
    var dirty: Bool { !saved && (applied || value != baseline) }
    var retriesSaving: Bool { applied || failure != nil }
    // Selection is not ownership. The applied rule ID/value is its exact version;
    // an unrelated layout revision must not prevent saving it. A retry can save the same captured graph after
    // navigation, but can neither apply the edit again nor write to a replacement.
    private var appliedObjectMatches: Bool {
        guard controller.canReadLibraryMetadata,
              controller.projectID == target.projectID, controller.projectInstanceID == target.instanceID,
              let root = controller.graphs.first(where: { $0.id == target.rootID }),
              let body = try? WorkflowGraphEditing.body(in: root, path: target.path), body.id == target.bodyID,
              let node = body.nodes.first(where: { $0.id == nodeID }) else { return false }
        return node.collectionRule == appliedValue
    }
    var allowsDiscard: Bool { !applied || saved || !appliedObjectMatches }
    private func stale() -> WorkflowIssue {
        .init("Collection rule editor target changed; the captured draft was not written to another container.", code: "container.issue.ruleTarget")
    }
    func save() async throws {
        guard !saving else { throw WorkflowIssue("Collection settings save already in progress.", code: "container.issue.ruleBusy") }
        saving = true; failure = nil; defer { saving = false }
        do {
            if saved { return }
            if applied {
                guard appliedObjectMatches else { throw stale() }
            } else {
                guard controller.isCurrent(target),
                      let node = controller.graph?.nodes.first(where: { $0.id == nodeID }),
                      node.collectionRule == baseline else { throw stale() }
            }
            if !applied, value != baseline {
                guard let updated = controller.setCollectionRule(value, nodeID: nodeID, target: target) else { throw stale() }
                target = updated; appliedValue = value; applied = true
            }
            try await flush()
            // The captured controller saved its own project. Navigation during
            // this await cannot turn a successful save into an unsaved dead end.
            saved = true
        } catch {
            let issue = error as? WorkflowIssue
            let value = WorkflowIssue(error.localizedDescription, code: issue?.code ?? "container.issue.ruleSave")
            failure = value; throw value
        }
    }
}

struct WorkflowCollectionRuleEditor: View {
    @Bindable var draft: WorkflowCollectionRuleDraft
    let review: Bool
    let library: SharedLibraryStore?
    @Environment(\.dLanguageStore) private var language
    @WorkbenchDismiss private var dismiss
    private func t(_ key: String) -> String { workflowText(language, "container." + key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(t(review ? "collectConfirmed" : "collectNew"), isOn: $draft.enabled)
                .disabled(draft.applied || draft.saving)
            Text(t("ruleFutureOnly")).font(.caption).foregroundStyle(.secondary)
            WorkbenchPicker(t("destination"), selection: $draft.folderID) {
                WorkbenchChoice(t("collectionDefaultDestination"), value: Optional<UUID>.none)
                if let library {
                    WorkbenchChoiceForEach(library.metadata.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
                        WorkbenchChoice(folder.name, value: Optional(folder.id))
                    }
                }
            }.disabled(!draft.enabled || draft.applied || draft.saving)
            if let failure = draft.failure {
                WorkbenchIssueText(raw: failure.reason, key: failure.code).foregroundStyle(.red)
            }
            HStack {
                Button(workspaceText(language, "cancel")) { dismiss() }
                    .buttonStyle(WorkbenchGlassButtonStyle())
                Spacer()
                Button(draft.retriesSaving ? workspaceText(language, "saveOnly") : t("saveSettings")) {
                    Task { do { try await draft.save(); $dismiss() } catch { /* Draft owns visible, recoverable failure. */ } }
                }.buttonStyle(WorkbenchPrimaryButtonStyle()).accessibilityIdentifier("container-rule-save")
                    .help(draft.retriesSaving ? workspaceText(language, "saveOnly.help") : t("saveSettings"))
            }.disabled(draft.saving)
        }.padding(24).frame(width: 460)
            .workbenchCloseProtection(isDirty: draft.dirty, isSaving: draft.saving,
                allowsDiscard: draft.allowsDiscard, save: { try await draft.save() })
    }
}
