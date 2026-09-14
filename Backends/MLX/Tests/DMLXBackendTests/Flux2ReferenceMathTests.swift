@testable import DMLXBackend
import CryptoKit
import DInference
import DRuntime
import Flux2
import Foundation
import ImageIO
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
            try autoreleasepool {
                try Self.withFixtureRandomState { try Self.evaluateFixture(root: root) }
            }
        }
        let check = try #require(comparisons.first { $0.reference == reference })
        #expect(check.actualShape == check.expectedShape, "\(reference.rawValue) shape")
        #expect(check.comparedElements > 0, "A missing or empty fixed tensor cannot pass")
        #expect(check.nonfiniteElements == 0, "\(reference.rawValue) must remain finite")
        #expect(check.mismatchedElements == 0,
                "\(reference.rawValue): max abs error \(check.maximumAbsoluteError), atol \(check.absoluteTolerance), rtol \(check.relativeTolerance)")
    }

    @Test("Production RGB normalization uses FP32 before its final BF16 cast")
    func productionRGBNormalizationUsesFP32BeforeBF16() async throws {
        let evidence = try await Self.withExecutionLease {
            try autoreleasepool { try Self.normalizationEvidence() }
        }
        let known: [Float] = [
            -1, 1, Float(128) / 127.5 - 1, Float(127) / 127.5 - 1,
            Float(127) / 127.5 - 1, Float(128) / 127.5 - 1, 1, -1,
            Float(128) / 127.5 - 1, Float(127) / 127.5 - 1, -1, 1,
        ]
        #expect(evidence.fp32.count == known.count)
        for (actual, expected) in zip(evidence.fp32, known) {
            #expect(abs(actual - expected) <= 1e-7)
        }
        #expect(evidence.bfloat16 == evidence.expectedBFloat16,
                "Final BF16 casting must round the independently normalized FP32 NCHW values")
        #expect(evidence.bfloat16 != evidence.legacyIntermediateBFloat16,
                "The test must detect the rejected UInt8-to-BF16-before-normalization path")
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
                    let image = try Flux2ImageMath.referenceTensor(
                        Self.knownReferenceInput(width: 512, height: 512), dtype: .bfloat16)
                    let prepared = try Flux2ImageMath.prepareReference(
                        vae: vae, image: image, dtype: .bfloat16)
                    #expect(prepared.latents.ndim == 3 && prepared.latents.dim(0) == 1)
                    #expect(prepared.ids.shape == [1, prepared.latents.dim(1), 4])
                    #expect((prepared.ids[.ellipsis, 0] .== MLXArray(Int32(10))).all().item(Bool.self))
                    #expect(MLX.isFinite(prepared.latents).all().item(Bool.self))
                }
            }
        }
    }

    @Test("Cancelled reference VAE boundary releases before the next reference request",
          .enabled(if: ProcessInfo.processInfo.environment["D_TEST_IMAGE_MODEL_DIR"] != nil),
          .timeLimit(.minutes(5)))
    func realReferenceCancellationReleasesThenRecovers() async throws {
        let model = try Self.realImageModelDirectory()
        let files = try RealReferenceFiles()
        defer { files.remove() }
        let first = Self.realRequest(model: model, reference: files.reference, seed: 42)
        let next = Self.realRequest(model: model, reference: files.reference, seed: 43)
        let trace = MLXTestTrace()
        let gate = MLXTestGate()
        let backend = try MLXImageBackend(configuration: .init(
            artifactDirectory: files.artifacts, profile: .scalableKlein4B), observer: { event in
                await trace.lifecycle(event)
                if event.runID == first.id && event.phase == .vaeLoaded { await gate.wait() }
            })
        let wrapped = ReferenceTracedBackend(
            backend: backend, trace: trace, blockedRun: first.id, gate: gate)
        try await Self.withRealRuntime(wrapped) { runtime in
            let firstRun = try await runtime.submit(first, backendID: backend.descriptor.id)
            let firstConsumer = Task { await Self.collect(firstRun, trace: trace) }
            var recoveryConsumer: Task<CollectedImageRun, Never>?
            do {
                try #require(await gate.waitForArrival(), "Reference VAE loading must reach its cancellation boundary")
                let nextRun = try await runtime.submit(next, backendID: backend.descriptor.id)
                recoveryConsumer = Task { await Self.collect(nextRun, trace: trace) }
                await firstRun.cancel()
                await gate.open()
                let cancelled = await firstConsumer.value
                let recovery = try #require(recoveryConsumer)
                let recovered = await recovery.value
                #expect(cancelled.outcome == .cancelled)
                #expect(cancelled.streamFailed)
                #expect(cancelled.outputs.isEmpty)
                _ = try Self.completedReference(recovered, root: files.artifacts,
                                                reference: files.reference)
                let firstEvents = await trace.events(for: first.id)
                #expect(firstEvents.map(\.phase).contains(.loadingVAE))
                #expect(firstEvents.map(\.phase).contains(.vaeLoaded))
                #expect(!firstEvents.map(\.phase).contains(.encoding))
                let firstRelease = try Self.releasedEvent(firstEvents)
                let nextRelease = try Self.releasedEvent(await trace.events(for: next.id))
                #expect(firstRelease.memory.activeBytes == 0 && firstRelease.memory.cacheBytes == 0)
                #expect(nextRelease.memory.activeBytes == 0 && nextRelease.memory.cacheBytes == 0)
                try Self.expectBefore(await trace.entries(), first: first.id, second: next.id)
                expectNoLateOutputs(await trace.entries())
                try await backend.cleanupUnpublishedArtifacts()
            } catch {
                await gate.open()
                await runtime.cancelAllAndWait()
                _ = await firstConsumer.value
                if let recoveryConsumer { _ = await recoveryConsumer.value }
                throw error
            }
        }
    }

    @Test("Two real reference runs publish PNGs without released-counter growth",
          .enabled(if: ProcessInfo.processInfo.environment["D_TEST_IMAGE_MODEL_DIR"] != nil),
          .timeLimit(.minutes(5)))
    func realRepeatedReferenceRunsReleaseWithoutGrowth() async throws {
        let model = try Self.realImageModelDirectory()
        let files = try RealReferenceFiles()
        defer { files.remove() }
        let trace = MLXTestTrace()
        let backend = try MLXImageBackend(configuration: .init(
            artifactDirectory: files.artifacts, profile: .scalableKlein4B),
            observer: { await trace.lifecycle($0) })
        let wrapped = ReferenceTracedBackend(backend: backend, trace: trace)
        try await Self.withRealRuntime(wrapped) { runtime in
            var releases: [MLXLifecycleEvent] = []
            var artifactURLs: Set<URL> = []
            for seed in [UInt64(42), UInt64(43)] {
                let request = Self.realRequest(model: model, reference: files.reference, seed: seed)
                let run = try await runtime.submit(request, backendID: backend.descriptor.id)
                let collected = await Self.collect(run, trace: trace)
                let result = try Self.completedReference(
                    collected, root: files.artifacts, reference: files.reference)
                artifactURLs.insert(try #require(result.artifacts.first).url)
                releases.append(try Self.releasedEvent(await trace.events(for: request.id)))
            }
            #expect(artifactURLs.count == 2)
            let first = try #require(releases.first)
            let second = try #require(releases.last)
            #expect(first.memory.activeBytes == 0 && first.memory.cacheBytes == 0)
            #expect(second.memory.activeBytes <= first.memory.activeBytes)
            #expect(second.memory.cacheBytes <= first.memory.cacheBytes)
            expectNoLateOutputs(await trace.entries())
            try await backend.cleanupUnpublishedArtifacts()
        }
    }

    @Test("Real reference conditioning changes the same-prompt same-seed output",
          .enabled(if: ProcessInfo.processInfo.environment["D_TEST_IMAGE_MODEL_DIR"] != nil),
          .timeLimit(.minutes(5)))
    func realReferenceConditioningChangesOutput() async throws {
        let model = try Self.realImageModelDirectory()
        let files = try RealReferenceFiles()
        defer { files.remove() }
        let trace = MLXTestTrace()
        let backend = try MLXImageBackend(configuration: .init(
            artifactDirectory: files.artifacts, profile: .scalableKlein4B),
            observer: { await trace.lifecycle($0) })
        let wrapped = ReferenceTracedBackend(backend: backend, trace: trace)
        try await Self.withRealRuntime(wrapped) { runtime in
            let conditioned = Self.realRequest(model: model, reference: files.reference, seed: 42)
            let unconditioned = Self.realRequest(model: model, reference: nil, seed: 42)
            let conditionedRun = try await runtime.submit(conditioned, backendID: backend.descriptor.id)
            let conditionedResult = try Self.completedReference(
                await Self.collect(conditionedRun, trace: trace),
                root: files.artifacts, reference: files.reference)
            let unconditionedRun = try await runtime.submit(unconditioned, backendID: backend.descriptor.id)
            let unconditionedResult = try Self.completedImage(
                await Self.collect(unconditionedRun, trace: trace), root: files.artifacts)
            #expect(unconditionedResult.metadata["referenceConditioningApplied"] == nil)
            let conditionedHash = try Self.pngHash(try #require(conditionedResult.artifacts.first),
                                                   root: files.artifacts)
            let unconditionedHash = try Self.pngHash(try #require(unconditionedResult.artifacts.first),
                                                     root: files.artifacts)
            // This proves that image conditioning reached production math. It is not a
            // universal claim about perceptual quality or preservation of unedited regions.
            #expect(conditionedHash != unconditionedHash)
            _ = try Self.releasedEvent(await trace.events(for: conditioned.id))
            _ = try Self.releasedEvent(await trace.events(for: unconditioned.id))
            expectNoLateOutputs(await trace.entries())
            try await backend.cleanupUnpublishedArtifacts()
        }
    }

    private struct NormalizationEvidence: Sendable {
        let fp32: [Float]
        let bfloat16: [Float]
        let expectedBFloat16: [Float]
        let legacyIntermediateBFloat16: [Float]
    }

    @inline(never)
    private static func normalizationEvidence() throws -> NormalizationEvidence {
        // Two RGB rows. The expected host array below is independently ordered NCHW.
        let rgb: [UInt8] = [0, 127, 128, 255, 128, 127,
                            128, 255, 0, 127, 0, 255]
        let input = ImageReferenceInput(rgb: Data(rgb), sha256: "known", width: 2, height: 2,
                                        encoding: "rgb8-srgb-v1")
        let fp32 = try Flux2ImageMath.referenceTensor(input, dtype: .float32)
        let bfloat16 = try Flux2ImageMath.referenceTensor(input, dtype: .bfloat16)
        let knownNCHW: [Float] = [
            -1, 1, Float(128) / 127.5 - 1, Float(127) / 127.5 - 1,
            Float(127) / 127.5 - 1, Float(128) / 127.5 - 1, 1, -1,
            Float(128) / 127.5 - 1, Float(127) / 127.5 - 1, -1, 1,
        ]
        let expectedBFloat16 = MLXArray(knownNCHW, [1, 3, 2, 2]).asType(.bfloat16)
        let bytes = MLXArray(Data(rgb), [1, 2, 2, 3], dtype: .uint8)
        let legacy = (bytes.asType(.bfloat16) / MLXArray(Float(127.5)).asType(.bfloat16)
                      - MLXArray(Float(1)).asType(.bfloat16)).transposed(0, 3, 1, 2)
        MLX.eval(fp32, bfloat16, expectedBFloat16, legacy)
        #expect(fp32.shape == [1, 3, 2, 2] && fp32.dtype == .float32)
        #expect(bfloat16.shape == [1, 3, 2, 2] && bfloat16.dtype == .bfloat16)
        return NormalizationEvidence(
            fp32: fp32.asArray(Float.self),
            bfloat16: bfloat16.asType(.float32).asArray(Float.self),
            expectedBFloat16: expectedBFloat16.asType(.float32).asArray(Float.self),
            legacyIntermediateBFloat16: legacy.asType(.float32).asArray(Float.self))
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
            root: root, image: tensor("image", in: inputs).asType(.float32),
            targetBatch: rawLatents.dim(0))
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
    private static func prepareFixtureReference(root: URL, image: MLXArray,
                                                targetBatch: Int) throws
        -> Flux2ImageMath.ReferenceConditioning {
        let vae = try Flux2AutoencoderKL.load(from: root, dtype: .float32)
        try Flux2ImageMath.validateVAEEncoderWeightCoverage(
            vae: vae, snapshot: root, expectedDType: .float32)
        return try Flux2ImageMath.prepareReference(
            vae: vae, image: image, dtype: .float32, targetBatch: targetBatch)
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

    private static let realRevision = "ef52ee019fd1d0e75ae4deb40476ba65989716d7"
    private static let realPrompt = "Transform the reference into a cobalt blue ceramic mosaic under warm studio light."

    private static func knownReferenceData(width: Int, height: Int) -> Data {
        let values: [UInt8] = [0, 127, 128, 255]
        var data = Data(count: width * height * 3)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in bytes.indices { bytes[index] = values[index % values.count] }
        }
        return data
    }

    private static func knownReferenceInput(width: Int, height: Int) -> ImageReferenceInput {
        ImageReferenceInput(rgb: knownReferenceData(width: width, height: height), sha256: "known",
                            width: width, height: height, encoding: "rgb8-srgb-v1")
    }

    private struct RealReferenceFiles {
        let temporary: TemporaryModelDirectory
        let artifacts: URL
        let reference: ImageReference

        init() throws {
            let temporary = try TemporaryModelDirectory()
            do {
                let artifacts = temporary.url.appendingPathComponent("artifacts", isDirectory: true)
                try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
                let file = temporary.url.appendingPathComponent("reference.rgb")
                let rgb = Flux2ReferenceMathTests.knownReferenceData(width: 512, height: 512)
                try rgb.write(to: file, options: .withoutOverwriting)
                let digest = SHA256.hash(data: rgb).map { String(format: "%02x", $0) }.joined()
                self.temporary = temporary
                self.artifacts = artifacts
                reference = ImageReference(url: file, sha256: digest, byteCount: UInt64(rgb.count),
                                           width: 512, height: 512)
            } catch {
                temporary.remove()
                throw error
            }
        }

        func remove() { temporary.remove() }
    }

    private static func realImageModelDirectory() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["D_TEST_IMAGE_MODEL_DIR"])
        try #require(!path.isEmpty)
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
                     && isDirectory.boolValue)
        return root
    }

    private static func realRequest(model: URL, reference: ImageReference?, seed: UInt64) -> InferenceRequest {
        let profile = reference == nil
            ? ImageExecutionCapability.scalableKlein4B.profile
            : ImageExecutionCapability.referenceKlein4B.profile
        return InferenceRequest(
            model: ModelReference(directory: model, revision: realRevision),
            input: .image(ImageRequest(prompt: realPrompt, width: 512, height: 512,
                                       steps: 4, guidanceScale: 1, seed: seed,
                                       executionProfile: profile, referenceImage: reference)))
    }

    private struct CollectedImageRun: Sendable {
        let outputs: [InferenceOutput]
        let outcome: RunOutcome
        let streamFailed: Bool
    }

    private static func collect(_ run: InferenceRun, trace: MLXTestTrace) async -> CollectedImageRun {
        var outputs: [InferenceOutput] = []
        var streamFailed = false
        do { for try await output in run.events { outputs.append(output) } }
        catch { streamFailed = true }
        let outcome = await run.outcome()
        await trace.terminal(run.id)
        return CollectedImageRun(outputs: outputs, outcome: outcome, streamFailed: streamFailed)
    }

    private static func completedImage(_ collected: CollectedImageRun, root: URL) throws -> InferenceResult {
        #expect(!collected.streamFailed)
        guard case .completed(let result) = collected.outcome else {
            Issue.record("Expected completed real image inference, received \(collected.outcome)")
            throw CocoaError(.coderInvalidValue)
        }
        #expect(result.artifacts.count == 1)
        let artifact = try #require(result.artifacts.first)
        let expectedOutputs = (0...4).map { InferenceOutput.progress(completed: $0, total: 4) }
            + [.artifact(artifact)]
        #expect(collected.outputs == expectedOutputs)
        _ = try pngHash(artifact, root: root)
        return result
    }

    private static func completedReference(_ collected: CollectedImageRun, root: URL,
                                           reference: ImageReference) throws -> InferenceResult {
        let result = try completedImage(collected, root: root)
        #expect(result.metadata["imageExecutionProfile"] == "referenceKlein4B")
        #expect(result.metadata["imageExecutionProfileRevision"] == "1")
        #expect(result.metadata["referenceImageSHA256"] == reference.sha256)
        #expect(result.metadata["referenceImageByteCount"] == String(reference.byteCount))
        #expect(result.metadata["referenceImageWidth"] == "512")
        #expect(result.metadata["referenceImageHeight"] == "512")
        #expect(result.metadata["referenceImageEncoding"] == "rgb8-srgb-v1")
        #expect(result.metadata["referenceConditioningApplied"] == "true")
        #expect(result.metadata["referenceImageIDScale"] == "10")
        #expect(result.metadata["generatedImageIDScale"] == "0")
        #expect((result.metadata["referenceLatentTokenCount"].flatMap(Int.init) ?? 0) > 0)
        #expect(result.metadata.values.allSatisfy { !$0.contains(reference.url.path) },
                "Reference metadata must not expose its absolute private path")
        return result
    }

    private static func pngHash(_ artifact: ArtifactReference, root: URL) throws -> String {
        #expect(artifact.mediaType == "image/png")
        try #require(artifact.url.isFileURL &&
                     artifact.url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        let data = try Data(contentsOf: artifact.url)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        #expect(image.width == 512 && image.height == 512)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func releasedEvent(_ events: [MLXLifecycleEvent]) throws -> MLXLifecycleEvent {
        #expect(events.map(\.phase).suffix(2) == [.drained, .released])
        #expect(events.filter { $0.phase == .drained }.count == 1)
        #expect(events.filter { $0.phase == .released }.count == 1)
        let released = try #require(events.last)
        #expect(released.phase == .released)
        #expect(released.memory.activeBytes == 0)
        #expect(released.memory.cacheBytes == 0)
        return released
    }

    private static func expectBefore(_ entries: [MLXTraceEntry], first: UUID, second: UUID) throws {
        let released = try #require(entries.firstIndex {
            if case .lifecycle(let event) = $0 {
                return event.runID == first && event.phase == .released
            }
            return false
        })
        let verifying = try #require(entries.firstIndex {
            if case .lifecycle(let event) = $0 {
                return event.runID == second && event.phase == .verifying
            }
            return false
        })
        #expect(released < verifying)
    }

    private struct ReferenceTracedBackend: InferenceBackend {
        let backend: MLXImageBackend
        let trace: MLXTestTrace
        var blockedRun: UUID?
        var gate: MLXTestGate?

        var descriptor: BackendDescriptor { backend.descriptor }

        func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
            do { return try await backend.estimate(request) }
            catch {
                if request.id == blockedRun { await gate?.executionFinished() }
                throw error
            }
        }

        func execute(_ request: InferenceRequest,
                     emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
            do {
                let result = try await backend.execute(request) { output in
                    await trace.output(request.id)
                    try await emit(output)
                }
                if request.id == blockedRun { await gate?.executionFinished() }
                return result
            } catch {
                if request.id == blockedRun { await gate?.executionFinished() }
                throw error
            }
        }

        func release() async { await backend.release() }
    }

    private static func withRealRuntime<Value: Sendable>(
        _ backend: any InferenceBackend,
        operation: (InferenceRuntime) async throws -> Value) async throws -> Value {
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(
            memoryBudgetBytes: 12 * 1024 * 1024 * 1024,
            maximumQueuedRuns: 2, eventBufferCapacity: 2_048))
        do {
            let value = try await operation(runtime)
            await runtime.shutdown()
            return value
        } catch {
            await runtime.shutdown()
            throw error
        }
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

    @inline(never)
    private static func withFixtureRandomState<Value>(_ body: () throws -> Value) rethrows -> Value {
        let state = MLXRandom.RandomState(seed: 0)
        return try withRandomState(state, body: body)
    }

    private static func cleanup() {
        MLX.Stream.gpu.synchronize()
        MLX.Stream.cpu.synchronize()
        Flux2RuntimeResources.clearCaches()
        Memory.clearCache()
    }
}
}
