import Darwin
import DInference
import Foundation

/// AUDIO1 host bridge for the separately pinned local Python SA3 provider. The child process,
/// not this Swift adapter, imports MLX. One instance belongs to one InferenceRuntime.
public actor MLXAudioBackend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.audio.sa3", version: "1", capabilities: [.audioGeneration])

    private let configuration: AudioBackendConfiguration
    private var lease: UUID?
    private var executing = false
    private var releasing = false
    private var lastRunDirectory: URL?

    public init(configuration: AudioBackendConfiguration) throws {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite,
              configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest("Audio timeout and cancellation grace must be finite and positive.")
        }
        self.configuration = configuration
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        try Task.checkCancellation()
        let inventory = try AudioModelInventory.inspect(request, configuration: configuration)
        return ResourceEstimate(peakBytes: inventory.estimatedPeakBytes, confidence: .estimated)
    }

    public func execute(
        _ request: InferenceRequest,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async throws -> InferenceResult {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed("Audio execution requires release of the preceding run.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()

        let inventory = try AudioModelInventory.inspect(request, configuration: configuration)
        guard inventory.configuration.licenseAcknowledged else {
            throw InferenceFailure.invalidRequest(
                "Audio model license acknowledgement must be explicitly supplied by a caller that already has rights.")
        }
        guard case .audio(let audio) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        let sourceInfo: AudioWAV.SourceInfo?
        if let source = audio.source {
            sourceInfo = try AudioWAV.validateSource(source.url, reference: source)
        } else {
            sourceInfo = nil
        }
        try inventory.confirmUnchanged()
        try Task.checkCancellation()

        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        let runDirectory: URL
        do {
            runDirectory = try Self.makeRunDirectory(root: inventory.configuration.artifactDirectory,
                                                     requestID: request.id)
        } catch {
            // The lease remains owned until runtime calls release, matching every other MLX backend.
            throw error
        }
        lastRunDirectory = runDirectory

        do {
            let job = runDirectory.appendingPathComponent("job", isDirectory: true)
            let temporary = runDirectory.appendingPathComponent("tmp", isDirectory: true)
            let cache = runDirectory.appendingPathComponent("cache", isDirectory: true)
            let requestURL = runDirectory.appendingPathComponent("request.json")
            let requestData = try Self.encodeRequest(request, audio: audio)
            let metadataExpectation = try AudioMetadataExpectation(
                requestData: requestData, inventory: inventory, audio: audio, sourceInfo: sourceInfo)
            try AudioFileSystem.writeExclusive(requestData, to: requestURL)

            let environment = [
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONNOUSERSITE": "1",
                "PYTHONPYCACHEPREFIX": cache.appendingPathComponent("pycache").path,
                "TMPDIR": temporary.path,
                "XDG_CACHE_HOME": cache.path,
            ]
            let process = AudioProviderProcess(
                executable: inventory.configuration.pythonExecutable,
                arguments: [
                    "-B", inventory.configuration.providerScript.path,
                    "--request", requestURL.path,
                    "--job-directory", job.path,
                    "--model-directory", inventory.directory.path,
                    "--profile", inventory.profile.rawValue,
                    "--manifest", inventory.configuration.modelManifest.path,
                    "--vendor-directory", inventory.configuration.vendorDirectory.path,
                ],
                environment: environment,
                currentDirectory: runDirectory,
                timeoutSeconds: inventory.configuration.timeoutSeconds,
                cancellationGraceSeconds: inventory.configuration.cancellationGraceSeconds)
            let terminal = try await process.run(runID: request.id, emit: emit)

            // The process and both pipe readers have exited before any artifact becomes visible
            // through the runtime event stream.
            try inventory.confirmUnchanged()
            if let source = audio.source {
                let after = try AudioWAV.validateSource(source.url, reference: source)
                guard after.sha256 == sourceInfo?.sha256,
                      after.sampleEncoding == sourceInfo?.sampleEncoding else {
                    throw InferenceFailure.backendFailed("Audio source changed while the provider was running.")
                }
            }
            let output = job.appendingPathComponent("output.wav")
            let recordURL = job.appendingPathComponent("result.json")
            let expectedFrames = audio.source?.frameCount
                ?? Int64((audio.durationSeconds * 44_100).rounded(.toNearestOrEven))
            let recordData = try AudioFileSystem.readRegularFile(
                recordURL, label: "Audio result record", maximumBytes: 2 * 1024 * 1024).0
            let record = try AudioProviderProtocol.parseResultSnapshot(recordData, runID: request.id)
            guard record == terminal else {
                throw InferenceFailure.backendFailed("result.json differs from the provider terminal result.")
            }
            try AudioProviderProtocol.validateMetadata(terminal, expected: metadataExpectation)
            let artifact = try AudioWAV.validateOutput(output, claim: terminal.artifact,
                                                       expectedFrames: expectedFrames)
            try Task.checkCancellation()
            try await emit(.artifact(artifact))
            return InferenceResult(
                artifacts: [artifact],
                metadata: [
                    "profile": inventory.profile.rawValue,
                    "modelRevision": AudioModelInventory.revision,
                    "precision": "dit=float16,text=float16,encoder=float32,decoder=float32,master=float32",
                    "recordPath": recordURL.path,
                ])
        } catch is CancellationError {
            // Published provider files, if any, remain under this exact owned run directory.
            throw CancellationError()
        } catch let failure as InferenceFailure {
            throw InferenceFailure.backendFailed(
                "\(failure.localizedDescription) Audio diagnostics were retained at \(runDirectory.path).")
        } catch {
            throw InferenceFailure.backendFailed(
                "Audio execution failed; diagnostics were retained at \(runDirectory.path): \(error.localizedDescription)")
        }
    }

    public func release() async {
        guard !executing, !releasing, let token = lease else { return }
        releasing = true
        defer { releasing = false }
        // No scanning or deletion: valid publications and failed diagnostic directories survive.
        lastRunDirectory = nil
        lease = nil
        await MLXExecutionLease.shared.relinquish(token)
    }

    private static func makeRunDirectory(root: URL, requestID: UUID) throws -> URL {
        let rootDescriptor = try AudioFileSystem.openDirectory(root, label: "Audio artifact directory")
        defer { Darwin.close(rootDescriptor) }
        let name = requestID.uuidString.lowercased() + "-" + UUID().uuidString.lowercased()
        guard Darwin.mkdirat(rootDescriptor, name, 0o700) == 0 else {
            throw InferenceFailure.backendFailed(
                "Cannot create unique audio run directory: \(String(cString: strerror(errno)))")
        }
        let run = root.appendingPathComponent(name, isDirectory: true)
        let runDescriptor = Darwin.openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard runDescriptor >= 0 else {
            throw InferenceFailure.backendFailed("Cannot open the newly created audio run directory.")
        }
        defer { Darwin.close(runDescriptor) }
        for child in ["job", "tmp", "cache"] {
            guard Darwin.mkdirat(runDescriptor, child, 0o700) == 0 else {
                throw InferenceFailure.backendFailed(
                    "Cannot create owned audio \(child) directory: \(String(cString: strerror(errno)))")
            }
        }
        return run
    }

    private struct FrozenRequest: Encodable {
        struct Source: Encodable {
            let path: String
            let sha256: String
            let frameCount: Int64
            let sampleRate: Int
            let channels: Int
        }
        struct Region: Encodable { let startFrame: Int64; let endFrame: Int64 }

        let schemaVersion = 1
        let runID: String
        let operation: String
        let prompt: String
        let durationSeconds: Double
        let seed: UInt64
        let steps: Int
        let guidanceScale: Float
        let strength: Float
        let source: Source?
        let editRegion: Region?
    }

    private static func encodeRequest(_ request: InferenceRequest, audio: AudioRequest) throws -> Data {
        let frozenSource = audio.source.map {
            FrozenRequest.Source(path: $0.url.standardizedFileURL.path, sha256: $0.sha256,
                                 frameCount: $0.frameCount, sampleRate: $0.sampleRate, channels: $0.channels)
        }
        let frozenRegion = audio.editRegion.map {
            FrozenRequest.Region(startFrame: $0.startFrame, endFrame: $0.endFrame)
        }
        let frozen = FrozenRequest(
            runID: request.id.uuidString.lowercased(), operation: audio.operation.rawValue,
            prompt: audio.prompt, durationSeconds: audio.durationSeconds, seed: audio.seed,
            steps: audio.steps, guidanceScale: audio.guidanceScale, strength: audio.strength,
            source: frozenSource, editRegion: frozenRegion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(frozen)
        guard data.count <= 1_048_576 else {
            throw InferenceFailure.invalidRequest("Frozen AUDIO1 request exceeds 1 MiB.")
        }
        return data
    }
}
