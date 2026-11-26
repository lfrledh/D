import Darwin
import CryptoKit
import DInference
import Foundation

/// Thin local-process adapter. The runtime owns admission; this actor owns the
/// shared heavy-compute lease until the child, readers and media writer drain.
public actor MLXVideoBackend: InferenceExecutionPlanning {
    public nonisolated let descriptor = BackendDescriptor(
        id: "mlx.video.wan21", version: "2", capabilities: [.videoGeneration])
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
        let (video, manifest) = try inspect(request)
        if video.adapterOptions == .wan(streamWeights: true) {
            return ResourceEstimate(peakBytes: try Self.streamingPeak(video, manifest: manifest))
        }
        return ResourceEstimate(peakBytes: try VideoBackendConfiguration.estimate(video))
    }

    private func planSeal(_ request: InferenceRequest) throws -> ModelExecutionSeal {
        let (_, data) = try inspect(request)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = manifest["tensors"] as? [[String: Any]], rows.count == 1261 else {
            throw InferenceFailure.invalidRequest("Wan preparation must contain the exact tensor inventory.")
        }
        let names = try rows.map { row -> String in
            guard let path = row["path"] as? String else { throw InferenceFailure.invalidResourceEstimate }
            return path
        }
        return try ModelExecutionSeal.capture(request.model, backend: descriptor,
            names: names + ["D-VIDEO-PREPARED.json"] + WanTokenizerResource.files.map(\.preparedPath))
    }

    public func lowMemoryPlans(for request: InferenceRequest) async throws -> [InferenceExecutionPlan] {
        let seal = try planSeal(request)
        return [.init(request: try request.lowMemoryRequest(method: .streaming), method: .streaming,
            strategyVersion: 2, modelIdentityToken: seal.token)]
    }
    public func validate(_ plan: InferenceExecutionPlan, for original: InferenceRequest) async throws {
        try plan.validateSemantics(original: original)
        guard plan.method == .streaming, plan.strategyVersion == 2,
              try planSeal(original).token == plan.modelIdentityToken else {
            throw InferenceFailure.inputIntegrityChanged("Approved Wan model files changed.")
        }
    }
    public func execute(_ plan: InferenceExecutionPlan, for original: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        try await validate(plan, for: original)
        return try await execute(plan.request, expectedPlan: plan, emit: emit)
    }

    /// Exact stored shared/block bytes plus bounded activation workspaces. VAE
    /// uses native FP32 convolution and materialized temporal caches; complete
    /// frame count still contributes to DiT, with no workload reduction.
    static func streamingPeak(_ video: VideoRequest, manifest: Data) throws -> UInt64 {
        guard let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let rows = object["tensors"] as? [[String: Any]], rows.count == 1261 else {
            throw InferenceFailure.invalidResourceEstimate
        }
        var groups: [String: [String: UInt64]] = [:]
        for row in rows {
            guard let role = row["role"] as? String, ["text", "diffusion", "vae"].contains(role),
                  let name = row["name"] as? String, let shape = row["shape"] as? [UInt64], !shape.isEmpty,
                  let dtype = row["dtype"] as? String, ["BF16", "F32"].contains(dtype) else {
                throw InferenceFailure.invalidResourceEstimate
            }
            var bytes: UInt64 = dtype == "F32" ? 4 : 2
            for dimension in shape {
                let next = bytes.multipliedReportingOverflow(by: dimension)
                guard dimension > 0, !next.overflow else { throw InferenceFailure.invalidResourceEstimate }
                bytes = next.partialValue
            }
            let group = name.hasPrefix("blocks.") ? name.split(separator: ".").prefix(2).joined(separator: ".") : "shared"
            let next = (groups[role]?[group] ?? 0).addingReportingOverflow(bytes)
            guard !next.overflow else { throw InferenceFailure.invalidResourceEstimate }
            groups[role, default: [:]][group] = next.partialValue
        }
        func sum(_ values: UInt64...) throws -> UInt64 {
            try values.reduce(0) { value, next in
                let result = value.addingReportingOverflow(next)
                guard !result.overflow else { throw InferenceFailure.invalidResourceEstimate }
                return result.partialValue
            }
        }
        func peak(_ role: String) throws -> UInt64 {
            let entries = groups[role] ?? [:]
            return try sum(entries["shared"] ?? 0, entries.filter { $0.key != "shared" }.values.max() ?? 0)
        }
        let gib: UInt64 = 1_073_741_824
        // Original T5 attention materializes 64 full 512x512 score matrices;
        // allow its FP32 softmax, residual/FFN intermediates and allocator margin.
        let text = try sum(peak("text"), gib)
        let tokens = UInt64((video.frameCount - 1) / 4 + 1) * UInt64(video.width / 16) * UInt64(video.height / 16)
        let work = tokens.multipliedReportingOverflow(by: 1536 * 4 * 32)
        guard !work.overflow else { throw InferenceFailure.invalidResourceEstimate }
        let diffusion = try sum(peak("diffusion"), work.partialValue, gib)
        return max(text, diffusion, try VideoExecutionCapability.wan21.estimatedDecoderPeakBytes(for: video))
    }

    private func inspect(_ request: InferenceRequest) throws -> (VideoRequest, Data) {
        try configuration.confirmDeployment?()
        try request.validate()
        guard case .video(let video) = request.input,
              request.model.revision == VideoBackendConfiguration.revision else {
            throw InferenceFailure.invalidRequest("Video V0 requires an explicit supported video request and pinned model revision.")
        }
        try VideoBackendConfiguration.validate(video)
        for (url, label) in [(request.model.directory, "prepared video model"),
                             (request.model.directory.appendingPathComponent("tokenizer", isDirectory: true), "video tokenizer"),
                             (configuration.artifactDirectory, "video artifacts")] {
            try AudioFileSystem.validateDirectory(url, label: label)
        }
        for protected in [request.model.directory, request.model.directory.appendingPathComponent("tokenizer", isDirectory: true),
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
        for resource in WanTokenizerResource.files {
            let (bytes, _) = try AudioFileSystem.readRegularFile(request.model.directory.appendingPathComponent(resource.preparedPath),
                label: "Wan tokenizer", maximumBytes: resource.size)
            guard bytes.count == resource.size, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == resource.sha256 else {
                throw InferenceFailure.invalidRequest("Wan tokenizer is missing or differs from the selected prepared model. Prepare this installation again.")
            }
        }
        return (video, data)
    }

    public func execute(_ request: InferenceRequest,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        try await execute(request, expectedPlan: nil, emit: emit)
    }
    private func execute(_ request: InferenceRequest, expectedPlan: InferenceExecutionPlan?,
                        emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        guard !executing, !releasing, lease == nil else {
            throw InferenceFailure.backendFailed("Video run requires release of the previous execution.")
        }
        executing = true
        defer { executing = false }
        try Task.checkCancellation()
        let (video, manifestData) = try inspect(request)
        if let expectedPlan, try planSeal(request).token != expectedPlan.modelIdentityToken {
            throw InferenceFailure.inputIntegrityChanged("Approved Wan files changed before execution.")
        }
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        lease = token
        if let expectedPlan, try planSeal(request).token != expectedPlan.modelIdentityToken {
            throw InferenceFailure.inputIntegrityChanged("Approved Wan files changed while queued.")
        }
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
        var arguments = ["-B", configuration.providerScript.path, "--request", requestURL.path,
                        "--model", request.model.directory.path, "--tokenizer", request.model.directory.appendingPathComponent("tokenizer", isDirectory: true).path,
                        "--output", output.path]
        let access: AudioProviderAccess?
        if let root = configuration.accessBootstrapRoot {
            access = try AudioProviderAccess.prepare(root: root, runID: request.id,
                directories: [request.model.directory, run])
            arguments += ["--access-manifest", access!.manifest.path,
                          "--access-run-id", request.id.uuidString.lowercased()]
        } else { access = nil }
        let terminal: VideoProviderProtocol.Result
        do {
            try configuration.confirmDeployment?()
            let process = LocalProviderProcess(executable: configuration.pythonExecutable,
                arguments: arguments,
                environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                              "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
                              "PYTHONPYCACHEPREFIX": cache.path, "TMPDIR": tmp.path, "XDG_CACHE_HOME": cache.path,
                              "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"],
                currentDirectory: access?.directory ?? run, timeoutSeconds: configuration.timeoutSeconds,
                cancellationGraceSeconds: configuration.cancellationGraceSeconds, label: "Video provider")
            terminal = try await process.run { reader, control in
                await VideoProviderProtocol.read(reader, control: control, runID: request.id, steps: video.steps, emit: emit)
            }
        } catch {
            // Child and readers have drained before access is revoked; release still
            // owns the heavy-compute lease even when private cleanup itself fails.
            do { try access?.finish() }
            catch { throw InferenceFailure.backendFailed("Video stopped but private access cleanup failed: \(error.localizedDescription)") }
            throw error
        }
        try access?.finish()
        try configuration.confirmDeployment?()
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
        if let expectedPlan, try planSeal(request).token != expectedPlan.modelIdentityToken {
            throw InferenceFailure.inputIntegrityChanged("Approved Wan files changed during execution.")
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
