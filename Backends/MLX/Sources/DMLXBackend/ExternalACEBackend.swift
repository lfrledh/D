import Darwin
import DInference
import Foundation

/// One ACE request per process. The existing process bridge drains stdout, stderr and
/// the child process before control returns; the MLX process lease remains held to release().
public actor ExternalACEBackend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.audio.ace15xl", version: "1", capabilities: [.audioGeneration])
    public nonisolated let executionCapability = AudioExecutionCapability(
        profile: .init(identifier: ACERequest.fixedProfile),
        contract: .init(operationID: "audio.ace15.xl-sft",
                        inputRoles: [.prompt, .referenceAudio, .audio], outputRole: .audio,
                        controlFidelity: .approximate),
        maximumDurationSeconds: 600, sampleRate: 48_000, channelCount: 2,
        operations: [.generate, .variation, .inpaint], noteControlFidelity: .unsupported,
        maximumSeed: UInt64(UInt32.max))

    private let configuration: ACEBackendConfiguration
    private var lease: UUID?
    private var executing = false
    private var releasing = false

    public init(configuration: ACEBackendConfiguration) throws {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite,
              configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest("ACE timeout and cancellation grace must be positive.")
        }
        self.configuration = configuration
    }

    public func validateModel(at model: URL) async throws -> ModelReference {
        let reference = ModelReference(directory: model, revision: ACEModelInventory.modelRevision)
        let sample = AudioRequest(operation: .generate, prompt: "inventory check",
                                  durationSeconds: 5.2, seed: 0, ace: ACERequest())
        _ = try ACEModelInventory.inspect(InferenceRequest(model: reference, input: .audio(sample)),
                                          configuration: configuration)
        return reference
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        try Task.checkCancellation()
        try configuration.confirmDeployment?()
        let inventory = try ACEModelInventory.inspect(request, configuration: configuration)
        guard case .audio(let audio) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        try executionCapability.validateDuration(audio.durationSeconds)
        return ResourceEstimate(peakBytes: inventory.estimatedPeakBytes, confidence: .estimated)
    }

    public func execute(_ request: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed("ACE requires release of the preceding run.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()
        try configuration.confirmDeployment?()
        let inventory = try ACEModelInventory.inspect(request, configuration: configuration)
        guard case .audio(let audio) = request.input, let ace = audio.ace else {
            throw InferenceFailure.invalidRequest("ACE typed request is absent.")
        }
        try executionCapability.validateDuration(audio.durationSeconds)
        try inventory.confirmUnchanged()
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        let run = try Self.makeRunDirectory(root: configuration.artifactDirectory, requestID: request.id)
        let job = run.appendingPathComponent("job", isDirectory: true)
        let jobIdentity = try MRT2ReportCommit.captureJobIdentity(job)
        let source = audio.source
        let reference = ace.referenceAudio
        var originals: [AudioSourceReference] = []
        do {
            let frozenSource = try Self.freeze(source, role: "source", into: run)
            if let source { originals.append(source) }
            let frozenReference = try Self.freeze(reference, role: "reference", into: run)
            if let reference { originals.append(reference) }
            let frozenACE = ACERequest(executionProfile: ace.executionProfile, vocal: ace.vocal,
                bpm: ace.bpm, keyScale: ace.keyScale, timeSignature: ace.timeSignature,
                steps: ace.steps, guidanceScale: ace.guidanceScale,
                referenceAudio: frozenReference, editOptions: ace.editOptions)
            let frozen = FrozenRequest(runID: request.id.uuidString.lowercased(),
                operation: audio.operation, prompt: audio.prompt,
                durationSeconds: audio.durationSeconds, seed: audio.seed,
                parameters: .aceStep15(frozenACE), source: frozenSource,
                editRegion: audio.editRegion,
                requestedSource: source?.url.absoluteString,
                requestedReference: reference?.url.absoluteString)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let requestData = try encoder.encode(frozen)
            guard requestData.count <= 3 * 1024 * 1024 else {
                throw InferenceFailure.invalidRequest("ACE frozen request exceeds 3 MiB.")
            }
            let expectation = try ACEMetadataExpectation(requestData: requestData, audio: audio)
            let requestURL = run.appendingPathComponent("request.json")
            try AudioFileSystem.writeExclusive(requestData, to: requestURL)
            let cache = run.appendingPathComponent("cache", isDirectory: true)
            let temporary = run.appendingPathComponent("tmp", isDirectory: true)
            let environment = [
                "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
                "PYTHONPYCACHEPREFIX": cache.appendingPathComponent("pycache").path,
                "TMPDIR": temporary.path, "XDG_CACHE_HOME": cache.path,
                "HF_HOME": cache.appendingPathComponent("hf").path,
                "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                "HF_DATASETS_OFFLINE": "1", "TOKENIZERS_PARALLELISM": "false",
            ]
            var arguments = ["-B", configuration.providerScript.path,
                             "--request", requestURL.path,
                             "--job-directory", job.path,
                             "--model-directory", inventory.root.path,
                             "--manifest", configuration.modelManifest.path,
                             "--vendor-directory", configuration.vendorDirectory.path]
            let access: AudioProviderAccess?
            if let bootstrap = configuration.accessBootstrapRoot {
                access = try AudioProviderAccess.prepare(root: bootstrap, runID: request.id,
                    directories: [inventory.root, configuration.vendorDirectory, run])
                arguments += ["--access-manifest", access!.manifest.path,
                              "--access-run-id", request.id.uuidString.lowercased()]
            } else { access = nil }
            let terminal: AudioProviderResult
            do {
                try configuration.confirmDeployment?()
                let process = AudioProviderProcess(executable: configuration.pythonExecutable,
                    arguments: arguments, environment: environment,
                    currentDirectory: access?.directory ?? run,
                    timeoutSeconds: configuration.timeoutSeconds,
                    cancellationGraceSeconds: configuration.cancellationGraceSeconds)
                terminal = try await process.run(runID: request.id, emit: emit)
            } catch {
                let stoppedError = error
                try Self.finishStopped(access: access, confirmation: configuration.confirmDeployment)
                throw stoppedError
            }
            try Self.finishStopped(access: access, confirmation: configuration.confirmDeployment)
            try Self.verify(originals)
            try inventory.confirmUnchanged()
            let recordURL = MRT2ReportCommit.observedURL(job: job, accessConfigured: access != nil)
            let (recordData, recordIdentity) = try AudioFileSystem.readRegularFile(
                recordURL, label: "ACE pending result", maximumBytes: 2 * 1024 * 1024)
            let record = try AudioProviderProtocol.parseResultSnapshot(recordData, runID: request.id)
            guard record == terminal else {
                throw InferenceFailure.backendFailed("ACE terminal differs from pending result record.")
            }
            try ACEProviderValidation.validate(terminal, expected: expectation, inventory: inventory)
            let requestedFrames = expectation.requestedFrames
            let maximum = max(requestedFrames, 245_760) + 96_000
            guard terminal.artifact.frameCount > 0, terminal.artifact.frameCount <= maximum else {
                throw InferenceFailure.backendFailed("ACE output length exceeds the bounded official decode envelope.")
            }
            let output = job.appendingPathComponent("output.wav")
            let artifact = try AudioWAV.validateOutput(output, claim: terminal.artifact,
                expectedFrames: terminal.artifact.frameCount, expectedSampleRate: 48_000)
            try Task.checkCancellation()
            let publishedRecord: URL
            if access != nil {
                publishedRecord = try MRT2ReportCommit.promotePending(in: job,
                    expectedJobIdentity: jobIdentity, expectedData: recordData,
                    expectedIdentity: recordIdentity)
            } else { publishedRecord = recordURL }
            try await emit(.artifact(artifact))
            return InferenceResult(artifacts: [artifact], metadata: [
                "profile": ACEModelInventory.profile,
                "modelRevision": ACEModelInventory.modelRevision,
                "precision": "XL=float32,MLX=float32,output=float32",
                "requestedFrames": String(requestedFrames),
                "effectiveFrames": String(try Self.effectiveFrames(terminal)),
                "deliveredFrames": String(terminal.artifact.frameCount),
                "requestedSource": source?.url.path ?? "",
                "sourceSHA256": source?.sha256 ?? "",
                "referenceSHA256": reference?.sha256 ?? "",
                "recordPath": publishedRecord.path,
            ])
        } catch {
            let stoppedError = error
            do { try Self.verify(originals) }
            catch { throw InferenceFailure.backendFailed("ACE input mutation detected after provider stop: \(error.localizedDescription)") }
            if stoppedError is CancellationError { throw CancellationError() }
            throw InferenceFailure.backendFailed("ACE execution failed; diagnostics retained at \(run.path): \(stoppedError.localizedDescription)")
        }
    }

    public func release() async {
        guard !executing, !releasing, let token = lease else { return }
        releasing = true
        defer { releasing = false }
        lease = nil
        await MLXExecutionLease.shared.relinquish(token)
    }

    private static func verify(_ references: [AudioSourceReference]) throws {
        for reference in references { _ = try ACEInputValidation.check(reference) }
    }

    private static func freeze(_ reference: AudioSourceReference?, role: String,
                               into run: URL) throws -> AudioSourceReference? {
        guard let reference else { return nil }
        let bytes = try ACEInputValidation.check(reference)
        let copy = run.appendingPathComponent("\(role).wav")
        try AudioFileSystem.writeExclusive(bytes, to: copy)
        let frozen = AudioSourceReference(url: copy, sha256: reference.sha256,
            frameCount: reference.frameCount, sampleRate: reference.sampleRate,
            channels: reference.channels)
        _ = try ACEInputValidation.check(frozen)
        return frozen
    }

    private static func makeRunDirectory(root: URL, requestID: UUID) throws -> URL {
        let rootFD = try AudioFileSystem.openDirectory(root, label: "ACE artifact directory")
        defer { Darwin.close(rootFD) }
        let name = requestID.uuidString.lowercased() + "-" + UUID().uuidString.lowercased()
        guard Darwin.mkdirat(rootFD, name, 0o700) == 0 else {
            throw InferenceFailure.backendFailed("Cannot create private ACE run directory.")
        }
        let run = root.appendingPathComponent(name, isDirectory: true)
        let fd = try AudioFileSystem.openDirectory(run, label: "ACE run directory")
        defer { Darwin.close(fd) }
        for child in ["job", "tmp", "cache"] {
            guard Darwin.mkdirat(fd, child, 0o700) == 0 else {
                throw InferenceFailure.backendFailed("Cannot create ACE \(child) directory.")
            }
        }
        return run
    }

    private static func finishStopped(access: AudioProviderAccess?,
                                      confirmation: (@Sendable () throws -> Void)?) throws {
        var failures: [String] = []
        do { try access?.finish() } catch { failures.append(error.localizedDescription) }
        do { try confirmation?() } catch { failures.append(error.localizedDescription) }
        guard failures.isEmpty else {
            throw InferenceFailure.backendFailed("ACE stopped provider check failed: " + failures.joined(separator: "; "))
        }
    }

    private static func effectiveFrames(_ result: AudioProviderResult) throws -> Int64 {
        let terminal = try result.snapshot.objectAny(context: "ACE terminal")
        let metadata = try terminal["metadata"]!.objectAny(context: "ACE metadata")
        return try metadata["effectiveFrames"]!.requiredInteger(context: "ACE effective frames")
    }

    private struct FrozenRequest: Encodable {
        let schemaVersion = 1
        let runID: String
        let operation: AudioOperation
        let prompt: String
        let durationSeconds: Double
        let seed: UInt64
        let parameters: AudioSynthesisParameters
        let source: AudioSourceReference?
        let editRegion: AudioEditRegion?
        let requestedSource: String?
        let requestedReference: String?
    }
}
