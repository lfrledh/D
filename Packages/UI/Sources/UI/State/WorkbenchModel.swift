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
    public var selectedAssetID: UUID? {
        get { projectSession.selectedAssetID }
        set { projectSession.selectedAssetID = newValue }
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
    public func copySettings(from id: UUID) async { await projectSession.copySettings(from: id) }
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
        guard !isChoosingLocation else { return }
        await projectSession.createProject(at: url)
    }
    public func openProject(at url: URL) async {
        guard !isChoosingLocation else { return }
        await projectSession.openProject(at: url)
    }
    public func closeProject() async { _ = await requestClose() }
    public func requestClose() async -> Bool {
        guard !isChoosingLocation else { return false }
        return await projectSession.requestClose()
    }
    public func cancelAndCloseProject() async -> Bool {
        guard !isChoosingLocation else { return false }
        return await projectSession.cancelAndCloseProject()
    }

    public func newProject() async {
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
