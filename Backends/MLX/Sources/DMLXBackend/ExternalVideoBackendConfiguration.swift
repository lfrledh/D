import DInference
import Foundation

public struct ExternalVideoBackendConfiguration: Sendable {
    public let profile: ExternalVideoExecutionProfile
    public let pythonExecutable: URL
    public let providerScript: URL
    public let ffmpeg: URL
    public let ffprobe: URL
    public let h3Executable: URL?
    public let h3Shader: URL?
    public let artifactDirectory: URL
    public let accessBootstrapRoot: URL?
    public let timeoutSeconds: Double
    public let cancellationGraceSeconds: Double
    public let confirmDeployment: (@Sendable () throws -> Void)?
    public init(profile: ExternalVideoExecutionProfile, pythonExecutable: URL, providerScript: URL,
                ffmpeg: URL, ffprobe: URL, h3Executable: URL? = nil, h3Shader: URL? = nil,
                artifactDirectory: URL, accessBootstrapRoot: URL? = nil,
                timeoutSeconds: Double = 7200, cancellationGraceSeconds: Double = 10,
                confirmDeployment: (@Sendable () throws -> Void)? = nil) {
        self.profile = profile; self.pythonExecutable = pythonExecutable; self.providerScript = providerScript
        self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; self.h3Executable = h3Executable; self.h3Shader = h3Shader
        self.artifactDirectory = artifactDirectory; self.accessBootstrapRoot = accessBootstrapRoot
        self.timeoutSeconds = timeoutSeconds; self.cancellationGraceSeconds = cancellationGraceSeconds
        self.confirmDeployment = confirmDeployment
    }
}

extension ExternalVideoBackendConfiguration {
    /// Registration checks only bounded metadata and paths. Full component hashes
    /// and precision are checked by the fixed provider before importing a model.
    func inspectPack(at directory: URL) throws -> Data {
        try confirmDeployment?()
        guard profile != .ltx25BF16Full else {
            throw InferenceFailure.invalidRequest("LTX 2.5 is a declared recipe, pending its gated component inventory and real validation; it is not ready to run.")
        }
        try AudioFileSystem.validateDirectory(directory, label: "video model pack")
        let (data, _) = try AudioFileSystem.readRegularFile(directory.appendingPathComponent(ExternalVideoModelManifest.filename),
            label: "video pack manifest", maximumBytes: 16 * 1024)
        var parser = AudioJSONParser(data: data, maximumDepth: 8)
        var keys: Set<String> = ["schemaVersion", "profile", "modelRevision"]
        if profile.textEncoderRevision != nil { keys.insert("textEncoderRevision") }
        let object = try parser.parse().object(exactKeys: keys, context: "video pack manifest")
        guard try object["schemaVersion"]?.requiredInteger(context: "pack schema") == 1 else {
            throw InferenceFailure.invalidRequest("Unsupported video pack schema.")
        }
        let value = try JSONDecoder().decode(ExternalVideoModelManifest.self, from: data)
        try value.validate()
        guard value.profile == profile else { throw InferenceFailure.invalidRequest("Video pack belongs to another recipe.") }
        try AudioFileSystem.validateDirectory(directory.appendingPathComponent("model"), label: "video model component")
        if profile.textEncoderRevision != nil {
            try AudioFileSystem.validateDirectory(directory.appendingPathComponent("text_encoder"), label: "video text component")
        }
        for protected in [directory, pythonExecutable.deletingLastPathComponent(), providerScript.deletingLastPathComponent()] {
            guard !AudioFileSystem.overlaps(artifactDirectory, protected) else {
                throw InferenceFailure.invalidRequest("Private video outputs must not overlap model or engine files.")
            }
        }
        return data
    }
}
