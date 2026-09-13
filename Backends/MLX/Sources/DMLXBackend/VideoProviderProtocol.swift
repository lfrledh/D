import CryptoKit
import DInference
import Foundation

enum VideoProviderProtocol {
    private static let stages: Set<String> = ["load-text", "encode-text", "release-text", "load-diffusion",
        "denoise", "release-diffusion", "load-vae", "decode", "released"]
    struct Result: Sendable {
        var snapshot: AudioJSONValue?
        var failure: String?
    }

    static func read(_ reader: LocalDedicatedPipeReader, control: LocalOwnedProcessControl,
                     runID: UUID, steps: Int,
                     emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async -> Result {
        var result = Result(), line = Data(), totalBytes = 0
        func fail(_ message: String) {
            if result.failure == nil { result.failure = message; control.requestStop(.protocolFailure(message)) }
        }
        while true {
            switch await reader.next() {
            case .data(let data):
                for byte in data {
                    totalBytes += 1
                    if totalBytes > 16 * 1024 * 1024 { fail("Video provider exceeded its 16 MiB protocol budget.") }
                    if result.failure != nil { continue }
                    if byte == 10 {
                        do {
                            var parser = AudioJSONParser(data: line, maximumDepth: 24)
                            let value = try parser.parse()
                            let object = try value.objectAny(context: "Video event")
                            guard try object["schema"]?.requiredString(context: "schema") == "d.video.frames.v1",
                                  try object["runID"]?.requiredString(context: "runID") == runID.uuidString.lowercased(),
                                  result.snapshot == nil else {
                                throw InferenceFailure.backendFailed("Video event identity or terminal ordering differs.")
                            }
                            switch try object["type"]?.requiredString(context: "type") {
                            case "result": result.snapshot = value
                            case "progress":
                                guard let completed = try object["completed"]?.requiredInteger(context: "completed"),
                                      let total = try object["total"]?.requiredInteger(context: "total"),
                                      completed >= 0, total > 0, completed <= total,
                                      let stage = try object["stage"]?.requiredString(context: "stage"), stages.contains(stage) else {
                                    throw InferenceFailure.backendFailed("Invalid video progress values.")
                                }
                                if stage == "denoise" {
                                    guard total == steps else { throw InferenceFailure.backendFailed("Video step total changed.") }
                                    try await emit(.progress(completed: Int(completed), total: Int(total)))
                                }
                            default: throw InferenceFailure.backendFailed("Unknown video protocol event.")
                            }
                        } catch { fail(error.localizedDescription) }
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(byte)
                        if line.count > 2 * 1024 * 1024 { fail("Video event exceeded 2 MiB.") }
                    }
                }
                reader.acknowledge()
            case .end:
                if !line.isEmpty { fail("Video protocol ended with an incomplete JSON line.") }
                if result.snapshot == nil, result.failure == nil { fail("Video provider exited without a result.") }
                return result
            case .failure(let code, let message):
                fail("Video stdout read failed: \(code) \(message)"); return result
            }
        }
    }

    static func validate(_ snapshot: AudioJSONValue, requestData: Data, manifestData: Data,
                         video: VideoRequest, rawURL: URL) throws -> VideoFrameSequence {
        let object = try snapshot.object(exactKeys: ["schema", "type", "runID", "request", "requestSHA256",
            "modelManifestSHA256", "precision", "conditions", "frames", "stages", "seconds"], context: "Video result")
        var requestParser = AudioJSONParser(data: requestData, maximumDepth: 24)
        let expected = try requestParser.parse()
        guard object["request"] == expected,
              try object["requestSHA256"]?.requiredString(context: "request digest") == sha256(requestData),
              try object["modelManifestSHA256"]?.requiredString(context: "manifest digest") == sha256(manifestData) else {
            throw InferenceFailure.backendFailed("Video result differs from the submitted immutable request/model snapshot.")
        }
        let requestObject = try expected.objectAny(context: "submitted video request")
        guard object["schema"] == .string("d.video.frames.v1"), object["type"] == .string("result"),
              object["runID"] == requestObject["runID"], object["seconds"]?.nonnegativeNumber == true,
              case .array(let conditions)? = object["conditions"], conditions.count == 2,
              case .array(let history)? = object["stages"], !history.isEmpty, history.count <= video.steps + (video.frameCount - 1) / 4 + 1 + 64 else {
            throw InferenceFailure.backendFailed("Invalid video execution evidence.")
        }
        for condition in conditions {
            let fields = try condition.object(exactKeys: ["tokenCount", "effectiveText"], context: "condition")
            guard let count = try fields["tokenCount"]?.requiredInteger(context: "tokenCount"),
                  (1...512).contains(count), (try fields["effectiveText"]?.requiredString(context: "effectiveText")) != nil else {
                throw InferenceFailure.backendFailed("Invalid video token conditioning record.")
            }
        }
        for event in history {
            let fields = try event.object(exactKeys: ["stage", "completed", "total", "seconds", "activeBytes",
                "cacheBytes", "peakBytes", "peakRSSBytes"], context: "stage record")
            guard let stage = try fields["stage"]?.requiredString(context: "stage"), stages.contains(stage),
                  let completed = try fields["completed"]?.requiredInteger(context: "completed"),
                  let total = try fields["total"]?.requiredInteger(context: "total"),
                  completed >= 0, total > 0, completed <= total, fields["seconds"]?.nonnegativeNumber == true else {
                throw InferenceFailure.backendFailed("Invalid video stage record.")
            }
            for field in ["activeBytes", "cacheBytes", "peakBytes", "peakRSSBytes"] {
                guard (try fields[field]?.requiredUInt64(context: field)) != nil else {
                    throw InferenceFailure.backendFailed("Missing video memory measurement.")
                }
            }
        }
        let last = try history[history.count - 1].objectAny(context: "last stage")
        guard last["stage"] == .string("released"),
              try last["completed"]?.requiredInteger(context: "released frames") == Int64(video.frameCount) else {
            throw InferenceFailure.backendFailed("Video result does not follow completed model release.")
        }
        let precision = try object["precision"]?.object(exactKeys: ["text", "diffusion", "vae"], context: "precision")
        guard precision?["text"] == .string("BF16"), precision?["vae"] == .string("F32"),
              precision?["diffusion"] == .string("BF16 with original FP32 time/head/modulation/norm tensors") else {
            throw InferenceFailure.backendFailed("Video precision report differs from the executed profile.")
        }
        guard let frame = try object["frames"]?.object(exactKeys: ["file", "width", "height", "frameCount",
            "fpsNumerator", "fpsDenominator", "layout", "colorInterpretation", "sha256", "byteCount"], context: "frames"),
              frame["file"] == .string("frames.rgb"), frame["layout"] == .string("RGB8-top-down"),
              frame["colorInterpretation"] == .string("full-range Rec.709 display RGB"),
              try frame["width"]?.requiredInteger(context: "width") == Int64(video.width),
              try frame["height"]?.requiredInteger(context: "height") == Int64(video.height),
              try frame["frameCount"]?.requiredInteger(context: "frameCount") == Int64(video.frameCount),
              try frame["fpsNumerator"]?.requiredInteger(context: "fpsNumerator") == Int64(video.frameRate.numerator),
              try frame["fpsDenominator"]?.requiredInteger(context: "fpsDenominator") == Int64(video.frameRate.denominator),
              let digest = try frame["sha256"]?.requiredString(context: "frame digest") else {
            throw InferenceFailure.backendFailed("Video frame metadata differs from the explicit request.")
        }
        let sequence = VideoFrameSequence(rawURL: rawURL, width: video.width, height: video.height,
            frameCount: video.frameCount, fpsNumerator: video.frameRate.numerator,
            fpsDenominator: video.frameRate.denominator, sha256: digest)
        let (_, total) = try sequence.validatedByteCounts()
        guard try frame["byteCount"]?.requiredUInt64(context: "frame bytes") == UInt64(total) else {
            throw InferenceFailure.backendFailed("Video frame byte count is inconsistent.")
        }
        return sequence
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
