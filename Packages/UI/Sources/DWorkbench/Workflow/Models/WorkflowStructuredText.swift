import Foundation

/// Converts a complete, bounded JSON value into a workflow datum without executing it.
public enum WorkflowStructuredText {
    public static func parse(_ text: String, as schema: WorkflowDataSchema) throws -> WorkflowDatum {
        guard text.utf8.count <= JSONParser.maximumInputBytes else {
            throw StructuredTextError(path: "$", reason: "JSON input exceeds 1 MiB.")
        }

        try validateSchema(schema)

        var parser = JSONParser(text)
        let json = try parser.parse()
        let datum = try convert(json, as: schema, path: "$")
        do {
            try datum.validate(as: schema)
        } catch {
            throw StructuredTextError(path: "$", reason: "Parsed value failed validation: \(error)")
        }
        return datum
    }

    /// Preflight before model admission; parsing uses the identical schema rules.
    public static func validateSchema(_ schema: WorkflowDataSchema) throws {
        do {
            try schema.validateDefinition()
        } catch {
            throw StructuredTextError(path: "$", reason: "Invalid schema: \(error)")
        }
        try requireSupported(schema, path: "$")

    }

    private static func requireSupported(_ schema: WorkflowDataSchema, path: String) throws {
        switch schema {
        case .record(let fields):
            for field in fields {
                try requireSupported(field.type, path: fieldPath(path, field.name))
            }
        case .list(let element), .optional(let element):
            try requireSupported(element, path: path + "[]")
        case .result:
            throw StructuredTextError(path: path, reason: "Result schemas cannot be parsed from model text.")
        case .asset:
            throw StructuredTextError(path: path, reason: "Asset schemas cannot be parsed from model text.")
        default:
            break
        }
    }

    private static func convert(_ json: JSONValue, as schema: WorkflowDataSchema, path: String) throws -> WorkflowDatum {
        switch schema {
        case .text:
            guard case .string(let value) = json else { throw typeError(path, expected: "string") }
            return .text(value)

        case .number(let unit):
            guard case .number(let value) = json else { throw typeError(path, expected: "number") }
            guard value.isFinite else { throw StructuredTextError(path: path, reason: "Number must be finite.") }
            return .number(value, unit: unit)

        case .boolean:
            guard case .boolean(let value) = json else { throw typeError(path, expected: "boolean") }
            return .boolean(value)

        case .enumeration(let choices):
            guard case .string(let value) = json else { throw typeError(path, expected: "enumeration string") }
            guard choices.contains(value) else {
                throw StructuredTextError(path: path, reason: "Value is not an allowed enumeration choice.")
            }
            return .enumeration(value, choices: choices)

        case .record(let fields):
            guard case .object(let object) = json else { throw typeError(path, expected: "object") }
            let declaredNames = Set(fields.map(\.name))
            if let unknown = object.keys.first(where: { !declaredNames.contains($0) }) {
                throw StructuredTextError(path: fieldPath(path, unknown), reason: "Unknown record field.")
            }

            var values: [String: WorkflowDatum] = [:]
            values.reserveCapacity(object.count)
            for field in fields {
                guard let value = object[field.name] else {
                    if field.required {
                        throw StructuredTextError(path: fieldPath(path, field.name), reason: "Required field is missing.")
                    }
                    continue
                }
                values[field.name] = try convert(value, as: field.type, path: fieldPath(path, field.name))
            }
            return .record(schema: fields, fields: values)

        case .list(let element):
            guard case .array(let array) = json else { throw typeError(path, expected: "array") }
            guard array.count <= JSONParser.maximumArrayValues else {
                throw StructuredTextError(path: path, reason: "List exceeds 4096 items.")
            }
            let items = try array.enumerated().map { offset, value in
                let identifier = String(offset + 1)
                return WorkflowDataItem(
                    id: identifier,
                    value: try convert(value, as: element, path: path + "[" + identifier + "]")
                )
            }
            return .list(element: element, items: items)

        case .optional(let inner):
            if case .null = json { return .none(inner) }
            return try convert(json, as: inner, path: path)

        case .result:
            throw StructuredTextError(path: path, reason: "Result schemas cannot be parsed from model text.")
        case .asset:
            throw StructuredTextError(path: path, reason: "Asset schemas cannot be parsed from model text.")
        }
    }

    private static func typeError(_ path: String, expected: String) -> StructuredTextError {
        StructuredTextError(path: path, reason: "Expected JSON \(expected).")
    }

    private static func fieldPath(_ path: String, _ field: String) -> String {
        path + "[" + field.debugDescription + "]"
    }
}

private struct StructuredTextError: Error, CustomStringConvertible, LocalizedError {
    let path: String
    let reason: String

    var description: String { path + ": " + reason }
    var errorDescription: String? { description }
}

private indirect enum JSONValue {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

private struct JSONParser {
    static let maximumInputBytes = 1_048_576
    static let maximumDepth = 24
    static let maximumValues = 65_536
    static let maximumObjectFields = 256
    static let maximumArrayValues = 4_096

    private let bytes: [UInt8]
    private var index = 0
    private var valueCount = 0

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    mutating func parse() throws -> JSONValue {
        skipWhitespace()
        let result = try parseValue(depth: 0, path: "$")
        skipWhitespace()
        guard index == bytes.count else {
            throw error(path: "$", "Trailing content after the JSON value.")
        }
        return result
    }

    private mutating func parseValue(depth: Int, path: String) throws -> JSONValue {
        guard depth <= Self.maximumDepth else {
            throw error(path: path, "JSON nesting exceeds 24 levels.")
        }
        valueCount += 1
        guard valueCount <= Self.maximumValues else {
            throw error(path: path, "JSON contains more than 65536 values.")
        }
        guard let byte = peek() else { throw error(path: path, "Expected a JSON value.") }

        switch byte {
        case 0x22:
            return .string(try parseString(path: path))
        case 0x7B:
            return try parseObject(depth: depth, path: path)
        case 0x5B:
            return try parseArray(depth: depth, path: path)
        case 0x74:
            try consumeKeyword([0x74, 0x72, 0x75, 0x65], path: path)
            return .boolean(true)
        case 0x66:
            try consumeKeyword([0x66, 0x61, 0x6C, 0x73, 0x65], path: path)
            return .boolean(false)
        case 0x6E:
            try consumeKeyword([0x6E, 0x75, 0x6C, 0x6C], path: path)
            return .null
        case 0x2D, 0x30...0x39:
            return .number(try parseNumber(path: path))
        default:
            throw error(path: path, "Invalid JSON value.")
        }
    }

    private mutating func parseObject(depth: Int, path: String) throws -> JSONValue {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return .object([:]) }

        var values: [String: JSONValue] = [:]
        while true {
            guard peek() == 0x22 else { throw error(path: path, "Object keys must be strings.") }
            let key = try parseString(path: path)
            let childPath = path + "[" + key.debugDescription + "]"
            guard values.index(forKey: key) == nil else {
                throw error(path: childPath, "Duplicate object key.")
            }
            guard values.count < Self.maximumObjectFields else {
                throw error(path: path, "Object exceeds 256 fields.")
            }
            skipWhitespace()
            guard consume(0x3A) else { throw error(path: childPath, "Expected ':' after object key.") }
            skipWhitespace()
            values[key] = try parseValue(depth: depth + 1, path: childPath)
            skipWhitespace()
            if consume(0x7D) { break }
            guard consume(0x2C) else { throw error(path: path, "Expected ',' or '}' in object.") }
            skipWhitespace()
            guard peek() != 0x7D else { throw error(path: path, "Trailing commas are not valid JSON.") }
        }
        return .object(values)
    }

    private mutating func parseArray(depth: Int, path: String) throws -> JSONValue {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return .array([]) }

        var values: [JSONValue] = []
        while true {
            guard values.count < Self.maximumArrayValues else {
                throw error(path: path, "Array exceeds 4096 values.")
            }
            let itemPath = path + "[" + String(values.count + 1) + "]"
            values.append(try parseValue(depth: depth + 1, path: itemPath))
            skipWhitespace()
            if consume(0x5D) { break }
            guard consume(0x2C) else { throw error(path: path, "Expected ',' or ']' in array.") }
            skipWhitespace()
            guard peek() != 0x5D else { throw error(path: path, "Trailing commas are not valid JSON.") }
        }
        return .array(values)
    }

    private mutating func parseString(path: String) throws -> String {
        precondition(peek() == 0x22)
        index += 1
        var output: [UInt8] = []

        while let byte = peek() {
            index += 1
            switch byte {
            case 0x22:
                guard let value = String(bytes: output, encoding: .utf8) else {
                    throw error(path: path, "String is not valid Unicode.")
                }
                return value
            case 0x5C:
                try appendEscape(to: &output, path: path)
            case 0x00...0x1F:
                throw error(path: path, "Unescaped control character in string.")
            default:
                output.append(byte)
            }
        }
        throw error(path: path, "Unterminated string.")
    }

    private mutating func appendEscape(to output: inout [UInt8], path: String) throws {
        guard let escaped = peek() else { throw error(path: path, "Unterminated string escape.") }
        index += 1
        switch escaped {
        case 0x22, 0x5C, 0x2F: output.append(escaped)
        case 0x62: output.append(0x08)
        case 0x66: output.append(0x0C)
        case 0x6E: output.append(0x0A)
        case 0x72: output.append(0x0D)
        case 0x74: output.append(0x09)
        case 0x75:
            let first = try parseHexCodeUnit(path: path)
            let scalarValue: UInt32
            if (0xD800...0xDBFF).contains(first) {
                guard consume(0x5C), consume(0x75) else {
                    throw error(path: path, "High surrogate must be followed by a low surrogate.")
                }
                let second = try parseHexCodeUnit(path: path)
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw error(path: path, "Invalid low surrogate.")
                }
                scalarValue = 0x10000 + (UInt32(first - 0xD800) << 10) + UInt32(second - 0xDC00)
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else {
                    throw error(path: path, "Low surrogate has no preceding high surrogate.")
                }
                scalarValue = UInt32(first)
            }
            guard let scalar = UnicodeScalar(scalarValue) else {
                throw error(path: path, "Invalid Unicode scalar.")
            }
            output.append(contentsOf: String(scalar).utf8)
        default:
            throw error(path: path, "Invalid string escape.")
        }
    }

    private mutating func parseHexCodeUnit(path: String) throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let byte = peek(), let digit = hexValue(byte) else {
                throw error(path: path, "Invalid Unicode escape.")
            }
            index += 1
            value = value * 16 + UInt16(digit)
        }
        return value
    }

    private mutating func parseNumber(path: String) throws -> Double {
        let start = index
        _ = consume(0x2D)
        guard let first = peek() else { throw error(path: path, "Incomplete number.") }
        if first == 0x30 {
            index += 1
            if let next = peek(), (0x30...0x39).contains(next) {
                throw error(path: path, "Leading zeros are not valid JSON numbers.")
            }
        } else if (0x31...0x39).contains(first) {
            consumeDigits()
        } else {
            throw error(path: path, "Invalid number.")
        }

        if consume(0x2E) {
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                throw error(path: path, "Fraction requires at least one digit.")
            }
            consumeDigits()
        }
        if let exponent = peek(), exponent == 0x65 || exponent == 0x45 {
            index += 1
            if let sign = peek(), sign == 0x2B || sign == 0x2D { index += 1 }
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                throw error(path: path, "Exponent requires at least one digit.")
            }
            consumeDigits()
        }

        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(token), value.isFinite else {
            throw error(path: path, "Number is outside the finite Double range.")
        }
        return value
    }

    private mutating func consumeDigits() {
        while let byte = peek(), (0x30...0x39).contains(byte) { index += 1 }
    }

    private mutating func consumeKeyword(_ keyword: [UInt8], path: String) throws {
        guard index + keyword.count <= bytes.count,
              bytes[index..<(index + keyword.count)].elementsEqual(keyword) else {
            throw error(path: path, "Invalid JSON literal.")
        }
        index += keyword.count
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        index += 1
        return true
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private func error(path: String, _ reason: String) -> StructuredTextError {
        StructuredTextError(path: path, reason: reason)
    }
}
