import Foundation
import DInference
import MLXVLM

/// Uses safetensors headers, rather than total checkpoint size, for the active weight peak.
enum QwenLayeredResourceEstimate {
    static func peak(inventory: QwenVLMModelInventory, tokens: UInt64,
                     visualPixels: UInt64, cacheLimit: Int) throws -> UInt64 {
        let (configData, _) = try AudioFileSystem.readRegularFile(
            inventory.directory.appendingPathComponent("config.json"),
            label: "Qwen3.5 config", maximumBytes: 4 * 1024 * 1024)
        let config = try QwenVLMModelInventory.object(configData)
        let modelConfiguration = try Qwen35LayeredFileValidation.configuration(configData)
        guard let text = config["text_config"] as? [String: Any] else {
            throw InferenceFailure.invalidRequest("Missing Qwen3.5 text configuration.")
        }
        let layers = try QwenVLMModelInventory.integer(text, "num_hidden_layers")
        let kvHeads = try QwenVLMModelInventory.integer(text, "num_key_value_heads")
        let headDim = try QwenVLMModelInventory.integer(text, "head_dim")
        let valueHeads = try QwenVLMModelInventory.integer(text, "linear_num_value_heads")
        let keyHeads = try positive(text, "linear_num_key_heads", default: 16, maximum: 256)
        let keyDim = try positive(text, "linear_key_head_dim", default: 192, maximum: 1024)
        let valueDim = try positive(text, "linear_value_head_dim", default: 128, maximum: 1024)
        let convKernel = try positive(text, "linear_conv_kernel_dim", default: 4, maximum: 64)
        guard (inventory.size == "9B" && layers == 32 || inventory.size == "27B" && layers == 64),
              kvHeads > 0, kvHeads <= 256, headDim > 0, headDim <= 1024,
              valueHeads > 0, valueHeads <= 256, cacheLimit >= 0 else {
            throw InferenceFailure.invalidRequest("Unsupported layered Qwen3.5 configuration.")
        }
        let fullLayers = layers / 4
        let linearLayers = layers - fullLayers
        var textResident: UInt64 = 0
        var visionBase: UInt64 = 0
        var visionMerger: UInt64 = 0
        var visionBlocks = [Int: UInt64]()
        var byLayer = [Int: UInt64]()
        let files = try FileManager.default.contentsOfDirectory(at: inventory.directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "safetensors" }
        for file in files {
            try Task.checkCancellation()
            let (data, payloadSize) = try Qwen35LayeredFileValidation.header(file)
            guard let header = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InferenceFailure.invalidRequest("Invalid safetensors header.")
            }
            var ranges: [(UInt64, UInt64)] = []
            for (name, value) in header where name != "__metadata__" {
                guard let tensor = value as? [String: Any],
                      Qwen35LayeredFileValidation.dimensions(tensor["shape"]) != nil,
                      let offsets = Qwen35LayeredFileValidation.offsets(tensor["data_offsets"]),
                      offsets[0] < offsets[1], offsets[1] <= payloadSize else {
                    throw InferenceFailure.invalidRequest("Invalid safetensors tensor offsets.")
                }
                ranges.append((offsets[0], offsets[1]))
            }
            for (name, value) in header where name != "__metadata__" &&
                !name.contains("mtp.") && !name.contains("position_ids") {
                guard let tensor = value as? [String: Any],
                      let offsets = Qwen35LayeredFileValidation.offsets(tensor["data_offsets"]),
                      offsets[0] < offsets[1], offsets[1] <= payloadSize,
                      let dtype = tensor["dtype"] as? String,
                      let width = Qwen35LayeredFileValidation.byteWidth(name: name, dtype: dtype),
                      let shape = Qwen35LayeredFileValidation.dimensions(tensor["shape"]),
                      validByteCount(shape, offsets, width: width) else {
                    throw InferenceFailure.invalidRequest("Invalid safetensors tensor offsets.")
                }
                let bytes = offsets[1] - offsets[0]
                let components = name.components(separatedBy: ".")
                if let layerPosition = components.firstIndex(of: "layers"),
                   layerPosition + 1 < components.count,
                   let layer = Int(components[layerPosition + 1]), layer >= 0, layer < layers,
                   name.contains("language_model") {
                    byLayer[layer, default: 0] = adding(byLayer[layer, default: 0], bytes)
                } else if name.contains("visual.") || name.hasPrefix("vision_tower.") {
                    if let blockPosition = components.firstIndex(of: "blocks"),
                       blockPosition + 1 < components.count,
                       let block = Int(components[blockPosition + 1]), block >= 0, block < 27 {
                        visionBlocks[block, default: 0] = adding(visionBlocks[block, default: 0], bytes)
                    } else if name.contains("merger.") {
                        visionMerger = adding(visionMerger, bytes)
                    } else {
                        visionBase = adding(visionBase, bytes)
                    }
                } else {
                    textResident = adding(textResident, bytes)
                }
            }
            ranges.sort { $0.0 < $1.0 }
            if ranges.count > 1 {
                for index in 1..<ranges.count where ranges[index].0 < ranges[index - 1].1 {
                    throw InferenceFailure.invalidRequest("Overlapping safetensors offsets.")
                }
            }
        }
        guard byLayer.count == layers, let active = byLayer.values.max() else {
            throw InferenceFailure.invalidRequest("Incomplete Qwen3.5 decoder weights.")
        }
        // Original FP32 linear controls can promote subsequent activations,
        // including full-attention KV and convolution state. Never estimate
        // these as BF16 merely because most stored weights are BF16.
        let kvPerToken = product(fullLayers, 2, kvHeads, headDim, 4)
        let recurrent = product(linearLayers, valueHeads, valueDim, keyDim, 4)
        let conv = multiplying(product(linearLayers, convKernel - 1, 4),
            adding(product(2, keyHeads, keyDim), product(valueHeads, valueDim)))
        let hidden = UInt64(inventory.size == "27B" ? 5120 : 4096)
        let promptWorkspace = adding(multiplying(tokens, hidden * 4), multiplying(512 * 32, hidden))
        // Chunked prefill preserves the resident output projection geometry.
        // Original mixed-precision controls can promote its result to FP32.
        let projection = product(512, modelConfiguration.textConfiguration.vocabularySize, 4)
        let cache = [multiplying(tokens, kvPerToken), recurrent, conv, projection,
                     promptWorkspace, UInt64(cacheLimit), 512 * 1024 * 1024].reduce(0, adding)
        // The prepared input remains captured by the generation closure until
        // completion, including its visual pixel arrays. Account for that
        // ownership during decode, not only during the vision stage.
        // A static RGB float32 image is repeated across two temporal frames.
        // Video pixel accounting already includes temporal padding; 24 is a
        // conservative common bound, never a claim that pixels are released.
        let retainedVisual = multiplying(visualPixels, 24)
        let decode = adding(textResident, adding(active, adding(cache, retainedVisual)))
        guard visualPixels > 0 else { return decode }
        guard visionBlocks.count == 27, let visionBlock = visionBlocks.values.max() else {
            throw InferenceFailure.invalidRequest("Incomplete Qwen3.5 vision blocks.")
        }
        let visualWorkspace = adding(retainedVisual, promptWorkspace)
        let visualStage = [textResident, visionBase, max(visionBlock, visionMerger),
                           visualWorkspace, UInt64(cacheLimit), 512 * 1024 * 1024].reduce(0, adding)
        return max(decode, visualStage)
    }

    private static func positive(_ config: [String: Any], _ key: String,
                                 default fallback: Int, maximum: Int) throws -> Int {
        let value = try config[key] == nil ? fallback : QwenVLMModelInventory.integer(config, key)
        guard value > 0, value <= maximum else {
            throw InferenceFailure.invalidRequest("Unsupported Qwen3.5 \(key).")
        }
        return value
    }

    private static func validByteCount(_ shape: [Int], _ offsets: [UInt64], width: UInt64) -> Bool {
        var bytes = width
        for dimension in shape {
            let (next, overflow) = bytes.multipliedReportingOverflow(by: UInt64(dimension))
            if overflow { return false }
            bytes = next
        }
        return bytes == offsets[1] - offsets[0]
    }

    private static func product(_ values: Int...) -> UInt64 {
        values.reduce(1) { multiplying($0, UInt64($1)) }
    }

    private static func adding(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : value
    }
    private static func multiplying(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? .max : value
    }
}
