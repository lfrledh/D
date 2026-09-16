import AudioToolbox
import AVFoundation
import CryptoKit
import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Pitch original ownership and durable decisions", .serialized)
struct PitchWorkflowTests {
    @Test func bundledModelURLAllowsCompletionAndDurableDecision() async throws {
        try await withPitchFixture { root, store, document, original in
            let project = root.appendingPathComponent("Pitch.dproject"), id = UUID()
            let directory = try #require(URL(string: "测试%20App.app/Contents/Resources/swift_f0/", relativeTo: root))
            #expect(directory != directory.absoluteURL)
            let model = ModelReference(directory: directory, revision: PitchAnalysisRequest.modelSHA256)
            let input = try await store.preparePitchInput(documentID: document.id, runID: id)
            _ = try await store.enqueue(request: .init(id: id, model: model, input: .pitch(input)), documentID: document.id)
            _ = try await store.updateJob(id: id, state: .generating)
            let output = project.appendingPathComponent("Tasks/\(id.uuidString)/pitch.json")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pitchResult(request: input, id: id)).write(to: output)
            let completed = try await store.complete(id: id, result: .init(artifacts: [.init(url: output, mediaType: PitchAnalysisResult.mediaType)]))
            let asset = try #require(completed.assets.last)
            let saved = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            #expect(await reopened.snapshot() == saved)
            #expect(try Data(contentsOf: root.appendingPathComponent("source.wav")) == original)
            try await reopened.close()
        }
    }
    @Test func relocationTransfersInvalidationBeforePendingResultSave() async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject"), id = UUID()
            let input = try await store.preparePitchInput(documentID: document.id, runID: id)
            _ = try await store.enqueue(request: .init(id: id, model: pitchModel, input: .pitch(input)), documentID: document.id)
            _ = try await store.invalidatePitchCandidates(documentID: document.id)
            let replacement = try await store.relocated(to: project)
            let output = project.appendingPathComponent("Tasks/\(id.uuidString)/pitch.json")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pitchResult(request: input, id: id)).write(to: output)
            let saved = try await replacement.complete(id: id, result: .init(artifacts: [.init(url: output, mediaType: PitchAnalysisResult.mediaType)]))
            let asset = try #require(saved.assets.last)
            #expect(saved.documents.last?.pitchAnalysis?.expiredAssetIDs == [asset.id])
            await #expect(throws: ProjectStoreError.self) { try await replacement.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true) }
            _ = try await replacement.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: false)
            try await replacement.close()
        }
    }

    @Test func sixtyFifthRejectedCandidateDoesNotTrapOrDeleteHistory() async throws {
        try await withPitchFixture { root, store, document, _ in
            for index in 0..<65 {
                let (_, asset) = try await pitchCandidate(store: store, documentID: document.id, project: root.appendingPathComponent("Pitch.dproject"))
                if index == 64 { _ = try await store.invalidatePitchCandidates(documentID: document.id) }
                _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: false)
            }
            let saved = await store.snapshot()
            #expect(saved.documents.last?.pitchAnalysis?.rejectedAssetIDs.count == 65)
            #expect(saved.documents.last?.pitchAnalysis?.selectedAssetID == nil)
            #expect(saved.jobs.count == 65 && saved.assets.count == 66)
        }
    }

    @Test func strictFileAndRoundedSourceTailAreIndependentOfProvider() throws {
        let source = PitchSourceIdentity(assetID: UUID(), documentID: UUID(), documentRevision: 0,
            contentSHA256: String(repeating: "a", count: 64), sampleRate: 16_000,
            frameCount: 2000, startFrame: 100, endFrame: 1379)
        let value = PitchAnalysisResult(runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
            sampleCount: 1280, frames: Array(repeating: .init(pitchHz: 440, confidence: 0.99, voiced: true), count: 5))
        let data = try JSONEncoder().encode(value)
        #expect(try PitchResultFile.decode(data) == value)
        var duplicate = Data("{\"schemaVersion\":1,".utf8); duplicate.append(data.dropFirst())
        #expect(throws: InferenceFailure.self) { try PitchResultFile.decode(duplicate) }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true")
        #expect(throws: (any Error).self) { try PitchResultFile.decode(Data(text.utf8)) }
        let mapped = try #require(PitchSourceNote.map(value).first)
        #expect(mapped.startFramePosition == 100)
        #expect(mapped.endFramePosition == 1379)
        let unvoiced = PitchFrame(pitchHz: nil, confidence: 0.1, voiced: false)
        let encoded = try JSONEncoder().encode(unvoiced)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"pitchHz\":null"))
    }

    @Test func unreadablePendingResultCanBeRejectedAndNavigationExpiresAnother() async throws {
        try await withPitchFixture { root, store, document, original in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (_, damaged) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            let file = project.appendingPathComponent(damaged.relativePath), sentinel = Data("damaged evidence".utf8)
            try sentinel.write(to: file)
            await #expect(throws: ProjectStoreError.self) { try await store.readPitchAnalysis(assetID: damaged.id) }
            _ = try await store.decidePitchAnalysis(assetID: damaged.id, documentID: document.id, accept: false)
            #expect(try Data(contentsOf: file) == sentinel)
            let (_, candidate) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.invalidatePitchCandidates(documentID: document.id)
            await #expect(throws: ProjectStoreError.self) { try await store.decidePitchAnalysis(assetID: candidate.id, documentID: document.id, accept: true) }
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            await #expect(throws: ProjectStoreError.self) { try await reopened.decidePitchAnalysis(assetID: candidate.id, documentID: document.id, accept: true) }
            _ = try await reopened.decidePitchAnalysis(assetID: candidate.id, documentID: document.id, accept: false)
            #expect(try Data(contentsOf: root.appendingPathComponent("source.wav")) == original)
            try await reopened.close()
        }
    }

    @Test(arguments: [16_000, 24_000, 44_100, 48_000])
    func conversionPreservesSourceAndSelectedTime(rate: Int) async throws {
        try await withPitchFixture(rate: rate) { root, store, document, original in
            var draft = try #require(document.audioDraft)
            let clip = AudioClip(name: "e\u{301} 🎵", range: .init(startFrame: Int64(rate / 4), endFrame: Int64(rate * 3 / 4)))
            draft.clips = [clip]; draft.selectedClipID = clip.id; draft.revision += 1
            _ = try await store.saveAudioDraft(draft, documentID: document.id, expectedRevision: 0)
            let input = try await store.preparePitchInput(documentID: document.id, runID: UUID())
            #expect(abs(input.sampleCount - 8_000) <= 1)
            #expect(input.source.startFrame == Int64(rate / 4))
            #expect(input.source.documentRevision == 1)
            let data = try Data(contentsOf: input.inputURL)
            #expect(data.count == input.sampleCount * 4)
            #expect(digest(data) == input.inputSHA256)
            let samples = data.withUnsafeBytes { raw in (0..<input.sampleCount).map { i in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            } }
            #expect(samples.allSatisfy { $0.isFinite })
            let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            #expect(abs(crossings - 220) <= 2)
            let asset = try #require(await store.snapshot().assets.first)
            #expect(try Data(contentsOf: await store.assetURL(for: asset)) == original)
            #expect(try Data(contentsOf: root.appendingPathComponent("source.wav")) == original)
        }
    }

    @Test func acceptRejectExportReopenPreservesOriginalAndHistory() async throws {
        try await withPitchFixture { root, store, document, original in
            let (result, asset) = try await pitchCandidate(store: store, documentID: document.id, project: root.appendingPathComponent("Pitch.dproject"))
            #expect(try await store.readPitchAnalysis(assetID: asset.id) == result)
            #expect(await store.snapshot().documents.last?.audioDraft == document.audioDraft)
            let saved = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            #expect(saved.documents.last?.pitchAnalysis?.acceptedAssetIDs == [asset.id])
            let (_, other) = try await pitchCandidate(store: store, documentID: document.id, project: root.appendingPathComponent("Pitch.dproject"))
            let rejected = try await store.decidePitchAnalysis(assetID: other.id, documentID: document.id, accept: false)
            #expect(rejected.documents.last?.pitchAnalysis?.selectedAssetID == asset.id)
            #expect(rejected.documents.last?.pitchAnalysis?.rejectedAssetIDs == [other.id])
            let target = root.appendingPathComponent("音高 候选.json")
            try await store.exportPitchAnalysis(assetID: asset.id, to: target)
            let bytes = try Data(contentsOf: target)
            #expect(!String(decoding: bytes, as: UTF8.self).contains(root.path))
            await #expect(throws: ProjectStoreError.self) { try await store.exportPitchAnalysis(assetID: asset.id, to: target) }
            #expect(try Data(contentsOf: target) == bytes)
            try await store.close()
            let reopened = try await ProjectStore.open(at: root.appendingPathComponent("Pitch.dproject"))
            #expect(await reopened.snapshot() == rejected)
            #expect(try await reopened.readPitchAnalysis(assetID: asset.id) == result)
            let source = try #require(await reopened.snapshot().assets.first)
            #expect(try Data(contentsOf: await reopened.assetURL(for: source)) == original)
            try await reopened.close()
        }
    }

    @Test func changedDraftMakesCandidateStaleAndRefusesAnotherUndecidedRun() async throws {
        try await withPitchFixture { root, store, document, _ in
            let (_, asset) = try await pitchCandidate(store: store, documentID: document.id, project: root.appendingPathComponent("Pitch.dproject"))
            var draft = try #require(document.audioDraft); draft.revision = 1; draft.note = "changed 原声 e\u{301}"
            _ = try await store.saveAudioDraft(draft, documentID: document.id, expectedRevision: 0)
            await #expect(throws: ProjectStoreError.self) { try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true) }
            let id = UUID(), input = try await store.preparePitchInput(documentID: document.id, runID: UUID())
            await #expect(throws: ProjectStoreError.self) {
                try await store.enqueue(request: .init(id: id, model: pitchModel, input: .pitch(input)), documentID: document.id)
            }
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: false)
            #expect(await store.snapshot().documents.last?.audioDraft == draft)
        }
    }

    @Test func wrongResultSourceAndBrokenSaveKeepPriorManifestAndAllowRetry() async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject"), id = UUID()
            let request = try await store.preparePitchInput(documentID: document.id, runID: id)
            _ = try await store.enqueue(request: .init(id: id, model: pitchModel, input: .pitch(request)), documentID: document.id)
            let output = project.appendingPathComponent("Tasks/\(id.uuidString)/pitch.json")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let wrong = pitchResult(request: request, id: UUID())
            try JSONEncoder().encode(wrong).write(to: output)
            let completion = InferenceResult(artifacts: [.init(url: output, mediaType: PitchAnalysisResult.mediaType)])
            await #expect(throws: ProjectStoreError.self) { try await store.complete(id: id, result: completion) }
            #expect(await store.snapshot().assets.count == 1)
            let correct = pitchResult(request: request, id: id)
            try JSONEncoder().encode(correct).write(to: output)
            let completed = try await store.complete(id: id, result: completion)
            let asset = try #require(completed.assets.last)
            let manifest = project.appendingPathComponent(ProjectStore.manifestFilename), before = try Data(contentsOf: manifest)
            let sentinel = Data("controlled external edit".utf8); try sentinel.write(to: manifest)
            await #expect(throws: ProjectStoreError.externalModification) { try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true) }
            #expect(try Data(contentsOf: manifest) == sentinel)
            #expect(await store.snapshot() == completed)
            try before.write(to: manifest)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
        }
    }

    @Test func schemaElevenBackupIsExactAndCannotSmugglePitchState() async throws {
        try await withPitchFixture { root, store, _, original in
            let previous = await store.snapshot(); try await store.close()
            let project = root.appendingPathComponent("Pitch.dproject"), file = project.appendingPathComponent(ProjectStore.manifestFilename)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["schemaVersion"] = 11
            let old = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]); try old.write(to: file)
            let reopened = try await ProjectStore.open(at: project)
            #expect(await reopened.snapshot().schemaVersion == 12)
            #expect(await reopened.snapshot().documents == previous.documents)
            #expect(try Data(contentsOf: project.appendingPathComponent("project.v11.backup.json")) == old)
            let asset = try #require(await reopened.snapshot().assets.first)
            #expect(try Data(contentsOf: await reopened.assetURL(for: asset)) == original)
            try await reopened.close()
            var docs = try #require(object["documents"] as? [[String: Any]])
            docs[docs.count - 1]["pitchAnalysis"] = ["acceptedAssetIDs": [], "rejectedAssetIDs": []]
            object["documents"] = docs
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            await #expect(throws: ProjectStoreError.self) { try await ProjectStore.open(at: project) }
        }
    }
}

@Suite("Retained HUM note exchange and original protection", .serialized)
struct PitchExchangeWorkflowTests {
    @Test func independentAppleReadersConfirmNotesTimingAndWaveform() throws {
        let silent = PitchFrame(pitchHz: nil, confidence: 0, voiced: false)
        let frames = Array(repeating: silent, count: 10)
            + Array(repeating: PitchFrame(pitchHz: 440, confidence: 0.99, voiced: true), count: 100)
            + Array(repeating: silent, count: 5)
            + Array(repeating: PitchFrame(pitchHz: 523.251130601, confidence: 0.99, voiced: true), count: 20)
        let count = 135 * 256 + 37
        let source = PitchSourceIdentity(assetID: UUID(), documentID: UUID(), documentRevision: 7,
            contentSHA256: String(repeating: "a", count: 64), sampleRate: 48000,
            frameCount: Int64(count * 3 + 96000), startFrame: 96000, endFrame: Int64(count * 3 + 96000))
        let result = PitchAnalysisResult(runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
                                        sampleCount: count, frames: frames)
        let midi = try PitchMIDIFile.encode(result: result)
        var optionalSequence: MusicSequence?
        #expect(NewMusicSequence(&optionalSequence) == noErr)
        let sequence = try #require(optionalSequence)
        defer { DisposeMusicSequence(sequence) }
        #expect(MusicSequenceFileLoadData(sequence, midi as CFData, .midiType, []) == noErr)
        var trackCount: UInt32 = 0
        #expect(MusicSequenceGetTrackCount(sequence, &trackCount) == noErr)
        #expect(trackCount == 1)
        var optionalTrack: MusicTrack?
        #expect(MusicSequenceGetIndTrack(sequence, 0, &optionalTrack) == noErr)
        let track = try #require(optionalTrack)
        var optionalIterator: MusicEventIterator?
        #expect(NewMusicEventIterator(track, &optionalIterator) == noErr)
        let iterator = try #require(optionalIterator)
        defer { DisposeMusicEventIterator(iterator) }
        var notes: [(UInt8, Double, Double, UInt8)] = []
        var hasEvent: DarwinBoolean = false
        #expect(MusicEventIteratorHasCurrentEvent(iterator, &hasEvent) == noErr)
        while hasEvent.boolValue {
            var timestamp: MusicTimeStamp = 0, type: MusicEventType = 0, size: UInt32 = 0
            var pointer: UnsafeRawPointer?
            #expect(MusicEventIteratorGetEventInfo(iterator, &timestamp, &type, &pointer, &size) == noErr)
            if type == kMusicEventType_MIDINoteMessage {
                let note = try #require(pointer).load(as: MIDINoteMessage.self)
                var start: Float64 = 0, end: Float64 = 0
                #expect(MusicSequenceGetSecondsForBeats(sequence, timestamp, &start) == noErr)
                #expect(MusicSequenceGetSecondsForBeats(sequence, timestamp + Double(note.duration), &end) == noErr)
                #expect(note.channel == 0)
                notes.append((note.note, start, end, note.velocity))
            }
            #expect(MusicEventIteratorNextEvent(iterator) == noErr)
            #expect(MusicEventIteratorHasCurrentEvent(iterator, &hasEvent) == noErr)
        }
        #expect(notes.count == 2)
        let expected: [(UInt8, Double, Double)] = [(69, 0.16, 1.76), (72, 1.84, 2.16)]
        for (actual, wanted) in zip(notes, expected) {
            #expect(actual.0 == wanted.0 && actual.3 == 80)
            #expect(abs(actual.1 - wanted.1) <= 0.000_261)
            #expect(abs(actual.2 - wanted.2) <= 0.000_261)
        }
        var trackLength: MusicTimeStamp = 0, lengthSize = UInt32(MemoryLayout<MusicTimeStamp>.size)
        #expect(MusicTrackGetProperty(track, kSequenceTrackProperty_TrackLength, &trackLength, &lengthSize) == noErr)
        var seconds: Float64 = 0
        #expect(MusicSequenceGetSecondsForBeats(sequence, trackLength, &seconds) == noErr)
        #expect(abs(seconds - Double(count) / 16000) <= 0.000_261)

        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? FileManager.default.temporaryDirectory.path
        let directory = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ordinary-notes.wav")
        let wav = try PitchNotePreview.encodeWAV(result: result)
        try wav.write(to: url)
        if let evidence = ProcessInfo.processInfo.environment["D_HUM_EXCHANGE_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: evidence)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try midi.write(to: directory.appendingPathComponent("synthetic-notes.mid"), options: .withoutOverwriting)
            try wav.write(to: directory.appendingPathComponent("synthetic-notes.wav"), options: .withoutOverwriting)
            try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("synthetic-analysis.json"), options: .withoutOverwriting)
        }
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48000 && file.fileFormat.channelCount == 1)
        #expect(file.length == count * 3)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        let total = Int(buffer.frameLength)
        let silenceRanges = [0..<7680, 84480..<88320, 103680..<total]
        for range in silenceRanges { #expect(range.allSatisfy { samples[$0] == 0 }) }
        #expect((0..<total).allSatisfy { samples[$0].isFinite && abs(samples[$0]) <= 0.200_02 })
        for (start, end, frequency) in [(7680, 84480, 440.0), (88320, 103680, 523.251130601)] {
            #expect(samples[start] == 0 && samples[end - 1] == 0)
            var crossings: [Double] = []
            for i in (start + 300)..<(end - 300) where samples[i - 1] <= 0 && samples[i] > 0 {
                let fraction = Double(-samples[i - 1] / (samples[i] - samples[i - 1]))
                crossings.append(Double(i - 1) + fraction)
            }
            #expect(crossings.count > 20)
            let measured = Double(crossings.count - 1) * 48000 / (try #require(crossings.last) - #require(crossings.first))
            #expect(abs(measured - frequency) < 0.1)
        }
    }

    @Test(arguments: [false, true])
    func reusedOriginalReaderRejectsNamedReplacementEvenInCancelledTask(cancel: Bool) async throws {
        try await withPitchFixture { root, store, document, _ in
            let registered = try await store.inspectAudio(documentID: document.id).url
            let before = try Data(contentsOf: registered)
            let backup = root.appendingPathComponent("original-backup")
            let replacement = Data("different inode and invalid audio".utf8)
            let job = Task {
                if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                return try AudioMediaInspector.withOriginalSource(at: registered) { _, count in
                    #expect(count == before.count)
                    try FileManager.default.moveItem(at: registered, to: backup)
                    try replacement.write(to: registered, options: .withoutOverwriting)
                    return true
                }
            }
            await #expect(throws: AudioMediaError.self) { _ = try await job.value }
            #expect(try Data(contentsOf: backup) == before)
            #expect(try Data(contentsOf: registered) == replacement)
        }
    }

    @Test func maximumMIDIAndMalformedAnalysisStayBounded() throws {
        var frames = Array(repeating: PitchFrame(pitchHz: nil, confidence: 0, voiced: false), count: 7500)
        for i in 7495..<7500 { frames[i] = PitchFrame(pitchHz: 440, confidence: 0.99, voiced: true) }
        let source = PitchSourceIdentity(assetID: UUID(), documentID: UUID(), documentRevision: 0,
            contentSHA256: String(repeating: "a", count: 64), sampleRate: 16000,
            frameCount: 1_920_000, startFrame: 0, endFrame: 1_920_000)
        let result = PitchAnalysisResult(runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
                                        sampleCount: 1_920_000, frames: frames)
        let data = try PitchMIDIFile.encode(result: result)
        #expect(data.count < 1024)
        var seq: MusicSequence?
        #expect(NewMusicSequence(&seq) == noErr)
        let sequence = try #require(seq)
        defer { DisposeMusicSequence(sequence) }
        #expect(MusicSequenceFileLoadData(sequence, data as CFData, .midiType, []) == noErr)
        var track: MusicTrack?
        #expect(MusicSequenceGetIndTrack(sequence, 0, &track) == noErr)
        var length: MusicTimeStamp = 0, size = UInt32(MemoryLayout<MusicTimeStamp>.size)
        #expect(MusicTrackGetProperty(try #require(track), kSequenceTrackProperty_TrackLength, &length, &size) == noErr)
        var seconds: Float64 = 0
        #expect(MusicSequenceGetSecondsForBeats(sequence, length, &seconds) == noErr)
        #expect(abs(seconds - 120) < 0.000_001)
        frames[0] = PitchFrame(pitchHz: .nan, confidence: 0.99, voiced: true)
        let bad = PitchAnalysisResult(runID: result.runID, source: source, inputSHA256: result.inputSHA256,
                                     sampleCount: result.sampleCount, frames: frames)
        #expect(throws: InferenceFailure.self) { try PitchMIDIFile.encode(result: bad) }
        #expect(throws: InferenceFailure.self) { try PitchNotePreview.encodeWAV(result: bad) }
    }

    @Test func runningPreviewRespondsToCancellation() async throws {
        let source = PitchSourceIdentity(assetID: UUID(), documentID: UUID(), documentRevision: 0,
            contentSHA256: String(repeating: "a", count: 64), sampleRate: 16000,
            frameCount: 1_920_000, startFrame: 0, endFrame: 1_920_000)
        let result = PitchAnalysisResult(runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
            sampleCount: 1_920_000, frames: Array(repeating: .init(pitchHz: 440, confidence: 0.99, voiced: true), count: 7500))
        let (started, continuation) = AsyncStream.makeStream(of: Bool.self)
        let work = Task.detached {
            continuation.yield(true); continuation.finish()
            return try PitchNotePreview.encodeWAV(result: result)
        }
        for await _ in started { break }
        try await Task.sleep(for: .milliseconds(1))
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
    }

    @Test(arguments: [false, true])
    func retainedResultExportsAndReopensWithoutChangingInputs(preview: Bool) async throws {
        try await withPitchFixture { root, store, document, original in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (result, asset) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            let output = root.appendingPathComponent(preview ? "音符 🎵.wav" : "音符 🎵.mid")
            await #expect(throws: ProjectStoreError.self) { try await exchange(store, asset.id, document.id, output, preview) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            let manifest = project.appendingPathComponent(ProjectStore.manifestFilename)
            let before = try Data(contentsOf: manifest), analysis = try Data(contentsOf: await store.assetURL(for: asset))
            let registeredOriginalURL = try await store.inspectAudio(documentID: document.id).url
            let registeredOriginal = try Data(contentsOf: registeredOriginalURL)
            try await exchange(store, asset.id, document.id, output, preview)
            let expected = try preview ? PitchNotePreview.encodeWAV(result: result) : PitchMIDIFile.encode(result: result)
            #expect(try Data(contentsOf: output) == expected)
            #expect(try Data(contentsOf: manifest) == before)
            #expect(try Data(contentsOf: registeredOriginalURL) == registeredOriginal)
            #expect(try Data(contentsOf: await store.assetURL(for: asset)) == analysis)
            #expect(try Data(contentsOf: root.appendingPathComponent("source.wav")) == original)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            try await exchange(reopened, asset.id, document.id, root.appendingPathComponent("reopened"), preview)
            #expect(try Data(contentsOf: root.appendingPathComponent("reopened")) == expected)
            #expect(try Data(contentsOf: manifest) == before)
            try await reopened.close()
        }
    }

    @Test(arguments: [false, true])
    func rejectedWrongDocumentAndRevisedSourceCannotExport(preview: Bool) async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject"), output = root.appendingPathComponent("output")
            let (_, rejected) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.decidePitchAnalysis(assetID: rejected.id, documentID: document.id, accept: false)
            await #expect(throws: ProjectStoreError.self) { try await exchange(store, rejected.id, document.id, output, preview) }
            let (_, asset) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            let imported = try await store.importAudio(at: root.appendingPathComponent("source.wav"), name: "另一份原声")
            let other = try #require(imported.documents.last)
            await #expect(throws: ProjectStoreError.self) { try await exchange(store, asset.id, other.id, output, preview) }
            var draft = try #require(await store.snapshot().documents.first(where: { $0.id == document.id })?.audioDraft)
            let previousRevision = draft.revision
            draft.note = "changed after analysis"; draft.revision += 1
            _ = try await store.saveAudioDraft(draft, documentID: document.id, expectedRevision: previousRevision)
            await #expect(throws: ProjectStoreError.self) { try await exchange(store, asset.id, document.id, output, preview) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test(arguments: ["analysis", "original", "manifest"])
    func externalInputChangesBlockBothExports(changed: String) async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (_, asset) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            let original = try await store.inspectAudio(documentID: document.id)
            let file = changed == "analysis" ? try await store.assetURL(for: asset) :
                (changed == "original" ? original.url : project.appendingPathComponent(ProjectStore.manifestFilename))
            let originalBytes = try Data(contentsOf: file)
            let sentinel = Data("deliberately damaged owned fixture".utf8)
            try sentinel.write(to: file)
            for preview in [false, true] {
                let output = root.appendingPathComponent("output-\(preview)")
                await #expect(throws: (any Error).self) { try await exchange(store, asset.id, document.id, output, preview) }
                #expect(!FileManager.default.fileExists(atPath: output.path))
            }
            #expect(try Data(contentsOf: file) == sentinel)
            try originalBytes.write(to: file) // Restore only this owned failure fixture for normal close.
        }
    }

    @Test(arguments: [false, true])
    func collisionsSymlinksAndProjectDestinationsAreProtected(preview: Bool) async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (_, asset) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            let sentinel = Data("existing work".utf8), target = root.appendingPathComponent("existing")
            try sentinel.write(to: target)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let parentLink = root.appendingPathComponent("directory-link")
            try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
            let manifest = project.appendingPathComponent(ProjectStore.manifestFilename)
            let before = try Data(contentsOf: manifest)
            for destination in [target, link, parentLink.appendingPathComponent("redirected"), project.appendingPathComponent("unregistered.mid"), project.appendingPathComponent("Tasks/unregistered.wav")] {
                await #expect(throws: ProjectStoreError.self) { try await exchange(store, asset.id, document.id, destination, preview) }
            }
            #expect(try Data(contentsOf: target) == sentinel)
            #expect(try Data(contentsOf: manifest) == before)
            #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("unregistered.mid").path))
            #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("Tasks/unregistered.wav").path))
        }
    }

    @Test(arguments: [false, true])
    func preparationFailureAndTamperingNeverPublish(preview: Bool) async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (_, asset) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            let manifest = project.appendingPathComponent(ProjectStore.manifestFilename), before = try Data(contentsOf: manifest)
            for mode in 0...2 {
                let destination = root.appendingPathComponent("failure-\(mode)")
                await #expect(throws: (any Error).self) {
                    try await exchange(store, asset.id, document.id, destination, preview) { point in
                        if case .contentDurable(let temporary) = point {
                            if mode == 0 { throw ProjectStoreError.io("controlled write failure") }
                            if mode == 1 { try Data("bad temporary".utf8).write(to: temporary) }
                            if mode == 2 { try Data("external manifest".utf8).write(to: manifest) }
                        }
                    }
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                if mode == 2 { try before.write(to: manifest) } // Restore only this deliberately damaged test fixture.
            }
            #expect(try Data(contentsOf: manifest) == before)
        }
    }

    @Test(arguments: [false, true])
    func errorAfterPublicationRetainsDeliveredFile(preview: Bool) async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (result, asset) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            let output = root.appendingPathComponent("published")
            await #expect(throws: ProjectStoreError.self) {
                try await exchange(store, asset.id, document.id, output, preview) { point in
                    if case .published = point { throw ProjectStoreError.io("controlled sync failure") }
                }
            }
            let expected = try preview ? PitchNotePreview.encodeWAV(result: result) : PitchMIDIFile.encode(result: result)
            #expect(try Data(contentsOf: output) == expected)
        }
    }

    @Test(arguments: [false, true])
    func substitutedTemporaryLinkCannotBePublished(preview: Bool) async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (result, asset) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            let bytes = try preview ? PitchNotePreview.encodeWAV(result: result) : PitchMIDIFile.encode(result: result)
            let replacement = root.appendingPathComponent("replacement"); try bytes.write(to: replacement)
            for hard in [false, true] {
                let output = root.appendingPathComponent("substitution-\(hard)")
                await #expect(throws: (any Error).self) {
                    try await exchange(store, asset.id, document.id, output, preview) { point in
                        if case .contentDurable(let temporary) = point {
                            try FileManager.default.removeItem(at: temporary)
                            if hard { try FileManager.default.linkItem(at: replacement, to: temporary) }
                            else { try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: replacement) }
                        }
                    }
                }
                #expect(!FileManager.default.fileExists(atPath: output.path))
                #expect(try Data(contentsOf: replacement) == bytes)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func publicationErrorStillReportsConcurrentInputDamage(cancel: Bool, damageOriginal: Bool) async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (_, asset) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            let output = root.appendingPathComponent("published")
            let manifest = project.appendingPathComponent(ProjectStore.manifestFilename)
            let damagedURL = damageOriginal ? try await store.inspectAudio(documentID: document.id).url : manifest
            let before = try Data(contentsOf: damagedURL)
            let job = Task { () -> String in
                do {
                    try await exchange(store, asset.id, document.id, output, false) { point in
                        if case .published = point {
                            try Data("concurrent damage".utf8).write(to: damagedURL)
                            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                            else { throw ProjectStoreError.io("controlled post-publication error") }
                        }
                    }
                    return "unexpected success"
                } catch { return String(describing: error) }
            }
            let error = await job.value
            #expect(error.contains("来源复核失败"))
            #expect(FileManager.default.fileExists(atPath: output.path))
            #expect(try Data(contentsOf: damagedURL) == Data("concurrent damage".utf8))
            try before.write(to: damagedURL) // Owned fixture cleanup after protection assertions.
        }
    }

    @Test(arguments: [false, true])
    func cancellationBeforeWorkOrPublicationLeavesNoOutput(preview: Bool) async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (_, asset) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            for atPublication in [false, true] {
                let output = root.appendingPathComponent("cancel-\(atPublication)")
                let job = Task {
                    if !atPublication { withUnsafeCurrentTask { $0?.cancel() } }
                    try await exchange(store, asset.id, document.id, output, preview) { point in
                        if case .contentDurable = point, atPublication { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
                await #expect(throws: CancellationError.self) { try await job.value }
                #expect(!FileManager.default.fileExists(atPath: output.path))
            }
        }
    }
}

private func exchange(_ store: ProjectStore, _ asset: UUID, _ document: UUID, _ output: URL, _ preview: Bool,
                      checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)? = nil) async throws {
    if preview { try await store.exportPitchNotePreview(assetID: asset, documentID: document, to: output, checkpoint: checkpoint) }
    else { try await store.exportPitchMIDI(assetID: asset, documentID: document, to: output, checkpoint: checkpoint) }
}

private let pitchModel = ModelReference(directory: URL(fileURLWithPath: "/fixture/swift_f0"), revision: PitchAnalysisRequest.modelSHA256)
private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func pitchResult(request: PitchAnalysisRequest, id: UUID) -> PitchAnalysisResult {
    .init(runID: id, source: request.source, inputSHA256: request.inputSHA256, sampleCount: request.sampleCount,
          frames: Array(repeating: .init(pitchHz: 440, confidence: 0.99, voiced: true), count: request.sampleCount / 256))
}
private func pitchCandidate(store: ProjectStore, documentID: UUID, project: URL) async throws -> (PitchAnalysisResult, ProjectAsset) {
    let id = UUID(), request = try await store.preparePitchInput(documentID: documentID, runID: id)
    _ = try await store.enqueue(request: .init(id: id, model: pitchModel, input: .pitch(request)), documentID: documentID)
    let result = pitchResult(request: request, id: id), output = project.appendingPathComponent("Tasks/\(id.uuidString)/pitch.json")
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(result).write(to: output)
    let completed = try await store.complete(id: id, result: .init(artifacts: [.init(url: output, mediaType: PitchAnalysisResult.mediaType)]))
    return (result, try #require(completed.assets.last))
}
private func withPitchFixture(rate: Int = 16_000, body: (URL, ProjectStore, ProjectDocument, Data) async throws -> Void) async throws {
    let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? FileManager.default.temporaryDirectory.path
    let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.wav")
    let samples = (0..<rate).map { Float(0.4 * sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
    try AudioTestMedia.writePCM(to: source, samples: [samples], sampleRate: Double(rate), bitDepth: 32, floatingPoint: true)
    let store = try await ProjectStore.create(at: root.appendingPathComponent("Pitch.dproject"), name: "Pitch")
    let imported = try await store.importAudio(at: source, name: "哼唱 🎵")
    try await body(root, store, try #require(imported.documents.last), Data(contentsOf: source))
    try await store.close()
}
