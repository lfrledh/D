import CryptoKit
import Darwin
import DInference
import Foundation

/// Fixed local implementations share DRuntime and the process-wide compute lease.
/// Only this owner spawns/terminates the process group; the Python driver cannot
/// create another session. Released compute never deletes an emitted artifact.
public actor ExternalVideoBackend: InferenceBackend {
    public nonisolated let descriptor: BackendDescriptor
    private let configuration: ExternalVideoBackendConfiguration
    private var lease: UUID?
    private var executing = false
    private var drained = true
    private var retainedModelScope: URL?
    private var quarantinedProcess: ExternalVideoProcessResult?
    private var retainedAccess: AudioProviderAccess?

    public init(configuration: ExternalVideoBackendConfiguration) throws {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite, configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest("External video deadlines must be positive and finite.")
        }
        self.configuration = configuration
        descriptor = .init(id: configuration.profile.backendID, version: "1", capabilities: [.videoGeneration])
    }

    public func validateModel(at directory: URL) throws -> ModelReference {
        _ = try configuration.inspectPack(at: directory)
        return ModelReference(directory: directory, revision: configuration.profile.modelIdentity)
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        let (video, _) = try inspect(request)
        let stream: Bool
        switch video.adapterOptions {
        case .h3(let value)?: stream = value
        case .ltx(let value, _)?: stream = value
        case nil: throw InferenceFailure.invalidRequest("Missing video loading strategy.")
        }
        // Stage-based planning estimates, not a physical-RAM prohibition. Users
        // can explicitly raise the runtime budget; actual peaks are run evidence.
        let baseGiB: UInt64
        if stream { baseGiB = configuration.profile == .h3BF16Full ? 10 : 8 }
        else { baseGiB = configuration.profile == .h3BF16Full ? 72 : (configuration.profile == .ltx23Q8GemmaQ4 ? 28 : 52) }
        let units = UInt64(video.width) * UInt64(video.height) * UInt64(video.frameCount)
        let (workspace, overflow) = units.multipliedReportingOverflow(by: 96)
        let (total, overflow2) = (baseGiB * 1_073_741_824).addingReportingOverflow(workspace)
        guard !overflow, !overflow2 else { throw InferenceFailure.invalidRequest("Video estimate overflows.") }
        return ResourceEstimate(peakBytes: total, confidence: .estimated)
    }

    private func inspect(_ request: InferenceRequest) throws -> (VideoRequest, Data) {
        try request.validate()
        guard case .video(let video) = request.input,
              request.model.revision == configuration.profile.modelIdentity else {
            throw InferenceFailure.invalidRequest("External video request/model identity mismatch.")
        }
        try configuration.profile.validate(video)
        let manifest = try configuration.inspectPack(at: request.model.directory)
        try AudioFileSystem.validateDirectory(configuration.artifactDirectory, label: "external video outputs")
        for file in [configuration.pythonExecutable, configuration.ffmpeg, configuration.ffprobe] + [configuration.h3Executable].compactMap({ $0 }) {
            guard FileManager.default.isExecutableFile(atPath: file.path) else {
                throw InferenceFailure.invalidRequest("Prepared video executable is unavailable: \(file.lastPathComponent)")
            }
        }
        _ = try AudioFileSystem.readRegularFile(configuration.providerScript, label: "external video provider", maximumBytes: 1_048_576)
        if configuration.profile == .h3BF16Full, configuration.h3Executable == nil || configuration.h3Shader == nil {
            throw InferenceFailure.invalidRequest("H3 engine deployment is incomplete.")
        }
        return (video, manifest)
    }

    public func execute(_ request: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard !executing, lease == nil, drained else { throw InferenceFailure.backendFailed("Previous video execution has not been released.") }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()
        let (video, manifest) = try inspect(request)
        let token = UUID(); try await MLXExecutionLease.shared.acquire(token); lease = token
        if request.model.directory.startAccessingSecurityScopedResource() { retainedModelScope = request.model.directory }
        let run = try makeRunDirectory(request.id)
        let input = run.appendingPathComponent("request.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let wire = try ExternalVideoWireRequest(id: request.id, profile: configuration.profile, video: video,
                                              manifestSHA256: Self.digest(manifest))
        let bytes = try encoder.encode(wire)
        guard bytes.count <= 1_048_576 else { throw InferenceFailure.invalidRequest("Video request exceeds 1 MiB.") }
        try AudioFileSystem.writeExclusive(bytes, to: input)
        var arguments = ["-B", configuration.providerScript.path, "--request", input.path,
                         "--pack", request.model.directory.path, "--ffmpeg", configuration.ffmpeg.path,
                         "--ffprobe", configuration.ffprobe.path]
        if let h3 = configuration.h3Executable, let shader = configuration.h3Shader {
            arguments += ["--h3-engine", h3.path, "--h3-shader", shader.path]
        }
        if let root = configuration.accessBootstrapRoot {
            retainedAccess = try AudioProviderAccess.prepare(root: root, runID: request.id, directories: [request.model.directory, run])
            arguments += ["--access-manifest", retainedAccess!.manifest.path, "--access-run-id", request.id.uuidString.lowercased()]
        }
        let environment = ["PATH": configuration.ffmpeg.deletingLastPathComponent().path + ":/usr/bin:/bin",
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HOME": run.appendingPathComponent("cache/hf").path,
            "XDG_CACHE_HOME": run.appendingPathComponent("cache").path, "TMPDIR": run.appendingPathComponent("tmp").path,
            "LTX2_GEMMA_MAX_LENGTH": "1024"]
        let terminal: ExternalVideoProcessResult
        do {
            terminal = try await ExternalVideoProcess(executable: configuration.pythonExecutable, arguments: arguments,
                environment: environment, currentDirectory: retainedAccess?.directory ?? run,
                timeoutSeconds: configuration.timeoutSeconds, cancellationGraceSeconds: configuration.cancellationGraceSeconds).run()
        } catch {
            // Transport throws only before a live process exists.
            try retainedAccess?.finish(); retainedAccess = nil
            throw error
        }
        drained = terminal.fullyDrained
        guard drained else {
            quarantinedProcess = terminal
            throw InferenceFailure.resourceCleanupUnconfirmed("Video process cleanup is unconfirmed; runtime disabled and resource lease retained. PID \(terminal.processID.map(String.init) ?? "unknown"). \(terminal.stderrTail)")
        }
        try retainedAccess?.finish(); retainedAccess = nil
        switch terminal.reason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw InferenceFailure.backendFailed("Video generation exceeded the explicit deadline. \(terminal.stderrTail)")
        case .cleanupUnconfirmed: throw InferenceFailure.resourceCleanupUnconfirmed("Inconsistent process cleanup result.")
        case .exited: break
        }
        guard terminal.exitCode == 0 else { throw InferenceFailure.backendFailed("Video engine failed. \(terminal.stderrTail)") }
        try Task.checkCancellation()
        let (resultData, _) = try AudioFileSystem.readRegularFile(run.appendingPathComponent("result.json"), label: "video terminal result", maximumBytes: 2_097_152)
        var parser = AudioJSONParser(data: resultData, maximumDepth: 24)
        let result = try parser.parse().objectAny(context: "video result")
        guard result["schema"] == .string("d.external-video.app-result.v1"),
              result["run_id"] == .string(request.id.uuidString.lowercased()),
              result["request_sha256"] == .string(Self.digest(bytes)),
              result["manifest_sha256"] == .string(Self.digest(manifest)),
              result["profile"] == .string(configuration.profile.rawValue),
              result["media_verified"] == .bool(true), result["published"] == .bool(false),
              result["candidate_file"] == .string("candidate.mp4") else {
            throw InferenceFailure.backendFailed("Video terminal result does not match the frozen request.")
        }
        let (_, currentManifest) = try inspect(request)
        let (currentRequest, _) = try AudioFileSystem.readRegularFile(input, label: "video input recheck", maximumBytes: 1_048_576)
        guard manifest == currentManifest, bytes == currentRequest else {
            throw InferenceFailure.inputIntegrityChanged("Video request or model manifest changed during execution.")
        }
        let artifact = ArtifactReference(url: run.appendingPathComponent("candidate.mp4"), mediaType: "video/mp4")
        try await emit(.artifact(artifact))
        return .init(artifacts: [artifact], metadata: ["profile": configuration.profile.rawValue,
            "modelRevision": configuration.profile.modelRevision, "modelIdentity": configuration.profile.modelIdentity,
            "streamWeights": String(wire.request.stream_weights), "recordPath": run.appendingPathComponent("result.json").path,
            "audio": configuration.profile == .h3BF16Full ? "AAC 32000 stereo" : "AAC 48000 stereo"])
    }

    public func release() async {
        guard !executing, drained, let token = lease else { return }
        retainedModelScope?.stopAccessingSecurityScopedResource(); retainedModelScope = nil
        lease = nil; await MLXExecutionLease.shared.relinquish(token)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func makeRunDirectory(_ id: UUID) throws -> URL {
        let root = try AudioFileSystem.openDirectory(configuration.artifactDirectory, label: "video artifact root")
        defer { Darwin.close(root) }
        let name = id.uuidString.lowercased() + "-" + UUID().uuidString.lowercased()
        guard mkdirat(root, name, 0o700) == 0 else { throw InferenceFailure.backendFailed("Cannot create private video output directory.") }
        let child = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw InferenceFailure.backendFailed("Cannot open private video output directory.") }
        defer { Darwin.close(child) }
        for item in ["cache", "tmp"] { guard mkdirat(child, item, 0o700) == 0 else { throw InferenceFailure.backendFailed("Cannot create video scratch directory.") } }
        return configuration.artifactDirectory.appendingPathComponent(name, isDirectory: true)
    }
}

struct ExternalVideoWireRequest: Encodable {
    let schema_version = 1
    let run_id: String
    let manifest_sha256: String
    let request: Parameters
    struct Parameters: Encodable {
        let schema_version = 1
        let profile: String, prompt: String, negative_prompt: String
        let width: Int, height: Int, frames: Int, steps: Int
        let fps: Double
        let seed: UInt64
        let stream_weights: Bool
        let cfg_scale: Float, stg_scale: Float
    }
    init(id: UUID, profile: ExternalVideoExecutionProfile, video: VideoRequest, manifestSHA256: String) throws {
        try profile.validate(video)
        run_id = id.uuidString.lowercased(); manifest_sha256 = manifestSHA256
        let stream: Bool, stg: Float
        switch video.adapterOptions {
        case .h3(let value)?: stream = value; stg = 0
        case .ltx(let value, let guidance)?: stream = value; stg = guidance
        case nil: throw InferenceFailure.invalidRequest("Missing video adapter options.")
        }
        request = .init(profile: profile.rawValue, prompt: video.prompt, negative_prompt: video.negativePrompt,
            width: video.width, height: video.height, frames: video.frameCount, steps: video.steps,
            fps: Double(video.frameRate.numerator) / Double(video.frameRate.denominator), seed: video.seed,
            stream_weights: stream, cfg_scale: video.guidanceScale, stg_scale: stg)
    }
}
