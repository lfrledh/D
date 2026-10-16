import AppKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

/// Native location choices; model and project ownership remain with ProjectSession.
struct WorkflowHostView: View {
    let model: WorkbenchModel
    let nodeTags: ModelNodeTagStore
    var metadata: SharedLibraryStore? = nil
    var library: ModelLibraryModel? = nil
    var onQuickUse: ((WorkflowNode) -> Void)? = nil
    var libraryContent: ((WorkflowCanvasLibraryMode, CGPoint, @escaping () -> Void) -> AnyView)? = nil
    var onSharedAssetDrop: ((UUID, UUID?, UUID, CGPoint, WorkflowCanvasInsertionTarget) -> Bool)? = nil
    var acceptsLegacyAsset: ((UUID, UUID) -> Bool)? = nil
    @Environment(\.dLanguageStore) private var languageStore
    var body: some View {
        Group {
            if let controller = model.projectSession.workflow {
                WorkflowCanvasView(controller: controller,
                    onTextModel: { chooseModel(controller: controller, kind: .text) },
                    onImageModel: { chooseModel(controller: controller, kind: .image) },
                    onImport: { id in Task { await importFile(nodeID: id, controller: controller) } },
                    onDestination: { Task { await destination(controller) } },
                    onPublishText: {
                        guard let target = controller.canvasInsertionTarget() else { return }
                        Task { await model.projectSession.publishTextToWorkflow(target: target, controller: controller) }
                    },
                    onReturnText: { ref in Task { await model.projectSession.returnWorkflowText(ref) } },
                    onAdditionalModel: { chooseModel(controller: controller, kind: $0) },
                    onRecord: { nodeID in Task { await model.projectSession.startWorkflowRecording(nodeID: nodeID, controller: controller) } },
                    nodeTags: nodeTags, metadata: metadata,
                    onImportAsset: { Task { await importAsset(controller) } },
                    onDropFile: { url in
                        guard model.projectSession.workflow === controller, controller.canEditCanvas else { return false }
                        Task { await importAssetURL(url, controller: controller) }; return true
                    }, onQuickUse: onQuickUse, libraryContent: libraryContent,
                    onSharedAssetDrop: onSharedAssetDrop, acceptsLegacyAsset: acceptsLegacyAsset, captureControls:AnyView(captureControls))
                    .environment(\.workflowViewerModel,model)
                    .onAppear { model.viewers.library=metadata }
                    .onChange(of:controller.mediaPreviewReference) { _,reference in
                        guard let reference,model.projectSession.workflow === controller else { return }
                        controller.mediaPreviewReference=nil
                        do { try model.viewers.open(.init(title:controller.availableAssets.first { $0.id == reference.assetID }?.name ?? "D",subtitle:model.manifest?.name ?? "",value:.asset(reference)),model:model,language:languageStore) }
                        catch { controller.errorMessage=error.localizedDescription }
                    }

            } else { ProgressView((languageStore?.text("workflow.host.loading", fallback: "正在读取项目流程…") ?? "正在读取项目流程…")) }
        }
        .environment(\.workbenchModelReadiness, model.projectSession.explicitModelReadiness)
        .task(id: model.manifest?.effectiveInstanceID) { await model.projectSession.openWorkflow() }
    }
    private var captureControls:some View {
        VStack(spacing:4) {
                        WorkflowCaptureRecoveryView(model: model)
                        if model.projectSession.workflowRecordingNodeID != nil {
                            HStack {
                                Text(languageStore?.text("workflow.recording.active", fallback: "本次原声录音：结束后保存为独立资产。") ?? "本次原声录音")
                                Button(languageStore?.text("workflow.recording.finish", fallback: "结束录音／取消许可等待") ?? "结束录音") {
                                    Task { await model.projectSession.finishWorkflowRecording() }
                                }.accessibilityIdentifier("workflow-record-finish")
                            }.padding().workbenchPanel(cornerRadius: 12)
                        }
        }
    }
    private func chooseModel(controller: WorkflowController, kind: WorkflowModelKind) {
        // Capture synchronously, before either the task or the native panel suspends.
        guard let target = controller.modelSelectionTarget(), target.kind == kind else { return }
        if kind != .pitch, let library {
            let owner = model.projectSession
            library.presentSelection { id in
                do {
                    guard model.projectSession === owner else { throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。")) }
                    try owner.checkWorkflowModelSelection(target: target, controller: controller)
                    let choice = try await owner.selectWorkflowInstallation(id: id) { choice in
                        guard model.projectSession === owner else { throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。")) }
                        try owner.checkWorkflowModelSelection(target: target, controller: controller)
                        guard choice.kind == kind else { throw WorkflowIssue(library.managementText("wrongKind", "此模型与目标节点类型不符。")) }
                    }
                    try owner.checkWorkflowModelSelection(target: target, controller: controller)
                    guard choice.kind == kind else { throw WorkflowIssue(library.managementText("wrongKind", "此模型与目标节点类型不符。")) }
                    controller.bindModel(choice.id, to: target)
                    library.isPresented = false
                } catch { library.errorMessage = error.localizedDescription }
            }
            let targetName = controller.graph?.nodes.first { $0.id == target.nodeID }.map { WorkflowHumanPresentation.name($0, in: controller.graph?.nodes ?? []) } ?? library.managementText("unknown", "未知")
            let targetTitle = (model.manifest?.name ?? "D") + " · " + ([controller.rootGraph?.name, controller.bodyPath.isEmpty ? nil : controller.graph?.name].compactMap { $0 }.joined(separator: " / ")) + " · " + targetName
            library.captureSelectionPresentation(targetTitle) {
                guard model.projectSession === owner else { return false }
                do { try owner.checkWorkflowModelSelection(target: target, controller: controller); return true } catch { return false }
            }
            library.configurationSelectionAction = { item in
                do {
                    guard model.projectSession === owner,
                          item.selectable, try owner.modelInventoryConfigurations().contains(item),
                          item.identity.hasPrefix(kind.rawValue + ":") else { throw WorkflowIssue(library.managementText("targetChanged", "选用目标或配置已改变，资源保留。")) }
                    try owner.checkWorkflowModelSelection(target: target, controller: controller)
                    controller.bindModel(item.identity, to: target)
                    library.isPresented = false
                } catch { library.errorMessage = error.localizedDescription }
            }
            return
        }
        Task {
            if kind == .pitch {
                guard model.projectSession.workflow === controller, controller.isCurrent(target) else { return }
                model.projectSession.bindSelectedWorkflowModel(); return
            }
            do {
                try model.projectSession.checkWorkflowModelRegistration(target: target, controller: controller)
                let panel = NSOpenPanel(); panel.title = (languageStore?.text("workflow.host.model", fallback: "选择此节点使用的已安装模型") ?? "选择此节点使用的已安装模型")
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                guard await panel.begin() == .OK, let url = panel.url else { return }
                try model.projectSession.checkWorkflowModelRegistration(target: target, controller: controller)
                await model.projectSession.registerWorkflowModel(at: url, target: target, controller: controller)
            } catch { controller.errorMessage = error.localizedDescription }
        }
    }
    private func importFile(nodeID: UUID, controller: WorkflowController) async {
        guard !model.isChangingProject else { return }
        guard let target = controller.assetBindingTarget(nodeID: nodeID),
              let (url, mode) = await NativeAssetImportPanel.choose(language: languageStore),
              model.projectSession.workflow === controller, controller.isCurrent(target) else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await controller.importFile(url, nodeID: nodeID, mode: mode)
    }
    private func importAsset(_ controller: WorkflowController) async {
        guard controller.canEditCanvas, !model.isChangingProject else { return }
        guard let (url, mode) = await NativeAssetImportPanel.choose(language: languageStore) else { return }
        await importAssetURL(url, controller: controller, mode: mode)
    }
    private func importAssetURL(_ url: URL, controller: WorkflowController, mode: AssetImportMode = .copy) async {
        guard model.projectSession.workflow === controller, controller.canEditCanvas, !model.isChangingProject else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await controller.importLibraryFile(url, mode: mode)
    }
    private func destination(_ controller: WorkflowController) async {
        await Self.chooseDestination(controller, model: model, language: languageStore)
    }
    static func chooseDestination(_ controller: WorkflowController, model: WorkbenchModel, language languageStore: UILanguageStore?) async {
        guard model.projectSession.workflow === controller, controller.readOnlyReason == nil, !model.isBusy, !model.isChangingProject else { return }
        let panel = NSOpenPanel(); panel.title = (languageStore?.text("workflow.host.destination", fallback: "选择导出目录（新建包含媒体、配方和回执的导出包）") ?? "选择导出目录（新建包含媒体、配方和回执的导出包）")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, model.projectSession.workflow === controller, controller.readOnlyReason == nil, !model.isBusy, !model.isChangingProject else { return }
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
            .padding().frame(maxWidth: .infinity, alignment: .leading).workbenchPanel(cornerRadius: 12)
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
            HStack {
                Button(languageStore?.text("baseline02.ui.label.572cf45ba436", fallback: "返回") ?? "返回", systemImage: "chevron.left") { dismiss() }
                Spacer()
            }
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
        }
        .padding(20).frame(minWidth: 420, minHeight: 140)
        .task(id: reference) { ready = await session.prepareWorkflowPreview(reference, controller: controller, requestID: requestID) != nil }
        .onDisappear { session.endWorkflowPreview(reference, requestID: requestID) }
    }
}
