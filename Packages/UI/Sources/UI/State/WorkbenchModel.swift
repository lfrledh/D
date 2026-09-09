import AppKit
import DWorkbench
import Foundation
import Observation
import UniformTypeIdentifiers

/// Presentation facade: native panels and view bindings live here. ProjectSession retains
/// every task and persistence transaction independently of this facade or any SwiftUI view.
@MainActor @Observable
public final class WorkbenchModel {
    public let projectSession: ProjectSession
    public let audioRecordingEnabled: Bool
    private let audioPanels: any AudioWorkbenchPanelProviding
    private var isChoosingLocation = false
    public private(set) var hasPendingEditor = false
    public private(set) var editorCloseAttempted = false

    public func beginEditing() { hasPendingEditor = true; editorCloseAttempted = false }
    public func endEditing() { hasPendingEditor = false; editorCloseAttempted = false }
    private func refuseEditorClose() -> Bool {
        guard hasPendingEditor else { return false }
        editorCloseAttempted = true
        NSSound.beep()
        return true
    }

    public var manifest: ProjectManifest? { projectSession.manifest }
    public var projectURL: URL? { projectSession.projectURL }
    public var modelName: String? { projectSession.modelName }
    public var modelStatus: String { projectSession.modelStatus }
    public var selectedModelID: ModelID? { projectSession.selectedModelID }
    public var imageProfile: ImageModelProfile { projectSession.imageProfile }
    public var prompt: String {
        get { projectSession.prompt }
        set { projectSession.prompt = newValue }
    }
    public var randomSeed: Bool {
        get { projectSession.randomSeed }
        set { projectSession.randomSeed = newValue }
    }
    public var seedText: String {
        get { projectSession.seedText }
        set { projectSession.seedText = newValue }
    }
    public var selectedAssetID: UUID? { projectSession.selectedAssetID }
    public var documents: [ProjectDocument] { projectSession.documents }
    public var activeDocumentID: UUID? { projectSession.activeDocumentID }
    public var activeDocument: ProjectDocument? { projectSession.activeDocument }
    public var showingAllArtworks: Bool { projectSession.showingAllArtworks }
    public private(set) var comparisonSelection: [UUID] = []
    private var comparisonProjectID: UUID?
    private var comparisonProjectURL: URL?
    private var comparisonDocumentID: UUID?
    private var comparisonOriginalAssetID: UUID?
    private var comparisonWasAllArtworks = false
    public private(set) var comparisonAssetIDs: [UUID] = []
    public var visibleAssets: [ProjectAsset] {
        projectSession.visibleAssets
    }
    public var isComparing: Bool { comparisonAssetIDs.count == 2 && comparisonProjectID == manifest?.id && comparisonProjectURL == projectURL }

    public func createTextDocument() async {
        await endComparison()
        await projectSession.createTextDocument()
    }
    public func chooseTextModel() async {
        guard !isChangingProject, !isBusy else { return }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        let panel = NSOpenPanel()
        panel.title = "选择已有 Qwen2.5 0.5B Instruct 4-bit 模型"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await projectSession.registerTextModel(at: url)
    }

    public func createDocument(name: String = "新创作") async {
        await endComparison()
        await projectSession.createDocument(name: name)
    }
    public func renameDocument(id: UUID, name: String) async {
        await projectSession.renameDocument(id: id, name: name)
    }
    public func switchDocument(to id: UUID) async {
        await endComparison()
        await projectSession.selectDocument(id: id)
    }
    public func showAllArtworks() async { await endComparison(); await projectSession.showAllArtworks() }
    public func selectAsset(_ id: UUID?) async { await projectSession.selectAsset(id) }
    public func updateAsset(id: UUID, name: String? = nil, note: String? = nil, isFavorite: Bool? = nil) async {
        await projectSession.updateCandidate(assetID: id, name: name, isFavorite: isFavorite, note: note)
    }
    public func adoptAsset(_ id: UUID) async { await projectSession.adoptAsset(id: id) }
    public func clearAdoptedAsset(documentID: UUID) async {
        await projectSession.clearAdoptedAsset(documentID: documentID)
    }
    public func revealAsset(_ id: UUID) async {
        if !showingAllArtworks, let asset = manifest?.assets.first(where: { $0.id == id }),
           let job = manifest?.jobs.first(where: { $0.id == asset.jobID }), job.documentID != activeDocumentID {
            await switchDocument(to: job.documentID)
        }
        await selectAsset(id)
    }
    public func forkFromAsset(_ id: UUID) async {
        let originalProjectID = manifest?.id
        var acknowledged = false
        if let warning = projectSession.forkCompatibilityWarning(for: id) {
            let alert = NSAlert()
            alert.messageText = "使用当前模型探索"
            alert.informativeText = warning
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            acknowledged = true
        }
        guard originalProjectID == manifest?.id,
              manifest?.assets.contains(where: { $0.id == id }) == true else { return }
        await endComparison()
        guard originalProjectID == manifest?.id else { return }
        await projectSession.forkDocument(from: id, acknowledgeCurrentModel: acknowledged)
    }
    public func toggleComparisonCandidate(_ id: UUID) {
        if comparisonProjectID != manifest?.id || comparisonProjectURL != projectURL {
            clearComparisonState()
            comparisonProjectID = manifest?.id
            comparisonProjectURL = projectURL
        }
        guard manifest?.assets.contains(where: { $0.id == id }) == true else { return }
        if comparisonSelection.contains(id) { comparisonSelection.removeAll { $0 == id } }
        else if comparisonSelection.count < 2 { comparisonSelection.append(id) }
    }
    public func beginComparison() {
        let available = Set(manifest?.assets.map(\.id) ?? [])
        guard comparisonSelection.count == 2, comparisonSelection.allSatisfy(available.contains) else { return }
        comparisonDocumentID = activeDocumentID
        comparisonOriginalAssetID = selectedAssetID
        comparisonWasAllArtworks = showingAllArtworks
        comparisonAssetIDs = comparisonSelection
        projectSession.automaticResultSelectionEnabled = false
    }
    public func endComparison() async {
        if isComparing, comparisonDocumentID == activeDocumentID,
           comparisonWasAllArtworks == showingAllArtworks {
            await projectSession.selectAsset(comparisonOriginalAssetID)
        }
        clearComparisonState()
    }
    /// Project replacement invalidates transient presentation without writing to the new store.
    public func invalidateComparison() { clearComparisonState() }
    private func clearComparisonState() {
        comparisonAssetIDs = []; comparisonSelection = []; comparisonProjectID = nil; comparisonProjectURL = nil
        comparisonDocumentID = nil; comparisonOriginalAssetID = nil
        projectSession.automaticResultSelectionEnabled = true
    }

    public var errorMessage: String? {
        get { projectSession.errorMessage }
        set { projectSession.errorMessage = newValue }
    }
    public var isChangingProject: Bool { projectSession.isChangingProject || isChoosingLocation }
    public var isBusy: Bool { projectSession.isBusy }
    public var canGenerate: Bool { projectSession.canGenerate && !isChoosingLocation }
    public var selectedAsset: ProjectAsset? { projectSession.selectedAsset }
    public var selectedJob: ProjectJob? { projectSession.selectedJob }
    public var phases: [UUID: String] { projectSession.phases }
    public var progress: [UUID: Double] { projectSession.progress }
    public var liveStates: [UUID: JobState] { projectSession.liveStates }
    public var assetURLs: [UUID: URL] { projectSession.assetURLs }
    public var activeJobIDs: Set<UUID> { projectSession.activeJobIDs }

    public init(sessionFactory: @escaping @Sendable (URL) async throws -> WorkbenchSession,
                settings: UserDefaults = .standard, modelLibrary: ModelLibrary? = nil,
                audioEnabled: Bool = false, audioRecordingEnabled: Bool = false,
                audioTransport: AudioTransport? = nil,
                audioPanels: any AudioWorkbenchPanelProviding = NativeAudioWorkbenchPanels()) {
        self.audioRecordingEnabled = audioRecordingEnabled
        self.audioPanels = audioPanels
        projectSession = ProjectSession(sessionFactory: sessionFactory, settings: settings,
                                        modelLibrary: modelLibrary, audioEnabled: audioEnabled,
                                        audioRecordingEnabled: audioRecordingEnabled,
                                        audioTransport: audioTransport,
                                        closeDecision: Self.chooseCloseDecision)
    }

    /// A headless service can outlive or be presented by a new facade without transferring tasks.
    public init(projectSession: ProjectSession, audioRecordingEnabled: Bool = false,
                audioPanels: any AudioWorkbenchPanelProviding = NativeAudioWorkbenchPanels()) {
        self.projectSession = projectSession
        self.audioRecordingEnabled = audioRecordingEnabled
        self.audioPanels = audioPanels
    }

    public func clearError() { projectSession.clearError() }

    /// Shared native import action; the rendered origin is supplied by the caller.
    func audioImportAction(contextID: UUID, documentID: UUID?) -> () -> Void {
        { [weak self] in
            Task { await self?.importAudio(contextID: contextID, documentID: documentID) }
        }
    }

    public func importAudio() async {
        guard let contextID = projectSession.audio?.contextID else { return }
        await importAudio(contextID: contextID, documentID: activeDocumentID)
    }

    private func importAudio(contextID originContextID: UUID, documentID originDocumentID: UUID?) async {
        guard projectSession.audio?.contextID == originContextID,
              activeDocumentID == originDocumentID else {
            errorMessage = "文档已改变，未打开旧的导入操作。请在当前文档重新选择。"
            return
        }
        guard !projectSession.isChangingProject, !isChoosingLocation, let projectID = manifest?.id, let projectURL,
              let activeDocumentID,
              let controller = projectSession.audio else {
            rejectConcurrentAudioPanel()
            return
        }
        let contextID = controller.contextID
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        guard let source = await audioPanels.chooseAudioImport() else { return }
        guard manifest?.id == projectID, self.projectURL == projectURL,
              self.activeDocumentID == activeDocumentID,
              projectSession.audio === controller, controller.contextID == contextID else {
            errorMessage = "项目已改变，未导入所选音频。请在当前项目中重新选择。"
            return
        }
        let name = source.deletingPathExtension().lastPathComponent
        if await projectSession.importAudio(at: source, name: name) {
            clearComparisonState()
        }
    }

    public func startAudioRecording() async {
        guard audioRecordingEnabled else {
            errorMessage = "当前版本尚未启用麦克风录音；不会申请系统许可。请先导入 WAV 或 CAF PCM。"
            return
        }
        _ = await projectSession.startAudioRecording(name: "新录音")
    }

    public func finishAudioRecording() async {
        _ = await projectSession.finishAudioRecording()
    }

    public func retryPendingAudioCapture(id: UUID, contextID: UUID,
                                         renderDocumentID: UUID?) async {
        guard validateRenderContext(contextID: contextID, documentID: renderDocumentID) else { return }
        _ = await projectSession.retryPendingAudioCapture(id: id)
    }

    public func keepPendingAudioCaptureForRecovery(id: UUID, contextID: UUID,
                                                   renderDocumentID: UUID?) {
        guard validateRenderContext(contextID: contextID, documentID: renderDocumentID) else { return }
        guard projectSession.keepPendingAudioCaptureForRecovery(id: id) else {
            errorMessage = "无法保留这项待恢复录音；请等待当前音频操作结束后重试。"
            return
        }
    }

    public func exportOriginalAudio(contextID: UUID, documentID: UUID) async {
        guard let identity = activeAudioIdentity(contextID: contextID, documentID: documentID),
              let container = projectSession.audio?.metadata?.format.container else { return }
        let name = exportBaseName()
        let kind = AudioExportPanelKind.original(container)
        let request = AudioExportPanelRequest(
            kind: kind,
            suggestedName: "\(name).\(kind.filenameExtension)",
            title: "导出原声原件",
            explanation: "保持已登记的 \(kind.filenameExtension.uppercased()) 容器和原始字节；不会覆盖已有文件。"
        )
        guard let destination = await chooseAudioDestination(request),
              validate(identity),
              projectSession.audio?.metadata?.format.container == container,
              validateExtension(destination, kind: kind) else { return }
        _ = await projectSession.exportOriginalAudio(
            to: destination, contextID: identity.contextID, documentID: identity.documentID
        )
    }

    public func exportSavedAudioClip(id: UUID, contextID: UUID, documentID: UUID) async {
        guard let identity = activeAudioIdentity(contextID: contextID, documentID: documentID),
              let range = projectSession.audio?.document?.clips.first(where: { $0.id == id })?.range else {
            return
        }
        let kind = AudioExportPanelKind.float32WAVRange
        let request = rangeExportRequest(name: exportBaseName())
        guard let destination = await chooseAudioDestination(request), validate(identity),
              projectSession.audio?.document?.clips.first(where: { $0.id == id })?.range == range,
              validateExtension(destination, kind: kind) else {
            if validate(identity), projectSession.audio?.document?.clips.first(where: { $0.id == id })?.range != range {
                errorMessage = "片段已改变，未导出旧范围。请重新选择片段。"
            }
            return
        }
        _ = await projectSession.exportAudioClip(
            id: id, to: destination, contextID: identity.contextID, documentID: identity.documentID
        )
    }

    public func exportAudioRange(_ range: AudioFrameRange, editorRevision: UInt64,
                                 contextID: UUID, documentID: UUID) async {
        guard let identity = activeAudioIdentity(contextID: contextID, documentID: documentID),
              let controller = projectSession.audio,
              controller.editorRevision == editorRevision,
              controller.clipRangeInput == range else {
            errorMessage = "当前范围已经改变，请确认新范围后再导出。"
            return
        }
        let kind = AudioExportPanelKind.float32WAVRange
        let request = rangeExportRequest(name: exportBaseName())
        guard let destination = await chooseAudioDestination(request), validate(identity),
              controller.editorRevision == editorRevision, controller.clipRangeInput == range,
              validateExtension(destination, kind: kind) else {
            if validate(identity),
               controller.editorRevision != editorRevision || controller.clipRangeInput != range {
                errorMessage = "面板打开期间范围已改变，未导出旧范围。"
            }
            return
        }
        _ = await projectSession.exportAudioRange(
            range, to: destination, contextID: identity.contextID, documentID: identity.documentID
        )
    }

    private struct AudioIdentity {
        let projectID: UUID
        let projectURL: URL
        let controller: ProjectAudioController
        let contextID: UUID
        let documentID: UUID
    }

    private func activeAudioIdentity(contextID: UUID, documentID: UUID) -> AudioIdentity? {
        guard let projectID = manifest?.id, let projectURL, let controller = projectSession.audio,
              controller.contextID == contextID, controller.documentID == documentID,
              activeDocumentID == documentID,
              activeDocument?.kind == .audio else { return nil }
        return AudioIdentity(projectID: projectID, projectURL: projectURL, controller: controller,
                             contextID: controller.contextID, documentID: documentID)
    }

    private func validate(_ identity: AudioIdentity) -> Bool {
        guard manifest?.id == identity.projectID, projectURL == identity.projectURL,
              activeDocumentID == identity.documentID, activeDocument?.kind == .audio,
              projectSession.audio === identity.controller,
              projectSession.audio?.contextID == identity.contextID,
              projectSession.audio?.documentID == identity.documentID else {
            errorMessage = "项目或原声文档已改变，未执行旧操作。请在当前文档中重试。"
            return false
        }
        return true
    }

    private func validateRenderContext(contextID: UUID, documentID: UUID?) -> Bool {
        guard projectSession.audio?.contextID == contextID, activeDocumentID == documentID else {
            errorMessage = "当前文档已改变，未执行旧的原声操作。"
            return false
        }
        return true
    }

    private func chooseAudioDestination(_ request: AudioExportPanelRequest) async -> URL? {
        guard !isChoosingLocation else {
            rejectConcurrentAudioPanel()
            return nil
        }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        return await audioPanels.chooseAudioExport(request)
    }

    private func validateExtension(_ url: URL, kind: AudioExportPanelKind) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare(kind.filenameExtension) == .orderedSame else {
            errorMessage = "导出文件扩展名必须是 .\(kind.filenameExtension)。未写入任何文件。"
            return false
        }
        return true
    }

    private func rangeExportRequest(name: String) -> AudioExportPanelRequest {
        AudioExportPanelRequest(
            kind: .float32WAVRange,
            suggestedName: "\(name)-片段.wav",
            title: "导出原声范围",
            explanation: "所选帧范围会转换为原采样率和声道数的 32 位浮点 WAV；不会覆盖已有文件。"
        )
    }

    private func exportBaseName() -> String {
        let candidate = activeDocument?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? "D-原声" : candidate
    }

    private func rejectConcurrentAudioPanel() {
        if isChoosingLocation {
            errorMessage = "另一个文件选择窗口尚未结束，请先完成或取消它。"
        }
    }
    public func canCancel(_ id: UUID) -> Bool { projectSession.canCancel(id) }
    public func cancel(_ id: UUID) async { await projectSession.cancel(id) }
    public func copySettings(from id: UUID) async {
        guard let asset = manifest?.assets.first(where: { $0.jobID == id }) else { return }
        await forkFromAsset(asset.id)
    }
    public func restoreLastProject() async { await projectSession.restoreLastProject() }
    public func recoverArtifacts() async {
        guard !isChoosingLocation else { return }
        await projectSession.recoverArtifacts()
    }
    public func generate() async {
        guard !isChoosingLocation else { return }
        await projectSession.generate()
    }
    public func selectModel(id: ModelID) async {
        guard !isChoosingLocation else { return }
        await projectSession.selectModel(id: id)
    }
    public func registerModel(at url: URL) async {
        guard !isChoosingLocation else { return }
        await projectSession.registerModel(at: url)
    }
    public func createProject(at url: URL) async {
        guard !refuseEditorClose() else { return }
        guard !isChoosingLocation else { return }
        await projectSession.createProject(at: url)
    }
    public func openProject(at url: URL) async {
        guard !refuseEditorClose() else { return }
        guard !isChoosingLocation else { return }
        await projectSession.openProject(at: url)
    }
    public func closeProject() async { _ = await requestClose() }
    public func requestClose() async -> Bool {
        guard !refuseEditorClose() else { return false }
        guard !isChoosingLocation else { return false }
        return await projectSession.requestClose()
    }
    public func cancelAndCloseProject() async -> Bool {
        guard !refuseEditorClose() else { return false }
        guard !isChoosingLocation else { return false }
        return await projectSession.cancelAndCloseProject()
    }

    public func newProject() async {
        guard !refuseEditorClose() else { return }
        guard !isChangingProject else { return }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        let panel = NSSavePanel()
        panel.title = "新建 D 项目"
        panel.nameFieldStringValue = "未命名.dproject"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "dproject") ?? .package]
        panel.isExtensionHidden = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await projectSession.createProject(at: url)
    }

    public func openProject() async {
        guard !refuseEditorClose() else { return }
        guard !isChangingProject else { return }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        let panel = NSOpenPanel()
        panel.title = "打开 D 项目"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dproject") ?? .package]
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await projectSession.openProject(at: url)
    }

    public func registerModel() async {
        guard !isChangingProject, !isBusy else { return }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        let panel = NSOpenPanel()
        panel.title = "选择 FLUX.2 Klein 4B q8 模型文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await projectSession.registerModel(at: url)
    }

    public func exportSelected() async {
        guard let id = selectedAssetID, !isChangingProject else { return }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        let panel = NSSavePanel()
        panel.title = "导出 PNG"
        panel.nameFieldStringValue = "D-\(id.uuidString.prefix(8)).png"
        panel.allowedContentTypes = [.png]
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await projectSession.export(assetID: id, to: url)
    }

    private static func chooseCloseDecision() async -> ProjectCloseDecision {
        let alert = NSAlert()
        alert.messageText = "项目还有运行中或排队的任务"
        alert.informativeText = "关闭前需要等待任务结束并保存记录。取消也需要等待当前计算释放资源。"
        alert.addButton(withTitle: "等待完成后关闭")
        alert.addButton(withTitle: "取消任务后关闭")
        alert.addButton(withTitle: "继续编辑")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .wait
        case .alertSecondButtonReturn: return .cancel
        default: return .keepOpen
        }
    }
}
