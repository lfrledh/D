import DInference
import Foundation

/// Reads metadata and sizes only. No MLX allocation or network access is permitted here.
struct LocalModelInventory: Sendable {
    let directory: URL
    let weightBytes: UInt64
    let estimatedPeakBytes: UInt64
    let contextLimit: Int

    private struct Configuration: Decodable {
        let model_type: String
        let hidden_size: Int
        let num_hidden_layers: Int
        let num_attention_heads: Int
        let num_key_value_heads: Int
        let max_position_embeddings: Int
        let vocab_size: Int
        let intermediate_size: Int
        let rms_norm_eps: Float?
        let rope_theta: Float?
        let rope_scaling: RopeScaling?
        let quantization: Quantization?
    }

    private struct RopeScaling: Decodable {
        let type: String?
        let factor: Float?
    }

    private struct Quantization: Decodable {
        let groupSize: Int
        let bits: Int
        let mode: String?

        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            guard values.allKeys.allSatisfy({ ["group_size", "bits", "mode"].contains($0.stringValue) }) else {
                throw InferenceFailure.invalidRequest("Per-layer quantization is not supported by this backend.")
            }
            groupSize = try values.decode(Int.self, forKey: Key(stringValue: "group_size"))
            bits = try values.decode(Int.self, forKey: Key(stringValue: "bits"))
            mode = try values.decodeIfPresent(String.self, forKey: Key(stringValue: "mode"))
        }
    }

    static func inspect(_ request: InferenceRequest, limits: MLXBackendConfiguration) throws -> Self {
        try request.validate()
        guard case .text(let input) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        guard input.maxTokens <= limits.maximumOutputTokens,
              input.prompt.utf8.count <= 1_048_576 else {
            throw InferenceFailure.invalidRequest("Text exceeds the backend's configured input/output limits.")
        }
        let directory = request.model.directory.standardizedFileURL
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InferenceFailure.invalidRequest("Model directory does not exist: \(directory.path)")
        }
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            let url = directory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 128 * 1024 * 1024 else {
                throw InferenceFailure.invalidRequest("Model metadata must be a nonempty regular file: \(name)")
            }
        }
        let configURL = directory.appendingPathComponent("config.json")
        guard let configSize = try configURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              configSize <= 1_048_576 else {
            throw InferenceFailure.invalidRequest("Model config.json is too large.")
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        // Deliberately support one validated family in this reference implementation.
        // Each new family needs its own memory estimate and real-model acceptance evidence.
        guard config.model_type == "qwen2" else {
            throw InferenceFailure.invalidRequest("This backend currently supports the qwen2 model family.")
        }
        guard (1...128).contains(config.num_hidden_layers),
              (1...32768).contains(config.hidden_size),
              (1...256).contains(config.num_attention_heads),
              (1...config.num_attention_heads).contains(config.num_key_value_heads),
              config.num_attention_heads % config.num_key_value_heads == 0,
              config.hidden_size % config.num_attention_heads == 0,
              (config.hidden_size / config.num_attention_heads) % 2 == 0,
              (1...1_048_576).contains(config.vocab_size),
              (1...262_144).contains(config.intermediate_size),
              config.max_position_embeddings > input.maxTokens else {
            throw InferenceFailure.invalidRequest("Unsupported or inconsistent model dimensions.")
        }
        for value in [config.rms_norm_eps, config.rope_theta].compactMap({ $0 }) {
            guard value.isFinite, value > 0 else {
                throw InferenceFailure.invalidRequest("Invalid normalization or rotary position parameters.")
            }
        }
        if let scaling = config.rope_scaling {
            guard scaling.type == "linear", let factor = scaling.factor, factor.isFinite, factor > 0 else {
                throw InferenceFailure.invalidRequest("Only positive, finite linear rope_scaling is supported.")
            }
        }
        if let quantization = config.quantization {
            guard quantization.bits == 4, quantization.groupSize == 64,
                  quantization.mode == nil || quantization.mode == "affine",
                  config.hidden_size % 64 == 0, config.intermediate_size % 64 == 0 else {
                throw InferenceFailure.invalidRequest("This backend supports flat affine 4-bit quantization with group_size 64.")
            }
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        // Match the upstream loader's recursive weight discovery; reject indirection rather
        // than estimating one file tree and then letting the loader traverse a different one.
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                  options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else {
            throw InferenceFailure.invalidRequest("Cannot enumerate the model directory.")
        }
        var weightBytes: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw InferenceFailure.invalidRequest("Model directory must not contain symbolic links.")
            }
            if url.pathExtension == "safetensors" {
                guard values.isRegularFile == true, let size = values.fileSize, size > 8 else {
                    throw InferenceFailure.invalidRequest("Invalid safetensors weight file.")
                }
                let (sum, overflow) = weightBytes.addingReportingOverflow(UInt64(size))
                guard !overflow, sum <= 128 * 1024 * 1024 * 1024 else {
                    throw InferenceFailure.invalidRequest("Model weight files exceed the supported size.")
                }
                weightBytes = sum
            }
        }
        if let enumerationError { throw enumerationError }
        guard weightBytes > 0 else { throw InferenceFailure.invalidRequest("No safetensors weights found.") }
        let context = min(limits.maximumPromptTokens + input.maxTokens, config.max_position_embeddings)
        // Conservative f32 KV accounting plus transient weight copy, workspace and allocator cache.
        // This is an admission estimate, not a hard protection against process/system OOM.
        let kvBytes = UInt64(context) * UInt64(config.num_hidden_layers)
            * UInt64(config.num_key_value_heads) * UInt64(config.hidden_size / config.num_attention_heads) * 2 * 4
        let estimate = weightBytes * 2 + kvBytes + 512 * 1024 * 1024 + UInt64(limits.cacheLimitBytes)
        return Self(directory: directory, weightBytes: weightBytes,
                    estimatedPeakBytes: estimate, contextLimit: config.max_position_embeddings)
    }
}
