@testable import DMLXBackend
import Flux2
import Foundation
import MLX
import Testing

extension MLXHardwareTests {
@Suite("Flux2 pinned image-conditioning production math", .serialized)
struct Flux2ReferenceMathTests {
    enum Reference: String, CaseIterable, Sendable {
        case outputIDs = "latent_ids"
        case referenceLatents = "image_latents"
        case referenceIDs = "image_latent_ids"
        case packedLatents = "packed_latents"
        case decoded

        var exact: Bool { self == .outputIDs || self == .referenceIDs }
    }

    @Test("Production reference encode and denoise match fixed FP32 tensors",
          arguments: Reference.allCases)
    func fixedReferenceParity(reference: Reference) async throws {
        let root = try Self.fixtureDirectory()
        let comparisons = try await Self.withExecutionLease {
            try autoreleasepool { try Self.evaluateFixture(root: root) }
        }
        let check = try #require(comparisons.first { $0.reference == reference })
        #expect(check.actualShape == check.expectedShape, "\(reference.rawValue) shape")
        #expect(check.comparedElements > 0, "A missing or empty fixed tensor cannot pass")
        #expect(check.nonfiniteElements == 0, "\(reference.rawValue) must remain finite")
        #expect(check.mismatchedElements == 0,
                "\(reference.rawValue): max abs error \(check.maximumAbsoluteError), atol \(check.absoluteTolerance), rtol \(check.relativeTolerance)")
    }

    @Test("Pinned real BF16 VAE covers and evaluates every reference-encoder tensor",
          .enabled(if: ProcessInfo.processInfo.environment["D_TEST_IMAGE_MODEL_DIR"] != nil))
    func realBF16EncoderCoverage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["D_TEST_IMAGE_MODEL_DIR"])
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        try await Self.withExecutionLease {
            try autoreleasepool {
                let state = MLXRandom.RandomState(seed: 0)
                try withRandomState(state) {
                    let vae = try Flux2AutoencoderKL.load(from: root, dtype: .bfloat16)
                    try Flux2ImageMath.validateVAEEncoderWeightCoverage(
                        vae: vae, snapshot: root, expectedDType: .bfloat16)
                }
            }
        }
    }

    private struct Comparison: Sendable {
        let reference: Reference
        let actualShape: [Int]
        let expectedShape: [Int]
        let comparedElements: Int
        let mismatchedElements: Int
        let nonfiniteElements: Int
        let maximumAbsoluteError: Double
        let absoluteTolerance: Float
        let relativeTolerance: Float
    }

    private static func fixtureDirectory() throws -> URL {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["D_TEST_FLUX_IMAGE_FIXTURE"] {
            try #require(!override.isEmpty, "D_TEST_FLUX_IMAGE_FIXTURE must name the fixed image fixture")
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            var repository = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { repository.deleteLastPathComponent() }
            root = repository.appendingPathComponent(
                "Vendor/flux2-swift/fixtures/flux2_tiny_klein_image_pipeline")
        }
        for name in ["klein_image_inputs.safetensors", "klein_image_expected.safetensors",
                     "transformer/config.json", "transformer/model.safetensors",
                     "vae/config.json", "vae/model.safetensors", "scheduler/config.json"] {
            try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                         "Required fixed image fixture is absent: \(name)")
        }
        return root
    }

    @inline(never)
    private static func evaluateFixture(root: URL) throws -> [Comparison] {
        let inputs = try MLX.loadArrays(
            url: root.appendingPathComponent("klein_image_inputs.safetensors"), stream: .cpu)
        let expected = try MLX.loadArrays(
            url: root.appendingPathComponent("klein_image_expected.safetensors"), stream: .cpu)
        func tensor(_ name: String, in values: [String: MLXArray]) throws -> MLXArray {
            try #require(values[name], "Missing immutable fixture tensor: \(name)")
        }
        func integer(_ name: String) throws -> Int {
            let value = try tensor(name, in: inputs)
            try #require(value.size == 1, "Fixture field must be scalar: \(name)")
            return Int(value.asType(.int32).item(Int32.self))
        }

        let height = try integer("height")
        let width = try integer("width")
        let steps = try integer("num_inference_steps")
        let imageIDScale = try integer("image_id_scale")
        try #require(height > 0 && width > 0 && steps > 0 && imageIDScale == 10)

        let rawLatents = try tensor("latents", in: inputs).asType(.float32)
        let outputIDs = try Flux2PositionIds.prepareLatentIds(rawLatents)
        let packedInput = try Flux2LatentUtils.packLatents(rawLatents)
        MLX.eval(packedInput, outputIDs)

        // This helper boundary drops the encoder VAE before the transformer is loaded.
        let reference = try prepareFixtureReference(
            root: root, image: tensor("image", in: inputs).asType(.float32))
        let combinedIDs = try Flux2ImageMath.appendReferenceIDs(
            outputIDs: outputIDs, reference: reference)
        let packed = try denoiseFixture(
            root: root, latents: packedInput, combinedIDs: combinedIDs,
            promptEmbeds: tensor("prompt_embeds", in: inputs).asType(.float32),
            textIDs: tensor("text_ids", in: inputs).asType(.int32),
            referenceLatents: reference.latents, steps: steps)
        let decoded = try decodeFixture(root: root, latents: packed, ids: outputIDs)
        try #require(decoded.shape == [rawLatents.dim(0), 3, height, width])

        return [
            compare(.outputIDs, actual: outputIDs,
                    expected: try tensor("latent_ids", in: inputs)),
            compare(.referenceLatents, actual: reference.latents,
                    expected: try tensor("image_latents", in: expected)),
            compare(.referenceIDs, actual: reference.ids,
                    expected: try tensor("image_latent_ids", in: expected)),
            compare(.packedLatents, actual: packed,
                    expected: try tensor("packed_latents", in: expected)),
            compare(.decoded, actual: decoded,
                    expected: try tensor("decoded", in: expected)),
        ]
    }

    @inline(never)
    private static func prepareFixtureReference(root: URL, image: MLXArray) throws
        -> Flux2ImageMath.ReferenceConditioning {
        let vae = try Flux2AutoencoderKL.load(from: root, dtype: .float32)
        try Flux2ImageMath.validateVAEEncoderWeightCoverage(
            vae: vae, snapshot: root, expectedDType: .float32)
        return try Flux2ImageMath.prepareReference(vae: vae, image: image, dtype: .float32)
    }

    @inline(never)
    private static func denoiseFixture(root: URL, latents: MLXArray, combinedIDs: MLXArray,
                                       promptEmbeds: MLXArray, textIDs: MLXArray,
                                       referenceLatents: MLXArray, steps: Int) throws -> MLXArray {
        let transformer = try Flux2Transformer2DModel.load(from: root, dtype: .float32)
        let scheduler = try FlowMatchEulerDiscreteScheduler.load(from: root)
        try Flux2ImageMath.configure(scheduler: scheduler, latents: latents, steps: steps)
        try #require(scheduler.timestepsValues.count == steps)
        let denoiser = Flux2Denoiser(transformer: transformer, scheduler: scheduler)
        var current = latents
        for timestep in scheduler.timestepsValues {
            current = try Flux2ImageMath.step(
                denoiser, current: current, timestep: timestep,
                promptEmbeds: promptEmbeds, textIDs: textIDs, imageIDs: combinedIDs,
                referenceLatents: referenceLatents)
        }
        MLX.eval(current)
        return current
    }

    @inline(never)
    private static func decodeFixture(root: URL, latents: MLXArray, ids: MLXArray) throws -> MLXArray {
        let vae = try Flux2AutoencoderKL.load(from: root, dtype: .float32)
        return try Flux2ImageMath.decode(vae: vae, latents: latents, ids: ids)
    }

    private static func compare(_ reference: Reference, actual: MLXArray,
                                expected: MLXArray) -> Comparison {
        let atol: Float = reference.exact ? 0 : 1e-4
        let rtol: Float = reference.exact ? 0 : 1e-3
        guard actual.shape == expected.shape else {
            return Comparison(reference: reference, actualShape: actual.shape, expectedShape: expected.shape,
                              comparedElements: 0, mismatchedElements: max(actual.size, expected.size),
                              nonfiniteElements: 0, maximumAbsoluteError: .infinity,
                              absoluteTolerance: atol, relativeTolerance: rtol)
        }
        let values = actual.asType(.float32).asArray(Float.self)
        let references = expected.asType(.float32).asArray(Float.self)
        var mismatched = 0
        var nonfinite = 0
        var maximum = 0.0
        for (value, expected) in zip(values, references) {
            guard value.isFinite && expected.isFinite else {
                mismatched += 1
                nonfinite += 1
                continue
            }
            let difference = abs(value - expected)
            if difference > atol + rtol * abs(expected) { mismatched += 1 }
            maximum = max(maximum, abs(Double(value) - Double(expected)))
        }
        return Comparison(reference: reference, actualShape: actual.shape, expectedShape: expected.shape,
                          comparedElements: values.count, mismatchedElements: mismatched,
                          nonfiniteElements: nonfinite, maximumAbsoluteError: maximum,
                          absoluteTolerance: atol, relativeTolerance: rtol)
    }

    private static func withExecutionLease<Value: Sendable>(
        _ body: () throws -> Value) async throws -> Value {
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        do {
            cleanup()
            let result = try body()
            cleanup()
            #expect(Memory.activeMemory == 0)
            #expect(Memory.cacheMemory == 0)
            await MLXExecutionLease.shared.relinquish(token)
            return result
        } catch {
            cleanup()
            await MLXExecutionLease.shared.relinquish(token)
            throw error
        }
    }

    private static func cleanup() {
        MLX.Stream.gpu.synchronize()
        MLX.Stream.cpu.synchronize()
        Flux2RuntimeResources.clearCaches()
        Memory.clearCache()
    }
}
}
