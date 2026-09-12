import DInference
import DMLXBackend
import DRuntime
import DWorkbench
import Foundation
import UI

/// The application is the only layer that chooses a concrete compute backend.
enum AppSessionFactory {
    nonisolated static func makeSession(artifactDirectory: URL,
        bundledAudioEngine: BundledAudioEngine? = nil,
        audioConsent: AudioModelUsePermission? = nil,
        bundledMusicEngine: BundledAudioEngine? = nil,
        musicConsent: AudioModelUsePermission? = nil,
        audioAccessRoot: URL? = nil) async throws -> WorkbenchSession {
        let stages = BackendStageMonitor()
        let backend = try MLXImageBackend(configuration: .init(artifactDirectory: artifactDirectory),
                                         observer: { await stages.record($0) })
        let textBackend = try MLXTextBackend()
        let audioBackend: MLXAudioBackend?
        if let engine = bundledAudioEngine, let consent = audioConsent, let accessRoot = audioAccessRoot {
            audioBackend = try MLXAudioBackend(configuration: .init(
                pythonExecutable: engine.pythonExecutable, providerScript: engine.providerScript,
                vendorDirectory: engine.vendorDirectory, modelManifest: engine.modelManifest,
                artifactDirectory: artifactDirectory, profile: .smMusic,
                accessBootstrapRoot: accessRoot,
                confirmDeployment: { try engine.confirmUnchanged() },
                modelUseAcknowledged: { await consent.isAcknowledged }))
        } else { audioBackend = try makeAudioBackend(artifactDirectory: artifactDirectory) }
        let musicBackend: MLXMRT2Backend?
        if let engine = bundledMusicEngine, let consent = musicConsent, let accessRoot = audioAccessRoot {
            musicBackend = try MLXMRT2Backend(configuration: .init(
                pythonExecutable: engine.pythonExecutable, providerScript: engine.providerScript,
                vendorDirectory: engine.vendorDirectory, modelManifest: engine.modelManifest,
                artifactDirectory: artifactDirectory, accessBootstrapRoot: accessRoot,
                confirmDeployment: { try engine.confirmUnchanged() },
                modelUseAcknowledged: { await consent.isAcknowledged }))
        } else { musicBackend = nil }
        var backends: [any InferenceBackend] = [backend, textBackend]
        if let musicBackend { backends.append(musicBackend) }
        if let audioBackend { backends.append(audioBackend) }
        let memoryBudgetBytes = ResourceBudgetPolicy().inferenceBudgetBytes(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        let runtime = try InferenceRuntime(
            backends: backends,
            configuration: try RuntimeConfiguration(memoryBudgetBytes: memoryBudgetBytes,
                                                    maximumQueuedRuns: 8))
        let validateAudioModel: (@Sendable (URL) async throws -> ModelReference)?
        if let audioBackend {
            validateAudioModel = { directory in
                let reference = ModelReference(directory: directory,
                    revision: AudioBackendConfiguration.registeredModelRevision)
                let request = AudioRequest(operation: .generate, prompt: "Model registration",
                                           durationSeconds: 6, seed: 42, steps: 8)
                _ = try await audioBackend.estimate(InferenceRequest(model: reference, input: .audio(request)))
                if bundledAudioEngine != nil, let audioConsent {
                    guard await audioConsent.confirm() else { throw CancellationError() }
                }
                return reference
            }
        } else {
            validateAudioModel = nil
        }
        let validateMusicModel: (@Sendable (URL) async throws -> ModelReference)?
        if let musicBackend {
            validateMusicModel = { directory in
                let reference = ModelReference(directory: directory, revision: MRT2BackendConfiguration.registeredModelRevision)
                let audio = AudioRequest(prompt: "Model registration", seed: 42,
                                         noteSequence: .init(durationFrames: 100, notes: nil))
                _ = try await musicBackend.estimate(InferenceRequest(model: reference, input: .audio(audio)))
                if let musicConsent { guard await musicConsent.confirm() else { throw CancellationError() } }
                return reference
            }
        } else { validateMusicModel = nil }
        return WorkbenchSession(
            engine: runtime,
            backendID: backend.descriptor.id,
            status: {
                let snapshot = await runtime.snapshot()
                let stage = await stages.current(runID: snapshot.activeRunID)
                let state = jobState(snapshot.phase, stage: stage)
                return WorkbenchRuntimeStatus(activeRunID: snapshot.activeRunID,
                                              phase: phaseTitle(snapshot.phase, stage: stage),
                                              queuedRunIDs: snapshot.queuedRunIDs,
                                              state: state)
            },
            shutdown: { await runtime.shutdown() },
            cleanup: { try await backend.cleanupUnpublishedArtifacts() },
            validateModel: { directory in
                // Registration checks layout and configuration without loading weights.
                // Actual execution still verifies the complete fixed model SHA-256 manifest.
                let request = InferenceRequest(model: ModelReference(directory: directory), input: .image(
                    ImageModelProfile.flux2Klein.request(prompt: "Model registration", seed: 0)))
                _ = try await backend.estimate(request)
            }, textBackendID: textBackend.descriptor.id, validateTextModel: { directory in
                let reference = try await TextModelProfiles.verify(at: directory)
                _ = try await textBackend.estimate(InferenceRequest(model: reference, input: .text(TextRequest(prompt: "Registration", maxTokens: 256))))
                return reference
            }, audioBackendID: audioBackend?.descriptor.id,
            validateAudioModel: validateAudioModel, musicBackendID: musicBackend?.descriptor.id,
            validateMusicModel: validateMusicModel)
    }

    /// Only an explicitly isolated development session can supply an existing local engine.
    /// This is not a shipping installer or an implicit license acceptance path.
    nonisolated private static func makeAudioBackend(artifactDirectory: URL) throws -> MLXAudioBackend? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard AudioWorkbenchIsolation.isEnabled(environment: environment),
              let path = environment["D_AUDIO_BACKEND_CONFIGURATION"] else { return nil }
        struct HostAudioConfiguration: Decodable {
            let pythonExecutable: URL
            let providerScript: URL
            let vendorDirectory: URL
            let modelManifest: URL
            let profile: AudioBackendProfile
            let licenseAcknowledged: Bool
        }
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else {
            throw InferenceFailure.invalidRequest("Local audio engine configuration is too large.")
        }
        let host = try JSONDecoder().decode(HostAudioConfiguration.self, from: data)
        guard host.licenseAcknowledged else {
            throw InferenceFailure.invalidRequest("The configured audio model usage has not been acknowledged.")
        }
        return try MLXAudioBackend(configuration: .init(pythonExecutable: host.pythonExecutable,
            providerScript: host.providerScript, vendorDirectory: host.vendorDirectory,
            modelManifest: host.modelManifest, artifactDirectory: artifactDirectory,
            profile: host.profile, licenseAcknowledged: host.licenseAcknowledged))
        #else
        return nil
        #endif
    }

    nonisolated private static func jobState(_ phase: RuntimeSnapshot.Phase?,
                                             stage: MLXLifecycleEvent.Phase?) -> JobState? {
        switch phase {
        case .preparing: .preparing
        case .running:
            switch stage {
            case .verifying, .tokenizing, .loading, .loadingTextEncoder, .textEncoderLoaded: .preparing
            case .drained, .released: .releasing
            default: .generating
            }
        case .cancelling: .cancelling
        case .releasing: .releasing
        case nil: nil
        }
    }

    nonisolated private static func phaseTitle(_ phase: RuntimeSnapshot.Phase?,
                                               stage: MLXLifecycleEvent.Phase?) -> String? {
        switch phase {
        case .preparing: "正在准备"
        case .running:
            switch stage {
            case .verifying: "正在校验模型完整性"
            case .tokenizing: "正在处理提示词"
            case .loading, .loadingTextEncoder: "正在加载文本编码器"
            case .loaded, .textEncoderLoaded, .encoding: "正在编码提示词"
            case .encoded, .loadingTransformer: "正在加载图像模型"
            case .transformerLoaded, .denoising, .generating: "正在生成图像"
            case .loadingVAE, .vaeLoaded: "正在加载图像解码器"
            case .decoding: "正在解码图像"
            case .decoded, .publishing: "正在写入图像文件"
            case .drained, .released: "正在释放计算资源"
            case nil: "正在执行推理"
            }
        case .cancelling: "正在取消"
        case .releasing: "正在释放资源"
        case nil: nil
        }
    }
}

/// A single latest event is enough; old task stages cannot label a new active task.
private actor BackendStageMonitor {
    private var latest: MLXLifecycleEvent?

    func record(_ event: MLXLifecycleEvent) { latest = event }

    func current(runID: UUID?) -> MLXLifecycleEvent.Phase? {
        guard let runID, latest?.runID == runID else { return nil }
        return latest?.phase
    }
}
