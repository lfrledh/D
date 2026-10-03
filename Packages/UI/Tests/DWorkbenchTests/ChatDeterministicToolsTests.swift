import Foundation
import Testing
@testable import DWorkbench

@Suite("Chat deterministic tools")
struct ChatDeterministicToolsTests {
    typealias Tools = ChatDeterministicTools

    @Test func explicitDecimalOperationsAndFailures() throws {
        #expect(try Tools.calculate(.init(.add, left: "0.1", right: "0.2")).decimal == "0.3")
        #expect(try Tools.calculate(.init(.subtract, left: "5", right: "8")).decimal == "-3")
        #expect(try Tools.calculate(.init(.multiply, left: "2.5", right: "4")).decimal == "10")
        #expect(try Tools.calculate(.init(.divide, left: "7.5", right: "2.5")).decimal == "3")
        expectError(.divisionByZero) { try Tools.calculate(.init(.divide, left: "1", right: "0")) }
        for invalid in ["NaN", "Infinity", "1e309", "2+3", "1.2.3"] {
            expectError(.invalidNumber) { try Tools.calculate(.init(.add, left: invalid, right: "1")) }
        }
    }

    @Test func inexactDecimalOperationsReportPrecisionLoss() {
        // 10^20 + 1 is representable, but its square needs 41 significant digits.
        let operand = "1" + String(repeating: "0", count: 19) + "1"
        for request in [
            Tools.ArithmeticRequest(.multiply, left: operand, right: operand),
            Tools.ArithmeticRequest(.divide, left: "1", right: "3")
        ] {
            do {
                _ = try Tools.calculate(request)
                Issue.record("Expected an explicit precision-loss error")
            } catch let error as Tools.ToolError {
                #expect(error.code == .arithmetic)
                #expect(error.message == "Decimal operation would lose precision.")
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func cancelledTaskCannotReturnAnArithmeticResult() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Tools.calculate(.init(.multiply, left: "2", right: "3"))
        }
        do {
            _ = try await task.value
            Issue.record("Expected Task cancellation")
        } catch is CancellationError {
            // Cancellation is controlled inside the Task before calculate starts.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func closedUnitFamiliesAndFiniteResults() throws {
        let distance = try Tools.convert(.init(value: 1, from: .miles, to: .kilometers))
        #expect(abs(distance.value - 1.609344) < 0.000001)
        let boiling = try Tools.convert(.init(value: 100, from: .celsius, to: .fahrenheit))
        #expect(abs(boiling.value - 212) < 0.000001)
        let duration = try Tools.convert(.init(value: 2, from: .hours, to: .minutes))
        #expect(duration.value == 120)
        expectError(.invalidInput) { try Tools.convert(.init(value: 1, from: .meters, to: .kilograms)) }
        expectError(.invalidInput) { try Tools.convert(.init(value: .infinity, from: .meters, to: .feet)) }
    }

    @Test func absoluteInstantShowsDayBoundaryInBothZones() throws {
        let result = try Tools.convert(.init(instant: "1970-01-01T00:00:00Z",
                                             sourceTimeZone: "UTC", targetTimeZone: "America/New_York"))
        #expect(result.epochSeconds == 0)
        #expect(result.utc == "1970-01-01T00:00:00Z")
        #expect(result.sourceLocal == "1970-01-01T00:00:00Z")
        #expect(result.targetLocal == "1969-12-31T19:00:00-05:00")
        expectError(.invalidInput) {
            try Tools.convert(.init(instant: "2026-11-01T01:30:00",
                                    sourceTimeZone: "America/New_York", targetTimeZone: "Asia/Tokyo"))
        }
        expectError(.invalidInput) {
            try Tools.convert(.init(instant: "1970-01-01T00:00:00Z",
                                    sourceTimeZone: "Not/A_Zone", targetTimeZone: "Asia/Tokyo"))
        }
        expectError(.invalidInput) {
            try Tools.convert(.init(instant: "2026-02-30T12:00:00Z",
                                    sourceTimeZone: "UTC", targetTimeZone: "Asia/Tokyo"))
        }
    }

    @Test func fullCSVSummaryIsIndependentOfUnicodeMultilinePreview() throws {
        let csv = "name,amount,note\n\"東京, A\",1.5,\"first\nsecond\"\n👩🏽‍🎨,,missing\nC,4.5,done\n"
        let result = try Tools.analyze(.init(csvData: Data(csv.utf8), numericColumns: ["amount"],
                                             budget: .init(maxInputBytes: 1_024, maxRows: 3,
                                                           maxColumns: 3, maxPreviewRows: 1)))
        #expect(result.columns == ["name", "amount", "note"])
        #expect(result.rowCount == 3)
        #expect(result.preview.count == 1)
        #expect(result.preview[0].cells == ["東京, A", "1.5", "first\nsecond"])
        let summary = try #require(result.numeric.first)
        #expect(summary.present == 2)
        #expect(summary.missing == 1)
        #expect(summary.minimum == 1.5)
        #expect(summary.maximum == 4.5)
        #expect(summary.mean == 3)
        let decoded = try JSONDecoder().decode(Tools.CSVResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
    }

    @Test func invalidSelectedNumberAndBudgetsFailInsteadOfDroppingRows() throws {
        let csv = Data("label,value\na,1\nb,not-a-number\nc,3\n".utf8)
        expectError(.invalidNumber) { try Tools.analyze(.init(csvData: csv, numericColumns: ["value"])) }
        expectError(.budget) {
            try Tools.analyze(.init(csvData: csv, numericColumns: [],
                                    budget: .init(maxInputBytes: 10, maxRows: 10, maxColumns: 2)))
        }
        expectError(.budget) {
            try Tools.analyze(.init(csvData: csv, numericColumns: [],
                                    budget: .init(maxInputBytes: 1_024, maxRows: 2, maxColumns: 2)))
        }
        expectError(.budget) {
            try Tools.analyze(.init(csvData: csv, numericColumns: [],
                                    budget: .init(maxInputBytes: 1_024, maxRows: 10, maxColumns: 1)))
        }
        expectError(.malformedCSV) {
            try Tools.analyze(.init(csvData: Data("a,b\n1,2,3\n".utf8), numericColumns: []))
        }
    }

    private func expectError<T>(_ code: Tools.ToolError.Code, _ body: () throws -> T) {
        do {
            _ = try body()
            Issue.record("Expected \(code.rawValue) error")
        } catch let error as Tools.ToolError {
            #expect(error.code == code)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
