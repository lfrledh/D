import Foundation
import Observation

/// One selected asset, one transport, no candidate-wide decoding or polling.
@MainActor @Observable public final class QuickAudioPlayback {
    public let transport: AudioTransport
    public private(set) var reference: WorkflowAssetReference?
    public private(set) var format: AudioFormatInfo?
    public private(set) var name = ""
    public private(set) var issue: String?
    public private(set) var issueCode: String?
    private var generation = UUID()
    public init(transport: AudioTransport = AudioTransport()) { self.transport = transport }
    public func stop() {
        generation = UUID(); transport.stopPlayback(); reference = nil; format = nil; name = ""; issue = nil; issueCode = nil
    }
    public func select(_ reference: WorkflowAssetReference, store: ProjectStore) async {
        stop()
        let ticket = generation
        do {
            let (url, asset) = try await store.workflowMedia(reference)
            guard reference.kind == .audio, let format = asset.metadata.audio?.format else {
                throw WorkflowIssue("This output is not playable audio.", code: "quick.audio.outputMismatch")
            }
            let policy = try await store.workflowAudioPlaybackPolicy(reference)
            guard generation == ticket, !Task.isCancelled else { return }
            try transport.preparePlayback(url: url, format: format, policy: policy)
            self.reference = reference; self.format = format; name = asset.name
        } catch {
            guard generation == ticket, !Task.isCancelled else { return }
            issue = error.localizedDescription; issueCode = (error as? WorkflowIssue)?.code
        }
    }
}
