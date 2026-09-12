import DInference
import Foundation

/// A bounded, strict interchange format for MRT2 note conditioning.
public enum MusicConditionFile {
    private static let maximumBytes = 128 * 1024

    public static func decode(_ data: Data) throws -> (draft: MusicCreationDraft, durationText: String) {
        guard data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw InferenceFailure.invalidRequest("Invalid or oversized music condition file.")
        }

        var parser = StrictMusicJSON(text)
        let value = try parser.parse()
        guard case .object(let root) = value else {
            throw InferenceFailure.invalidRequest("A music condition file must contain one object.")
        }
        try requireKeys(root, allowed: ["schemaVersion", "frameRate", "durationFrames", "notes"],
                        required: ["schemaVersion", "frameRate", "durationFrames"])

        let schemaVersion = try integer(root["schemaVersion"], field: "schemaVersion")
        let frameRate = try integer(root["frameRate"], field: "frameRate")
        let durationFrames = try integer(root["durationFrames"], field: "durationFrames")

        let events: [AudioNoteEvent]?
        if let noteValue = root["notes"] {
            guard case .array(let rows) = noteValue, rows.count <= 512 else {
                throw InferenceFailure.invalidRequest("Invalid notes in music condition file.")
            }
            events = try rows.map { row in
                guard case .object(let fields) = row else {
                    throw InferenceFailure.invalidRequest("Each music note must be an object.")
                }
                try requireKeys(fields, allowed: ["pitch", "startFrame", "endFrame"],
                                required: ["pitch", "startFrame", "endFrame"])
                return AudioNoteEvent(
                    pitch: try integer(fields["pitch"], field: "pitch"),
                    startFrame: try integer(fields["startFrame"], field: "startFrame"),
                    endFrame: try integer(fields["endFrame"], field: "endFrame")
                )
            }
        } else {
            events = nil
        }

        let sequence = AudioNoteSequence(schemaVersion: schemaVersion, frameRate: frameRate,
                                         durationFrames: durationFrames, notes: events)
        try sequence.validate()

        let rows = events?.map {
            MusicNoteDraft(
                pitchText: String($0.pitch),
                startText: secondsText(forFrames: $0.startFrame),
                durationText: secondsText(forFrames: $0.endFrame - $0.startFrame)
            )
        } ?? []
        return (MusicCreationDraft(notes: rows, hasNoteCondition: events != nil),
                secondsText(forFrames: durationFrames))
    }

    public static func encode(_ draft: MusicCreationDraft, durationText: String) throws -> Data {
        let sequence = try draft.makeSequence(durationText: durationText)
        var json = "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":\(sequence.durationFrames)"
        if let notes = sequence.notes {
            json += ",\"notes\":["
            for (index, note) in notes.enumerated() {
                if index > 0 { json += "," }
                json += "{\"pitch\":\(note.pitch),\"startFrame\":\(note.startFrame),\"endFrame\":\(note.endFrame)}"
            }
            json += "]"
        }
        json += "}"
        let data = Data(json.utf8)
        guard data.count <= maximumBytes else {
            throw InferenceFailure.invalidRequest("Music condition file is too large.")
        }
        return data
    }

    private static func requireKeys(_ object: [String: StrictMusicJSON.Value],
                                    allowed: Set<String>, required: Set<String>) throws {
        let keys = Set(object.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
            throw InferenceFailure.invalidRequest("Unknown or missing music condition field.")
        }
    }

    private static func integer(_ value: StrictMusicJSON.Value?, field: String) throws -> Int {
        guard case .number(let token)? = value,
              !token.contains("."), !token.contains("e"), !token.contains("E"),
              let result = Int(token) else {
            throw InferenceFailure.invalidRequest("\(field) must be an integer.")
        }
        return result
    }

    private static func secondsText(forFrames frames: Int) -> String {
        let whole = frames / 25
        let hundredths = (frames % 25) * 4
        guard hundredths != 0 else { return String(whole) }
        if hundredths.isMultiple(of: 10) {
            return "\(whole).\(hundredths / 10)"
        }
        return "\(whole)." + String(format: "%02d", hundredths)
    }
}

/// Deliberately local: enough JSON for this schema, with duplicate-key and depth enforcement.
private struct StrictMusicJSON {
    indirect enum Value {
        case object([String: Value])
        case array([Value])
        case string(String)
        case number(String)
        case boolean(Bool)
        case null
    }

    private let scalars: [Unicode.Scalar]
    private var position = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    mutating func parse() throws -> Value {
        skipWhitespace()
        let result = try parseValue(depth: 1)
        skipWhitespace()
        guard position == scalars.count else { throw invalidJSON() }
        return result
    }

    private mutating func parseValue(depth: Int) throws -> Value {
        guard depth <= 8, position < scalars.count else { throw invalidJSON() }
        switch scalars[position].value {
        case 123: return try parseObject(depth: depth) // {
        case 91: return try parseArray(depth: depth)   // [
        case 34: return .string(try parseString())
        case 45, 48...57: return .number(try parseNumber())
        case 116:
            try consume("true")
            return .boolean(true)
        case 102:
            try consume("false")
            return .boolean(false)
        case 110:
            try consume("null")
            return .null
        default: throw invalidJSON()
        }
    }

    private mutating func parseObject(depth: Int) throws -> Value {
        position += 1
        skipWhitespace()
        var object: [String: Value] = [:]
        if take(125) { return .object(object) }
        while true {
            guard position < scalars.count, scalars[position].value == 34 else { throw invalidJSON() }
            let key = try parseString()
            guard object[key] == nil else {
                throw InferenceFailure.invalidRequest("Duplicate music condition field.")
            }
            skipWhitespace()
            guard take(58) else { throw invalidJSON() }
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            if take(125) { return .object(object) }
            guard take(44) else { throw invalidJSON() }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws -> Value {
        position += 1
        skipWhitespace()
        var array: [Value] = []
        if take(93) { return .array(array) }
        while true {
            array.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if take(93) { return .array(array) }
            guard take(44) else { throw invalidJSON() }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        guard take(34) else { throw invalidJSON() }
        var result = ""
        while position < scalars.count {
            let scalar = scalars[position]
            position += 1
            if scalar.value == 34 { return result }
            if scalar.value == 92 {
                guard position < scalars.count else { throw invalidJSON() }
                let escape = scalars[position].value
                position += 1
                switch escape {
                case 34: result.unicodeScalars.append("\"")
                case 92: result.unicodeScalars.append("\\")
                case 47: result.unicodeScalars.append("/")
                case 98: result.unicodeScalars.append("\u{08}")
                case 102: result.unicodeScalars.append("\u{0c}")
                case 110: result.unicodeScalars.append("\n")
                case 114: result.unicodeScalars.append("\r")
                case 116: result.unicodeScalars.append("\t")
                case 117:
                    let first = try parseHexQuad()
                    let value: UInt32
                    if (0xd800...0xdbff).contains(first) {
                        guard take(92), take(117) else { throw invalidJSON() }
                        let second = try parseHexQuad()
                        guard (0xdc00...0xdfff).contains(second) else { throw invalidJSON() }
                        value = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
                    } else {
                        guard !(0xdc00...0xdfff).contains(first) else { throw invalidJSON() }
                        value = first
                    }
                    guard let decoded = Unicode.Scalar(value) else { throw invalidJSON() }
                    result.unicodeScalars.append(decoded)
                default: throw invalidJSON()
                }
            } else {
                guard scalar.value >= 0x20 else { throw invalidJSON() }
                result.unicodeScalars.append(scalar)
            }
        }
        throw invalidJSON()
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard position + 4 <= scalars.count else { throw invalidJSON() }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit = scalars[position].value
            position += 1
            value <<= 4
            switch digit {
            case 48...57: value += digit - 48
            case 65...70: value += digit - 55
            case 97...102: value += digit - 87
            default: throw invalidJSON()
            }
        }
        return value
    }

    private mutating func parseNumber() throws -> String {
        let start = position
        _ = take(45)
        guard position < scalars.count else { throw invalidJSON() }
        if take(48) {
            if position < scalars.count, isDigit(scalars[position]) { throw invalidJSON() }
        } else {
            guard position < scalars.count, (49...57).contains(scalars[position].value) else {
                throw invalidJSON()
            }
            while position < scalars.count, isDigit(scalars[position]) { position += 1 }
        }
        if take(46) {
            guard position < scalars.count, isDigit(scalars[position]) else { throw invalidJSON() }
            while position < scalars.count, isDigit(scalars[position]) { position += 1 }
        }
        if position < scalars.count, scalars[position].value == 101 || scalars[position].value == 69 {
            position += 1
            if position < scalars.count, scalars[position].value == 43 || scalars[position].value == 45 {
                position += 1
            }
            guard position < scalars.count, isDigit(scalars[position]) else { throw invalidJSON() }
            while position < scalars.count, isDigit(scalars[position]) { position += 1 }
        }
        return String(String.UnicodeScalarView(scalars[start..<position]))
    }

    private func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    private mutating func consume(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard position < scalars.count, scalars[position] == expected else { throw invalidJSON() }
            position += 1
        }
    }

    private mutating func take(_ value: UInt32) -> Bool {
        guard position < scalars.count, scalars[position].value == value else { return false }
        position += 1
        return true
    }

    private mutating func skipWhitespace() {
        while position < scalars.count,
              [9, 10, 13, 32].contains(scalars[position].value) {
            position += 1
        }
    }

    private func invalidJSON() -> InferenceFailure {
        .invalidRequest("Invalid JSON in music condition file.")
    }
}
