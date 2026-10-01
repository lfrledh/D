import CryptoKit
import DInference
import DRuntime
import Foundation
import Testing
@testable import DMLXBackend

/// Full representative sampling is separate from the historical connectivity smoke.
/// This opt-in test never downloads, substitutes a model, or publishes to a user project.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["D_TEST_VIDEO_REPRESENTATIVE"] == "1"))
struct ExternalVideoRepresentativeTests {
    @Test(.timeLimit(.minutes(1440)))
    func textAndNativeFrameConditions() async throws {
        let env = ProcessInfo.processInfo.environment
        let profileName = try #require(env["D_TEST_REAL_VIDEO_PROFILE"])
        let profile = try #require(ExternalVideoExecutionProfile(rawValue: profileName))
        try #require(profile == .h3BF16Full || profile == .ltx25BF16Full)
        let engine = URL(fileURLWithPath: try #require(env["D_TEST_REAL_VIDEO_ENGINE"]))
        let pack = URL(fileURLWithPath: try #require(env["D_TEST_REAL_VIDEO_PACK"]))
        let root = URL(fileURLWithPath: try #require(env["D_TEST_EXTERNAL_VIDEO_ROOT"]))
            .appendingPathComponent("representative-" + UUID().uuidString)
        let outputs = root.appendingPathComponent("outputs")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        let manifestURL = pack.appendingPathComponent(ExternalVideoModelManifest.filename)
        let originalManifest = try Data(contentsOf: manifestURL)
        let isH3 = profile == .h3BF16Full
        let width = isH3 ? 512 : 704, height = isH3 ? 512 : 480
        func reference(_ name: String, blue: Bool) throws -> VideoFrameReference {
            var rgb = [UInt8](repeating: 32, count: width * height * 3)
            for y in 0..<height { for x in 0..<width {
                let offset = (y * width + x) * 3
                if (width / 4..<width * 3 / 4).contains(x) && (height / 4..<height * 3 / 4).contains(y) {
                    rgb[offset + (blue ? 2 : 0)] = 210
                }
            } }
            let data = try ImagePNG.encode(rgb: rgb, width: width, height: height)
            let file = root.appendingPathComponent(name + ".png")
            try data.write(to: file, options: .withoutOverwriting)
            return .init(url: file, width: width, height: height, byteCount: UInt64(data.count),
                contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let first = try reference("first", blue: false)
        let last = isH3 ? try reference("last", blue: true) : nil
        let backend = try ExternalVideoBackend(configuration: .init(profile: profile,
            pythonExecutable: engine.appendingPathComponent("python/bin/python3"),
            providerScript: engine.appendingPathComponent("provider/app_video_driver.py"),
            ffmpeg: engine.appendingPathComponent("native/ffmpeg"), ffprobe: engine.appendingPathComponent("native/ffprobe"),
            h3Executable: isH3 ? engine.appendingPathComponent("native/h3") : nil,
            h3Shader: isH3 ? engine.appendingPathComponent("native/h3_shaders.metal") : nil,
            artifactDirectory: outputs, timeoutSeconds: 43_200, cancellationGraceSeconds: 10))
        let model = try await backend.validateModel(at: pack)
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 15 * 1_073_741_824))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            for conditioned in [false, true] {
                let name = conditioned ? "conditioned" : "text"
                let video = VideoRequest(
                    prompt: conditioned ? "A red cube slowly rotates on a dark tabletop, steady camera, subtle room ambience."
                        : "A red ceramic cup on a wooden table, steady camera, natural light, quiet room ambience.",
                    negativePrompt: "", width: width, height: height,
                    frameCount: isH3 ? 22 : 97, frameRate: .init(numerator: 24),
                    steps: isH3 ? 50 : 30, guidanceScale: isH3 ? 1 : 3,
                    scheduleShift: 1, seed: 42, executionProfile: profile.reference,
                    adapterOptions: isH3 ? .h3(streamWeights: true) : .ltx(streamWeights: true, spatiotemporalGuidance: 1),
                    firstFrame: conditioned ? first : nil, lastFrame: conditioned ? last : nil)
                let request = InferenceRequest(model: model, input: .video(video))
                try encoder.encode(request).write(to: root.appendingPathComponent(name + "-request.json"), options: .withoutOverwriting)
                print("D_VIDEO_REPRESENTATIVE_START", name, root.path)
                let start = Date(), run = try await runtime.submit(request, backendID: backend.descriptor.id)
                var streamFailure: String?
                do { for try await _ in run.events {} }
                catch { streamFailure = error.localizedDescription }
                let outcome = await run.outcome(), state = await runtime.snapshot()
                try JSONSerialization.data(withJSONObject: ["seconds": Date().timeIntervalSince(start),
                    "outcome": String(describing: outcome), "streamFailure": streamFailure ?? "none",
                    "activeRun": state.activeRunID?.uuidString ?? "none", "reservedBytes": state.reservedBytes,
                    "guiVerified": false, "userStorePublished": false], options: [.sortedKeys])
                    .write(to: root.appendingPathComponent(name + "-terminal.json"), options: .withoutOverwriting)
                #expect(state.activeRunID == nil && state.reservedBytes == 0)
                #expect(streamFailure == nil)
                guard case .completed(let result) = outcome else {
                    try Data(String(describing: outcome).utf8).write(to: root.appendingPathComponent(name + "-failure.txt"))
                    throw InferenceFailure.backendFailed("Representative \(name) failed: \(outcome)")
                }
                #expect(result.artifacts.count == 1 && result.metadata["profile"] == profile.rawValue)
                #expect(result.metadata["streamWeights"] == "true")
                if conditioned {
                    #expect(result.metadata["firstFrameSHA256"] == first.contentSHA256)
                    if let last { #expect(result.metadata["lastFrameSHA256"] == last.contentSHA256) }
                }
                try encoder.encode(result).write(to: root.appendingPathComponent(name + "-result.json"), options: .withoutOverwriting)
                try JSONSerialization.data(withJSONObject: ["seconds": Date().timeIntervalSince(start),
                    "activeRun": state.activeRunID?.uuidString ?? "none", "reservedBytes": state.reservedBytes,
                    "guiVerified": false, "userStorePublished": false], options: [.sortedKeys])
                    .write(to: root.appendingPathComponent(name + "-acceptance.json"), options: .withoutOverwriting)
                #expect(try Data(contentsOf: manifestURL) == originalManifest)
                for frame in [first, last].compactMap({ $0 }) {
                    #expect(SHA256.hash(data: try Data(contentsOf: frame.url)).map { String(format: "%02x", $0) }.joined() == frame.contentSHA256)
                }
                print("D_VIDEO_REPRESENTATIVE_DONE", name, root.path)
            }
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
}
