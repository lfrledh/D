import AppKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

/// Native location choices; model and project ownership remain with ProjectSession.
struct WorkflowHostView: View {
    let model: WorkbenchModel
    var body: some View {
        Group {
            if let controller = model.projectSession.workflow {
                WorkflowCanvasView(controller: controller,
                    onTextModel: { Task { await model.chooseTextModel(); model.projectSession.bindSelectedWorkflowModel() } },
                    onImageModel: { Task { await model.registerModel(); model.projectSession.bindSelectedWorkflowModel() } },
                    onImport: { id in Task { await importFile(nodeID: id, controller: controller) } },
                    onDestination: { Task { await destination(controller) } },
                    onPublishText: { Task { await model.projectSession.publishTextToWorkflow() } },
                    onReturnText: { ref in Task { await model.projectSession.returnWorkflowText(ref) } })
            } else { ProgressView("正在读取项目流程…") }
        }
        .task(id: model.manifest?.id) { await model.projectSession.openWorkflow() }
    }
    private func importFile(nodeID: UUID, controller: WorkflowController) async {
        guard !model.isChangingProject else { return }
        let panel = NSOpenPanel(); panel.title = "导入为不可变资产快照"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .png, .jpeg, .init(filenameExtension: "md") ?? .plainText]
        guard await panel.begin() == .OK, let url = panel.url, model.projectSession.workflow === controller else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await controller.importFile(url, nodeID: nodeID)
    }
    private func destination(_ controller: WorkflowController) async {
        guard !model.isBusy, !model.isChangingProject else { return }
        let panel = NSOpenPanel(); panel.title = "选择导出目录（新建包含媒体、配方和回执的导出包）"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, model.projectSession.workflow === controller else { return }
        await model.projectSession.selectWorkflowDestination(at: url)
    }
}
