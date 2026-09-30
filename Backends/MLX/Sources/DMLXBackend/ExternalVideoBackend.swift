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
        do {
            let result = try await executeOwned(request, emit: emit)
            try finishAccessAfterDrain()
            return result
        } catch {
            let primary = error
            do { try finishAccessAfterDrain() }
            catch {
                let context = "\(primary.localizedDescription); access cleanup: \(error.localizedDescription)"
                if case InferenceFailure.inputIntegrityChanged = primary {
                    throw InferenceFailure.inputIntegrityChanged(context)
                }
                throw InferenceFailure.backendFailed(context)
            }
            throw primary
        }
    }

    private func finishAccessAfterDrain() throws {
        guard drained, let access = retainedAccess else { return }
        // Clear the handle before the one-shot cleanup. A partially removed
        // bootstrap is retained as evidence; it is not a running GPU process.
        retainedAccess = nil
        try access.finish()
    }

    private func executeOwned(_ request: InferenceRequest,
                              emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        try Task.checkCancellation()
        let (video, manifest) = try inspect(request)
        let manifestURL = request.model.directory.appendingPathComponent(ExternalVideoModelManifest.filename)
        let (frozenManifest, manifestIdentity) = try AudioFileSystem.readRegularFile(manifestURL, label: "video manifest snapshot", maximumBytes: 16_384)
        guard frozenManifest == manifest else { throw InferenceFailure.inputIntegrityChanged("Video pack changed during admission.") }
        let token = UUID(); try await MLXExecutionLease.shared.acquire(token); lease = token
        if request.model.directory.startAccessingSecurityScopedResource() { retainedModelScope = request.model.directory }
        let scopedFrames = [video.firstFrame, video.lastFrame].compactMap { $0?.url }
            .filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scopedFrames { url.stopAccessingSecurityScopedResource() } }
        let run = try makeRunDirectory(request.id)
        let firstFrame = try video.firstFrame.map { try Self.freezeFrame($0, role: "first", in: run) }
        let lastFrame = try video.lastFrame.map { try Self.freezeFrame($0, role: "last", in: run) }
        let input = run.appendingPathComponent("request.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let wire = try ExternalVideoWireRequest(id: request.id, profile: configuration.profile, video: video,
                                              manifestSHA256: Self.digest(manifest),
                                              firstFrame: firstFrame?.wire, lastFrame: lastFrame?.wire)
        let bytes = try encoder.encode(wire)
        guard bytes.count <= 1_048_576 else { throw InferenceFailure.invalidRequest("Video request exceeds 1 MiB.") }
        try AudioFileSystem.writeExclusive(bytes, to: input)
        let (_, inputIdentity) = try AudioFileSystem.readRegularFile(input, label: "frozen video input", maximumBytes: 1_048_576)
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
            throw error
        }
        drained = terminal.fullyDrained
        guard drained else {
            quarantinedProcess = terminal
            throw InferenceFailure.resourceCleanupUnconfirmed("Video process cleanup is unconfirmed; runtime disabled and resource lease retained. PID \(terminal.processID.map(String.init) ?? "unknown"). \(terminal.stderrTail)")
        }
        // A bounded detached read deliberately does not inherit user cancellation:
        // protection failures must remain observable on every drained terminal path.
        try await Task.detached {
            do {
                let (nowManifest, nowManifestIdentity) = try AudioFileSystem.readRegularFile(manifestURL, label: "video manifest recheck", maximumBytes: 16_384)
                let (nowInput, nowInputIdentity) = try AudioFileSystem.readRegularFile(input, label: "video input recheck", maximumBytes: 1_048_576)
                guard nowManifest == manifest, nowManifestIdentity == manifestIdentity,
                      nowInput == bytes, nowInputIdentity == inputIdentity else {
                    throw InferenceFailure.inputIntegrityChanged("Video request or model manifest changed during execution.")
                }
                try firstFrame?.recheck()
                try lastFrame?.recheck()
            } catch {
                throw InferenceFailure.inputIntegrityChanged("Video frozen input verification failed: \(error.localizedDescription)")
            }
        }.value
        try finishAccessAfterDrain()
        switch terminal.reason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw InferenceFailure.backendFailed("Video generation exceeded the explicit deadline. \(terminal.stderrTail)")
        case .cleanupUnconfirmed: throw InferenceFailure.backendFailed("Video process exited before all owned work completed. " + terminal.stderrTail)
        case .exited: break
        }
        guard terminal.exitCode == 0 else {
            throw InferenceFailure.backendFailed("Video engine failed (exit \(terminal.exitCode.map(String.init) ?? "unknown")). \(terminal.stderrTail)")
        }
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
        if firstFrame != nil || lastFrame != nil {
            let expectedFirst: AudioJSONValue? = firstFrame.map { .string($0.reference.contentSHA256) }
            let expectedLast: AudioJSONValue? = lastFrame.map { .string($0.reference.contentSHA256) }
            guard case .object(let conditions)? = result["frame_conditions"],
                  conditions["first_frame_sha256"] == expectedFirst,
                  conditions["last_frame_sha256"] == expectedLast else {
                throw InferenceFailure.backendFailed("Video result omitted frozen frame provenance.")
            }
        }
        let candidate = run.appendingPathComponent("candidate.mp4")
        guard case .string(let expectedDigest)? = result["sha256"] else {
            throw InferenceFailure.backendFailed("Video terminal result has no candidate digest.")
        }
        let output = run.appendingPathComponent("output.mp4")
        try Self.copyVerifiedCandidate(candidate, to: output, expectedDigest: expectedDigest)
        let artifact = ArtifactReference(url: output, mediaType: "video/mp4")
        try await emit(.artifact(artifact))
        var metadata = ["profile": configuration.profile.rawValue,
            "modelRevision": configuration.profile.modelRevision, "modelIdentity": configuration.profile.modelIdentity,
            "streamWeights": String(wire.request.stream_weights), "recordPath": run.appendingPathComponent("result.json").path,
            "audio": configuration.profile == .h3BF16Full ? "AAC 32000 stereo" : "AAC 48000 stereo"]
        if let firstFrame {
            metadata["firstFrameSHA256"] = firstFrame.reference.contentSHA256
            metadata["firstFrameSourceURL"] = firstFrame.reference.url.absoluteString
        }
        if let lastFrame {
            metadata["lastFrameSHA256"] = lastFrame.reference.contentSHA256
            metadata["lastFrameSourceURL"] = lastFrame.reference.url.absoluteString
        }
        return .init(artifacts: [artifact], metadata: metadata)
    }

    public func release() async {
        guard !executing, drained, let token = lease else { return }
        retainedModelScope?.stopAccessingSecurityScopedResource(); retainedModelScope = nil
        lease = nil; await MLXExecutionLease.shared.relinquish(token)
    }
    /// A new inode satisfies Store's no-hardlink rule. Read and hash the same
    /// source fd, with bounded memory, and publish only after its frozen digest
    /// matches the driver's result. Failed unpublished copies stay in this run.
    static func copyVerifiedCandidate(_ source: URL, to destination: URL, expectedDigest: String,
                                      afterCopy: (() throws -> Void)? = nil) throws {
        guard expectedDigest.utf8.count == 64,
              expectedDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw InferenceFailure.backendFailed("Invalid video digest.")
        }
        let parent = try AudioFileSystem.openDirectory(source.deletingLastPathComponent(), label: "video candidate parent")
        defer { Darwin.close(parent) }
        guard source.deletingLastPathComponent() == destination.deletingLastPathComponent() else {
            throw InferenceFailure.invalidRequest("Video publication must stay in its owned run.")
        }
        let input = Darwin.openat(parent, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw InferenceFailure.backendFailed("Cannot open video candidate.") }
        defer { Darwin.close(input) }
        var before = stat()
        guard Darwin.fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0 else {
            throw InferenceFailure.backendFailed("Video candidate is not an independent regular file.")
        }
        let output = Darwin.openat(parent, destination.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw InferenceFailure.backendFailed("Cannot create video output without overwriting.") }
        defer { Darwin.close(output) }
        var hash = SHA256(), remaining = before.st_size
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while remaining > 0 {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, min($0.count, Int(remaining))) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw InferenceFailure.backendFailed("Video candidate ended during publication.") }
            hash.update(data: Data(buffer.prefix(count)))
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw InferenceFailure.backendFailed("Cannot write complete video output.") }
                    offset += written
                }
            }
            remaining -= off_t(count)
        }
        try afterCopy?()
        var after = stat(), named = stat(), published = stat(), publishedName = stat()
        let observedDigest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard observedDigest == expectedDigest,
              Darwin.fstat(input, &after) == 0, AudioFileSystem.Identity(after) == AudioFileSystem.Identity(before),
              Darwin.fstatat(parent, source.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              AudioFileSystem.Identity(named) == AudioFileSystem.Identity(before),
              Darwin.fstat(output, &published) == 0, published.st_size == before.st_size,
              Darwin.fstatat(parent, destination.lastPathComponent, &publishedName, AT_SYMLINK_NOFOLLOW) == 0,
              AudioFileSystem.Identity(publishedName) == AudioFileSystem.Identity(published),
              published.st_nlink == 1, published.st_ino != before.st_ino else {
            throw InferenceFailure.inputIntegrityChanged("Video candidate differs from the engine's verified result.")
        }
        guard Darwin.fsync(output) == 0 else { throw InferenceFailure.backendFailed("Cannot flush video output.") }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private struct FrozenFrame: Sendable {
        let reference: VideoFrameReference
        let sourceIdentity: AudioFileSystem.Identity
        let frozenURL: URL
        let frozenIdentity: AudioFileSystem.Identity
        var wire: ExternalVideoWireRequest.FrameCondition {
            .init(file: frozenURL.lastPathComponent, width: reference.width, height: reference.height,
                  byte_count: reference.byteCount, content_sha256: reference.contentSHA256)
        }
        func recheck() throws {
            do {
                let (source, sourceNow) = try AudioFileSystem.readRegularFile(reference.url,
                    label: "video source frame", maximumBytes: 64 * 1_048_576)
                let (frozen, frozenNow) = try AudioFileSystem.readRegularFile(frozenURL,
                    label: "video frozen frame", maximumBytes: 64 * 1_048_576)
                let namedSource = try AudioFileSystem.regularFile(reference.url,
                    label: "video source frame", maximumBytes: nil)
                let namedFrozen = try AudioFileSystem.regularFile(frozenURL,
                    label: "video frozen frame", maximumBytes: nil)
                guard sourceNow == sourceIdentity, frozenNow == frozenIdentity,
                      namedSource == sourceIdentity, namedFrozen == frozenIdentity,
                      source == frozen, UInt64(source.count) == reference.byteCount,
                      ExternalVideoBackend.digest(source) == reference.contentSHA256 else {
                    throw InferenceFailure.inputIntegrityChanged("Video frame condition changed during execution.")
                }
            } catch {
                throw InferenceFailure.inputIntegrityChanged("Video frame condition verification failed: \(error.localizedDescription)")
            }
        }
    }
    private static func freezeFrame(_ reference: VideoFrameReference, role: String, in run: URL) throws -> FrozenFrame {
        try reference.validate()
        guard !AudioFileSystem.overlaps(run, reference.url) else {
            throw InferenceFailure.invalidRequest("Video frame source overlaps its private output.")
        }
        let (data, identity) = try AudioFileSystem.readRegularFile(reference.url,
            label: "video \(role) frame", maximumBytes: 64 * 1_048_576)
        let namedSource = try AudioFileSystem.regularFile(reference.url,
            label: "video \(role) frame", maximumBytes: nil)
        guard namedSource == identity,
              UInt64(data.count) == reference.byteCount, digest(data) == reference.contentSHA256 else {
            throw InferenceFailure.inputIntegrityChanged("Video \(role) frame differs from its frozen reference.")
        }
        try ImagePNG.validate(data, width: reference.width, height: reference.height)
        let frozenURL = run.appendingPathComponent("\(role)-frame.png")
        try AudioFileSystem.writeExclusive(data, to: frozenURL)
        let (saved, savedIdentity) = try AudioFileSystem.readRegularFile(frozenURL,
            label: "frozen video \(role) frame", maximumBytes: 64 * 1_048_576)
        guard saved == data, savedIdentity != identity else {
            throw InferenceFailure.inputIntegrityChanged("Frozen video frame copy is not independent.")
        }
        return .init(reference: reference, sourceIdentity: identity, frozenURL: frozenURL, frozenIdentity: savedIdentity)
    }
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
    struct FrameCondition: Encodable {
        let file: String
        let width: Int
        let height: Int
        let byte_count: UInt64
        let content_sha256: String
    }
    struct Parameters: Encodable {
        let schema_version = 1
        let profile: String, prompt: String, negative_prompt: String
        let width: Int, height: Int, frames: Int, steps: Int
        let fps: Double
        let seed: UInt64
        let stream_weights: Bool
        let cfg_scale: Float, stg_scale: Float
        let first_frame: FrameCondition?
        let last_frame: FrameCondition?
    }
    init(id: UUID, profile: ExternalVideoExecutionProfile, video: VideoRequest, manifestSHA256: String,
         firstFrame: FrameCondition? = nil, lastFrame: FrameCondition? = nil) throws {
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
            stream_weights: stream, cfg_scale: video.guidanceScale, stg_scale: stg,
            first_frame: firstFrame, last_frame: lastFrame)
    }
}
