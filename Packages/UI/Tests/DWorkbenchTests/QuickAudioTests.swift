import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Quick audio compact form and preserved history", .serialized) @MainActor
struct QuickAudioTests {
    private func draft(_ operation: String = "d.music.generate") throws -> QuickDraft {
        var node = try #require(WorkflowRegistry.standard.operation(operation)?.definition.makeNode())
        node.parameters["modelID"] = .text("fixture:exact")
        return .init(id: operation + "|fixture:exact", node: node)
    }
    private func store() async throws -> ProjectStore {
        try await ProjectStore.create(at: URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("QuickAudio-\(UUID()).dproject"), name: "Quick audio fixture")
    }
    @Test func durationRoundTripEveryLegalFrameAndInvalidGrid() throws {
        for frame in 1...400 { #expect(QuickAudioPresentation.frames(seconds: QuickAudioPresentation.seconds(frames: frame)) == frame) }
        #expect(QuickAudioPresentation.seconds(frames: 123) == "4.92")
        for value in ["", "0", "-1", "0.03", "4.921", "16.04", "NaN", "1e1", "1,2", "1.2.3"] { #expect(QuickAudioPresentation.frames(seconds: value) == nil) }
        var value = try draft(); value.node.parameters["durationFrames"] = .integer(123)
        #expect(QuickGenerationController.validationIssue(value) == nil)
        value.fieldText["quickDurationSeconds"] = "4.921"
        #expect(QuickGenerationController.validationIssue(value)?.code == "quick.audio.durationGrid")
        #expect(value.node.parameters["durationFrames"] == .integer(123))
    }
    @Test func hiddenInputsEvenEmptyCannotExecuteOrLoseIdentity() throws {
        for operation in ["d.music.generate", WorkflowModelRoutes.ace] {
            for port in operation == "d.music.generate" ? ["prompt", "notes", "chords"] : ["prompt", "lyrics", "source", "reference"] {
                var value = try draft(operation); value.inputs[port] = .data(.text(""))
                let frozen = value
                #expect(QuickAudioPresentation.requiresWorkflow(value))
                #expect(QuickGenerationController.validationIssue(value)?.code == "quick.audio.complex")
                #expect(value == frozen)
            }
        }
    }
    @Test func descriptionSeedAndUnexpectedOutputAreNotSilentlyAccepted() throws {
        var value = try draft()
        value.node.parameters["promptText"] = .text("")
        #expect(QuickGenerationController.validationIssue(value)?.code == "quick.audio.descriptionInvalid")
        value.node.parameters["promptText"] = .text("piano")
        value.node.parameters["seed"] = .text("4294967295"); value.attempts = 2
        #expect(QuickAudioPresentation.batchIssue(value)?.code == "quick.audio.seedBatch")
        value.attempts = 1; #expect(QuickAudioPresentation.batchIssue(value) == nil)
        value.node.parameters["seed"] = .text("4294967296")
        #expect(QuickGenerationController.validationIssue(value)?.code == "quick.audio.seedInvalid")
        let run = QuickRunRecord(id: UUID(), draft: value, createdAt: Date(), status: .completed, outputs: ["output": .data(.text("unexpected retained output"))], candidates: [], issue: nil)
        #expect(QuickAudioPresentation.hasUnexpectedOutput(run))
        #expect(run.outputs["output"]?.datum?.text == "unexpected retained output")
        var candidateOnly = run; candidateOnly.outputs = [:]
        let image = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), version: UUID(), kind: .image, sha256: String(repeating: "a", count: 64))
        candidateOnly.candidates = [.init(id: UUID(), attemptID: UUID(), asset: image, seed: "42")]
        #expect(QuickAudioPresentation.hasUnexpectedOutput(candidateOnly))
        candidateOnly.candidates = [.init(id: UUID(), attemptID: UUID(), error: "failed without output", seed: "42")]
        #expect(!QuickAudioPresentation.hasUnexpectedOutput(candidateOnly))
    }
    @Test func aceModesLyricsAndInactiveDefaults() throws {
        var value = try draft(WorkflowModelRoutes.ace)
        #expect(!QuickAudioPresentation.requiresWorkflow(value))
        #expect(QuickGenerationController.validationIssue(value) == nil)
        for mode in ["cover", "repaint"] {
            value.node.parameters["mode"] = .text(mode)
            #expect(QuickAudioPresentation.requiresWorkflow(value))
        }
        value.node.parameters["mode"] = .text("generate")
        value.node.parameters["vocal"] = .text("lyrics")
        value.node.parameters["lyricsText"] = .text("[Verse]\nKeep these words 音乐")
        let lyrics = value.node.parameters["lyricsText"]
        #expect(QuickGenerationController.validationIssue(value) == nil)
        value.node.parameters["vocal"] = .text("instrumental")
        #expect(QuickGenerationController.validationIssue(value)?.code == "quick.audio.lyricsConflict")
        #expect(value.node.parameters["lyricsText"] == lyrics)
        value.node.parameters["vocal"] = .text("lyrics")
        value.node.parameters["duration"] = .decimal(5.21)
        #expect(QuickGenerationController.validationIssue(value) != nil)
        value.node.parameters["duration"] = .decimal(20.1)
        #expect(QuickGenerationController.validationIssue(value) == nil)
        value.node.parameters["seed"] = .text("4294967296")
        #expect(QuickGenerationController.validationIssue(value) != nil)
    }
    @Test func historicalPitchLoadsButNewSelectionAndRetryAreBlocked() async throws {
        let store = try await store(); let pitch = try draft("d.music.pitch")
        var state = try await store.quickCreationState()
        state.drafts = [pitch]; state.selectedDraftID = pitch.id
        state.navigation = .init(selected: .audio, lastDrafts: ["audio": pitch.id])
        let run = QuickRunRecord(id: UUID(), draft: pitch, createdAt: Date(), status: .failed, outputs: [:], candidates: [], issue: "Historical diagnostic")
        state.runs = [run]
        _ = try await store.saveQuickCreationState(state, expectedRevision: state.revision)
        var calls = 0
        let c = QuickGenerationController(store: store) { calls += 1; throw WorkflowIssue("must not execute") }
        await c.load(); #expect(c.draft == pitch); #expect(!c.canStart); #expect(!c.canRetry(run))
        c.start(); c.retryAttempt(run.id); await c.waitForCompletion()
        #expect(calls == 0); #expect(c.state.runs == [run])
        c.select(operationID: "d.music.pitch", modelID: "fixture:new")
        #expect(c.draft == pitch)
        c.select(operationID: "d.music.generate", modelID: "fixture:mrt")
        #expect(c.visibleRuns.isEmpty)
        let allDrafts = c.state.drafts
        var stale = pitch; stale.node.title = "changed"
        #expect(throws: WorkflowIssue.self) { try c.resumeAudioDraft(stale) }
        #expect(c.draft?.id != pitch.id)
        try c.resumeAudioDraft(pitch)
        #expect(c.draft == pitch); #expect(c.visibleRuns == [run]); #expect(c.state.drafts == allDrafts)
        #expect(c.state.navigation?.lastDrafts["audio"] == pitch.id)
        c.start(); c.retryAttempt(run.id); await c.waitForCompletion()
        #expect(calls == 0); #expect(c.state.runs == [run])
        try await c.prepareForTermination(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.quickCreationState().runs == [run])
        try await reopened.close()
    }
    @Test func modelSwitchKeepsSeparateDraftsAndNoHiddenDefaultPrompt() async throws {
        let store = try await store()
        let c = QuickGenerationController(store: store) { throw WorkflowIssue("must not execute") }
        await c.load(); c.select(operationID: "d.music.generate", modelID: "fixture:mrt")
        let mrt = try #require(c.draft?.id)
        #expect(c.draft?.node.parameters["promptText"] == .text("")); #expect(c.draft?.inputs.isEmpty == true)
        c.setAudioDurationSeconds("4.92", draftID: mrt)
        c.setParameter("promptText", value: .text("music A"), draftID: mrt)
        c.select(operationID: WorkflowModelRoutes.ace, modelID: "fixture:ace")
        let ace = try #require(c.draft?.id)
        c.setParameter("vocal", value: .text("lyrics"), draftID: ace)
        c.setParameter("lyricsText", value: .text("keep me"), draftID: ace)
        c.select(operationID: "d.music.generate", modelID: "fixture:mrt")
        #expect(c.draft?.node.parameters["durationFrames"] == .integer(123))
        #expect(c.draft?.node.parameters["promptText"] == .text("music A"))
        #expect(c.draft?.node.parameters["lyricsText"] == nil)
        c.select(operationID: WorkflowModelRoutes.ace, modelID: "fixture:ace")
        #expect(c.draft?.node.parameters["lyricsText"] == .text("keep me"))
        let previous = try #require(c.state.drafts.first { $0.id == mrt })
        try c.resumeAudioDraft(previous)
        #expect(c.draft == previous); #expect(c.state.runs.isEmpty)
        try await c.prepareForTermination(); try await store.close()
    }
    @Test func playbackIsExplicitSwitchStopsAndLateLoadCannotReturn() async throws {
        let store = try await store()
        let bytes = try WorkflowMusicPrograms.render(sequence: .init(clock: .seconds, notes: [], duration: 0.5), sampleRate: 16000)
        let a = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav", name: "first", operationID: "d.asset.import").record.reference
        let b = try await store.publishWorkflowAsset(data: bytes, mediaType: "audio/wav", name: "second", operationID: "d.asset.import").record.reference
        let playback = QuickAudioPlayback()
        await playback.select(a, store: store)
        #expect(playback.reference == a); #expect(playback.transport.state == .recorded)
        #expect(playback.format?.frameCount == 8000)
        playback.transport.setVolume(0.25); #expect(playback.transport.volume == 0.25)
        try playback.transport.seek(toFrame: 4000); #expect(playback.transport.positionFrame == 4000)
        let pending = Task { await playback.select(b, store: store) }
        await Task.yield(); pending.cancel(); playback.stop(); await pending.value
        #expect(playback.reference == nil); #expect(playback.transport.state == .idle)
        await playback.select(b, store: store)
        #expect(playback.reference == b); #expect(playback.name == "second")
        #expect(playback.transport.positionFrame == 0); #expect(playback.transport.state == .recorded)
        playback.stop(); try await store.close()
    }
}
