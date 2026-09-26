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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_LANGUAGE_REAL_CASE"] == "access"), .timeLimit(.minutes(1)))
    func freshPitchAccessParentAndChild() throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("D/NodeLanguageAccess/" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let resources = try #require(Bundle.main.resourceURL)
        let resolvedEngine = try BundledAudioEngine.resolve(resourceDirectory: resources, family: .pitch)
        let engine = try #require(resolvedEngine)
        let directories = [engine.vendorDirectory, root.appendingPathComponent("Input"), root.appendingPathComponent("Run")]
        for directory in directories.dropFirst() { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
        var grants: [[String: String]] = []
        var parent: [[String: Any]] = []
        for (index, directory) in directories.enumerated() {
            let bookmark = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            let resolved = try URL(resolvingBookmarkData: bookmark, options: .init(rawValue: (1 << 8) | (1 << 9) | (1 << 15)), relativeTo: nil, bookmarkDataIsStale: &stale)
            parent.append(["grantIndex": index, "stale": stale, "samePath": resolved.path == directory.path])
            grants.append(["path": directory.path, "bookmark": bookmark.base64EncodedString()])
        }
        let manifest = root.appendingPathComponent("private-grants.json")
        try fm.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: false)
        try #require(fm.createFile(atPath: manifest.path, contents: JSONSerialization.data(withJSONObject: grants), attributes: [.posixPermissions: 0o600]))
        defer { try? fm.removeItem(at: manifest) } // Only this test's ephemeral capabilities; reports contain no bookmark.
        let probe = #"""
        import sys,json,base64
        from pathlib import Path
        sys.path.insert(0,sys.argv[1])
        import d_audio_access as a
        result=[]
        adapter=a._make_cf_adapter()
        for index,g in enumerate(json.loads(Path(sys.argv[2]).read_text())):
            url=None;started=False
            try:
                url,path=adapter.resolve(base64.b64decode(g['bookmark']))
                started=adapter.start(url)
                a._check_directory_readable(path)
                result.append(dict(grantIndex=index,resolved=True,samePath=path==g['path'],started=started,readable=True))
            except a.AudioAccessError as e:
                reason='stale' if str(e)=='bookmark is stale' else 'access_error'
                result.append(dict(grantIndex=index,resolved=False,reason=reason))
            finally:
                if url is not None:
                    if started:adapter.stop(url)
                    adapter.release_url(url)
        print(json.dumps(result))
        """#
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = engine.pythonExecutable
        process.arguments = ["-B", "-c", probe, engine.providerScript.deletingLastPathComponent().path, manifest.path]
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "TMPDIR": root.appendingPathComponent("tmp").path]
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
        let child = try JSONSerialization.jsonObject(with: bytes)
        let report = try JSONSerialization.data(withJSONObject: ["parent": parent, "child": child, "exit": process.terminationStatus], options: [.prettyPrinted, .sortedKeys])
        try report.write(to: root.appendingPathComponent("result.json"), options: [.withoutOverwriting])
        print("D_NODE_LANGUAGE_ACCESS_REPORT=\(root.appendingPathComponent("result.json").path)")
        print(String(decoding: report, as: UTF8.self))
        try #require(process.terminationStatus == 0)
        try #require(parent.allSatisfy { ($0["stale"] as? Bool) == false && ($0["samePath"] as? Bool) == true })
        let rows = try #require(child as? [[String: Any]])
        try #require(rows.count == 3 && rows.allSatisfy { ($0["resolved"] as? Bool) == true && ($0["samePath"] as? Bool) == true && ($0["readable"] as? Bool) == true })
    }

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
            let firstRefs = try candidateReferences(firstRun)
            let secondRefs = try candidateReferences(secondRun)
            try #require(Set(firstRefs).isDisjoint(with: Set(secondRefs)))
            try #require(Set(firstRefs + secondRefs) == Set(musicRecords.map(\.reference)))
            let corrected = try WorkflowNoteSequence(datum: acceptedMelody)
            try #require(corrected.sources == recognized.sources)
            try #require(corrected.notes.first?.pitch == min(127, try #require(recognized.notes.first?.pitch) + 1))
            let allCalls = [firstRun, secondRun].flatMap { $0.planCheckpoint?.records ?? [] }
            for record in musicRecords {
                try #require(record.request?.model == musicReference)
                let call = try #require(allCalls.first { $0.step.id == record.stepID })
                let actualNotes = try WorkflowNoteSequence(datum: #require(call.step.inputs["notes"]?.datum))
                let actualChords = try WorkflowChordTrack(datum: #require(call.step.inputs["chords"]?.datum))
                try #require(try actualNotes.datum() == aMelody)
                let expectedHarmony = firstRefs.contains(record.reference) ? originalChords : harmonyB
                try #require(try actualChords.datum() == expectedHarmony)
                let request = try #require(record.request)
                try #require(request.id == call.step.id && call.step.outputs["output"]?.asset == record.reference)
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
                let exportID = UUID()
                let receipt = try await store.exportWorkflowAssets([record.reference], name: "music", exportID: exportID, directory: exports)
                let folder = exports.appendingPathComponent("music-\(exportID.uuidString).dexport")
                try verifyReceipt(receipt, at: folder)
                let wav = folder.appendingPathComponent("1.wav")
                try #require(try digest(wav) == record.reference.sha256)
                let exported = try AudioMediaInspector.inspect(at: wav, policy: .generated)
                try #require(exported.format == inspection.format)
            }
            // Exact typed handoff and MIDI are program outputs, separate from model waveform.
            let melody = try #require(secondRun.planCheckpoint?.records.first { $0.step.node.operationID == "d.music.align" }?.step.outputs["output"]?.datum)
            let midiID = UUID(), harmonyID = UUID()
            let midiReceipt = try await store.exportWorkflowDatum(melody, format: "midi", name: "melody", exportID: midiID, directory: exports)
            let harmonyReceipt = try await store.exportWorkflowDatum(harmonyB, format: "json", name: "harmony", exportID: harmonyID, directory: exports)
            let midiFolder = exports.appendingPathComponent("melody-\(midiID.uuidString).dexport")
            let harmonyFolder = exports.appendingPathComponent("harmony-\(harmonyID.uuidString).dexport")
            try verifyReceipt(midiReceipt, at: midiFolder); try verifyReceipt(harmonyReceipt, at: harmonyFolder)
            let midi = try Data(contentsOf: midiFolder.appendingPathComponent("1.mid"))
            try #require(midi.starts(with: Data([0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1])))
            try #require(midi.suffix(3) == Data([0xff, 0x2f, 0]))
            let exportedHarmony = try JSONDecoder().decode(WorkflowDatum.self, from: Data(contentsOf: harmonyFolder.appendingPathComponent("1.json")))
            try #require(exportedHarmony == harmonyB)
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
    private func candidateReferences(_ run: WorkflowRun) throws -> [WorkflowAssetReference] {
        let output = try #require(run.planCheckpoint?.records.first { $0.address.path.count == 1 && $0.step.node.operationID == "d.value.return" }?.step.outputs["output"]?.datum)
        guard case .record(_, let fields) = output, case .list(_, let candidates)? = fields["candidates"] else { throw WorkflowIssue("E03 final delivery is not a candidate record.") }
        try #require(candidates.map(\.id) == ["candidate-1", "candidate-2", "candidate-3"])
        return try candidates.map { item in
            guard case .result(let result) = item.value, result.status == .success, case .asset(let ref)? = result.value else { throw WorkflowIssue("E03 retained a failed or skipped candidate.") }
            return ref
        }
    }
    private func verifyReceipt(_ receipt: WorkflowExportReceipt, at folder: URL) throws {
        try #require(receipt.names.count == receipt.hashes.count)
        for (name, hash) in zip(receipt.names, receipt.hashes) { try #require(try digest(folder.appendingPathComponent(name)) == hash) }
        let decoded = try JSONDecoder().decode(WorkflowExportReceipt.self, from: Data(contentsOf: folder.appendingPathComponent("receipt.json")))
        try #require(decoded == receipt)
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
        try #require(actual.durationFrames == 100)
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
