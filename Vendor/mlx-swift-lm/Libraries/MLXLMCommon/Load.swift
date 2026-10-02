// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXNN

/// An explicit local-file projection supplied by a caller that has verified its catalog.
/// `nil` at the factory boundary retains upstream directory discovery for legacy callers.
public struct ModelFileSelection: Sendable {
    public let paths: Set<String>

    public init(paths: Set<String>) { self.paths = paths }

    public func contains(_ name: String) -> Bool { paths.contains(name) }

    public func weightURLs(in directory: URL) -> [URL] {
        paths.filter { $0.hasSuffix(".safetensors") }.sorted()
            .map { directory.appendingPathComponent($0) }
    }
}

/// For a catalog-admitted sidecar, malformed stop fields are errors rather than
/// silently falling back to config.json defaults.
public func decodeAdmittedGenerationConfig(_ data: Data) throws -> GenerationConfigFile {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let values = object as? [String: Any] else {
        throw NSError(domain: "ModelFileSelection", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Invalid admitted generation configuration."])
    }
    for key in ["stop", "stop_strings"] where values[key] != nil {
        guard values[key] is String || values[key] is [String] else {
            throw NSError(domain: "ModelFileSelection", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid admitted \(key)."])
        }
    }
    return try JSONDecoder.json5().decode(GenerationConfigFile.self, from: data)
}

/// Load model weights.
///
/// This is typically called via ``GenericModelFactory/load(from:using:configuration:useLatest:progressHandler:)``.
/// This function loads all `safetensor` files in the given `modelDirectory`,
/// calls ``BaseLanguageModel/sanitize(weights:metadata:)`` to allow per-model preprocessing,
/// applies optional quantization, and
/// updates the model with the weights.
public func loadWeights(
    modelDirectory: URL, model: BaseLanguageModel,
    quantization: BaseConfiguration.Quantization? = nil,
    perLayerQuantization: BaseConfiguration.PerLayerQuantization? = nil,
    fileSelection: ModelFileSelection? = nil
) throws {
    // load the weights and collect metadata from the first safetensor file
    var weights = [String: MLXArray]()
    var metadata = [String: String]()
    if let fileSelection {
        for url in fileSelection.weightURLs(in: modelDirectory) {
            let (w, m) = try loadArraysAndMetadata(url: url)
            for (key, value) in w { weights[key] = value }
            if metadata.isEmpty { metadata = m }
        }
    } else {
        let enumerator = FileManager.default.enumerator(
            at: modelDirectory, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "safetensors" {
            let (w, m) = try loadArraysAndMetadata(url: url)
            for (key, value) in w {
                weights[key] = value
            }
            if metadata.isEmpty {
                metadata = m
            }
        }
    }

    // per-model cleanup (models can inspect metadata to customize behavior)
    weights = model.sanitize(weights: weights, metadata: metadata)

    // quantize if needed
    if quantization != nil || perLayerQuantization != nil {
        quantize(model: model) { path, module in
            if weights["\(path).scales"] != nil {
                if let perLayerQuantization {
                    return perLayerQuantization.quantization(layer: path)?.asTuple
                } else {
                    return quantization?.asTuple
                }
            } else {
                return nil
            }
        }
    }

    // apply the loaded weights
    let parameters = ModuleParameters.unflattened(weights)
    try model.update(parameters: parameters, verify: [.all])

    eval(model)
}
