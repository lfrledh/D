@testable import DMLXBackend
import Flux2
import Foundation
import MLX
import Testing

/// The enclosing hardware suite serializes all raw MLX and real backend tests.
/// Each raw fixture also holds the production lease through complete cleanup.
extension MLXHardwareTests {
@Suite("Flux2 tiny reference math and retained resources", .serialized)
struct Flux2ImageMathTests {
    enum Reference: String, CaseIterable, Sendable {
        case promptEmbeds = "prompt_embeds"
        case textIDs = "text_ids"
        case latentIDs = "latent_ids"
        case packedLatents = "packed_latents"
        case decoded

        var exact: Bool { self == .textIDs || self == .latentIDs }
    }

    @Test("Production math matches the pinned float32 reference", arguments: Reference.allCases)
    func referenceParity(reference: Reference) async throws {
        let root = try Self.fixtureDirectory()
        let comparisons = try await Self.withExecutionLease {
            try autoreleasepool {
                try Self.withFixtureRandomState { try Self.evaluateFixture(root: root) }
            }
        }
        let check = try #require(comparisons.first { $0.reference == reference })
        #expect(check.actualShape == check.expectedShape, "\(reference.rawValue) shape")
        #expect(check.comparedElements > 0, "A missing or empty comparison cannot pass")
        #expect(check.nonfiniteElements == 0, "\(reference.rawValue) must remain finite")
        #expect(check.mismatchedElements == 0,
                "\(reference.rawValue): max abs error \(check.maximumAbsoluteError), atol \(check.absoluteTolerance), rtol \(check.relativeTolerance)")
    }

    @Test("Tiny counters measure allocator clear, Flux2 cache clear, and scoped RNG release")
    func cacheOwnershipBreakdown() async throws {
        let root = try Self.fixtureDirectory()
        let points = try await Self.withExecutionLease {
            #expect(Memory.activeMemory == 0, "The isolated test must start without retained MLX arrays")
            var snapshots = [Self.memoryPoint("baseline")]
            let scoped = try autoreleasepool {
                try Self.withFixtureRandomState {
                    // Only host comparison values leave this non-inlined model/tensor scope.
                    _ = try Self.evaluateFixture(root: root)
                    Self.synchronize()
                    let before = Self.memoryPoint("after_tiny_before_clear")
                    Memory.clearCache()
                    let allocatorOnly = Self.memoryPoint("allocator_cleared_rng_and_flux_cache_alive")
                    Flux2RuntimeResources.clearCaches()
                    Self.synchronize()
                    let fluxCleared = Self.memoryPoint("flux_cache_cleared_rng_alive")
                    Memory.clearCache()
                    let bothCaches = Self.memoryPoint("both_caches_cleared_rng_alive")
                    return [before, allocatorOnly, fluxCleared, bothCaches]
                }
            }
            snapshots.append(contentsOf: scoped)
            Self.synchronize()
            Memory.clearCache()
            snapshots.append(Self.memoryPoint("scoped_rng_released"))
            return snapshots
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("Flux2 tiny cache breakdown: \(String(decoding: try encoder.encode(points), as: UTF8.self))")
        let before = try #require(points.first { $0.phase == "after_tiny_before_clear" })
        let allocatorOnly = try #require(points.first { $0.phase == "allocator_cleared_rng_and_flux_cache_alive" })
        let fluxCleared = try #require(points.first { $0.phase == "flux_cache_cleared_rng_alive" })
        let bothCaches = try #require(points.first { $0.phase == "both_caches_cleared_rng_alive" })
        let released = try #require(points.last)
        // Record measured bytes without assigning an unmeasured residual to an owner.
        // Clearing free allocator buffers must not change the count of active arrays.
        #expect(allocatorOnly.activeBytes == before.activeBytes)
        #expect(allocatorOnly.cacheBytes == 0)
        #expect(fluxCleared.activeBytes < allocatorOnly.activeBytes,
                "The explicit Flux2 cache clear must release retained fixture allocations")
        #expect(bothCaches.activeBytes == fluxCleared.activeBytes)
        #expect(bothCaches.cacheBytes == 0)
        #expect(released.activeBytes == 0)
        #expect(released.cacheBytes == 0)
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

    private struct MemoryPoint: Codable, Sendable {
        let phase: String
        let activeBytes: Int
        let cacheBytes: Int
    }

    private static func fixtureDirectory() throws -> URL {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["D_TEST_FLUX_FIXTURE"] {
            try #require(!override.isEmpty, "D_TEST_FLUX_FIXTURE must name the tiny Klein fixture directory")
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            var repository = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { repository.deleteLastPathComponent() }
            root = repository.appendingPathComponent("Vendor/flux2-swift/fixtures/flux2_tiny_klein_pipeline")
        }
        for name in ["klein_inputs.safetensors", "klein_expected.safetensors", "text_encoder/config.json",
                     "text_encoder/model.safetensors", "transformer/config.json", "transformer/model.safetensors",
                     "vae/config.json", "vae/model.safetensors", "scheduler/config.json"] {
            try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                         "Required fixed tiny fixture is absent: \(name)")
        }
        return root
    }

    private static func withExecutionLease<Value: Sendable>(_ body: () throws -> Value) async throws -> Value {
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        do {
            cleanup()
            let result = try body()
            cleanup()
            #expect(Memory.activeMemory == 0, "All tiny-test model, tensor, RNG and Flux2 cache owners must release")
            #expect(Memory.cacheMemory == 0)
            await MLXExecutionLease.shared.relinquish(token)
            return result
        } catch {
            cleanup()
            await MLXExecutionLease.shared.relinquish(token)
            throw error
        }
    }

    private static func synchronize() {
        MLX.Stream.gpu.synchronize()
        MLX.Stream.cpu.synchronize()
    }

    private static func cleanup() {
        synchronize()
        Flux2RuntimeResources.clearCaches()
        Memory.clearCache()
    }

    private static func memoryPoint(_ phase: String) -> MemoryPoint {
        MemoryPoint(phase: phase, activeBytes: Memory.activeMemory, cacheBytes: Memory.cacheMemory)
    }

    @inline(never)
    private static func withFixtureRandomState<Value>(_ body: () throws -> Value) rethrows -> Value {
        let state = MLXRandom.RandomState(seed: 0)
        return try withRandomState(state, body: body)
    }

    @inline(never)
    private static func evaluateFixture(root: URL) throws -> [Comparison] {
        let inputs = try MLX.loadArrays(url: root.appendingPathComponent("klein_inputs.safetensors"), stream: .cpu)
        let expected = try MLX.loadArrays(url: root.appendingPathComponent("klein_expected.safetensors"), stream: .cpu)
        func tensor(_ name: String, in values: [String: MLXArray]) throws -> MLXArray {
            try #require(values[name], "Missing fixture tensor: \(name)")
        }
        func integer(_ name: String) throws -> Int {
            let value = try tensor(name, in: inputs)
            try #require(value.size == 1, "Fixture field must be scalar: \(name)")
            return Int(value.asType(.int32).item(Int32.self))
        }
        let height = try integer("height")
        let width = try integer("width")
        let steps = try integer("num_inference_steps")
        try #require(height > 0 && width > 0 && steps > 0)
        let encoding = try encodeFixture(
            root: root, inputIDs: tensor("input_ids", in: inputs).asType(.int32),
            attentionMask: tensor("attention_mask", in: inputs).asType(.int32))
        let rawLatents = try tensor("latents", in: inputs).asType(.float32)
        let ids = try Flux2PositionIds.prepareLatentIds(rawLatents)
        let packedInput = try Flux2LatentUtils.packLatents(rawLatents)
        MLX.eval(packedInput, ids)
        let packed = try denoiseFixture(root: root, latents: packedInput, ids: ids, encoding: encoding, steps: steps)
        let decoded = try decodeFixture(root: root, latents: packed, ids: ids)
        try #require(decoded.shape == [rawLatents.dim(0), 3, height, width])
        return [
            compare(.promptEmbeds, actual: encoding.promptEmbeds, expected: try tensor("prompt_embeds", in: inputs)),
            compare(.textIDs, actual: encoding.textIds, expected: try tensor("text_ids", in: inputs)),
            compare(.latentIDs, actual: ids, expected: try tensor("latent_ids", in: inputs)),
            compare(.packedLatents, actual: packed, expected: try tensor("packed_latents", in: expected)),
            compare(.decoded, actual: decoded, expected: try tensor("decoded", in: expected)),
        ]
    }

    @inline(never)
    private static func encodeFixture(root: URL, inputIDs: MLXArray, attentionMask: MLXArray) throws -> Flux2PromptEncoding {
        let model = try Flux2Qwen3TextEncoder.load(from: root, dtype: .float32)
        let encoder = Flux2KleinPromptEncoder(textEncoder: model, hiddenStateLayers: [0])
        let result = try encoder.encodeTokens(inputIds: inputIDs, attentionMask: attentionMask)
        MLX.eval(result.promptEmbeds, result.textIds, result.inputIds, result.attentionMask)
        return result
    }

    @inline(never)
    private static func denoiseFixture(root: URL, latents: MLXArray, ids: MLXArray,
                                       encoding: Flux2PromptEncoding, steps: Int) throws -> MLXArray {
        let transformer = try Flux2Transformer2DModel.load(from: root, dtype: .float32)
        let scheduler = try FlowMatchEulerDiscreteScheduler.load(from: root)
        try Flux2ImageMath.configure(scheduler: scheduler, latents: latents, steps: steps)
        try #require(scheduler.timestepsValues.count == steps)
        let denoiser = Flux2Denoiser(transformer: transformer, scheduler: scheduler)
        var current = latents
        for timestep in scheduler.timestepsValues {
            current = try Flux2ImageMath.step(denoiser, current: current, timestep: timestep,
                                             promptEmbeds: encoding.promptEmbeds, textIDs: encoding.textIds,
                                             imageIDs: ids)
        }
        MLX.eval(current, ids)
        return current
    }

    @inline(never)
    private static func decodeFixture(root: URL, latents: MLXArray, ids: MLXArray) throws -> MLXArray {
        let vae = try Flux2AutoencoderKL.load(from: root, dtype: .float32)
        return try Flux2ImageMath.decode(vae: vae, latents: latents, ids: ids)
    }

    private static func compare(_ reference: Reference, actual: MLXArray, expected: MLXArray) -> Comparison {
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
}
}
