import CryptoKit
import Darwin
import DInference
import Foundation

public struct PitchBackendConfiguration: Sendable {
    public let pythonExecutable: URL
    public let providerScript: URL
    public let artifactDirectory: URL
    public let timeoutSeconds: Double
    public let cancellationGraceSeconds: Double
    public let accessBootstrapRoot: URL?

    public init(pythonExecutable: URL, providerScript: URL, artifactDirectory: URL,
                timeoutSeconds: Double = 30, cancellationGraceSeconds: Double = 2,
                accessBootstrapRoot: URL? = nil) {
        self.pythonExecutable = pythonExecutable
        self.providerScript = providerScript
        self.artifactDirectory = artifactDirectory
        self.timeoutSeconds = timeoutSeconds
        self.cancellationGraceSeconds = cancellationGraceSeconds
        self.accessBootstrapRoot = accessBootstrapRoot
    }
}

public actor PitchAnalysisBackend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "cpu.pitch.swift-f0", version: "0.1.2-d1", capabilities: [.audioPitchAnalysis])

    private let configuration: PitchBackendConfiguration
    private var executing = false
    private var requiresRelease = false

    public init(configuration: PitchBackendConfiguration) throws {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite,
              configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest(
                "Pitch timeout and cancellation grace must be finite and positive.")
        }
        self.configuration = configuration
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        _ = try PitchAdmission.inspect(request, configuration: configuration)
        return ResourceEstimate(peakBytes: 256 * 1024 * 1024, confidence: .estimated)
    }

    public func execute(
        _ request: InferenceRequest,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async throws -> InferenceResult {
        guard !executing, !requiresRelease else {
            throw InferenceFailure.backendFailed(
                "Pitch execution requires release of the preceding run.")
        }
        executing = true
        requiresRelease = true
        defer { executing = false }
        try Task.checkCancellation()

        let admission = try PitchAdmission.inspect(request, configuration: configuration)
        let runDirectory = try Self.makeRunDirectory(
            root: admission.artifactDirectory, runID: request.id)
        let requestURL = runDirectory.appendingPathComponent("request.json")
        let requestData = try Self.encodeRequest(
            requestID: request.id, pitch: admission.pitch,
            modelDirectory: admission.modelDirectory, runDirectory: runDirectory)
        try AudioFileSystem.writeExclusive(requestData, to: requestURL)
        let temporary = runDirectory.appendingPathComponent("tmp", isDirectory: true)
        let cache = runDirectory.appendingPathComponent("cache", isDirectory: true)
        let environment = [
            "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
            "PYTHONPYCACHEPREFIX": cache.appendingPathComponent("pycache").path,
            "TMPDIR": temporary.path, "XDG_CACHE_HOME": cache.path,
        ]
        var arguments = ["-B", admission.providerScript.path, "--request", requestURL.path]
        let access: AudioProviderAccess?
        if let root = configuration.accessBootstrapRoot {
            access = try AudioProviderAccess.prepare(
                root: root, runID: request.id,
                directories: [admission.modelDirectory,
                              admission.inputURL.deletingLastPathComponent(), runDirectory])
            arguments += ["--access-manifest", access!.manifest.path,
                          "--access-run-id", request.id.uuidString.lowercased(),
                          "--model-directory", admission.modelDirectory.path,
                          "--input-directory", admission.inputURL.deletingLastPathComponent().path,
                          "--run-directory", runDirectory.path]
        } else {
            access = nil
        }

        let response: PitchProviderResponse
        do {
            let process = LocalProviderProcess(
                executable: admission.pythonExecutable, arguments: arguments,
                environment: environment, currentDirectory: access?.directory ?? runDirectory,
                timeoutSeconds: configuration.timeoutSeconds,
                cancellationGraceSeconds: configuration.cancellationGraceSeconds,
                label: "Pitch provider")
            let stdout = try await process.run { reader, control in
                await PitchAnalysisProviderProtocol.readStdout(reader, control: control)
            }
            if let failure = stdout.failure {
                throw InferenceFailure.backendFailed(failure)
            }
            response = try PitchAnalysisProviderProtocol.parse(
                stdout.data, expectedRunID: request.id, expected: admission.pitch)
        } catch {
            let stoppedError = error
            do { try access?.finish() }
            catch {
                throw InferenceFailure.backendFailed(
                    "Pitch provider stopped with \(stoppedError.localizedDescription); "
                    + "post-exit access cleanup also failed: \(error.localizedDescription)")
            }
            throw stoppedError
        }
        try access?.finish()

        // Recheck admitted bytes after the child has exited. No candidate is published before
        // the process and both pipe readers have drained and the current request still matches.
        try admission.confirmUnchanged()
        try Task.checkCancellation()
        try await emit(.progress(completed: response.result.frames.count,
                                 total: response.result.frames.count))
        try Task.checkCancellation()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let artifactData = try encoder.encode(PublishedResult(response.result))
        guard artifactData.count <= PitchAnalysisResult.maximumJSONBytes else {
            throw InferenceFailure.backendFailed("Pitch artifact exceeds the 2 MiB boundary.")
        }
        let candidate = try Self.publish(artifactData, in: runDirectory)
        let artifact = ArtifactReference(url: candidate.url, mediaType: PitchAnalysisResult.mediaType)
        do {
            try Task.checkCancellation()
            try await emit(.artifact(artifact))
            try Task.checkCancellation()
        } catch {
            let consumerError = error
            do { try Self.removeFailedCandidate(candidate, in: runDirectory) }
            catch {
                throw InferenceFailure.backendFailed(
                    "Pitch consumer failed with \(consumerError.localizedDescription); "
                    + "its unpublished candidate could not be removed: \(error.localizedDescription)")
            }
            throw consumerError
        }
        return InferenceResult(artifacts: [artifact], metadata: [
            "profile": response.metadata.profile,
            "modelSHA256": response.metadata.modelSHA256,
            "provider": response.metadata.provider,
            "analysisSeconds": String(format: "%.9f", response.metadata.analysisSeconds),
        ])
    }

    public func release() async {
        guard !executing else { return }
        requiresRelease = false
    }

    static func encodeRequest(requestID: UUID, pitch: PitchAnalysisRequest,
                              modelDirectory: URL, runDirectory: URL) throws -> Data {
        let frozen = FrozenRequest(
            runID: requestID.uuidString.lowercased(), source: FrozenSource(pitch.source),
            profile: PitchAnalysisRequest.profile,
            preprocessing: PitchAnalysisRequest.preprocessing,
            modelSHA256: PitchAnalysisRequest.modelSHA256,
            inputSHA256: pitch.inputSHA256, sampleCount: pitch.sampleCount,
            inputPath: pitch.inputURL.standardizedFileURL.path,
            modelDirectory: modelDirectory.standardizedFileURL.path,
            runDirectory: runDirectory.standardizedFileURL.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(frozen)
        guard data.count <= 1_048_576 else {
            throw InferenceFailure.invalidRequest("Frozen pitch request exceeds 1 MiB.")
        }
        return data
    }

    private static func makeRunDirectory(root: URL, runID: UUID) throws -> URL {
        let rootFD = try AudioFileSystem.openDirectory(root, label: "Pitch artifact directory")
        defer { Darwin.close(rootFD) }
        let name = runID.uuidString
        guard Darwin.mkdirat(rootFD, name, 0o700) == 0 else {
            throw InferenceFailure.backendFailed(
                "Pitch run directory already exists or cannot be created: \(String(cString: strerror(errno)))")
        }
        let run = root.appendingPathComponent(name, isDirectory: true)
        let runFD = Darwin.openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard runFD >= 0 else {
            throw InferenceFailure.backendFailed("Cannot open the new pitch run directory.")
        }
        defer { Darwin.close(runFD) }
        for child in ["tmp", "cache"] {
            guard Darwin.mkdirat(runFD, child, 0o700) == 0 else {
                throw InferenceFailure.backendFailed("Cannot create owned pitch \(child) directory.")
            }
        }
        return run
    }

    private static func publish(_ data: Data, in run: URL) throws -> PublishedCandidate {
        let pending = run.appendingPathComponent("pitch.pending.json")
        try AudioFileSystem.writeExclusive(data, to: pending)
        let runFD = try AudioFileSystem.openDirectory(run, label: "Pitch run directory")
        defer { Darwin.close(runFD) }
        guard renameatx_np(runFD, "pitch.pending.json", runFD, "pitch.json",
                           UInt32(RENAME_EXCL)) == 0 else {
            throw InferenceFailure.backendFailed(
                "Cannot atomically publish pitch.json without overwrite: \(String(cString: strerror(errno)))")
        }
        guard Darwin.fsync(runFD) == 0 else {
            let code = errno
            _ = Darwin.unlinkat(runFD, "pitch.json", 0)
            throw InferenceFailure.backendFailed(
                "Cannot flush the pitch artifact directory: \(String(cString: strerror(code)))")
        }
        let artifact = run.appendingPathComponent("pitch.json")
        let (observed, identity) = try AudioFileSystem.readRegularFile(
            artifact, label: "Published pitch candidate",
            maximumBytes: UInt64(PitchAnalysisResult.maximumJSONBytes))
        guard observed == data else {
            throw InferenceFailure.backendFailed("Published pitch candidate bytes changed.")
        }
        let digest = SHA256.hash(data: observed).map { String(format: "%02x", $0) }.joined()
        return PublishedCandidate(url: artifact, identity: identity, sha256: digest)
    }

    private static func removeFailedCandidate(_ candidate: PublishedCandidate, in run: URL) throws {
        guard candidate.url == run.appendingPathComponent("pitch.json") else {
            throw InferenceFailure.backendFailed("Refused cleanup of an unknown pitch candidate.")
        }
        let runFD = try AudioFileSystem.openDirectory(run, label: "Pitch run directory")
        defer { Darwin.close(runFD) }
        let (data, identity) = try AudioFileSystem.readRegularFile(
            candidate.url, label: "Failed pitch candidate",
            maximumBytes: UInt64(PitchAnalysisResult.maximumJSONBytes))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard identity == candidate.identity, digest == candidate.sha256,
              Darwin.unlinkat(runFD, "pitch.json", 0) == 0 else {
            throw InferenceFailure.backendFailed(
                "Refused cleanup because the published pitch candidate was moved or replaced.")
        }
    }

    private struct PublishedCandidate: Sendable {
        let url: URL
        let identity: AudioFileSystem.Identity
        let sha256: String
    }

    private struct FrozenRequest: Encodable {
        let schemaVersion = 1
        let runID: String
        let source: FrozenSource
        let profile: String
        let preprocessing: String
        let modelSHA256: String
        let inputSHA256: String
        let sampleCount: Int
        let inputPath: String
        let modelDirectory: String
        let runDirectory: String
    }

    private struct FrozenSource: Encodable {
        let assetID: String
        let documentID: String
        let documentRevision: UInt64
        let contentSHA256: String
        let sampleRate: Double
        let frameCount: Int64
        let startFrame: Int64
        let endFrame: Int64

        init(_ source: PitchSourceIdentity) {
            assetID = source.assetID.uuidString.lowercased()
            documentID = source.documentID.uuidString.lowercased()
            documentRevision = source.documentRevision
            contentSHA256 = source.contentSHA256
            sampleRate = source.sampleRate
            frameCount = source.frameCount
            startFrame = source.startFrame
            endFrame = source.endFrame
        }
    }

    private struct PublishedResult: Encodable {
        let schemaVersion: Int
        let runID: UUID
        let source: FrozenSource
        let profile: String
        let preprocessing: String
        let modelSHA256: String
        let inputSHA256: String
        let sampleCount: Int
        let frames: [PublishedFrame]

        init(_ result: PitchAnalysisResult) {
            schemaVersion = result.schemaVersion
            runID = result.runID
            source = FrozenSource(result.source)
            profile = result.profile
            preprocessing = result.preprocessing
            modelSHA256 = result.modelSHA256
            inputSHA256 = result.inputSHA256
            sampleCount = result.sampleCount
            frames = result.frames.map(PublishedFrame.init)
        }
    }

    private struct PublishedFrame: Encodable {
        let pitchHz: Double?
        let confidence: Double
        let voiced: Bool

        init(_ frame: PitchFrame) {
            pitchHz = frame.pitchHz
            confidence = frame.confidence
            voiced = frame.voiced
        }

        func encode(to encoder: Encoder) throws {
            enum CodingKeys: String, CodingKey { case pitchHz, confidence, voiced }
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let pitchHz { try container.encode(pitchHz, forKey: .pitchHz) }
            else { try container.encodeNil(forKey: .pitchHz) }
            try container.encode(confidence, forKey: .confidence)
            try container.encode(voiced, forKey: .voiced)
        }
    }
}

struct PitchAdmission: Sendable {
    let pitch: PitchAnalysisRequest
    let pythonExecutable: URL
    let providerScript: URL
    let artifactDirectory: URL
    let modelDirectory: URL
    let inputURL: URL
    let pythonResolvedURL: URL
    let pythonIdentity: AudioFileSystem.Identity
    let providerIdentity: AudioFileSystem.Identity
    let helperIdentity: AudioFileSystem.Identity?
    let modelIdentity: AudioFileSystem.Identity
    let coreIdentity: AudioFileSystem.Identity
    let inputIdentity: AudioFileSystem.Identity

    static func inspect(_ request: InferenceRequest,
                        configuration: PitchBackendConfiguration) throws -> Self {
        try Task.checkCancellation()
        try request.validate()
        guard case .pitch(let pitch) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        guard request.model.revision == PitchAnalysisRequest.modelSHA256 else {
            throw InferenceFailure.invalidRequest(
                "Pitch execution requires the fixed SwiftF0 model digest revision.")
        }
        let python = try AudioFileSystem.absoluteLocal(
            configuration.pythonExecutable, label: "Pitch Python executable")
        let resolvedPython = python.resolvingSymlinksInPath().standardizedFileURL
        let pythonIdentity = try AudioFileSystem.regularFile(
            resolvedPython, label: "Resolved pitch Python executable", maximumBytes: nil)
        guard Darwin.access(python.path, X_OK) == 0 else {
            throw InferenceFailure.invalidRequest("Pitch Python executable is not executable.")
        }
        let provider = try AudioFileSystem.absoluteLocal(
            configuration.providerScript, label: "Pitch provider script")
        let providerIdentity = try AudioFileSystem.regularFile(
            provider, label: "Pitch provider script", maximumBytes: 16 * 1024 * 1024)
        let helperIdentity: AudioFileSystem.Identity?
        if configuration.accessBootstrapRoot != nil {
            helperIdentity = try AudioFileSystem.regularFile(
                provider.deletingLastPathComponent().appendingPathComponent("d_audio_access.py"),
                label: "Pitch access helper", maximumBytes: 1024 * 1024)
        } else {
            helperIdentity = nil
        }
        let artifacts = try AudioFileSystem.absoluteLocal(
            configuration.artifactDirectory, label: "Pitch artifact directory")
        try AudioFileSystem.validateDirectory(artifacts, label: "Pitch artifact directory")
        if let root = configuration.accessBootstrapRoot {
            try AudioFileSystem.validateDirectory(root, label: "Pitch access bootstrap root")
        }
        let model = try AudioFileSystem.absoluteLocal(request.model.directory, label: "Pitch model directory")
        try AudioFileSystem.validateDirectory(model, label: "Pitch model directory")
        let input = try AudioFileSystem.absoluteLocal(pitch.inputURL, label: "Prepared pitch input")
        let (inputData, inputIdentity) = try AudioFileSystem.readRegularFile(
            input, label: "Prepared pitch input", maximumBytes: 7_680_000)
        guard inputData.count == pitch.sampleCount * 4,
              sha256(inputData) == pitch.inputSHA256 else {
            throw InferenceFailure.invalidRequest("Prepared pitch input size or digest is incorrect.")
        }
        let finite = inputData.withUnsafeBytes { bytes -> Bool in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let bits = UInt32(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: offset, as: UInt32.self))
                if !Float(bitPattern: bits).isFinite { return false }
            }
            return true
        }
        guard finite else {
            throw InferenceFailure.invalidRequest("Prepared pitch input contains non-finite samples.")
        }
        let modelURL = model.appendingPathComponent("model.onnx")
        let (modelData, modelIdentity) = try AudioFileSystem.readRegularFile(
            modelURL, label: "SwiftF0 model.onnx", maximumBytes: 399_114)
        guard modelData.count == 399_114,
              sha256(modelData) == PitchAnalysisRequest.modelSHA256 else {
            throw InferenceFailure.invalidRequest("SwiftF0 model.onnx digest is incorrect.")
        }
        let coreIdentity = try AudioFileSystem.regularFile(
            model.appendingPathComponent("core.py"), label: "SwiftF0 core.py",
            maximumBytes: 1024 * 1024)
        guard !AudioFileSystem.overlaps(artifacts, model),
              !AudioFileSystem.overlaps(artifacts, input),
              !AudioFileSystem.overlaps(model, input),
              !AudioFileSystem.overlaps(artifacts, provider),
              !AudioFileSystem.overlaps(input, provider) else {
            throw InferenceFailure.invalidRequest(
                "Pitch model, prepared input, provider, and artifact paths must not overlap.")
        }
        return Self(pitch: pitch, pythonExecutable: python, providerScript: provider,
                    artifactDirectory: artifacts, modelDirectory: model, inputURL: input,
                    pythonResolvedURL: resolvedPython,
                    pythonIdentity: pythonIdentity, providerIdentity: providerIdentity,
                    helperIdentity: helperIdentity,
                    modelIdentity: modelIdentity, coreIdentity: coreIdentity,
                    inputIdentity: inputIdentity)
    }

    func confirmUnchanged() throws {
        try Task.checkCancellation()
        let resolvedPython = pythonExecutable.resolvingSymlinksInPath().standardizedFileURL
        let currentPython = try AudioFileSystem.regularFile(
            resolvedPython, label: "Resolved pitch Python executable", maximumBytes: nil)
        let currentProvider = try AudioFileSystem.regularFile(
            providerScript, label: "Pitch provider script", maximumBytes: 16 * 1024 * 1024)
        let currentHelper: AudioFileSystem.Identity?
        if helperIdentity != nil {
            currentHelper = try AudioFileSystem.regularFile(
                providerScript.deletingLastPathComponent().appendingPathComponent("d_audio_access.py"),
                label: "Pitch access helper", maximumBytes: 1024 * 1024)
        } else {
            currentHelper = nil
        }
        let currentModel = try AudioFileSystem.regularFile(
            modelDirectory.appendingPathComponent("model.onnx"), label: "SwiftF0 model.onnx",
            maximumBytes: 399_114)
        let currentCore = try AudioFileSystem.regularFile(
            modelDirectory.appendingPathComponent("core.py"), label: "SwiftF0 core.py",
            maximumBytes: 1024 * 1024)
        let currentInput = try AudioFileSystem.regularFile(
            inputURL, label: "Prepared pitch input", maximumBytes: 7_680_000)
        guard resolvedPython == pythonResolvedURL, currentPython == pythonIdentity,
              Darwin.access(pythonExecutable.path, X_OK) == 0,
              currentProvider == providerIdentity,
              currentHelper == helperIdentity, currentModel == modelIdentity,
              currentCore == coreIdentity, currentInput == inputIdentity else {
            throw InferenceFailure.invalidRequest(
                "Pitch deployment or prepared input changed after admission.")
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
