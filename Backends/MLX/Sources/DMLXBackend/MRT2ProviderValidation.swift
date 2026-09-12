import CryptoKit
import Darwin
import DInference
import Foundation

struct MRT2MetadataExpectation: Sendable {
    let requestSnapshot: AudioJSONValue
    let condition: AudioJSONValue
    let conditionSHA256: String
    let prompt: String
    let seed: UInt64
    let weights: [MRT2ModelInventory.Weight]

    init(requestData: Data, inventory: MRT2ModelInventory, audio: AudioRequest) throws {
        var requestParser = AudioJSONParser(data: requestData, maximumDepth: 16)
        requestSnapshot = try requestParser.parse()

        guard case .mrt2FixedV1(let sequence) = audio.parameters else {
            throw InferenceFailure.invalidRequest(
                "MRT2 metadata requires fixed-v1 note conditioning.")
        }
        let canonical = CanonicalCondition(sequence: sequence)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonical)
        var conditionParser = AudioJSONParser(data: data, maximumDepth: 16)
        condition = try conditionParser.parse()
        conditionSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        prompt = audio.prompt
        seed = audio.seed
        weights = inventory.weights
    }

    private struct CanonicalCondition: Encodable {
        struct Sequence: Encodable {
            struct Note: Encodable {
                let pitch: Int
                let startFrame: Int
                let endFrame: Int
            }

            let schemaVersion: Int
            let frameRate: Int
            let durationFrames: Int
            let notes: [Note]?
        }

        let sequence: Sequence
        let notesMode: String

        init(sequence source: AudioNoteSequence) {
            sequence = Sequence(
                schemaVersion: source.schemaVersion,
                frameRate: source.frameRate,
                durationFrames: source.durationFrames,
                notes: source.canonicalNotes?.map {
                    Sequence.Note(pitch: $0.pitch, startFrame: $0.startFrame,
                                  endFrame: $0.endFrame)
                })
            if source.notes == nil {
                notesMode = "absent"
            } else if source.notes?.isEmpty == true {
                notesMode = "explicitEmpty"
            } else {
                notesMode = "notes"
            }
        }
    }
}

enum MRT2ProviderValidation {
    static let sdkRevision = "694a545e4ba0b88bf1150137b129582166d3e07f"

    static func validateMetadata(
        _ result: AudioProviderResult,
        expected: MRT2MetadataExpectation
    ) throws {
        do {
            let terminal = try result.snapshot.objectAny(context: "MRT2 result terminal")
            guard let metadataValue = terminal["metadata"] else {
                throw InferenceFailure.backendFailed("MRT2 result metadata is absent.")
            }
            let metadata = try metadataValue.objectAny(context: "MRT2 result metadata")
            let required = Set([
                "request", "profile", "modelRepository", "modelRevision", "weightManifest",
                "sdkRevision", "condition", "conditionSHA256", "engineIdentity",
                "timingsSeconds", "mlxAllocations", "cleanup",
            ])
            guard required.isSubset(of: Set(metadata.keys)),
                  metadata["request"] == expected.requestSnapshot,
                  metadata["condition"] == expected.condition,
                  try metadata["profile"]!.requiredString(context: "MRT2 profile")
                    == MRT2ModelInventory.profile,
                  try metadata["modelRepository"]!.requiredString(context: "MRT2 repository")
                    == MRT2ModelInventory.repository,
                  try metadata["modelRevision"]!.requiredString(context: "MRT2 revision")
                    == MRT2ModelInventory.revision,
                  try metadata["sdkRevision"]!.requiredString(context: "MRT2 SDK revision")
                    == sdkRevision,
                  try metadata["conditionSHA256"]!.requiredString(context: "MRT2 condition digest")
                    == expected.conditionSHA256 else {
                throw InferenceFailure.backendFailed(
                    "MRT2 result does not match the admitted request, condition, or revisions.")
            }

            try validateWeights(metadata["weightManifest"]!, expected: expected.weights)
            try validateEngineIdentity(metadata["engineIdentity"]!, expected: expected)
            try validateCleanup(metadata["cleanup"]!)
            try validateDiagnostics(metadata["timingsSeconds"]!, context: "MRT2 timings")
            try validateDiagnostics(metadata["mlxAllocations"]!, context: "MRT2 allocations")
        } catch let failure as InferenceFailure {
            if case .backendFailed = failure { throw failure }
            throw InferenceFailure.backendFailed(
                "Invalid MRT2 provider metadata: \(failure.localizedDescription)")
        } catch {
            throw InferenceFailure.backendFailed(
                "Invalid MRT2 provider metadata: \(error.localizedDescription)")
        }
    }

    private static func validateWeights(
        _ value: AudioJSONValue,
        expected weights: [MRT2ModelInventory.Weight]
    ) throws {
        guard case .array(let entries) = value, entries.count == 6 else {
            throw InferenceFailure.backendFailed(
                "MRT2 result must identify exactly six model files.")
        }
        var actual: [String: (UInt64, String)] = [:]
        for entry in entries {
            let item = try entry.object(
                exactKeys: ["path", "size", "sha256"], context: "MRT2 weight provenance")
            let path = try item["path"]!.requiredString(context: "MRT2 weight path")
            let size = try item["size"]!.requiredUInt64(context: "MRT2 weight size")
            let digest = try item["sha256"]!.requiredString(context: "MRT2 weight digest")
            guard actual.updateValue((size, digest), forKey: path) == nil else {
                throw InferenceFailure.backendFailed(
                    "MRT2 result contains duplicate weight provenance.")
            }
        }
        guard actual.count == weights.count,
              weights.allSatisfy({ actual[$0.path]?.0 == $0.size
                                  && actual[$0.path]?.1 == $0.sha256 }) else {
            throw InferenceFailure.backendFailed(
                "MRT2 result weight provenance differs from admission.")
        }
    }

    private static func validateEngineIdentity(
        _ value: AudioJSONValue,
        expected: MRT2MetadataExpectation
    ) throws {
        let identity = try value.objectAny(context: "MRT2 engine identity")
        let required = Set([
            "profile", "model_name", "model_revision", "sdk_repository", "sdk_revision",
            "sdk_source_files", "graph_conversion", "graph_internal_precision",
            "output_conversion", "mlx_version", "numpy_version", "litert_version",
            "sentencepiece_version", "prompt", "prompt_sentencepiece_tokens", "mapper_seed",
            "sampling_seed", "sampling_key_state_index", "state_leaf_count", "warmup_steps",
            "temperature", "top_k", "cfg_scales", "closed", "released",
        ])
        guard required.isSubset(of: Set(identity.keys)),
              !containsForbiddenPathKey(value),
              try identity["profile"]!.requiredString(context: "engine profile")
                == MRT2ModelInventory.profile,
              try identity["model_name"]!.requiredString(context: "engine model name")
                == "mrt2_small",
              try identity["model_revision"]!.requiredString(context: "engine model revision")
                == MRT2ModelInventory.revision,
              try identity["sdk_repository"]!.requiredString(context: "engine SDK repository")
                == "https://github.com/magenta/magenta-realtime",
              try identity["sdk_revision"]!.requiredString(context: "engine SDK revision")
                == sdkRevision,
              try identity["graph_conversion"]!.requiredString(context: "engine graph conversion")
                == "official MLX export loaded with import_function",
              try identity["graph_internal_precision"]!.requiredString(context: "engine precision")
                == "unknown",
              try identity["output_conversion"]!.requiredString(context: "engine output conversion")
                == "graph int16 to float32 divided by 32768",
              try identity["prompt"]!.requiredString(context: "engine prompt") == expected.prompt,
              try identity["prompt_sentencepiece_tokens"]!.requiredInteger(
                context: "engine prompt token count") >= 0,
              try identity["mapper_seed"]!.requiredInteger(context: "engine mapper seed") == 0,
              try identity["sampling_seed"]!.requiredUInt64(context: "engine sampling seed")
                == expected.seed,
              try identity["sampling_key_state_index"]!.requiredInteger(
                context: "engine sampling-key state index") == 2,
              try identity["state_leaf_count"]!.requiredInteger(context: "engine state count") == 165,
              try identity["warmup_steps"]!.requiredInteger(context: "engine warmup steps") == 5,
              identity["temperature"] == decimal("1.3"),
              try identity["top_k"]!.requiredInteger(context: "engine top-k") == 40,
              identity["closed"] == .bool(false), identity["released"] == .bool(false),
              identity["close_error"] == nil else {
            throw InferenceFailure.backendFailed(
                "MRT2 engine identity is incomplete or contradicts the executed export.")
        }

        let sourceFiles = [
            "magenta_rt/mlx/system.py", "magenta_rt/musiccoca.py",
            "magenta_rt/config.py", "magenta_rt/mlx/model.py",
        ].map(AudioJSONValue.string)
        guard identity["sdk_source_files"] == .array(sourceFiles) else {
            throw InferenceFailure.backendFailed("MRT2 SDK source identity is incorrect.")
        }
        for key in ["mlx_version", "numpy_version", "litert_version", "sentencepiece_version"] {
            let version = try identity[key]!.requiredString(context: "engine \(key)")
            guard !version.isEmpty,
                  !["unknown", "unavailable"].contains(version.lowercased()) else {
                throw InferenceFailure.backendFailed("MRT2 engine version is absent: \(key)")
            }
        }
        let scales = try identity["cfg_scales"]!.object(
            exactKeys: ["musiccoca", "notes", "drums"], context: "MRT2 CFG scales")
        guard scales["musiccoca"] == .integer(3), scales["notes"] == .integer(1),
              scales["drums"] == .integer(1) else {
            throw InferenceFailure.backendFailed("MRT2 CFG scales are incorrect.")
        }
    }

    private static func validateCleanup(_ value: AudioJSONValue) throws {
        let cleanup = try value.objectAny(context: "MRT2 cleanup")
        guard cleanup["released"] == .bool(true), cleanup["error"] == nil else {
            throw InferenceFailure.backendFailed(
                "MRT2 cleanup must prove release and contain no error.")
        }
    }

    private static func validateDiagnostics(
        _ value: AudioJSONValue,
        context: String,
        enclosingUnavailable: Bool = false
    ) throws {
        switch value {
        case .integer(let number) where number >= 0: return
        case .unsignedInteger: return
        case .number(let number) where number >= 0: return
        case .string(let text) where !text.isEmpty: return
        case .bool: return
        case .null where enclosingUnavailable: return
        case .array(let values):
            guard !values.isEmpty else {
                throw InferenceFailure.backendFailed("\(context) cannot be an empty diagnostic array.")
            }
            for entry in values {
                try validateDiagnostics(entry, context: context,
                                        enclosingUnavailable: enclosingUnavailable)
            }
        case .object(let object):
            guard !object.isEmpty else {
                throw InferenceFailure.backendFailed("\(context) cannot be empty.")
            }
            let unavailable = enclosingUnavailable || object.values.contains {
                if case .string(let text) = $0 {
                    return ["unknown", "unavailable"].contains(text.lowercased())
                }
                return false
            }
            for (key, entry) in object {
                try validateDiagnostics(entry, context: "\(context).\(key)",
                                        enclosingUnavailable: unavailable)
            }
        default:
            throw InferenceFailure.backendFailed(
                "\(context) contains a negative, non-finite, or unexplained unavailable value.")
        }
    }

    private static func containsForbiddenPathKey(_ value: AudioJSONValue) -> Bool {
        guard case .object(let object) = value else { return false }
        let forbidden = Set(["model_root", "graph_path", "state_path", "resource_paths"])
        return !forbidden.isDisjoint(with: Set(object.keys))
            || object.values.contains(where: containsForbiddenPathKey)
    }

    private static func decimal(_ text: String) -> AudioJSONValue {
        .number(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!)
    }
}

/// Commits an already validated private-access report without granting the child any
/// additional path. All operations are anchored to the existing, no-follow job descriptor.
enum MRT2ReportCommit {
    static let pendingName = "pending-result.json"
    static let finalName = "result.json"

    static func observedURL(job: URL, accessConfigured: Bool) -> URL {
        job.appendingPathComponent(accessConfigured ? pendingName : finalName)
    }

    static func promotePending(
        in job: URL,
        expectedData: Data,
        expectedIdentity: AudioFileSystem.Identity
    ) throws -> URL {
        let jobDescriptor = try AudioFileSystem.openDirectory(
            job, label: "MRT2 job directory")
        defer { Darwin.close(jobDescriptor) }

        try validateFile(
            named: pendingName, in: jobDescriptor, expectedData: expectedData,
            expectedIdentity: expectedIdentity, requireFullIdentity: true,
            checkCancellation: true)

        var destination = stat()
        guard Darwin.fstatat(
            jobDescriptor, finalName, &destination, AT_SYMLINK_NOFOLLOW) != 0 else {
            throw InferenceFailure.backendFailed(
                "MRT2 result promotion refuses to overwrite an existing result.json.")
        }
        guard errno == ENOENT else {
            throw ioFailure("Inspect MRT2 result promotion destination")
        }

        var currentPending = stat()
        guard Darwin.fstatat(
            jobDescriptor, pendingName, &currentPending, AT_SYMLINK_NOFOLLOW) == 0,
              currentPending.st_mode & S_IFMT == S_IFREG,
              AudioFileSystem.Identity(currentPending) == expectedIdentity else {
            throw InferenceFailure.backendFailed(
                "MRT2 pending result changed immediately before promotion.")
        }

        try Task.checkCancellation()
        guard renameatx_np(
            jobDescriptor, pendingName, jobDescriptor, finalName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw ioFailure("Promote MRT2 pending result without overwriting")
        }
        do {
            guard Darwin.fsync(jobDescriptor) == 0 else {
                throw ioFailure("Flush MRT2 result promotion")
            }
            try validateFile(
                named: finalName, in: jobDescriptor, expectedData: expectedData,
                expectedIdentity: expectedIdentity, requireFullIdentity: false,
                checkCancellation: false)
        } catch {
            // The rename is the commit point. Never delete or replace a committed result
            // merely because durability/readback verification subsequently failed.
            throw InferenceFailure.backendFailed(
                "MRT2 result was promoted but final verification failed; the file was preserved: "
                + error.localizedDescription)
        }
        return job.appendingPathComponent(finalName)
    }

    private static func validateFile(
        named name: String,
        in directory: Int32,
        expectedData: Data,
        expectedIdentity: AudioFileSystem.Identity,
        requireFullIdentity: Bool,
        checkCancellation: Bool
    ) throws {
        let descriptor = Darwin.openat(
            directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioFailure("Open MRT2 \(name)") }
        defer { Darwin.close(descriptor) }

        var beforeValue = stat()
        guard Darwin.fstat(descriptor, &beforeValue) == 0,
              beforeValue.st_mode & S_IFMT == S_IFREG,
              beforeValue.st_size >= 0,
              UInt64(beforeValue.st_size) == UInt64(expectedData.count) else {
            throw InferenceFailure.backendFailed(
                "MRT2 \(name) is not the expected bounded regular file.")
        }
        let before = AudioFileSystem.Identity(beforeValue)
        if requireFullIdentity {
            guard before == expectedIdentity else {
                throw InferenceFailure.backendFailed(
                    "MRT2 pending result changed before promotion.")
            }
        } else {
            guard before.device == expectedIdentity.device,
                  before.inode == expectedIdentity.inode else {
                throw InferenceFailure.backendFailed(
                    "MRT2 promoted result does not retain the pending file identity.")
            }
        }

        var data = Data()
        data.reserveCapacity(expectedData.count)
        var buffer = [UInt8](repeating: 0, count: min(max(expectedData.count, 1), 64 * 1024))
        while data.count < expectedData.count {
            if checkCancellation { try Task.checkCancellation() }
            let requested = min(buffer.count, expectedData.count - data.count)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ioFailure("Read complete MRT2 \(name)") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var extra: UInt8 = 0
        var trailing: Int
        repeat { trailing = Darwin.read(descriptor, &extra, 1) }
        while trailing < 0 && errno == EINTR
        guard trailing == 0 else {
            throw InferenceFailure.backendFailed("MRT2 \(name) grew while being verified.")
        }
        var afterValue = stat()
        guard Darwin.fstat(descriptor, &afterValue) == 0,
              AudioFileSystem.Identity(afterValue) == before,
              data == expectedData else {
            throw InferenceFailure.backendFailed(
                "MRT2 \(name) identity or content changed during verification.")
        }
    }

    private static func ioFailure(_ action: String) -> InferenceFailure {
        .backendFailed("\(action): \(String(cString: strerror(errno)))")
    }
}
