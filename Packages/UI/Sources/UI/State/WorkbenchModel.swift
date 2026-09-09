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
        panel.title = "选择已注册的 Qwen2.5 Instruct 4-bit 模型（0.5B／1.5B／7B／32B）"
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
                settings: UserDefaults = .standard, modelLibrary: ModelLibrary? = nil) {
        projectSession = ProjectSession(sessionFactory: sessionFactory, settings: settings,
                                        modelLibrary: modelLibrary, closeDecision: Self.chooseCloseDecision)
    }

    /// A headless service can outlive or be presented by a new facade without transferring tasks.
    public init(projectSession: ProjectSession) { self.projectSession = projectSession }

    public func clearError() { projectSession.clearError() }
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
