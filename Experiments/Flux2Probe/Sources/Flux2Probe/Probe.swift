// Isolated hardware experiment; this is not the production D inference backend.
// Schedule helpers below are adapted without changing their calculations from
// mzbac/flux2.swift, commit 959a4af7c0721c800851c84431ffd3fa1f353f1f,
// Sources/Flux2/Schedulers/FlowMatchEulerDiscreteScheduler.swift (Apache-2.0).
// Upstream license: https://github.com/mzbac/flux2.swift/blob/959a4af7c0721c800851c84431ffd3fa1f353f1f/LICENSE

import CoreGraphics
import Darwin
import Flux2
import Foundation
import ImageIO
import MLX
import MLXNN
import MLXRandom
import UniformTypeIdentifiers

private enum Fixed {
    static let width = 512
    static let height = 512
    static let steps = 4
    static let maxLength = 512
    static let prompt = "A red ceramic teapot on a wooden table beside a window, soft morning light, detailed studio photograph."
    static let repository = "mzbac/FLUX.2-klein-4B-q8"
    static let revision = "ef52ee019fd1d0e75ae4deb40476ba65989716d7"
    static let sourceRevision = "959a4af7c0721c800851c84431ffd3fa1f353f1f"
}

private struct Options {
    let model: URL
    let output: URL
    let report: URL
    let seed: UInt64
    let stopAfterStep: Int?
    let runIndex: Int
    let runCount: Int

    static let usage = """
    Usage: Flux2Probe --model /absolute/local/snapshot --output /absolute/image.png
                      --report /absolute/report.json [--seed 42] [--stop-after-step 1...4]
                      [--repeat 1...3]
    Fixed: FLUX.2 Klein 4B q8, 512 x 512, 4 steps, guidance 1, 512 text tokens.
    The snapshot must already exist. Output/report parents must exist; targets must be new.
    --stop-after-step evaluates that step, releases local model scopes, records cleanup,
    produces no PNG, and exits 130. This is a cleanup probe, not a signal harness.
    --repeat runs in one process with the same seed; later output/report names gain -2/-3.
    All targets are checked before the first run. A stop or failure ends the remaining runs.
    Tiny numerical fixture only: --fixture-only /absolute/fixture --report /absolute/report.json
    """

    static func parse(_ arguments: [String]) throws -> Options? {
        if arguments == ["--help"] { return nil }
        let allowed: Set<String> = ["--model", "--output", "--report", "--seed", "--stop-after-step", "--repeat"]
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard allowed.contains(flag), values[flag] == nil else {
                throw ProbeError.invalidArgument("Unknown or duplicate argument: \(flag)")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw ProbeError.invalidArgument("Missing value for \(flag)")
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        func absoluteURL(_ key: String) throws -> URL {
            guard let value = values[key], value.hasPrefix("/"), !value.contains("\0") else {
                throw ProbeError.invalidArgument("\(key) requires an absolute filesystem path")
            }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        let model = try absoluteURL("--model")
        let output = try absoluteURL("--output")
        let report = try absoluteURL("--report")
        guard let runCount = Int(values["--repeat"] ?? "1"), (1...3).contains(runCount) else {
            throw ProbeError.invalidArgument("--repeat must be an integer between 1 and 3")
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: model.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProbeError.invalidArgument("The model snapshot directory does not exist: \(model.path)")
        }
        let resolvedModel = model.resolvingSymlinksInPath()
        guard output.pathExtension.lowercased() == "png", report.pathExtension.lowercased() == "json",
              output != report else {
            throw ProbeError.invalidArgument("Output must be .png and report must be a distinct .json file")
        }
        let destinations = (1...runCount).flatMap { index in
            [numberedURL(output, index: index), numberedURL(report, index: index)]
        }
        for destination in destinations {
            let parent = destination.deletingLastPathComponent()
            guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProbeError.invalidArgument("Destination parent must already exist: \(parent.path)")
            }
            let resolved = parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent)
            guard resolved.path != resolvedModel.path,
                  !resolved.path.hasPrefix(resolvedModel.path + "/") else {
                throw ProbeError.invalidArgument("Output/report must be outside the model snapshot")
            }
            // attributesOfItem also detects a dangling symbolic link, unlike fileExists.
            guard (try? fm.attributesOfItem(atPath: destination.path)) == nil else {
                throw ProbeError.invalidArgument("Refusing to overwrite an existing target: \(destination.path)")
            }
        }
        // These checks select a local snapshot. Integrity/provenance is established by
        // the separate pinned downloader; this probe does not claim to rehash 9.4 GB.
        for relative in ["model_index.json", "text_encoder/config.json", "tokenizer/tokenizer_config.json",
                         "transformer/config.json", "vae/config.json"] {
            let file = model.appendingPathComponent(relative)
            guard fm.isReadableFile(atPath: file.path) else {
                throw ProbeError.invalidArgument("Missing local snapshot file: \(file.path)")
            }
        }
        guard let seed = UInt64(values["--seed"] ?? "42") else {
            throw ProbeError.invalidArgument("--seed must be an unsigned 64-bit integer")
        }
        var stopAfterStep: Int?
        if let raw = values["--stop-after-step"] {
            guard let step = Int(raw), (1...Fixed.steps).contains(step) else {
                throw ProbeError.invalidArgument("--stop-after-step must be between 1 and 4")
            }
            stopAfterStep = step
        }
        return Options(model: model, output: output, report: report, seed: seed,
                       stopAfterStep: stopAfterStep, runIndex: 1, runCount: runCount)
    }

    func forRun(_ index: Int) -> Options {
        Options(model: model, output: Self.numberedURL(output, index: index),
                report: Self.numberedURL(report, index: index), seed: seed,
                stopAfterStep: stopAfterStep, runIndex: index, runCount: runCount)
    }

    private static func numberedURL(_ url: URL, index: Int) -> URL {
        guard index > 1 else { return url }
        let name = url.deletingPathExtension().lastPathComponent + "-\(index)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
            .appendingPathExtension(url.pathExtension)
    }
}

private struct FixtureOptions {
    let root: URL
    let report: URL

    static func parse(_ arguments: [String]) throws -> FixtureOptions {
        guard arguments.count == 4 else {
            throw ProbeError.invalidArgument("Fixture mode accepts only --fixture-only PATH and --report PATH")
        }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let flag = arguments[index]
            let value = arguments[index + 1]
            guard ["--fixture-only", "--report"].contains(flag), values[flag] == nil,
                  value.hasPrefix("/"), !value.contains("\0") else {
                throw ProbeError.invalidArgument("Invalid fixture argument or nonabsolute path: \(flag)")
            }
            values[flag] = value
        }
        guard let rootPath = values["--fixture-only"], let reportPath = values["--report"] else {
            throw ProbeError.invalidArgument("Fixture mode requires --fixture-only and --report")
        }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let report = URL(fileURLWithPath: reportPath).standardizedFileURL
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.fileExists(atPath: report.deletingLastPathComponent().path, isDirectory: &isDirectory),
              isDirectory.boolValue, report.pathExtension.lowercased() == "json",
              (try? fm.attributesOfItem(atPath: report.path)) == nil else {
            throw ProbeError.invalidArgument("Fixture must be a directory; report must be a new .json file in an existing directory")
        }
        let resolvedReport = report.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(report.lastPathComponent)
        guard !resolvedReport.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw ProbeError.invalidArgument("Fixture report must be outside the read-only fixture directory")
        }
        return FixtureOptions(root: root, report: report)
    }
}

private enum ProbeError: Error, LocalizedError {
    case invalidArgument(String)
    case invalidTensor(String)
    case image(String)
    case stoppedAfterStep(Int)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let text), .invalidTensor(let text), .image(let text): return text
        case .stoppedAfterStep(let step): return "Requested stop after evaluated denoising step \(step)"
        }
    }
}

private struct MemoryStage: Codable {
    let name: String
    let elapsedSeconds: Double
    let intervalSeconds: Double
    let activeBytes: Int
    let cacheBytes: Int
    let intervalPeakBytes: Int
    let largestObservedPeakBytes: Int
    let processMaximumResidentBytes: Int64?
    let cacheWasCleared: Bool
    let shapes: [String: [Int]]?
}

private struct Artifact: Codable {
    let path: String
    let bytes: Int
    let width: Int
    let height: Int
    let decodedShape: [Int]
    let decodedPixelsFinite: Bool
    let pngDecodedAndValidated: Bool
}

private struct Report: Encodable {
    let schemaVersion = 1
    let modelRepositoryExpected = Fixed.repository
    let modelRevisionExpected = Fixed.revision
    let flux2SourceRevision = Fixed.sourceRevision
    let modelSnapshot: String
    let outputRequested: String
    let prompt = Fixed.prompt
    let width = Fixed.width
    let height = Fixed.height
    let inferenceSteps = Fixed.steps
    let guidanceScale = 1.0
    let modelTimestepScale = 0.001
    let textMaxLength = Fixed.maxLength
    let seed: UInt64
    let stopAfterStep: Int?
    let runIndex: Int
    let runCount: Int
    let allocatorMemoryLimitBytes: Int
    let allocatorCacheLimitBytes: Int
    let notes = [
        "The expected model identity is pinned by the separate downloader; this probe does not rehash weights.",
        "MLX memoryLimit is an allocator scheduling setting, not a hard process RSS cap.",
        "Each interval peak is reset after its checkpoint; active/cache are sampled after stream synchronization.",
        "Allocator statistics exclude some CPU/Metal/process allocations; the parent monitors process RSS separately.",
        "Repeats share one process. Allocator peaks reset per run; live allocations remain in the next run's baseline.",
        "processMaximumResidentBytes is the process lifetime high-water mark, not a per-run RSS peak.",
        "Flux2AttentionMaskCache has no public clear API at the pinned revision; final residual active memory is recorded without asserting zero.",
        "Cancellation checks occur at explicit stage/step boundaries and cannot interrupt an already running GPU kernel.",
    ]
    var status = "running"
    var elapsedSeconds = 0.0
    var stages: [MemoryStage] = []
    var timesteps: [Float]?
    var sigmas: [Float]?
    var artifact: Artifact?
    var error: String?
}

private final class Recorder {
    private let start = ProcessInfo.processInfo.systemUptime
    private var previous: Double
    private var largestPeak = 0
    private let destination: URL
    var report: Report

    init(options: Options) {
        previous = start
        destination = options.report
        report = Report(
            modelSnapshot: options.model.path, outputRequested: options.output.path,
            seed: options.seed, stopAfterStep: options.stopAfterStep,
            runIndex: options.runIndex, runCount: options.runCount,
            allocatorMemoryLimitBytes: Memory.memoryLimit,
            allocatorCacheLimitBytes: Memory.cacheLimit
        )
    }

    func checkpoint(_ name: String, clearCache: Bool = false, shapes: [String: [Int]]? = nil) throws {
        drainStreams()
        let peak = Memory.peakMemory
        largestPeak = max(largestPeak, peak)
        if clearCache { Memory.clearCache() }
        let now = ProcessInfo.processInfo.systemUptime
        var usage = rusage()
        // On macOS ru_maxrss is bytes. It is separate from MLX allocator accounting.
        let maximumResident = getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : nil
        let stage = MemoryStage(
            name: name, elapsedSeconds: now - start, intervalSeconds: now - previous,
            activeBytes: Memory.activeMemory, cacheBytes: Memory.cacheMemory,
            intervalPeakBytes: peak, largestObservedPeakBytes: largestPeak,
            processMaximumResidentBytes: maximumResident,
            cacheWasCleared: clearCache, shapes: shapes
        )
        report.stages.append(stage)
        report.elapsedSeconds = now - start
        previous = now
        Memory.peakMemory = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: destination, options: .atomic)
        stderr("\(name): elapsed=\(String(format: "%.3f", stage.elapsedSeconds))s active=\(stage.activeBytes) cache=\(stage.cacheBytes) intervalPeak=\(peak)")
    }
}

private func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func drainStreams() {
    MLX.Stream.gpu.synchronize()
    MLX.Stream.cpu.synchronize()
}

private struct Denoised {
    let latents: MLXArray
    let ids: MLXArray
}

// Each synchronous helper owns its model. Evaluated arrays alone cross these
// boundaries; no detached tasks, unchecked Sendable conformances, or model singletons.
@inline(never)
private func encodePrompt(options: Options, recorder: Recorder) throws -> Flux2PromptEncoding {
    try Task.checkCancellation()
    try recorder.checkpoint("text_encoder_load_started")
    let encoder = try Flux2KleinPromptEncoder(
        snapshot: options.model, dtype: .bfloat16, hiddenStateLayers: [9, 18, 27],
        maxLengthOverride: Fixed.maxLength
    )
    MLX.eval(encoder.textEncoder)
    try recorder.checkpoint("text_encoder_loaded")
    try Task.checkCancellation()
    let encoding = try encoder.encodePrompts([Fixed.prompt], maxLength: Fixed.maxLength)
    MLX.eval(encoding.promptEmbeds, encoding.textIds, encoding.inputIds, encoding.attentionMask)
    guard encoding.inputIds.shape == [1, Fixed.maxLength],
          encoding.promptEmbeds.ndim == 3,
          encoding.promptEmbeds.dim(0) == 1,
          encoding.promptEmbeds.dim(1) == Fixed.maxLength else {
        throw ProbeError.invalidTensor("Unexpected prompt shapes: ids=\(encoding.inputIds.shape), embeds=\(encoding.promptEmbeds.shape)")
    }
    guard MLX.isFinite(encoding.promptEmbeds).all().item(Bool.self) else {
        throw ProbeError.invalidTensor("Prompt embeddings contain NaN or infinity")
    }
    try recorder.checkpoint("prompt_encoded", shapes: [
        "embeddings": encoding.promptEmbeds.shape, "textIDs": encoding.textIds.shape,
        "inputIDs": encoding.inputIds.shape,
    ])
    return encoding
}

@inline(never)
private func prepareLatents(options: Options, inChannels: Int, dtype: DType, recorder: Recorder) throws -> Flux2PreparedLatents {
    try Task.checkCancellation()
    try recorder.checkpoint("preparation_vae_load_started")
    let vae = try Flux2AutoencoderKL.load(from: options.model, dtype: .bfloat16)
    let patchArea = vae.configuration.patchSizeArea
    guard patchArea > 0, inChannels > 0, inChannels % patchArea == 0 else {
        throw ProbeError.invalidTensor("Transformer channels \(inChannels) are incompatible with VAE patch area \(patchArea)")
    }
    // Seed after all initializers that can consume the global stream, immediately
    // before sampling the requested noise. This is one isolated process and run.
    MLXRandom.seed(options.seed)
    let prepared = try Flux2LatentPreparation.prepareLatents(
        batchSize: 1, numLatentChannels: inChannels / patchArea,
        height: Fixed.height, width: Fixed.width, vae: vae, dtype: dtype
    )
    MLX.eval(prepared.latents, prepared.ids)
    try recorder.checkpoint("latents_prepared", shapes: ["latents": prepared.latents.shape, "latentIDs": prepared.ids.shape])
    return prepared
}

// The upstream convenience methods are internal. These two helpers preserve their
// exact Float operations; only receiver access has changed to explicit arguments.
// Source: FlowMatchEulerDiscreteScheduler.swift:403-436, commit noted above.
private func defaultSigmas(useFlowSigmas: Bool?, numInferenceSteps: Int) -> [Float]? {
    if useFlowSigmas == true { return nil }
    let start: Float = 1.0
    let end: Float = 1.0 / Float(numInferenceSteps)
    if numInferenceSteps <= 1 { return [start] }
    let step = (end - start) / Float(numInferenceSteps - 1)
    return (0..<numInferenceSteps).map { start + Float($0) * step }
}

private func empiricalMu(imageSeqLen: Int, numSteps: Int) -> Float {
    let a1: Float = 8.73809524e-05
    let b1: Float = 1.89833333
    let a2: Float = 0.00016927
    let b2: Float = 0.45666666
    if imageSeqLen > 4300 { return a2 * Float(imageSeqLen) + b2 }
    let m200 = a2 * Float(imageSeqLen) + b2
    let m10 = a1 * Float(imageSeqLen) + b1
    let a = (m200 - m10) / 190.0
    let b = m200 - 200.0 * a
    return a * Float(numSteps) + b
}

@inline(never)
private func evaluatedStep(_ denoiser: Flux2Denoiser, current: MLXArray, step: Float,
                           promptEmbeds: MLXArray, textIds: MLXArray, ids: MLXArray) throws -> MLXArray {
    let timestep = MLX.full([current.dim(0)], values: step).asType(current.dtype)
    let output = try denoiser.step(
        latents: current, encoderHiddenStates: promptEmbeds, timestep: timestep,
        imgIds: ids, txtIds: textIds, guidance: nil,
        attentionMask: .none, modelTimestepScale: 0.001
    )
    MLX.eval(output.prevLatents)
    return output.prevLatents
}

// Shared by the real 4B path and the independent tiny-fixture numerical comparison.
// Callback indices are 1-based; onStep observes already evaluated, finite latents.
@inline(never)
func probeDenoise(
    transformer: Flux2Transformer2DModel, scheduler: FlowMatchEulerDiscreteScheduler,
    latents: MLXArray, ids: MLXArray, promptEmbeds: MLXArray, textIds: MLXArray,
    steps: Int, beforeStep: (Int) throws -> Void = { _ in },
    onStep: (Int, MLXArray) throws -> Void = { _, _ in }
) throws -> MLXArray {
    guard steps > 0, latents.ndim == 3, latents.dim(0) > 0 else {
        throw ProbeError.invalidTensor("Invalid denoising steps or packed latent shape")
    }
    let sigmas = defaultSigmas(useFlowSigmas: scheduler.config.useFlowSigmas, numInferenceSteps: steps)
    let mu = scheduler.config.useDynamicShifting
        ? empiricalMu(imageSeqLen: latents.dim(1), numSteps: steps) : nil
    try scheduler.setTimesteps(numInferenceSteps: steps, sigmas: sigmas, mu: mu)
    scheduler.setBeginIndex(0)
    guard scheduler.timestepsValues.count == steps else {
        throw ProbeError.invalidTensor("Scheduler produced \(scheduler.timestepsValues.count) steps, expected \(steps)")
    }
    let denoiser = Flux2Denoiser(transformer: transformer, scheduler: scheduler)
    var current = latents
    for (index, step) in scheduler.timestepsValues.enumerated() {
        try Task.checkCancellation()
        try beforeStep(index + 1)
        current = try evaluatedStep(denoiser, current: current, step: step,
                                    promptEmbeds: promptEmbeds, textIds: textIds, ids: ids)
        guard MLX.isFinite(current).all().item(Bool.self) else {
            throw ProbeError.invalidTensor("Denoising step \(index + 1) produced NaN or infinity")
        }
        try onStep(index + 1, current)
        try Task.checkCancellation()
    }
    MLX.eval(current, ids)
    return current
}

@inline(never)
private func denoise(options: Options, encoding: Flux2PromptEncoding, recorder: Recorder) throws -> Denoised {
    try Task.checkCancellation()
    try recorder.checkpoint("transformer_load_started")
    let transformer = try Flux2Transformer2DModel.load(from: options.model, dtype: .bfloat16)
    MLX.eval(transformer)
    let scheduler = try FlowMatchEulerDiscreteScheduler.load(from: options.model)
    try recorder.checkpoint("transformer_loaded")
    let prepared = try prepareLatents(
        options: options, inChannels: transformer.configuration.inChannels,
        dtype: encoding.promptEmbeds.dtype, recorder: recorder
    )
    try recorder.checkpoint("preparation_vae_released", clearCache: true)
    let current = try probeDenoise(
        transformer: transformer, scheduler: scheduler, latents: prepared.latents, ids: prepared.ids,
        promptEmbeds: encoding.promptEmbeds, textIds: encoding.textIds, steps: Fixed.steps,
        beforeStep: { step in
            recorder.report.timesteps = scheduler.timestepsValues
            recorder.report.sigmas = scheduler.sigmasValues
            try recorder.checkpoint("denoise_step_\(step)_started")
        },
        onStep: { step, current in
            try recorder.checkpoint("denoise_step_\(step)_evaluated", shapes: ["latents": current.shape])
            try Task.checkCancellation()
            if options.stopAfterStep == step { throw ProbeError.stoppedAfterStep(step) }
        }
    )
    return Denoised(latents: current, ids: prepared.ids)
}

@inline(never)
private func generateLatents(options: Options, recorder: Recorder) throws -> Denoised {
    let encoding = try encodePrompt(options: options, recorder: recorder)
    try recorder.checkpoint("text_encoder_released", clearCache: true)
    return try denoise(options: options, encoding: encoding, recorder: recorder)
}

@inline(never)
func probeDecode(vae: Flux2AutoencoderKL, latents: MLXArray, ids: MLXArray) throws -> MLXArray {
    try Task.checkCancellation()
    let unpacked = try Flux2LatentUtils.unpackLatentsWithIds(latents, ids: ids)
    let input = try Flux2LatentUtils.denormalizeAndUnpatchify(unpacked, vae: vae)
    let decoded = vae.decode(input)
    MLX.eval(decoded)
    guard MLX.isFinite(decoded).all().item(Bool.self) else {
        throw ProbeError.invalidTensor("VAE pixels contain NaN or infinity before clipping")
    }
    return decoded
}

@inline(never)
private func decode(options: Options, denoised: Denoised, recorder: Recorder) throws -> MLXArray {
    try Task.checkCancellation()
    try recorder.checkpoint("decode_vae_load_started")
    let vae = try Flux2AutoencoderKL.load(from: options.model, dtype: .bfloat16)
    MLX.eval(vae)
    try recorder.checkpoint("decode_vae_loaded")
    try Task.checkCancellation()
    let decoded = try probeDecode(vae: vae, latents: denoised.latents, ids: denoised.ids)
    guard decoded.shape == [1, 3, Fixed.height, Fixed.width] else {
        throw ProbeError.invalidTensor("Expected decoded shape [1, 3, 512, 512], received \(decoded.shape)")
    }
    try recorder.checkpoint("vae_decoded", shapes: ["decoded": decoded.shape])
    return decoded
}

private func writePNG(_ decoded: MLXArray, to destination: URL) throws -> Artifact {
    try Task.checkCancellation()
    // Same NCHW [-1, 1] -> RGB [0, 255] transformation as the upstream CLI.
    let rgb = (MLX.clip(decoded[0].asType(.float32) / 2 + 0.5, min: 0, max: 1) * 255)
        .transposed(1, 2, 0).reshaped(-1).asType(.uint8).asArray(UInt8.self)
    guard rgb.count == Fixed.width * Fixed.height * 3 else {
        throw ProbeError.image("Unexpected byte count after pixel conversion")
    }
    var rgba = [UInt8](repeating: 255, count: Fixed.width * Fixed.height * 4)
    for pixel in 0..<(Fixed.width * Fixed.height) {
        rgba[pixel * 4] = rgb[pixel * 3]
        rgba[pixel * 4 + 1] = rgb[pixel * 3 + 1]
        rgba[pixel * 4 + 2] = rgb[pixel * 3 + 2]
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(
            width: Fixed.width, height: Fixed.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Fixed.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
          ) else { throw ProbeError.image("Could not create CGImage") }
    let temporary = destination.deletingLastPathComponent()
        .appendingPathComponent(".flux2-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let writer = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw ProbeError.image("Could not create PNG destination")
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer),
          let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
          CGImageSourceGetCount(source) == 1,
          let type = CGImageSourceGetType(source), (type as String) == UTType.png.identifier,
          let validated = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
          validated.width == Fixed.width, validated.height == Fixed.height else {
        throw ProbeError.image("Saved PNG failed ImageIO decoding/shape validation")
    }
    let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
    guard let bytes = size?.intValue, bytes > 0 else { throw ProbeError.image("Saved PNG is empty") }
    try Task.checkCancellation()
    // moveItem refuses an existing destination; the input snapshot is never modified.
    try FileManager.default.moveItem(at: temporary, to: destination)
    return Artifact(path: destination.path, bytes: bytes, width: validated.width, height: validated.height,
                    decodedShape: decoded.shape, decodedPixelsFinite: true, pngDecodedAndValidated: true)
}

@inline(never)
private func runProbe(options: Options, recorder: Recorder) throws -> Artifact {
    let denoised = try generateLatents(options: options, recorder: recorder)
    try recorder.checkpoint("transformer_and_conditioning_released", clearCache: true,
                            shapes: ["latents": denoised.latents.shape, "latentIDs": denoised.ids.shape])
    let decoded = try decode(options: options, denoised: denoised, recorder: recorder)
    try recorder.checkpoint("decode_vae_released", clearCache: true)
    let artifact = try writePNG(decoded, to: options.output)
    try recorder.checkpoint("png_validated")
    return artifact
}

// All per-run tensors and error values are scoped here. Only an exit code crosses
// into the repeat loop; live allocations and upstream static caches stay observable.
@inline(never)
private func executeRun(options: Options) -> Int32 {
    Memory.peakMemory = 0
    let recorder = Recorder(options: options)
    var exitCode: Int32 = 0
    do {
        try recorder.checkpoint("probe_started", clearCache: true)
        recorder.report.artifact = try autoreleasepool { try runProbe(options: options, recorder: recorder) }
        recorder.report.status = "completed"
    } catch ProbeError.stoppedAfterStep(let step) {
        recorder.report.status = "stopped"
        recorder.report.error = ProbeError.stoppedAfterStep(step).localizedDescription
        exitCode = 130
    } catch is CancellationError {
        recorder.report.status = "cancelled"
        recorder.report.error = "Task cancellation observed at an explicit boundary"
        exitCode = 130
    } catch {
        recorder.report.status = "failed"
        recorder.report.error = error.localizedDescription
        exitCode = 1
    }
    // Model/tensor helpers have unwound on success, stop, and thrown failure.
    // Synchronize both default streams before clearing free allocator blocks.
    // Fatal native errors and process termination cannot run this cleanup.
    drainStreams()
    Memory.clearCache()
    do {
        try recorder.checkpoint("all_local_scopes_released", clearCache: true)
    } catch {
        stderr("Could not persist final report: \(error.localizedDescription)")
        exitCode = 1
    }
    if let error = recorder.report.error { stderr(error) }
    print(options.report.path)
    return exitCode
}

@main
private struct Flux2Probe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--fixture-only") {
            let fixture: FixtureOptions
            do {
                fixture = try FixtureOptions.parse(arguments)
            } catch {
                stderr(error.localizedDescription + "\n" + Options.usage)
                exit(2)
            }
            var fixtureExitCode: Int32 = 0
            do {
                try autoreleasepool { try runFixtureParity(fixtureRoot: fixture.root, reportURL: fixture.report) }
            } catch {
                stderr("Tiny fixture comparison failed: \(error.localizedDescription)")
                fixtureExitCode = 1
            }
            drainStreams()
            Memory.clearCache()
            print(fixture.report.path)
            exit(fixtureExitCode)
        }
        let options: Options
        do {
            guard let parsed = try Options.parse(arguments) else {
                print(Options.usage)
                return
            }
            options = parsed
        } catch {
            stderr(error.localizedDescription + "\n" + Options.usage)
            exit(2)
        }

        // Verified against vendored MLX Swift 0.30.6 Memory.swift: this setting
        // makes allocation wait on scheduled work; it is NOT a process memory cap.
        Memory.memoryLimit = 10 * 1024 * 1024 * 1024
        Memory.cacheLimit = 256 * 1024 * 1024
        var exitCode: Int32 = 0
        for index in 1...options.runCount {
            stderr("Starting run \(index)/\(options.runCount) with seed \(options.seed)")
            exitCode = executeRun(options: options.forRun(index))
            if exitCode != 0 { break }
        }
        exit(exitCode)
    }
}
