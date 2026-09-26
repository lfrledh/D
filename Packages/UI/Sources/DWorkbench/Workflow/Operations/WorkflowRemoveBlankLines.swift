import Foundation

/// S3 extension: one module and one static registration; no controller or storage dispatch branch.
enum WorkflowRemoveBlankLines {
    static let operation = WorkflowOperation(definition: .init(
        id: "d.text.remove-blank-lines", title: "移除空行", detail: "保留非空行的文字，统一换行为 LF；发布新资产，不改原件。",
        inputs: [.init("input", "文字", kinds: [.text])], outputs: [.init("output", "文字", kinds: [.text])]),
        execute: { context, services in
            guard let input = context.inputs["input"]?.asset, input.kind == .text else {
                throw WorkflowIssue("需要文字输入。", nodeID: context.node.id, port: "input")
            }
            let text = try await services.readText(input)
            let result = text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
            return .outputs(["output": .asset(try await services.publishText(result, parents: [input], context: context))])
        })
}
