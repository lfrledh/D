import DInference
import Foundation

/// Concrete model recipes reuse the same video service and runtime. These are
/// distinct from historical Wan v1, whose saved parameters retain their meaning.
enum WorkflowExternalVideoOperations {
    static let operations = ExternalVideoExecutionProfile.allCases.map(operation)
    private static func operation(_ profile: ExternalVideoExecutionProfile) -> WorkflowOperation {
        let h3 = profile == .h3BF16Full
        let title: String
        switch profile {
        case .h3BF16Full: title = "MiniMax H3 Base FL2VA · BF16"
        case .ltx23BF16Full: title = "LTX 2.3 dev · BF16"
        case .ltx23Q8GemmaQ4: title = "LTX 2.3 dev · Q8 / Gemma Q4"
        case .ltx25BF16Full: title = "LTX-2.5 dev · BF16"
        }
        let detail = h3
            ? "FL2VA：文字及可选首帧、尾帧，输出含声音的视频；公开 Base 已作 CFG 蒸馏。首帧按目标尺寸拉伸、尾帧填满裁切；流式加载不改变精度。未接入 Ref2VA。"
            : "非蒸馏 dev：文字及可选首帧，输出含声音的视频；流式加载扩散块，文字编码器和解码器仍需各自的内存。不接受尾帧或任意参考列表。"
        var fields: [WorkflowFieldDefinition] = [
            .init("promptText", "提示", .text(multiline: true), .text("A small boat on a calm lake.")),
            .init("width", "宽（32 的倍数）", .integer, .integer(256)),
            .init("height", "高（32 的倍数）", .integer, .integer(256)),
            .init("frameCount", h3 ? "帧数（5+17n，至少22）" : "帧数（8n+1）", .integer, .integer(h3 ? 22 : 9)),
            .init("frameRate", h3 ? "帧率（固定24）" : "帧率", .integer, .integer(24)),
            .init("steps", "步数", .integer, .integer(h3 ? 20 : 30)),
            .init("guidance", h3 ? "引导（固定1）" : "CFG 引导", .decimal, .decimal(h3 ? 1 : 3)),
            .init("seed", "种子", .text(multiline: false), .text("42")),
            .init("streamWeights", "流式加载扩散权重", .flag, .flag(true)),
            .init("memoryBudgetGiB", "显式内存预算 GiB（0使用运行时策略）", .integer, .integer(0)),
            WorkflowLanguageOperations.modelField,
        ]
        if !h3 {
            fields += [.init("negativePrompt", "负向提示", .text(multiline: true), .text("")),
                       .init("stg", "STG 引导", .decimal, .decimal(0))]
        }
        let recipe = WorkflowVideoRecipe(profile: profile)
        var inputs: [WorkflowPortDefinition] = [.init("prompt", "提示", kinds: [.text], required: false),
            .init("firstFrame", "首帧 PNG", kinds: [.image], required: false)]
        if h3 { inputs.append(.init("lastFrame", "尾帧 PNG", kinds: [.image], required: false)) }
        return WorkflowOperation(definition: .init(id: recipe.operationID, title: title, detail: detail,
            inputs: inputs,
            outputs: [.init("output", "含声音的视频", kinds: [.video])], fields: fields, modelKind: .video),
            validate: { node in
                guard let seed = UInt64(node.parameters["seed"]?.string ?? "") else { throw WorkflowIssue("视频种子无效。") }
                // Connected prompt values are validated after input binding; parameter
                // checks must neither run a model nor rewrite a submitted prompt.
                _ = try recipe.request(node: node, prompt: "Parameter validation", seed: seed)
            }, execute: { context, services in
                .outputs(["output": .asset(try await services.generateVideo(context: context))])
            })
    }
}
