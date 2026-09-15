import CryptoKit
import Darwin
import DInference
import Foundation

struct SingingBackendDependencies: Sendable {
    let inspect: @Sendable (InferenceRequest, SingingBackendConfiguration) throws -> SingingModelInventory
    let run: @Sendable (
        URL, [String], [String: String], URL, Double, Double, UUID,
        @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async throws -> SingingProviderTerminal

    static let production = Self(
        inspect: { try SingingModelInventory.inspect($0, configuration: $1) },
        run: { executable, arguments, environment, directory, timeout, grace, runID, emit in
            try await SingingProviderProtocol.run(
                executable: executable, arguments: arguments, environment: environment,
                currentDirectory: directory, timeoutSeconds: timeout,
                cancellationGraceSeconds: grace, runID: runID, emit: emit)
        })
}

public actor SingingBackend: InferenceBackend {
    public nonisolated let descriptor = BackendDescriptor(
        id: "audio.singing.qixuan", version: "1", capabilities: [.audioSingingGeneration])

    private let configuration: SingingBackendConfiguration
    private let dependencies: SingingBackendDependencies
    private var lease: UUID?
    private var executing = false
    private var releasing = false
    private var lastRunDirectory: URL?

    public init(configuration: SingingBackendConfiguration) throws {
        try Self.validateDurations(configuration)
        self.configuration = configuration
        dependencies = .production
    }

    init(configuration: SingingBackendConfiguration, dependencies: SingingBackendDependencies) throws {
        try Self.validateDurations(configuration)
        self.configuration = configuration
        self.dependencies = dependencies
    }

    public func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        try Task.checkCancellation()
        let inventory = try dependencies.inspect(request, configuration)
        return ResourceEstimate(peakBytes: inventory.estimatedPeakBytes, confidence: .estimated)
    }

    public func execute(
        _ request: InferenceRequest,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async throws -> InferenceResult {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed("Singing execution requires release of the preceding run.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()
        let inventory = try dependencies.inspect(request, configuration)
        guard case .singing(let singing) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        try inventory.confirmUnchanged(cancellable: true)
        try Task.checkCancellation()

        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        let runDirectory = try Self.makeRunDirectory(
            root: inventory.configuration.artifactDirectory, requestID: request.id)
        lastRunDirectory = runDirectory
        var requestSeal: SingingSealedFile?

        do {
            let temporary = runDirectory.appendingPathComponent("tmp", isDirectory: true)
            let cache = runDirectory.appendingPathComponent("cache", isDirectory: true)
            let output = runDirectory.appendingPathComponent("output", isDirectory: true)
            let requestURL = runDirectory.appendingPathComponent("request.json")
            let requestData = try SingingRequestWire.encode(request)
            let requestSHA = SHA256.hash(data: requestData).map { String(format: "%02x", $0) }.joined()
            try AudioFileSystem.writeExclusive(requestData, to: requestURL)
            requestSeal = try SingingSealedFile.capture(
                requestURL, label: "Frozen singing request", maximumBytes: 2 * 1024 * 1024,
                cancellable: true)
            let environment = [
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONNOUSERSITE": "1",
                "TMPDIR": temporary.path,
                "XDG_CACHE_HOME": cache.path,
                "NUMBA_CACHE_DIR": cache.appendingPathComponent("numba").path,
                "MPLCONFIGDIR": cache.appendingPathComponent("matplotlib").path,
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
                "HF_DATASETS_OFFLINE": "1",
            ]
            let arguments = [
                "-B", inventory.configuration.providerScript.path,
                "--request", requestURL.path,
                "--bank-directory", inventory.bankDirectory.path,
                "--vocoder-directory", inventory.vocoderDirectory.path,
                "--vendor-directory", inventory.configuration.vendorDirectory.path,
                "--profile", inventory.configuration.profileManifest.path,
                "--output-directory", output.path,
            ]
            let terminal = try await dependencies.run(
                inventory.configuration.pythonExecutable, arguments, environment, runDirectory,
                inventory.configuration.timeoutSeconds, inventory.configuration.cancellationGraceSeconds,
                request.id, emit)
            guard terminal.resultPath == "result.json" else {
                throw InferenceFailure.backendFailed("Singing terminal result path is invalid.")
            }
            try AudioFileSystem.validateDirectory(output, label: "Singing provider output directory")
            let resultURL = output.appendingPathComponent("result.json")
            let (resultSeal, resultData) = try SingingSealedFile.captureData(
                resultURL, label: "Singing result record", maximumBytes: 2 * 1024 * 1024,
                cancellable: true)
            let result = try SingingProviderProtocol.parseResult(resultData)
            try SingingProviderProtocol.validate(
                result, runID: request.id, request: singing, requestSHA256: requestSHA,
                inventory: inventory)
            let artifact = try SingingProviderProtocol.validateWAV(
                output.appendingPathComponent("output.wav"), record: result)
            do { try resultSeal.confirmUnchanged(cancellable: false) }
            catch {
                throw InferenceFailure.backendFailed(
                    "Singing result record changed after it was parsed: \(error.localizedDescription)")
            }

            // This check is intentionally non-cancellable: a cancellation or consumer
            // failure may not suppress verification that protected inputs stayed intact.
            try Task.checkCancellation()
            try Self.confirmPostDrain(inventory: inventory, requestSeal: requestSeal)
            do {
                try await emit(.artifact(artifact))
            } catch {
                let consumerError = error
                do { try Self.confirmPostDrain(inventory: inventory, requestSeal: requestSeal) }
                catch { throw Self.protectionFailure(error, original: consumerError) }
                throw consumerError
            }
            return InferenceResult(artifacts: [artifact], metadata: [
                "profile": SingingBackendConfiguration.profileID,
                "precision": result.execution.precision,
                "sourcePhraseID": result.source.phraseID,
                "sourcePhraseRevision": String(result.source.phraseRevision),
                "requestSHA256": result.source.requestSHA256,
                "recordPath": resultURL.path,
                "seedControl": result.execution.seedControl,
            ])
        } catch {
            let original = error
            do { try Self.confirmPostDrain(inventory: inventory, requestSeal: requestSeal) }
            catch { throw Self.protectionFailure(error, original: original) }
            if original is CancellationError { throw CancellationError() }
            if let failure = original as? InferenceFailure { throw failure }
            throw InferenceFailure.backendFailed(
                "Singing execution failed; diagnostics were retained at \(runDirectory.path): "
                    + original.localizedDescription)
        }
    }

    public func release() async {
        guard !executing, !releasing, let token = lease else { return }
        releasing = true
        defer { releasing = false }
        lastRunDirectory = nil
        lease = nil
        await MLXExecutionLease.shared.relinquish(token)
    }

    private static func validateDurations(_ value: SingingBackendConfiguration) throws {
        guard value.timeoutSeconds.isFinite, value.timeoutSeconds > 0,
              value.cancellationGraceSeconds.isFinite, value.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest("Singing timeout and cancellation grace must be finite and positive.")
        }
    }

    private static func makeRunDirectory(root: URL, requestID: UUID) throws -> URL {
        let rootFD = try AudioFileSystem.openDirectory(root, label: "Singing artifact directory")
        defer { Darwin.close(rootFD) }
        let name = requestID.uuidString.lowercased() + "-" + UUID().uuidString.lowercased()
        guard Darwin.mkdirat(rootFD, name, 0o700) == 0 else {
            throw InferenceFailure.backendFailed("Cannot create unique singing run directory: \(String(cString: strerror(errno)))")
        }
        let run = root.appendingPathComponent(name, isDirectory: true)
        let runFD = Darwin.openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard runFD >= 0 else {
            throw InferenceFailure.backendFailed("Cannot open the newly created singing run directory.")
        }
        defer { Darwin.close(runFD) }
        for child in ["tmp", "cache"] {
            guard Darwin.mkdirat(runFD, child, 0o700) == 0 else {
                throw InferenceFailure.backendFailed("Cannot create owned singing \(child) directory: \(String(cString: strerror(errno)))")
            }
        }
        return run
    }

    private static func protectionFailure(_ integrity: Error, original: Error) -> InferenceFailure {
        if let failure = integrity as? InferenceFailure,
           case .inputIntegrityChanged(let detail) = failure {
            return .inputIntegrityChanged(
                "\(detail) Original singing stop/error: \(original.localizedDescription)")
        }
        return .backendFailed(
            "Singing input protection verification could not complete: \(integrity.localizedDescription). "
                + "Original singing stop/error: \(original.localizedDescription)")
    }

    private static func confirmPostDrain(
        inventory: SingingModelInventory, requestSeal: SingingSealedFile?
    ) throws {
        var observed: InferenceFailure?
        var unknown: Error?
        do { try inventory.confirmUnchanged(cancellable: false) }
        catch let failure as InferenceFailure {
            if case .inputIntegrityChanged = failure { observed = failure }
            else { unknown = failure }
        } catch { unknown = error }
        if let requestSeal {
            do { try requestSeal.confirmUnchanged(cancellable: false) }
            catch let failure as InferenceFailure {
                if case .inputIntegrityChanged = failure { observed = observed ?? failure }
                else { unknown = unknown ?? failure }
            } catch { unknown = unknown ?? error }
        }
        if let observed { throw observed }
        if let unknown { throw unknown }
    }
}
