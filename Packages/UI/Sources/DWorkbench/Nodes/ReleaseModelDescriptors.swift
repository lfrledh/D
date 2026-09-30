import Foundation

/// UI-only projection of typed operation definitions and pinned model registrations.
/// Execution always validates the original operation contract; these strings are never parsed.
enum ReleaseModelDescriptors {
    static var entries: [ModelNodeDescriptor] {
        var values = ((try? TextModelProfiles.registeredVLM()) ?? []).map { profile in
            descriptor(id: profile.id, mode: .text, title: profile.displayTitle,
                model: profile.repository, revision: profile.revision,
                precision: profile.quantizationBits == 0 ? "Original BF16" : "Affine \(profile.quantizationBits)-bit",
                engine: "mlx.vlm.qwen35 · MLX LM 3.31.4", operation: profile.repository.contains("Qwen3.8-27B") ? WorkflowModelRoutes.qwen38 : WorkflowModelRoutes.qwen35)
        }
        values.append(descriptor(id: "flux2-klein-4b-bf16", mode: .image, title: "FLUX.2-klein-4B · BF16",
            model: "black-forest-labs/FLUX.2-klein-4B", revision: "e7b7dc27f91deacad38e78976d1f2b499d76a294",
            precision: "Original BF16 · distilled Klein 4B", engine: "mlx.image.flux2-klein · Flux2", operation: "d.image.generate"))
        values.append(descriptor(id: "flux2-dev-bf16", mode: .image, title: "FLUX.2-dev · BF16",
            model: "black-forest-labs/FLUX.2-dev", revision: "26afe3a78bb242c0a8bb181dcc8937bb16e5c66c",
            precision: "Original BF16", engine: "mlx.image.flux2-dev · Flux2", operation: WorkflowModelRoutes.fluxDev))
        values.append(descriptor(id: "ace-step-1.5-xl-sft-f32-no-lm", mode: .audio,
            title: "ACE-Step 1.5 XL SFT · F32 / no-LM", model: "ACE-Step/acestep-v15-xl-sft",
            revision: "d06de46b4622f781cf07f4a013a67d591ca52819", precision: "Original F32 XL SFT / no-LM",
            engine: "mlx.audio.ace-step-1.5-xl-sft", operation: WorkflowModelRoutes.ace))
        return values
    }
    static func descriptor(id: String, mode: CreatorMode, title: String, model: String,
                           revision: String, precision: String, engine: String, operation: String) -> ModelNodeDescriptor {
        let definition = WorkflowRegistry.standard.operation(operation)!.definition
        func port(_ value: WorkflowPortDefinition) -> ModelNodePort {
            .init(id: value.id, title: value.title,
                dataType: value.kinds.map(\.rawValue).joined(separator: " / ") + (value.assetListKind.map { " · ordered " + $0.rawValue } ?? ""),
                requirement: value.required ? .required : .optional, detail: "")
        }
        return .init(id: id, modality: mode, title: title, summary: definition.detail,
            modelIdentity: model, revision: revision, engine: engine, device: "MLX GPU",
            precision: precision, availability: .evaluation,
            deploymentNote: "固定资源另行导入；已有实现不等于当前环境已通过真实推理。执行时重新校验安装、条件及资源。",
            operations: [.init(id: definition.id, title: definition.title, summary: definition.detail,
                inputs: definition.inputs.map(port), outputs: definition.outputs.map(port),
                parameters: definition.fields.map { field in
                    .init(id: field.id, title: field.title, defaultValue: String(describing: field.defaultValue),
                        acceptedValues: String(describing: field.kind), detail: "执行由共享有类型契约校验。", isAdjustable: true)
                })],
            notes: ["Quick 与 Canvas 使用同一个操作契约；此页只展示，不作执行规则。"],
            evidencePaths: ["docs/tasks/D-RELEASE-FREEZE-01.md"])
    }
}
