import XCTest
@testable import DWorkbench

final class WorkflowStructuredTextTests: XCTestCase {
    func testParsesRecordListUnicodeEscapesAndOptionalValues() throws {
        let fields: [WorkflowRecordField] = [
            .init("title", .text),
            .init("score", .number(unit: "%")),
            .init("enabled", .boolean),
            .init("mode", .enumeration(["draft", "final"])),
            .init("tags", .list(.text)),
            .init("note", .optional(.text)),
        ]
        let input = #"{"title":"作品\n\uD83C\uDFA8","score":98.5,"enabled":true,"mode":"final","tags":["α","quote: \"ok\""],"note":null}"#

        let parsed = try WorkflowStructuredText.parse(input, as: .record(fields))
        guard case .record(let declared, let values) = parsed else { return XCTFail("Expected record") }
        XCTAssertEqual(declared, fields)
        XCTAssertEqual(values["title"], .text("作品\n🎨"))
        XCTAssertEqual(values["score"], .number(98.5, unit: "%"))
        XCTAssertEqual(values["enabled"], .boolean(true))
        XCTAssertEqual(values["mode"], .enumeration("final", choices: ["draft", "final"]))
        XCTAssertEqual(values["note"], .none(.text))
        guard let tagsValue = values["tags"], case .list(.text, let tags) = tagsValue else {
            return XCTFail("Expected text list")
        }
        XCTAssertEqual(tags.map(\.id), ["1", "2"])
        XCTAssertEqual(tags.map(\.value), [.text("α"), .text("quote: \"ok\"")])
    }

    func testParsesPresentOptionalAndTopLevelJSONString() throws {
        XCTAssertEqual(
            try WorkflowStructuredText.parse(#""line\tvalue""#, as: .text),
            .text("line\tvalue")
        )
        XCTAssertEqual(
            try WorkflowStructuredText.parse(#""present""#, as: .optional(.text)),
            .text("present")
        )
    }

    func testNumberUsesSchemaUnitAndBooleanIsNotANumber() throws {
        XCTAssertEqual(
            try WorkflowStructuredText.parse("12.25", as: .number(unit: "ms")),
            .number(12.25, unit: "ms")
        )
        assertRejected("true", as: .number(unit: nil), containing: "$")
        assertRejected("1", as: .boolean, containing: "$")
        assertRejected(#""12.25""#, as: .number(unit: "ms"), containing: "$")
    }

    func testRejectsNonFiniteAndMalformedNumbers() {
        assertRejected("1e400", as: .number(unit: nil), containing: "finite Double")
        assertRejected("01", as: .number(unit: nil), containing: "Leading zeros")
        assertRejected("1.", as: .number(unit: nil), containing: "Fraction")
        assertRejected("NaN", as: .number(unit: nil), containing: "$")
    }

    func testRejectsMissingUnknownAndIllegalNullFieldsWithPaths() {
        let schema: WorkflowDataSchema = .record([
            .init("name", .text),
            .init("nickname", .text, required: false),
            .init("note", .optional(.text), required: false),
        ])
        assertRejected(#"{"nickname":"n"}"#, as: schema, containing: "name")
        assertRejected(#"{"name":"n","extra":1}"#, as: schema, containing: "extra")
        assertRejected(#"{"name":"n","nickname":null}"#, as: schema, containing: "nickname")

        XCTAssertNoThrow(try WorkflowStructuredText.parse(#"{"name":"n"}"#, as: schema))
        XCTAssertNoThrow(try WorkflowStructuredText.parse(#"{"name":"n","note":null}"#, as: schema))
    }

    func testRejectsUnknownEnumerationChoice() {
        assertRejected(#""other""#, as: .enumeration(["one", "two"]), containing: "enumeration")
        assertRejected("1", as: .enumeration(["one", "two"]), containing: "enumeration")
    }

    func testRejectsDirectAndEscapedDuplicateKeys() {
        let schema: WorkflowDataSchema = .record([.init("a", .number(unit: nil))])
        assertRejected(#"{"a":1,"a":2}"#, as: schema, containing: "Duplicate")
        assertRejected(#"{"a":1,"\u0061":2}"#, as: schema, containing: "Duplicate")
    }

    func testRejectsTrailingContentMarkdownAndTrailingCommas() {
        assertRejected(#""ok" explanation"#, as: .text, containing: "Trailing")
        assertRejected("```json\n\"ok\"\n```", as: .text, containing: "$")
        assertRejected("[1,]", as: .list(.number(unit: nil)), containing: "Trailing commas")
        assertRejected(#"{"value":1,}"#, as: .record([.init("value", .number(unit: nil))]), containing: "Trailing commas")
    }

    func testRejectsInvalidUnicodeEscapes() {
        assertRejected(#""\uD800""#, as: .text, containing: "surrogate")
        assertRejected(#""\uDC00""#, as: .text, containing: "surrogate")
        assertRejected(#""\uD800\u0041""#, as: .text, containing: "surrogate")
    }

    func testRejectsDepthInputListObjectAndTotalValueLimits() {
        let nested = String(repeating: "[", count: 26) + "0" + String(repeating: "]", count: 26)
        assertRejected(nested, as: .list(.number(unit: nil)), containing: "nesting")

        let oversizedInput = "\"" + String(repeating: "a", count: 1_048_576) + "\""
        assertRejected(oversizedInput, as: .text, containing: "1 MiB")

        let tooManyItems = "[" + Array(repeating: "0", count: 4_097).joined(separator: ",") + "]"
        assertRejected(tooManyItems, as: .list(.number(unit: nil)), containing: "4096")

        let object = "{" + (0..<257).map { "\"f\($0)\":null" }.joined(separator: ",") + "}"
        assertRejected(object, as: .record([]), containing: "256")

        let group = "[" + Array(repeating: "null", count: 4_096).joined(separator: ",") + "]"
        let tooManyValues = "[" + Array(repeating: group, count: 17).joined(separator: ",") + "]"
        assertRejected(tooManyValues, as: .list(.list(.optional(.text))), containing: "65536")
    }

    func testRejectsResultAndAssetSchemasIncludingNestedUnsupportedSchemas() {
        assertRejected(#""value""#, as: .result(.text), containing: "Result")
        assertRejected(#""value""#, as: .asset(.image), containing: "Asset")
        assertRejected("{}", as: .record([.init("future", .optional(.asset(.image)), required: false)]), containing: "Asset")
    }

    func testStableListIdentifiersAndFailedParseDoesNotMutatePriorValue() throws {
        let schema: WorkflowDataSchema = .list(.text)
        let input = #"["first","second"]"#
        let first = try WorkflowStructuredText.parse(input, as: schema)
        let second = try WorkflowStructuredText.parse(input, as: schema)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.items?.map(\.id), ["1", "2"])

        assertRejected(#"["first",false]"#, as: schema, containing: "[2]")
        XCTAssertEqual(first, second)
    }

    private func assertRejected(
        _ input: String,
        as schema: WorkflowDataSchema,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try WorkflowStructuredText.parse(input, as: schema), file: file, line: line) { error in
            XCTAssertTrue(
                String(describing: error).contains(fragment),
                "Expected error to contain \(fragment.debugDescription), got: \(error)",
                file: file,
                line: line
            )
        }
    }
}
