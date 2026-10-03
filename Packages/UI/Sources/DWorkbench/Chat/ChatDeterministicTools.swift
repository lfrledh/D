import Foundation
import TabularData

/// In-memory, value-only operations. The caller owns scheduling, authorization, and activity records.
public enum ChatDeterministicTools {
    public struct ToolError: Error, LocalizedError, Codable, Sendable, Equatable {
        public enum Code: String, Codable, Sendable { case invalidInput, divisionByZero, arithmetic, budget, malformedCSV, invalidNumber }
        public let code: Code
        public let message: String
        public var errorDescription: String? { message }
        public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    }

    public enum ArithmeticOperator: String, Codable, Sendable { case add, subtract, multiply, divide }
    public struct ArithmeticRequest: Codable, Sendable, Equatable {
        public let operation: ArithmeticOperator
        public let left: String
        public let right: String
        public init(_ operation: ArithmeticOperator, left: String, right: String) {
            self.operation = operation; self.left = left; self.right = right
        }
    }
    public struct ArithmeticResult: Codable, Sendable, Equatable {
        public let decimal: String
        /// Always true for division: Foundation can round a quotient without reporting precision loss.
        public let mayBeRounded: Bool
    }

    /// Decimal operands are decimal strings so JSON never routes them through binary floating point.
    /// Reported precision loss is rejected. A successful division may still be rounded.
    public static func calculate(_ request: ArithmeticRequest) throws -> ArithmeticResult {
        try Task.checkCancellation()
        var left = try decimal(request.left)
        var right = try decimal(request.right)
        if request.operation == .divide && right == 0 {
            throw ToolError(.divisionByZero, "Division by zero.")
        }
        // Foundation can silently round multiplication too. A conservative decimal
        // digit budget establishes exact representability before non-division arithmetic.
        if request.operation != .divide {
            let a = decimalShape(request.left), b = decimalShape(request.right)
            let needed: Int
            if request.operation == .multiply { needed = a.digits + b.digits }
            else { let exponent = min(a.exponent, b.exponent); needed = max(a.digits + a.exponent - exponent, b.digits + b.exponent - exponent) + 1 }
            guard needed <= 38 else { throw ToolError(.arithmetic, "Decimal operation would lose precision.") }
        }
        var answer = Decimal()
        let status: NSDecimalNumber.CalculationError
        switch request.operation {
        case .add: status = NSDecimalAdd(&answer, &left, &right, .plain)
        case .subtract: status = NSDecimalSubtract(&answer, &left, &right, .plain)
        case .multiply: status = NSDecimalMultiply(&answer, &left, &right, .plain)
        case .divide: status = NSDecimalDivide(&answer, &left, &right, .plain)
        }
        try Task.checkCancellation()
        if status == .lossOfPrecision {
            throw ToolError(.arithmetic, "Decimal operation would lose precision.")
        }
        guard status == .noError,
              NSDecimalNumber(decimal: answer) != NSDecimalNumber.notANumber else {
            throw ToolError(.arithmetic, "Decimal operation overflowed or underflowed.")
        }
        return ArithmeticResult(decimal: NSDecimalNumber(decimal: answer).stringValue,
                                mayBeRounded: request.operation == .divide)
    }

    public enum UnitFamily: String, Codable, Sendable { case length, mass, temperature, duration }
    public enum UnitChoice: String, Codable, Sendable {
        case meters, centimeters, kilometers, feet, miles
        case grams, kilograms, pounds
        case celsius, fahrenheit, kelvin
        case seconds, minutes, hours

        public var family: UnitFamily {
            switch self {
            case .meters, .centimeters, .kilometers, .feet, .miles: .length
            case .grams, .kilograms, .pounds: .mass
            case .celsius, .fahrenheit, .kelvin: .temperature
            case .seconds, .minutes, .hours: .duration
            }
        }
        fileprivate var dimension: Dimension {
            switch self {
            case .meters: UnitLength.meters
            case .centimeters: UnitLength.centimeters
            case .kilometers: UnitLength.kilometers
            case .feet: UnitLength.feet
            case .miles: UnitLength.miles
            case .grams: UnitMass.grams
            case .kilograms: UnitMass.kilograms
            case .pounds: UnitMass.pounds
            case .celsius: UnitTemperature.celsius
            case .fahrenheit: UnitTemperature.fahrenheit
            case .kelvin: UnitTemperature.kelvin
            case .seconds: UnitDuration.seconds
            case .minutes: UnitDuration.minutes
            case .hours: UnitDuration.hours
            }
        }
    }
    public struct UnitRequest: Codable, Sendable, Equatable {
        public let value: Double
        public let from: UnitChoice
        public let to: UnitChoice
        public init(value: Double, from: UnitChoice, to: UnitChoice) {
            self.value = value; self.from = from; self.to = to
        }
    }
    public struct UnitResult: Codable, Sendable, Equatable {
        public let value: Double
        public let unit: UnitChoice
    }

    public static func convert(_ request: UnitRequest) throws -> UnitResult {
        try Task.checkCancellation()
        guard request.value.isFinite, request.from.family == request.to.family else {
            throw ToolError(.invalidInput, "A finite value and units from the same family are required.")
        }
        let value = Measurement(value: request.value, unit: request.from.dimension)
            .converted(to: request.to.dimension).value
        guard value.isFinite else { throw ToolError(.arithmetic, "Unit conversion exceeded the finite range.") }
        try Task.checkCancellation()
        return UnitResult(value: value, unit: request.to)
    }

    public struct TimeRequest: Codable, Sendable, Equatable {
        public let instant: String
        public let sourceTimeZone: String
        public let targetTimeZone: String
        public init(instant: String, sourceTimeZone: String, targetTimeZone: String) {
            self.instant = instant; self.sourceTimeZone = sourceTimeZone; self.targetTimeZone = targetTimeZone
        }
    }
    public struct TimeResult: Codable, Sendable, Equatable {
        public let epochSeconds: Double
        public let utc: String
        public let sourceLocal: String
        public let targetLocal: String
        public let sourceTimeZone: String
        public let targetTimeZone: String
    }

    /// The instant must include Z or a numeric offset; a local wall time is never inferred.
    public static func convert(_ request: TimeRequest) throws -> TimeResult {
        try Task.checkCancellation()
        let expression = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?(?:Z|[+-](?:0[0-9]|1[0-4]):[0-5][0-9])$"#
        guard request.instant.range(of: expression, options: .regularExpression) != nil,
              validInstantFields(request.instant),
              let source = timeZone(request.sourceTimeZone), let target = timeZone(request.targetTimeZone) else {
            throw ToolError(.invalidInput, "An explicit ISO 8601 instant and valid IANA time zones are required.")
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = request.instant.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = parser.date(from: request.instant), date.timeIntervalSince1970.isFinite else {
            throw ToolError(.invalidInput, "Invalid ISO 8601 instant.")
        }
        let utcFormatter = ISO8601DateFormatter()
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)!
        utcFormatter.formatOptions = request.instant.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        func local(_ zone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.dateFormat = request.instant.contains(".")
                ? "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX" : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            return formatter.string(from: date)
        }
        try Task.checkCancellation()
        return TimeResult(epochSeconds: date.timeIntervalSince1970, utc: utcFormatter.string(from: date),
                          sourceLocal: local(source), targetLocal: local(target),
                          sourceTimeZone: request.sourceTimeZone, targetTimeZone: request.targetTimeZone)
    }

    public struct CSVBudget: Codable, Sendable, Equatable {
        public let maxInputBytes: Int
        public let maxRows: Int
        public let maxColumns: Int
        public let maxPreviewRows: Int
        public init(maxInputBytes: Int = 2_000_000, maxRows: Int = 10_000,
                    maxColumns: Int = 64, maxPreviewRows: Int = 20) {
            self.maxInputBytes = maxInputBytes; self.maxRows = maxRows
            self.maxColumns = maxColumns; self.maxPreviewRows = maxPreviewRows
        }
        fileprivate func validate() throws {
            guard (1...8_000_000).contains(maxInputBytes), (1...100_000).contains(maxRows),
                  (1...256).contains(maxColumns), (0...100).contains(maxPreviewRows) else {
                throw ToolError(.budget, "CSV budget is outside supported bounds.")
            }
        }
    }
    public struct CSVRequest: Codable, Sendable, Equatable {
        public let csvData: Data
        public let numericColumns: [String]
        public let budget: CSVBudget
        public init(csvData: Data, numericColumns: [String], budget: CSVBudget = .init()) {
            self.csvData = csvData; self.numericColumns = numericColumns; self.budget = budget
        }
    }
    public struct CSVRow: Codable, Sendable, Equatable {
        public let cells: [String?]
    }
    public struct NumericSummary: Codable, Sendable, Equatable {
        public let column: String
        public let present: Int
        public let missing: Int
        public let minimum: Double?
        public let maximum: Double?
        public let mean: Double?
    }
    public struct CSVResult: Codable, Sendable, Equatable {
        public let columns: [String]
        public let rowCount: Int
        public let numeric: [NumericSummary]
        /// Only this property is limited by maxPreviewRows; all summaries use every row.
        public let preview: [CSVRow]
    }

    public static func analyze(_ request: CSVRequest) throws -> CSVResult {
        try Task.checkCancellation()
        try request.budget.validate()
        guard !request.csvData.isEmpty, request.csvData.count <= request.budget.maxInputBytes else {
            throw ToolError(.budget, "CSV input is empty or exceeds its byte budget.")
        }
        var options = CSVReadingOptions()
        options.nilEncodings = [""]
        options.ignoresEmptyLines = false
        options.usesQuoting = true
        options.usesEscaping = false
        let inferred: DataFrame
        do { inferred = try DataFrame(csvData: request.csvData, options: options) }
        catch { throw ToolError(.malformedCSV, "CSV could not be parsed.") }
        try Task.checkCancellation()
        let names = inferred.columns.map(\.name)
        guard !names.isEmpty, !names.contains(where: { $0.isEmpty }), Set(names).count == names.count else {
            throw ToolError(.malformedCSV, "CSV headers are missing or duplicate.")
        }
        guard names.count <= request.budget.maxColumns else {
            throw ToolError(.budget, "CSV column budget exceeded.")
        }
        guard inferred.rows.count <= request.budget.maxRows else {
            throw ToolError(.budget, "CSV row budget exceeded.")
        }
        guard Set(request.numericColumns).count == request.numericColumns.count,
              request.numericColumns.allSatisfy({ names.contains($0) }) else {
            throw ToolError(.invalidInput, "Numeric columns must be distinct CSV headers.")
        }
        // Explicit String types avoid inferred numeric conversion turning invalid cells into nil.
        let types = Dictionary(uniqueKeysWithValues: names.map { ($0, CSVType.string) })
        let frame: DataFrame
        do { frame = try DataFrame(csvData: request.csvData, types: types, options: options) }
        catch { throw ToolError(.malformedCSV, "CSV could not be parsed as text.") }
        try Task.checkCancellation()
        guard frame.columns.map(\.name) == names, frame.rows.count == inferred.rows.count else {
            throw ToolError(.malformedCSV, "CSV parsing produced inconsistent rows or headers.")
        }
        let columns = frame.columns
        var summaries: [NumericSummary] = []
        for name in request.numericColumns {
            try Task.checkCancellation()
            guard let index = names.firstIndex(of: name) else { throw ToolError(.malformedCSV, "Missing CSV column.") }
            var present = 0
            var missing = 0
            var minimum = Double.infinity
            var maximum = -Double.infinity
            var sum = 0.0
            var compensation = 0.0
            for row in 0..<frame.rows.count {
                try Task.checkCancellation()
                guard let raw = columns[index][row] else { missing += 1; continue }
                guard let string = raw as? String, isDecimalLiteral(string),
                      let number = Double(string), number.isFinite else {
                    throw ToolError(.invalidNumber, "Invalid number in column \(name), row \(row + 1).")
                }
                present += 1
                minimum = Swift.min(minimum, number)
                maximum = Swift.max(maximum, number)
                let adjusted = number - compensation
                let next = sum + adjusted
                compensation = (next - sum) - adjusted
                sum = next
                guard sum.isFinite else { throw ToolError(.arithmetic, "Numeric summary exceeded finite range.") }
            }
            let mean = present == 0 ? nil : sum / Double(present)
            summaries.append(NumericSummary(column: name, present: present, missing: missing,
                                            minimum: present == 0 ? nil : minimum,
                                            maximum: present == 0 ? nil : maximum, mean: mean))
        }
        var preview: [CSVRow] = []
        for row in 0..<Swift.min(frame.rows.count, request.budget.maxPreviewRows) {
            try Task.checkCancellation()
            var cells: [String?] = []
            for column in columns {
                try Task.checkCancellation()
                guard let value = column[row] else { cells.append(nil); continue }
                guard let string = value as? String else {
                    throw ToolError(.malformedCSV, "CSV text column contained a non-text value.")
                }
                cells.append(string)
            }
            preview.append(CSVRow(cells: cells))
        }
        return CSVResult(columns: names, rowCount: frame.rows.count, numeric: summaries, preview: preview)
    }

    private static func timeZone(_ identifier: String) -> TimeZone? {
        guard identifier == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(identifier) else { return nil }
        return TimeZone(identifier: identifier)
    }

    private static func validInstantFields(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func number(_ range: Range<Int>) -> Int? { Int(String(decoding: bytes[range], as: UTF8.self)) }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              year > 0, (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            return false
        }
        if let sign = bytes.lastIndex(where: { $0 == 43 || $0 == 45 }), sign > 18 {
            guard let offsetHour = number((sign + 1)..<(sign + 3)),
                  let offsetMinute = number((sign + 4)..<(sign + 6)),
                  offsetHour < 14 || (offsetHour == 14 && offsetMinute == 0) else { return false }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fields = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: fields) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return actual.year == year && actual.month == month && actual.day == day &&
            actual.hour == hour && actual.minute == minute && actual.second == second
    }

    private static func decimalShape(_ text: String) -> (digits: Int, exponent: Int) {
        let unsigned = text.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        let pieces = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(pieces.joined()), exponent = pieces.count == 2 ? -pieces[1].count : 0
        while digits.first == "0" { digits.removeFirst() }
        while digits.last == "0" { digits.removeLast(); exponent += 1 }
        return (max(1, digits.count), digits.isEmpty ? 0 : exponent)
    }

    private static func decimal(_ text: String) throws -> Decimal {
        guard isDecimalLiteral(text), text.filter(\.isNumber).count <= 38,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              NSDecimalNumber(decimal: value) != NSDecimalNumber.notANumber else {
            throw ToolError(.invalidNumber, "A finite decimal with at most 38 digits is required.")
        }
        return value
    }

    private static func isDecimalLiteral(_ text: String) -> Bool {
        text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil
    }
}
