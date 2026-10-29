import AppKit
import DWorkbench
import Foundation
import CoreGraphics

/// Human presentation only. Commands continue to use the full stored identities.
struct WorkflowNodeIdentity: Equatable {
    let title: String
    let detail: String?
    let annotation: String?

    static func modelIdentity(node: WorkflowNode, definition: WorkflowOperationDefinition?, defaults: [String: String]) -> String? {
        if let identity = node.parameters["modelID"]?.string, !identity.isEmpty { return identity }
        return definition?.modelKind.flatMap { defaults[$0.rawValue] }
    }

    @MainActor
    static func resolve(
        node: WorkflowNode,
        definition: WorkflowOperationDefinition?,
        modelChoices: [WorkflowModelChoice],
        assets: [ProjectAsset],
        tools: [WorkflowToolDefinition],
        language: UILanguageStore?
    ) -> Self {
        let function = definition.map { WorkflowCanvasPresentation.operationTitle($0, language: language) }
            ?? workflowText(language, "canvas.identity.unknownOperation", fallback: "未知操作")
        let title = node.title.isEmpty ? function : node.title
        var detail = function
        if let modelKind = definition?.modelKind {
            let modelID = node.parameters["modelID"]?.string ?? ""
            let model = modelChoices.first { $0.id == modelID && $0.kind == modelKind }
                ?? WorkflowModelRoutes.draftChoice(operationID: node.operationID, modelID: modelID)
            let state = model?.displayName ?? workflowText(language,
                modelID.isEmpty ? "canvas.identity.chooseModel" : "canvas.identity.unknownModel",
                fallback: modelID.isEmpty ? "选择模型" : "未识别的模型")
            detail += " · " + state
        } else if let reference = node.assetReference {
            detail += " · " + (assets.first { $0.id == reference.assetID }?.name
                ?? workflowText(language, "canvas.identity.unknownAsset", fallback: "未识别的素材"))
        } else if case .invoke(let reference) = node.control {
            detail += " · " + (fixedTool(reference: reference, tools: tools)?.name
                ?? workflowText(language, "canvas.identity.unknownTool", fallback: "未识别的工具")) + " · v\(reference.version)"
        }
        return Self(title: title, detail: detail == title ? nil : detail, annotation: nil)
    }

    static func fixedTool(reference: WorkflowToolReference,
                          tools: [WorkflowToolDefinition]) -> WorkflowToolDefinition? {
        tools.first {
            $0.id == reference.id && $0.version == reference.version
                && (try? WorkflowPlanCompiler.digest($0)) == reference.digest
        }
    }
}

/// Local presentation identity; never a frozen run or a project schema field.
struct WorkflowCanvasViewContext: Codable, Hashable {
    let projectID: UUID?
    let rootGraphID: UUID?
    let bodyPath: [WorkflowCanvasBodyLocation]
    var instanceID: UUID? = nil
}

struct WorkflowCanvasViewMemory: Codable, Equatable {
    let zoom: CGFloat
    let rawVisibleCenter: CGPoint
    let selectedNodeID: UUID?
}

/// Owned by the existing workbench facade. Continuous camera updates stay in
/// memory; one idle write and the normal close/termination flush persist at most
/// 128 graph/body views in the injected application's preference suite.
@MainActor final class WorkflowCanvasViewStateStore: NSObject {
    static let storageKey = "D.Workflow.canvasViews.v1"
    private struct Entry: Codable { let context: WorkflowCanvasViewContext; let state: WorkflowCanvasViewMemory }
    private struct Archive: Codable { var version = 1; let entries: [Entry] }
    private var values: [WorkflowCanvasViewContext: WorkflowCanvasViewMemory] = [:]
    private var recency: [WorkflowCanvasViewContext] = []
    private let settings: UserDefaults?
    private let capacity: Int
    private var pendingWrite: Task<Void, Never>?
    private var dirty = false
    private(set) var invalidStoredRecord = false
    private(set) var writeCount = 0

    init(settings: UserDefaults? = nil, capacity: Int = 128) {
        self.settings = settings; self.capacity = max(1, min(128, capacity))
        super.init()
        if let stored = settings?.object(forKey: Self.storageKey) {
            if let data = stored as? Data, data.count <= 1_048_576,
               let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1,
               archive.entries.count <= 128,
               Set(archive.entries.map(\.context)).count == archive.entries.count,
               archive.entries.allSatisfy({ Self.valid($0.state) && Self.persistable($0.context) }) {
                for entry in archive.entries.suffix(self.capacity) {
                    values[entry.context] = entry.state; recency.append(entry.context)
                }
            } else { invalidStoredRecord = true }
        }
        if settings != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(flush),
                name: NSApplication.willTerminateNotification, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private static func valid(_ state: WorkflowCanvasViewMemory) -> Bool {
        state.zoom.isFinite && state.zoom > 0 && state.rawVisibleCenter.x.isFinite && state.rawVisibleCenter.y.isFinite
    }
    private static func persistable(_ context: WorkflowCanvasViewContext) -> Bool {
        context.projectID != nil && context.instanceID != nil && context.rootGraphID != nil && context.bodyPath.count <= 8
    }

    func save(_ state: WorkflowCanvasViewMemory, for context: WorkflowCanvasViewContext, makeCurrent: Bool = true) {
        guard Self.valid(state) else { return }
        let changed = values[context] != state || (makeCurrent && recency.last != context)
        values[context] = state
        if makeCurrent || !recency.contains(context) {
            recency.removeAll { $0 == context }; recency.append(context)
        }
        while recency.count > capacity { values.removeValue(forKey: recency.removeFirst()) }
        guard changed, settings != nil, !invalidStoredRecord, Self.persistable(context) else { return }
        dirty = true
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    func capture(zoom: CGFloat, rawVisibleCenter: CGPoint,
                 selectedNodeID: UUID?, for context: WorkflowCanvasViewContext, makeCurrent: Bool = true) {
        save(WorkflowCanvasViewMemory(zoom: zoom, rawVisibleCenter: rawVisibleCenter,
            selectedNodeID: selectedNodeID), for: context, makeCurrent: makeCurrent)
    }

    func state(for context: WorkflowCanvasViewContext) -> WorkflowCanvasViewMemory? {
        values[context]
    }

    func lastContext(projectID: UUID?, instanceID: UUID?) -> WorkflowCanvasViewContext? {
        guard projectID != nil, instanceID != nil else { return nil }
        return recency.last { $0.projectID == projectID && $0.instanceID == instanceID }
    }

    @objc func flush() {
        pendingWrite?.cancel(); pendingWrite = nil
        guard dirty, !invalidStoredRecord, let settings else { return }
        let archive = Archive(entries: recency.compactMap { context in
            guard Self.persistable(context), let state = values[context] else { return nil }
            return Entry(context: context, state: state)
        })
        guard let data = try? JSONEncoder().encode(archive), data.count <= 1_048_576 else { return }
        settings.set(data, forKey: Self.storageKey); dirty = false; writeCount += 1
    }
}
