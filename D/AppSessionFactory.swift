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
        audioAccessRoot: URL? = nil,
        bundledVideoEngine: BundledAudioEngine? = nil, videoAccessRoot: URL? = nil,
        bundledPitchEngine: BundledAudioEngine? = nil,
        bundledExternalVideoEngine: BundledAudioEngine? = nil, bundledACEEngine: BundledAudioEngine? = nil) async throws -> WorkbenchSession {
        let stages = BackendStageMonitor()
        let backend = try MLXImageBackend(configuration: .init(artifactDirectory: artifactDirectory, profile: .scalableKlein4B),
                                         observer: { await stages.record($0) })
        let textBackend = try MLXTextBackend(configuration: .init(maximumPromptTokens: 32768, maximumOutputTokens: 8192), observer: { await stages.record($0) })
        let vlmBackend = try MLXQwenVLMBackend(configuration: .init(artifactDirectory: artifactDirectory,
            maximumPromptTokens: 262144, maximumOutputTokens: 262144), observer: { await stages.record($0) })
        let devBackend = try MLXFluxDevBackend(configuration: .init(artifactDirectory: artifactDirectory, profile: .flux2Dev))
        var modelAdapters: [WorkflowModelAdapter] = []
        for profile in try TextModelProfiles.registeredVLM() {
            let operation = profile.repository.contains("Qwen3.8-27B") ? WorkflowModelRoutes.qwen38 : WorkflowModelRoutes.qwen35
            modelAdapters.append(.init(kind: .text, modelRevision: profile.revision, operationID: operation,
                title: profile.displayTitle, backendID: vlmBackend.descriptor.id, textCapability: vlmBackend.executionCapability,
                validateModel: { directory in
                    let reference = try await TextModelProfiles.verifyVLM(at: directory, profileID: profile.id)
                    _ = try MLXQwenVLMBackend.validateModel(at: directory, revision: reference.revision)
                    return reference
                }))
        }
        modelAdapters.append(.init(kind: .image, modelRevision: "e7b7dc27f91deacad38e78976d1f2b499d76a294",
            operationID: "d.image.generate", title: "FLUX.2-klein-4B · BF16", backendID: backend.descriptor.id,
            imageRecipe: .klein(capability: backend.executionCapability),
            validateModel: { try await backend.validateModel(at: $0, revision: "e7b7dc27f91deacad38e78976d1f2b499d76a294") }))
        modelAdapters.append(.init(kind: .image, modelRevision: "26afe3a78bb242c0a8bb181dcc8937bb16e5c66c",
            operationID: WorkflowModelRoutes.fluxDev, title: "FLUX.2-dev · BF16", backendID: devBackend.descriptor.id,
            imageRecipe: .fluxDev(capability: devBackend.executionCapability),
            validateModel: { try await devBackend.validateModel(at: $0) }))

        let aceBackend: ExternalACEBackend?
        if let engine = bundledACEEngine, let accessRoot = audioAccessRoot {
            let implementation = try ExternalACEBackend(configuration: .init(
                pythonExecutable: engine.pythonExecutable, providerScript: engine.providerScript,
                vendorDirectory: engine.vendorDirectory, modelManifest: engine.modelManifest,
                artifactDirectory: artifactDirectory, accessBootstrapRoot: accessRoot,
                confirmDeployment: { try engine.confirmUnchanged() }))
            aceBackend = implementation
            modelAdapters.append(.init(kind: .music, modelRevision: "d06de46b4622f781cf07f4a013a67d591ca52819",
                operationID: WorkflowModelRoutes.ace, title: "ACE-Step 1.5 XL SFT · MLX F32 / no-LM",
                backendID: implementation.descriptor.id, validateModel: { try await implementation.validateModel(at: $0) }))
        } else { aceBackend = nil }
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
        let memoryBudgetBytes = ResourceBudgetPolicy().inferenceBudgetBytes(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        let videoBackend: MLXVideoBackend?
        if let engine = bundledVideoEngine, let tokenizer = engine.videoTokenizerDirectory,
           let accessRoot = videoAccessRoot {
            videoBackend = try MLXVideoBackend(configuration: .init(
                pythonExecutable: engine.pythonExecutable, providerScript: engine.providerScript,
                tokenizerDirectory: tokenizer, artifactDirectory: artifactDirectory,
                memoryLimitBytes: memoryBudgetBytes, accessBootstrapRoot: accessRoot,
                confirmDeployment: { try engine.confirmUnchanged() }))
        } else { videoBackend = nil }
        var externalVideoBackends: [ExternalVideoBackend] = []
        var videoAdapters: [WorkflowVideoAdapter] = []
        if let engine = bundledExternalVideoEngine, let accessRoot = videoAccessRoot,
           let ffmpeg = engine.externalVideoTool("ffmpeg"), let ffprobe = engine.externalVideoTool("ffprobe") {
            for profile in ExternalVideoExecutionProfile.allCases {
                let implementation = try ExternalVideoBackend(configuration: .init(profile: profile,
                    pythonExecutable: engine.pythonExecutable, providerScript: engine.providerScript,
                    ffmpeg: ffmpeg, ffprobe: ffprobe,
                    h3Executable: profile == .h3BF16Full ? engine.externalVideoTool("h3") : nil,
                    h3Shader: profile == .h3BF16Full ? engine.externalVideoTool("h3_shaders.metal") : nil, artifactDirectory: artifactDirectory,
                    accessBootstrapRoot: accessRoot, timeoutSeconds: 43_200,
                    confirmDeployment: { try engine.confirmUnchanged() }))
                externalVideoBackends.append(implementation)
                videoAdapters.append(.init(profile: profile, validateModel: { try await implementation.validateModel(at: $0) }))
            }
        }
        let pitchBackend: PitchAnalysisBackend?
        let pitchReference: ModelReference?
        if let engine = bundledPitchEngine {
            try engine.confirmUnchanged()
            pitchBackend = try PitchAnalysisBackend(configuration: .init(pythonExecutable: engine.pythonExecutable,
                providerScript: engine.providerScript, artifactDirectory: artifactDirectory,
                accessBootstrapRoot: audioAccessRoot))
            pitchReference = ModelReference(directory: engine.vendorDirectory, revision: PitchAnalysisRequest.modelSHA256)
        } else { pitchBackend = nil; pitchReference = nil }
        var backends: [any InferenceBackend] = [backend, textBackend, vlmBackend, devBackend]
        if let pitchBackend { backends.append(pitchBackend) }
        if let videoBackend { backends.append(videoBackend) }
        backends.append(contentsOf: externalVideoBackends)
        if let musicBackend { backends.append(musicBackend) }
        if let aceBackend { backends.append(aceBackend) }
        if let audioBackend { backends.append(audioBackend) }
        let runtime = try InferenceRuntime(
            backends: backends,
            configuration: try RuntimeConfiguration(memoryBudgetBytes: memoryBudgetBytes,
                                                    maximumQueuedRuns: 8, allowsRequestBudgetIncrease: true))
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
        let validateVideoModel: (@Sendable (URL) async throws -> ModelReference)?
        if let videoBackend {
            validateVideoModel = { directory in
                let reference = ModelReference(directory: directory, revision: VideoBackendConfiguration.revision)
                let video = try VideoCreationDraft(prompt: "Model registration").makeRequest()
                _ = try await videoBackend.estimate(InferenceRequest(model: reference, input: .video(video)))
                return reference
            }
        } else { validateVideoModel = nil }
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
            cleanup: {
                try await backend.cleanupUnpublishedArtifacts()
                try await devBackend.cleanupUnpublishedArtifacts()
            },
            validateModel: { directory in
                // Registration checks layout and configuration without loading weights.
                // Actual execution still verifies the complete fixed model SHA-256 manifest.
                let request = InferenceRequest(model: ModelReference(directory: directory), input: .image(
                    ImageModelProfile.flux2Klein.request(prompt: "Model registration", seed: 0)))
                _ = try await backend.estimate(request)
            }, textBackendID: textBackend.descriptor.id, validateTextModel: { directory in
                let reference = try await TextModelProfiles.verify(at: directory)
                _ = try await textBackend.estimate(InferenceRequest(model: reference, input: .text(TextRequest(prompt: "Registration", maxTokens: 256,
                    execution: .init(profile: .init(identifier: "qwen2-text"), maximumPromptTokens: 2048)))))
                return reference
            }, previewTextTemplate: { model, request in
                try await ChatTemplatePreviewProvider.preview(model: model, request: request)
            }, audioBackendID: audioBackend?.descriptor.id,
            validateAudioModel: validateAudioModel, musicBackendID: musicBackend?.descriptor.id,
            validateMusicModel: validateMusicModel,
            imageCapability: backend.executionCapability, textCapability: textBackend.executionCapability,
            audioCapability: audioBackend?.executionCapability, musicCapability: musicBackend?.executionCapability,
            videoBackendID: videoBackend?.descriptor.id, validateVideoModel: validateVideoModel,
            videoCapability: videoBackend?.executionCapability, videoAdapters: videoAdapters, modelAdapters: modelAdapters, defaultMemoryBudgetBytes: memoryBudgetBytes,
            pitchBackendID: pitchBackend?.descriptor.id, pitchModel: pitchReference)
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
            case .loading: "Loading model / 正在加载模型"
            case .loadingTextEncoder: "正在加载文本编码器"
            case .loaded: "Preparing context / 正在准备上下文"
            case .textEncoderLoaded, .encoding: "正在编码提示词"
            case .encoded, .loadingTransformer: "正在加载图像模型"
            case .generating: "Generating raw model output / 正在生成原始模型输出"
            case .transformerLoaded, .denoising: "正在生成图像"
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
