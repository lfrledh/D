import DInference
import Foundation

struct MRT2ModelInventory: Sendable {
    static let profile = "mrt2-small-export-v1"
    static let repository = "google/magenta-realtime-2"
    static let revision = MRT2BackendConfiguration.registeredModelRevision
    static let recordedLicense = "CC-BY-4.0; model card additional responsible use terms"

    struct Weight: Sendable, Equatable {
        let path: String
        let size: UInt64
        let sha256: String
        let identity: AudioFileSystem.Identity
    }

    struct ManifestFile: Sendable, Equatable {
        let path: String
        let size: UInt64
        let sha256: String
    }

    struct Manifest: Sendable, Equatable {
        let license: String
        let files: [ManifestFile]
    }

    static let requiredFiles: [ManifestFile] = [
        ManifestFile(
            path: "models/mrt2_small/mrt2_small.mlxfn", size: 455_654_550,
            sha256: "1a70b0de30b3e6ad054fe6a61a7765408f01127628e6362c1abc328809a3c422"),
        ManifestFile(
            path: "models/mrt2_small/mrt2_small_state.safetensors", size: 8_676_998,
            sha256: "23f1e05a6beea306fe39970bd61193f2d3e5fbd8f08af93570bda4ca9ec33255"),
        ManifestFile(
            path: "resources/musiccoca/mapper.tflite", size: 86_166_664,
            sha256: "2f9743cc8f121a588b69c7f4d79a2a4111ce81864cbde8830054cd5e97f3d717"),
        ManifestFile(
            path: "resources/musiccoca/pretrained_vector_quantizer.tflite", size: 72_422_108,
            sha256: "7a8a19e2119ad405818eae84a331a970f1a582b3389d4bfd27814f75b455a444"),
        ManifestFile(
            path: "resources/musiccoca/spm.model", size: 517_448,
            sha256: "ff325a99b61ba5726cf6437cde6eefbb633dbaa363a684f7a97ed99b55202cca"),
        ManifestFile(
            path: "resources/musiccoca/text_encoder.tflite", size: 418_674_324,
            sha256: "e1222e3418cbe8cc2623939571bae8e9ab6f0d511404b0d83da69f4e6e11b272"),
    ]

    let directory: URL
    let weights: [Weight]
    let estimatedPeakBytes: UInt64
    let configuration: ValidatedMRT2Configuration

    static func inspect(
        _ request: InferenceRequest,
        configuration supplied: MRT2BackendConfiguration
    ) throws -> Self {
        try Task.checkCancellation()
        try request.validate()
        guard case .audio(let audio) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        guard request.model.revision == revision else {
            throw InferenceFailure.invalidRequest(
                "MRT2 execution requires the registered revision \(revision).")
        }
        guard case .mrt2FixedV1(let sequence) = audio.parameters,
              audio.operation == .generate, audio.source == nil, audio.editRegion == nil else {
            throw InferenceFailure.invalidRequest(
                "MRT2 accepts only fixed-v1 note-conditioned generation requests.")
        }
        try sequence.validate()

        let configuration = try AudioFileSystem.validate(
            supplied, modelDirectory: request.model.directory)
        let manifestData = try AudioFileSystem.readRegularFile(
            configuration.modelManifest, label: "MRT2 model manifest",
            maximumBytes: 2 * 1024 * 1024).0
        let manifest = try parseManifest(manifestData)
        var weights: [Weight] = []
        for file in manifest.files {
            try Task.checkCancellation()
            let url = request.model.directory.appendingPathComponent(file.path)
            let identity = try AudioFileSystem.regularFile(
                url, label: "MRT2 model file \(file.path)", maximumBytes: nil)
            guard identity.size >= 0, UInt64(identity.size) == file.size else {
                throw InferenceFailure.invalidRequest(
                    "MRT2 model file size mismatch: \(file.path)")
            }
            weights.append(Weight(path: file.path, size: file.size,
                                  sha256: file.sha256, identity: identity))
        }
        return Self(
            directory: request.model.directory.standardizedFileURL,
            weights: weights,
            estimatedPeakBytes: try estimate(durationFrames: sequence.durationFrames),
            configuration: configuration)
    }

    func confirmUnchanged() throws {
        let currentProvider = try AudioFileSystem.regularFile(
            configuration.providerScript, label: "MRT2 provider script",
            maximumBytes: 16 * 1024 * 1024)
        let currentManifest = try AudioFileSystem.regularFile(
            configuration.modelManifest, label: "MRT2 model manifest",
            maximumBytes: 2 * 1024 * 1024)
        let currentVendor = try AudioFileSystem.directoryIdentity(
            configuration.vendorDirectory, label: "MRT2 vendor directory")
        let currentModel = try AudioFileSystem.directoryIdentity(
            directory, label: "MRT2 model directory")
        guard currentProvider == configuration.providerIdentity,
              currentManifest == configuration.manifestIdentity,
              currentVendor == configuration.vendorIdentity,
              currentModel == configuration.modelIdentity else {
            throw InferenceFailure.invalidRequest(
                "MRT2 deployment inputs changed after admission.")
        }
        for weight in weights {
            try Task.checkCancellation()
            let current = try AudioFileSystem.regularFile(
                directory.appendingPathComponent(weight.path),
                label: "MRT2 model file \(weight.path)", maximumBytes: nil)
            guard current == weight.identity else {
                throw InferenceFailure.invalidRequest(
                    "MRT2 model file changed after admission: \(weight.path)")
            }
        }
    }

    static func estimate(durationFrames: Int) throws -> UInt64 {
        guard durationFrames > 0 else {
            throw InferenceFailure.invalidRequest("MRT2 duration frames must be positive.")
        }
        let frames = UInt64(durationFrames)
        let (samples, sampleOverflow) = frames.multipliedReportingOverflow(by: 1_920)
        let (pcmBytes, pcmOverflow) = samples.multipliedReportingOverflow(by: 2 * 4)
        let (workspace, workspaceOverflow) = pcmBytes.multipliedReportingOverflow(by: 3)
        let (total, totalOverflow) = UInt64(3 * 1024 * 1024 * 1024)
            .addingReportingOverflow(workspace)
        guard !sampleOverflow, !pcmOverflow, !workspaceOverflow, !totalOverflow else {
            throw InferenceFailure.invalidRequest("MRT2 resource estimate exceeds UInt64 capacity.")
        }
        return total
    }

    static func parseManifest(_ data: Data) throws -> Manifest {
        let root: AudioJSONValue
        do {
            var parser = AudioJSONParser(data: data, maximumDepth: 16)
            root = try parser.parse()
        } catch {
            throw InferenceFailure.invalidRequest(
                "Invalid MRT2 model manifest JSON: \(error.localizedDescription)")
        }
        let object = try root.object(
            exactKeys: ["schemaVersion", "profile", "repository", "revision", "license", "files"],
            context: "MRT2 manifest")
        guard try object["schemaVersion"]!.requiredInteger(context: "MRT2 schemaVersion") == 1,
              try object["profile"]!.requiredString(context: "MRT2 profile") == profile,
              try object["repository"]!.requiredString(context: "MRT2 repository") == repository,
              try object["revision"]!.requiredString(context: "MRT2 revision") == revision else {
            throw InferenceFailure.invalidRequest(
                "MRT2 manifest does not identify the fixed schema, profile, repository, and revision.")
        }
        let license = try object["license"]!.requiredString(context: "MRT2 recorded license")
        guard !license.isEmpty, case .array(let entries) = object["files"]!,
              entries.count == requiredFiles.count else {
            throw InferenceFailure.invalidRequest(
                "MRT2 manifest must record its license text and exactly six files.")
        }

        let expected = Dictionary(uniqueKeysWithValues: requiredFiles.map { ($0.path, $0) })
        var files: [ManifestFile] = []
        var paths = Set<String>()
        for entry in entries {
            let item = try entry.object(
                exactKeys: ["path", "size", "sha256"], context: "MRT2 manifest file")
            let path = try item["path"]!.requiredString(context: "MRT2 file path")
            let size = try item["size"]!.requiredUInt64(context: "MRT2 file size")
            let sha256 = try item["sha256"]!.requiredString(context: "MRT2 file SHA-256")
            guard paths.insert(path).inserted, let fixed = expected[path],
                  fixed.size == size, fixed.sha256 == sha256 else {
                throw InferenceFailure.invalidRequest(
                    "MRT2 manifest file does not match the fixed inventory: \(path)")
            }
            files.append(ManifestFile(path: path, size: size, sha256: sha256))
        }
        guard paths == Set(expected.keys) else {
            throw InferenceFailure.invalidRequest(
                "MRT2 manifest does not contain exactly the fixed six-file inventory.")
        }
        return Manifest(license: license, files: files)
    }
}
