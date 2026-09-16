import CryptoKit
import Darwin
import DInference
import Foundation

struct SingingProviderTerminal: Sendable, Equatable {
    let resultPath: String
}

struct SingingResultRecord: Sendable {
    struct Source: Sendable {
        let phraseID: String
        let phraseRevision: Int64
        let requestSHA256: String
        let durationTicks: Int64
    }
    struct Model: Sendable {
        let bankArchiveSHA256: String
        let vocoderRevision: String
        let vocoderSHA256: String
        let bankTermsSHA256: String
        let vocoderLicenseSHA256: String
        let profileSHA256: String?
        let vendorManifestSHA256: String?
    }
    struct Audio: Sendable {
        let path: String
        let encoding: String
        let sampleRate: Int
        let channels: Int
        let frameCount: Int64
        let sha256: String
    }
    struct Stage: Sendable {
        let name: String
        let seconds: Double
    }
    struct Execution: Sendable {
        struct ONNXDevice: Sendable {
            let requested: String
            let actual: String
            let provider: String
            let runtime: String
            let version: String
            let precision: String
            let fallback: String
        }
        struct VocoderDevice: Sendable {
            let requested: String
            let actual: String
            let runtime: String
            let version: String
            let precision: String
            let fallback: String
            let parameterDevice: String
            let bufferDevice: String
            let inputDevice: String
            let outputDevice: String
        }
        struct Devices: Sendable {
            let onnx: ONNXDevice
            let vocoder: VocoderDevice
        }

        let precision: String
        let seedControl: String
        let nativeFrameCount: Int64
        let trimHeadSamples: Int64
        let outputFrameCount: Int64
        let projectionRelativeResidual: Double
        let saturatedSamples: Int64
        let stages: [Stage]
        let devices: Devices?
    }
    let schemaVersion: Int64
    let profileID: String
    let runID: String
    let source: Source
    let model: Model
    let audio: Audio
    let execution: Execution
}

private struct SingingStdoutState: Sendable {
    var nextStage = 0
    var terminal: SingingProviderTerminal?
    var failure: String?
}

enum SingingProviderProtocol {
    static let stages = ["validation", "duration", "pitch", "variance", "acoustic", "vocoder", "publish"]

    static func run(
        executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL,
        timeoutSeconds: Double, cancellationGraceSeconds: Double, runID: UUID,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async throws -> SingingProviderTerminal {
        let process = LocalProviderProcess(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory, timeoutSeconds: timeoutSeconds,
            cancellationGraceSeconds: cancellationGraceSeconds, label: "Singing provider")
        let state = try await process.run { reader, control in
            await readStdout(reader, runID: runID, control: control, emit: emit)
        }
        if let failure = state.failure { throw InferenceFailure.backendFailed(failure) }
        guard let terminal = state.terminal, state.nextStage == stages.count else {
            throw InferenceFailure.backendFailed(
                "Singing provider exited without the complete ordered progress protocol and one result event.")
        }
        return terminal
    }

    private static func readStdout(
        _ reader: LocalDedicatedPipeReader, runID: UUID, control: LocalOwnedProcessControl,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async -> SingingStdoutState {
        var state = SingingStdoutState()
        var line = Data()
        var total = 0
        while true {
            switch await reader.next() {
            case .data(let data):
                for byte in data {
                    total += 1
                    if total > 16 * 1024 * 1024 {
                        fail(&state, "Singing provider stdout exceeded 16 MiB.", control)
                        continue
                    }
                    if state.failure != nil { continue }
                    if byte == 0x0A {
                        await processLine(line, runID: runID, state: &state, control: control, emit: emit)
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(byte)
                        if line.count > 2 * 1024 * 1024 {
                            fail(&state, "Singing provider emitted a JSON line larger than 2 MiB.", control)
                        }
                    }
                }
                reader.acknowledge()
            case .end:
                if state.failure == nil, !line.isEmpty {
                    await processLine(line, runID: runID, state: &state, control: control, emit: emit)
                }
                return state
            case .failure(let code, let message):
                fail(&state, "Cannot drain singing stdout: errno \(code): \(message)", control)
                return state
            }
        }
    }

    private static func processLine(
        _ line: Data, runID: UUID, state: inout SingingStdoutState,
        control: LocalOwnedProcessControl,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async {
        guard !line.isEmpty else {
            fail(&state, "Singing provider emitted an empty stdout line.", control)
            return
        }
        do {
            var parser = AudioJSONParser(data: line, maximumDepth: 32)
            let value = try parser.parse()
            let any = try value.objectAny(context: "singing provider event")
            let type = try any["type"]?.requiredString(context: "singing event type")
            switch type {
            case "progress":
                guard state.terminal == nil, state.nextStage < stages.count else {
                    throw InferenceFailure.backendFailed("Singing progress was duplicated or followed the terminal event.")
                }
                let object = try value.object(exactKeys: ["type", "runID", "stage"], context: "singing progress")
                try validateRunID(object, runID: runID)
                let stage = try object["stage"]!.requiredString(context: "singing progress stage")
                guard stage == stages[state.nextStage] else {
                    throw InferenceFailure.backendFailed("Singing progress stages are missing, duplicated, or out of order.")
                }
                state.nextStage += 1
                try await emit(.progress(completed: state.nextStage, total: stages.count))
            case "result":
                guard state.terminal == nil, state.nextStage == stages.count else {
                    throw InferenceFailure.backendFailed("Singing result arrived before complete progress or was duplicated.")
                }
                let object = try value.object(exactKeys: ["type", "runID", "resultPath"], context: "singing result")
                try validateRunID(object, runID: runID)
                let resultPath = try object["resultPath"]!.requiredString(context: "singing resultPath")
                guard resultPath == "result.json" else {
                    throw InferenceFailure.backendFailed("Singing resultPath must be result.json.")
                }
                state.terminal = SingingProviderTerminal(resultPath: resultPath)
            default:
                throw InferenceFailure.backendFailed("Unknown singing provider stdout event.")
            }
        } catch {
            fail(&state, "Invalid singing provider stdout: \(error.localizedDescription)", control)
        }
    }

    private static func validateRunID(_ object: [String: AudioJSONValue], runID: UUID) throws {
        let value = try object["runID"]!.requiredString(context: "singing event runID")
        guard value == runID.uuidString.lowercased() else {
            throw InferenceFailure.backendFailed("Singing provider event has the wrong or noncanonical runID.")
        }
    }

    private static func fail(
        _ state: inout SingingStdoutState, _ message: String, _ control: LocalOwnedProcessControl
    ) {
        guard state.failure == nil else { return }
        state.failure = message
        control.requestStop(.protocolFailure(message))
    }

    static func parseResult(_ data: Data) throws -> SingingResultRecord {
        do { return try parseResultBody(data) }
        catch let failure as InferenceFailure {
            if case .backendFailed = failure { throw failure }
            throw InferenceFailure.backendFailed("Invalid singing result record: \(failure.localizedDescription)")
        } catch {
            throw InferenceFailure.backendFailed("Invalid singing result record: \(error.localizedDescription)")
        }
    }

    private static func parseResultBody(_ data: Data) throws -> SingingResultRecord {
        let root: [String: AudioJSONValue]
        do {
            var parser = AudioJSONParser(data: data, maximumDepth: 32)
            root = try parser.parse().object(
                exactKeys: ["schemaVersion", "runID", "profileID", "status", "source", "model", "audio", "execution"],
                context: "singing result")
        } catch { throw InferenceFailure.backendFailed("Invalid singing result JSON: \(error.localizedDescription)") }
        let schemaVersion = try root["schemaVersion"]!.requiredInteger(context: "result schemaVersion")
        let profileID = try root["profileID"]!.requiredString(context: "result profileID")
        guard let deployment = SingingBackendConfiguration.profile(for: profileID),
              schemaVersion == deployment.resultSchemaVersion,
              try root["status"]!.requiredString(context: "result status") == "rendered" else {
            throw InferenceFailure.backendFailed("Singing result header is unsupported.")
        }
        let source = try root["source"]!.object(
            exactKeys: ["phraseID", "phraseRevision", "requestSHA256", "durationTicks"], context: "result source")
        let modelKeys: Set<String> = deployment.vocoderDevice == .mps
            ? ["bankArchiveSHA256", "vocoderRevision", "vocoderSHA256", "bankTermsSHA256",
               "vocoderLicenseSHA256", "profileSHA256", "vendorManifestSHA256"]
            : ["bankArchiveSHA256", "vocoderRevision", "vocoderSHA256", "bankTermsSHA256",
               "vocoderLicenseSHA256"]
        let model = try root["model"]!.object(
            exactKeys: modelKeys, context: "result model")
        let audio = try root["audio"]!.object(
            exactKeys: ["path", "encoding", "sampleRate", "channels", "frameCount", "sha256"],
            context: "result audio")
        let executionKeys: Set<String> = deployment.vocoderDevice == .mps
            ? ["precision", "seedControl", "nativeFrameCount", "trimHeadSamples", "outputFrameCount",
               "projectionRelativeResidual", "saturatedSamples", "stages", "devices"]
            : ["precision", "seedControl", "nativeFrameCount", "trimHeadSamples", "outputFrameCount",
               "projectionRelativeResidual", "saturatedSamples", "stages"]
        let execution = try root["execution"]!.object(
            exactKeys: executionKeys, context: "result execution")
        let stageValues = try array(execution["stages"]!, context: "result stages")
        guard stageValues.count == stages.count else {
            throw InferenceFailure.backendFailed("Singing result must report exactly seven stages.")
        }
        let parsedStages = try zip(stageValues, stages).map { value, expected -> SingingResultRecord.Stage in
            let item = try value.object(exactKeys: ["name", "seconds"], context: "result stage")
            let name = try item["name"]!.requiredString(context: "result stage name")
            let seconds = try finiteNumber(item["seconds"]!, context: "result stage seconds")
            guard name == expected, seconds >= 0 else {
                throw InferenceFailure.backendFailed("Singing result stages are invalid or out of order.")
            }
            return .init(name: name, seconds: seconds)
        }
        let residual = try finiteNumber(execution["projectionRelativeResidual"]!, context: "projection residual")
        guard residual >= 0, residual <= 0.10 else {
            throw InferenceFailure.backendFailed("Singing projection residual exceeds the fixed compatibility budget.")
        }
        let sampleRate = try platformInt(audio["sampleRate"]!, context: "audio sampleRate")
        let channels = try platformInt(audio["channels"]!, context: "audio channels")
        let devices: SingingResultRecord.Execution.Devices?
        if deployment.vocoderDevice == .mps {
            let rootDevices = try execution["devices"]!.object(
                exactKeys: ["onnx", "vocoder"], context: "execution devices")
            let onnx = try rootDevices["onnx"]!.object(
                exactKeys: ["requested", "actual", "provider", "runtime", "version", "precision", "fallback"],
                context: "ONNX execution device")
            let vocoder = try rootDevices["vocoder"]!.object(
                exactKeys: ["requested", "actual", "runtime", "version", "precision", "fallback",
                            "parameterDevice", "bufferDevice", "inputDevice", "outputDevice"],
                context: "vocoder execution device")
            devices = .init(
                onnx: .init(
                    requested: try string(onnx, "requested", context: "ONNX requested device"),
                    actual: try string(onnx, "actual", context: "ONNX actual device"),
                    provider: try string(onnx, "provider", context: "ONNX provider"),
                    runtime: try string(onnx, "runtime", context: "ONNX runtime"),
                    version: try runtimeVersion(onnx["version"]!, context: "ONNX runtime version"),
                    precision: try string(onnx, "precision", context: "ONNX precision"),
                    fallback: try string(onnx, "fallback", context: "ONNX fallback")),
                vocoder: .init(
                    requested: try string(vocoder, "requested", context: "vocoder requested device"),
                    actual: try string(vocoder, "actual", context: "vocoder actual device"),
                    runtime: try string(vocoder, "runtime", context: "vocoder runtime"),
                    version: try runtimeVersion(vocoder["version"]!, context: "vocoder runtime version"),
                    precision: try string(vocoder, "precision", context: "vocoder precision"),
                    fallback: try string(vocoder, "fallback", context: "vocoder fallback"),
                    parameterDevice: try string(vocoder, "parameterDevice", context: "vocoder parameter device"),
                    bufferDevice: try string(vocoder, "bufferDevice", context: "vocoder buffer device"),
                    inputDevice: try string(vocoder, "inputDevice", context: "vocoder input device"),
                    outputDevice: try string(vocoder, "outputDevice", context: "vocoder output device")))
        } else {
            devices = nil
        }
        return SingingResultRecord(
            schemaVersion: schemaVersion, profileID: profileID,
            runID: try root["runID"]!.requiredString(context: "result runID"),
            source: .init(
                phraseID: try source["phraseID"]!.requiredString(context: "source phraseID"),
                phraseRevision: try source["phraseRevision"]!.requiredInteger(context: "source phraseRevision"),
                requestSHA256: try source["requestSHA256"]!.requiredString(context: "source requestSHA256"),
                durationTicks: try source["durationTicks"]!.requiredInteger(context: "source durationTicks")),
            model: .init(
                bankArchiveSHA256: try model["bankArchiveSHA256"]!.requiredString(context: "model bank archive"),
                vocoderRevision: try model["vocoderRevision"]!.requiredString(context: "model vocoder revision"),
                vocoderSHA256: try model["vocoderSHA256"]!.requiredString(context: "model vocoder SHA-256"),
                bankTermsSHA256: try model["bankTermsSHA256"]!.requiredString(context: "model bank terms"),
                vocoderLicenseSHA256: try model["vocoderLicenseSHA256"]!.requiredString(context: "model vocoder license"),
                profileSHA256: try model["profileSHA256"]?.requiredString(context: "model profile SHA-256"),
                vendorManifestSHA256: try model["vendorManifestSHA256"]?.requiredString(
                    context: "model vendor manifest SHA-256")),
            audio: .init(
                path: try audio["path"]!.requiredString(context: "audio path"),
                encoding: try audio["encoding"]!.requiredString(context: "audio encoding"),
                sampleRate: sampleRate, channels: channels,
                frameCount: try audio["frameCount"]!.requiredInteger(context: "audio frameCount"),
                sha256: try audio["sha256"]!.requiredString(context: "audio SHA-256")),
            execution: .init(
                precision: try execution["precision"]!.requiredString(context: "execution precision"),
                seedControl: try execution["seedControl"]!.requiredString(context: "execution seedControl"),
                nativeFrameCount: try execution["nativeFrameCount"]!.requiredInteger(context: "nativeFrameCount"),
                trimHeadSamples: try execution["trimHeadSamples"]!.requiredInteger(context: "trimHeadSamples"),
                outputFrameCount: try execution["outputFrameCount"]!.requiredInteger(context: "outputFrameCount"),
                projectionRelativeResidual: residual,
                saturatedSamples: try execution["saturatedSamples"]!.requiredInteger(context: "saturatedSamples"),
                stages: parsedStages, devices: devices))
    }

    static func validate(
        _ record: SingingResultRecord, runID: UUID, request: SingingRequest,
        requestSHA256: String, inventory: SingingModelInventory
    ) throws {
        let profile = inventory.profile
        let deployment = inventory.deployment
        guard record.schemaVersion == deployment.resultSchemaVersion,
              record.profileID == request.profileID,
              request.profileID == deployment.profileID,
              record.runID == runID.uuidString.lowercased(),
              exact(record.source.phraseID, request.phrase.id),
              record.source.phraseRevision == request.phrase.revision,
              record.source.durationTicks == request.phrase.durationTicks,
              record.source.requestSHA256 == requestSHA256,
              record.model.bankArchiveSHA256 == profile.bankArchiveSHA256,
              record.model.vocoderRevision == profile.vocoderRevision,
              record.model.bankTermsSHA256 == profile.bankTermsSHA256,
              record.model.vocoderLicenseSHA256 == profile.vocoderLicenseSHA256,
              record.model.vocoderSHA256 == profile.vocoderFiles.first(where: {
                  $0.path == "bigvgan_generator.pt"
              })?.sha256,
              record.audio.path == "output.wav", record.audio.encoding == "float32LE-WAV",
              record.audio.sampleRate == 44_100, record.audio.channels == 1,
              record.execution.precision == deployment.precision,
              record.execution.seedControl == "unsupported", record.execution.trimHeadSamples == 4096,
              record.execution.saturatedSamples >= 0 else {
            throw InferenceFailure.backendFailed("Singing result does not match the admitted request or fixed profile.")
        }
        switch deployment.vocoderDevice {
        case .cpu:
            guard record.model.profileSHA256 == nil,
                  record.model.vendorManifestSHA256 == nil,
                  record.execution.devices == nil else {
                throw InferenceFailure.backendFailed("CPU singing result must retain the strict v1 shape.")
            }
        case .mps:
            guard record.model.profileSHA256 == deployment.profileSHA256,
                  record.model.vendorManifestSHA256 == SingingBackendConfiguration.vendorManifestSHA256,
                  let devices = record.execution.devices,
                  validMPSDevices(devices) else {
                throw InferenceFailure.backendFailed(
                    "MPS singing result does not prove the fixed no-fallback device execution.")
            }
        }
        let delivered = try deliveredFrames(request.phrase.durationTicks)
        let native = try nativeFrames(request.phrase.durationTicks)
        guard record.audio.frameCount == delivered,
              record.execution.outputFrameCount == delivered,
              record.execution.nativeFrameCount == native,
              validDigest(record.audio.sha256), validDigest(record.model.vocoderSHA256) else {
            throw InferenceFailure.backendFailed("Singing result frame counts or digests are invalid.")
        }
    }

    private static func validMPSDevices(_ devices: SingingResultRecord.Execution.Devices) -> Bool {
        let onnx = devices.onnx
        let vocoder = devices.vocoder
        return onnx.requested == "cpu" && onnx.actual == "cpu"
            && onnx.provider == "CPUExecutionProvider" && onnx.runtime == "onnxruntime"
            && onnx.precision == "FP32-original" && onnx.fallback == "forbidden"
            && vocoder.requested == "mps" && vocoder.actual == "mps"
            && vocoder.runtime == "torch" && vocoder.precision == "FP32"
            && vocoder.fallback == "forbidden" && vocoder.parameterDevice == "mps"
            && vocoder.bufferDevice == "mps" && vocoder.inputDevice == "mps"
            && vocoder.outputDevice == "mps"
    }

    static func validateWAV(
        _ url: URL, record: SingingResultRecord
    ) throws -> ArtifactReference {
        let (data, identity) = try AudioFileSystem.readRegularFile(
            url, label: "Singing output WAV", maximumBytes: 512 * 1024 * 1024)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard identity.size >= 0, digest == record.audio.sha256 else {
            throw InferenceFailure.backendFailed("Singing WAV SHA-256 does not match result.json.")
        }
        let claim = AudioProviderArtifact(
            path: url.path, sha256: digest, byteCount: UInt64(identity.size),
            frameCount: record.audio.frameCount, sampleRate: record.audio.sampleRate,
            channels: record.audio.channels, encoding: "float32")
        let artifact = try AudioWAV.validateOutput(
            url, claim: claim, expectedFrames: record.audio.frameCount,
            expectedSampleRate: 44_100, expectedChannels: 1, requireNonzero: true)
        let saturated = try saturatedSampleCount(data)
        guard saturated == record.execution.saturatedSamples else {
            throw InferenceFailure.backendFailed("Singing saturated sample count does not match the delivered WAV.")
        }
        let sealed = try SingingSealedFile.capture(
            url, label: "Validated singing output WAV", maximumBytes: UInt64(identity.size),
            cancellable: false)
        guard sealed.identity == identity, sealed.sha256 == digest else {
            throw InferenceFailure.backendFailed("Singing WAV path changed after independent validation.")
        }
        return artifact
    }

    static func deliveredFrames(_ ticks: Int64) throws -> Int64 {
        let product = ticks.multipliedReportingOverflow(by: 44_100)
        guard ticks > 0, !product.overflow else {
            throw InferenceFailure.backendFailed("Singing delivered frame count is not representable.")
        }
        let adjusted = product.partialValue.addingReportingOverflow(500_000)
        guard !adjusted.overflow else {
            throw InferenceFailure.backendFailed("Singing delivered frame count is not representable.")
        }
        return adjusted.partialValue / 1_000_000
    }

    static func nativeFrames(_ ticks: Int64) throws -> Int64 {
        let product = ticks.multipliedReportingOverflow(by: 44_100)
        let doubled = product.partialValue.multipliedReportingOverflow(by: 2)
        let shifted = doubled.partialValue.addingReportingOverflow(512_000_000)
        guard ticks > 0, !product.overflow, !doubled.overflow, !shifted.overflow else {
            throw InferenceFailure.backendFailed("Singing native frame count is not representable.")
        }
        let denominator: Int64 = 1_024_000_000
        var quotient = shifted.partialValue / denominator
        let remainder = shifted.partialValue % denominator
        if remainder * 2 > denominator || (remainder * 2 == denominator && !quotient.isMultiple(of: 2)) {
            quotient += 1
        }
        let withContext = quotient.addingReportingOverflow(16)
        let native = withContext.partialValue.multipliedReportingOverflow(by: 512)
        guard !withContext.overflow, !native.overflow else {
            throw InferenceFailure.backendFailed("Singing native frame count is not representable.")
        }
        return native.partialValue
    }

    private static func saturatedSampleCount(_ data: Data) throws -> Int64 {
        guard data.count >= 12 else { throw InferenceFailure.backendFailed("Singing WAV is truncated.") }
        var offset = 12
        var pcm: Range<Int>?
        while offset < data.count {
            guard offset + 8 <= data.count else { throw InferenceFailure.backendFailed("Singing WAV chunk is truncated.") }
            let length = Int(u32(data, offset + 4)), body = offset + 8
            guard length >= 0, body <= data.count, length <= data.count - body else {
                throw InferenceFailure.backendFailed("Singing WAV chunk length is invalid.")
            }
            if data[offset..<(offset + 4)] == Data("data".utf8) {
                guard pcm == nil else { throw InferenceFailure.backendFailed("Singing WAV has duplicate data chunks.") }
                pcm = body..<(body + length)
            }
            let padded = length + (length & 1)
            guard padded <= data.count - body else { throw InferenceFailure.backendFailed("Singing WAV padding is invalid.") }
            offset = body + padded
        }
        guard let pcm, pcm.count.isMultiple(of: 4) else {
            throw InferenceFailure.backendFailed("Singing WAV float data is missing or misaligned.")
        }
        var count: Int64 = 0
        for sample in stride(from: pcm.lowerBound, to: pcm.upperBound, by: 4) {
            let value = Float(bitPattern: u32(data, sample))
            if abs(value) >= 1 { count += 1 }
        }
        return count
    }

    private static func array(_ value: AudioJSONValue, context: String) throws -> [AudioJSONValue] {
        guard case .array(let values) = value else {
            throw InferenceFailure.backendFailed("\(context) must be an array.")
        }
        return values
    }

    private static func string(
        _ object: [String: AudioJSONValue], _ key: String, context: String
    ) throws -> String {
        try object[key]!.requiredString(context: context)
    }

    private static func runtimeVersion(_ value: AudioJSONValue, context: String) throws -> String {
        let version = try value.requiredString(context: context)
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version.utf8.count <= 128 else {
            throw InferenceFailure.backendFailed("\(context) must contain 1...128 UTF-8 bytes.")
        }
        return version
    }

    private static func finiteNumber(_ value: AudioJSONValue, context: String) throws -> Double {
        let decimal: Decimal
        switch value {
        case .integer(let number): decimal = Decimal(number)
        case .unsignedInteger(let number):
            guard let parsed = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")) else {
                throw InferenceFailure.backendFailed("\(context) is not representable.")
            }
            decimal = parsed
        case .number(let number): decimal = number
        default: throw InferenceFailure.backendFailed("\(context) must be a number, not a Boolean.")
        }
        let result = NSDecimalNumber(decimal: decimal).doubleValue
        guard result.isFinite else { throw InferenceFailure.backendFailed("\(context) must be finite.") }
        return result
    }

    private static func platformInt(_ value: AudioJSONValue, context: String) throws -> Int {
        let number = try value.requiredInteger(context: context)
        guard let result = Int(exactly: number) else {
            throw InferenceFailure.backendFailed("\(context) is outside the platform Int range.")
        }
        return result
    }

    private static func exact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
