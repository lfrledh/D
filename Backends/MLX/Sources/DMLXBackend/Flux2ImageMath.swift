// Scheduler calculations adapted from mzbac/flux2.swift at
// 959a4af7c0721c800851c84431ffd3fa1f353f1f (Apache-2.0).
// See Vendor/flux2-swift/LICENSE and Vendor/flux2-swift.provenance.json.
import DInference
import Flux2
import Foundation
import MLX
import MLXNN

/// The real backend and independent numerical fixtures exercise these same operations.
internal enum Flux2ImageMath {
    struct ReferenceConditioning {
        let latents: MLXArray
        let ids: MLXArray
    }

    static func configure(scheduler: FlowMatchEulerDiscreteScheduler, latents: MLXArray, steps: Int) throws {
        guard steps > 0, latents.ndim == 3, latents.dim(0) > 0 else {
            throw InferenceFailure.backendFailed("Invalid packed latent shape or step count.")
        }
        let sigmas: [Float]?
        if scheduler.config.useFlowSigmas == true {
            sigmas = nil
        } else if steps == 1 {
            sigmas = [1]
        } else {
            let start: Float = 1
            let end: Float = 1 / Float(steps)
            let step = (end - start) / Float(steps - 1)
            sigmas = (0..<steps).map { start + Float($0) * step }
        }
        let mu = scheduler.config.useDynamicShifting ? empiricalMu(length: latents.dim(1), steps: steps) : nil
        try scheduler.setTimesteps(numInferenceSteps: steps, sigmas: sigmas, mu: mu)
        scheduler.setBeginIndex(0)
        guard scheduler.timestepsValues.count == steps else {
            throw InferenceFailure.backendFailed("The scheduler returned an unexpected number of steps.")
        }
    }

    private static func empiricalMu(length: Int, steps: Int) -> Float {
        let a1: Float = 8.73809524e-05
        let b1: Float = 1.89833333
        let a2: Float = 0.00016927
        let b2: Float = 0.45666666
        if length > 4300 { return a2 * Float(length) + b2 }
        let m200 = a2 * Float(length) + b2
        let m10 = a1 * Float(length) + b1
        let a = (m200 - m10) / 190.0
        let b = m200 - 200.0 * a
        return a * Float(steps) + b
    }

    @inline(never)
    static func step(_ denoiser: Flux2Denoiser, current: MLXArray, timestep: Float,
                     promptEmbeds: MLXArray, textIDs: MLXArray, imageIDs: MLXArray,
                     referenceLatents: MLXArray? = nil) throws -> MLXArray {
        let time = MLX.full([current.dim(0)], values: timestep).asType(current.dtype)
        let output = try denoiser.step(
            latents: current, encoderHiddenStates: promptEmbeds, timestep: time,
            imgIds: imageIDs, txtIds: textIDs, imageLatents: referenceLatents, guidance: nil,
            attentionMask: .none, modelTimestepScale: 0.001)
        MLX.eval(output.prevLatents)
        try requireFinite(output.prevLatents, name: "Denoised latents")
        return output.prevLatents
    }

    static func referenceTensor(_ input: ImageReferenceInput, dtype: DType) throws -> MLXArray {
        let (pixels, overflow) = input.width.multipliedReportingOverflow(by: input.height)
        let (expected, byteOverflow) = pixels.multipliedReportingOverflow(by: 3)
        guard !overflow, !byteOverflow, input.rgb.count == expected else {
            throw InferenceFailure.invalidRequest("The frozen image reference RGB payload has an invalid length.")
        }
        let bytes = MLXArray(input.rgb, [1, input.height, input.width, 3], dtype: .uint8)
        let scale = MLXArray(Float(127.5)).asType(dtype)
        let image = (bytes.asType(dtype) / scale - MLXArray(Float(1)).asType(dtype))
            .transposed(0, 3, 1, 2)
        MLX.eval(image)
        try requireFinite(image, name: "Reference pixels")
        return image
    }

    @inline(never)
    static func prepareReference(vae: Flux2AutoencoderKL, image: MLXArray,
                                 dtype: DType) throws -> ReferenceConditioning {
        guard image.ndim == 4, image.dim(0) == 1, image.dim(1) == 3 else {
            throw InferenceFailure.invalidRequest("Reference pixels must be one NCHW RGB image.")
        }
        let prepared = try Flux2LatentPreparation.prepareImageLatents(
            images: [image], batchSize: 1, vae: vae, dtype: dtype, imageIdScale: 10)
        MLX.eval(prepared.latents, prepared.ids)
        guard prepared.latents.ndim == 3, prepared.ids.ndim == 3,
              prepared.latents.dim(0) == 1, prepared.ids.dim(0) == 1,
              prepared.latents.dim(1) == prepared.ids.dim(1), prepared.ids.dim(2) == 4,
              (prepared.ids[.ellipsis, 0] .== MLXArray(Int32(10))).all().item(Bool.self) else {
            throw InferenceFailure.backendFailed("FLUX.2 produced invalid t10 reference conditioning IDs.")
        }
        try requireFinite(prepared.latents, name: "Reference latents")
        return ReferenceConditioning(latents: prepared.latents, ids: prepared.ids)
    }

    static func appendReferenceIDs(outputIDs: MLXArray,
                                   reference: ReferenceConditioning?) throws -> MLXArray {
        guard outputIDs.ndim == 3, outputIDs.dim(2) == 4,
              (outputIDs[.ellipsis, 0] .== MLXArray(Int32(0))).all().item(Bool.self) else {
            throw InferenceFailure.backendFailed("FLUX.2 produced invalid t0 output latent IDs.")
        }
        guard let reference else { return outputIDs }
        guard reference.ids.dim(0) == outputIDs.dim(0) else {
            throw InferenceFailure.backendFailed("Reference and output latent ID batches do not match.")
        }
        let combined = MLX.concatenated([outputIDs, reference.ids], axis: 1)
        MLX.eval(combined)
        return combined
    }

    /// Upstream VAE loading uses verify:none. Compare the tensors needed by the new
    /// encoder path against the fixed safetensors headers, then evaluate each loaded
    /// tensor so missing, random or non-finite encoder state cannot reach conditioning.
    static func validateVAEEncoderWeightCoverage(vae: Flux2AutoencoderKL, snapshot: URL,
                                                 expectedDType: DType) throws {
        func required(_ name: String) -> Bool {
            name.hasPrefix("encoder.") || name.hasPrefix("quant_conv.") ||
                name == "bn.running_mean" || name == "bn.running_var"
        }
        let actual = Dictionary(uniqueKeysWithValues: vae.parameters().flattened())
            .filter { required($0.key) }
        guard !actual.isEmpty, actual.keys.contains(where: { $0.hasPrefix("encoder.") }),
              actual["bn.running_mean"] != nil, actual["bn.running_var"] != nil else {
            throw InferenceFailure.backendFailed("The loaded FLUX.2 VAE does not expose complete encoder state.")
        }

        let files = try Flux2WeightsLoader(snapshot: snapshot).listSafetensors(component: .vae)
        var expected: [String: [Int]] = [:]
        for file in files {
            let reader = try SafeTensorsReader(fileURL: file)
            for metadata in reader.allMetadata() where required(metadata.name) {
                guard expected[metadata.name] == nil else {
                    throw InferenceFailure.backendFailed("The FLUX.2 VAE repeats a required encoder tensor.")
                }
                let shape = metadata.shape
                expected[metadata.name] = shape.count == 4
                    ? [shape[0], shape[2], shape[3], shape[1]] : shape
            }
        }
        guard Set(actual.keys) == Set(expected.keys) else {
            throw InferenceFailure.backendFailed("The FLUX.2 VAE encoder tensor coverage is incomplete.")
        }
        var finiteChecks: [(String, MLXArray)] = []
        finiteChecks.reserveCapacity(actual.count)
        for (name, parameter) in actual {
            guard let expectedShape = expected[name], parameter.shape == expectedShape,
                  parameter.dtype == expectedDType else {
                throw InferenceFailure.backendFailed("The FLUX.2 VAE encoder tensor shape or dtype is invalid: \(name)")
            }
            finiteChecks.append((name, MLX.isFinite(parameter).all()))
        }
        MLX.eval(finiteChecks.map { $0.1 })
        for (name, check) in finiteChecks where !check.item(Bool.self) {
            throw InferenceFailure.backendFailed("VAE encoder tensor \(name) contains NaN or infinity.")
        }
    }

    @inline(never)
    static func decode(vae: Flux2AutoencoderKL, latents: MLXArray, ids: MLXArray) throws -> MLXArray {
        let unpacked = try Flux2LatentUtils.unpackLatentsWithIds(latents, ids: ids)
        let input = try Flux2LatentUtils.denormalizeAndUnpatchify(unpacked, vae: vae)
        let decoded = vae.decode(input)
        MLX.eval(decoded)
        try requireFinite(decoded, name: "Decoded pixels")
        return decoded
    }

    static func requireFinite(_ array: MLXArray, name: String) throws {
        guard MLX.isFinite(array).all().item(Bool.self) else {
            throw InferenceFailure.backendFailed("\(name) contain NaN or infinity.")
        }
    }
}
