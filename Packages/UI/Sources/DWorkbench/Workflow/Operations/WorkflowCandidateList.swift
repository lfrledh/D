import Foundation

/// Explicit compatibility bridge from the original G01 collection to the common list language.
/// Full items retain failures, seed strings and attempt identity. `successful` is an explicitly
/// named filtered output; it never implies that missing candidates passed.
enum WorkflowCandidateList {
    static let fields: [WorkflowRecordField] = [
        .init("id", .text), .init("attemptID", .text), .init("seed", .text),
        .init("status", .enumeration(["success", "failed"])),
        .init("asset", .optional(.asset(.image))), .init("error", .optional(.text))
    ]
    static let operation = WorkflowOperation(definition: .init(id: "d.value.candidates", title: "候选转列表",
        detail: "完整记录保留所有候选；成功图片另有明确的筛选输出。不等待人工、不重新生成。",
        inputs: [.init("input", "图像候选", kinds: [.images])],
        outputs: [.init("output", "全部候选记录", kinds: [.list]), .init("successful", "仅成功图片", kinds: [.list])]),
        execute: { context, _ in
            guard case .collection(let candidates)? = context.inputs["input"] else { throw WorkflowIssue("需要图像候选集合。") }
            return .outputs(try convert(candidates))
        })
    static func convert(_ candidates: [WorkflowCandidate]) throws -> [String: WorkflowValue] {
        guard candidates.count <= 8, Set(candidates.map(\.id)).count == candidates.count,
              Set(candidates.map(\.attemptID)).count == candidates.count else { throw WorkflowIssue("候选身份重复或超限。") }
        var all: [WorkflowDataItem] = [], successful: [WorkflowDataItem] = []
        for candidate in candidates {
            guard UInt64(candidate.seed) != nil, candidate.asset?.kind == .image || candidate.asset == nil,
                  (candidate.asset == nil) != (candidate.error == nil) else { throw WorkflowIssue("候选状态、媒体或seed无效。") }
            let id = candidate.id.uuidString
            let record = WorkflowDatum.record(schema: fields, fields: [
                "id": .text(id), "attemptID": .text(candidate.attemptID.uuidString), "seed": .text(candidate.seed),
                "status": .enumeration(candidate.asset == nil ? "failed" : "success", choices: ["success", "failed"]),
                "asset": candidate.asset.map { .asset($0) } ?? .none(.asset(.image)),
                "error": candidate.error.map { .text($0) } ?? .none(.text)
            ])
            try record.validate(); all.append(.init(id: id, value: record))
            if let ref = candidate.asset { successful.append(.init(id: id, value: .asset(ref))) }
        }
        return ["output": .data(.list(element: .record(fields), items: all)), "successful": .data(.list(element: .asset(.image), items: successful))]
    }
}
