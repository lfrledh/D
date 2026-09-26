import Foundation

/// Concrete operations; shared scheduling, assets and persistence remain outside this module.
enum WorkflowTextOperations {
    static let textInput = WorkflowOperation(
        definition: .init(
            id: "d.text.input", title: "文字输入", detail: "提供可编辑文字。", inputs: [],
            outputs: [.init("output", "文字", kinds: [.text])],
            fields: [.init("text", "文字", .text(multiline: true), .text(""))]
        ),
        execute: { context, services in
            let text = try WorkflowScalarReader.text("text", in: context.node)
            try WorkflowExecution.ensureTextLimit(text, node: context.node, port: nil)
            let asset = try await services.publishText(text, parents: [], context: context)
            return .outputs(["output": .asset(asset)])
        }
    )

    static let textTemplate = WorkflowOperation(
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
        validate: { node in try WorkflowTemplate.validate(WorkflowScalarReader.text("template", in: node), nodeID: node.id) },
        execute: { context, services in
            let template = try WorkflowScalarReader.text("template", in: context.node)
            try WorkflowTemplate.validate(template, nodeID: context.node.id)
            var parents: [WorkflowAssetReference] = []
            var input: (text: String, parent: WorkflowAssetReference?)?
            var other: (text: String, parent: WorkflowAssetReference?)?
            if template.contains("{{input}}") {
                input = try await WorkflowTemplate.value(port: "input", fallback: "inputText", context: context, services: services)
                if let parent = input?.parent { parents.append(parent) }
            }
            if template.contains("{{other}}") {
                other = try await WorkflowTemplate.value(port: "other", fallback: "otherText", context: context, services: services)
                if let parent = other?.parent { parents.append(parent) }
            }
            let result = try WorkflowTemplate.render(template, input: input?.text, other: other?.text, nodeID: context.node.id)
            try WorkflowExecution.ensureTextLimit(result, node: context.node, port: nil)
            let asset = try await services.publishText(result, parents: parents, context: context)
            return .outputs(["output": .asset(asset)])
        }
    )

    static let textRewrite = WorkflowOperation(
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
            ], modelKind: .text
        ),
        validate: { node in
            try WorkflowLimits.positive(WorkflowScalarReader.integer("maximumOutputTokens", in: node), field: "maximumOutputTokens", node: node)
            try WorkflowLimits.positive(WorkflowScalarReader.integer("maximumPromptTokens", in: node), field: "maximumPromptTokens", node: node)
            try WorkflowLimits.range(WorkflowScalarReader.decimal("temperature", in: node), 0 ... 2, field: "temperature", node: node)
            try WorkflowLimits.positiveUnit(WorkflowScalarReader.decimal("topP", in: node), field: "topP", node: node)
        },
        execute: { context, services in
            try WorkflowExecution.requireModel(in: context.node)
            let parents: [WorkflowAssetReference]
            let text: String
            if let input = context.inputs["input"] {
                let reference = try WorkflowExecution.asset(input, kind: .text, port: "input", node: context.node)
                text = try await services.readText(reference)
                parents = [reference]
            } else {
                text = try WorkflowScalarReader.text("fallbackText", in: context.node)
                parents = []
            }
            guard !text.isEmpty else { throw WorkflowIssue("改写文字不能为空。", nodeID: context.node.id, port: "input") }
            try WorkflowExecution.ensureTextLimit(text, node: context.node, port: "input")
            let output = try await services.rewriteText(text, parents: parents, context: context)
            return .outputs(["output": .asset(output)])
        }
    )

    static let textConfirm = WorkflowOperation(
        definition: .init(
            id: "d.text.confirm", title: "确认文字", detail: "等待用户确认文字候选。",
            inputs: [.init("input", "文字", kinds: [.text])],
            outputs: [.init("output", "文字", kinds: [.text])]
        ),
        execute: { context, _ in
            let reference = try WorkflowExecution.inputAsset("input", kind: .text, context: context)
            return .reviewText(reference)
        }
    )

}
