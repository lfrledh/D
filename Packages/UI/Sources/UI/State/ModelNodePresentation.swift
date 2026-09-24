import DWorkbench
import Foundation
import Observation

/// Presentation ownership only. This is not a page-independent application operation API.
@MainActor @Observable
final class ModelNodePresentation {
    private(set) var pane: WorkspacePane = .creations
    private(set) var selectedNodeID: String?
    private var revision = UUID()

    func selectPane(_ value: WorkspacePane) {
        guard pane != value else { return }
        pane = value; revision = UUID()
    }
    func selectNode(_ value: String?) {
        guard selectedNodeID != value else { return }
        selectedNodeID = value; revision = UUID()
    }
    func projectChanged() {
        pane = .creations; selectedNodeID = nil; revision = UUID()
    }
    func modalityChanged() {
        selectedNodeID = nil
        if pane != .nodes { pane = .creations }
        revision = UUID()
    }

    func tagWriter(node: ModelNodeDescriptor, store: ModelNodeTagStore,
                   model: WorkbenchModel) -> ([String]) -> String? {
        let capturedRevision = revision
        let epoch = model.projectSession.navigationEpoch
        return { tags in
            guard self.revision == capturedRevision, self.pane == .nodes,
                  self.selectedNodeID == node.id, model.creatorMode == node.modality,
                  model.projectSession.navigationEpoch == epoch else {
                return "模型页面已改变，请在当前页面重新编辑标签。"
            }
            do { try store.setTags(tags, for: node.id); return nil }
            catch { return error.localizedDescription }
        }
    }

    /// Both the menu command and its regression tests dispatch this exact captured action.
    func generationAction(model: WorkbenchModel, enabled: @escaping () -> Bool) -> () async -> Bool {
        let capturedRevision = revision
        let epoch = model.projectSession.navigationEpoch
        let mode = model.creatorMode
        let documentID = model.presentedDocument?.id
        let sourcesMode = model.showingTextSources
        return {
            guard self.revision == capturedRevision, self.pane != .nodes, enabled() else { return false }
            return await model.generateCaptured(mode: mode, epoch: epoch, documentID: documentID, sourcesMode: sourcesMode)
        }
    }

    func generationCommand(model: WorkbenchModel, enabled: @escaping () -> Bool) -> WorkbenchGenerationCommand {
        let action = generationAction(model: model, enabled: enabled)
        return WorkbenchGenerationCommand(title: model.visibleGenerationTitle,
            isEnabled: pane != .nodes && enabled()) { Task { _ = await action() } }
    }
}
