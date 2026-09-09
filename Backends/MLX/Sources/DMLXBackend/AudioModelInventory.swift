import DInference
import Foundation

struct AudioModelInventory: Sendable {
    static let repository = "stabilityai/stable-audio-3-optimized"
    static let revision = AudioBackendConfiguration.registeredModelRevision

    struct Weight: Sendable, Equatable {
        let path: String
        let size: UInt64
        let sha256: String
        let identity: AudioFileSystem.Identity
    }

    let directory: URL
    let profile: AudioBackendProfile
    let weights: [Weight]
    let estimatedPeakBytes: UInt64
    let configuration: ValidatedAudioConfiguration

    static func inspect(_ request: InferenceRequest,
                        configuration supplied: AudioBackendConfiguration) throws -> Self {
        try Task.checkCancellation()
        try request.validate()
        guard case .audio(let audio) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        guard request.model.revision == revision else {
            throw InferenceFailure.invalidRequest(
                "Audio execution requires the registered SA3 revision \(revision).")
        }
        guard audio.seed <= UInt64(UInt32.max) - 1,
              (1...100).contains(audio.steps),
              audio.guidanceScale.isFinite, (1...15).contains(audio.guidanceScale) else {
            throw InferenceFailure.invalidRequest("Audio seed, steps, or guidance is outside the AUDIO1 profile limits.")
        }
        let maximumDuration: Double = supplied.profile == .medium ? 380 : 120
        guard audio.durationSeconds <= maximumDuration else {
            throw InferenceFailure.invalidRequest(
                "Audio duration exceeds the \(supplied.profile.rawValue) profile limit.")
        }
        let durationFrames = audio.durationSeconds * 44_100
        guard durationFrames.isFinite, durationFrames > 0,
              durationFrames <= Double(Int64.max),
              durationFrames.rounded(.toNearestOrEven) > 0 else {
            throw InferenceFailure.invalidRequest("Audio duration cannot be represented in the 44100 Hz frame clock.")
        }
        if let source = audio.source {
            guard source.sampleRate == 44_100, source.channels == 2,
                  abs(durationFrames - Double(source.frameCount)) <= 0.5 else {
                throw InferenceFailure.invalidRequest(
                    "Audio edit sources must be stereo 44100 Hz and match duration within half a frame.")
            }
        }

        let config = try AudioFileSystem.validate(supplied, modelDirectory: request.model.directory,
                                                  source: audio.source?.url)
        let manifestData = try AudioFileSystem.readRegularFile(
            config.modelManifest, label: "Audio model manifest", maximumBytes: 1_048_576).0
        let manifest = try AudioManifest.parse(manifestData, profile: supplied.profile)
        var weights: [Weight] = []
        for file in manifest.files {
            try Task.checkCancellation()
            let url = request.model.directory.appendingPathComponent(file.path)
            let identity = try AudioFileSystem.regularFile(url, label: "Audio model weight \(file.path)",
                                                           maximumBytes: nil)
            guard identity.size >= 0, UInt64(identity.size) == file.size else {
                throw InferenceFailure.invalidRequest("Audio model weight size mismatch: \(file.path)")
            }
            weights.append(Weight(path: file.path, size: file.size,
                                  sha256: file.sha256, identity: identity))
        }
        let peak = try estimate(largestWeight: weights.map(\.size).max() ?? 0,
                                durationSeconds: audio.durationSeconds)
        return Self(directory: request.model.directory.standardizedFileURL, profile: supplied.profile,
                    weights: weights, estimatedPeakBytes: peak, configuration: config)
    }

    func confirmUnchanged() throws {
        for weight in weights {
            try Task.checkCancellation()
            let current = try AudioFileSystem.regularFile(
                directory.appendingPathComponent(weight.path), label: "Audio model weight \(weight.path)",
                maximumBytes: nil)
            guard current == weight.identity else {
                throw InferenceFailure.invalidRequest("Audio model weight changed after admission: \(weight.path)")
            }
        }
    }

    static func estimate(largestWeight: UInt64, durationSeconds: Double) throws -> UInt64 {
        guard largestWeight > 0, durationSeconds.isFinite, durationSeconds > 0,
              durationSeconds.rounded(.up) <= Double(UInt64.max) else {
            throw InferenceFailure.invalidRequest("Audio resource estimate inputs are invalid.")
        }
        let seconds = UInt64(durationSeconds.rounded(.up))
        let (weights, weightOverflow) = largestWeight.multipliedReportingOverflow(by: 2)
        let (workspace, workspaceOverflow) = seconds.multipliedReportingOverflow(by: 64 * 1024 * 1024)
        let (base, baseOverflow) = weights.addingReportingOverflow(1024 * 1024 * 1024)
        let (total, totalOverflow) = base.addingReportingOverflow(workspace)
        guard !weightOverflow, !workspaceOverflow, !baseOverflow, !totalOverflow else {
            throw InferenceFailure.invalidRequest("Audio resource estimate exceeds UInt64 capacity.")
        }
        return total
    }
}

private struct AudioManifest {
    struct File {
        let path: String
        let size: UInt64
        let sha256: String
    }
    let files: [File]

    static func parse(_ data: Data, profile: AudioBackendProfile) throws -> Self {
        let root: AudioJSONValue
        do {
            var parser = AudioJSONParser(data: data, maximumDepth: 32)
            root = try parser.parse()
        } catch {
            throw InferenceFailure.invalidRequest("Invalid audio model manifest JSON: \(error.localizedDescription)")
        }
        let object = try root.object(exactKeys: ["schemaVersion", "repository", "revision", "files"],
                                     context: "audio manifest")
        guard try object["schemaVersion"]?.requiredInteger(context: "manifest schemaVersion") == 1,
              try object["repository"]?.requiredString(context: "manifest repository")
                == AudioModelInventory.repository,
              try object["revision"]?.requiredString(context: "manifest revision")
                == AudioModelInventory.revision,
              case .array(let entries)? = object["files"], entries.count == 4 else {
            throw InferenceFailure.invalidRequest(
                "Audio manifest must identify the pinned repository/revision and exactly four weights.")
        }

        var files: [File] = []
        for entry in entries {
            let item = try entry.object(exactKeys: ["path", "size", "sha256"], context: "manifest file")
            let path = try item["path"]!.requiredString(context: "manifest file path")
            let signedSize = try item["size"]!.requiredInteger(context: "manifest file size")
            let digest = try item["sha256"]!.requiredString(context: "manifest file SHA-256")
            guard signedSize > 0,
                  digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw InferenceFailure.invalidRequest("Invalid audio manifest size or SHA-256 for \(path).")
            }
            files.append(File(path: path, size: UInt64(signedSize), sha256: digest))
        }
        let codec = profile == .medium ? "same_l" : "same_s"
        let dit: String
        switch profile {
        case .smMusic: dit = "dit_sm-music_f16.npz"
        case .smSFX: dit = "dit_sm-sfx_f16.npz"
        case .medium: dit = "dit_medium_f16.npz"
        }
        let required = Set([
            "MLX/\(dit)", "MLX/t5gemma_f16.npz",
            "MLX/\(codec)_encoder_f32.npz", "MLX/\(codec)_decoder_f32.npz",
        ])
        guard Set(files.map(\.path)) == required, Set(files.map(\.path)).count == files.count else {
            throw InferenceFailure.invalidRequest(
                "Audio manifest does not contain exactly the four required \(profile.rawValue) weight paths.")
        }
        return Self(files: files)
    }
}

enum AudioJSONValue: Sendable, Equatable {
    case object([String: AudioJSONValue])
    case array([AudioJSONValue])
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Decimal)
    case bool(Bool)
    case null

    static func == (lhs: Self, rhs: Self) -> Bool {
        if let left = lhs.decimalNumber, let right = rhs.decimalNumber {
            return left == right
        }
        switch (lhs, rhs) {
        case (.object(let left), .object(let right)): return left == right
        case (.array(let left), .array(let right)): return left == right
        case (.string(let left), .string(let right)): return left == right
        case (.bool(let left), .bool(let right)): return left == right
        case (.null, .null): return true
        default: return false
        }
    }

    private var decimalNumber: Decimal? {
        switch self {
        case .integer(let value): return Decimal(value)
        case .unsignedInteger(let value):
            return Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
        case .number(let value): return value
        default: return nil
        }
    }

    func object(exactKeys: Set<String>, context: String) throws -> [String: AudioJSONValue] {
        guard case .object(let value) = self, Set(value.keys) == exactKeys else {
            throw InferenceFailure.invalidRequest("Unexpected keys or type in \(context).")
        }
        return value
    }

    func requiredString(context: String) throws -> String {
        guard case .string(let value) = self else {
            throw InferenceFailure.invalidRequest("\(context) must be a string.")
        }
        return value
    }

    func requiredInteger(context: String) throws -> Int64 {
        switch self {
        case .integer(let value): return value
        case .unsignedInteger(let value) where value <= UInt64(Int64.max): return Int64(value)
        default:
            throw InferenceFailure.invalidRequest("\(context) must be a representable integer, not a Boolean or floating value.")
        }
    }

    func requiredUInt64(context: String) throws -> UInt64 {
        switch self {
        case .integer(let value) where value >= 0: return UInt64(value)
        case .unsignedInteger(let value): return value
        default:
            throw InferenceFailure.invalidRequest("\(context) must be an unsigned integer, not a Boolean or floating value.")
        }
    }

    var nonnegativeNumber: Bool {
        guard let decimalNumber else { return false }
        return decimalNumber >= 0
    }
}

/// Small bounded RFC 8259 parser used before any Foundation object decoding. It preserves
/// integer-vs-Boolean types and compares decoded object keys, so `"path"` and `"p\u0061th"`
/// are correctly rejected as duplicates.
struct AudioJSONParser {
    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let bytes: [UInt8]
    private let maximumDepth: Int
    private var index = 0

    init(data: Data, maximumDepth: Int) {
        bytes = Array(data)
        self.maximumDepth = maximumDepth
    }

    mutating func parse() throws -> AudioJSONValue {
        guard !bytes.isEmpty else { throw ParseError(message: "Empty JSON input.") }
        skipWhitespace()
        let value = try parseValue(depth: 1)
        skipWhitespace()
        guard index == bytes.count else { throw ParseError(message: "Trailing JSON data.") }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> AudioJSONValue {
        guard depth <= maximumDepth, index < bytes.count else {
            throw ParseError(message: "JSON exceeds maximum depth or ends unexpectedly.")
        }
        switch bytes[index] {
        case 0x7B: return try parseObject(depth: depth)
        case 0x5B: return try parseArray(depth: depth)
        case 0x22: return .string(try parseString())
        case 0x74: try consume("true"); return .bool(true)
        case 0x66: try consume("false"); return .bool(false)
        case 0x6E: try consume("null"); return .null
        case 0x2D, 0x30...0x39: return try parseNumber()
        default: throw ParseError(message: "Unexpected JSON token at byte \(index).")
        }
    }

    private mutating func parseObject(depth: Int) throws -> AudioJSONValue {
        index += 1
        skipWhitespace()
        var result: [String: AudioJSONValue] = [:]
        if take(0x7D) { return .object(result) }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ParseError(message: "JSON object key must be a string.")
            }
            let key = try parseString()
            guard result[key] == nil else { throw ParseError(message: "Duplicate JSON object key: \(key)") }
            skipWhitespace()
            guard take(0x3A) else { throw ParseError(message: "Missing colon after JSON object key.") }
            skipWhitespace()
            result[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            if take(0x7D) { break }
            guard take(0x2C) else { throw ParseError(message: "Missing comma in JSON object.") }
            skipWhitespace()
        }
        return .object(result)
    }

    private mutating func parseArray(depth: Int) throws -> AudioJSONValue {
        index += 1
        skipWhitespace()
        var result: [AudioJSONValue] = []
        if take(0x5D) { return .array(result) }
        while true {
            result.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if take(0x5D) { break }
            guard take(0x2C) else { throw ParseError(message: "Missing comma in JSON array.") }
            skipWhitespace()
        }
        return .array(result)
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let encoded = Data(bytes[start..<index])
                do { return try JSONDecoder().decode(String.self, from: encoded) }
                catch { throw ParseError(message: "Invalid JSON string encoding.") }
            }
            guard byte >= 0x20 else { throw ParseError(message: "Control byte in JSON string.") }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { throw ParseError(message: "Truncated JSON escape.") }
                let escape = bytes[index]
                if escape == 0x75 {
                    guard index + 4 < bytes.count,
                          bytes[(index + 1)...(index + 4)].allSatisfy(Self.isHex) else {
                        throw ParseError(message: "Invalid JSON Unicode escape.")
                    }
                    index += 4
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) {
                    throw ParseError(message: "Invalid JSON escape.")
                }
            }
            index += 1
        }
        throw ParseError(message: "Unterminated JSON string.")
    }

    private mutating func parseNumber() throws -> AudioJSONValue {
        let start = index
        _ = take(0x2D)
        guard index < bytes.count else { throw ParseError(message: "Truncated JSON number.") }
        if take(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw ParseError(message: "Leading zero in JSON number.")
            }
        } else {
            guard takeDigit(1...9) else { throw ParseError(message: "Invalid JSON number.") }
            while takeDigit(0...9) {}
        }
        var integral = true
        if take(0x2E) {
            integral = false
            guard takeDigit(0...9) else { throw ParseError(message: "Missing JSON fraction digits.") }
            while takeDigit(0...9) {}
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            integral = false
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            guard takeDigit(0...9) else { throw ParseError(message: "Missing JSON exponent digits.") }
            while takeDigit(0...9) {}
        }
        guard let text = String(bytes: bytes[start..<index], encoding: .utf8) else {
            throw ParseError(message: "Invalid JSON number encoding.")
        }
        if integral {
            if let value = Int64(text) { return .integer(value) }
            if let value = UInt64(text) { return .unsignedInteger(value) }
            throw ParseError(message: "JSON integer is outside the signed/unsigned 64-bit range.")
        }
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else {
            throw ParseError(message: "JSON number is not finite or representable.")
        }
        return .number(value)
    }

    private mutating func consume(_ literal: StaticString) throws {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw ParseError(message: "Invalid JSON literal.")
        }
        index += expected.count
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func takeDigit(_ range: ClosedRange<Int>) -> Bool {
        guard index < bytes.count else { return false }
        let digit = Int(bytes[index]) - 48
        guard range.contains(digit) else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
