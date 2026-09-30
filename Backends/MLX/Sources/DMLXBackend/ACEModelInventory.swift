import CryptoKit
import Darwin
import DInference
import Foundation

/// Manifest v1 is an exact file inventory prepared by the host. Every path is relative
/// to the original model root, including its checkpoints/ prefix. Roles are xl, vae,
/// embedding. The runtime view in vendorDirectory is separately pinned by the host.
struct ACEModelInventory: Sendable {
    static let profile = ACERequest.fixedProfile
    static let modelRepository = "ACE-Step/acestep-v15-xl-sft"
    static let modelRevision = "d06de46b4622f781cf07f4a013a67d591ca52819"
    static let sharedRepository = "ACE-Step/Ace-Step1.5"
    static let sharedRevision = "19671f406d603126926c1b7e2adc169acbcade22"
    static let sourceRevision = "ca1e85fe9430179831e6bc6be790c332190a3866"

    struct File: Codable, Sendable, Equatable {
        let path: String
        let size: UInt64
        let sha256: String
        let role: String
    }
    struct Manifest: Codable, Sendable {
        let schemaVersion: Int
        let profile: String
        let modelRepository: String
        let modelRevision: String
        let sharedRepository: String
        let sharedRevision: String
        let sourceRevision: String
        let files: [File]
    }
    struct AdmittedFile: Sendable {
        let file: File
        let identity: AudioFileSystem.Identity
    }

    let root: URL
    let manifest: Manifest
    let files: [AdmittedFile]
    let estimatedPeakBytes: UInt64
    let configuration: ACEBackendConfiguration
    let providerIdentity: AudioFileSystem.Identity
    let manifestIdentity: AudioFileSystem.Identity
    let vendorIdentity: AudioFileSystem.Identity
    let rootIdentity: AudioFileSystem.Identity

    static func inspect(_ request: InferenceRequest,
                        configuration: ACEBackendConfiguration) throws -> Self {
        try Task.checkCancellation()
        try request.validate()
        guard case .audio(let audio) = request.input, let ace = audio.ace else {
            throw InferenceFailure.invalidRequest("ACE requires typed ACE-Step 1.5 audio parameters.")
        }
        try ace.validate()
        guard request.model.revision == modelRevision else {
            throw InferenceFailure.invalidRequest("ACE model revision is not the pinned XL SFT revision.")
        }
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite,
              configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest("Invalid ACE timeout or cancellation grace.")
        }
        let root = try AudioFileSystem.absoluteLocal(request.model.directory, label: "ACE model root")
        let provider = try AudioFileSystem.absoluteLocal(configuration.providerScript, label: "ACE provider")
        let manifestURL = try AudioFileSystem.absoluteLocal(configuration.modelManifest, label: "ACE manifest")
        let vendor = try AudioFileSystem.absoluteLocal(configuration.vendorDirectory, label: "ACE runtime view")
        let artifact = try AudioFileSystem.absoluteLocal(configuration.artifactDirectory, label: "ACE artifact root")
        let python = try AudioFileSystem.absoluteLocal(configuration.pythonExecutable, label: "ACE Python")
        _ = try AudioFileSystem.regularFile(python.resolvingSymlinksInPath(), label: "ACE Python", maximumBytes: nil)
        guard Darwin.access(python.path, X_OK) == 0 else {
            throw InferenceFailure.invalidRequest("ACE Python is not executable.")
        }
        try AudioFileSystem.validateDirectory(root, label: "ACE model root")
        try AudioFileSystem.validateDirectory(vendor, label: "ACE runtime view")
        try AudioFileSystem.validateDirectory(artifact, label: "ACE artifact root")
        let providerIdentity = try AudioFileSystem.regularFile(provider, label: "ACE provider", maximumBytes: 16 * 1024 * 1024)
        let manifestIdentity = try AudioFileSystem.regularFile(manifestURL, label: "ACE manifest", maximumBytes: 2 * 1024 * 1024)
        let vendorIdentity = try AudioFileSystem.directoryIdentity(vendor, label: "ACE runtime view")
        let rootIdentity = try AudioFileSystem.directoryIdentity(root, label: "ACE model root")
        let protected = [root, vendor, artifact, provider, manifestURL]
        for i in protected.indices {
            for j in protected.indices where j > i {
                guard !AudioFileSystem.overlaps(protected[i], protected[j]) else {
                    throw InferenceFailure.invalidRequest("ACE deployment paths overlap.")
                }
            }
        }
        if let bootstrap = configuration.accessBootstrapRoot {
            let local = try AudioFileSystem.absoluteLocal(bootstrap, label: "ACE access bootstrap")
            try AudioFileSystem.validateDirectory(local, label: "ACE access bootstrap")
            guard protected.allSatisfy({ !AudioFileSystem.overlaps(local, $0) }) else {
                throw InferenceFailure.invalidRequest("ACE bootstrap overlaps a protected path.")
            }
        }
        let manifestData = try AudioFileSystem.readRegularFile(
            manifestURL, label: "ACE manifest", maximumBytes: 2 * 1024 * 1024).0
        var parser = AudioJSONParser(data: manifestData, maximumDepth: 16)
        let parsed = try parser.parse()
        let object = try parsed.object(exactKeys: ["schemaVersion", "profile", "modelRepository",
            "modelRevision", "sharedRepository", "sharedRevision", "sourceRevision", "files"],
            context: "ACE manifest")
        guard try object["schemaVersion"]!.requiredInteger(context: "ACE schema") == 1,
              try object["profile"]!.requiredString(context: "ACE profile") == profile,
              try object["modelRepository"]!.requiredString(context: "ACE repository") == modelRepository,
              try object["modelRevision"]!.requiredString(context: "ACE model revision") == modelRevision,
              try object["sharedRepository"]!.requiredString(context: "ACE shared repository") == sharedRepository,
              try object["sharedRevision"]!.requiredString(context: "ACE shared revision") == sharedRevision,
              try object["sourceRevision"]!.requiredString(context: "ACE source revision") == sourceRevision,
              case .array(let entries) = object["files"]!, !entries.isEmpty,
              entries.count <= 4096 else {
            throw InferenceFailure.invalidRequest("ACE manifest is absent or identifies the wrong profile.")
        }
        var files: [File] = []
        var roles = Set<String>()
        var paths = Set<String>()
        for entry in entries {
            let file = try entry.object(exactKeys: ["path", "size", "sha256", "role"], context: "ACE manifest file")
            let path = try file["path"]!.requiredString(context: "ACE file path")
            let size = try file["size"]!.requiredUInt64(context: "ACE file size")
            let digest = try file["sha256"]!.requiredString(context: "ACE file digest")
            let role = try file["role"]!.requiredString(context: "ACE file role")
            guard paths.insert(path).inserted, size > 0, digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  ["xl", "vae", "embedding"].contains(role),
                  !path.contains(".."), !path.contains("//"), !path.contains("\0"),
                  path.hasPrefix("checkpoints/"), !path.hasSuffix("/") else {
                throw InferenceFailure.invalidRequest("Invalid ACE manifest file entry.")
            }
            let expectedPrefix = role == "xl" ? "checkpoints/acestep-v15-xl-sft/"
                : role == "vae" ? "checkpoints/vae/" : "checkpoints/Qwen3-Embedding-0.6B/"
            guard path.hasPrefix(expectedPrefix) else {
                throw InferenceFailure.invalidRequest("ACE file role and checkpoint path disagree.")
            }
            roles.insert(role)
            files.append(File(path: path, size: size, sha256: digest, role: role))
        }
        guard roles == Set(["xl", "vae", "embedding"]) else {
            throw InferenceFailure.invalidRequest("ACE requires XL, VAE and embedding resources.")
        }
        let decoded = Manifest(schemaVersion: 1, profile: profile,
            modelRepository: modelRepository, modelRevision: modelRevision,
            sharedRepository: sharedRepository, sharedRevision: sharedRevision,
            sourceRevision: sourceRevision, files: files)
        var admitted: [AdmittedFile] = []
        var total: UInt64 = 0
        for file in files {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(file.path)
            let identity = try AudioFileSystem.regularFile(url, label: "ACE resource \(file.path)", maximumBytes: nil)
            guard identity.size >= 0, UInt64(identity.size) == file.size,
                  try sha256(url) == file.sha256 else {
                throw InferenceFailure.invalidRequest("ACE resource does not match manifest: \(file.path)")
            }
            admitted.append(AdmittedFile(file: file, identity: identity))
            let (sum, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow else { throw InferenceFailure.invalidRequest("ACE inventory size overflow.") }
            total = sum
        }
        // Official MPS initialization holds the PyTorch model and MLX converted copy.
        // This estimate includes both full-precision copies and a bounded runtime reserve.
        let (twice, overflow) = total.multipliedReportingOverflow(by: 2)
        let (estimate, overflow2) = twice.addingReportingOverflow(8 * 1024 * 1024 * 1024)
        guard !overflow, !overflow2 else { throw InferenceFailure.invalidRequest("ACE peak estimate overflow.") }
        return Self(root: root, manifest: decoded, files: admitted,
                    estimatedPeakBytes: estimate, configuration: configuration,
                    providerIdentity: providerIdentity, manifestIdentity: manifestIdentity,
                    vendorIdentity: vendorIdentity, rootIdentity: rootIdentity)
    }

    func confirmUnchanged() throws {
        guard try AudioFileSystem.regularFile(configuration.providerScript, label: "ACE provider", maximumBytes: 16 * 1024 * 1024) == providerIdentity,
              try AudioFileSystem.regularFile(configuration.modelManifest, label: "ACE manifest", maximumBytes: 2 * 1024 * 1024) == manifestIdentity,
              try AudioFileSystem.directoryIdentity(configuration.vendorDirectory, label: "ACE runtime view") == vendorIdentity,
              try AudioFileSystem.directoryIdentity(root, label: "ACE model root") == rootIdentity else {
            throw InferenceFailure.invalidRequest("ACE deployment changed after admission.")
        }
        for admitted in files {
            let url = root.appendingPathComponent(admitted.file.path)
            guard try AudioFileSystem.regularFile(url, label: "ACE resource", maximumBytes: nil) == admitted.identity,
                  try Self.sha256(url) == admitted.file.sha256 else {
                throw InferenceFailure.invalidRequest("ACE resource changed after admission: \(admitted.file.path)")
            }
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw InferenceFailure.invalidRequest("ACE resource cannot be opened without following links.") }
        defer { Darwin.close(fd) }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw InferenceFailure.invalidRequest("ACE resource read failed.") }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
