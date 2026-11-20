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

    enum ItemLabel {
        case original(String)
        case owned(String, [String: String])
        @MainActor func display(_ language: UILanguageStore?) -> String {
            switch self {
            case .original(let value): return value
            case .owned(let key, let arguments): return workflowText(language, key, arguments: arguments)
            }
        }
    }

    struct Failure {
        let raw: String
        var key: String? = nil
        var arguments: [String: String] = [:]
        var label: ItemLabel? = nil
        var labelIsNameArgument = false
        var binding = false
        init(_ error: any Error, label: String? = nil, binding: Bool = false) {
            raw = error.localizedDescription; key = (error as? WorkflowIssue)?.code
            self.label = label.map(ItemLabel.original); self.binding = binding
        }
        init(raw: String, key: String, arguments: [String: String]) {
            self.raw = raw; self.key = key; self.arguments = arguments
        }
        @MainActor func display(_ language: UILanguageStore?) -> String {
            var arguments = arguments
            if labelIsNameArgument { arguments["name"] = label?.display(language) }
            let summary = key.map { workflowText(language, $0, fallback: raw, arguments: arguments) } ?? raw
            if binding { return workflowText(language, "quick.input.issue.binding", arguments: ["detail": summary]) }
            if labelIsNameArgument { return summary }
            return label.map { $0.display(language) + ": " + summary } ?? summary
        }
    }

    struct Result {
        var published = 0
        var bound = 0
        var copied = 0
        var cancelled = false
        var failures: [Failure] = []
        @MainActor func display(_ language: UILanguageStore?) -> String? {
            if cancelled { return workflowText(language, "quick.input.cancelled") }
            return failures.isEmpty ? nil : failures.map { $0.display(language) }.joined(separator: "\n")
        }
        var message: String? {
            if cancelled { return "导入已取消；已保存的素材仍在资料库，当前输入未修改。" }
            return failures.isEmpty ? nil : failures.map(\.raw).joined(separator: "\n")
        }
    }

    static func clipboardItems(_ pasteboard: NSPasteboard = .general) throws -> [Item] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(Item.file)
        }
        if let png = pasteboard.data(forType: .png) { return [.png(png)] }
        throw WorkflowIssue("剪贴板没有本地文件或PNG图像。", code: "quick.input.issue.emptyClipboard")
    }

    static func run(_ items: [Item], quick: QuickGenerationController, draft: QuickDraft,
                    port: WorkflowPortDefinition, resolveSharedAsset: SharedAssetResolver? = nil, language: UILanguageStore? = nil) async -> Result {
        var result = Result()
        let activity: UUID
        do { activity = try quick.beginInputActivity() }
        catch is CancellationError { result.cancelled = true; return result }
        catch { result.failures = [.init(error)]; return result }
        defer { quick.endInputActivity(activity) }
        let destination = quick.store
        var compatible: [WorkflowAssetReference] = []
        for (index, item) in items.enumerated() {
            let label: ItemLabel
            switch item {
            case .file(let url): label = url.lastPathComponent.isEmpty ? .owned("quick.input.issue.file", ["index": String(index + 1)]) : .original(url.lastPathComponent)
            case .png: label = .original("PNG \(index + 1)")
            case .managed(let transfer):
                switch transfer {
                case .asset(_, let id), .assetInstance(_, _, let id): label = .owned("quick.input.issue.asset", ["id": String(id.uuidString.prefix(8))])
                default: label = .owned("quick.input.issue.dropped", ["index": String(index + 1)])
                }
            }
            do {
                try quick.checkInputActivity(activity)
                let reference: WorkflowAssetReference
                switch item {
                case .file(let url):
                    guard url.isFileURL else { throw WorkflowIssue("只接受本地文件URL。", code: "quick.input.issue.localFileOnly") }
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
                    default: throw WorkflowIssue("只能拖入项目素材。", code: "quick.input.issue.projectAssetOnly")
                    }
                    let manifest = await destination.snapshot()
                    try quick.checkInputActivity(activity)
                    if projectID == manifest.id &&
                        instanceID == manifest.effectiveInstanceID {
                        reference = try await destination.pinWorkflowAsset(assetID)
                        result.published += 1
                        try quick.checkInputActivity(activity)
                    } else {
                        guard let resolveSharedAsset else { throw WorkflowIssue("请先打开来源项目，再拖入该素材。", code: "quick.input.issue.openSource") }
                        let (source, pinned, _) = try await resolveSharedAsset(projectID, instanceID, assetID)
                        try quick.checkInputActivity(activity)
                        let sourceManifest = await source.snapshot()
                        try quick.checkInputActivity(activity)
                        guard sourceManifest.id == projectID,
                              (instanceID == nil || sourceManifest.effectiveInstanceID == instanceID),
                              pinned.assetID == assetID, pinned.projectID == projectID else {
                            throw WorkflowIssue("来源项目或素材身份已改变。", code: "quick.input.issue.sourceChanged")
                        }
                        if source === destination { reference = pinned }
                        else { reference = try await destination.copyWorkflowAsset(pinned, from: source) }
                        if source !== destination { result.copied += 1 }
                        result.published += 1
                        try quick.checkInputActivity(activity)
                    }
                }
                if port.assetListKind.map({ $0 == reference.kind }) ?? port.kinds.contains(reference.kind) {
                    compatible.append(reference)
                } else {
                    var failure = Failure(raw: label.display(language) + "：素材已保留在资料库，但类型不符合此端口。", key: "quick.input.issue.incompatible", arguments: [:])
                    failure.label = label
                    failure.labelIsNameArgument = true
                    result.failures.append(failure)
                }
            } catch is CancellationError {
                result.cancelled = true
                return result
            } catch {
                if Task.isCancelled { result.cancelled = true; return result }
                var failure = Failure(error)
                failure.label = label
                result.failures.append(failure)
            }
        }
        do { try quick.checkInputActivity(activity) }
        catch { result.cancelled = true; return result }
        guard !compatible.isEmpty else { return result }
        if port.assetListKind == nil && compatible.count > 1 {
            result.failures.append(.init(raw: "此端口一次只能绑定一个素材；有 \(compatible.count) 个兼容项，均已保留在资料库，请明确选择一个。", key: "quick.input.issue.multiple", arguments: ["count": String(compatible.count)]))
            return result
        }
        do {
            try quick.checkInputActivity(activity)
            // A corrupt saved input needs an explicit user action, never an implicit repair.
            if let saved = draft.inputs[port.id] { _ = try port.resolveAssets(saved) }
            guard quick.store === destination else { throw WorkflowIssue("项目已改变；素材已保留在资料库，未修改当前输入。", code: "quick.input.issue.projectChanged") }
            try quick.checkInputActivity(activity)
            try quick.commitImportedAssets(compatible, port: port, draftID: draft.id,
                                           expectedNode: draft.node, expectedInputs: draft.inputs, admittedActivity: activity)
            result.bound = compatible.count
        } catch is CancellationError {
            result.cancelled = true
        } catch {
            if Task.isCancelled { result.cancelled = true; return result }
            result.failures.append(.init(error, binding: true))
        }
        return result
    }
}
