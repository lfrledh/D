import AppKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

/// Native location choices; model and project ownership remain with ProjectSession.
struct WorkflowHostView: View {
    let model: WorkbenchModel
    let nodeTags: ModelNodeTagStore
    @Environment(\.dLanguageStore) private var languageStore
    var body: some View {
        Group {
            if let controller = model.projectSession.workflow {
                WorkflowCanvasView(controller: controller,
                    onTextModel: { chooseModel(controller: controller, kind: .text) },
                    onImageModel: { chooseModel(controller: controller, kind: .image) },
                    onImport: { id in Task { await importFile(nodeID: id, controller: controller) } },
                    onDestination: { Task { await destination(controller) } },
                    onPublishText: { Task { await model.projectSession.publishTextToWorkflow() } },
                    onReturnText: { ref in Task { await model.projectSession.returnWorkflowText(ref) } },
                    onAdditionalModel: { chooseModel(controller: controller, kind: $0) },
                    onRecord: { nodeID in Task { await model.projectSession.startWorkflowRecording(nodeID: nodeID, controller: controller) } },
                    nodeTags: nodeTags,
                    onImportAsset: { Task { await importAsset(controller) } },
                    onDropFile: { url in
                        guard model.projectSession.workflow === controller, controller.canEditCanvas else { return false }
                        Task { await importAssetURL(url, controller: controller) }; return true
                    })
                    .safeAreaInset(edge: .bottom) {
                        WorkflowCaptureRecoveryView(model: model)
                        if model.projectSession.workflowRecordingNodeID != nil {
                            HStack {
                                Text(languageStore?.text("workflow.recording.active", fallback: "本次原声录音：结束后保存为独立资产。") ?? "本次原声录音")
                                Button(languageStore?.text("workflow.recording.finish", fallback: "结束录音／取消许可等待") ?? "结束录音") {
                                    Task { await model.projectSession.finishWorkflowRecording() }
                                }.accessibilityIdentifier("workflow-record-finish")
                            }.padding().background(.regularMaterial)
                        }
                    }
                    .sheet(isPresented: Binding(get: { controller.mediaPreviewReference != nil }, set: { if !$0 { controller.mediaPreviewReference = nil } })) {
                        if let reference = controller.mediaPreviewReference {
                            WorkflowMediaPreviewPanel(session: model.projectSession, controller: controller, reference: reference)
                        }
                    }
            } else { ProgressView((languageStore?.text("workflow.host.loading", fallback: "正在读取项目流程…") ?? "正在读取项目流程…")) }
        }
        .task(id: model.manifest?.id) { await model.projectSession.openWorkflow() }
    }
    private func chooseModel(controller: WorkflowController, kind: WorkflowModelKind) {
        // Capture synchronously, before either the task or the native panel suspends.
        guard let target = controller.modelSelectionTarget(), target.kind == kind else { return }
        Task {
            guard model.projectSession.workflow === controller, controller.isCurrent(target) else { return }
            if kind == .pitch { model.projectSession.bindSelectedWorkflowModel(); return }
            let panel = NSOpenPanel(); panel.title = (languageStore?.text("workflow.host.model", fallback: "选择此节点使用的已安装模型") ?? "选择此节点使用的已安装模型")
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            guard await panel.begin() == .OK, let url = panel.url,
                  model.projectSession.workflow === controller, controller.isCurrent(target) else { return }
            await model.projectSession.registerWorkflowModel(at: url, target: target, controller: controller)
        }
    }
    private func importFile(nodeID: UUID, controller: WorkflowController) async {
        guard !model.isChangingProject else { return }
        let panel = NSOpenPanel(); panel.title = (languageStore?.text("workflow.host.import", fallback: "导入为不可变资产快照") ?? "导入为不可变资产快照")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .png, .jpeg, .audio, .mpeg4Movie, .json, .init(filenameExtension: "md") ?? .plainText]
        guard await panel.begin() == .OK, let url = panel.url, model.projectSession.workflow === controller else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await controller.importFile(url, nodeID: nodeID)
    }
    private func importAsset(_ controller: WorkflowController) async {
        guard controller.canEditCanvas, !model.isChangingProject else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = languageStore?.text("canvas.assets.import", fallback: "导入素材") ?? "导入素材"
        panel.allowedContentTypes = [.plainText, .png, .jpeg, .audio, .mpeg4Movie, .json, .init(filenameExtension: "md") ?? .plainText]
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await importAssetURL(url, controller: controller)
    }
    private func importAssetURL(_ url: URL, controller: WorkflowController) async {
        guard model.projectSession.workflow === controller, controller.canEditCanvas, !model.isChangingProject else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await controller.importLibraryFile(url)
    }
    private func destination(_ controller: WorkflowController) async {
        guard !model.isBusy, !model.isChangingProject else { return }
        let panel = NSOpenPanel(); panel.title = (languageStore?.text("workflow.host.destination", fallback: "选择导出目录（新建包含媒体、配方和回执的导出包）") ?? "选择导出目录（新建包含媒体、配方和回执的导出包）")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, model.projectSession.workflow === controller else { return }
        await model.projectSession.selectWorkflowDestination(at: url)
    }
}

/// Recovery must be reachable without navigating to the audio page: a failed
/// capture deliberately blocks that navigation until the user preserves it.
struct WorkflowCaptureRecoveryView: View {
    let model: WorkbenchModel
    @Environment(\.dLanguageStore) private var languageStore
    var body: some View {
        if let audio = model.projectSession.audio, !audio.pendingCaptures.isEmpty {
            let contextID = audio.contextID
            let documentID = model.activeDocumentID
            VStack(alignment: .leading, spacing: 8) {
                Text(languageStore?.text("workflow.recording.recovery", fallback: "待恢复录音：重试保存，或保留原文件后继续。") ?? "待恢复录音")
                ForEach(audio.pendingCaptures) { capture in
                    HStack {
                        Text(capture.name).lineLimit(1)
                        Button(languageStore?.text("workflow.recording.retry", fallback: "重试保存") ?? "重试保存") {
                            Task { await model.retryPendingAudioCapture(id: capture.id,
                                contextID: contextID, renderDocumentID: documentID) }
                        }.accessibilityIdentifier("workflow-record-retry-\(capture.id.uuidString)")
                        Button(languageStore?.text("workflow.recording.keep", fallback: "保留待恢复，继续操作") ?? "保留待恢复，继续操作") {
                            model.keepPendingAudioCaptureForRecovery(id: capture.id,
                                contextID: contextID, renderDocumentID: documentID)
                        }.accessibilityIdentifier("workflow-record-keep-\(capture.id.uuidString)")
                    }
                }
            }
            .disabled(audio.isBusy || model.isChangingProject)
            .padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
        }
    }
}

private struct WorkflowMediaPreviewPanel: View {
    let session: ProjectSession
    let controller: WorkflowController
    let reference: WorkflowAssetReference
    @State private var ready = false
    @State private var requestID = UUID()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dLanguageStore) private var languageStore
    var body: some View {
        VStack(spacing: 14) {
            if ready {
                if reference.kind == .video {
                    VideoPreview(url: session.videoPreviewURL, identity: session.videoPreviewIdentity).frame(minWidth: 520, minHeight: 300)
                } else {
                    HStack {
                        Button(languageStore?.text("workflow.preview.play", fallback: "播放") ?? "播放") { session.playWorkflowAudio(reference, requestID: requestID) }
                        Button(languageStore?.text("workflow.preview.pause", fallback: "暂停") ?? "暂停") { session.pauseWorkflowAudio(reference, requestID: requestID) }
                    }
                    Text(reference.assetID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else { Text(controller.errorMessage ?? (languageStore?.text("workflow.preview.preparing", fallback: "正在核对已保存媒体…") ?? "正在核对已保存媒体…")) }
            Button(languageStore?.text("workflow.preview.close", fallback: "关闭") ?? "关闭") { dismiss() }
        }
        .padding(20).frame(minWidth: 420, minHeight: 140)
        .task(id: reference) { ready = await session.prepareWorkflowPreview(reference, controller: controller, requestID: requestID) != nil }
        .onDisappear { session.endWorkflowPreview(reference, requestID: requestID) }
    }
}
