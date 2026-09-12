import Darwin
import DInference
import Foundation

/// Host-owned launch configuration for the fixed MRT2-small export provider.
/// Constructing this value performs no I/O and does not acknowledge model terms.
public struct MRT2BackendConfiguration: Sendable {
    public static let registeredModelRevision = "010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc"

    public let pythonExecutable: URL
    public let providerScript: URL
    public let vendorDirectory: URL
    public let modelManifest: URL
    public let artifactDirectory: URL
    public let licenseAcknowledged: Bool
    public let timeoutSeconds: Double
    public let cancellationGraceSeconds: Double
    public let accessBootstrapRoot: URL?
    public let confirmDeployment: (@Sendable () throws -> Void)?
    public let modelUseAcknowledged: (@Sendable () async -> Bool)?

    public init(
        pythonExecutable: URL,
        providerScript: URL,
        vendorDirectory: URL,
        modelManifest: URL,
        artifactDirectory: URL,
        licenseAcknowledged: Bool = false,
        timeoutSeconds: Double = 600,
        cancellationGraceSeconds: Double = 15,
        accessBootstrapRoot: URL? = nil,
        confirmDeployment: (@Sendable () throws -> Void)? = nil,
        modelUseAcknowledged: (@Sendable () async -> Bool)? = nil
    ) {
        self.pythonExecutable = pythonExecutable
        self.providerScript = providerScript
        self.vendorDirectory = vendorDirectory
        self.modelManifest = modelManifest
        self.artifactDirectory = artifactDirectory
        self.licenseAcknowledged = licenseAcknowledged
        self.timeoutSeconds = timeoutSeconds
        self.cancellationGraceSeconds = cancellationGraceSeconds
        self.accessBootstrapRoot = accessBootstrapRoot
        self.confirmDeployment = confirmDeployment
        self.modelUseAcknowledged = modelUseAcknowledged
    }
}

struct ValidatedMRT2Configuration: Sendable {
    let pythonExecutable: URL
    let providerScript: URL
    let vendorDirectory: URL
    let modelManifest: URL
    let artifactDirectory: URL
    let licenseAcknowledged: Bool
    let timeoutSeconds: Double
    let cancellationGraceSeconds: Double
    let providerIdentity: AudioFileSystem.Identity
    let manifestIdentity: AudioFileSystem.Identity
    let vendorIdentity: AudioFileSystem.Identity
    let modelIdentity: AudioFileSystem.Identity
}

extension AudioFileSystem {
    static func validate(
        _ configuration: MRT2BackendConfiguration,
        modelDirectory: URL
    ) throws -> ValidatedMRT2Configuration {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite,
              configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest(
                "MRT2 timeout and cancellation grace must be finite and positive.")
        }

        let suppliedPython = try absoluteLocal(configuration.pythonExecutable,
                                               label: "MRT2 Python executable")
        let python = suppliedPython.resolvingSymlinksInPath().standardizedFileURL
        _ = try regularFile(python, label: "MRT2 Python executable", maximumBytes: nil)
        guard Darwin.access(python.path, X_OK) == 0 else {
            throw InferenceFailure.invalidRequest("MRT2 Python executable is not executable.")
        }

        let provider = try absoluteLocal(configuration.providerScript,
                                         label: "MRT2 provider script")
        let providerIdentity = try regularFile(
            provider, label: "MRT2 provider script", maximumBytes: 16 * 1024 * 1024)
        let vendor = try absoluteLocal(configuration.vendorDirectory,
                                       label: "MRT2 vendor directory")
        try validateDirectory(vendor, label: "MRT2 vendor directory")
        let vendorIdentity = try directoryIdentity(vendor, label: "MRT2 vendor directory")
        let manifest = try absoluteLocal(configuration.modelManifest,
                                         label: "MRT2 model manifest")
        let manifestIdentity = try regularFile(
            manifest, label: "MRT2 model manifest", maximumBytes: 2 * 1024 * 1024)
        let artifacts = try absoluteLocal(configuration.artifactDirectory,
                                          label: "MRT2 artifact directory")
        try validateDirectory(artifacts, label: "MRT2 artifact directory")
        let model = try absoluteLocal(modelDirectory, label: "MRT2 model directory")
        try validateDirectory(model, label: "MRT2 model directory")
        let modelIdentity = try directoryIdentity(model, label: "MRT2 model directory")

        let protected: [(String, URL)] = [
            ("model", model), ("vendor", vendor), ("provider", provider),
            ("manifest", manifest), ("artifact", artifacts),
        ]
        for left in protected.indices {
            for right in protected.indices where right > left {
                guard !overlaps(protected[left].1, protected[right].1) else {
                    throw InferenceFailure.invalidRequest(
                        "MRT2 \(protected[left].0) and \(protected[right].0) paths must not overlap.")
                }
            }
        }

        if let suppliedBootstrap = configuration.accessBootstrapRoot {
            let bootstrap = try absoluteLocal(suppliedBootstrap,
                                              label: "MRT2 access bootstrap root")
            try validateDirectory(bootstrap, label: "MRT2 access bootstrap root")
            guard protected.allSatisfy({ !overlaps(bootstrap, $0.1) }) else {
                throw InferenceFailure.invalidRequest(
                    "MRT2 access bootstrap root must not overlap model, vendor, provider, manifest, or artifacts.")
            }
        }

        return ValidatedMRT2Configuration(
            pythonExecutable: python, providerScript: provider, vendorDirectory: vendor,
            modelManifest: manifest, artifactDirectory: artifacts,
            licenseAcknowledged: configuration.licenseAcknowledged,
            timeoutSeconds: configuration.timeoutSeconds,
            cancellationGraceSeconds: configuration.cancellationGraceSeconds,
            providerIdentity: providerIdentity, manifestIdentity: manifestIdentity,
            vendorIdentity: vendorIdentity, modelIdentity: modelIdentity)
    }

    static func directoryIdentity(_ url: URL, label: String) throws -> Identity {
        let descriptor = try openDirectory(url, label: label)
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw InferenceFailure.invalidRequest("Cannot inspect \(label).")
        }
        return Identity(value)
    }
}
