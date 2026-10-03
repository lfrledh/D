import XCTest
@testable import DWorkbench

final class ChatOutputFormatTests: XCTestCase {
    func testAutomaticAndUnverifiedPresentationRequests() throws {
        let automatic = ChatOutputFormat()
        XCTAssertEqual(automatic.kind, .automatic)
        XCTAssertNil(automatic.promptInstruction)
        XCTAssertNoThrow(try automatic.validate())
        XCTAssertEqual(automatic.check("anything"), .init(status: .notChecked))

        let plain = ChatOutputFormat(kind: .plainText)
        let markdown = ChatOutputFormat(kind: .markdown)
        XCTAssertEqual(plain.promptInstruction, "Respond in plain text.")
        XCTAssertEqual(markdown.promptInstruction, "Respond in Markdown.")
        XCTAssertEqual(plain.check("```json\n{}\n```"), .init(status: .notChecked))
        XCTAssertEqual(markdown.check("unclosed **markup"), .init(status: .notChecked))

        let roundTrip = try JSONDecoder().decode(ChatOutputFormat.self, from: JSONEncoder().encode(automatic))
        XCTAssertEqual(roundTrip, automatic)
    }

    func testJSONChecksEntireUnicodeValueWithoutChangingSource() throws {
        let format = ChatOutputFormat(kind: .json)
        try format.validate()
        XCTAssertNotNil(format.promptInstruction)
        let source = #"{"作品":"🎨","enabled":true,"count":2,"items":[null,"α"]}"#
        let original = source
        let report = format.check(source)
        XCTAssertEqual(source, original)
        XCTAssertEqual(report, .init(status: .valid))
        XCTAssertNil(report.datum)
        XCTAssertEqual(try JSONDecoder().decode(ChatOutputFormat.Report.self, from: JSONEncoder().encode(report)), report)
        XCTAssertEqual(format.check("true").status, .valid)
        XCTAssertEqual(format.check("12.5").status, .valid)
    }

    func testJSONRejectsFencesTrailingContentDuplicateKeysAndInvalidLiterals() {
        let format = ChatOutputFormat(kind: .json)
        assertInvalid(format, "```json\n{}\n```", containing: "JSON")
        assertInvalid(format, "{} trailing", containing: "Trailing")
        assertInvalid(format, #"{"a":1,"a":2}"#, containing: "Duplicate")
        assertInvalid(format, #"{"a":1,"\u0061":2}"#, containing: "Duplicate")
        assertInvalid(format, "NaN", containing: "JSON")
        assertInvalid(format, "1e400", containing: "finite Double")
        assertInvalid(format, #""\uD800""#, containing: "surrogate")
        assertInvalid(format, "\"\u{0001}\"", containing: "control character")
        assertInvalid(format, "[1,]", containing: "Trailing commas")
        assertInvalid(format, "\"" + String(repeating: "a", count: 1_048_576) + "\"", containing: "1 MiB")
    }

    func testSchemaPromptContainsExactDeclaredDataAndChecksTypes() throws {
        let fields: [WorkflowRecordField] = [
            .init("title", .text),
            .init("enabled", .boolean),
            .init("score", .number(unit: "点")),
            .init("tags", .list(.text)),
            .init("note", .optional(.text), required: false),
        ]
        let schema: WorkflowDataSchema = .record(fields)
        let format = ChatOutputFormat(kind: .schema, schema: schema)
        try format.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let declaration = String(decoding: try encoder.encode(schema), as: UTF8.self)
        let instruction = try XCTUnwrap(format.promptInstruction)
        XCTAssertTrue(instruction.contains(declaration))
        XCTAssertTrue(instruction.contains("D WorkflowDataSchema"))
        XCTAssertFalse(instruction.contains("constrained decoding"))

        let source = #"{"title":"作品🎨","enabled":true,"score":2,"tags":["α","β"],"note":null}"#
        let original = source
        let report = format.check(source)
        XCTAssertEqual(source, original)
        XCTAssertEqual(report.status, .valid)
        XCTAssertNil(report.reason)
        guard case .record(let declared, let values)? = report.datum else {
            return XCTFail("Expected structured record datum")
        }
        XCTAssertEqual(declared, fields)
        XCTAssertEqual(values["title"], .text("作品🎨"))
        XCTAssertEqual(values["enabled"], .boolean(true))
        XCTAssertEqual(values["score"], .number(2, unit: "点"))
        XCTAssertEqual(values["note"], .none(.text))
        XCTAssertEqual(values["tags"]?.items?.map(\.value), [.text("α"), .text("β")])
        XCTAssertEqual(try JSONDecoder().decode(ChatOutputFormat.Report.self, from: JSONEncoder().encode(report)), report)

        XCTAssertEqual(format.check(#"{"title":"作品","enabled":true,"score":2,"tags":[]}"#).status, .valid)
        assertInvalid(format, #"{"enabled":true,"score":2,"tags":[]}"#, containing: "title")
        assertInvalid(format, #"{"title":"x","enabled":true,"score":2,"tags":[],"extra":1}"#, containing: "extra")
        assertInvalid(format, #"{"title":"x","enabled":1,"score":2,"tags":[]}"#, containing: "enabled")
        assertInvalid(format, #"{"title":"x","enabled":true,"score":false,"tags":[]}"#, containing: "score")
        assertInvalid(format, #"{"title":"x","enabled":true,"score":2,"tags":[1]}"#, containing: "tags")
        assertInvalid(format, #"{"title":"x","enabled":true,"score":2,"tags":[],"note":12}"#, containing: "note")
    }

    func testPreflightRejectsMissingExtraAndIllegalSchemas() {
        let missing = ChatOutputFormat(kind: .schema)
        XCTAssertThrowsError(try missing.validate())
        XCTAssertNil(missing.promptInstruction)
        XCTAssertEqual(missing.check("{} ").status, .invalid)

        for kind in [ChatOutputFormat.Kind.automatic, .plainText, .markdown, .json] {
            let extra = ChatOutputFormat(kind: kind, schema: .text)
            XCTAssertThrowsError(try extra.validate())
            XCTAssertNil(extra.promptInstruction)
            XCTAssertEqual(extra.check("{} ").status, .invalid)
        }

        let illegal: [WorkflowDataSchema] = [
            .record([.init("same", .text), .init("same", .boolean)]),
            .enumeration([]),
            .list(.asset(.image)),
            .record([.init("outcome", .optional(.result(.text)), required: false)]),
        ]
        for schema in illegal {
            let format = ChatOutputFormat(kind: .schema, schema: schema)
            XCTAssertThrowsError(try format.validate())
            XCTAssertNil(format.promptInstruction)
            XCTAssertEqual(format.check("{} ").status, .invalid)
        }
    }

    func testSchemaDeclarationRejectsAggregateSizeBeforeFullEncoding() {
        let choices = (0..<32).map { "choice\($0)-" + String(repeating: "a", count: 48) }
        let fields = (0..<64).map { WorkflowRecordField("field\($0)", .enumeration(choices)) }
        XCTAssertLessThanOrEqual(fields.count, 256)
        XCTAssertTrue(choices.allSatisfy { $0.utf8.count <= 1_024 })
        assertOversizedSchema(.record(fields))
    }

    func testSchemaDeclarationCountsEscapedBytes() {
        let choices = (0..<256).map { "c\($0)" + String(repeating: "\"", count: 150) }
        XCTAssertLessThan(choices.reduce(0) { $0 + $1.utf8.count }, 65_536)
        assertOversizedSchema(.enumeration(choices))
    }

    func testSchemaDeclarationBoundaryIsAcceptedWithoutTruncation() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let baseChoices = (0..<255).map { String(format: "%03d", $0) + String(repeating: "a", count: 250) }
        let baseSchema: WorkflowDataSchema = .enumeration(baseChoices + ["z"])
        let remaining = 65_536 - (try encoder.encode(baseSchema).count)
        guard remaining > 0, remaining < 1_024 else {
            return XCTFail("Boundary fixture must leave room for one legal choice.")
        }
        let finalChoice = "z" + String(repeating: "q", count: remaining)
        XCTAssertLessThanOrEqual(finalChoice.utf8.count, 1_024)
        let schema: WorkflowDataSchema = .enumeration(baseChoices + [finalChoice])
        XCTAssertEqual(try encoder.encode(schema).count, 65_536)

        let format = ChatOutputFormat(kind: .schema, schema: schema)
        try format.validate()
        let instruction = try XCTUnwrap(format.promptInstruction)
        XCTAssertTrue(instruction.contains(finalChoice))
        XCTAssertLessThan(instruction.utf8.count, 66_000)
        XCTAssertEqual(format.check("\"\(finalChoice)\"").status, .valid)

        let overLimit: WorkflowDataSchema = .enumeration(baseChoices + [finalChoice + "q"])
        assertOversizedSchema(overLimit)
    }

    func testSchemaDeclarationBoundaryWithNilUnitNumbers() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let numberFields = (0..<32).map { WorkflowRecordField("nilUnit\($0)", .number(unit: nil)) }
        let baseChoices = (0..<248).map { String(format: "%03d", $0) + String(repeating: "a", count: 250) }
        let baseSchema: WorkflowDataSchema = .record(numberFields + [
            .init("choice", .enumeration(baseChoices + ["z"])),
        ])
        let remaining = 65_536 - (try encoder.encode(baseSchema).count)
        guard remaining > 0, remaining < 1_024 else {
            return XCTFail("Nil-unit boundary fixture must leave room for one legal choice.")
        }
        let finalChoice = "z" + String(repeating: "q", count: remaining)
        let schema: WorkflowDataSchema = .record(numberFields + [
            .init("choice", .enumeration(baseChoices + [finalChoice])),
        ])
        let encoded = try encoder.encode(schema)
        XCTAssertEqual(encoded.count, 65_536)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#"{"number":{}}"#))

        let format = ChatOutputFormat(kind: .schema, schema: schema)
        try format.validate()
        XCTAssertNotNil(format.promptInstruction)

        let overLimit: WorkflowDataSchema = .record(numberFields + [
            .init("choice", .enumeration(baseChoices + [finalChoice + "q"])),
        ])
        assertOversizedSchema(overLimit)
    }

    private func assertOversizedSchema(
        _ schema: WorkflowDataSchema,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let format = ChatOutputFormat(kind: .schema, schema: schema)
        XCTAssertThrowsError(try format.validate(), file: file, line: line) { error in
            XCTAssertTrue((error as? ChatOutputFormat.ValidationError)?.reason.contains("64 KiB") == true,
                          "Error: \(error)", file: file, line: line)
        }
        XCTAssertNil(format.promptInstruction, file: file, line: line)
        let report = format.check("\"choice\"")
        XCTAssertEqual(report.status, .invalid, file: file, line: line)
        XCTAssertTrue(report.reason?.contains("64 KiB") == true, file: file, line: line)
        XCTAssertNil(report.datum, file: file, line: line)
    }

    private func assertInvalid(
        _ format: ChatOutputFormat,
        _ source: String,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let original = source
        let report = format.check(source)
        XCTAssertEqual(source, original, file: file, line: line)
        XCTAssertEqual(report.status, .invalid, file: file, line: line)
        XCTAssertNil(report.datum, file: file, line: line)
        XCTAssertTrue(report.reason?.contains(fragment) == true, "Reason: \(report.reason ?? "nil")", file: file, line: line)
    }
}
