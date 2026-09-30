import DInference
import Foundation

/// The host supplies an already prepared, offline runtime and model inventory.
public struct ACEBackendConfiguration: Sendable {
    public let pythonExecutable: URL
    public let providerScript: URL
    public let vendorDirectory: URL
    public let modelManifest: URL
    public let artifactDirectory: URL
    public let timeoutSeconds: Double
    public let cancellationGraceSeconds: Double
    public let accessBootstrapRoot: URL?
    public let confirmDeployment: (@Sendable () throws -> Void)?

    public init(pythonExecutable: URL, providerScript: URL, vendorDirectory: URL,
                modelManifest: URL, artifactDirectory: URL,
                timeoutSeconds: Double = 3600, cancellationGraceSeconds: Double = 30,
                accessBootstrapRoot: URL? = nil,
                confirmDeployment: (@Sendable () throws -> Void)? = nil) {
        self.pythonExecutable = pythonExecutable; self.providerScript = providerScript
        self.vendorDirectory = vendorDirectory; self.modelManifest = modelManifest
        self.artifactDirectory = artifactDirectory
        self.timeoutSeconds = timeoutSeconds
        self.cancellationGraceSeconds = cancellationGraceSeconds
        self.accessBootstrapRoot = accessBootstrapRoot
        self.confirmDeployment = confirmDeployment
    }
}
