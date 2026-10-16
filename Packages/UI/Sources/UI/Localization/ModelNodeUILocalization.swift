import DWorkbench
import Foundation

/// Display copies only. Canonical matching prevents translating a user's renamed
/// descriptor merely because it happens to reuse a built-in identity.
@MainActor enum ModelNodeUILocalization {
    static let registryBackedIDs: Set<String> = [
        "Qwen/Qwen3.5-9B", "Qwen/Qwen3.8-27B", "mlx-community/Qwen3.5-9B-4bit", "mlx-community/Qwen3.8-27B-4bit",
        "flux2-klein-4b-bf16", "flux2-dev-bf16", "ace-step-1.5-xl-sft-f32-no-lm",
        "video.model.minimax-h3-fl2va-bf16-full-v1", "video.model.ltx-2.3-dev-bf16-full-v1",
        "video.model.ltx-2.3-dev-q8-gemma3-q4-test-v1", "video.model.ltx-2.5-dev-bf16-full-v1"
    ]
    static func isCanonical(_ node: ModelNodeDescriptor) -> Bool { ModelNodeCatalog.entries.first { $0.id == node.id } == node }
    static func usesRegistry(_ node: ModelNodeDescriptor) -> Bool { isCanonical(node) && registryBackedIDs.contains(node.id) }
    static func owned(_ source: String, language: UILanguageStore?) -> String {
        let precisionKeys = ["Original BF16": "consistency.model.precision.originalBF16", "Affine 4-bit": "consistency.model.precision.affine4", "Original BF16 · distilled Klein 4B": "consistency.model.precision.distilled4B", "Original F32 XL SFT / no-LM": "consistency.model.precision.f32NoLM"]
        guard let key = precisionKeys[source] ?? ModelNodeOwnedCopy.keys[source] else { return source }
        return workflowText(language, key, fallback: source)
    }
    static func display(_ source: ModelNodeDescriptor, language: UILanguageStore?) -> ModelNodeDescriptor {
        guard isCanonical(source) else { return source }
        func t(_ value: String) -> String { owned(value, language: language) }
        let useRegistry = registryBackedIDs.contains(source.id), isExternalVideo = source.id.hasPrefix("video.model.")
        var definitions: [WorkflowOperationDefinition] = []
        let operations = source.operations.map { operation -> ModelNodeOperation in
            if useRegistry, let definition = WorkflowRegistry.standard.operation(operation.id)?.definition {
                definitions.append(definition)
                @MainActor func port(_ value: WorkflowPortDefinition, input: Bool) -> ModelNodePort {
                    let original = (input ? operation.inputs : operation.outputs).first { $0.id == value.id }
                    let kinds = value.kinds.map { $0.rawValue }.joined(separator: " / ")
                    let dataType: String
                    if let element = value.assetListKind { dataType = kinds + " · " + t("有序") + " " + element.rawValue }
                    else { dataType = original?.dataType ?? kinds }
                    // Obsolete external-video copy incorrectly claimed no first/last
                    // frame ports. Display the actual registered contract instead.
                    return .init(id: value.id, title: WorkflowCanvasPresentation.portTitle(operationID: definition.id, port: value, input: input, language: language),
                        dataType: t(dataType), requirement: value.required ? .required : .optional,
                        detail: isExternalVideo && input ? "" : t(original?.detail ?? ""))
                }
                let parameters = definition.fields.map { field -> ModelNodeParameter in
                    let original = operation.parameters.first { $0.id == field.id }
                    return .init(id: field.id, title: WorkflowCanvasPresentation.fieldTitle(operationID: definition.id, field: field, language: language),
                        defaultValue: original?.defaultValue ?? String(describing: field.defaultValue),
                        acceptedValues: original.map { t($0.acceptedValues) } ?? String(describing: field.kind),
                        detail: original.map { t($0.detail) } ?? t("执行由共享有类型契约校验。"), isAdjustable: original?.isAdjustable ?? true)
                }
                return .init(id: operation.id, title: WorkflowCanvasPresentation.operationTitle(definition, language: language),
                    summary: WorkflowCanvasPresentation.operationDetail(definition, language: language), inputs: definition.inputs.map { port($0, input: true) },
                    outputs: definition.outputs.map { port($0, input: false) }, parameters: parameters)
            }
            @MainActor func port(_ value: ModelNodePort) -> ModelNodePort {
                let requirement: ModelNodePortRequirement
                if case .conditional(let condition) = value.requirement { requirement = .conditional(t(condition)) } else { requirement = value.requirement }
                return .init(id: value.id, title: t(value.title), dataType: t(value.dataType), requirement: requirement, detail: t(value.detail))
            }
            return .init(id: operation.id, title: t(operation.title), summary: t(operation.summary), inputs: operation.inputs.map(port), outputs: operation.outputs.map(port),
                parameters: operation.parameters.map { .init(id: $0.id, title: t($0.title), defaultValue: t($0.defaultValue), acceptedValues: t($0.acceptedValues), detail: t($0.detail), isAdjustable: $0.isAdjustable) })
        }
        return .init(id: source.id, modality: source.modality,
            title: isExternalVideo && definitions.count == 1 ? WorkflowCanvasPresentation.operationTitle(definitions[0], language: language) : t(source.title),
            summary: definitions.count == 1 ? WorkflowCanvasPresentation.operationDetail(definitions[0], language: language) : t(source.summary),
            modelIdentity: source.modelIdentity, revision: source.revision, engine: t(source.engine), device: t(source.device), precision: t(source.precision),
            availability: source.availability, deploymentNote: t(source.deploymentNote), operations: operations, notes: source.notes.map(t), evidencePaths: source.evidencePaths)
    }
    static func availability(_ value: ModelNodeAvailability, language: UILanguageStore?) -> String { owned(value.title, language: language) }
    static func requirement(_ value: ModelNodePortRequirement, language: UILanguageStore?) -> String {
        switch value {
        case .required: workflowText(language, "workflow.port.required", fallback: "Required")
        case .optional: workflowText(language, "workflow.port.optional", fallback: "Optional")
        case .conditional: owned("条件必选", language: language)
        }
    }
}
