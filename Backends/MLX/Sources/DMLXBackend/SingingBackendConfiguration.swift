import Foundation

/// Host-owned, explicit standalone deployment. Constructing a configuration does
/// not load code, scan models, grant material rights or request system access.
public struct SingingBackendConfiguration: Sendable {
    public static let profileID = "qixuan-2.7.0-bigvgan-44k-approx-v1"
    public static let profileSHA256 = "15489802b768fdd5c447325d5483b293601e63db54f46e84eb1c7b84df010a39"
    public static let vendorManifestSHA256 = "e3f9f9eb2a3cad99b5f75501cbc8b5fd6504257d0c26a69c2f1c817d2c7d0000"
    public static let bankArchiveSHA256 = "fe8ee7c95883d327a2b7facbbe832a7a53e1344918dc791ca83fc23b08034110"
    public static let vocoderRevision = "95a9d1dcb12906c03edd938d77b9333d6ded7dfb"

    public let pythonExecutable: URL
    public let providerScript: URL
    public let vendorDirectory: URL
    public let profileManifest: URL
    public let artifactDirectory: URL
    public let timeoutSeconds: Double
    public let cancellationGraceSeconds: Double

    public init(pythonExecutable: URL, providerScript: URL, vendorDirectory: URL,
                profileManifest: URL, artifactDirectory: URL,
                timeoutSeconds: Double = 600, cancellationGraceSeconds: Double = 45) {
        self.pythonExecutable = pythonExecutable; self.providerScript = providerScript
        self.vendorDirectory = vendorDirectory; self.profileManifest = profileManifest
        self.artifactDirectory = artifactDirectory; self.timeoutSeconds = timeoutSeconds
        self.cancellationGraceSeconds = cancellationGraceSeconds
    }
}
