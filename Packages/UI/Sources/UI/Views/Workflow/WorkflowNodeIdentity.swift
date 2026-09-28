import DWorkbench
import Foundation
import CoreGraphics

/// A node's stored title is an annotation. Its executable identity comes from the
/// bound model, versioned tool, asset reference, or operation definition.
struct WorkflowNodeIdentity: Equatable {
    let title: String
    let detail: String?
    let annotation: String?

    @MainActor
    static func resolve(
        node: WorkflowNode,
        definition: WorkflowOperationDefinition?,
        modelChoices: [WorkflowModelChoice],
        assets: [ProjectAsset],
        tools: [WorkflowToolDefinition],
        language: UILanguageStore?
    ) -> Self {
        let annotation = node.title.isEmpty ? nil : node.title
        if let modelKind = definition?.modelKind {
            let modelID = node.parameters["modelID"]?.string ?? ""
            guard !modelID.isEmpty else {
                return Self(title: workflowText(language, "canvas.identity.chooseModel", fallback: "选择模型"),
                            detail: nil, annotation: annotation)
            }
            if let model = modelChoices.first(where: { $0.id == modelID && $0.kind == modelKind }) {
                return Self(title: model.displayName, detail: modelID, annotation: annotation)
            }
            return Self(title: workflowText(language, "canvas.identity.unknownModel", fallback: "未识别的模型"),
                        detail: modelID, annotation: annotation)
        }
        if let reference = node.assetReference {
            let name = assets.first(where: { $0.id == reference.assetID })?.name
                ?? workflowText(language, "canvas.identity.unknownAsset", fallback: "未识别的素材")
            return Self(title: name, detail: reference.assetID.uuidString, annotation: annotation)
        }
        if case .invoke(let reference) = node.control {
            let matching = tools.first {
                $0.id == reference.id && $0.version == reference.version
                    && (try? WorkflowPlanCompiler.digest($0)) == reference.digest
            }
            let name = matching?.name
                ?? workflowText(language, "canvas.identity.unknownTool", fallback: "未识别的工具")
            return Self(title: name, detail: "v\(reference.version) · \(reference.id.uuidString)",
                        annotation: annotation)
        }
        let title = definition.map { WorkflowCanvasPresentation.operationTitle($0, language: language) }
            ?? workflowText(language, "canvas.identity.unknownOperation", fallback: "未知操作")
        return Self(title: title, detail: node.operationID, annotation: annotation)
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
    let scrollPoint: CGPoint
    let selectedNodeID: UUID?
}

struct WorkflowCanvasViewStateStore {
    private var values: [WorkflowCanvasViewContext: WorkflowCanvasViewMemory] = [:]

    mutating func save(_ state: WorkflowCanvasViewMemory, for context: WorkflowCanvasViewContext) {
        values[context] = state
    }

    func state(for context: WorkflowCanvasViewContext) -> WorkflowCanvasViewMemory? {
        values[context]
    }
}
