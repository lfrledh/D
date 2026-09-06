// Scheduler calculations adapted from mzbac/flux2.swift at
// 959a4af7c0721c800851c84431ffd3fa1f353f1f (Apache-2.0).
// See Vendor/flux2-swift/LICENSE and Vendor/flux2-swift.provenance.json.
import DInference
import Flux2
import MLX

/// The real backend and independent numerical fixtures exercise these same operations.
internal enum Flux2ImageMath {
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
                     promptEmbeds: MLXArray, textIDs: MLXArray, imageIDs: MLXArray) throws -> MLXArray {
        let time = MLX.full([current.dim(0)], values: timestep).asType(current.dtype)
        let output = try denoiser.step(
            latents: current, encoderHiddenStates: promptEmbeds, timestep: time,
            imgIds: imageIDs, txtIds: textIDs, guidance: nil,
            attentionMask: .none, modelTimestepScale: 0.001)
        MLX.eval(output.prevLatents)
        try requireFinite(output.prevLatents, name: "Denoised latents")
        return output.prevLatents
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
