import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow media presentation r1") @MainActor
struct WorkflowMediaPresentationTests {
    @Test func videoPresetsAreExactAndApplyOnlySevenParameters() throws {
        #expect(WorkflowVideoPresets.all == [
            .init(id: "connectivity", width: 256, height: 256, frameCount: 17, frameRate: 16,
                  steps: 4, guidance: 5, scheduleShift: 5),
            .init(id: "fullPreview", width: 320, height: 192, frameCount: 17, frameRate: 16,
                  steps: 50, guidance: 6, scheduleShift: 8),
            .init(id: "official480p", width: 832, height: 480, frameCount: 81, frameRate: 16,
                  steps: 50, guidance: 6, scheduleShift: 8),
        ])

        var node = WorkflowLanguageOperations.video.definition.makeNode()
        node.parameters["modelID"] = .text("model-content")
        node.parameters["promptText"] = .text("prompt")
        node.parameters["negativePrompt"] = .text("negative")
        node.parameters["seed"] = .text("18446744073709551615")
        node.parameters["memoryBudgetGiB"] = .integer(27)
        node.parameters["future"] = .text("preserve")
        let applied = try #require(WorkflowVideoPresets.connectivity.applying(to: node))

        for (key, value) in WorkflowVideoPresets.connectivity.parameters {
            #expect(applied.parameters[key] == value)
        }
        for key in ["modelID", "promptText", "negativePrompt", "seed", "memoryBudgetGiB", "future"] {
            #expect(applied.parameters[key] == node.parameters[key])
        }
        #expect(applied.id == node.id && applied.title == node.title)
        #expect(WorkflowVideoPresets.fullPreview.applying(
            to: WorkflowNode(operationID: "d.image.generate", title: "image")
        ) == nil)
    }

    @Test func newVideoNodesAndNewE04UseFullPreviewWithoutRewritingStoredFourStepNodes() throws {
        let defaults = WorkflowLanguageOperations.video.definition.makeNode()
        for (key, value) in WorkflowVideoPresets.fullPreview.parameters {
            #expect(defaults.parameters[key] == value)
        }

        let e04 = try WorkflowLanguageExamples.make(.multimodal).graph
        let video = try #require(e04.nodes.first { $0.operationID == "d.video.generate" })
        for (key, value) in WorkflowVideoPresets.fullPreview.parameters {
            #expect(video.parameters[key] == value)
        }

        var historical = defaults
        historical.parameters.merge(WorkflowVideoPresets.connectivity.parameters) { _, new in new }
        let encoded = try JSONEncoder().encode(WorkflowGraph(nodes: [historical]))
        let reopened = try JSONDecoder().decode(WorkflowGraph.self, from: encoded)
        #expect(reopened.nodes[0].parameters["steps"] == .integer(4))
        #expect(reopened.nodes[0].parameters["width"] == .integer(256))
    }

    @Test func musicPortIsOptionalAndActualOperationPreservesAllFourConditionModes() async throws {
        let notesPort = try #require(WorkflowMusicOperations.music.definition.inputs.first { $0.id == "notes" })
        #expect(!notesPort.required)

        let noteSource = reference(kind: .notes, marker: "a")
        let chordSource = reference(kind: .chords, marker: "b")
        let empty = WorkflowNoteSequence(clock: .seconds, notes: [], duration: 4)
        let notes = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "n1", pitch: 64, start: 0.04, end: 1.04, velocity: 0.7)],
            duration: 4,
            sources: [noteSource]
        )
        let tempo = WorkflowTempoMap(
            beatsPerMinute: 120, firstBeatSeconds: 0, numerator: 4, denominator: 4
        )
        let chords = WorkflowChordTrack(
            chords: [.init(id: "C", root: 0, quality: .major, octave: 4,
                           inversion: 0, start: 0, end: 4)],
            duration: 4,
            tempo: tempo,
            sources: [chordSource]
        )

        let services = CapturingMediaServices()
        try await executeMusic(inputs: [:], services: services)
        try await executeMusic(inputs: ["notes": .data(try empty.datum())], services: services)
        try await executeMusic(inputs: ["notes": .data(try notes.datum())], services: services)
        try await executeMusic(inputs: ["chords": .data(try chords.datum())], services: services)

        #expect(services.music.count == 4)
        #expect(services.music[0].request.noteSequence != nil)
        #expect(services.music[0].request.noteSequence?.notes == nil)
        #expect(services.music[1].request.noteSequence?.notes == [])
        #expect(services.music[2].request.noteSequence?.notes == [
            .init(pitch: 64, startFrame: 1, endFrame: 26),
        ])
        #expect(!(services.music[3].request.noteSequence?.notes?.isEmpty ?? true))
        #expect(services.music[0].parents.isEmpty)
        #expect(services.music[1].parents.isEmpty)
        #expect(services.music[2].parents == [noteSource])
        #expect(services.music[3].parents == [chordSource])
    }

    private func executeMusic(
        inputs: [String: WorkflowValue],
        services: CapturingMediaServices
    ) async throws {
        let node = WorkflowMusicOperations.music.definition.makeNode()
        let context = WorkflowExecutionContext(node: node, stepID: UUID(), inputs: inputs)
        _ = try await WorkflowMusicOperations.music.execute(context, services)
    }

    private func reference(kind: WorkflowDataKind, marker: Character) -> WorkflowAssetReference {
        .init(
            projectID: UUID(), assetID: UUID(), kind: kind,
            sha256: String(repeating: marker, count: 64)
        )
    }
}

@MainActor private final class CapturingMediaServices: WorkflowOperationServices {
    struct MusicCall {
        let request: AudioRequest
        let parents: [WorkflowAssetReference]
    }

    private(set) var music: [MusicCall] = []

    func generateMusic(
        _ request: AudioRequest,
        parents: [WorkflowAssetReference],
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        music.append(.init(request: request, parents: parents))
        return .init(
            projectID: UUID(), assetID: UUID(), kind: .audio,
            sha256: String(repeating: "c", count: 64)
        )
    }

    func readText(_ reference: WorkflowAssetReference) async throws -> String {
        throw WorkflowIssue("Media presentation fixture must not read text assets.")
    }

    func verifyAsset(_ reference: WorkflowAssetReference) async throws {
        throw WorkflowIssue("Media presentation fixture must not verify assets.")
    }

    func publishText(
        _ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        throw WorkflowIssue("Media presentation fixture must not publish text.")
    }

    func rewriteText(
        _ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        throw WorkflowIssue("Media presentation fixture must not rewrite text.")
    }

    func generateImages(
        prompt: String, reference: WorkflowAssetReference?, context: WorkflowExecutionContext
    ) async throws -> [WorkflowCandidate] {
        throw WorkflowIssue("Media presentation fixture must not generate images.")
    }

    func transformImage(
        _ reference: WorkflowAssetReference, context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        throw WorkflowIssue("Media presentation fixture must not transform images.")
    }

    func export(
        _ value: WorkflowValue, context: WorkflowExecutionContext
    ) async throws -> WorkflowExportReceipt {
        throw WorkflowIssue("Media presentation fixture must not export.")
    }
}
