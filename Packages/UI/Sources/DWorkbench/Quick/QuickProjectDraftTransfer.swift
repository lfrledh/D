import DInference
import Foundation

/// Lossless projection of the two retired project generation forms. The source
/// document and its candidates stay in the project; this creates settings only.
enum QuickProjectDraftTransfer {
    static func image(_ source: ProjectDraft, capability: ImageExecutionCapability,
                      modelID: String, title: String, reference: WorkflowAssetReference?) throws -> QuickDraft {
        guard let definition = WorkflowRegistry.standard.operation("d.image.generate")?.definition else {
            throw WorkflowIssue("Unknown operation")
        }
        var node = definition.makeNode(); node.title = title
        node.parameters["modelID"] = .text(modelID)
        node.parameters["promptText"] = .text(source.prompt)
        node.parameters["width"] = .integer(source.imageSettings.width)
        node.parameters["height"] = .integer(source.imageSettings.height)
        node.parameters["steps"] = .integer(capability.steps)
        node.parameters["guidance"] = .decimal(Double(capability.guidanceScale))
        node.parameters["seed"] = .text(source.seedText)
        node.parameters["randomSeed"] = .flag(source.randomSeed)
        node.parameters["count"] = .integer(1)
        // Keep the saved execution envelope, including verified512. The selected
        // adapter validates it at admission; an unknown profile is never upgraded.
        let savedProfile = source.imageSettings.executionProfile
        guard [ImageExecutionCapability.verified512.profile, capability.profile,
               ImageExecutionCapability.referenceKlein4B.profile].contains(savedProfile) else {
            throw WorkflowIssue("所选模型与此节点的执行配方不同；不会静默替换。")
        }
        node.parameters["projectImageProfile"] = .text(savedProfile.identifier)
        node.parameters["projectImageProfileRevision"] = .integer(savedProfile.revision)
        return QuickDraft(id: UUID().uuidString, node: node,
            inputs: reference.map { ["ref": .asset($0)] } ?? [:])
    }

    static func video(_ source: VideoCreationDraft, modelID: String, title: String) throws -> QuickDraft {
        guard let definition = WorkflowRegistry.standard.operation("d.video.generate")?.definition else {
            throw WorkflowIssue("Unknown operation")
        }
        var node = definition.makeNode(); node.title = title
        node.parameters["modelID"] = .text(modelID)
        node.parameters["promptText"] = .text(source.prompt)
        node.parameters["negativePrompt"] = .text(source.negativePrompt)
        node.parameters["seed"] = .text(source.seedText)
        node.parameters["memoryBudgetGiB"] = nil
        node.parameters["memoryBudgetMiBText"] = .text(source.memoryBudgetMiBText)
        var result = QuickDraft(id: UUID().uuidString, node: node)
        for (key, raw) in [("width", source.widthText), ("height", source.heightText),
                           ("frameCount", source.framesText), ("frameRate", source.fpsNumeratorText),
                           ("frameRateDenominator", source.fpsDenominatorText), ("steps", source.stepsText)] {
            result.fieldText[key] = raw
            // Invalid raw stays visible and blocks admission, never falls back to
            // an executable default. The typed placeholder is not a request.
            result.node.parameters[key] = .integer(Int(raw) ?? 0)
        }
        for (key, raw) in [("guidance", source.guidanceText), ("scheduleShift", source.shiftText)] {
            result.fieldText[key] = raw
            result.node.parameters[key] = .decimal(Double(raw).flatMap { $0.isFinite ? $0 : nil } ?? 0)
        }
        return result
    }
}
