import DInference
import DMLXBackend
import DRuntime
import Foundation
import UI

/// The application is the only layer that chooses a concrete compute backend.
enum AppSessionFactory {
    nonisolated static func makeSession(artifactDirectory: URL) async throws -> WorkbenchSession {
        let stages = BackendStageMonitor()
        let backend = try MLXImageBackend(configuration: .init(artifactDirectory: artifactDirectory),
                                         observer: { await stages.record($0) })
        let runtime = try InferenceRuntime(
            backends: [backend],
            configuration: try RuntimeConfiguration(memoryBudgetBytes: 8 * 1024 * 1024 * 1024,
                                                    maximumQueuedRuns: 8))
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
                    ImageRequest(prompt: "Model registration", width: 512, height: 512,
                                 steps: 4, guidanceScale: 1, seed: 0)))
                _ = try await backend.estimate(request)
            })
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
            case nil: "正在准备模型"
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
