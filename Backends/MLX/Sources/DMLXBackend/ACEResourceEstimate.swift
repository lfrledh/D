import DInference
import Flux2
import Foundation

/// Residency estimate for the complete F32 pipeline, independent of host RAM.
/// This is an admission estimate, not a physical cap or a reason to quantize.
enum ACEResourceEstimate {
    static func layered(root: URL, files: [ACEModelInventory.File], duration: Double,
                        guidance: Float) throws -> UInt64 {
        var resident: UInt64 = 0, conditions: UInt64 = 0, embedding: UInt64 = 0, vae: UInt64 = 0
        var layers: [String: UInt64] = [:]
        for file in files where file.path.hasSuffix(".safetensors") {
            try Task.checkCancellation()
            // Files were digest-verified by the inventory; read metadata, no MLX arrays.
            let reader = try SafeTensorsReader(fileURL: root.appendingPathComponent(file.path))
            for tensor in reader.allMetadata() {
                let bytes = try multiply(UInt64(tensor.elementCount), 4)
                switch file.role {
                case "embedding": embedding = try add(embedding, bytes)
                case "vae": vae = try add(vae, bytes)
                case "xl":
                    if tensor.name.hasPrefix("decoder.layers.") {
                        let parts = tensor.name.split(separator: ".")
                        guard parts.count > 3 else { throw InferenceFailure.invalidRequest("Invalid ACE decoder key.") }
                        let key = String(parts[2])
                        layers[key] = try add(layers[key, default: 0], bytes)
                    } else if tensor.name.hasPrefix("decoder.") {
                        resident = try add(resident, bytes)
                    } else { conditions = try add(conditions, bytes) }
                default: throw InferenceFailure.invalidRequest("Unknown ACE resource role.")
                }
            }
        }
        guard let largest = layers.values.max(), layers.count == 32 else {
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
