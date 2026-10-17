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

/// Presentation memory only; never added to the project schema.
struct WorkflowCanvasViewContext: Hashable {
    let projectID: UUID?
    let rootGraphID: UUID?
    let bodyPath: [WorkflowCanvasBodyLocation]
}

struct WorkflowCanvasViewMemory: Equatable {
    let zoom: CGFloat
    let rawVisibleCenter: CGPoint
    let selectedNodeID: UUID?
}

struct WorkflowCanvasViewStateStore {
    private var values: [WorkflowCanvasViewContext: WorkflowCanvasViewMemory] = [:]

    mutating func save(_ state: WorkflowCanvasViewMemory, for context: WorkflowCanvasViewContext) {
        values[context] = state
    }

    mutating func capture(zoom: CGFloat, rawVisibleCenter: CGPoint,
                          selectedNodeID: UUID?, for context: WorkflowCanvasViewContext) {
        save(WorkflowCanvasViewMemory(zoom: zoom, rawVisibleCenter: rawVisibleCenter,
            selectedNodeID: selectedNodeID), for: context)
    }

    func state(for context: WorkflowCanvasViewContext) -> WorkflowCanvasViewMemory? {
        values[context]
    }
}
