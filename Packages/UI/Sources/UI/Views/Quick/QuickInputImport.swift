import AppKit
import DWorkbench
import Foundation

/// One explicit Quick input action. The draft snapshot is captured before any panel or Store await.
@MainActor enum QuickInputImport {
    typealias SharedAssetResolver = (UUID, UUID?, UUID) async throws -> (ProjectStore, WorkflowAssetReference, String)

    enum Item {
        case file(URL)
        case png(Data)
        case managed(WorkflowCanvasTransfer)
    }

    struct Result {
        var published = 0
        var bound = 0
        var copied = 0
        var cancelled = false
        var failures: [String] = []
        var message: String? {
            if cancelled { return "导入已取消；已保存的素材仍在资料库，当前输入未修改。" }
            return failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    static func clipboardItems(_ pasteboard: NSPasteboard = .general) throws -> [Item] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(Item.file)
        }
        if let png = pasteboard.data(forType: .png) { return [.png(png)] }
        throw WorkflowIssue("剪贴板没有本地文件或PNG图像。")
    }

    static func run(_ items: [Item], quick: QuickGenerationController, draft: QuickDraft,
                    port: WorkflowPortDefinition, resolveSharedAsset: SharedAssetResolver? = nil) async -> Result {
        var result = Result()
        let activity: UUID
        do { activity = try quick.beginInputActivity() }
        catch is CancellationError { result.cancelled = true; return result }
        catch { result.failures = [error.localizedDescription]; return result }
        defer { quick.endInputActivity(activity) }
        let destination = quick.store
        var compatible: [WorkflowAssetReference] = []
        for (index, item) in items.enumerated() {
            let label: String
            switch item {
            case .file(let url): label = url.lastPathComponent.isEmpty ? "文件 \(index + 1)" : url.lastPathComponent
            case .png: label = "PNG \(index + 1)"
            case .managed(let transfer):
                switch transfer {
                case .asset(_, let id), .assetInstance(_, _, let id): label = "素材 " + String(id.uuidString.prefix(8))
                default: label = "拖入项 \(index + 1)"
                }
            }
            do {
                try quick.checkInputActivity(activity)
                let reference: WorkflowAssetReference
                switch item {
                case .file(let url):
                    guard url.isFileURL else { throw WorkflowIssue("只接受本地文件URL。") }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    reference = try await destination.importWorkflowMediaFile(at: url).record.reference
                    result.published += 1
                    try quick.checkInputActivity(activity)
                case .png(let data):
                    reference = try await destination.importWorkflowPNG(data, name: "Clipboard PNG").record.reference
                    result.published += 1
                    try quick.checkInputActivity(activity)
                case .managed(let transfer):
                    let projectID: UUID, instanceID: UUID?, assetID: UUID
                    switch try transfer.validated() {
                    case .asset(let project, let asset): (projectID, instanceID, assetID) = (project, nil, asset)
                    case .assetInstance(let project, let instance, let asset):
                        (projectID, instanceID, assetID) = (project, instance, asset)
                    default: throw WorkflowIssue("只能拖入项目素材。")
                    }
                    let manifest = await destination.snapshot()
                    try quick.checkInputActivity(activity)
                    if projectID == manifest.id &&
                        (instanceID == manifest.effectiveInstanceID ||
                         (instanceID == nil && manifest.effectiveInstanceID == manifest.id)) {
                        reference = try await destination.pinWorkflowAsset(assetID)
                        result.published += 1
                        try quick.checkInputActivity(activity)
                    } else {
                        guard let resolveSharedAsset else { throw WorkflowIssue("请先打开来源项目，再拖入该素材。") }
                        let (source, pinned, _) = try await resolveSharedAsset(projectID, instanceID, assetID)
                        try quick.checkInputActivity(activity)
                        let sourceManifest = await source.snapshot()
                        try quick.checkInputActivity(activity)
                        guard sourceManifest.id == projectID,
                              (instanceID == nil || sourceManifest.effectiveInstanceID == instanceID),
                              pinned.assetID == assetID, pinned.projectID == projectID else {
                            throw WorkflowIssue("来源项目或素材身份已改变。")
                        }
                        reference = try await destination.copyWorkflowAsset(pinned, from: source)
                        if source !== destination { result.copied += 1 }
                        result.published += 1
                        try quick.checkInputActivity(activity)
                    }
                }
                if port.assetListKind.map({ $0 == reference.kind }) ?? port.kinds.contains(reference.kind) {
                    compatible.append(reference)
                } else {
                    result.failures.append(label + "：素材已保留在资料库，但类型不符合此端口。")
                }
            } catch is CancellationError {
                result.cancelled = true
                return result
            } catch {
                if Task.isCancelled { result.cancelled = true; return result }
                result.failures.append(label + "：" + error.localizedDescription)
            }
        }
        do { try quick.checkInputActivity(activity) }
        catch { result.cancelled = true; return result }
        guard !compatible.isEmpty else { return result }
        if port.assetListKind == nil && compatible.count > 1 {
            result.failures.append("此端口一次只能绑定一个素材；有 \(compatible.count) 个兼容项，均已保留在资料库，请明确选择一个。")
            return result
        }
        do {
            try quick.checkInputActivity(activity)
            // A corrupt saved input needs an explicit user action, never an implicit repair.
            if let saved = draft.inputs[port.id] { _ = try port.resolveAssets(saved) }
            guard quick.store === destination else { throw WorkflowIssue("项目已改变；素材已保留在资料库，未修改当前输入。") }
            try quick.checkInputActivity(activity)
            try quick.commitImportedAssets(compatible, port: port, draftID: draft.id,
                                           expectedNode: draft.node, expectedInputs: draft.inputs)
            result.bound = compatible.count
        } catch is CancellationError {
            result.cancelled = true
        } catch {
            if Task.isCancelled { result.cancelled = true; return result }
            result.failures.append("绑定：" + error.localizedDescription)
        }
        return result
    }
}
