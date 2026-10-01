import Foundation
import Darwin
import CoreFoundation
import MLX
import MLXLMCommon
import MLXNN

/// Indexes tensor headers and opens only the shards needed by a resident stage or decoder layer.
/// No shard's array dictionary is retained after its selected tensors are evaluated.
final class Qwen35LayeredWeights {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return "Qwen3.5 layered weights: \(reason)" }
            return nil
        }
    }

    private struct Identity: Equatable {
        let size: UInt64
        let device: UInt64
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }
    private struct Entry {
        let file: URL
        let shape: [Int]
        let dtype: String
    }
    private let identity: [URL: Identity]
    private let entries: [String: Entry]
    private let metadata: [URL: [String: String]]
    private let indexURL: URL?
    private let indexIdentity: Identity?
    static let maximumHeaderBytes: UInt64 = 16 * 1024 * 1024
    static let maximumIndexBytes: UInt64 = 4 * 1024 * 1024

    static func readBounded(_ url: URL, maximum: UInt64) throws -> Data {
        let before = try identity(url)
        guard before.size <= maximum else { throw Failure.invalid("\(url.lastPathComponent) is too large") }
        let handle = try openVerified(url, expected: before)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: Int(before.size) + 1),
              UInt64(data.count) == before.size,
              try descriptorIdentity(handle) == before, try identity(url) == before else {
            throw Failure.invalid("\(url.lastPathComponent) changed while reading")
        }
        try hasUniqueObjectKeys(data)
        return data
    }

    static func readHeader(_ url: URL) throws -> (Data, UInt64) {
        let before = try identity(url)
        guard before.size >= 8 else { throw Failure.invalid("short safetensors header") }
        let handle = try openVerified(url, expected: before)
        defer { try? handle.close() }
        guard let lengthBytes = try handle.read(upToCount: 8), lengthBytes.count == 8 else {
            throw Failure.invalid("short safetensors header")
        }
        let length = lengthBytes.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        guard length > 0, length <= maximumHeaderBytes, length <= before.size - 8,
              let data = try handle.read(upToCount: Int(length)), data.count == Int(length),
              try descriptorIdentity(handle) == before, try identity(url) == before,
              try hasUniqueObjectKeys(data) else {
            throw Failure.invalid("invalid safetensors header")
        }
        return (data, before.size - 8 - length)
    }

    static func identityToken(_ url: URL) throws -> String {
        let value = try identity(url)
        return "\(value.device):\(value.inode):\(value.size):" +
            "\(value.modifiedSeconds):\(value.modifiedNanoseconds):" +
            "\(value.changedSeconds):\(value.changedNanoseconds)"
    }

    /// Test seam after selection and before lazy MLX arrays are evaluated.
    var beforeSelectedEvaluation: (() throws -> Void)?

    init(directory: URL) throws {
        _ = try Self.identity(directory, directory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "safetensors" }.sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw Failure.invalid("no safetensors shards") }
        var identities: [URL: Identity] = [:]
        var entries: [String: Entry] = [:]
        var metadata: [URL: [String: String]] = [:]
        for file in files {
            try Task.checkCancellation()
            identities[file] = try Self.identity(file)
            let handle = try Self.openVerified(file, expected: identities[file]!)
            defer { try? handle.close() }
            guard identities[file]!.size >= 8 else {
                throw Failure.invalid("short header in \(file.lastPathComponent)")
            }
            guard let lengthBytes = try handle.read(upToCount: 8), lengthBytes.count == 8 else {
                throw Failure.invalid("short header in \(file.lastPathComponent)")
            }
            let length = lengthBytes.enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << ($1.offset * 8))
            }
            guard length > 0, length <= Self.maximumHeaderBytes,
                  length <= identities[file]!.size - 8,
                  let data = try handle.read(upToCount: Int(length)), data.count == Int(length),
                  try Self.descriptorIdentity(handle) == identities[file],
                  try Self.identity(file) == identities[file],
                  try Self.hasUniqueObjectKeys(data),
                  let header = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.invalid("invalid header in \(file.lastPathComponent)")
            }
            if header["__metadata__"] != nil,
               !(header["__metadata__"] is [String: String]) {
                throw Failure.invalid("invalid safetensors metadata")
            }
            metadata[file] = header["__metadata__"] as? [String: String] ?? [:]
            for (key, value) in header where key != "__metadata__" &&
                !key.contains("position_ids") && !key.contains("mtp.") {
                guard let tensor = value as? [String: Any],
                      let dtype = tensor["dtype"] as? String, dtype == "BF16",
                      let shape = Self.strictDimensions(tensor["shape"]),
                      let offsets = Self.strictOffsets(tensor["data_offsets"]),
                      offsets[0] < offsets[1], offsets[1] <= identities[file]!.size - 8 - length,
                      Self.validByteCount(shape: shape, offsets: offsets),
                      entries[key] == nil else {
                    throw Failure.invalid("unsupported or duplicate tensor \(key)")
                }
                entries[key] = Entry(file: file, shape: shape, dtype: dtype)
            }
            var ranges: [(UInt64, UInt64)] = []
            for (key, value) in header where key != "__metadata__" {
                guard let tensor = value as? [String: Any],
                      Self.strictDimensions(tensor["shape"]) != nil,
                      let offsets = Self.strictOffsets(tensor["data_offsets"]),
                      offsets[0] < offsets[1],
                      offsets[1] <= identities[file]!.size - 8 - length else {
                    throw Failure.invalid("invalid tensor bounds in \(file.lastPathComponent)")
                }
                ranges.append((offsets[0], offsets[1]))
            }
            ranges.sort { $0.0 < $1.0 }
            if ranges.count > 1 {
                for index in 1..<ranges.count where ranges[index].0 < ranges[index - 1].1 {
                    throw Failure.invalid("overlapping tensor offsets in \(file.lastPathComponent)")
                }
            }
        }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        var indexIdentity: Identity?
        var indexStat = stat()
        if lstat(index.path, &indexStat) == 0 {
            indexIdentity = try Self.identity(index)
            let data = try Self.readBounded(index, maximum: Self.maximumIndexBytes)
            guard try Self.identity(index) == indexIdentity else {
                throw Failure.invalid("safetensors index changed while reading")
            }
            guard try Self.hasUniqueObjectKeys(data),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = object["weight_map"] as? [String: String] else {
                throw Failure.invalid("incomplete safetensors index")
            }
            for (key, entry) in entries where map[key] != entry.file.lastPathComponent {
                throw Failure.invalid("wrong shard for \(key)")
            }
            for key in map.keys where entries[key] == nil &&
                !key.contains("position_ids") && !key.contains("mtp.") {
                throw Failure.invalid("index references unknown tensor \(key)")
            }
        }
        self.identity = identities
        self.entries = entries
        self.metadata = metadata
        self.indexURL = indexIdentity == nil ? nil : index
        self.indexIdentity = indexIdentity
    }

    private static func identity(_ url: URL, directory: Bool = false) throws -> Identity {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              directory ? (value.st_mode & S_IFMT == S_IFDIR) : (value.st_mode & S_IFMT == S_IFREG),
              value.st_size >= 0 else {
            throw Failure.invalid("cannot identify \(url.lastPathComponent)")
        }
        return identity(value)
    }

    private static func identity(_ value: stat) -> Identity {
        Identity(size: UInt64(value.st_size), device: UInt64(value.st_dev),
                        inode: UInt64(value.st_ino), modifiedSeconds: value.st_mtimespec.tv_sec,
                        modifiedNanoseconds: value.st_mtimespec.tv_nsec,
                        changedSeconds: value.st_ctimespec.tv_sec,
                        changedNanoseconds: value.st_ctimespec.tv_nsec)
    }

    private static func descriptorIdentity(_ handle: FileHandle) throws -> Identity {
        var value = stat()
        guard fstat(handle.fileDescriptor, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else {
            throw Failure.invalid("file descriptor changed")
        }
        return identity(value)
    }

    private static func openVerified(_ url: URL, expected: Identity) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalid("cannot open \(url.lastPathComponent)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard try descriptorIdentity(handle) == expected, try identity(url) == expected else {
            try? handle.close()
            throw Failure.invalid("\(url.lastPathComponent) changed before reading")
        }
        return handle
    }

    static func strictInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["q", "Q", "i", "I", "l", "L", "s", "S"].contains(String(cString: number.objCType)) else {
            return nil
        }
        return UInt64(number.stringValue)
    }

    static func strictDimensions(_ value: Any?) -> [Int]? {
        guard let values = value as? [Any], !values.isEmpty, values.count <= 8 else { return nil }
        var result: [Int] = []
        var elements: UInt64 = 1
        for value in values {
            guard let number = strictInteger(value), number > 0,
                  number <= UInt64(Int32.max) else { return nil }
            let (next, overflow) = elements.multipliedReportingOverflow(by: number)
            guard !overflow, next <= UInt64(Int32.max) else { return nil }
            elements = next
            result.append(Int(number))
        }
        return result
    }

    static func strictOffsets(_ value: Any?) -> [UInt64]? {
        guard let values = value as? [Any], values.count == 2,
              let start = strictInteger(values[0]),
              let end = strictInteger(values[1]) else { return nil }
        return [start, end]
    }

    static func hasUniqueObjectKeys(_ data: Data) throws -> Bool {
        var scanner = JSONKeyScanner(bytes: Array(data), position: 0)
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.position == data.count else { throw Failure.invalid("invalid JSON suffix") }
        return true
    }

    private struct JSONKeyScanner {
        let bytes: [UInt8]
        var position: Int

        mutating func whitespace() {
            while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) {
                position += 1
            }
        }

        mutating func string() throws -> String {
            whitespace()
            guard position < bytes.count, bytes[position] == 34 else {
                throw Failure.invalid("invalid JSON string")
            }
            let start = position
            position += 1
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 92 {
                    guard position < bytes.count else { break }
                    position += 1
                } else if byte == 34 {
                    return try JSONDecoder().decode(String.self,
                        from: Data(bytes[start..<position]))
                }
            }
            throw Failure.invalid("unterminated JSON string")
        }

        mutating func value(depth: Int) throws {
            whitespace()
            guard depth <= 64, position < bytes.count else {
                throw Failure.invalid("invalid JSON nesting")
            }
            switch bytes[position] {
            case 123:
                position += 1
                var keys = Set<String>()
                whitespace()
                if position < bytes.count, bytes[position] == 125 { position += 1; return }
                while true {
                    let key = try string()
                    guard keys.insert(key).inserted else {
                        throw Failure.invalid("duplicate JSON object key: \(key)")
                    }
                    whitespace()
                    guard position < bytes.count, bytes[position] == 58 else {
                        throw Failure.invalid("invalid JSON object")
                    }
                    position += 1
                    try value(depth: depth + 1)
                    whitespace()
                    guard position < bytes.count else { throw Failure.invalid("short JSON object") }
                    let delimiter = bytes[position]
                    position += 1
                    if delimiter == 125 { return }
                    guard delimiter == 44 else { throw Failure.invalid("invalid JSON object delimiter") }
                }
            case 91:
                position += 1
                whitespace()
                if position < bytes.count, bytes[position] == 93 { position += 1; return }
                while true {
                    try value(depth: depth + 1)
                    whitespace()
                    guard position < bytes.count else { throw Failure.invalid("short JSON array") }
                    let delimiter = bytes[position]
                    position += 1
                    if delimiter == 93 { return }
                    guard delimiter == 44 else { throw Failure.invalid("invalid JSON array delimiter") }
                }
            case 34:
                _ = try string()
            default:
                let start = position
                while position < bytes.count && ![44, 93, 125, 9, 10, 13, 32].contains(bytes[position]) {
                    position += 1
                }
                guard position > start else { throw Failure.invalid("invalid JSON value") }
            }
        }
    }

    private static func validByteCount(shape: [Int], offsets: [UInt64]) -> Bool {
        var bytes: UInt64 = 2 // BF16
        for dimension in shape {
            let (next, overflow) = bytes.multipliedReportingOverflow(by: UInt64(dimension))
            if overflow { return false }
            bytes = next
        }
        return bytes == offsets[1] - offsets[0]
    }

    private func selected(_ choose: (String) -> Bool, model: Qwen35) throws -> ([String: MLXArray], [URL]) {
        try verifyIndex()
        var byShard: [URL: [String]] = [:]
        for key in entries.keys where choose(key) {
            byShard[entries[key]!.file, default: []].append(key)
        }
        guard !byShard.isEmpty else { throw Failure.invalid("requested weight stage is missing") }
        var result: [String: MLXArray] = [:]
        for file in byShard.keys.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard try Self.identity(file) == identity[file] else {
                throw Failure.invalid("shard changed: \(file.lastPathComponent)")
            }
            let arrays = try loadArrays(url: file)
            var slice: [String: MLXArray] = [:]
            for key in byShard[file]! {
                guard let array = arrays[key], array.dtype == .bfloat16,
                      array.shape == entries[key]!.shape else {
                    throw Failure.invalid("tensor changed or missing: \(key)")
                }
                slice[key] = array
            }
            let sanitized = model.sanitize(weights: slice, metadata: metadata[file] ?? [:])
            for (key, array) in sanitized {
                guard result[key] == nil else { throw Failure.invalid("sanitized key collision: \(key)") }
                result[key] = array
            }
        }
        return (result, byShard.keys.sorted(by: { $0.path < $1.path }))
    }

    func loadResident(into model: Qwen35) throws {
        let (weights, files) = try selected({ !Self.isDecoderKey($0) &&
            !Self.normalized($0).hasPrefix("vision_tower.") }, model: model)
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        try beforeSelectedEvaluation?()
        try checkedEval(model)
        try verify(files)
    }

    func loadLayer(_ index: Int, into layer: Qwen35Language.DecoderLayer,
                   model: Qwen35) throws {
        let prefix = "language_model.model.layers.\(index)."
        let (weights, files) = try selected({ Self.normalized($0).hasPrefix(prefix) }, model: model)
        var local: [String: MLXArray] = [:]
        for (key, value) in weights {
            guard key.hasPrefix(prefix) else { throw Failure.invalid("wrong layer key \(key)") }
            local[String(key.dropFirst(prefix.count))] = value
        }
        try layer.update(parameters: ModuleParameters.unflattened(local), verify: [.all])
        try beforeSelectedEvaluation?()
        try checkedEval(layer)
        try verify(files)
    }

    func loadVisionPart(_ prefix: String, into part: Module, model: Qwen35) throws {
        let fullPrefix = "vision_tower." + prefix + "."
        let (weights, files) = try selected({ Self.normalized($0).hasPrefix(fullPrefix) }, model: model)
        var local: [String: MLXArray] = [:]
        for (key, value) in weights {
            guard key.hasPrefix(fullPrefix) else { throw Failure.invalid("wrong vision key \(key)") }
            local[String(key.dropFirst(fullPrefix.count))] = value
        }
        try part.update(parameters: ModuleParameters.unflattened(local), verify: [.all])
        try beforeSelectedEvaluation?()
        try checkedEval(part)
        try verify(files)
    }

    private func verify(_ files: [URL]) throws {
        try Task.checkCancellation()
        try verifyIndex()
        for file in files {
            guard try Self.identity(file) == identity[file] else {
                throw Failure.invalid("shard changed during evaluation: \(file.lastPathComponent)")
            }
        }
    }

    private func verifyIndex() throws {
        if let indexURL, let indexIdentity {
            guard try Self.identity(indexURL) == indexIdentity else {
                throw Failure.invalid("safetensors index changed during loading")
            }
        } else if let firstShard = identity.keys.first {
            let index = firstShard.deletingLastPathComponent()
                .appendingPathComponent("model.safetensors.index.json")
            var value = stat()
            guard lstat(index.path, &value) != 0 else {
                throw Failure.invalid("safetensors index appeared during loading")
            }
        }
    }

    private static func isDecoderKey(_ key: String) -> Bool {
        normalized(key).hasPrefix("language_model.model.layers.")
    }

    private static func normalized(_ key: String) -> String {
        if key.hasPrefix("model.language_model.") {
            return "language_model.model." + String(key.dropFirst("model.language_model.".count))
        }
        if key.hasPrefix("model.visual.") {
            return "vision_tower." + String(key.dropFirst("model.visual.".count))
        }
        if key.hasPrefix("model.") { return "language_model." + key }
        if key.hasPrefix("lm_head.") { return "language_model." + key }
        return key
    }
}

/// Shared narrow header rules used by the loader and the resource estimator.
public enum Qwen35LayeredFileValidation {
    public static func header(_ url: URL) throws -> (Data, UInt64) {
        try Qwen35LayeredWeights.readHeader(url)
    }
    public static func dimensions(_ value: Any?) -> [Int]? {
        Qwen35LayeredWeights.strictDimensions(value)
    }
    public static func offsets(_ value: Any?) -> [UInt64]? {
        Qwen35LayeredWeights.strictOffsets(value)
    }
    public static func uniqueJSON(_ data: Data) throws {
        _ = try Qwen35LayeredWeights.hasUniqueObjectKeys(data)
    }
    public static func identity(_ url: URL) throws -> String {
        try Qwen35LayeredWeights.identityToken(url)
    }
}
