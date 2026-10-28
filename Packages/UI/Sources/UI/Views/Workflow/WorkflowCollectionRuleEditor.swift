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
    var tagIDs: Set<UUID>
    var editsTags = false
    var newTagNames: [String] = []
    var tagName = ""
    var invalidTagName = false
    private let tagStore: SharedLibraryStore?
    private let editedRuleID = UUID()
    private(set) var applied = false
    private(set) var saved = false
    private var appliedValue: WorkflowAssetCollectionRule?
    private(set) var saving = false
    var failure: WorkflowIssue?
    @ObservationIgnored private let flush: @MainActor () async throws -> Void

    init(controller: WorkflowController, node: WorkflowNode, target: WorkflowCanvasInsertionTarget,
         tagStore: SharedLibraryStore? = nil, flush: (@MainActor () async throws -> Void)? = nil) {
        self.tagStore = tagStore
        self.controller = controller; nodeID = node.id; baseline = node.collectionRule; self.target = target
        enabled = baseline != nil; folderID = baseline?.folderID; tagIDs = baseline?.tagIDs ?? []
        self.flush = flush ?? { try await controller.saveExplicitEdits() }
    }
    var value: WorkflowAssetCollectionRule? {
        guard enabled else { return nil }
        if let baseline, !(editsTags && baseline.folderID != nil), baseline.folderID == folderID, (baseline.tagIDs ?? []) == tagIDs { return baseline }
        return .init(id: editedRuleID, tagIDs: tagIDs)
    }
    var dirty: Bool { !saved && (applied || value != baseline || !newTagNames.isEmpty || !tagName.isEmpty) }
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
            if !applied, enabled, !tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WorkflowIssue("Finish adding the tag before saving.", code: "container.issue.pendingTag")
            }
            if !applied, enabled, tagStore == nil, !newTagNames.isEmpty || !tagIDs.isEmpty {
                throw WorkflowIssue("Tag store is unavailable; the draft is retained.", code: "metadata.tags.unavailable")
            }
            if !applied, enabled, let tagStore {
                guard tagIDs.allSatisfy({ tagStore.metadata.tags[$0] != nil }) else { throw WorkflowIssue("Selected tag disappeared.", code: "container.issue.tagChanged") }
                if !newTagNames.isEmpty {
                    tagIDs.formUnion(try tagStore.createTags(newTagNames)); newTagNames.removeAll(); editsTags = true
                }
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
            Text(t("ruleSaveFailure")).font(.caption).foregroundStyle(.secondary)
            Text(t("ruleOffKeepsSaved")).font(.caption).foregroundStyle(.secondary)
            if let old = draft.baseline?.folderID, !draft.editsTags {
                Text(t("legacyFolder").replacingOccurrences(of: "{name}", with: library?.metadata.folders[old]?.name ?? old.uuidString))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(t("editTags")) {
                HStack {
                    TextField(t("newTag"), text: $draft.tagName)
                    Button(t("addTag")) {
                        let value = draft.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty, value.count <= 32 else { draft.invalidTagName = true; return }
                        draft.invalidTagName = false
                        if let existing = library?.metadata.tags.values.first(where: { $0.name.utf8.elementsEqual(value.utf8) }) {
                            draft.tagIDs.insert(existing.id); draft.editsTags = true
                        } else if !draft.newTagNames.contains(value) { draft.newTagNames.append(value) }
                        draft.tagName = ""
                    }.disabled(draft.tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if draft.invalidTagName { Text(workflowText(language, "metadata.tags.invalidName")).foregroundStyle(.red) }
                ForEach(draft.newTagNames, id: \.self) { name in
                    HStack { Text(name); Button { draft.newTagNames.removeAll { $0 == name } } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel(workflowText(language, "metadata.tags.removePending")) }
                }
                Toggle(t("collectionDefaultDestination"), isOn: Binding(get: {
                    draft.tagIDs.isEmpty && draft.newTagNames.isEmpty && (draft.baseline?.folderID == nil || draft.editsTags)
                }, set: { empty in
                    if empty { draft.tagIDs.removeAll(); draft.newTagNames.removeAll(); draft.tagName = ""; draft.editsTags = true }
                })).help(t("collectionDefaultDestination.help"))
                if let library {
                    ForEach(library.metadata.tags.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
                        Toggle(tag.name, isOn: Binding(get: { draft.tagIDs.contains(tag.id) }, set: { selected in
                            draft.editsTags = true
                            if selected { draft.tagIDs.insert(tag.id) } else { draft.tagIDs.remove(tag.id) }
                        }))
                    }
                }
            }.disabled(!draft.enabled || draft.applied || draft.saving || library == nil)
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
