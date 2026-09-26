import Foundation

/// Concrete operations; shared scheduling, assets and persistence remain outside this module.
enum WorkflowAssetOperations {
    static let assetReference = WorkflowOperation(
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

    static let assetChoose = WorkflowOperation(
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

    static let assetExport = WorkflowOperation(
        definition: .init(
            id: "d.asset.export", title: "导出", detail: "媒体与来源清单打包；默认不覆盖、不公开提示词。完整配方仍在项目中可查。",
            inputs: [.init("input", "内容", kinds: [.text, .image, .images])],
            outputs: [.init("output", "回执", kinds: [.receipt])],
            fields: [.init("fileName", "文件名", .text(multiline: false), .text("export"))]
        ),
        validate: { node in
            let name = try WorkflowScalarReader.text("fileName", in: node)
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
    )}
