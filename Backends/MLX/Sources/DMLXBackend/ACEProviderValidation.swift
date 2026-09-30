import CryptoKit
import DInference
import Foundation

enum ACEInputValidation {
    static func check(_ reference: AudioSourceReference) throws -> Data {
        try ACERequest.validateReference(reference)
        let data = try AudioFileSystem.readRegularFile(
            reference.url, label: "ACE input WAV", maximumBytes: 512 * 1024 * 1024).0
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8),
              UInt64(u32(data, 4)) + 8 == data.count else {
            throw InferenceFailure.invalidRequest("ACE input is not a complete RIFF/WAV file.")
        }
        var offset = 12
        var format: (Int, Int, Int, Int, Int, Int)?
        var pcm: Range<Int>?
        while offset < data.count {
            guard offset + 8 <= data.count else { throw InferenceFailure.invalidRequest("Truncated ACE WAV chunk.") }
            let length = Int(u32(data, offset + 4)), body = offset + 8
            guard length <= data.count - body else { throw InferenceFailure.invalidRequest("Invalid ACE WAV chunk length.") }
            if data[offset..<(offset + 4)] == Data("fmt ".utf8) {
                guard format == nil, length >= 16 else { throw InferenceFailure.invalidRequest("Duplicate ACE WAV format.") }
                format = (Int(u16(data, body)), Int(u16(data, body + 2)), Int(u32(data, body + 4)),
                          Int(u32(data, body + 8)), Int(u16(data, body + 12)), Int(u16(data, body + 14)))
            } else if data[offset..<(offset + 4)] == Data("data".utf8) {
                guard pcm == nil else { throw InferenceFailure.invalidRequest("Duplicate ACE WAV audio data.") }
                pcm = body..<(body + length)
            }
            offset = body + length + (length & 1)
            guard offset <= data.count else { throw InferenceFailure.invalidRequest("Truncated ACE WAV padding.") }
        }
        guard offset == data.count, let format, let pcm,
              format.1 == 2, format.2 == 48_000,
              ((format.0 == 3 && format.5 == 32)
               || (format.0 == 1 && [16, 24, 32].contains(format.5))),
              format.4 == 2 * format.5 / 8,
              format.3 == 48_000 * format.4,
              pcm.count.isMultiple(of: format.4),
              Int64(pcm.count / format.4) == reference.frameCount else {
            throw InferenceFailure.invalidRequest("ACE WAV format or frame count disagrees with the frozen reference.")
        }
        if format.0 == 3 {
            var index = pcm.lowerBound
            while index < pcm.upperBound {
                guard Float(bitPattern: u32(data, index)).isFinite else {
                    throw InferenceFailure.invalidRequest("ACE WAV contains a nonfinite sample.")
                }
                index += 4
            }
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == reference.sha256 else {
            throw InferenceFailure.invalidRequest("ACE input SHA-256 changed.")
        }
        return data
    }

    private static func u16(_ data: Data, _ p: Int) -> UInt16 {
        UInt16(data[p]) | UInt16(data[p+1]) << 8
    }
    private static func u32(_ data: Data, _ p: Int) -> UInt32 {
        UInt32(data[p]) | UInt32(data[p+1]) << 8 | UInt32(data[p+2]) << 16 | UInt32(data[p+3]) << 24
    }
}

struct ACEMetadataExpectation: Sendable {
    let frozen: AudioJSONValue
    let requestedFrames: Int64
    let source: AudioSourceReference?
    let reference: AudioSourceReference?

    init(requestData: Data, audio: AudioRequest) throws {
        var parser = AudioJSONParser(data: requestData, maximumDepth: 32)
        frozen = try parser.parse()
        requestedFrames = Int64((audio.durationSeconds * 48_000).rounded())
        source = audio.source
        reference = audio.ace?.referenceAudio
    }
}

enum ACEProviderValidation {
    static func validate(_ result: AudioProviderResult,
                         expected: ACEMetadataExpectation,
                         inventory: ACEModelInventory) throws {
        let terminal = try result.snapshot.objectAny(context: "ACE terminal")
        let metadata = try terminal["metadata"]!.objectAny(context: "ACE metadata")
        guard metadata["request"] == expected.frozen,
              try metadata["profile"]?.requiredString(context: "ACE profile") == ACEModelInventory.profile,
              try metadata["modelRevision"]?.requiredString(context: "ACE model revision") == ACEModelInventory.modelRevision,
              try metadata["sharedRevision"]?.requiredString(context: "ACE shared revision") == ACEModelInventory.sharedRevision,
              try metadata["sourceRevision"]?.requiredString(context: "ACE source revision") == ACEModelInventory.sourceRevision,
              try metadata["precision"]?.requiredString(context: "ACE precision") == "XL=float32,MLX=float32,output=float32",
              try metadata["device"]?.requiredString(context: "ACE device") == "mps+mlx",
              try metadata["requestedFrames"]?.requiredInteger(context: "ACE requested frames") == expected.requestedFrames,
              try metadata["deliveredFrames"]?.requiredInteger(context: "ACE delivered frames") == result.artifact.frameCount,
              let effective = try metadata["effectiveFrames"]?.requiredInteger(context: "ACE effective frames"),
              effective > 0, result.artifact.frameCount > 0,
              metadata["sourceSHA256"] == expected.source.map({ .string($0.sha256) }) ?? .null,
              metadata["referenceSHA256"] == expected.reference.map({ .string($0.sha256) }) ?? .null else {
            throw InferenceFailure.backendFailed("ACE result does not match frozen request, sources, precision or length facts.")
        }
        guard case .array(let entries)? = metadata["weightManifest"],
              entries.count == inventory.files.count else {
            throw InferenceFailure.backendFailed("ACE result weight inventory is incomplete.")
        }
        var observed = Set<String>()
        for entry in entries {
            let item = try entry.object(exactKeys: ["path", "size", "sha256", "role"], context: "ACE weight")
            let path = try item["path"]!.requiredString(context: "ACE path")
            let size = try item["size"]!.requiredUInt64(context: "ACE size")
            let digest = try item["sha256"]!.requiredString(context: "ACE digest")
            let role = try item["role"]!.requiredString(context: "ACE role")
            guard observed.insert(path).inserted,
                  inventory.files.contains(where: { $0.file.path == path && $0.file.size == size
                    && $0.file.sha256 == digest && $0.file.role == role }) else {
                throw InferenceFailure.backendFailed("ACE result weight provenance changed.")
            }
        }
    }
}
