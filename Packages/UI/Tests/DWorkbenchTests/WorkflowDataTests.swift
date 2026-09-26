import Foundation
import Testing
@testable import DWorkbench

struct WorkflowDataTests {
    @Test func typedRoundTripAndIdentity() throws {
        let schema: WorkflowDataSchema = .record([.init("文字", .text), .init("duration", .number(unit: "seconds"))])
        guard case .record(let fields) = schema else { return }
        let value = WorkflowDatum.record(schema: fields, fields: ["文字": .text("你好e\u{301}👨‍👩‍👧‍👦"), "duration": .number(4, unit: "seconds")])
        let list = WorkflowDatum.list(element: schema, items: [.init(id: "stable-1", value: value)])
        try list.validate()
        #expect(try JSONDecoder().decode(WorkflowDatum.self, from: JSONEncoder().encode(list)) == list)
        #expect(try value.value(at: ["文字"]).text == "你好e\u{301}👨‍👩‍👧‍👦")
    }
    @Test func rejectsUnitsMalformedRecordsAndDuplicateItems() {
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.number(25, unit: "frames").validate(as: .number(unit: "seconds")) }
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.number(.infinity, unit: nil).validate() }
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.record(schema: [.init("required", .text)], fields: [:]).validate() }
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.list(element: .text, items: [.init(id: "x", value: .text("a")), .init(id: "x", value: .text("b"))]).validate() }
    }
    @Test func emptyMissingAndFailureRemainDifferent() throws {
        let empty = WorkflowDatum.list(element: .text, items: [])
        let none = WorkflowDatum.none(.list(.text))
        let failure = WorkflowDatum.result(.init(status: .failed, expected: .list(.text), issues: ["unavailable"]))
        try empty.validate(); try none.validate(); try failure.validate()
        #expect(empty != none && none != failure && empty != failure)
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.result(.init(status: .failed, expected: .text, value: .text("bad"))).validate() }
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.result(.init(status: .success, expected: .text)).validate() }
    }
    @Test func predicatesAreTypedAndBounded() throws {
        let value = WorkflowDatum.record(schema: [.init("n", .number(unit: "beats"))], fields: ["n": .number(4, unit: "beats")])
        #expect(try WorkflowDataRule(path: ["n"], comparison: .greater, value: .number(2, unit: "beats")).matches(value))
        #expect(try !WorkflowDataRule(path: ["missing"]).matches(value))
        #expect(throws: WorkflowIssue.self) { try WorkflowDataRule(path: ["n"], comparison: .equals, value: .number(4, unit: "seconds")).matches(value) }
        var nested = WorkflowDatum.text("leaf")
        for _ in 0..<30 { nested = .list(element: nested.schema, items: [.init(value: nested)]) }
        #expect(throws: WorkflowIssue.self) { try nested.validate() }
    }
}
