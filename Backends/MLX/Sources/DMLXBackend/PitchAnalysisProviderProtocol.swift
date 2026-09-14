import DInference
import Foundation

struct PitchProviderMetadata: Sendable, Equatable {
    let profile: String
    let modelSHA256: String
    let provider: String
    let analysisSeconds: Double
}

struct PitchProviderResponse: Sendable, Equatable {
    let result: PitchAnalysisResult
    let metadata: PitchProviderMetadata
}

struct PitchProviderStdout: Sendable {
    let data: Data
    let failure: String?
}

enum PitchAnalysisProviderProtocol {
    static let providerIdentity = "swift-f0-0.1.2/onnxruntime-cpu"

    static func readStdout(_ reader: LocalDedicatedPipeReader,
                           control: LocalOwnedProcessControl) async -> PitchProviderStdout {
        var data = Data()
        var failure: String?
        while true {
            switch await reader.next() {
            case .data(let chunk):
                if failure == nil {
                    if data.count + chunk.count > PitchAnalysisResult.maximumJSONBytes + 1 {
                        failure = "Pitch provider stdout exceeded the 2 MiB result boundary."
                        control.requestStop(.protocolFailure(failure!))
                    } else {
                        data.append(chunk)
                    }
                }
                reader.acknowledge()
            case .end:
                guard failure == nil else { return PitchProviderStdout(data: Data(), failure: failure) }
                guard data.last == 0x0A else {
                    let message = "Pitch provider result must end with one newline."
                    control.requestStop(.protocolFailure(message))
                    return PitchProviderStdout(data: Data(), failure: message)
                }
                data.removeLast()
                guard !data.isEmpty, data.count <= PitchAnalysisResult.maximumJSONBytes,
                      !data.contains(0x0A), !data.contains(0x0D) else {
                    let message = "Pitch provider must emit exactly one bounded JSON line."
                    control.requestStop(.protocolFailure(message))
                    return PitchProviderStdout(data: Data(), failure: message)
                }
                return PitchProviderStdout(data: data, failure: nil)
            case .failure(let code, let message):
                let detail = "Cannot drain pitch provider stdout: POSIX read failed with errno \(code): \(message)"
                control.requestStop(.protocolFailure(detail))
                return PitchProviderStdout(data: Data(), failure: detail)
            }
        }
    }

    static func parse(_ data: Data, expectedRunID: UUID,
                      expected: PitchAnalysisRequest) throws -> PitchProviderResponse {
        guard !data.isEmpty, data.count <= PitchAnalysisResult.maximumJSONBytes else {
            throw InferenceFailure.backendFailed(
                "Pitch provider JSON exceeds the 2 MiB result boundary.")
        }
        let root: AudioJSONValue
        do {
            var parser = AudioJSONParser(data: data, maximumDepth: 32)
            root = try parser.parse()
        } catch {
            throw InferenceFailure.backendFailed(
                "Invalid pitch provider JSON: \(error.localizedDescription)")
        }
        let object = try root.object(exactKeys: [
            "schemaVersion", "runID", "source", "profile", "preprocessing",
            "modelSHA256", "inputSHA256", "sampleCount", "frames", "metadata",
        ], context: "pitch result")
        let schema = try object["schemaVersion"]!.requiredInteger(context: "pitch schemaVersion")
        let runText = try object["runID"]!.requiredString(context: "pitch runID")
        guard schema == 1, runText == runText.lowercased(),
              UUID(uuidString: runText) == expectedRunID else {
            throw InferenceFailure.backendFailed("Pitch result has the wrong schema or runID.")
        }
        let source = try parseSource(object["source"]!)
        let profile = try object["profile"]!.requiredString(context: "pitch profile")
        let preprocessing = try object["preprocessing"]!.requiredString(context: "pitch preprocessing")
        let modelDigest = try object["modelSHA256"]!.requiredString(context: "pitch model digest")
        let inputDigest = try object["inputSHA256"]!.requiredString(context: "pitch input digest")
        let sampleCount64 = try object["sampleCount"]!.requiredInteger(context: "pitch sampleCount")
        guard sampleCount64 >= 0, sampleCount64 <= Int64(Int.max) else {
            throw InferenceFailure.backendFailed("Pitch sampleCount is not representable.")
        }
        guard case .array(let values)? = object["frames"] else {
            throw InferenceFailure.backendFailed("Pitch frames must be an array.")
        }
        let frames = try values.map(parseFrame)
        let result = PitchAnalysisResult(
            runID: expectedRunID, source: source, inputSHA256: inputDigest,
            sampleCount: Int(sampleCount64), frames: frames, schemaVersion: Int(schema),
            profile: profile, preprocessing: preprocessing, modelSHA256: modelDigest)
        try result.validate()
        guard result.source == expected.source, result.inputSHA256 == expected.inputSHA256,
              result.sampleCount == expected.sampleCount,
              result.profile == PitchAnalysisRequest.profile,
              result.preprocessing == PitchAnalysisRequest.preprocessing,
              result.modelSHA256 == PitchAnalysisRequest.modelSHA256 else {
            throw InferenceFailure.backendFailed(
                "Pitch provider result does not match the current admitted request.")
        }

        let metadataObject = try object["metadata"]!.object(exactKeys: [
            "profile", "modelSHA256", "provider", "analysisSeconds",
        ], context: "pitch metadata")
        let metadata = PitchProviderMetadata(
            profile: try metadataObject["profile"]!.requiredString(context: "metadata profile"),
            modelSHA256: try metadataObject["modelSHA256"]!.requiredString(context: "metadata model digest"),
            provider: try metadataObject["provider"]!.requiredString(context: "metadata provider"),
            analysisSeconds: try number(metadataObject["analysisSeconds"]!, context: "metadata analysisSeconds"))
        guard metadata.profile == PitchAnalysisRequest.profile,
              metadata.modelSHA256 == PitchAnalysisRequest.modelSHA256,
              metadata.provider == providerIdentity,
              metadata.analysisSeconds.isFinite, metadata.analysisSeconds >= 0 else {
            throw InferenceFailure.backendFailed("Pitch provider metadata is inconsistent.")
        }
        return PitchProviderResponse(result: result, metadata: metadata)
    }

    private static func parseSource(_ value: AudioJSONValue) throws -> PitchSourceIdentity {
        let object = try value.object(exactKeys: [
            "assetID", "documentID", "documentRevision", "contentSHA256",
            "sampleRate", "frameCount", "startFrame", "endFrame",
        ], context: "pitch source")
        guard let assetID = UUID(uuidString: try object["assetID"]!.requiredString(context: "source assetID")),
              let documentID = UUID(uuidString: try object["documentID"]!.requiredString(context: "source documentID")) else {
            throw InferenceFailure.backendFailed("Pitch source contains an invalid UUID.")
        }
        return PitchSourceIdentity(
            assetID: assetID, documentID: documentID,
            documentRevision: try object["documentRevision"]!.requiredUInt64(context: "source revision"),
            contentSHA256: try object["contentSHA256"]!.requiredString(context: "source digest"),
            sampleRate: try number(object["sampleRate"]!, context: "source sampleRate"),
            frameCount: try object["frameCount"]!.requiredInteger(context: "source frameCount"),
            startFrame: try object["startFrame"]!.requiredInteger(context: "source startFrame"),
            endFrame: try object["endFrame"]!.requiredInteger(context: "source endFrame"))
    }

    private static func parseFrame(_ value: AudioJSONValue) throws -> PitchFrame {
        let object = try value.object(exactKeys: ["rawPitchHz", "confidence", "voiced"],
                                      context: "pitch frame")
        let rawPitch = try number(object["rawPitchHz"]!, context: "raw pitch")
        let confidence = try number(object["confidence"]!, context: "pitch confidence")
        guard case .bool(let reportedVoiced)? = object["voiced"],
              rawPitch.isFinite, confidence.isFinite, (0...1).contains(confidence) else {
            throw InferenceFailure.backendFailed("Pitch frame contains invalid numeric or Boolean data.")
        }
        let expectedVoiced = confidence > 0.9 && (46.875...2093.75).contains(rawPitch)
        guard reportedVoiced == expectedVoiced else {
            throw InferenceFailure.backendFailed("Pitch frame contradicts the frozen voiced predicate.")
        }
        return PitchFrame(pitchHz: expectedVoiced ? rawPitch : nil,
                          confidence: confidence, voiced: expectedVoiced)
    }

    private static func number(_ value: AudioJSONValue, context: String) throws -> Double {
        let result: Double
        switch value {
        case .integer(let integer): result = Double(integer)
        case .unsignedInteger(let integer): result = Double(integer)
        case .number(let decimal): result = NSDecimalNumber(decimal: decimal).doubleValue
        default:
            throw InferenceFailure.backendFailed("\(context) must be numeric, not a Boolean.")
        }
        guard result.isFinite else {
            throw InferenceFailure.backendFailed("\(context) must be finite.")
        }
        return result
    }
}
