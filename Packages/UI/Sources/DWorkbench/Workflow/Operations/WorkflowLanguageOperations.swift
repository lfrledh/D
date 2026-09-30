import DInference
import Foundation

/// New language nodes use typed values; historical M0 operation IDs retain their meaning.
enum WorkflowLanguageOperations {
    static let operations: [WorkflowOperation] = [language,
        makeLanguage(id: WorkflowModelRoutes.qwen35, title: "Qwen3.5-9B", visual: true),
        makeLanguage(id: WorkflowModelRoutes.qwen38, title: "Qwen3.8-27B", visual: true), video]
    static let modelField = WorkflowFieldDefinition("modelID", "模型内容身份", .text(multiline: false), .text(""))
    static let language = makeLanguage(id: "d.model.language", title: "Qwen2.5 Instruct · 兼容", visual: false)
    static func makeLanguage(id: String, title: String, visual: Bool) -> WorkflowOperation {
        let visualInputs: [WorkflowPortDefinition] = visual ? [
            .init("images", "有序参考图像", kinds: [.image, .list], required: false, assetListKind: .image),
            .init("video", "视频（2 FPS抽帧，无音频理解）", kinds: [.video], required: false)] : []
        let visualFields: [WorkflowFieldDefinition] = visual ? [
            .init("minimumPixels", "每图最小像素（0使用模型配置）", .integer, .integer(0)),
            .init("maximumPixels", "每图最大像素（0使用模型配置）", .integer, .integer(0)),
            .init("maximumVideoFrames", "抽帧安全预算", .integer, .integer(64))] : []
        return WorkflowOperation(definition: .init(id: id, title: title, detail: "任务生成文字；可配置 JSON 解析与结构校验，不是原生约束解码。",
        inputs: [.init("task", "任务", kinds: [.text], required: false), .init("content", "内容", kinds: [.text], required: false)] + visualInputs,
        outputs: [.init("output", "结果", kinds: WorkflowDataKind.allCases), .init("raw", "原始模型文字", kinds: [.text])],
        fields: [.init("task", "任务", .text(multiline: true), .text("请写一个简短的创作提案。")),
            .init("outputMode", "输出", .choice(["text", "json"]), .text("text")),
            .init("maximumPromptTokens", "输入 token 上限", .integer, .integer(2048)),
            .init("maximumOutputTokens", "输出 token 上限", .integer, .integer(256)),
            .init("temperature", "温度", .decimal, .decimal(0.7)), .init("topP", "Top P", .decimal, .decimal(0.95)), modelField] + visualFields, modelKind: .text),
        validate: { node in
            guard (1...(visual ? 262144 : 32768)).contains(try WorkflowScalarReader.integer("maximumPromptTokens", in: node)),
                  (1...(visual ? 262144 : 8192)).contains(try WorkflowScalarReader.integer("maximumOutputTokens", in: node)) else { throw WorkflowIssue("文字 token 范围无效。") }
            try WorkflowLimits.nonnegative(WorkflowScalarReader.decimal("temperature", in: node), field: "temperature", node: node)
            guard let mode = node.parameters["outputMode"]?.string, ["text", "json"].contains(mode) else { throw WorkflowIssue("输出模式无效。") }
            if mode == "json" {
                guard let schema = node.dataConfiguration?.schema else { throw WorkflowIssue("请明确 JSON 输出结构。") }
                try WorkflowStructuredText.validateSchema(schema)
            }
            let p = try WorkflowScalarReader.decimal("topP", in: node)
            guard p > 0 && p <= 1 else { throw WorkflowIssue("Top P 必须大于0且不超过1。") }
            if visual {
                let min = try WorkflowScalarReader.integer("minimumPixels", in: node)
                let max = try WorkflowScalarReader.integer("maximumPixels", in: node)
                guard min >= 0, max >= 0, min == 0 || max == 0 || min <= max,
                      try WorkflowScalarReader.integer("maximumVideoFrames", in: node) > 0 else { throw WorkflowIssue("视觉处理预算无效。") }
            }
        }, execute: { context, services in
            let task = try await text(context.inputs["task"], fallback: context.node.parameters["task"]?.string ?? "", services: services)
            let content = try await context.inputs["content"].asyncText(services)
            let raw = try await services.generateLanguage(task: task, content: content, context: context)
            let value = try await services.readText(raw)
            let output: WorkflowDatum
            if context.node.parameters["outputMode"]?.string == "json" {
                do {
                    guard let schema = context.node.dataConfiguration?.schema else { throw WorkflowIssue("请明确 JSON 输出结构。") }
                    output = try WorkflowStructuredText.parse(value, as: schema)
                } catch { throw WorkflowOutputValidationFailure(raw: raw, reason: error.localizedDescription) }
            } else { output = .text(value) }
            return .outputs(["output": .data(output), "raw": .asset(raw)])
        })
    }
    static let video = WorkflowOperation(definition: .init(id: "d.video.generate", title: "Wan2.1-T2V-1.3B", detail: "Wan2.1 T2V；不支持首尾帧或图像条件。",
        inputs: [.init("prompt", "提示", kinds: [.text], required: false)], outputs: [.init("output", "视频", kinds: [.video])],
        fields: [.init("promptText", "提示", .text(multiline: true), .text("A small boat on a calm lake.")),
            .init("negativePrompt", "负向提示", .text(multiline: true), .text("")),
            .init("width", "宽", .integer, .integer(WorkflowVideoPresets.fullPreview.width)),
            .init("height", "高", .integer, .integer(WorkflowVideoPresets.fullPreview.height)),
            .init("frameCount", "帧数 4n+1", .integer, .integer(WorkflowVideoPresets.fullPreview.frameCount)),
            .init("frameRate", "帧率", .integer, .integer(WorkflowVideoPresets.fullPreview.frameRate)),
            .init("memoryBudgetGiB", "显式内存预算 GiB（0使用运行时策略）", .integer, .integer(0)),
            .init("steps", "步数", .integer, .integer(WorkflowVideoPresets.fullPreview.steps)),
            .init("guidance", "引导", .decimal, .decimal(WorkflowVideoPresets.fullPreview.guidance)),
            .init("scheduleShift", "采样偏移", .decimal, .decimal(WorkflowVideoPresets.fullPreview.scheduleShift)),
            .init("seed", "种子", .text(multiline: false), .text("42")), modelField], modelKind: .video),
        execute: { context, services in .outputs(["output": .asset(try await services.generateVideo(context: context))]) })

    @MainActor static func text(_ value: WorkflowValue?, fallback: String = "", services: any WorkflowOperationServices) async throws -> String {
        guard let value else { return fallback }
        if let text = value.datum?.text { return text }
        if let ref = value.asset, ref.kind == .text { return try await services.readText(ref) }
        throw WorkflowIssue("此输入需要文字或明确的文字资产。")
    }
}
private extension Optional where Wrapped == WorkflowValue {
    @MainActor func asyncText(_ services: any WorkflowOperationServices) async throws -> String? {
        guard let value = self else { return nil }
        return try await WorkflowLanguageOperations.text(value, services: services)
    }
}
struct WorkflowOutputValidationFailure: LocalizedError {
    let raw: WorkflowAssetReference
    let reason: String
    var errorDescription: String? { "模型原始输出已保留（\(raw.assetID)），结构检查失败：\(reason)" }
}
