import Darwin
import DInference
import Foundation

/// Thin local-process adapter. The runtime owns admission; this actor owns the
/// shared heavy-compute lease until the child, readers and media writer drain.
public actor MLXVideoBackend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.video.wan21", version: "1", capabilities: [.videoGeneration])
    public nonisolated let executionCapability = VideoExecutionCapability.wan21
    private let configuration: VideoBackendConfiguration
    private var lease: UUID?
    private var executing = false
    private var releasing = false

    public init(configuration: VideoBackendConfiguration) throws {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite, configuration.cancellationGraceSeconds > 0,
              configuration.memoryLimitBytes > 0, configuration.memoryLimitBytes <= Int64.max else {
            throw InferenceFailure.invalidRequest("Video resource limits must be finite, positive and representable.")
        }
        self.configuration = configuration
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        let (video, _) = try inspect(request)
        return ResourceEstimate(peakBytes: try VideoBackendConfiguration.estimate(video))
    }

    private func inspect(_ request: InferenceRequest) throws -> (VideoRequest, Data) {
        try request.validate()
        guard case .video(let video) = request.input,
              request.model.revision == VideoBackendConfiguration.revision else {
            throw InferenceFailure.invalidRequest("Video V0 requires an explicit supported video request and pinned model revision.")
        }
        try VideoBackendConfiguration.validate(video)
        for (url, label) in [(request.model.directory, "prepared video model"),
                             (configuration.tokenizerDirectory, "video tokenizer"),
                             (configuration.artifactDirectory, "video artifacts")] {
            try AudioFileSystem.validateDirectory(url, label: label)
        }
        for protected in [request.model.directory, configuration.tokenizerDirectory,
                          configuration.providerScript.deletingLastPathComponent(),
                          configuration.pythonExecutable.deletingLastPathComponent()] {
            guard !AudioFileSystem.overlaps(configuration.artifactDirectory, protected) else {
                throw InferenceFailure.invalidRequest("Video task outputs must be separate from models and runtime files.")
            }
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.pythonExecutable.path) else {
            throw InferenceFailure.invalidRequest("Video Python executable is unavailable.")
        }
        _ = try AudioFileSystem.readRegularFile(configuration.providerScript, label: "video provider", maximumBytes: 1_048_576)
        let (data, _) = try AudioFileSystem.readRegularFile(
            request.model.directory.appendingPathComponent("D-VIDEO-PREPARED.json"),
            label: "prepared video manifest", maximumBytes: 4 * 1024 * 1024)
        var parser = AudioJSONParser(data: data, maximumDepth: 24)
        let object = try parser.parse().objectAny(context: "prepared video manifest")
        guard object["complete"] == .bool(true),
              object["revision"] == .string(VideoBackendConfiguration.revision) else {
            throw InferenceFailure.invalidRequest("Video model preparation is incomplete or belongs to another revision.")
        }
        return (video, data)
    }

    public func execute(_ request: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed("Video run requires release of the previous execution.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()
        let (video, manifestData) = try inspect(request)
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        let run = try Self.makeRunDirectory(root: configuration.artifactDirectory, id: request.id)
        let output = run.appendingPathComponent("frames", isDirectory: true)
        let requestURL = run.appendingPathComponent("request.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(VideoWireRequest(id: request.id, video: video,
                                                      memoryLimitBytes: request.memoryBudgetBytes ?? configuration.memoryLimitBytes))
        guard data.count <= 1_048_576 else { throw InferenceFailure.invalidRequest("Video request exceeds 1 MiB.") }
        try AudioFileSystem.writeExclusive(data, to: requestURL)
        let cache = run.appendingPathComponent("cache"), tmp = run.appendingPathComponent("tmp")
        let process = LocalProviderProcess(executable: configuration.pythonExecutable,
            arguments: ["-B", configuration.providerScript.path, "--request", requestURL.path,
                        "--model", request.model.directory.path, "--tokenizer", configuration.tokenizerDirectory.path,
                        "--output", output.path],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                          "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
                          "PYTHONPYCACHEPREFIX": cache.path, "TMPDIR": tmp.path, "XDG_CACHE_HOME": cache.path,
                          "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"],
            currentDirectory: run, timeoutSeconds: configuration.timeoutSeconds,
            cancellationGraceSeconds: configuration.cancellationGraceSeconds, label: "Video provider")
        let terminal = try await process.run { reader, control in
            await VideoProviderProtocol.read(reader, control: control, runID: request.id, steps: video.steps, emit: emit)
        }
        if let failure = terminal.failure { throw InferenceFailure.backendFailed(failure) }
        guard let snapshot = terminal.snapshot else { throw InferenceFailure.backendFailed("Missing video result.") }
        try Task.checkCancellation()
        let (record, _) = try AudioFileSystem.readRegularFile(output.appendingPathComponent("result.json"),
            label: "video result", maximumBytes: 2 * 1024 * 1024)
        var parser = AudioJSONParser(data: record, maximumDepth: 24)
        guard try parser.parse() == snapshot else { throw InferenceFailure.backendFailed("Video terminal and saved record differ.") }
        let (_, currentManifest) = try inspect(request)
        let (currentRequest, _) = try AudioFileSystem.readRegularFile(requestURL, label: "video request", maximumBytes: 1_048_576)
        guard currentManifest == manifestData, currentRequest == data else {
            throw InferenceFailure.backendFailed("Video request or model manifest changed during execution.")
        }
        let sequence = try VideoProviderProtocol.validate(snapshot, requestData: data, manifestData: manifestData,
            video: video, rawURL: output.appendingPathComponent("frames.rgb"))
        let (frameBytes, totalBytes) = try sequence.validatedByteCounts()
        let destination = run.appendingPathComponent("output.mp4")
        let inspected = try await VideoArtifactWriter.encode(sequence, to: destination,
            limits: .init(maximumFrameBytes: UInt64(frameBytes), maximumOutputBytes: UInt64(totalBytes) + 1_048_576,
                          timeoutSeconds: configuration.timeoutSeconds))
        do {
            let inspection = try encoder.encode(inspected)
            try AudioFileSystem.writeExclusive(inspection, to: run.appendingPathComponent("media.json"))
        } catch {
            throw InferenceFailure.backendFailed("Video was preserved at \(destination.path), but its media report could not be saved: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        let artifact = ArtifactReference(url: destination, mediaType: "video/mp4")
        try await emit(.artifact(artifact))
        return InferenceResult(artifacts: [artifact], metadata: [
            "profile": VideoBackendConfiguration.profile.identifier, "modelRevision": VideoBackendConfiguration.revision,
            "recordPath": output.appendingPathComponent("result.json").path,
            "mediaRecordPath": run.appendingPathComponent("media.json").path, "sha256": inspected.sha256,
            "precision": "T5/DiT BF16 with original FP32 tensors; VAE FP32", "audio": "none",
            "memoryGuidelineBytes": String(request.memoryBudgetBytes ?? configuration.memoryLimitBytes)])
    }

    public func release() async {
        guard !executing, !releasing, let token = lease else { return }
        releasing = true
        defer { releasing = false }
        // Per-run child termination releases all model memory. Published files and
        // failed diagnostics are host-owned and never deleted by release.
        lease = nil
        await MLXExecutionLease.shared.relinquish(token)
    }

    private static func makeRunDirectory(root: URL, id: UUID) throws -> URL {
        let fd = try AudioFileSystem.openDirectory(root, label: "video task directory")
        defer { Darwin.close(fd) }
        let name = id.uuidString.lowercased() + "-" + UUID().uuidString.lowercased()
        guard mkdirat(fd, name, 0o700) == 0 else { throw InferenceFailure.backendFailed("Cannot create private video run directory.") }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw InferenceFailure.backendFailed("Cannot open private video run directory.") }
        defer { Darwin.close(child) }
        for item in ["tmp", "cache"] {
            guard mkdirat(child, item, 0o700) == 0 else { throw InferenceFailure.backendFailed("Cannot create video cache/temporary directory.") }
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }
}
