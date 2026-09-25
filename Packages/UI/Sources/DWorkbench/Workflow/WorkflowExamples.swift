import Foundation

public enum WorkflowExamples {
    public static func text() -> WorkflowGraph {
        var input = node("d.text.input", title: "原文")
        input.parameters["text"] = .text("Write a short introduction for a local exhibition.")
        let rewrite = node("d.text.rewrite", title: "简洁英文改写")
        let confirm = node("d.text.confirm", title: "确认改写")
        return WorkflowGraph(
            name: "文字改写",
            nodes: [input, rewrite, confirm],
            connections: [connect(input, rewrite), connect(rewrite, confirm)],
            layout: [place(input, 0, 0), place(rewrite, 280, 0), place(confirm, 560, 0)]
        )
    }

    public static func image() -> WorkflowGraph {
        var prompt = node("d.text.input", title: "图像提示")
        prompt.parameters["text"] = .text("A quiet studio filled with morning light")
        let rewrite = node("d.text.rewrite", title: "整理提示")
        let confirm = node("d.text.confirm", title: "确认提示")
        let generate = node("d.image.generate", title: "生成候选")
        let choose = node("d.asset.choose", title: "选择图像")
        let resize = node("d.image.resize", title: "调整尺寸")
        let convert = node("d.image.convert", title: "转换格式")
        let export = node("d.asset.export", title: "导出图像")
        return WorkflowGraph(
            name: "完整图像流程",
            nodes: [prompt, rewrite, confirm, generate, choose, resize, convert, export],
            connections: [
                connect(prompt, rewrite),
                connect(rewrite, confirm),
                connect(confirm, generate, targetPort: "prompt"),
                connect(generate, choose),
                connect(choose, resize),
                connect(resize, convert),
                connect(convert, export),
            ],
            layout: [
                place(prompt, 0, 0), place(rewrite, 260, 0), place(confirm, 520, 0),
                place(generate, 780, 0), place(choose, 1_040, 0), place(resize, 1_300, 0),
                place(convert, 1_560, 0), place(export, 1_820, 0),
            ]
        )
    }

    public static func file() -> WorkflowGraph {
        let reference = node("d.asset.reference", title: "选择图像")
        let resize = node("d.image.resize", title: "调整尺寸")
        let convert = node("d.image.convert", title: "转换格式")
        let export = node("d.asset.export", title: "导出文件")
        return WorkflowGraph(
            name: "图像文件处理",
            nodes: [reference, resize, convert, export],
            connections: [connect(reference, resize), connect(resize, convert), connect(convert, export)],
            layout: [place(reference, 0, 0), place(resize, 280, 0), place(convert, 560, 0), place(export, 840, 0)]
        )
    }

    public static func template() -> WorkflowGraph {
        var input = node("d.text.input", title: "input：主题")
        input.parameters["text"] = .text("a moonlit garden")
        var other = node("d.text.input", title: "other：语气")
        other.parameters["text"] = .text("a restrained editorial tone")
        var template = node("d.text.template", title: "命名模板")
        template.parameters["template"] = .text("Describe {{input}} in {{other}}.")
        let confirm = node("d.text.confirm", title: "确认模板结果")
        return WorkflowGraph(
            name: "双输入文字模板",
            nodes: [input, other, template, confirm],
            connections: [
                connect(input, template, targetPort: "input"),
                connect(other, template, targetPort: "other"),
                connect(template, confirm),
            ],
            layout: [place(input, 0, 0), place(other, 0, 180), place(template, 320, 80), place(confirm, 640, 80)]
        )
    }

    private static func node(_ operationID: String, title: String) -> WorkflowNode {
        guard let definition = WorkflowRegistry.standard.operation(operationID)?.definition else {
            preconditionFailure("缺少内置操作：\(operationID)")
        }
        var value = definition.makeNode()
        value.title = title
        return value
    }

    private static func connect(
        _ source: WorkflowNode,
        _ target: WorkflowNode,
        targetPort: String = "input"
    ) -> WorkflowConnection {
        WorkflowConnection(sourceNode: source.id, targetNode: target.id, targetPort: targetPort)
    }

    private static func place(_ node: WorkflowNode, _ x: Double, _ y: Double) -> WorkflowLayout {
        WorkflowLayout(nodeID: node.id, x: x, y: y)
    }
}
