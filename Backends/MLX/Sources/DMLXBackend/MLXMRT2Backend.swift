import Darwin
import DInference
import Foundation

/// Host bridge for the fixed, separately deployed MRT2-small Python provider.
/// The provider owns MLX objects; this actor owns one serialized runtime lifecycle.
public actor MLXMRT2Backend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.audio.mrt2", version: "1", capabilities: [.audioGeneration])

    private let configuration: MRT2BackendConfiguration
    private var lease: UUID?
    private var executing = false
    private var releasing = false
    private var lastRunDirectory: URL?

    public init(configuration: MRT2BackendConfiguration) throws {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite,
              configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest(
                "MRT2 timeout and cancellation grace must be finite and positive.")
        }
        self.configuration = configuration
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        try Task.checkCancellation()
        try configuration.confirmDeployment?()
        let inventory = try MRT2ModelInventory.inspect(request, configuration: configuration)
        return ResourceEstimate(peakBytes: inventory.estimatedPeakBytes, confidence: .estimated)
    }

    public func execute(
        _ request: InferenceRequest,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async throws -> InferenceResult {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed(
                "MRT2 execution requires release of the preceding run.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()

        try configuration.confirmDeployment?()
        let inventory = try MRT2ModelInventory.inspect(request, configuration: configuration)
        guard case .audio(let audio) = request.input,
              case .mrt2FixedV1(let sequence) = audio.parameters else {
            throw InferenceFailure.invalidRequest(
                "MRT2 accepts only fixed-v1 note-conditioned audio requests.")
        }

        var acknowledged = inventory.configuration.licenseAcknowledged
        if !acknowledged, let check = configuration.modelUseAcknowledged {
            acknowledged = await check()
        }
        try Task.checkCancellation()
        guard acknowledged else {
            throw InferenceFailure.invalidRequest(
                "MRT2 model use must be explicitly acknowledged by an authorized caller.")
        }
        try inventory.confirmUnchanged()
        try Task.checkCancellation()

        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        let runDirectory: URL
        do {
            runDirectory = try Self.makeRunDirectory(
                root: inventory.configuration.artifactDirectory, requestID: request.id)
        } catch {
            // Once acquired, the process-wide lease remains held until runtime release.
            throw error
        }
        lastRunDirectory = runDirectory

        do {
            let job = runDirectory.appendingPathComponent("job", isDirectory: true)
            let temporary = runDirectory.appendingPathComponent("tmp", isDirectory: true)
            let cache = runDirectory.appendingPathComponent("cache", isDirectory: true)
            let requestURL = runDirectory.appendingPathComponent("request.json")
            let requestData = try Self.encodeRequest(request, audio: audio)
            let metadataExpectation = try MRT2MetadataExpectation(
                requestData: requestData, inventory: inventory, audio: audio)
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
            var arguments = [
                "-B", inventory.configuration.providerScript.path,
                "--request", requestURL.path,
                "--job-directory", job.path,
                "--model-directory", inventory.directory.path,
                "--manifest", inventory.configuration.modelManifest.path,
                "--vendor-directory", inventory.configuration.vendorDirectory.path,
            ]
            let access: AudioProviderAccess?
            if let root = configuration.accessBootstrapRoot {
                access = try AudioProviderAccess.prepare(
                    root: root, runID: request.id,
                    directories: [inventory.directory, runDirectory])
                arguments += [
                    "--access-manifest", access!.manifest.path,
                    "--access-run-id", request.id.uuidString.lowercased(),
                ]
            } else {
                access = nil
            }

            let terminal: AudioProviderResult
            do {
                try configuration.confirmDeployment?()
                let process = AudioProviderProcess(
                    executable: inventory.configuration.pythonExecutable,
                    arguments: arguments, environment: environment,
                    currentDirectory: access?.directory ?? runDirectory,
                    timeoutSeconds: inventory.configuration.timeoutSeconds,
                    cancellationGraceSeconds: inventory.configuration.cancellationGraceSeconds)
                terminal = try await process.run(runID: request.id, emit: emit)
            } catch {
                let stoppedError = error
                do {
                    try Self.finishStoppedProvider(
                        access: access, confirmDeployment: configuration.confirmDeployment)
                } catch {
                    throw InferenceFailure.backendFailed(
                        "MRT2 provider stopped with \(stoppedError.localizedDescription); "
                        + "post-exit verification also failed: \(error.localizedDescription)")
                }
                throw stoppedError
            }
            try Self.finishStoppedProvider(
                access: access, confirmDeployment: configuration.confirmDeployment)

            // No artifact is emitted until the child and both pipe readers have stopped and
            // every independently observed request, model, result, and WAV fact agrees.
            try inventory.confirmUnchanged()
            let output = job.appendingPathComponent("output.wav")
            let accessConfigured = access != nil
            let observedRecordURL = MRT2ReportCommit.observedURL(
                job: job, accessConfigured: accessConfigured)
            let (expectedFrames, frameOverflow) = Int64(sequence.durationFrames)
                .multipliedReportingOverflow(by: 1_920)
            guard expectedFrames > 0, !frameOverflow else {
                throw InferenceFailure.backendFailed(
                    "MRT2 expected frame count is not representable.")
            }
            let (recordData, recordIdentity) = try AudioFileSystem.readRegularFile(
                observedRecordURL,
                label: accessConfigured ? "MRT2 pending result record" : "MRT2 result record",
                maximumBytes: 2 * 1024 * 1024)
            let record = try AudioProviderProtocol.parseResultSnapshot(
                recordData, runID: request.id)
            guard record == terminal else {
                throw InferenceFailure.backendFailed(
                    "MRT2 result record differs from the provider terminal result.")
            }
            try MRT2ProviderValidation.validateMetadata(
                terminal, expected: metadataExpectation)
            let artifact = try AudioWAV.validateOutput(
                output, claim: terminal.artifact, expectedFrames: expectedFrames,
                expectedSampleRate: 48_000)
            try Task.checkCancellation()
            let recordURL: URL
            if accessConfigured {
                recordURL = try MRT2ReportCommit.promotePending(
                    in: job, expectedData: recordData, expectedIdentity: recordIdentity)
            } else {
                recordURL = observedRecordURL
            }
            try await emit(.artifact(artifact))
            return InferenceResult(
                artifacts: [artifact],
                metadata: [
                    "profile": MRT2ModelInventory.profile,
                    "modelRevision": MRT2ModelInventory.revision,
                    "conditionSHA256": metadataExpectation.conditionSHA256,
                    "precision": "graph=unknown,output=float32",
                    "recordPath": recordURL.path,
                ])
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as InferenceFailure {
            throw InferenceFailure.backendFailed(
                "\(failure.localizedDescription) MRT2 diagnostics were retained at \(runDirectory.path).")
        } catch {
            throw InferenceFailure.backendFailed(
                "MRT2 execution failed; diagnostics were retained at \(runDirectory.path): "
                + error.localizedDescription)
        }
    }

    public func release() async {
        guard !executing, !releasing, let token = lease else { return }
        releasing = true
        defer { releasing = false }
        // Valid artifacts and failed diagnostic directories remain owned by the host.
        lastRunDirectory = nil
        lease = nil
        await MLXExecutionLease.shared.relinquish(token)
    }

    static func makeRunDirectory(root: URL, requestID: UUID) throws -> URL {
        let rootDescriptor = try AudioFileSystem.openDirectory(
            root, label: "MRT2 artifact directory")
        defer { Darwin.close(rootDescriptor) }
        let name = requestID.uuidString.lowercased()
            + "-" + UUID().uuidString.lowercased()
        guard Darwin.mkdirat(rootDescriptor, name, 0o700) == 0 else {
            throw InferenceFailure.backendFailed(
                "Cannot create unique MRT2 run directory: \(String(cString: strerror(errno)))")
        }
        let run = root.appendingPathComponent(name, isDirectory: true)
        let runDescriptor = Darwin.openat(
            rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard runDescriptor >= 0 else {
            throw InferenceFailure.backendFailed(
                "Cannot open the newly created MRT2 run directory.")
        }
        defer { Darwin.close(runDescriptor) }
        for child in ["job", "tmp", "cache"] {
            guard Darwin.mkdirat(runDescriptor, child, 0o700) == 0 else {
                throw InferenceFailure.backendFailed(
                    "Cannot create owned MRT2 \(child) directory: \(String(cString: strerror(errno)))")
            }
        }
        return run
    }

    static func encodeRequest(_ request: InferenceRequest, audio: AudioRequest) throws -> Data {
        guard case .mrt2FixedV1 = audio.parameters,
              audio.operation == .generate, audio.source == nil, audio.editRegion == nil else {
            throw InferenceFailure.invalidRequest(
                "MRT2 request encoding accepts only fixed-v1 generation.")
        }
        let frozen = FrozenRequest(
            runID: request.id.uuidString.lowercased(), operation: audio.operation.rawValue,
            prompt: audio.prompt, durationSeconds: audio.durationSeconds,
            seed: audio.seed, parameters: audio.parameters)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(frozen)
        guard data.count <= 1_048_576 else {
            throw InferenceFailure.invalidRequest("Frozen MRT2 request exceeds 1 MiB.")
        }
        return data
    }

    private static func finishStoppedProvider(
        access: AudioProviderAccess?,
        confirmDeployment: (@Sendable () throws -> Void)?
    ) throws {
        var failures: [String] = []
        do { try access?.finish() }
        catch { failures.append("private access cleanup: \(error.localizedDescription)") }
        do { try confirmDeployment?() }
        catch { failures.append("deployment identity: \(error.localizedDescription)") }
        guard failures.isEmpty else {
            throw InferenceFailure.backendFailed(failures.joined(separator: "; "))
        }
    }

    private struct FrozenRequest: Encodable {
        let schemaVersion = 1
        let runID: String
        let operation: String
        let prompt: String
        let durationSeconds: Double
        let seed: UInt64
        let parameters: AudioSynthesisParameters
    }
}
