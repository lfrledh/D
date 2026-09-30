import CoreFoundation
import DInference
import Foundation

/// Local metadata inspection. No MLX allocation or network access occurs here.
public struct QwenVLMModelInventory: Sendable {
    public let directory: URL
    public let family: String
    public let size: String
    public let contextLimit: Int
    public let weightBytes: UInt64
    public let minimumPixels: Int
    public let maximumPixels: Int

    static func inspect(_ request: InferenceRequest, capability: TextExecutionCapability) throws -> Self {
        try request.validate()
        guard case .text(let text) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        try capability.validate(text)
        guard text.resolvedMessages.contains(where: { message in
            message.parts.contains { part in
                switch part {
                case .text(let value): !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .image, .video: true
                }
            } || message.toolCalls != nil
        }) else {
            throw InferenceFailure.invalidRequest("VLM request needs text or visual input, and text is limited to 1 MiB.")
        }
        let inventory = try validateModel(at: request.model.directory)
        _ = try QwenMessageMapping.context(for: text.thinking, modelSize: inventory.size)
        let prompt = try capability.resolvedPromptTokens(for: text)
        guard prompt <= inventory.contextLimit,
              text.maxTokens <= inventory.contextLimit - prompt else {
            throw InferenceFailure.invalidRequest("Configured tokens exceed model context.")
        }
        return inventory
    }

    public static func validateModel(at location: URL) throws -> Self {
        let directory = try AudioFileSystem.absoluteLocal(location, label: "VLM model")
        try AudioFileSystem.validateDirectory(directory, label: "VLM model")
        for name in ["config.json", "preprocessor_config.json", "tokenizer.json", "tokenizer_config.json"] {
            _ = try AudioFileSystem.regularFile(directory.appendingPathComponent(name), label: name,
                                                maximumBytes: name == "tokenizer.json" ? 128 * 1024 * 1024 : 4 * 1024 * 1024)
        }
        let (configData, _) = try AudioFileSystem.readRegularFile(directory.appendingPathComponent("config.json"),
                                                                  label: "VLM config", maximumBytes: 4 * 1024 * 1024)
        let config = try object(configData)
        guard config["model_type"] as? String == "qwen3_5",
              (config["architectures"] as? [String]) == ["Qwen3_5ForConditionalGeneration"],
              let text = config["text_config"] as? [String: Any],
              let vision = config["vision_config"] as? [String: Any],
              text["model_type"] as? String == "qwen3_5_text",
              vision["model_type"] as? String == "qwen3_5" else {
            throw InferenceFailure.invalidRequest("Unsupported VLM architecture.")
        }
        let hidden = try integer(text, "hidden_size")
        let layers = try integer(text, "num_hidden_layers")
        let size: String
        switch (hidden, layers) {
        case (4096, 32): size = "9B"
        case (5120, 64): size = "27B"
        default: throw InferenceFailure.invalidRequest("Unsupported Qwen3.5 dimensions.")
        }
        try validateOutputGateType(text, size: size)
        let context = try integer(text, "max_position_embeddings")
        guard context > 0, context <= 262_144,
              try integer(text, "vocab_size") == 248_320,
              try integer(text, "head_dim") == 256,
              try integer(text, "num_key_value_heads") == 4,
              try integer(text, "num_attention_heads") == (size == "9B" ? 16 : 24),
              try integer(text, "intermediate_size") == (size == "9B" ? 12_288 : 17_408),
              try integer(text, "linear_num_value_heads") == (size == "9B" ? 32 : 48),
              try validAttentionLayout(text, layers: layers),
              try integer(vision, "out_hidden_size") == hidden,
              try integer(vision, "hidden_size") == 1152,
              try integer(vision, "intermediate_size") == 4304,
              try integer(vision, "num_heads") == 16,
              try integer(vision, "num_position_embeddings") == 2304,
              try integer(vision, "in_channels") == 3,
              try integer(vision, "patch_size") == 16,
              try integer(vision, "spatial_merge_size") == 2,
              try integer(vision, "temporal_patch_size") == 2,
              try integer(vision, "depth") == 27 else {
            throw InferenceFailure.invalidRequest("Inconsistent Qwen3.5 text or vision dimensions.")
        }
        if text["dtype"] as? String != "bfloat16" {
            throw InferenceFailure.invalidRequest("Unsupported Qwen3.5 weight dtype.")
        }
        if let format = config["quantization_config"] {
            guard let advertised = format as? [String: Any],
                  let actual = config["quantization"] as? [String: Any],
                  try integer(advertised, "group_size") == integer(actual, "group_size"),
                  try integer(advertised, "bits") == integer(actual, "bits"),
                  (advertised["mode"] as? String ?? "affine") == (actual["mode"] as? String ?? "affine") else {
                throw InferenceFailure.invalidRequest("Quantization metadata disagrees with the MLX loader configuration.")
            }
        }
        if let quant = config["quantization"] {
            guard let quant = quant as? [String: Any] else {
                throw InferenceFailure.invalidRequest("Invalid quantization object.")
            }
            try validateQuantization(quant)
        }
        let (processorData, _) = try AudioFileSystem.readRegularFile(
            directory.appendingPathComponent("preprocessor_config.json"), label: "VLM preprocessor",
            maximumBytes: 4 * 1024 * 1024)
        let budgets = try QwenVLMProcessorConfiguration.normalized(processorData, overrides: nil)
        let manager = FileManager.default
        var enumerationError: Error?
        guard let files = manager.enumerator(at: directory,
                                             includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                             errorHandler: { _, error in enumerationError = error; return false }) else {
            throw InferenceFailure.invalidRequest("Cannot enumerate VLM model directory.")
        }
        var bytes: UInt64 = 0
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                throw InferenceFailure.invalidRequest("VLM model contains a symbolic link.")
            }
            if url.pathExtension == "safetensors" {
                guard values.isRegularFile == true, let length = values.fileSize, length > 8 else {
                    throw InferenceFailure.invalidRequest("Invalid safetensors weight file.")
                }
                let (sum, overflow) = bytes.addingReportingOverflow(UInt64(length))
                guard !overflow else { throw InferenceFailure.invalidRequest("Weight size overflow.") }
                bytes = sum
            }
        }
        if let enumerationError { throw enumerationError }
        guard bytes > 0 else { throw InferenceFailure.invalidRequest("No VLM weights found.") }
        return Self(directory: directory, family: "qwen3_5", size: size, contextLimit: context,
                    weightBytes: bytes, minimumPixels: budgets.minimum, maximumPixels: budgets.maximum)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InferenceFailure.invalidRequest("VLM configuration must be a JSON object.")
        }
        return result
    }

    static func integer(_ object: [String: Any], _ name: String) throws -> Int {
        guard let number = object[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              NSNumber(value: number.intValue) == number else {
            throw InferenceFailure.invalidRequest("Missing or invalid \(name).")
        }
        return number.intValue
    }

    static func validAttentionLayout(_ text: [String: Any], layers: Int) throws -> Bool {
        let interval = text["full_attention_interval"] == nil
            ? 4 : try integer(text, "full_attention_interval")
        guard interval == 4, let types = text["layer_types"] as? [String],
              types.count == layers else { return false }
        return types.enumerated().allSatisfy { index, type in
            type == ((index + 1) % 4 == 0 ? "full_attention" : "linear_attention")
        }
    }

    static func validateOutputGateType(_ text: [String: Any], size: String) throws {
        if text["output_gate_type"] == nil, size == "9B" { return }
        guard let gate = text["output_gate_type"] as? String,
              (size == "9B" && gate == "sigmoid") ||
              (size == "27B" && gate == "swish") else {
            throw InferenceFailure.invalidRequest("Unsupported Qwen3.5 output gate type for model size.")
        }
    }

    private static func validateQuantization(_ value: [String: Any]) throws {
        guard try integer(value, "group_size") == 64,
              [4, 8].contains(try integer(value, "bits")),
              (value["mode"] as? String ?? "affine") == "affine" else {
            throw InferenceFailure.invalidRequest("Only affine 4/8-bit Qwen3.5 weights are adapted.")
        }
        for (key, item) in value where !["group_size", "bits", "mode"].contains(key) {
            if let skip = item as? Bool, skip == false { continue }
            guard let layer = item as? [String: Any],
                  try integer(layer, "group_size") == 64,
                  [4, 8].contains(try integer(layer, "bits")),
                  (layer["mode"] as? String ?? "affine") == "affine" else {
                throw InferenceFailure.invalidRequest("Unsupported per-layer VLM quantization.")
            }
        }
    }
}

/// Upstream 3.31.4 reads top-level min/max keys and ignores the official nested `size`.
enum QwenVLMProcessorConfiguration {
    static func normalized(_ data: Data, overrides: TextVisualProcessing?) throws
        -> (data: Data, minimum: Int, maximum: Int) {
        var object = try QwenVLMModelInventory.object(data)
        guard object["processor_class"] as? String == "Qwen3VLProcessor",
              let size = object["size"] as? [String: Any],
              size.keys.allSatisfy({ ["shortest_edge", "longest_edge"].contains($0) }) else {
            throw InferenceFailure.invalidRequest("Unsupported Qwen3VL processor configuration.")
        }
        let minPixels = try QwenVLMModelInventory.integer(size, "shortest_edge")
        let maxPixels = try QwenVLMModelInventory.integer(size, "longest_edge")
        guard minPixels > 0, maxPixels >= minPixels,
              try QwenVLMModelInventory.integer(object, "patch_size") == 16,
              try QwenVLMModelInventory.integer(object, "merge_size") == 2,
              try QwenVLMModelInventory.integer(object, "temporal_patch_size") == 2 else {
            throw InferenceFailure.invalidRequest("Invalid Qwen3VL processor budget or geometry.")
        }
        if let top = object["min_pixels"], (top as? Int) != minPixels {
            throw InferenceFailure.invalidRequest("Conflicting minimum pixel budgets.")
        }
        if let top = object["max_pixels"], (top as? Int) != maxPixels {
            throw InferenceFailure.invalidRequest("Conflicting maximum pixel budgets.")
        }
        for key in ["image_mean", "image_std"] {
            guard let values = object[key] as? [NSNumber], values.count == 3,
                  values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() &&
                                      $0.doubleValue.isFinite &&
                                      (key != "image_std" || $0.doubleValue > 0) }) else {
                throw InferenceFailure.invalidRequest("Invalid Qwen3VL \(key) channels.")
            }
        }
        try overrides?.validate()
        let minimum = overrides?.minimumPixels ?? minPixels
        let maximum = overrides?.maximumPixels ?? maxPixels
        guard minimum <= maximum else { throw InferenceFailure.invalidRequest("Conflicting pixel overrides.") }
        object["min_pixels"] = minimum
        object["max_pixels"] = maximum
        return (try JSONSerialization.data(withJSONObject: object), minimum, maximum)
    }
}
