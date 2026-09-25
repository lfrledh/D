import Foundation

enum WorkflowBuiltins {
    static let operations: [WorkflowOperation] = [
        textInput, assetReference, textTemplate, textRewrite, imageGenerate,
        textConfirm, assetChoose, imageResize, imageConvert, assetExport,
        WorkflowRemoveBlankLines.operation,
    ]

    private static let textInput = WorkflowOperation(
        definition: .init(
            id: "d.text.input", title: "文字输入", detail: "提供可编辑文字。", inputs: [],
            outputs: [.init("output", "文字", kinds: [.text])],
            fields: [.init("text", "文字", .text(multiline: true), .text(""))]
        ),
        execute: { context, services in
            let text = try Scalar.text("text", in: context.node)
            try Execution.ensureTextLimit(text, node: context.node, port: nil)
            let asset = try await services.publishText(text, parents: [], context: context)
            return .outputs(["output": .asset(asset)])
        }
    )

    private static let assetReference = WorkflowOperation(
        definition: .init(
            id: "d.asset.reference", title: "项目素材", detail: "引用已发布且不可变的项目素材。", inputs: [],
            outputs: [.init("output", "素材", kinds: [.text, .image])]
        ),
        execute: { context, services in
            guard let reference = context.node.assetReference else {
                throw WorkflowIssue("尚未选择项目素材。", nodeID: context.node.id)
            }
            guard reference.kind == .text || reference.kind == .image else {
                throw WorkflowIssue("该素材类型不能作为普通素材引用。", nodeID: context.node.id)
            }
            try await services.verifyAsset(reference)
            return .outputs(["output": .asset(reference)])
        }
    )

    private static let textTemplate = WorkflowOperation(
        definition: .init(
            id: "d.text.template", title: "文字模板", detail: "仅替换命名变量，不执行脚本。",
            inputs: [
                .init("input", "主要文字", kinds: [.text], required: false),
                .init("other", "辅助文字", kinds: [.text], required: false),
            ],
            outputs: [.init("output", "文字", kinds: [.text])],
            fields: [
                .init("template", "模板", .text(multiline: true), .text("{{input}}")),
                .init("inputText", "主要文字后备", .text(multiline: true), .text("")),
                .init("otherText", "辅助文字后备", .text(multiline: true), .text("")),
            ]
        ),
        validate: { node in try Template.validate(Scalar.text("template", in: node), nodeID: node.id) },
        execute: { context, services in
            let template = try Scalar.text("template", in: context.node)
            try Template.validate(template, nodeID: context.node.id)
            var parents: [WorkflowAssetReference] = []
            var input: (text: String, parent: WorkflowAssetReference?)?
            var other: (text: String, parent: WorkflowAssetReference?)?
            if template.contains("{{input}}") {
                input = try await Template.value(port: "input", fallback: "inputText", context: context, services: services)
                if let parent = input?.parent { parents.append(parent) }
            }
            if template.contains("{{other}}") {
                other = try await Template.value(port: "other", fallback: "otherText", context: context, services: services)
                if let parent = other?.parent { parents.append(parent) }
            }
            let result = try Template.render(template, input: input?.text, other: other?.text, nodeID: context.node.id)
            try Execution.ensureTextLimit(result, node: context.node, port: nil)
            let asset = try await services.publishText(result, parents: parents, context: context)
            return .outputs(["output": .asset(asset)])
        }
    )

    private static let textRewrite = WorkflowOperation(
        definition: .init(
            id: "d.text.rewrite", title: "文字改写", detail: "使用明确绑定的已登记文字模型改写。",
            inputs: [.init("input", "文字", kinds: [.text], required: false)],
            outputs: [.init("output", "改写文字", kinds: [.text])],
            fields: [
                .init("fallbackText", "后备文字", .text(multiline: true), .text("")),
                .init("instruction", "指令", .text(multiline: true), .text("Rewrite the text concisely in English.")),
                .init("maximumOutputTokens", "最大输出 token", .integer, .integer(128)),
                .init("maximumPromptTokens", "最大提示 token", .integer, .integer(2_048)),
                .init("temperature", "温度", .decimal, .decimal(0.7)),
                .init("topP", "Top P", .decimal, .decimal(0.95)),
                .init("modelID", "模型内容身份", .text(multiline: false), .text("")),
            ]
        ),
        validate: { node in
            try Limits.positive(Scalar.integer("maximumOutputTokens", in: node), field: "maximumOutputTokens", node: node)
            try Limits.positive(Scalar.integer("maximumPromptTokens", in: node), field: "maximumPromptTokens", node: node)
            try Limits.range(Scalar.decimal("temperature", in: node), 0 ... 2, field: "temperature", node: node)
            try Limits.positiveUnit(Scalar.decimal("topP", in: node), field: "topP", node: node)
        },
        execute: { context, services in
            try Execution.requireModel(in: context.node)
            let parents: [WorkflowAssetReference]
            let text: String
            if let input = context.inputs["input"] {
                let reference = try Execution.asset(input, kind: .text, port: "input", node: context.node)
                text = try await services.readText(reference)
                parents = [reference]
            } else {
                text = try Scalar.text("fallbackText", in: context.node)
                parents = []
            }
            guard !text.isEmpty else { throw WorkflowIssue("改写文字不能为空。", nodeID: context.node.id, port: "input") }
            try Execution.ensureTextLimit(text, node: context.node, port: "input")
            let output = try await services.rewriteText(text, parents: parents, context: context)
            return .outputs(["output": .asset(output)])
        }
    )

    private static let imageGenerate = WorkflowOperation(
        definition: .init(
            id: "d.image.generate", title: "图像生成", detail: "生成相互独立且保留身份的候选。",
            inputs: [
                .init("prompt", "提示文字", kinds: [.text], required: false),
                .init("ref", "参考图像", kinds: [.image], required: false),
            ],
            outputs: [.init("output", "候选图像", kinds: [.images])],
            fields: [
                .init("promptText", "后备提示", .text(multiline: true), .text("")),
                .init("width", "宽度", .integer, .integer(512)),
                .init("height", "高度", .integer, .integer(512)),
                .init("steps", "步数", .integer, .integer(4)),
                .init("guidance", "引导", .decimal, .decimal(1)),
                .init("seed", "种子", .text(multiline: false), .text("42")),
                .init("count", "候选数", .integer, .integer(3)),
                .init("modelID", "模型内容身份", .text(multiline: false), .text("")),
            ]
        ),
        validate: { node in
            try Limits.positive(Scalar.integer("width", in: node), field: "width", node: node)
            try Limits.positive(Scalar.integer("height", in: node), field: "height", node: node)
            try Limits.positive(Scalar.integer("steps", in: node), field: "steps", node: node)
            try Limits.nonnegative(Scalar.decimal("guidance", in: node), field: "guidance", node: node)
            let seed = try Scalar.text("seed", in: node)
            guard !seed.isEmpty, seed.utf8.allSatisfy({ (48 ... 57).contains($0) }), UInt64(seed) != nil else {
                throw WorkflowIssue("seed 必须是 UInt64 十进制字符串。", nodeID: node.id)
            }
            let count = try Scalar.integer("count", in: node)
            guard (1 ... 8).contains(count) else { throw WorkflowIssue("count 必须为 1...8。", nodeID: node.id) }
        },
        execute: { context, services in
            try Execution.requireModel(in: context.node)
            let prompt: String
            if let input = context.inputs["prompt"] {
                let reference = try Execution.asset(input, kind: .text, port: "prompt", node: context.node)
                prompt = try await services.readText(reference)
            } else {
                prompt = try Scalar.text("promptText", in: context.node)
            }
            guard !prompt.isEmpty else { throw WorkflowIssue("生成提示不能为空。", nodeID: context.node.id, port: "prompt") }
            try Execution.ensureTextLimit(prompt, node: context.node, port: "prompt")
            let reference = try context.inputs["ref"].map {
                try Execution.asset($0, kind: .image, port: "ref", node: context.node)
            }
            let candidates = try await services.generateImages(prompt: prompt, reference: reference, context: context)
            let expectedCount = try Scalar.integer("count", in: context.node)
            guard candidates.count == expectedCount,
                  Set(candidates.map(\.id)).count == candidates.count,
                  Set(candidates.map(\.attemptID)).count == candidates.count else {
                throw WorkflowIssue("生成服务必须返回指定数量且身份独立的全部候选。", nodeID: context.node.id)
            }
            return .outputs(["output": .collection(candidates)])
        }
    )

    private static let textConfirm = WorkflowOperation(
        definition: .init(
            id: "d.text.confirm", title: "确认文字", detail: "等待用户确认文字候选。",
            inputs: [.init("input", "文字", kinds: [.text])],
            outputs: [.init("output", "文字", kinds: [.text])]
        ),
        execute: { context, _ in
            let reference = try Execution.inputAsset("input", kind: .text, context: context)
            return .reviewText(reference)
        }
    )

    private static let assetChoose = WorkflowOperation(
        definition: .init(
            id: "d.asset.choose", title: "选择候选", detail: "等待用户从全部候选中选择。",
            inputs: [.init("input", "候选", kinds: [.images])],
            outputs: [.init("output", "图像", kinds: [.image])]
        ),
        execute: { context, _ in
            guard case .collection(let candidates)? = context.inputs["input"] else {
                throw WorkflowIssue("候选集合尚未就绪。", nodeID: context.node.id, port: "input")
            }
            return .choose(candidates)
        }
    )

    private static let imageResize = WorkflowOperation(
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
            let width = try Scalar.integer("width", in: node), height = try Scalar.integer("height", in: node)
            guard (1 ... 8_192).contains(width), (1 ... 8_192).contains(height),
                  width <= 32 * 1_024 * 1_024 / height else {
                throw WorkflowIssue("尺寸必须为 1...8192，且总像素不超过 32 Mi。", nodeID: node.id)
            }
        },
        execute: { context, services in
            let reference = try Execution.inputAsset("input", kind: .image, context: context)
            let output = try await services.transformImage(reference, context: context)
            return .outputs(["output": .asset(output)])
        }
    )

    private static let imageConvert = WorkflowOperation(
        definition: .init(
            id: "d.image.convert", title: "转换图像", detail: "显式选择编码及背景。",
            inputs: [.init("input", "图像", kinds: [.image])],
            outputs: [.init("output", "图像", kinds: [.image])],
            fields: [
                .init("format", "格式", .choice(["png", "jpeg"]), .text("png")),
                .init("quality", "质量", .decimal, .decimal(0.9)),
                .init("background", "背景", .choice(["white", "black"]), .text("white")),
            ]
        ),
        validate: { node in
            try Limits.range(Scalar.decimal("quality", in: node), 0 ... 1, field: "quality", node: node)
        },
        execute: { context, services in
            let reference = try Execution.inputAsset("input", kind: .image, context: context)
            let output = try await services.transformImage(reference, context: context)
            return .outputs(["output": .asset(output)])
        }
    )

    private static let assetExport = WorkflowOperation(
        definition: .init(
            id: "d.asset.export", title: "导出", detail: "媒体与来源清单打包；默认不覆盖、不公开提示词。完整配方仍在项目中可查。",
            inputs: [.init("input", "内容", kinds: [.text, .image, .images])],
            outputs: [.init("output", "回执", kinds: [.receipt])],
            fields: [.init("fileName", "文件名", .text(multiline: false), .text("export"))]
        ),
        validate: { node in
            let name = try Scalar.text("fileName", in: node)
            guard !name.isEmpty, name != ".", !name.contains(".."),
                  !name.contains("/"), !name.contains("\\"),
                  !name.contains("\n"), !name.contains("\r"), !name.contains("\u{0}") else {
                throw WorkflowIssue("fileName 必须是单一文件名，不能包含目录或 ..。", nodeID: node.id)
            }
        },
        execute: { context, services in
            guard let value = context.inputs["input"], [.text, .image, .images].contains(value.kind) else {
                throw WorkflowIssue("导出输入尚未就绪或类型不符。", nodeID: context.node.id, port: "input")
            }
            let receipt = try await services.export(value, context: context)
            return .outputs(["output": .receipt(receipt)])
        }
    )
}

private enum Scalar {
    static func text(_ field: String, in node: WorkflowNode) throws -> String {
        guard case .text(let value)? = node.parameters[field] else {
            throw WorkflowIssue("字段 \(field) 必须是文字。", nodeID: node.id)
        }
        return value
    }

    static func integer(_ field: String, in node: WorkflowNode) throws -> Int {
        guard case .integer(let value)? = node.parameters[field] else {
            throw WorkflowIssue("字段 \(field) 必须是整数。", nodeID: node.id)
        }
        return value
    }

    static func decimal(_ field: String, in node: WorkflowNode) throws -> Double {
        guard case .decimal(let value)? = node.parameters[field], value.isFinite else {
            throw WorkflowIssue("字段 \(field) 必须是有限小数。", nodeID: node.id)
        }
        return value
    }
}

private enum Limits {
    static func positive(_ value: Int, field: String, node: WorkflowNode) throws {
        guard value > 0 else { throw WorkflowIssue("字段 \(field) 必须大于零。", nodeID: node.id) }
    }

    static func range(_ value: Double, _ range: ClosedRange<Double>, field: String, node: WorkflowNode) throws {
        guard range.contains(value) else {
            throw WorkflowIssue("字段 \(field) 超出范围 \(range.lowerBound)...\(range.upperBound)。", nodeID: node.id)
        }
    }

    static func nonnegative(_ value: Double, field: String, node: WorkflowNode) throws {
        guard value >= 0 else { throw WorkflowIssue("字段 \(field) 不能为负数。", nodeID: node.id) }
    }

    static func positiveUnit(_ value: Double, field: String, node: WorkflowNode) throws {
        guard value > 0, value <= 1 else {
            throw WorkflowIssue("字段 \(field) 必须大于零且不超过 1。", nodeID: node.id)
        }
    }
}

private enum Template {
    static func validate(_ template: String, nodeID: UUID) throws {
        let remainder = template
            .replacingOccurrences(of: "{{input}}", with: "")
            .replacingOccurrences(of: "{{other}}", with: "")
        guard !remainder.contains("{{"), !remainder.contains("}}") else {
            throw WorkflowIssue("模板只允许 {{input}} 和 {{other}}，且不会执行脚本。", nodeID: nodeID)
        }
    }

    static func render(_ template: String, input: String?, other: String?, nodeID: UUID) throws -> String {
        var remainder = template[...]
        var result = ""
        while !remainder.isEmpty {
            let inputRange = remainder.range(of: "{{input}}")
            let otherRange = remainder.range(of: "{{other}}")
            let selection: (range: Range<String.Index>, value: String?)?
            switch (inputRange, otherRange) {
            case (.some(let left), .some(let right)):
                selection = left.lowerBound < right.lowerBound ? (left, input) : (right, other)
            case (.some(let range), .none): selection = (range, input)
            case (.none, .some(let range)): selection = (range, other)
            case (.none, .none): selection = nil
            }
            guard let selection else {
                result.append(contentsOf: remainder)
                break
            }
            result.append(contentsOf: remainder[..<selection.range.lowerBound])
            guard let value = selection.value else {
                throw WorkflowIssue("模板引用的变量缺少值。", nodeID: nodeID)
            }
            result.append(value)
            remainder = remainder[selection.range.upperBound...]
        }
        return result
    }

    @MainActor static func value(
        port: String,
        fallback: String,
        context: WorkflowExecutionContext,
        services: any WorkflowOperationServices
    ) async throws -> (text: String, parent: WorkflowAssetReference?) {
        if let input = context.inputs[port] {
            let reference = try Execution.asset(input, kind: .text, port: port, node: context.node)
            let text = try await services.readText(reference)
            try Execution.ensureTextLimit(text, node: context.node, port: port)
            return (text, reference)
        }
        let text = try Scalar.text(fallback, in: context.node)
        guard !text.isEmpty else {
            throw WorkflowIssue("模板引用的变量缺少值。", nodeID: context.node.id, port: port)
        }
        try Execution.ensureTextLimit(text, node: context.node, port: port)
        return (text, nil)
    }
}

private enum Execution {
    private static let maximumTextBytes = 1_048_576

    static func requireModel(in node: WorkflowNode) throws {
        let modelID = try Scalar.text("modelID", in: node)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowIssue("执行前必须绑定已登记模型的内容身份。", nodeID: node.id)
        }
    }

    static func ensureTextLimit(_ text: String, node: WorkflowNode, port: String?) throws {
        guard text.utf8.count <= maximumTextBytes else {
            throw WorkflowIssue("输入文字超过 \(maximumTextBytes) 字节。", nodeID: node.id, port: port)
        }
    }

    static func inputAsset(_ port: String, kind: WorkflowDataKind, context: WorkflowExecutionContext) throws -> WorkflowAssetReference {
        guard let value = context.inputs[port] else {
            throw WorkflowIssue("输入尚未就绪。", nodeID: context.node.id, port: port)
        }
        return try asset(value, kind: kind, port: port, node: context.node)
    }

    static func asset(_ value: WorkflowValue, kind: WorkflowDataKind, port: String, node: WorkflowNode) throws -> WorkflowAssetReference {
        guard case .asset(let reference) = value, reference.kind == kind else {
            throw WorkflowIssue("输入实际类型不符。", nodeID: node.id, port: port)
        }
        return reference
    }
}
