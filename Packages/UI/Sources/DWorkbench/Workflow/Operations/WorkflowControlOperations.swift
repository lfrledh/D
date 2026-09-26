import Foundation

enum WorkflowControlOperations {
    static let operations: [WorkflowOperation] = [
        control("branch", "条件选择", "只执行命中的分支。", input: WorkflowDataKind.allCases),
        control("map", "逐项执行", "逐项调用内部流程，保留每项身份。", input: [.list]),
        control("loop", "重复到满足条件", "有限状态循环，逐轮保存。", input: WorkflowDataKind.allCases),
        control("invoke", "使用自定义工具", "调用固定版本的工具；可展开内部流程。", input: WorkflowDataKind.allCases),
        WorkflowOperation(definition: .init(id: "d.control.human", title: "等待用户处理", detail: "可选人工任务，不会自动批准。",
            inputs: [.init("input", "材料", kinds: WorkflowDataKind.allCases)],
            outputs: [.init("output", "决定", kinds: WorkflowDataKind.allCases)], fields: [
                .init("kind", "处理方式", .choice(WorkflowHumanTaskKind.allCases.map(\.rawValue)), .text("editText")),
                .init("instruction", "需要处理什么", .text(multiline: true), .text("请检查并提交。"))]), execute: { context, _ in
                    guard let input = context.inputs["input"]?.datum,
                          let kind = WorkflowHumanTaskKind(rawValue: context.node.parameters["kind"]?.string ?? "") else { throw WorkflowIssue("人工任务材料或类型缺失。") }
                    try input.validate()
                    return .humanTask(.init(id: context.stepID, kind: kind,
                        title: context.node.parameters["instruction"]?.string ?? context.node.title,
                        materials: input, resultSchema: context.node.dataConfiguration?.schema ?? input.schema))
                })
    ]
    private static func control(_ suffix: String, _ title: String, _ detail: String, input: [WorkflowDataKind]) -> WorkflowOperation {
        .init(definition: .init(id: "d.control." + suffix, title: title, detail: detail,
            inputs: [.init("input", "输入", kinds: input), .init("shared", "共享字段", kinds: [.record], required: false)],
            outputs: [.init("output", "结果", kinds: WorkflowDataKind.allCases), .init("exitReason", "退出原因", kinds: [.enumeration])]),
              execute: { context, _ in throw WorkflowIssue("控制节点必须通过结构化计划执行。", nodeID: context.node.id) })
    }
}
