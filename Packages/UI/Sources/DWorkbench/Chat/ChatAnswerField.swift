import Foundation

/// A field choice freezes the adopted answer, not the current model form or an
/// old validation report. Paths are arrays, so literal dots in keys stay literal.
public struct ChatAnswerField: Sendable, Equatable {
    public let sessionID: UUID
    public let messageID: UUID
    public let answer: ChatSelectedAnswer
    public let path: [String]
    public let value: WorkflowDatum

    public init(session: ChatSession, messageID: UUID, path: [String]) throws {
        guard path.count <= 24, let answer = session.selectedAnswer(messageID: messageID),
              let format = answer.attempt?.outputFormat else { throw WorkflowIssue("此回答没有已保存的结构定义；请使用文字/选段交接。") }
        let report = format.check(answer.text)
        guard report.status == .valid, let datum = report.datum else {
            throw WorkflowIssue(report.reason ?? "此回答尚未通过有类型的结构校验；原文仍可保存。")
        }
        let value = try datum.value(at: path); try value.validate()
        self.sessionID = session.id; self.messageID = messageID
        self.answer = answer; self.path = path; self.value = value
    }
    public func validateCurrent(_ session: ChatSession) throws {
        guard session.id == sessionID, session.selectedAnswer(messageID: messageID) == answer else {
            throw WorkflowIssue("采用的回答版本已改变；请重新选择字段，旧资产不变。")
        }
    }
    public static func choices(session: ChatSession, messageID: UUID) throws -> [ChatAnswerField] {
        let root = try Self(session: session, messageID: messageID, path: [])
        var paths: [[String]] = [[]]
        func visit(_ value: WorkflowDatum, path: [String]) throws {
            guard case .record(_, let fields) = value else { return }
            for key in fields.keys.sorted() {
                guard paths.count < 1024 else { throw WorkflowIssue("字段过多，请保存整个结构或在工作流提取字段。") }
                let next = path + [key]; paths.append(next)
                try visit(fields[key]!, path: next)
            }
        }
        try visit(root.value, path: [])
        // Reuse the once-validated root; no reparsing a large answer per field.
        return try paths.map { path in
            Self(sessionID: session.id, messageID: messageID, answer: root.answer,
                 path: path, value: try root.value.value(at: path))
        }
    }
    private init(sessionID: UUID, messageID: UUID, answer: ChatSelectedAnswer, path: [String], value: WorkflowDatum) {
        self.sessionID = sessionID; self.messageID = messageID; self.answer = answer; self.path = path; self.value = value
    }
    /// Existing d.value.input stores this explicit envelope. d.value.field can
    /// select "value"; "source" retains the exact published field version.
    public func envelope(source: WorkflowAssetReference) throws -> WorkflowDatum {
        let value = WorkflowDatum.record(schema: [.init("value", value.schema), .init("source", .asset(.text)),
            .init("path", .list(.text))], fields: ["value": value, "source": .asset(source),
            "path": .list(element: .text, items: path.enumerated().map { .init(id: String($0.offset), value: .text($0.element)) })])
        try value.validate(); return value
    }
}
