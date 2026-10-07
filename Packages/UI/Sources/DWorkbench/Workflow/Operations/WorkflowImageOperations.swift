import Foundation

/// Concrete operations; shared scheduling, assets and persistence remain outside this module.
enum WorkflowImageOperations {
    static let imageGenerate = makeGenerate(id: "d.image.generate", title: "FLUX.2-klein-4B", dev: false)
    static let devGenerate = makeGenerate(id: WorkflowModelRoutes.fluxDev, title: "FLUX.2-dev · BF16", dev: true)
    static func makeGenerate(id: String, title: String, dev: Bool) -> WorkflowOperation { WorkflowOperation(
        definition: .init(
            id: id, title: title, detail: "生成相互独立且保留身份的候选。",
            inputs: [
                .init("prompt", "提示文字", kinds: [.text], required: false),
                .init("ref", "有序参考图像", kinds: [.image, .list], required: false, assetListKind: .image),
            ],
            outputs: [.init("output", "候选图像", kinds: [.images])],
            fields: [
                .init("promptText", "后备提示", .text(multiline: true), .text("")),
                .init("width", "宽度", .integer, .integer(512)),
                .init("height", "高度", .integer, .integer(512)),
                .init("steps", "步数", .integer, .integer(dev ? 50 : 4)),
                .init("guidance", "引导", .decimal, .decimal(dev ? 4 : 1)),
                .init("seed", "种子", .text(multiline: false), .text("42")),
                .init("count", "候选数", .integer, .integer(3)),
                .init("memoryBudgetGiB", "显式内存预算 GiB（0使用运行时策略）", .integer, .integer(0)),
                .init("loadingStrategy", "加载方式", .choice(["staged", "ssdLayered"]), .text("staged")),
                .init("modelID", "模型内容身份", .text(multiline: false), .text("")),
            ], modelKind: .image
        ),
        validate: { node in
            try WorkflowLimits.positive(WorkflowScalarReader.integer("width", in: node), field: "width", node: node)
            try WorkflowLimits.positive(WorkflowScalarReader.integer("height", in: node), field: "height", node: node)
            try WorkflowLimits.positive(WorkflowScalarReader.integer("steps", in: node), field: "steps", node: node)
            try WorkflowLimits.nonnegative(WorkflowScalarReader.decimal("guidance", in: node), field: "guidance", node: node)
            _ = try WorkflowLanguageMessageForm.memoryBudgetBytes(node.parameters)
            if let value = node.parameters["loadingStrategy"] {
                guard let mode = value.string, ["staged", "ssdLayered"].contains(mode) else {
                    throw WorkflowIssue("此图像实现不支持所选加载方式。", nodeID: node.id)
                }
            }
            let seed = try WorkflowScalarReader.text("seed", in: node)
            guard !seed.isEmpty, seed.utf8.allSatisfy({ (48 ... 57).contains($0) }), UInt64(seed) != nil else {
                throw WorkflowIssue("seed 必须是 UInt64 十进制字符串。", nodeID: node.id)
            }
            let count = try WorkflowScalarReader.integer("count", in: node)
            guard (1 ... 8).contains(count) else { throw WorkflowIssue("count 必须为 1...8。", nodeID: node.id) }
        },
        execute: { context, services in
            try WorkflowExecution.requireModel(in: context.node)
            let prompt: String
            if let input = context.inputs["prompt"] {
                prompt = try await WorkflowLanguageOperations.text(input, services: services)
            } else {
                prompt = try WorkflowScalarReader.text("promptText", in: context.node)
            }
            guard !prompt.isEmpty else { throw WorkflowIssue("生成提示不能为空。", nodeID: context.node.id, port: "prompt") }
            try WorkflowExecution.ensureTextLimit(prompt, node: context.node, port: "prompt")
            let references = try context.inputs["ref"].map {
                try WorkflowPortDefinition("ref", "", kinds: [.image, .list], required: false, assetListKind: .image).resolveAssets($0)
            } ?? []
            // Context owns the complete ordered list; this argument retains old service ABI.
            let reference = references.count == 1 ? references.first : nil
            let candidates = try await services.generateImages(prompt: prompt, reference: reference, context: context)
            let expectedCount = try WorkflowScalarReader.integer("count", in: context.node)
            guard candidates.count == expectedCount,
                  Set(candidates.map(\.id)).count == candidates.count,
                  Set(candidates.map(\.attemptID)).count == candidates.count else {
                throw WorkflowIssue("生成服务必须返回指定数量且身份独立的全部候选。", nodeID: context.node.id)
            }
            return .outputs(["output": .collection(candidates)])
        }
    ) }

    static let imageResize = WorkflowOperation(
        definition: .init(
            id: "d.image.resize", title: "调整图像尺寸", detail: "按明确模式调整尺寸。",
            inputs: [.init("input", "图像", kinds: [.image])],
            outputs: [.init("output", "图像", kinds: [.image])],
            fields: [
                .init("width", "宽度", .integer, .integer(512)),
                .init("height", "高度", .integer, .integer(512)),
                .init("mode", "模式", .choice(["fit", "fill", "stretch"]), .text("fit")),
            ]
        ),
        validate: { node in
            let width = try WorkflowScalarReader.integer("width", in: node), height = try WorkflowScalarReader.integer("height", in: node)
            guard (1 ... 8_192).contains(width), (1 ... 8_192).contains(height),
                  width <= 32 * 1_024 * 1_024 / height else {
                throw WorkflowIssue("尺寸必须为 1...8192，且总像素不超过 32 Mi。", nodeID: node.id)
            }
        },
        execute: { context, services in
            let reference = try WorkflowExecution.inputAsset("input", kind: .image, context: context)
            let output = try await services.transformImage(reference, context: context)
            return .outputs(["output": .asset(output)])
        }
    )

    static let imageConvert = WorkflowOperation(
        definition: .init(
            id: "d.image.convert", title: "转换图像", detail: "显式选择编码及背景。",
            inputs: [.init("input", "图像", kinds: [.image])],
            outputs: [.init("output", "图像", kinds: [.image])],
            fields: [
                .init("format", "格式", .choice(ImageCodecRegistry.standard.formatIDs), .text("png")),
                .init("quality", "质量", .decimal, .decimal(0.9)),
                .init("background", "背景", .choice(["white", "black"]), .text("white")),
            ]
        ),
        validate: { node in
            try WorkflowLimits.range(WorkflowScalarReader.decimal("quality", in: node), 0 ... 1, field: "quality", node: node)
        },
        execute: { context, services in
            let reference = try WorkflowExecution.inputAsset("input", kind: .image, context: context)
            let output = try await services.transformImage(reference, context: context)
            return .outputs(["output": .asset(output)])
        }
    )

}
