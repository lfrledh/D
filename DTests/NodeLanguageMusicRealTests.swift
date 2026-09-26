import AVFoundation
import CryptoKit
import DInference
import DMLXBackend
import DWorkbench
import Foundation
import Testing
@testable import D

/// Real previously authorized recording + SwiftF0/MRT2, through the editable E03.
/// Automated decisions are test actions, not a new user consent or listening verdict.
@Suite(.serialized) @MainActor
struct NodeLanguageMusicRealTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_LANGUAGE_REAL_CASE"] == "music"), .timeLimit(.minutes(20)))
    func recordedMelodyAndTwoHarmonyVersionsReachRealConditionedMusic() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["D_NODE_LANGUAGE_MUSIC_ACKNOWLEDGED"] == "1")
        let authorization = try #require(env["D_NODE_LANGUAGE_MUSIC_AUTHORIZATION_SOURCE"])
        let modelURL = URL(fileURLWithPath: try #require(env["D_NODE_LANGUAGE_MUSIC_MODEL"]))
        let recording = URL(fileURLWithPath: try #require(env["D_NODE_LANGUAGE_RECORDING"]))
        let originalDigest = try digest(recording)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("D/NodeLanguageAcceptance/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let access = root.appendingPathComponent("Access")
        try FileManager.default.createDirectory(at: access, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let exports = root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
        let project = root.appendingPathComponent("real-music.dproject")
        print("D_NODE_LANGUAGE_REAL_MUSIC_ROOT=\(root.path)")
        let resources = try #require(Bundle.main.resourceURL)
        let musicEngine = try #require(try BundledAudioEngine.resolve(resourceDirectory: resources, family: .mrt2Music))
        let pitchEngine = try #require(try BundledAudioEngine.resolve(resourceDirectory: resources, family: .pitch))
        let suite = "D.NodeLanguage.RealMusic." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        // The caller must explicitly cite the existing same-revision development authorization.
        // This fixture does not accept a third-party license or claim a new GUI confirmation.
        settings.set(true, forKey: "audio.model-use.mrt2-small." + MRT2BackendConfiguration.registeredModelRevision)
        let consent = AudioModelUsePermission(settings: settings, model: .mrt2Music)
        let store = try await ProjectStore.create(at: project, name: "Real E03 music")
        let runtime = try await AppSessionFactory.makeSession(artifactDirectory: store.artifactDirectory,
            bundledMusicEngine: musicEngine, musicConsent: consent, audioAccessRoot: access, bundledPitchEngine: pitchEngine)
        let started = Date()
        do {
            let validator = try #require(runtime.validateMusicModel)
            let musicReference = try await validator(modelURL)
            let pitchReference = try #require(runtime.pitchModel)
            let musicBackend = try #require(runtime.musicBackendID), pitchBackend = try #require(runtime.pitchBackendID)
            let musicID = "music:" + (musicReference.revision ?? "unknown")
            let pitchID = "pitch:" + (pitchReference.revision ?? "unknown")
            let services = WorkflowServices(store: store, session: runtime, defaultIdentity: { kind in
                switch kind { case .music: musicID; case .pitch: pitchID; default: "" }
            }, resolveModel: { kind, identity in
                if kind == .music && identity == musicID { return .init(identity: identity, reference: musicReference, backendID: musicBackend) }
                if kind == .pitch && identity == pitchID { return .init(identity: identity, reference: pitchReference, backendID: pitchBackend) }
                throw WorkflowIssue("E03 default must not request a text model or another binding.")
            })
            let bundle = try WorkflowLanguageExamples.make(.music)
            let revision = try #require(try await store.workflowState().archive?.revision)
            _ = try await store.saveWorkflow(graphs: [bundle.graph], runs: [], expectedRevision: revision, tools: bundle.tools)
            let c = WorkflowController(services: services); await c.load()
            let input = try #require(c.graph?.nodes.first { $0.operationID == "d.asset.reference" })
            await c.importFile(recording, nodeID: input.id)
            try #require(c.errorMessage == nil, Comment(rawValue: c.errorMessage ?? ""))
            let target = try #require(c.graph?.nodes.last { $0.operationID == "d.value.return" }).id
            let chordInput = try #require(c.graph?.nodes.first { $0.title == "输入明确和弦" })
            let originalChords = try #require(chordInput.dataConfiguration?.value)
            let firstRun = try await runAndDecide(c, target: target, retainedMelody: nil)
            try #require(firstRun.status == .completed)
            let firstArchive = try #require(try await store.workflowState().archive)
            let firstRequests = firstArchive.assets.compactMap(\.request)
            let firstMusic = firstRequests.compactMap { request -> AudioRequest? in
                if case .audio(let value) = request.input { return value }; return nil
            }
            try #require(firstMusic.count == 3)
            for request in firstMusic { try #require(request.noteSequence != nil); try #require(request.noteSequence?.durationFrames == 100) }
            let firstPitch = firstRequests.filter { if case .pitch = $0.input { return true }; return false }
            try #require(firstPitch.count == 1)
            let firstNotes = firstRun.planCheckpoint?.records.first { $0.step.node.operationID == "d.music.pitch" }?.step.outputs["output"]?.datum
            let recognized = try WorkflowNoteSequence(datum: #require(firstNotes))
            try #require(!recognized.notes.isEmpty)
            let acceptedMelody = try #require(firstRun.planCheckpoint?.records.first {
                $0.step.humanTask?.resultSchema == WorkflowNoteSequence.schema(clock: .seconds)
            }?.step.outputs["output"]?.datum)
            // New editable harmony version, without changing the recording or recognized notes.
            var changedChords = try WorkflowChordTrack(datum: originalChords)
            for i in changedChords.chords.indices { changedChords.chords[i].root = (changedChords.chords[i].root + 2) % 12 }
            let harmonyB = try changedChords.datum()
            var config = try #require(chordInput.dataConfiguration); config.value = harmonyB
            c.setDataConfiguration(nodeID: chordInput.id, value: config)
            let secondRun = try await runAndDecide(c, target: target, retainedMelody: acceptedMelody)
            try #require(secondRun.status == .completed)
            let archive = try #require(try await store.workflowState().archive)
            try #require(archive.runs.first { $0.id == firstRun.id } == firstRun)
            let requests = archive.assets.compactMap(\.request)
            let musicRecords = archive.assets.filter { if case .audio? = $0.request?.input { return true }; return false }
            try #require(musicRecords.count == 6)
            let secondMusic = musicRecords.filter { record in !firstArchive.assets.contains { $0.reference == record.reference } }
            try #require(secondMusic.count == 3)
            let aNotes = try #require(firstMusic.first?.noteSequence?.notes)
            let bInput = try #require(secondMusic.first?.request?.input)
            guard case .audio(let bAudio) = bInput else { throw WorkflowIssue("Expected actual audio request.") }
            let bNotes = try #require(bAudio.noteSequence?.notes)
            try #require(aNotes != bNotes)
            let aMelody = try #require(firstRun.planCheckpoint?.records.first { $0.step.node.operationID == "d.music.align" }?.step.outputs["output"]?.datum)
            let bMelody = try #require(secondRun.planCheckpoint?.records.first { $0.step.node.operationID == "d.music.align" }?.step.outputs["output"]?.datum)
            try #require(aMelody == bMelody)
            let allCalls = [firstRun, secondRun].flatMap { $0.planCheckpoint?.records ?? [] }
            for record in musicRecords {
                try #require(record.request?.model == musicReference)
                let call = try #require(allCalls.first { $0.step.id == record.stepID })
                let actualNotes = try WorkflowNoteSequence(datum: #require(call.step.inputs["notes"]?.datum))
                let actualChords = try WorkflowChordTrack(datum: #require(call.step.inputs["chords"]?.datum))
                let request = try #require(record.request)
                guard case .audio(let input) = request.input else { throw WorkflowIssue("Expected conditioned music.") }
                try verifyCondition(try #require(input.noteSequence), notes: actualNotes, chords: actualChords)
                try #require(record.metadata["conditionSHA256"]?.count == 64)
                let (url, asset) = try await store.workflowMedia(record.reference)
                let inspection = try AudioMediaInspector.inspect(at: url, policy: .generated)
                try #require(inspection.format.frameCount > 0)
                try #require(asset.metadata.audio?.origin == .modelGenerated)
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: buffer)
                try #require(buffer.frameLength > 0)
                let channel = try #require(buffer.floatChannelData?.pointee)
                let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
                let finite = samples.allSatisfy { $0.isFinite }
                try #require(finite)
                try #require(samples.contains { abs($0) > 0.00001 })
                _ = try await store.exportWorkflowDatum(.asset(record.reference), format: "auto", name: "music", exportID: UUID(), directory: exports)
            }
            // Exact typed handoff and MIDI are program outputs, separate from model waveform.
            let melody = try #require(secondRun.planCheckpoint?.records.first { $0.step.node.operationID == "d.music.align" }?.step.outputs["output"]?.datum)
            _ = try await store.exportWorkflowDatum(melody, format: "midi", name: "melody", exportID: UUID(), directory: exports)
            _ = try await store.exportWorkflowDatum(harmonyB, format: "json", name: "harmony", exportID: UUID(), directory: exports)
            try #require(requests.allSatisfy { if case .text = $0.input { return false }; return true })
            try #require(try digest(recording) == originalDigest)
            await c.save(); try #require(!c.hasPendingSaves)
            let finalArchive = try #require(try await store.workflowState().archive)
            try JSONEncoder().encode(finalArchive).write(to: root.appendingPathComponent("workflow-evidence.json"), options: .withoutOverwriting)
            c.deactivateAfterClose(); try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            try #require(try await reopened.workflowState().archive == finalArchive)
            try await reopened.close()
            try #require(await runtime.status().activeRunID == nil)
            await runtime.shutdown()
            let report: [String: Any] = ["case": "music", "project": project.path,
                "modelRevision": musicReference.revision ?? "unknown", "pitchRevision": pitchReference.revision ?? "unknown",
                "authorizationSource": authorization, "consent": "isolated fixture reflecting prior explicit same-revision development authorization; not a new click",
                "sourceRecordingSHA256": originalDigest, "recognizedNotes": recognized.notes.count,
                "conditionedGenerations": musicRecords.count, "harmonyVersions": 2,
                "elapsedSeconds": Date().timeIntervalSince(started), "nativeRecording": false, "listening": false, "gui": false]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("real-result.json"), options: .withoutOverwriting)
            print("D_NODE_LANGUAGE_REAL_MUSIC_PASS=\(root.path)")
        } catch {
            await runtime.shutdown(); try? await store.close(preserveExternalChanges: true); throw error
        }
    }

    private func runAndDecide(_ c: WorkflowController, target: UUID, retainedMelody: WorkflowDatum?) async throws -> WorkflowRun {
        await c.run(target: target, only: false)
        try #require(c.errorMessage == nil, Comment(rawValue: c.errorMessage ?? ""))
        let id = try #require(c.runs.last?.id)
        var decisions = 0
        while c.runs.last?.status == .waiting {
            decisions += 1; try #require(decisions <= 2)
            let record = try #require(c.callRecords(runID: id).first { $0.step.status == .waiting })
            let human = try #require(record.step.humanTask)
            var value = human.materials
            if human.resultSchema == WorkflowNoteSequence.schema(clock: .seconds) {
                if let retainedMelody { value = retainedMelody }
                else {
                    var notes = try WorkflowNoteSequence(datum: value)
                    try #require(!notes.notes.isEmpty)
                    notes.notes[0].pitch = min(127, notes.notes[0].pitch + 1)
                    value = try notes.datum()
                }
            }
            await c.decideHuman(stepID: record.step.id, value: value, expectedTask: human)
            try #require(c.errorMessage == nil, Comment(rawValue: c.errorMessage ?? ""))
            await c.resume(runID: id)
            try #require(c.errorMessage == nil, Comment(rawValue: c.errorMessage ?? ""))
        }
        return try #require(c.runs.first { $0.id == id })
    }
    /// Independent frame occupancy/onset oracle, not the production condition builder.
    private func verifyCondition(_ actual: AudioNoteSequence, notes: WorkflowNoteSequence, chords: WorkflowChordTrack) throws {
        var expectedHeld = Set<String>(), expectedOnsets = Set<String>()
        func add(_ pitch: Int, _ start: Double, _ end: Double) {
            let a = Int((start * 25).rounded(.toNearestOrAwayFromZero)), b = Int((end * 25).rounded(.toNearestOrAwayFromZero))
            if b > a { expectedOnsets.insert("\(pitch):\(a)"); for frame in a..<b { expectedHeld.insert("\(pitch):\(frame)") } }
        }
        let tempo = try #require(notes.tempo)
        for note in notes.notes where note.velocity > 0 {
            let a = tempo.firstBeatSeconds + note.start * 60 / tempo.beatsPerMinute
            let b = tempo.firstBeatSeconds + note.end * 60 / tempo.beatsPerMinute
            add(note.pitch, a, b)
        }
        let harmonyTempo = try #require(chords.tempo)
        for chord in chords.chords {
            let intervals: [Int] = switch chord.quality {
            case .major: [0, 4, 7]; case .minor: [0, 3, 7]; case .dominant7: [0, 4, 7, 10]
            case .major7: [0, 4, 7, 11]; case .minor7: [0, 3, 7, 10]; case .diminished: [0, 3, 6]
            }
            for (index, interval) in intervals.enumerated() {
                add((chord.octave + 1) * 12 + chord.root + interval + (index < chord.inversion ? 12 : 0),
                    harmonyTempo.firstBeatSeconds + chord.start * 60 / harmonyTempo.beatsPerMinute,
                    harmonyTempo.firstBeatSeconds + chord.end * 60 / harmonyTempo.beatsPerMinute)
            }
        }
        var observedHeld = Set<String>(), observedOnsets = Set<String>()
        for note in try #require(actual.notes) {
            observedOnsets.insert("\(note.pitch):\(note.startFrame)")
            for frame in note.startFrame..<note.endFrame { observedHeld.insert("\(note.pitch):\(frame)") }
        }
        try #require(observedHeld == expectedHeld)
        try #require(observedOnsets == expectedOnsets)
    }
    private func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
}
