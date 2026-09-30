import DInference
import Foundation

extension ModelNodeCatalog {
    static let externalVideoEntries: [ModelNodeDescriptor] = ExternalVideoExecutionProfile.allCases.map { profile in
        let definition = WorkflowExternalVideoOperations.operations.first { $0.definition.id == WorkflowVideoRecipe(profile: profile).operationID }!.definition
        let h3 = profile == .h3BF16Full
        let quantized = profile == .ltx23Q8GemmaQ4
        return ModelNodeDescriptor(id: "video.model." + profile.rawValue, modality: .video,
            title: definition.title, summary: definition.detail,
            modelIdentity: h3 ? "MiniMaxAI/MiniMax-H3 · FL2VA" : "Lightricks/LTX · dev",
            revision: profile.modelRevision,
            engine: h3 ? "h3.c · 原生 Metal" : "ltx-2-mlx · Python MLX",
            device: "神经网络使用 Apple GPU；媒体编码在 CPU；本机成功运行需另看验证记录。",
            precision: quantized ? "DiT Q8 / Gemma3 Q4；非蒸馏 dev" : (h3 ? "全尺寸 BF16；公开 Base 为 CFG 蒸馏" : "全尺寸 BF16；非蒸馏 dev"),
            availability: .evaluation,
            deploymentNote: "节点已定义；执行必须取得对应运行时和固定模型资源，未准备时明确拒绝。App 不附模型权重。",
            operations: [.init(id: definition.id, title: definition.title, summary: definition.detail,
                inputs: [.init(id: "prompt", title: "文字提示", dataType: "UTF-8 String", requirement: .required,
                               detail: "可由输入框或文字端口提供；本节点没有参考图或首尾帧端口。")],
                outputs: [.init(id: "output", title: "含声音的视频", dataType: "H.264 + AAC MP4", requirement: .required,
                                detail: h3 ? "AAC 32 kHz 双声道；音视频共同属于同一资产。" : "AAC 48 kHz 双声道；音视频共同属于同一资产。")],
                parameters: definition.fields.filter { $0.id != "modelID" }.map { field in
                    .init(id: field.id, title: field.title, defaultValue: String(describing: field.defaultValue),
                          acceptedValues: "由此模型的有类型请求契约校验", detail: field.id == "streamWeights"
                            ? "只改变扩散权重加载方式；不改精度、不绕过取消或资源管理。" : "详细联合限制见执行配方。",
                          isAdjustable: true)
                })],
            notes: ["完整精度配置与量化测试配置是不同身份，不自动替换。",
                    "流式加载不是无内存上限；编码、解码和激活仍使用统一内存。",
                    "模型已有适配、资源已安装、某机器已验收是不同状态。"],
            evidencePaths: ["Sources/DInference/ExternalVideoExecutionProfile.swift",
                            "Sources/DInference/ExternalVideoModelManifest.swift",
                            "docs/tasks/D-VIDEO-MODELS-01.md"])
    }
}
