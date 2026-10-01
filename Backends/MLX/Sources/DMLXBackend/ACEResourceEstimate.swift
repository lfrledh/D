import DInference
import Darwin
import Foundation

/// Residency estimate for the complete F32 pipeline, independent of host RAM.
/// This is an admission estimate, not a physical cap or a reason to quantize.
enum ACEResourceEstimate {
    static func layered(root: URL, files: [ACEModelInventory.AdmittedFile], duration: Double,
                        guidance: Float) throws -> UInt64 {
        guard duration.isFinite, duration > 0, duration <= 600, guidance.isFinite, guidance >= 0 else {
            throw InferenceFailure.invalidRequest("Invalid ACE estimate input.")
        }
        var resident: UInt64 = 0, conditions: UInt64 = 0, embedding: UInt64 = 0, vae: UInt64 = 0
        var layers: [String: UInt64] = [:]
        for admitted in files where admitted.file.path.hasSuffix(".safetensors") {
            try Task.checkCancellation()
            let file = admitted.file
            let tensors = try tensorElementCounts(at: root.appendingPathComponent(file.path), expected: admitted.identity)
            for (name, count) in tensors {
                let bytes = try multiply(count, 4)
                switch file.role {
                case "embedding": embedding = try add(embedding, bytes)
                case "vae": vae = try add(vae, bytes)
                case "xl":
                    if name.hasPrefix("decoder.layers.") {
                        let parts = name.split(separator: ".")
                        guard parts.count > 3 else { throw InferenceFailure.invalidRequest("Invalid ACE decoder key.") }
                        let key = String(parts[2])
                        layers[key] = try add(layers[key, default: 0], bytes)
                    } else if name.hasPrefix("decoder.") {
                        resident = try add(resident, bytes)
                    } else { conditions = try add(conditions, bytes) }
                default: throw InferenceFailure.invalidRequest("Unknown ACE resource role.")
                }
            }
        }
        guard let largest = layers.values.max(), Set(layers.keys) == Set((0..<32).map(String.init)) else {
            throw InferenceFailure.invalidRequest("ACE XL complete 32-layer inventory is required.")
        }
        // Both VAE copies are kept for official offload/dtype compatibility.
        let shared = try add(resident, multiply(vae, 2))
        let encode = try add(shared, add(conditions, embedding))
        let diffusion = try add(shared, multiply(largest, 2))
        // 25 Hz latents, patch size 2; official sliding mask is still dense.
        let sequence = UInt64(ceil(max(duration, 5.12) * 12.5))
        let mask = try multiply(multiply(sequence, sequence), 4)
        // Official CFG disables cross-attention caching. Without CFG, retain all
        // 32 layers' K/V up to the fixed caption+lyrics token bounds.
        let kv: UInt64 = guidance > 1 ? 0 : 262_144 * (256 + 2048)
        let activationsAndAllocator: UInt64 = 2 * 1024 * 1024 * 1024
        return try add(max(encode, diffusion), add(activationsAndAllocator, add(mask, kv)))
    }

    /// Header-only read with checked arithmetic. Never calls an MLX loader.
    static func tensorElementCounts(at url: URL, expected: AudioFileSystem.Identity) throws -> [String: UInt64] {
        let before = try AudioFileSystem.regularFile(url, label: "ACE tensor metadata", maximumBytes: nil)
        guard before == expected, before.size >= 8 else { throw InferenceFailure.inputIntegrityChanged("ACE weights changed before metadata read.") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw InferenceFailure.invalidRequest("Cannot open ACE tensor metadata.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0, AudioFileSystem.Identity(st) == expected else {
            throw InferenceFailure.inputIntegrityChanged("ACE tensor location changed.")
        }
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else { throw InferenceFailure.invalidRequest("Truncated ACE tensor header.") }
        let length = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard length > 0, length <= 16 * 1_048_576, length <= UInt64(before.size - 8),
              let bytes = try handle.read(upToCount: Int(length)), bytes.count == Int(length) else {
            throw InferenceFailure.invalidRequest("Invalid ACE tensor header length.")
        }
        var parser = AudioJSONParser(data: bytes, maximumDepth: 8)
        let objects = try parser.parse().objectAny(context: "ACE tensor header")
        let payloadBytes = UInt64(before.size - 8) - length
        var result: [String: UInt64] = [:]
        for (name, value) in objects where name != "__metadata__" {
            try Task.checkCancellation()
            let item = try value.object(exactKeys: ["dtype", "shape", "data_offsets"], context: "ACE tensor")
            guard let dtype = try item["dtype"]?.requiredString(context: "dtype"),
                  let elementBytes = ["F32": UInt64(4), "F16": 2, "BF16": 2, "F64": 8][dtype],
                  case .array(let shape)? = item["shape"], shape.count <= 32,
                  case .array(let offsets)? = item["data_offsets"], offsets.count == 2 else {
                throw InferenceFailure.invalidRequest("Unsupported ACE tensor metadata.")
            }
            var count: UInt64 = 1
            for dimension in shape { count = try multiply(count, dimension.requiredUInt64(context: "shape")) }
            let start = try offsets[0].requiredUInt64(context: "offset"), end = try offsets[1].requiredUInt64(context: "offset")
            guard end >= start, end <= payloadBytes, end - start == (try multiply(count, elementBytes)) else {
                throw InferenceFailure.invalidRequest("ACE tensor shape and byte range disagree.")
            }
            result[name] = count
        }
        guard !result.isEmpty, Darwin.fstat(fd, &st) == 0, AudioFileSystem.Identity(st) == expected,
              try AudioFileSystem.regularFile(url, label: "ACE tensor metadata", maximumBytes: nil) == expected else {
            throw InferenceFailure.inputIntegrityChanged("ACE weights changed during metadata read.")
        }
        return result
    }

    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw InferenceFailure.invalidRequest("ACE residency estimate overflow.") }
        return value
    }
    private static func multiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw InferenceFailure.invalidRequest("ACE residency estimate overflow.") }
        return value
    }
}
